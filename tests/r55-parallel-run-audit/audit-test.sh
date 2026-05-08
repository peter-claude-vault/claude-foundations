#!/bin/bash
# audit-test.sh — T-9 acceptance fixture (Plan 80/81 SP01).
#
# Validates r55-parallel-run-audit.sh behavior against synthetic
# parallel-run.log data (Phase A bootstrap not yet deployed; fixture provides
# the divergence log). Tests:
#   1. summary on missing log: log_present=false, all counts=0
#   2. summary on present log: counts derived correctly
#   3. list emits divergences only (skips matching decisions)
#   4. list --undisposed-only filters out disposed rows
#   5. dispose records new disposition row in JSONL
#   6. invalid disposition rejected
#   7. phase-advance-check: BLOCKED when undisposed > 0
#   8. phase-advance-check: BLOCKED when bug-new > 0
#   9. phase-advance-check: PASS when all expected/bug-old, zero bug-new
#  10. iteration-count: <3 returns count, exits 0
#  11. iteration-count: ≥3 returns count, exits 2 (cap reached)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$REPO_ROOT/skills/librarian/capabilities/r55-parallel-run-audit.sh"
[[ -x "$H" ]] || { echo "FAIL: $H not executable"; exit 1; }

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

run() {
  PARALLEL_RUN_LOG="$LOG" \
  PARALLEL_RUN_DISPS="$DISPS" \
  bash "$H" "$@"
}

# === Synthetic log fixture ================================================
# 8 decisions: 3 matching (no divergence), 5 diverged.
# Of the 5 diverged: 2 expected, 1 bug-old, 1 bug-new (pre-disposed); 1 undisposed.
LOG="$TEST_DIR/parallel-run.log"
DISPS="$TEST_DIR/parallel-run-dispositions.jsonl"

cat > "$LOG" << 'EOF'
{"ts":"2026-05-15T00:00:00Z","run_id":"r001","plan_id":"71-cf","signal":"cwd","tool":"Edit","file":"/h/.claude/x.sh","old_decision":"deny","new_decision":"deny","diverged":false,"schema_version":1}
{"ts":"2026-05-15T00:00:01Z","run_id":"r002","plan_id":"71-cf","signal":"cwd","tool":"Write","file":"/h/.claude/y.sh","old_decision":"allow","new_decision":"allow","diverged":false,"schema_version":1}
{"ts":"2026-05-15T00:00:02Z","run_id":"r003","plan_id":"71-cf","signal":"transcript","tool":"Edit","file":"/h/.claude/projects/p1/m.md","old_decision":"deny","new_decision":"allow","diverged":true,"schema_version":1}
{"ts":"2026-05-15T00:00:03Z","run_id":"r004","plan_id":"71-cf","signal":"cwd","tool":"Edit","file":"/h/.claude/hooks/state/checkpoint.md","old_decision":"deny","new_decision":"allow","diverged":true,"schema_version":1}
{"ts":"2026-05-15T00:00:04Z","run_id":"r005","plan_id":"71-cf","signal":"cwd","tool":"Edit","file":"/h/.claude/foo.sh","old_decision":"allow","new_decision":"deny","diverged":true,"schema_version":1}
{"ts":"2026-05-15T00:00:05Z","run_id":"r006","plan_id":"71-cf","signal":"cwd","tool":"Edit","file":"/h/.claude/bar.sh","old_decision":"deny","new_decision":"allow","diverged":true,"schema_version":1}
{"ts":"2026-05-15T00:00:06Z","run_id":"r007","plan_id":"71-cf","signal":"transcript","tool":"Write","file":"/h/.claude/baz","old_decision":"allow","new_decision":"deny","diverged":true,"schema_version":1}
{"ts":"2026-05-15T00:00:07Z","run_id":"r008","plan_id":"71-cf","signal":"cwd","tool":"Read","file":"/h/.claude/q","old_decision":"allow","new_decision":"allow","diverged":false,"schema_version":1}
EOF

