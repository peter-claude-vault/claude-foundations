#!/bin/bash
# tests/sp07/initial-job-setup-unit-test.sh — synthetic unit tests for SP07 T-9
# onboarding/initial-job-setup.sh.
#
# Validates the 8 acceptance criteria from
# ~/.claude-plans/71-claude-foundations-engine-v2/07-onboarder-ux/tasks.md L200-208:
#
#   T1 (AC #1, #2, #3): default librarian → dry-run preview + plist staged at
#       $STAGING_DIR/com.claude-stem.librarian-scan.plist; never at
#       ~/Library/LaunchAgents/.
#   T2 (AC #1, #2, #3): architect alt → plist staged with weekday-aware
#       schedule under com.claude-stem.architect-analysis.plist.
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
#
# T-9-followup adds 8-Q interview surface tests (T8..T17) covering AC #8:
#   T8  AUTO_CONFIRM=1 + no AUTO_OVERRIDES → interview skipped, no
#       interview_override audit line.
#   T9  AUTO_OVERRIDES=Q1=architect on librarian fixture → jobs[0] re-derived
#       to architect defaults (budget=10, model=opus, dow=[1]).
#   T10 AUTO_OVERRIDES=Q1=none → interview short-circuits, jobs:[] written,
#       interview_opt_out_9 audit event, exit 0, no plist staged.
#   T11 AUTO_OVERRIDES=Q2=14:30 → schedule.hour/minute updated.
#   T12 AUTO_OVERRIDES=Q2=25:99 → invalid time rejected (rc=3).
#   T13 AUTO_OVERRIDES=Q4=3 on architect → schedule.dow=[3] updated.
#   T14 AUTO_OVERRIDES=Q4=... on librarian → Q4 not asked (no dow drift).
#   T15 AUTO_OVERRIDES=Q6=-5 → invalid budget rejected (rc=3).
#   T16 AUTO_OVERRIDES=Q7=foobar → invalid model rejected (rc=3).
#   T17 corrections[] in audit JSONL contains field paths only (no
#       user-typed values; reference-leak floor / Hard Rule 9).
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

# Variant for T-9-followup (8-Q interview): caller supplies AUTO_OVERRIDES.
# AUTO_CONFIRM stays 1 to bypass the staging y/n prompt.
run_script_with_overrides() {
  local hroot="$1" overrides="$2"; shift 2
  HOME="$hroot" \
  CLAUDE_HOME="$hroot/.claude" \
  RENDER_LAUNCHD="$RENDER" \
  STAGING_DIR="$hroot/.claude/Library/LaunchAgents.staging" \
  AUDIT_LOG="$hroot/.claude/onboarding/audit/initial-job-setup.jsonl" \
  AUTO_CONFIRM=1 \
  AUTO_OVERRIDES="$overrides" \
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
T1_PLIST="$T1_HOME/.claude/Library/LaunchAgents.staging/com.claude-stem.librarian-scan.plist"
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
T2_PLIST="$T2_HOME/.claude/Library/LaunchAgents.staging/com.claude-stem.architect-analysis.plist"
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

# ============================================================
# T-9-followup: 8-Q interview surface tests (AC #8)
# ============================================================

LIBRARIAN_FIXTURE='{
  "schema_version": "1.0.0",
  "platform": "darwin-launchd",
  "jobs": [
    {"id": "librarian", "enabled": true, "schedule": {"hour": 6, "minute": 0}, "command": "x", "log_path": "x", "idle_watchdog_sec": 180, "budget_usd": 5, "model": "sonnet", "skip_weekends": true}
  ],
  "tripwires": [],
  "observability": {"morning_brief_staleness_h": 48, "librarian_staleness_h": 24, "sessionstart_banner_staleness_h": 24}
}'

ARCHITECT_FIXTURE='{
  "schema_version": "1.0.0",
  "platform": "darwin-launchd",
  "jobs": [
    {"id": "architect", "enabled": true, "schedule": {"hour": 6, "minute": 0, "dow": [1]}, "command": "x", "log_path": "x", "idle_watchdog_sec": 180, "budget_usd": 10, "model": "opus"}
  ],
  "tripwires": [],
  "observability": {"morning_brief_staleness_h": 48, "librarian_staleness_h": 24, "sessionstart_banner_staleness_h": 24}
}'

