#!/bin/bash
# capability-test.sh — exercises update-harness-validated.sh subcommands
# (Plan 80/81 SP01 T-27 capability tier-1 coverage)
#
# Test isolation contract per feedback_test_isolation_for_hooks_state:
# every fixture stays under $TEST_DIR; no real ~/.claude-plans writes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP="${CAP_OVERRIDE:-$HOME/Code/claude-stem/skills/librarian/capabilities/update-harness-validated.sh}"

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
    echo "FAIL: $name"
    echo "       expected: $expected"
    echo "       actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

TEST_DIR=$(mktemp -d -t t27-cap-XXXXXX)
trap "rm -rf '$TEST_DIR'" EXIT

# Setup: synthetic manifest with no harness_validated[]
MANIFEST="$TEST_DIR/manifest.json"
cat > "$MANIFEST" <<'JSON'
{
  "schema_version": 1,
  "project": "Test sub-plan",
  "spec_path": "/dev/null",
  "type": "sub-plan",
  "parent_plan": "test-parent",
  "sub_plan_id": "test-sp",
  "top_level_status": "in_progress"
}
JSON

# === Scenario 1: add — first entry creates the array ====================
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ENTRY1='{
  "harness_id": "manifest_mechanism_extensibility",
  "sub_plan_id": "01-manifest-generalization",
  "run_id": "run-001",
  "sha": "abc1234",
  "timestamp": "'$NOW'",
  "verdict": "pass",
  "tier": "tier-1",
  "evidence_path": "dogfood-history/run-001/",
  "harness_freshness": "fresh",
  "schema_version": 1
}'

"$CAP" add "$MANIFEST" "$ENTRY1" >/dev/null 2>&1
assert "scenario_1_add_first_entry" $? 0

COUNT=$(jq '.harness_validated | length' "$MANIFEST")
assert_eq "scenario_1_array_length_1" "$COUNT" "1"

# === Scenario 2: add — appends to existing array =======================
ENTRY2='{
  "harness_id": "live_guard_root_resolution_determinism",
  "sub_plan_id": "01-manifest-generalization",
  "run_id": "run-002",
  "sha": "abc1234",
  "timestamp": "'$NOW'",
  "verdict": "pass",
  "tier": "tier-1",
  "evidence_path": "dogfood-history/run-002/",
  "harness_freshness": "fresh",
  "schema_version": 1
}'

"$CAP" add "$MANIFEST" "$ENTRY2" >/dev/null 2>&1
assert "scenario_2_add_appends" $? 0

COUNT=$(jq '.harness_validated | length' "$MANIFEST")
assert_eq "scenario_2_array_length_2" "$COUNT" "2"

# === Scenario 3: add — invalid verdict rejected ========================
BAD_ENTRY='{
  "harness_id": "x",
  "sub_plan_id": "01",
  "run_id": "run-003",
  "sha": "abc1234",
  "timestamp": "'$NOW'",
  "verdict": "INVALID",
  "tier": "tier-1",
  "evidence_path": "x",
  "harness_freshness": "fresh",
  "schema_version": 1
}'

"$CAP" add "$MANIFEST" "$BAD_ENTRY" >/dev/null 2>&1
assert "scenario_3_invalid_verdict_rejected" $? 2

COUNT=$(jq '.harness_validated | length' "$MANIFEST")
assert_eq "scenario_3_array_unchanged" "$COUNT" "2"

# === Scenario 4: add — missing required field rejected =================
MISSING_FIELD='{
  "harness_id": "x",
  "sub_plan_id": "01",
  "run_id": "run-004",
  "verdict": "pass",
  "tier": "tier-1",
  "evidence_path": "x",
  "harness_freshness": "fresh",
  "schema_version": 1
}'

"$CAP" add "$MANIFEST" "$MISSING_FIELD" >/dev/null 2>&1
assert "scenario_4_missing_fields_rejected" $? 2

# === Scenario 5: add — invalid SHA rejected ============================
BAD_SHA='{
  "harness_id": "x",
  "sub_plan_id": "01",
  "run_id": "run-005",
  "sha": "NOT-A-SHA",
  "timestamp": "'$NOW'",
  "verdict": "pass",
  "tier": "tier-1",
  "evidence_path": "x",
  "harness_freshness": "fresh",
  "schema_version": 1
}'

"$CAP" add "$MANIFEST" "$BAD_SHA" >/dev/null 2>&1
assert "scenario_5_invalid_sha_rejected" $? 2

# === Scenario 6: list returns the array ================================
LIST_OUT=$("$CAP" list "$MANIFEST" 2>/dev/null)
LIST_LEN=$(jq 'length' <<< "$LIST_OUT")
assert_eq "scenario_6_list_length_2" "$LIST_LEN" "2"

