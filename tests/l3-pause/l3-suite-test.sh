#!/bin/bash
# l3-suite-test.sh — T-17 acceptance fixture suite (Plan 80/81 SP01).
#
# Six tests closing the A4 anti-success criterion (L3 partial-pause state).
# Where Session 2's multi-owner-test.sh validates control-flow primitives,
# this suite asserts the SP09 Incident-β regression and the SP01 atomic-
# rollback / launchctl-rc-error / orphan-state semantics that Plan 71
# SP09 Session 17 surfaced as structural gaps.
#
# Tests:
#   1. idempotence — pause-twice no-op (no new owners; no double-fire)
#   2. multi-owner stack — Plan 80 atop Plan 71; resume only when empty
#   3. atomic-rollback — pause partial-fail → roll back applied + non-zero rc
#   4. orphan-state detection — closed plan's state files persist (no
#      auto-resume); status surfaces them
#   5. launchctl-rc-error surfacing — mock launchctl rc=1 → stderr + non-zero
#   6. Incident-β regression (live-guard cross-tool) — auto-memory write
#      under Plan-71-context with no nonce affinity → DENY; nonce stays on disk

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
L3="$REPO_ROOT/hooks/lib/l3-pause-helper.sh"
LG="$REPO_ROOT/hooks/lib/live-guard.sh"
[[ -x "$L3" ]] || { echo "FAIL: $L3 not executable"; exit 1; }
[[ -x "$LG" ]] || { echo "FAIL: $LG not executable"; exit 1; }

TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

PASS_COUNT=0
FAIL_COUNT=0

