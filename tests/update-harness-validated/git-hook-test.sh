#!/bin/bash
# git-hook-test.sh — exercises pre-commit + post-commit T-27 hooks
# (Plan 80/81 SP01 T-27 R-46-cousin gate behavior)
#
# Tests the hook bodies directly via test-isolation env, avoiding any
# real git repo mutation. Per feedback_test_isolation_for_hooks_state.

set -uo pipefail

PRE_HOOK="$HOME/Code/claude-stem/git-hooks/pre-commit-harness-validated.sh"
POST_HOOK="$HOME/Code/claude-stem/git-hooks/post-commit-harness-invalidate.sh"
CAP="$HOME/Code/claude-stem/skills/librarian/capabilities/update-harness-validated.sh"

PASS=0
FAIL=0

assert() {
  local name="$1" rc_actual="$2" rc_expected="$3" extra="${4:-}"
  if [[ "$rc_actual" -eq "$rc_expected" ]]; then
    echo "PASS: $name${extra:+ ($extra)}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name expected rc=$rc_expected got rc=$rc_actual${extra:+ ($extra)}"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name expected='$expected' actual='$actual'"
    FAIL=$((FAIL + 1))
  fi
}

TEST_DIR=$(mktemp -d -t t27-hook-XXXXXX)
trap "rm -rf '$TEST_DIR'" EXIT

# Each scenario sets up its own diff-override fixture
mkdir -p "$TEST_DIR/diff-fixtures" "$TEST_DIR/hooks-state" "$TEST_DIR/plans"
mkdir -p "$TEST_DIR/fakerepo"
git -C "$TEST_DIR/fakerepo" init -q
git -C "$TEST_DIR/fakerepo" -c user.email=test@test -c user.name=test commit --allow-empty -q -m bootstrap

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SHA=$(git -C "$TEST_DIR/fakerepo" rev-parse HEAD)

# --- Helper: create before/after manifest pair ---
create_manifest_pair() {
  local name="$1" before_status="$2" after_status="$3" \
        sub_plan_id="$4" hv_entries="$5"
  cat > "$TEST_DIR/diff-fixtures/${name}.before.json" <<JSON
{
  "schema_version": 1,
  "project": "$name",
  "spec_path": "/dev/null",
  "type": "sub-plan",
  "parent_plan": "test",
  "sub_plan_id": "$sub_plan_id",
  "top_level_status": "$before_status",
  "harness_validated": $hv_entries
}
JSON
  cat > "$TEST_DIR/diff-fixtures/${name}.after.json" <<JSON
{
  "schema_version": 1,
  "project": "$name",
  "spec_path": "/dev/null",
  "type": "sub-plan",
  "parent_plan": "test",
  "sub_plan_id": "$sub_plan_id",
  "top_level_status": "$after_status",
  "harness_validated": $hv_entries
}
JSON
}

# Helper: run pre-hook with controlled fixtures
run_pre_hook() {
  local manifest_path="$1"
  PRE_COMMIT_STAGED_OVERRIDE="$manifest_path" \
  PRE_COMMIT_DIFF_OVERRIDE="$TEST_DIR/diff-fixtures" \
  HOOKS_STATE_OVERRIDE="$TEST_DIR/hooks-state" \
  FOUNDATION_REPO_OVERRIDE="$TEST_DIR/fakerepo" \
  FOUNDATION_SHA_OVERRIDE="$SHA" \
  UPDATE_HARNESS_CAP="$CAP" \
  bash "$PRE_HOOK"
}

# === Scenario 1: pre-commit — flip with fresh+pass entry → ALLOW ========
HV='[{
  "harness_id": "test-h",
  "sub_plan_id": "01-test",
  "run_id": "r1",
  "sha": "'$SHA'",
  "timestamp": "'$NOW'",
  "verdict": "pass",
  "tier": "tier-1",
  "evidence_path": "x",
  "harness_freshness": "fresh",
  "schema_version": 1
}]'

create_manifest_pair "scenario1-manifest" "in_progress" "complete" "01-test" "$HV"
run_pre_hook "scenario1-manifest.json" >/dev/null 2>&1
assert "scenario_1_flip_with_fresh_pass_allows" $? 0

# === Scenario 2: flip with NO harness_validated[] → REJECT ==============
create_manifest_pair "scenario2-manifest" "in_progress" "complete" "02-test" "[]"
run_pre_hook "scenario2-manifest.json" >/dev/null 2>&1
assert "scenario_2_flip_with_no_validated_rejects" $? 1

# === Scenario 3: flip with stale (sha mismatch) entry → REJECT ==========
HV_STALE_SHA='[{
  "harness_id": "test-h",
  "sub_plan_id": "03-test",
  "run_id": "r1",
  "sha": "deadbeef",
  "timestamp": "'$NOW'",
  "verdict": "pass",
  "tier": "tier-1",
  "evidence_path": "x",
  "harness_freshness": "fresh",
  "schema_version": 1
}]'
create_manifest_pair "scenario3-manifest" "in_progress" "complete" "03-test" "$HV_STALE_SHA"
run_pre_hook "scenario3-manifest.json" >/dev/null 2>&1
assert "scenario_3_flip_with_stale_sha_rejects" $? 1