# Pre-dispose 4 of 5 divergences (leave r007 undisposed)
cat > "$DISPS" << 'EOF'
{"ts":"2026-05-15T01:00:00Z","run_id":"r003","disposition":"expected","note":"projects carve-out by design","schema_version":1}
{"ts":"2026-05-15T01:00:01Z","run_id":"r004","disposition":"expected","note":"checkpoint exempt_paths SP07 OQ-H","schema_version":1}
{"ts":"2026-05-15T01:00:02Z","run_id":"r005","disposition":"bug-old","note":"old missed scope","schema_version":1}
{"ts":"2026-05-15T01:00:03Z","run_id":"r006","disposition":"bug-new","note":"new helper false-allow","schema_version":1}
EOF

# === Test 1: summary on missing log =======================================
echo "Test 1: summary on missing log → log_present=false"
LOG="$TEST_DIR/missing.log" run summary > "$TEST_DIR/sum-missing.json"
assert "$(jq -r '.log_present' "$TEST_DIR/sum-missing.json")" "false" "T1 log_present=false"
assert "$(jq -r '.total_decisions' "$TEST_DIR/sum-missing.json")" "0" "T1 total_decisions=0"

# === Test 2: summary on present log =======================================
echo ""
echo "Test 2: summary on present log → counts derived"
run summary > "$TEST_DIR/sum-present.json"
assert "$(jq -r '.log_present' "$TEST_DIR/sum-present.json")" "true" "T2 log_present=true"
assert "$(jq -r '.total_decisions' "$TEST_DIR/sum-present.json")" "8" "T2 total_decisions=8"
assert "$(jq -r '.total_divergences' "$TEST_DIR/sum-present.json")" "5" "T2 total_divergences=5"
assert "$(jq -r '.dispositions.expected' "$TEST_DIR/sum-present.json")" "2" "T2 expected=2"
assert "$(jq -r '.dispositions."bug-old"' "$TEST_DIR/sum-present.json")" "1" "T2 bug-old=1"
assert "$(jq -r '.dispositions."bug-new"' "$TEST_DIR/sum-present.json")" "1" "T2 bug-new=1"
assert "$(jq -r '.dispositions.undisposed' "$TEST_DIR/sum-present.json")" "1" "T2 undisposed=1"

# === Test 3: list emits divergences only ==================================
echo ""
echo "Test 3: list emits divergences only"
list_count=$(run list | grep -c .)
assert "$list_count" "5" "T3 list emits 5 divergence rows"

# === Test 4: list --undisposed-only =======================================
echo ""
echo "Test 4: list --undisposed-only filters disposed rows"
ud_count=$(run list --undisposed-only | grep -c .)
assert "$ud_count" "1" "T4 list --undisposed-only emits 1 row"
ud_run_id=$(run list --undisposed-only | jq -r '.run_id' | head -1)
assert "$ud_run_id" "r007" "T4 undisposed run_id is r007"

# === Test 5: dispose records new disposition ==============================
echo ""
echo "Test 5: dispose records new disposition row"
disps_before=$(wc -l < "$DISPS" | tr -d ' ')
run dispose r007 expected "transcript-mode allowed-by-design under deterministic_only flag" > /dev/null
disps_after=$(wc -l < "$DISPS" | tr -d ' ')
assert "$((disps_after - disps_before))" "1" "T5 disposition row appended"
last=$(tail -1 "$DISPS" | jq -r '.run_id + "|" + .disposition')
assert "$last" "r007|expected" "T5 last row run_id=r007 disposition=expected"

# === Test 6: invalid disposition rejected =================================
echo ""
echo "Test 6: invalid disposition rejected (rc != 0)"
run dispose r999 invalid-tag "some note" 2>/dev/null && rc=0 || rc=$?
assert "$rc" "2" "T6 invalid disposition exit=2"