assert() {
  if [[ "$1" == "$2" ]]; then
    echo "  PASS: $3"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: $3 (expected '$2', got '$1')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# === Test 1: idempotence ==================================================
echo "Test 1: idempotence — pause-twice no-op (no new owners)"
T1_DIR="$TEST_DIR/t1"
T1_PR="$T1_DIR/.claude-plans"
T1_HS="$T1_DIR/.claude/hooks/state"
mkdir -p "$T1_PR/plan-a" "$T1_HS"
cat > "$T1_PR/plan-a/manifest.json" <<EOF
{"schema_version": 1,
 "live_mutation_scope": {"enabled": true,
   "layer_3": {"enabled": true, "expected_quiescence_period_seconds": 0,
     "session_end_hooks": [{"path": "/h/foo.sh", "pause_via": "sentinel", "sentinel_path": "$T1_HS/foo.lock"}]}}}
EOF
T1_REG="$T1_DIR/registry.json"
echo '{"schema_version": 1, "writers": [{"id": "foo.sh", "hook_path": "/h/foo.sh", "write_paths": ["/x/**"], "pause_mechanism": "sentinel"}]}' > "$T1_REG"

run_t1() {
  HOOKS_STATE_OVERRIDE="$T1_HS" PLANS_ROOT_OVERRIDE="$T1_PR" \
  L3_REGISTRY_PATH="$T1_REG" L3_QUIESCENCE_OVERRIDE=0 SKIP_LAUNCHCTL=1 \
  bash "$L3" "$@"
}

out=$(run_t1 pause plan-a --quiescence-skip)
[[ "$out" == *"writers: 1"* ]] && assert "ok" "ok" "T1 first pause: 1 writer" \
  || assert "no" "ok" "T1 first pause: 1 writer (got: $out)"

# Second pause: zero new writers (idempotent)
out=$(run_t1 pause plan-a --quiescence-skip)
[[ "$out" == *"writers: 0"* ]] && assert "ok" "ok" "T1 second pause idempotent (0 new writers)" \
  || assert "no" "ok" "T1 second pause idempotent (got: $out)"

# Owners array still has only [plan-a] (no duplicate)
sf="$T1_HS/l3-pause-state/foo_sh.json"
owners=$(jq -r '.owners | join(",")' "$sf")
assert "$owners" "plan-a" "T1 owners stable after re-pause"

# Sentinel file present
[[ -e "$T1_HS/foo.lock" ]] && assert "present" "present" "T1 sentinel intact after re-pause" \
  || assert "absent" "present" "T1 sentinel intact after re-pause"

# === Test 2: multi-owner stack ============================================
echo ""
echo "Test 2: multi-owner stack — Plan 80 atop Plan 71; full release only when empty"
T2_DIR="$TEST_DIR/t2"
T2_PR="$T2_DIR/.claude-plans"
T2_HS="$T2_DIR/.claude/hooks/state"
mkdir -p "$T2_PR/71-foundations" "$T2_PR/80-stem" "$T2_HS"

for p in 71-foundations 80-stem; do
cat > "$T2_PR/$p/manifest.json" <<EOF
{"schema_version": 1,
 "live_mutation_scope": {"enabled": true,
   "layer_3": {"enabled": true, "expected_quiescence_period_seconds": 0,
     "session_end_hooks": [{"path": "/h/shared.sh", "pause_via": "sentinel", "sentinel_path": "$T2_HS/shared.lock"}]}}}
EOF
done

T2_REG="$T2_DIR/registry.json"
echo '{"schema_version": 1, "writers": [{"id": "shared.sh", "hook_path": "/h/shared.sh", "write_paths": ["/x/**"], "pause_mechanism": "sentinel"}]}' > "$T2_REG"

run_t2() {
  HOOKS_STATE_OVERRIDE="$T2_HS" PLANS_ROOT_OVERRIDE="$T2_PR" \
  L3_REGISTRY_PATH="$T2_REG" L3_QUIESCENCE_OVERRIDE=0 SKIP_LAUNCHCTL=1 \
  bash "$L3" "$@"
}

run_t2 pause 71-foundations --quiescence-skip > /dev/null
run_t2 pause 80-stem --quiescence-skip > /dev/null

sf2="$T2_HS/l3-pause-state/shared_sh.json"
owners=$(jq -r '.owners | join(",")' "$sf2")
assert "$owners" "71-foundations,80-stem" "T2 stack ordering [71, 80]"

run_t2 resume 80-stem > /dev/null
[[ -e "$T2_HS/shared.lock" ]] && assert "present" "present" "T2 sentinel persists after resume-80 (71 still owner)" \
  || assert "absent" "present" "T2 sentinel persists after resume-80"

owners=$(jq -r '.owners | join(",")' "$sf2")
assert "$owners" "71-foundations" "T2 owners=[71-foundations] after resume-80"

run_t2 resume 71-foundations > /dev/null
[[ ! -e "$T2_HS/shared.lock" ]] && assert "absent" "absent" "T2 sentinel removed after full release" \
  || assert "present" "absent" "T2 sentinel removed after full release"
[[ ! -e "$sf2" ]] && assert "absent" "absent" "T2 state file removed after full release" \
  || assert "present" "absent" "T2 state file removed after full release"

# === Test 3: atomic-rollback ==============================================
echo ""
echo "Test 3: atomic-rollback — partial-fail → revert applied + non-zero rc"
T3_DIR="$TEST_DIR/t3"
T3_PR="$T3_DIR/.claude-plans"
T3_HS="$T3_DIR/.claude/hooks/state"
mkdir -p "$T3_PR/plan-rb" "$T3_HS"

# Plan declares two sentinels: first applies cleanly to a writable path,
# second targets a path inside a NON-EXISTENT directory → touch fails.
cat > "$T3_PR/plan-rb/manifest.json" <<EOF
{"schema_version": 1,
 "live_mutation_scope": {"enabled": true,
   "layer_3": {"enabled": true, "expected_quiescence_period_seconds": 0,
     "session_end_hooks": [
       {"path": "/h/first.sh", "pause_via": "sentinel", "sentinel_path": "$T3_HS/first.lock"},
       {"path": "/h/second.sh", "pause_via": "sentinel", "sentinel_path": "$T3_DIR/missing-dir/second.lock"}
     ]}}}
EOF
T3_REG="$T3_DIR/registry.json"
cat > "$T3_REG" <<'EOF'
{"schema_version": 1, "writers": [
  {"id": "first.sh", "hook_path": "/h/first.sh", "write_paths": ["/x/**"], "pause_mechanism": "sentinel"},
  {"id": "second.sh", "hook_path": "/h/second.sh", "write_paths": ["/y/**"], "pause_mechanism": "sentinel"}
]}
EOF

run_t3() {
  HOOKS_STATE_OVERRIDE="$T3_HS" PLANS_ROOT_OVERRIDE="$T3_PR" \
  L3_REGISTRY_PATH="$T3_REG" L3_QUIESCENCE_OVERRIDE=0 SKIP_LAUNCHCTL=1 \
  bash "$L3" "$@"
}

set +e
run_t3 pause plan-rb --quiescence-skip 2>&1 > /dev/null
rc=$?
set -e
assert "$rc" "1" "T3 pause rc=1 on partial fail"

# First sentinel must have been REVERTED (created then removed during rollback)
[[ ! -e "$T3_HS/first.lock" ]] && assert "absent" "absent" "T3 first sentinel reverted" \
  || assert "present" "absent" "T3 first sentinel reverted"

# State files must NOT exist for either writer
[[ ! -e "$T3_HS/l3-pause-state/first_sh.json" ]] && assert "absent" "absent" "T3 first state file cleaned" \
  || assert "present" "absent" "T3 first state file cleaned"
[[ ! -e "$T3_HS/l3-pause-state/second_sh.json" ]] && assert "absent" "absent" "T3 second state file absent" \
  || assert "present" "absent" "T3 second state file absent"

# === Test 4: orphan-state detection =======================================
echo ""
echo "Test 4: orphan-state detection — closed plan's state persists; status surfaces it"
T4_DIR="$TEST_DIR/t4"
T4_PR="$T4_DIR/.claude-plans"
T4_HS="$T4_DIR/.claude/hooks/state"
mkdir -p "$T4_PR/plan-orphan" "$T4_HS"
cat > "$T4_PR/plan-orphan/manifest.json" <<EOF
{"schema_version": 1, "top_level_status": "in_progress",
 "live_mutation_scope": {"enabled": true,
   "layer_3": {"enabled": true, "expected_quiescence_period_seconds": 0,
     "session_end_hooks": [{"path": "/h/orph.sh", "pause_via": "sentinel", "sentinel_path": "$T4_HS/orph.lock"}]}}}
EOF
T4_REG="$T4_DIR/registry.json"
echo '{"schema_version": 1, "writers": [{"id": "orph.sh", "hook_path": "/h/orph.sh", "write_paths": ["/x/**"], "pause_mechanism": "sentinel"}]}' > "$T4_REG"

run_t4() {
  HOOKS_STATE_OVERRIDE="$T4_HS" PLANS_ROOT_OVERRIDE="$T4_PR" \
  L3_REGISTRY_PATH="$T4_REG" L3_QUIESCENCE_OVERRIDE=0 SKIP_LAUNCHCTL=1 \
  bash "$L3" "$@"
}

run_t4 pause plan-orphan --quiescence-skip > /dev/null

# Now flip the plan's manifest to closed (simulating retired plan)
jq '.top_level_status = "closed" | .live_mutation_scope.enabled = false' \
  "$T4_PR/plan-orphan/manifest.json" > "$T4_PR/plan-orphan/manifest.json.tmp" \
  && mv "$T4_PR/plan-orphan/manifest.json.tmp" "$T4_PR/plan-orphan/manifest.json"

# State file MUST still exist (no auto-resume)
[[ -e "$T4_HS/l3-pause-state/orph_sh.json" ]] && assert "present" "present" "T4 state file persists (no auto-resume)" \
  || assert "absent" "present" "T4 state file persists"

[[ -e "$T4_HS/orph.lock" ]] && assert "present" "present" "T4 sentinel persists" \
  || assert "absent" "present" "T4 sentinel persists"

# Status command surfaces the orphan owned by plan-orphan
status_out=$(run_t4 status plan-orphan)
[[ "$status_out" == *"plan-orphan"* ]] && assert "found" "found" "T4 status surfaces orphan" \
  || assert "missing" "found" "T4 status surfaces orphan"

# Explicit user action still resumes (proves no auto-resume but explicit works)
run_t4 resume plan-orphan > /dev/null
[[ ! -e "$T4_HS/orph.lock" ]] && assert "absent" "absent" "T4 explicit resume releases sentinel" \
  || assert "present" "absent" "T4 explicit resume releases sentinel"

# === Test 5: launchctl-rc-error surfacing =================================
echo ""
echo "Test 5: launchctl-rc-error — mock launchctl rc=1 → stderr + non-zero"
T5_DIR="$TEST_DIR/t5"
T5_PR="$T5_DIR/.claude-plans"
T5_HS="$T5_DIR/.claude/hooks/state"
mkdir -p "$T5_PR/plan-rc" "$T5_HS"
cat > "$T5_PR/plan-rc/manifest.json" <<EOF
{"schema_version": 1,
 "live_mutation_scope": {"enabled": true,
   "layer_3": {"enabled": true, "expected_quiescence_period_seconds": 0,
     "launchd_labels": ["com.test-rc-fail"]}}}
EOF
T5_REG="$T5_DIR/registry.json"
cat > "$T5_REG" <<'EOF'
{"schema_version": 1, "writers": [
  {"id": "com.test-rc-fail", "launchd_label": "com.test-rc-fail",
   "plist_path": "/nonexistent/com.test-rc-fail.plist",
   "write_paths": ["/x/**"], "pause_mechanism": "launchctl"}
]}
EOF

# Mock launchctl: list returns 0 (loaded); unload returns 1 with stderr message
T5_MOCK="$T5_DIR/launchctl-mock.sh"
cat > "$T5_MOCK" <<'EOF'
#!/bin/bash
# Mock launchctl: list reports loaded; both unload AND remove fail with rc=1.
case "$1" in
  list) exit 0 ;;
  unload|remove)
    echo "launchctl: failed to $1 ${2:-}" >&2
    exit 1 ;;
  load) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T5_MOCK"