# ---------- T8: AUTO_CONFIRM=1 + no AUTO_OVERRIDES → interview skipped ----------
# T7 already verified the staged-event audit line; re-use T1's audit log to
# confirm no interview_override line was emitted (the existing 10/10 path
# proves this implicitly, but we assert it explicitly here).
T8_AUDIT="$T1_HOME/.claude/onboarding/audit/initial-job-setup.jsonl"
T8_INTERVIEW_LINES=$(grep '"event":"interview_override"' "$T8_AUDIT" 2>/dev/null | wc -l | tr -d ' ')
if [ "$T8_INTERVIEW_LINES" = "0" ]; then
  pass "T8 AUTO_CONFIRM-only path → no interview_override audit line"
else
  fail "T8" "expected 0 interview_override events; got $T8_INTERVIEW_LINES"
fi

# ---------- T9: Q1 swap librarian → architect re-derives defaults ----------
T9_HOME="$TEST_ROOT/t9"
setup_fake_home "$T9_HOME" "$LIBRARIAN_FIXTURE"
T9_OUT="$TEST_ROOT/t9.out"
run_script_with_overrides "$T9_HOME" "Q1=architect" > "$T9_OUT" 2>&1
T9_RC=$?
T9_ID=$(jq -r '.jobs[0].id' "$T9_HOME/orchestration.json")
T9_BUDGET=$(jq -r '.jobs[0].budget_usd' "$T9_HOME/orchestration.json")
T9_MODEL=$(jq -r '.jobs[0].model' "$T9_HOME/orchestration.json")
T9_DOW=$(jq -r '.jobs[0].schedule.dow[0]' "$T9_HOME/orchestration.json")
T9_PLIST="$T9_HOME/.claude/Library/LaunchAgents.staging/com.claude-stem.architect-analysis.plist"
if [ "$T9_RC" -eq 0 ] \
   && [ "$T9_ID" = "architect" ] \
   && [ "$T9_BUDGET" = "10" ] \
   && [ "$T9_MODEL" = "opus" ] \
   && [ "$T9_DOW" = "1" ] \
   && [ -f "$T9_PLIST" ]; then
  pass "T9 Q1=architect on librarian fixture → defaults re-derived (budget=10, model=opus, dow=[1])"
else
  fail "T9" "rc=$T9_RC, id=$T9_ID, budget=$T9_BUDGET, model=$T9_MODEL, dow=$T9_DOW, plist_exists=$([ -f "$T9_PLIST" ] && echo y || echo n)"
fi