# === Test 7: phase-advance-check BLOCKED on undisposed ====================
echo ""
echo "Test 7: phase-advance-check BLOCKED on undisposed"
# Reset dispositions to recreate undisposed state
cat > "$DISPS" << 'EOF'
{"ts":"x","run_id":"r003","disposition":"expected","note":"","schema_version":1}
{"ts":"x","run_id":"r004","disposition":"expected","note":"","schema_version":1}
{"ts":"x","run_id":"r005","disposition":"bug-old","note":"","schema_version":1}
{"ts":"x","run_id":"r006","disposition":"bug-old","note":"","schema_version":1}
EOF
# r007 still undisposed
run phase-advance-check 2>/dev/null && rc=0 || rc=$?
assert "$rc" "1" "T7 phase-advance-check rc=1 (undisposed=1)"

# === Test 8: phase-advance-check BLOCKED on bug-new =======================
echo ""
echo "Test 8: phase-advance-check BLOCKED on bug-new"
cat > "$DISPS" << 'EOF'
{"ts":"x","run_id":"r003","disposition":"expected","note":"","schema_version":1}
{"ts":"x","run_id":"r004","disposition":"expected","note":"","schema_version":1}
{"ts":"x","run_id":"r005","disposition":"bug-old","note":"","schema_version":1}
{"ts":"x","run_id":"r006","disposition":"bug-old","note":"","schema_version":1}
{"ts":"x","run_id":"r007","disposition":"bug-new","note":"","schema_version":1}
EOF
run phase-advance-check 2>/dev/null && rc=0 || rc=$?
assert "$rc" "1" "T8 phase-advance-check rc=1 (bug-new=1)"

# === Test 9: phase-advance-check PASS =====================================
echo ""
echo "Test 9: phase-advance-check PASS when all expected/bug-old, zero bug-new"
cat > "$DISPS" << 'EOF'
{"ts":"x","run_id":"r003","disposition":"expected","note":"","schema_version":1}
{"ts":"x","run_id":"r004","disposition":"expected","note":"","schema_version":1}
{"ts":"x","run_id":"r005","disposition":"bug-old","note":"","schema_version":1}
{"ts":"x","run_id":"r006","disposition":"bug-old","note":"","schema_version":1}
{"ts":"x","run_id":"r007","disposition":"expected","note":"","schema_version":1}
EOF
run phase-advance-check && rc=0 || rc=$?
assert "$rc" "0" "T9 phase-advance-check rc=0 (all justified)"

# === Test 10: iteration-count <3 ==========================================
echo ""
echo "Test 10: iteration-count returns count, exits 0 when <3"
cat > "$DISPS" << 'EOF'
{"ts":"x","run_id":"r006","disposition":"bug-new","note":"","schema_version":1}
{"ts":"x","run_id":"r007","disposition":"bug-new","note":"","schema_version":1}
EOF
out=$(run iteration-count 2>/dev/null) && rc=0 || rc=$?
assert "$out" "2" "T10 iteration-count output=2"
assert "$rc" "0" "T10 exit=0 when bug-new <3"

# === Test 11: iteration-count ≥3 ==========================================
echo ""
echo "Test 11: iteration-count exits 2 when bug-new ≥3 (escalation)"
cat > "$DISPS" << 'EOF'
{"ts":"x","run_id":"r006","disposition":"bug-new","note":"","schema_version":1}
{"ts":"x","run_id":"r007","disposition":"bug-new","note":"","schema_version":1}
{"ts":"x","run_id":"r005","disposition":"bug-new","note":"","schema_version":1}
EOF
out=$(run iteration-count 2>/dev/null) && rc=0 || rc=$?
assert "$out" "3" "T11 iteration-count output=3"
assert "$rc" "2" "T11 exit=2 (cap reached)"

# === Summary ==============================================================
echo ""
echo "Tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
echo "All T-9 r55-parallel-run-audit assertions PASSED."
exit 0