set +e
out=$(HOOKS_STATE_OVERRIDE="$T5_HS" PLANS_ROOT_OVERRIDE="$T5_PR" \
  L3_REGISTRY_PATH="$T5_REG" L3_QUIESCENCE_OVERRIDE=0 \
  L3_LAUNCHCTL_BIN="$T5_MOCK" SKIP_LAUNCHCTL=0 \
  bash "$L3" pause plan-rc --quiescence-skip 2>&1)
rc=$?
set -e

assert "$rc" "1" "T5 pause rc=1 on launchctl unload failure"
[[ "$out" == *"unload failed"* ]] && assert "surfaced" "surfaced" "T5 unload error in stderr" \
  || assert "absent" "surfaced" "T5 unload error surfaced (got: $out)"

# === Test 6: Incident-β regression (live-guard nonce-consume) =============
echo ""
echo "Test 6: Incident-β regression — auto-memory write with no nonce affinity → DENY"
T6_DIR="$TEST_DIR/t6"
T6_PR="$T6_DIR/.claude-plans"
T6_HS="$T6_DIR/.claude/hooks/state"
T6_NONCE_DIR="$T6_HS/sp09-nonces"
T6_GIT_HOME="$T6_DIR/foundation-repo"
T6_SESSION="t6-session"
mkdir -p "$T6_PR/71-foundations" "$T6_HS/$T6_SESSION" "$T6_NONCE_DIR" "$T6_GIT_HOME"