# ---------- T10: Q1=none → interview short-circuit, jobs:[], no plist ----------
T10_HOME="$TEST_ROOT/t10"
setup_fake_home "$T10_HOME" "$LIBRARIAN_FIXTURE"
T10_OUT="$TEST_ROOT/t10.out"
run_script_with_overrides "$T10_HOME" "Q1=none" > "$T10_OUT" 2>&1
T10_RC=$?
T10_JOBS_LEN=$(jq -r '.jobs | length' "$T10_HOME/orchestration.json")
T10_STAGED_COUNT=$(ls -1 "$T10_HOME/.claude/Library/LaunchAgents.staging"/*.plist 2>/dev/null | wc -l | tr -d ' ')
T10_AUDIT="$T10_HOME/.claude/onboarding/audit/initial-job-setup.jsonl"
T10_OPT_OUT_LINES=$(grep '"event":"interview_opt_out_9"' "$T10_AUDIT" 2>/dev/null | wc -l | tr -d ' ')
if [ "$T10_RC" -eq 0 ] \
   && [ "$T10_JOBS_LEN" = "0" ] \
   && [ "$T10_STAGED_COUNT" = "0" ] \
   && [ "$T10_OPT_OUT_LINES" -ge 1 ]; then
  pass "T10 Q1=none → jobs:[] + interview_opt_out_9 audit + no plist"
else
  fail "T10" "rc=$T10_RC, jobs_len=$T10_JOBS_LEN, staged=$T10_STAGED_COUNT, opt_out_lines=$T10_OPT_OUT_LINES"
fi

# ---------- T11: Q2 time override → schedule.hour/minute updated ----------
T11_HOME="$TEST_ROOT/t11"
setup_fake_home "$T11_HOME" "$LIBRARIAN_FIXTURE"
T11_OUT="$TEST_ROOT/t11.out"
run_script_with_overrides "$T11_HOME" "Q2=14:30" > "$T11_OUT" 2>&1
T11_RC=$?
T11_HOUR=$(jq -r '.jobs[0].schedule.hour' "$T11_HOME/orchestration.json")
T11_MIN=$(jq -r '.jobs[0].schedule.minute' "$T11_HOME/orchestration.json")
if [ "$T11_RC" -eq 0 ] && [ "$T11_HOUR" = "14" ] && [ "$T11_MIN" = "30" ]; then
  pass "T11 Q2=14:30 → schedule.hour=14, minute=30"
else
  fail "T11" "rc=$T11_RC, hour=$T11_HOUR, minute=$T11_MIN"
fi

# ---------- T12: invalid time rejected (rc=3) ----------
T12_HOME="$TEST_ROOT/t12"
setup_fake_home "$T12_HOME" "$LIBRARIAN_FIXTURE"
T12_OUT="$TEST_ROOT/t12.out"
run_script_with_overrides "$T12_HOME" "Q2=25:99" > "$T12_OUT" 2>&1
T12_RC=$?
if [ "$T12_RC" = "3" ] && grep -q "Q2 invalid time" "$T12_OUT"; then
  pass "T12 Q2=25:99 → rejected (rc=3) with 'Q2 invalid time' diag"
else
  fail "T12" "rc=$T12_RC, out=$(head -3 "$T12_OUT" | tr '\n' '|')"
fi

# ---------- T13: Q4 architect dow override ----------
T13_HOME="$TEST_ROOT/t13"
setup_fake_home "$T13_HOME" "$ARCHITECT_FIXTURE"
T13_OUT="$TEST_ROOT/t13.out"
run_script_with_overrides "$T13_HOME" "Q4=3" > "$T13_OUT" 2>&1
T13_RC=$?
T13_DOW=$(jq -r '.jobs[0].schedule.dow[0]' "$T13_HOME/orchestration.json")
if [ "$T13_RC" -eq 0 ] && [ "$T13_DOW" = "3" ] && grep -q 'Schedule: weekly Wednesday' "$T13_OUT"; then
  pass "T13 Q4=3 on architect → dow=[3], 'weekly Wednesday' in preview"
else
  fail "T13" "rc=$T13_RC, dow=$T13_DOW, schedule_line=$(grep -i schedule "$T13_OUT" | head -1)"
fi

# ---------- T14: Q4 silently ignored on librarian (no Q4 prompt for daily jobs) ----------
T14_HOME="$TEST_ROOT/t14"
setup_fake_home "$T14_HOME" "$LIBRARIAN_FIXTURE"
T14_OUT="$TEST_ROOT/t14.out"
# Q4=5 in CSV would set Saturday IF asked. Librarian skip rule must drop it.
run_script_with_overrides "$T14_HOME" "Q4=5" > "$T14_OUT" 2>&1
T14_RC=$?
T14_DOW=$(jq -r '.jobs[0].schedule.dow // "absent"' "$T14_HOME/orchestration.json")
if [ "$T14_RC" -eq 0 ] && [ "$T14_DOW" = "absent" ]; then
  pass "T14 Q4=5 on librarian → not asked (dow absent from manifest)"
else
  fail "T14" "rc=$T14_RC, dow=$T14_DOW"
fi

# ---------- T15: invalid budget rejected (rc=3) ----------
T15_HOME="$TEST_ROOT/t15"
setup_fake_home "$T15_HOME" "$LIBRARIAN_FIXTURE"
T15_OUT="$TEST_ROOT/t15.out"
run_script_with_overrides "$T15_HOME" "Q6=-5" > "$T15_OUT" 2>&1
T15_RC=$?
if [ "$T15_RC" = "3" ] && grep -q "Q6 invalid budget" "$T15_OUT"; then
  pass "T15 Q6=-5 → rejected (rc=3) with 'Q6 invalid budget' diag"
else
  fail "T15" "rc=$T15_RC, out=$(head -3 "$T15_OUT" | tr '\n' '|')"
fi

# ---------- T16: invalid model rejected (rc=3) ----------
T16_HOME="$TEST_ROOT/t16"
setup_fake_home "$T16_HOME" "$LIBRARIAN_FIXTURE"
T16_OUT="$TEST_ROOT/t16.out"
run_script_with_overrides "$T16_HOME" "Q7=foobar" > "$T16_OUT" 2>&1
T16_RC=$?
if [ "$T16_RC" = "3" ] && grep -q "Q7 invalid model" "$T16_OUT"; then
  pass "T16 Q7=foobar → rejected (rc=3) with 'Q7 invalid model' diag"
else
  fail "T16" "rc=$T16_RC, out=$(head -3 "$T16_OUT" | tr '\n' '|')"
fi

# ---------- T17: corrections[] field-paths only (Hard Rule 9 reference-leak floor) ----------
# Multi-Q override; verify audit JSONL corrections[] contains field paths
# matching ^[UO]\. and does NOT contain user-typed values (like "14:30",
# "haiku", "20", etc.).
T17_HOME="$TEST_ROOT/t17"
setup_fake_home "$T17_HOME" "$LIBRARIAN_FIXTURE"
T17_OUT="$TEST_ROOT/t17.out"
run_script_with_overrides "$T17_HOME" "Q2=14:30,Q6=20,Q7=haiku" > "$T17_OUT" 2>&1
T17_RC=$?
T17_AUDIT="$T17_HOME/.claude/onboarding/audit/initial-job-setup.jsonl"
T17_OVERRIDE_LINE=$(grep '"event":"interview_override"' "$T17_AUDIT" | head -1)

# AC: line exists; corrections[] is non-empty; every element starts with U. or O.;
# none of the user-typed values (14:30, 20, haiku) appear anywhere on that line.
T17_OK=1
if [ -z "$T17_OVERRIDE_LINE" ]; then
  T17_OK=0
  T17_REASON="missing interview_override line"
elif ! echo "$T17_OVERRIDE_LINE" | jq -e '.corrections | length > 0 and all(. | test("^[UO]\\."))' >/dev/null 2>&1; then
  T17_OK=0
  T17_REASON="corrections[] empty or contains non-path entries"
elif echo "$T17_OVERRIDE_LINE" | grep -qE '14:30|"haiku"|"20"'; then
  T17_OK=0
  T17_REASON="user-typed value leaked into audit line"
fi

if [ "$T17_OK" = "1" ]; then
  pass "T17 corrections[] field-paths only (no leak of user-typed values)"
else
  fail "T17" "$T17_REASON; line=$T17_OVERRIDE_LINE"
fi

# ---------- T18: Q1=architect fixture + Q8 librarian-only skipped on swap ----------
# When Q1 swaps to architect, skip_weekends should be absent from manifest
# (architect runs once weekly; skip_weekends is meaningless).
T18_HOME="$TEST_ROOT/t18"
setup_fake_home "$T18_HOME" "$LIBRARIAN_FIXTURE"
T18_OUT="$TEST_ROOT/t18.out"
run_script_with_overrides "$T18_HOME" "Q1=architect" > "$T18_OUT" 2>&1
T18_RC=$?
T18_SKIPW=$(jq -r '.jobs[0].skip_weekends // "absent"' "$T18_HOME/orchestration.json")
if [ "$T18_RC" -eq 0 ] && [ "$T18_SKIPW" = "absent" ]; then
  pass "T18 Q1=architect → skip_weekends absent from architect job"
else
  fail "T18" "rc=$T18_RC, skip_weekends=$T18_SKIPW"
fi

# ---------- T19: Q5 path with ~/ expansion ----------
T19_HOME="$TEST_ROOT/t19"
setup_fake_home "$T19_HOME" "$LIBRARIAN_FIXTURE"
T19_OUT="$TEST_ROOT/t19.out"
HOME="$T19_HOME" run_script_with_overrides "$T19_HOME" "Q5=~/.claude/altlogs" > "$T19_OUT" 2>&1
T19_RC=$?
T19_LOG=$(jq -r '.jobs[0].log_path' "$T19_HOME/orchestration.json")
if [ "$T19_RC" -eq 0 ] && [ "$T19_LOG" = "$T19_HOME/.claude/altlogs" ]; then
  pass "T19 Q5=~/path → eval-expanded to absolute"
else
  fail "T19" "rc=$T19_RC, log_path=$T19_LOG (expected $T19_HOME/.claude/altlogs)"
fi

# ---------- T20: invalid TZ (abbreviation, not IANA) rejected (rc=3) ----------
T20_HOME="$TEST_ROOT/t20"
setup_fake_home "$T20_HOME" "$LIBRARIAN_FIXTURE"
T20_OUT="$TEST_ROOT/t20.out"
run_script_with_overrides "$T20_HOME" "Q3=EDT" > "$T20_OUT" 2>&1
T20_RC=$?
if [ "$T20_RC" = "3" ] && grep -q "Q3 invalid TZ" "$T20_OUT"; then
  pass "T20 Q3=EDT (abbreviation) → rejected (rc=3) with 'Q3 invalid TZ' diag"
else
  fail "T20" "rc=$T20_RC, out=$(head -3 "$T20_OUT" | tr '\n' '|')"
fi

# ---------- summary ----------
echo "=== initial-job-setup-unit-test ==="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