# === Scenario 7: freshness-check — match found =========================
"$CAP" freshness-check "$MANIFEST" "01-manifest-generalization" \
  --foundation-sha "abc1234" --max-age-days 7 >/dev/null 2>&1
assert "scenario_7_freshness_check_match" $? 0

# === Scenario 8: freshness-check — sha mismatch ========================
"$CAP" freshness-check "$MANIFEST" "01-manifest-generalization" \
  --foundation-sha "deadbee" --max-age-days 7 >/dev/null 2>&1
assert "scenario_8_freshness_check_sha_mismatch" $? 1

# === Scenario 9: freshness-check — sub_plan_id mismatch ================
"$CAP" freshness-check "$MANIFEST" "99-nonexistent" \
  --foundation-sha "abc1234" --max-age-days 7 >/dev/null 2>&1
assert "scenario_9_freshness_check_sp_mismatch" $? 1

# === Scenario 10: freshness-check — too-old timestamp ==================
OLD_MANIFEST="$TEST_DIR/manifest-old.json"
cat > "$OLD_MANIFEST" <<JSON
{
  "schema_version": 1,
  "project": "Old test",
  "spec_path": "/dev/null",
  "type": "sub-plan",
  "parent_plan": "test",
  "sub_plan_id": "test-sp",
  "harness_validated": [
    {
      "harness_id": "x",
      "sub_plan_id": "01-manifest-generalization",
      "run_id": "run-old",
      "sha": "abc1234",
      "timestamp": "2026-01-01T00:00:00Z",
      "verdict": "pass",
      "tier": "tier-1",
      "evidence_path": "x",
      "harness_freshness": "fresh",
      "schema_version": 1
    }
  ]
}
JSON

"$CAP" freshness-check "$OLD_MANIFEST" "01-manifest-generalization" \
  --foundation-sha "abc1234" --max-age-days 7 >/dev/null 2>&1
assert "scenario_10_freshness_check_too_old" $? 1

# === Scenario 11: freshness-check — invalidated entry rejected =========
INV_MANIFEST="$TEST_DIR/manifest-inv.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$INV_MANIFEST" <<JSON
{
  "schema_version": 1,
  "project": "Inv test",
  "spec_path": "/dev/null",
  "type": "sub-plan",
  "parent_plan": "test",
  "sub_plan_id": "test-sp",
  "harness_validated": [
    {
      "harness_id": "x",
      "sub_plan_id": "01-manifest-generalization",
      "run_id": "run-inv",
      "sha": "abc1234",
      "timestamp": "$NOW",
      "verdict": "pass",
      "tier": "tier-1",
      "evidence_path": "x",
      "harness_freshness": "invalidated",
      "schema_version": 1
    }
  ]
}
JSON

"$CAP" freshness-check "$INV_MANIFEST" "01-manifest-generalization" \
  --foundation-sha "abc1234" --max-age-days 7 >/dev/null 2>&1
assert "scenario_11_freshness_check_invalidated_rejected" $? 1

# === Scenario 12: invalidate — marks all matching =====================
"$CAP" invalidate "$MANIFEST" "01-manifest-generalization" >/dev/null 2>&1
assert "scenario_12_invalidate_rc_zero" $? 0

INV_COUNT=$(jq '[.harness_validated[] | select(.harness_freshness == "invalidated")] | length' "$MANIFEST")
assert_eq "scenario_12_both_entries_invalidated" "$INV_COUNT" "2"

# After invalidate, freshness-check now fails
"$CAP" freshness-check "$MANIFEST" "01-manifest-generalization" \
  --foundation-sha "abc1234" --max-age-days 7 >/dev/null 2>&1
assert "scenario_12_post_invalidate_freshness_fails" $? 1

# === Scenario 13: query — emits JSONL ==================================
QUERY_ROOT="$TEST_DIR/query-root"
mkdir -p "$QUERY_ROOT/plan-A" "$QUERY_ROOT/plan-B"
cp "$MANIFEST" "$QUERY_ROOT/plan-A/manifest.json"
cp "$OLD_MANIFEST" "$QUERY_ROOT/plan-B/manifest.json"

QUERY_OUT=$("$CAP" query "$QUERY_ROOT" 2>/dev/null)
QUERY_LINES=$(echo "$QUERY_OUT" | grep -c '_manifest_path')
assert_eq "scenario_13_query_3_entries" "$QUERY_LINES" "3"

# Each row has computed_freshness band
COMPUTED_BANDS=$(echo "$QUERY_OUT" | jq -r '._computed_freshness' | sort -u)
echo "  query computed bands: $(echo $COMPUTED_BANDS | tr '\n' ',')"

# === Summary ===========================================================
TOTAL=$((PASS + FAIL))
echo ""
echo "==== T-27 capability test summary ===="
echo "PASS: $PASS / $TOTAL"
echo "FAIL: $FAIL / $TOTAL"
exit $((FAIL > 0 ? 1 : 0))