# Set up a synthetic foundation-repo with an anchor tag for nonce sha resolution
git -C "$T6_GIT_HOME" init -q
echo "anchor-marker" > "$T6_GIT_HOME/anchor.txt"
git -C "$T6_GIT_HOME" add anchor.txt > /dev/null
git -C "$T6_GIT_HOME" -c user.email=t@t.com -c user.name=t commit -q -m "anchor commit"
git -C "$T6_GIT_HOME" tag t6-anchor
ANCHOR_SHA=$(git -C "$T6_GIT_HOME" rev-parse t6-anchor)

# Plan-71-like manifest: tier-2 detection via active-plans.txt; basename-match-env
cat > "$T6_PR/71-foundations/manifest.json" <<EOF
{
  "schema_version": 1,
  "live_mutation_scope": {
    "enabled": true,
    "scope_paths": ["\$HOME/.claude/**"],
    "exempt_paths": [],
    "detection_signals": {
      "plan_id_pattern": "^71($|-)",
      "deterministic_only": true
    },
    "override": {
      "nonce_dir": "$T6_NONCE_DIR",
      "nonce_sha_anchor": "t6-anchor",
      "nonce_consume_strategy": "basename_match_env",
      "nonce_affinity_env": "PLAN_71_NONCE_TASK",
      "nonce_min_reason_length": 12
    },
    "enforcement": {"match_action": "deny"}
  }
}
EOF

