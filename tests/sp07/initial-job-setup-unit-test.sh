#!/bin/bash
# tests/sp07/initial-job-setup-unit-test.sh — synthetic unit tests for SP07 T-9
# onboarding/initial-job-setup.sh.
#
# Validates the 8 acceptance criteria from
# ~/.claude-plans/71-claude-foundations-engine-v2/07-onboarder-ux/tasks.md L200-208:
#
#   T1 (AC #1, #2, #3): default librarian → dry-run preview + plist staged at
#       $STAGING_DIR/com.claude-foundations.librarian-scan.plist; never at
#       ~/Library/LaunchAgents/.
#   T2 (AC #1, #2, #3): architect alt → plist staged with weekday-aware
#       schedule under com.claude-foundations.architect-analysis.plist.
#   T3 (AC #7):         opt-out #9 (jobs:[]) → no plist written, no render
#       invocation, exit 0 cleanly.
#   T4 (AC #4):         post-onboard prompt directs user to
#       `claude system enable-daemon`.
#   T5 (AC #5):         no executable line in initial-job-setup.sh invokes
#       launchctl (production-flow rule).
#   T6 (structural):    no executable line writes outside the staging dir
#       (no `Library/LaunchAgents` path that lacks the `.staging` suffix).
#   T7 (AC #1):         audit JSONL written with the expected schema fields
#       (timestamp + event + job + schedule + plist_path for staged event;
#       timestamp + event for opt-out event).
#
# AC #6 (test/dogfood launchctl bootstrap under SP00 T-9 sandbox-exec inside
# SP00 T-1 Lima) is gated behind SP00 dependencies and validated by SP07
# T-11 Alex dogfood — out of scope for this unit-test sibling.
# AC #8 (per-job defaults from initial-job-setup-flow.md) is gated behind
# SP07 T-5 (Section D record-and-drop UX) which is not-started; T-9 slice
# stubs Section D output via fixture and ships the rendering shell only.
#
# Hermetic: per-test fake $HOME with stub paths.sh + per-test
# orchestration.json fixture. Real render-launchd.sh from foundation-repo
# is invoked (deps: jq, plutil, envsubst — verified at session pre-flight).
# Bash 3.2 clean (R-23).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/onboarding/initial-job-setup.sh"
RENDER="$REPO_ROOT/installer/render-launchd.sh"

if [ ! -x "$SCRIPT" ]; then echo "FAIL: cannot exec $SCRIPT"; exit 2; fi
if [ ! -x "$RENDER" ]; then echo "FAIL: cannot exec $RENDER"; exit 2; fi

TEST_ROOT="$(mktemp -d -t initial-job-setup-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 — $2"; }

# Per-test fake $HOME with paths.sh + orchestration.json fixture.
# $1 = fake home root, $2 = orchestration.json content (heredoc body).
setup_fake_home() {
  local hroot="$1"
  local orch_json="$2"
  mkdir -p "$hroot/.claude/hooks/lib" \
           "$hroot/.claude/logs" \
           "$hroot/.claude/Library/LaunchAgents.staging" \
           "$hroot/.claude/onboarding/audit"

  cat > "$hroot/.claude/hooks/lib/paths.sh" <<EOF
export CLAUDE_HOME="$hroot/.claude"
export CLAUDE_LOG_DIR="$hroot/.claude/logs"
export ORCHESTRATION_JSON="$hroot/orchestration.json"
EOF

  printf '%s\n' "$orch_json" > "$hroot/orchestration.json"
}

# Common env exports for invoking the script under test.
# $1 = fake home root.
run_script() {
  local hroot="$1"; shift
  HOME="$hroot" \
  CLAUDE_HOME="$hroot/.claude" \
  RENDER_LAUNCHD="$RENDER" \
  STAGING_DIR="$hroot/.claude/Library/LaunchAgents.staging" \
  AUDIT_LOG="$hroot/.claude/onboarding/audit/initial-job-setup.jsonl" \
  AUTO_CONFIRM=1 \
  "$SCRIPT" "$@"
}