# === Scenario 4: flip with FAIL verdict → REJECT ========================
HV_FAIL='[{
  "harness_id": "test-h",
  "sub_plan_id": "04-test",
  "run_id": "r1",
  "sha": "'$SHA'",
  "timestamp": "'$NOW'",
  "verdict": "fail",
  "tier": "tier-1",
  "evidence_path": "x",
  "harness_freshness": "fresh",
  "schema_version": 1
}]'
create_manifest_pair "scenario4-manifest" "in_progress" "complete" "04-test" "$HV_FAIL"
run_pre_hook "scenario4-manifest.json" >/dev/null 2>&1
assert "scenario_4_flip_with_fail_verdict_rejects" $? 1

# === Scenario 5: NO flip (status unchanged) → ALLOW =====================
HV_EMPTY="[]"
create_manifest_pair "scenario5-manifest" "in_progress" "in_progress" "05-test" "$HV_EMPTY"
run_pre_hook "scenario5-manifest.json" >/dev/null 2>&1
assert "scenario_5_no_flip_allows" $? 0

# === Scenario 6: flip away from complete (regression) → ALLOW ===========
create_manifest_pair "scenario6-manifest" "complete" "in_progress" "06-test" "$HV_EMPTY"
run_pre_hook "scenario6-manifest.json" >/dev/null 2>&1
assert "scenario_6_flip_away_from_complete_allows" $? 0

# === Scenario 7: sentinel override fires → ALLOW ========================
SENTINEL_REPO="$TEST_DIR/sentinel-repo"
mkdir -p "$SENTINEL_REPO"
git -C "$SENTINEL_REPO" init -q
git -C "$SENTINEL_REPO" -c user.email=t@t -c user.name=t commit --allow-empty -q -m boot
touch "$SENTINEL_REPO/.allow-harness-validation-skip"

# Create a flip+empty-validated case that WOULD reject without sentinel
create_manifest_pair "scenario7-manifest" "in_progress" "complete" "07-test" "[]"
(
  cd "$SENTINEL_REPO"
  PRE_COMMIT_STAGED_OVERRIDE="scenario7-manifest.json" \
  PRE_COMMIT_DIFF_OVERRIDE="$TEST_DIR/diff-fixtures" \
  HOOKS_STATE_OVERRIDE="$TEST_DIR/hooks-state" \
  FOUNDATION_REPO_OVERRIDE="$TEST_DIR/fakerepo" \
  FOUNDATION_SHA_OVERRIDE="$SHA" \
  UPDATE_HARNESS_CAP="$CAP" \
  bash "$PRE_HOOK" >/dev/null 2>&1
)
assert "scenario_7_sentinel_override_allows" $? 0

# === Scenario 8: flip with invalidated entry → REJECT ===================
HV_INV='[{
  "harness_id": "test-h",
  "sub_plan_id": "08-test",
  "run_id": "r1",
  "sha": "'$SHA'",
  "timestamp": "'$NOW'",
  "verdict": "pass",
  "tier": "tier-1",
  "evidence_path": "x",
  "harness_freshness": "invalidated",
  "schema_version": 1
}]'
create_manifest_pair "scenario8-manifest" "in_progress" "complete" "08-test" "$HV_INV"
run_pre_hook "scenario8-manifest.json" >/dev/null 2>&1
assert "scenario_8_flip_with_invalidated_rejects" $? 1

# === Scenario 9: post-commit — scope intersection → invalidates =========
# Setup: plan-tree manifest with harness_validated entries + scope_paths
PLAN_DIR="$TEST_DIR/plans/sp-test"
mkdir -p "$PLAN_DIR"
cat > "$PLAN_DIR/manifest.json" <<JSON
{
  "schema_version": 1,
  "project": "Test sub-plan",
  "spec_path": "/dev/null",
  "type": "sub-plan",
  "parent_plan": "parent",
  "sub_plan_id": "01-test",
  "live_mutation_scope": {
    "enabled": true,
    "schema_version": 1,
    "scope_paths": ["\$HOME/Code/claude-stem/skills/librarian/**"]
  },
  "harness_validated": [
    {
      "harness_id": "h",
      "sub_plan_id": "01-test",
      "run_id": "r",
      "sha": "$SHA",
      "timestamp": "$NOW",
      "verdict": "pass",
      "tier": "tier-1",
      "evidence_path": "x",
      "harness_freshness": "fresh",
      "schema_version": 1
    }
  ]
}
JSON