# Plant a task-bound nonce file (T-13-postmortem) — represents the SP09 case
NONCE_FILE="$T6_NONCE_DIR/T-13-postmortem.nonce"
printf 'T-13\tInvestigating Incident β postmortem\t%s' "$ANCHOR_SHA" > "$NONCE_FILE"

# Set up tier-2 active-plans.txt for deterministic detection
echo "71-foundations" > "$T6_HS/$T6_SESSION/active-plans.txt"

# Auto-memory tool call: FILE_PATH under scope, NO PLAN_71_NONCE_TASK env set
# (this is the SP09 Session 17 case: UserPromptSubmit auto-memory edit on
# MEMORY.md without a task affinity).
target_file="$HOME/.claude/projects/-Users-test/memory/MEMORY.md"

set +e
out=$(FILE_PATH="$target_file" \
      TOOL_NAME="Edit" \
      HOOKS_STATE_OVERRIDE="$T6_HS" \
      PLANS_ROOT_OVERRIDE="$T6_PR" \
      CLAUDE_HOME="$T6_GIT_HOME" \
      CLAUDE_SESSION_ID="$T6_SESSION" \
      bash "$LG" 2>&1)
lg_rc=$?
set -e

# Decision MUST be deny (live-guard outputs hookSpecificOutput JSON to stdout).
permission=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
assert "$permission" "deny" "T6 decision=deny (no nonce affinity = no consumption)"

# Critical assertion: the nonce file MUST STILL be on disk (not consumed).
[[ -e "$NONCE_FILE" ]] && assert "present" "present" "T6 nonce file NOT consumed (Incident-β class blocked)" \
  || assert "absent" "present" "T6 nonce file NOT consumed"

# Audit log entry should record deny, NOT allow-override (no nonce_task field)
DEC_LOG="$T6_HS/gate-decisions.log"
if [[ -r "$DEC_LOG" ]]; then
  last_decision=$(tail -1 "$DEC_LOG" | jq -r '.decision // empty')
  assert "$last_decision" "deny" "T6 audit log last decision=deny"
fi

# Positive control: WITH affinity env set correctly → nonce IS consumed
PLAN_71_NONCE_TASK="T-13-postmortem" \
  FILE_PATH="$target_file" TOOL_NAME="Edit" \
  HOOKS_STATE_OVERRIDE="$T6_HS" PLANS_ROOT_OVERRIDE="$T6_PR" \
  CLAUDE_HOME="$T6_GIT_HOME" CLAUDE_SESSION_ID="$T6_SESSION" \
  bash "$LG" >/dev/null 2>&1

[[ ! -e "$NONCE_FILE" ]] && assert "absent" "absent" "T6 positive control: with affinity, nonce IS consumed" \
  || assert "present" "absent" "T6 positive control: with affinity, nonce IS consumed"

# === Summary ==============================================================
echo ""
echo "Tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
echo "All T-17 L3 6-test suite assertions PASSED."
echo "A4 anti-success criterion structurally closed: L3 partial-pause state"
echo "+ Incident-β class regression formally testable from this fixture."
exit 0