# ---------- T1: default librarian → staged plist ----------
T1_HOME="$TEST_ROOT/t1"
T1_ORCH='{
  "schema_version": "1.0.0",
  "platform": "darwin-launchd",
  "jobs": [
    {"id": "librarian", "enabled": true, "schedule": {"hour": 6, "minute": 0}, "command": "x", "log_path": "x", "idle_watchdog_sec": 180}
  ],
  "tripwires": [],
  "observability": {"morning_brief_staleness_h": 48, "librarian_staleness_h": 24, "sessionstart_banner_staleness_h": 24}
}'
setup_fake_home "$T1_HOME" "$T1_ORCH"
T1_OUT="$TEST_ROOT/t1.out"
run_script "$T1_HOME" > "$T1_OUT" 2>&1
T1_RC=$?
T1_PLIST="$T1_HOME/.claude/Library/LaunchAgents.staging/com.claude-foundations.librarian-scan.plist"
if [ "$T1_RC" -eq 0 ] && [ -f "$T1_PLIST" ] && plutil -lint -s "$T1_PLIST" >/dev/null 2>&1; then
  pass "T1 librarian default → plist staged + plutil-lint clean"
else
  fail "T1" "rc=$T1_RC, plist_exists=$([ -f "$T1_PLIST" ] && echo y || echo n), out=$(head -5 "$T1_OUT" | tr '\n' '|')"
fi

# T1 must NOT have written to ~/Library/LaunchAgents/ (under fake $HOME).
T1_USER_AGENTS="$T1_HOME/Library/LaunchAgents"
if [ ! -d "$T1_USER_AGENTS" ] || [ -z "$(ls -A "$T1_USER_AGENTS" 2>/dev/null)" ]; then
  pass "T1 librarian default → no write to user LaunchAgents dir"
else
  fail "T1-isolation" "user LaunchAgents dir non-empty: $(ls -1 "$T1_USER_AGENTS" 2>&1)"
fi

# ---------- T2: architect alt → staged plist with weekday ----------
T2_HOME="$TEST_ROOT/t2"
T2_ORCH='{
  "schema_version": "1.0.0",
  "platform": "darwin-launchd",
  "jobs": [
    {"id": "architect", "enabled": true, "schedule": {"hour": 6, "minute": 0, "dow": [1]}, "command": "x", "log_path": "x", "idle_watchdog_sec": 180}
  ],
  "tripwires": [],
  "observability": {"morning_brief_staleness_h": 48, "librarian_staleness_h": 24, "sessionstart_banner_staleness_h": 24}
}'
setup_fake_home "$T2_HOME" "$T2_ORCH"
T2_OUT="$TEST_ROOT/t2.out"
run_script "$T2_HOME" > "$T2_OUT" 2>&1
T2_RC=$?
T2_PLIST="$T2_HOME/.claude/Library/LaunchAgents.staging/com.claude-foundations.architect-analysis.plist"
if [ "$T2_RC" -eq 0 ] && [ -f "$T2_PLIST" ] && plutil -lint -s "$T2_PLIST" >/dev/null 2>&1; then
  pass "T2 architect alt → plist staged + plutil-lint clean"
else
  fail "T2" "rc=$T2_RC, plist_exists=$([ -f "$T2_PLIST" ] && echo y || echo n), out=$(head -5 "$T2_OUT" | tr '\n' '|')"
fi

# Verify weekday-aware schedule appeared in human-readable preview.
if grep -q 'Schedule: weekly Monday' "$T2_OUT"; then
  pass "T2 schedule line surfaces weekday from dow[0]"
else
  fail "T2-schedule" "expected 'Schedule: weekly Monday'; got: $(grep -i schedule "$T2_OUT" | head -2)"
fi