# Run post-commit hook with a committed path that intersects scope_paths
COMMITTED_PATHS="$HOME/Code/claude-stem/skills/librarian/capabilities/foo.sh"
PLANS_ROOT_OVERRIDE="$TEST_DIR/plans" \
HOOKS_STATE_OVERRIDE="$TEST_DIR/hooks-state" \
FOUNDATION_REPO_OVERRIDE="$TEST_DIR/fakerepo" \
POST_COMMIT_DIFF_OVERRIDE="$COMMITTED_PATHS" \
UPDATE_HARNESS_CAP="$CAP" \
bash "$POST_HOOK" >/dev/null 2>&1
assert "scenario_9_post_commit_intersection_rc_zero" $? 0

INV_FRESH=$(jq -r '.harness_validated[0].harness_freshness' "$PLAN_DIR/manifest.json")
assert_eq "scenario_9_entry_invalidated" "$INV_FRESH" "invalidated"

# === Scenario 10: post-commit — no intersection → no invalidation =======
# Reset to fresh
jq '.harness_validated[0].harness_freshness = "fresh"' "$PLAN_DIR/manifest.json" > "$PLAN_DIR/manifest.tmp" \
  && mv "$PLAN_DIR/manifest.tmp" "$PLAN_DIR/manifest.json"

NON_INTERSECT="$HOME/Code/claude-stem/elsewhere/foo.sh"
PLANS_ROOT_OVERRIDE="$TEST_DIR/plans" \
HOOKS_STATE_OVERRIDE="$TEST_DIR/hooks-state" \
FOUNDATION_REPO_OVERRIDE="$TEST_DIR/fakerepo" \
POST_COMMIT_DIFF_OVERRIDE="$NON_INTERSECT" \
UPDATE_HARNESS_CAP="$CAP" \
bash "$POST_HOOK" >/dev/null 2>&1
assert "scenario_10_no_intersection_rc_zero" $? 0

INV_FRESH=$(jq -r '.harness_validated[0].harness_freshness' "$PLAN_DIR/manifest.json")
assert_eq "scenario_10_entry_remains_fresh" "$INV_FRESH" "fresh"

# === Scenario 11: pre-commit handles missing manifest gracefully ========
PRE_COMMIT_STAGED_OVERRIDE="nonexistent.json" \
PRE_COMMIT_DIFF_OVERRIDE="$TEST_DIR/diff-fixtures" \
HOOKS_STATE_OVERRIDE="$TEST_DIR/hooks-state" \
FOUNDATION_REPO_OVERRIDE="$TEST_DIR/fakerepo" \
FOUNDATION_SHA_OVERRIDE="$SHA" \
UPDATE_HARNESS_CAP="$CAP" \
bash "$PRE_HOOK" >/dev/null 2>&1
assert "scenario_11_missing_manifest_passthrough" $? 0

# === Scenario 12: pre-commit — non-manifest staged paths → noop ========
PRE_COMMIT_STAGED_OVERRIDE="some-other-file.sh
README.md" \
PRE_COMMIT_DIFF_OVERRIDE="$TEST_DIR/diff-fixtures" \
HOOKS_STATE_OVERRIDE="$TEST_DIR/hooks-state" \
FOUNDATION_REPO_OVERRIDE="$TEST_DIR/fakerepo" \
FOUNDATION_SHA_OVERRIDE="$SHA" \
UPDATE_HARNESS_CAP="$CAP" \
bash "$PRE_HOOK" >/dev/null 2>&1
assert "scenario_12_non_manifest_staged_noop" $? 0

# === Scenario 13: audit log written ====================================
LOG="$TEST_DIR/hooks-state/gate-decisions.log"
LOG_ROWS=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
if [[ -z "$LOG_ROWS" || "$LOG_ROWS" -lt 5 ]]; then
  echo "FAIL: scenario_13_audit_log_written (expected ≥5 rows; got ${LOG_ROWS:-0})"
  FAIL=$((FAIL + 1))
else
  echo "PASS: scenario_13_audit_log_written ($LOG_ROWS rows)"
  PASS=$((PASS + 1))
fi

# === Scenario 14: audit log entries are well-formed JSON ===============
INVALID_JSON_LINES=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  if ! jq empty <<< "$line" 2>/dev/null; then
    INVALID_JSON_LINES=$((INVALID_JSON_LINES + 1))
  fi
done < "$LOG"
if [[ "$INVALID_JSON_LINES" -eq 0 ]]; then
  echo "PASS: scenario_14_audit_log_well_formed_json"
  PASS=$((PASS + 1))
else
  echo "FAIL: scenario_14_audit_log_well_formed_json ($INVALID_JSON_LINES bad rows)"
  FAIL=$((FAIL + 1))
fi

# === Summary ===========================================================
TOTAL=$((PASS + FAIL))
echo ""
echo "==== T-27 git-hook test summary ===="
echo "PASS: $PASS / $TOTAL"
echo "FAIL: $FAIL / $TOTAL"
exit $((FAIL > 0 ? 1 : 0))