# ---------- T3: opt-out #9 (jobs:[]) → no plist, no staging file ----------
T3_HOME="$TEST_ROOT/t3"
T3_ORCH='{
  "schema_version": "1.0.0",
  "platform": "darwin-launchd",
  "jobs": [],
  "tripwires": [],
  "observability": {"morning_brief_staleness_h": 48, "librarian_staleness_h": 24, "sessionstart_banner_staleness_h": 24}
}'
setup_fake_home "$T3_HOME" "$T3_ORCH"
T3_OUT="$TEST_ROOT/t3.out"
run_script "$T3_HOME" > "$T3_OUT" 2>&1
T3_RC=$?
T3_STAGING="$T3_HOME/.claude/Library/LaunchAgents.staging"
T3_STAGED_COUNT=$(ls -1 "$T3_STAGING"/*.plist 2>/dev/null | wc -l | tr -d ' ')
if [ "$T3_RC" -eq 0 ] && [ "$T3_STAGED_COUNT" = "0" ]; then
  pass "T3 opt-out #9 → exit 0, no plist staged"
else
  fail "T3" "rc=$T3_RC, staged_count=$T3_STAGED_COUNT, out=$(head -3 "$T3_OUT" | tr '\n' '|')"
fi

# Audit JSONL must contain opt_out_9_skip event.
T3_AUDIT="$T3_HOME/.claude/onboarding/audit/initial-job-setup.jsonl"
if [ -s "$T3_AUDIT" ] && jq -e '.event == "opt_out_9_skip"' "$T3_AUDIT" >/dev/null 2>&1; then
  pass "T3 audit JSONL records opt_out_9_skip event"
else
  fail "T3-audit" "audit_size=$(stat -f%z "$T3_AUDIT" 2>/dev/null || echo 0), content=$(cat "$T3_AUDIT" 2>&1)"
fi

# ---------- T4: post-onboard prompt directs to enable-daemon ----------
if grep -q 'claude system enable-daemon' "$T1_OUT"; then
  pass "T4 post-onboard prompt emits 'claude system enable-daemon' pointer"
else
  fail "T4" "expected 'claude system enable-daemon' in T1 stdout; got tail: $(tail -5 "$T1_OUT" | tr '\n' '|')"
fi

# ---------- T5: no executable line invokes launchctl ----------
T5_HITS=$(awk '/^[[:space:]]*#/{next} /launchctl/{print}' "$SCRIPT" | wc -l | tr -d ' ')
if [ "$T5_HITS" = "0" ]; then
  pass "T5 no executable launchctl invocation in initial-job-setup.sh"
else
  fail "T5" "$T5_HITS non-comment line(s) reference launchctl; lines: $(awk '/^[[:space:]]*#/{next} /launchctl/{print NR":"$0}' "$SCRIPT")"
fi

# ---------- T6: no executable line writes outside the staging dir ----------
T6_HITS=$(awk '/^[[:space:]]*#/{next} /Library\/LaunchAgents/ && !/Library\/LaunchAgents\.staging/{print}' "$SCRIPT" | wc -l | tr -d ' ')
if [ "$T6_HITS" = "0" ]; then
  pass "T6 no non-staging Library/LaunchAgents reference in executable code"
else
  fail "T6" "$T6_HITS non-staging hit(s); lines: $(awk '/^[[:space:]]*#/{next} /Library\/LaunchAgents/ && !/Library\/LaunchAgents\.staging/{print NR":"$0}' "$SCRIPT")"
fi

# ---------- T7: audit JSONL schema for staged event ----------
T1_AUDIT="$T1_HOME/.claude/onboarding/audit/initial-job-setup.jsonl"
if [ -s "$T1_AUDIT" ] \
   && jq -e '.event == "staged" and .job == "librarian" and .plist_path != "" and .schedule != "" and .timestamp != ""' "$T1_AUDIT" >/dev/null 2>&1; then
  pass "T7 audit JSONL records staged event with all required fields"
else
  fail "T7" "audit content: $(cat "$T1_AUDIT" 2>&1)"
fi

# ---------- summary ----------
echo "=== initial-job-setup-unit-test ==="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
