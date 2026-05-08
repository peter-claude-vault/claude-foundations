#!/bin/bash
# regen-trigger-test.sh — T-13 acceptance fixture (Plan 80/81 SP01).
#
# Validates post-tool-use-manifest.sh behavior:
#   1. Edit on top-level plan manifest → regen fires
#   2. Write on sub-plan manifest → regen fires
#   3. Edit on non-manifest file → regen does NOT fire
#   4. Edit on file outside .claude-plans → regen does NOT fire
#   5. Wrong tool_name (Read) → regen does NOT fire
#   6. Malformed JSON stdin → silent exit 0 (no error)
#   7. Missing rebuild binary → silent exit 0 (slow-path fallback covers)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$REPO_ROOT/hooks/post-tool-use-manifest.sh"
RB="$REPO_ROOT/skills/librarian/capabilities/active-gates-rebuild.sh"
[[ -x "$H" ]] || { echo "FAIL: $H not executable"; exit 1; }
[[ -x "$RB" ]] || { echo "FAIL: $RB not executable"; exit 1; }

TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

PASS_COUNT=0
FAIL_COUNT=0

# Synthetic plan-tree
PR="$TEST_DIR/.claude-plans"
mkdir -p "$PR/plan-test/01-feature"
cat > "$PR/plan-test/manifest.json" <<'EOF'
{"schema_version": 1, "live_mutation_scope": {"enabled": true, "scope_paths": ["$HOME/.test/**"]}}
EOF
cat > "$PR/plan-test/01-feature/manifest.json" <<'EOF'
{"schema_version": 1, "parent_plan": "plan-test",
 "live_mutation_scope": {"enabled": true, "inherits_from": "plan-test", "scope_paths": ["$HOME/.test/feature/**"]}}
EOF

LOG="$TEST_DIR/post-tool-use.log"
OUT="$TEST_DIR/active-gates.json"

run_hook() {
  local stdin_json="$1"
  ACTIVE_GATES_REBUILD_BIN="$RB" \
  PLANS_ROOT_OVERRIDE="$PR" \
  ACTIVE_GATES_PATH="$OUT" \
  POST_TOOL_USE_SYNC_MODE=1 \
  POST_TOOL_USE_LOG="$LOG" \
  bash "$H" <<< "$stdin_json"
}

assert() {
  if [[ "$1" == "$2" ]]; then
    echo "  PASS: $3"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: $3 (expected '$2', got '$1')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# === Test 1: Edit on top-level plan manifest → regen fires ================
echo "Test 1: Edit on top-level plan manifest → regen fires"
rm -f "$OUT" "$LOG"
EVENT=$(jq -nc --arg fp "$PR/plan-test/manifest.json" '{tool_name: "Edit", tool_input: {file_path: $fp}}')
run_hook "$EVENT"
[[ -f "$OUT" ]] && assert "exists" "exists" "T1 active-gates.json written" \
  || assert "missing" "exists" "T1 active-gates.json written"
assert "$(jq -r '.metadata.master_gate_count' "$OUT" 2>/dev/null)" "1" "T1 1 master gate"

# === Test 2: Write on sub-plan manifest → regen fires =====================
echo ""
echo "Test 2: Write on sub-plan manifest → regen fires"
rm -f "$OUT" "$LOG"
EVENT=$(jq -nc --arg fp "$PR/plan-test/01-feature/manifest.json" '{tool_name: "Write", tool_input: {file_path: $fp}}')
run_hook "$EVENT"
[[ -f "$OUT" ]] && assert "exists" "exists" "T2 active-gates.json written" \
  || assert "missing" "exists" "T2 active-gates.json written"
assert "$(jq -r '.metadata.sub_plan_merge_count' "$OUT" 2>/dev/null)" "1" "T2 1 sub-plan merge"

# === Test 3: Edit on non-manifest file → regen does NOT fire =============
echo ""
echo "Test 3: Edit on non-manifest file → regen does NOT fire"
rm -f "$OUT" "$LOG"
EVENT=$(jq -nc --arg fp "$PR/plan-test/spec.md" '{tool_name: "Edit", tool_input: {file_path: $fp}}')
run_hook "$EVENT"
[[ ! -f "$OUT" ]] && assert "absent" "absent" "T3 no regen for spec.md edit" \
  || assert "present" "absent" "T3 no regen for spec.md edit"

# === Test 4: Edit on file outside .claude-plans → regen does NOT fire =====
echo ""
echo "Test 4: Edit on file outside .claude-plans → regen does NOT fire"
rm -f "$OUT" "$LOG"
EVENT=$(jq -nc --arg fp "/some/random/manifest.json" '{tool_name: "Edit", tool_input: {file_path: $fp}}')
run_hook "$EVENT"
[[ ! -f "$OUT" ]] && assert "absent" "absent" "T4 no regen for random manifest.json" \
  || assert "present" "absent" "T4 no regen for random manifest.json"

# === Test 5: Wrong tool_name (Read) → regen does NOT fire ================
echo ""
echo "Test 5: Wrong tool_name (Read) → regen does NOT fire"
rm -f "$OUT" "$LOG"
EVENT=$(jq -nc --arg fp "$PR/plan-test/manifest.json" '{tool_name: "Read", tool_input: {file_path: $fp}}')
run_hook "$EVENT"
[[ ! -f "$OUT" ]] && assert "absent" "absent" "T5 no regen for Read tool" \
  || assert "present" "absent" "T5 no regen for Read tool"

# === Test 6: Malformed JSON stdin → silent exit 0 ========================
echo ""
echo "Test 6: Malformed JSON stdin → silent exit 0 (no error)"
rm -f "$OUT" "$LOG"
ACTIVE_GATES_REBUILD_BIN="$RB" \
PLANS_ROOT_OVERRIDE="$PR" \
ACTIVE_GATES_PATH="$OUT" \
POST_TOOL_USE_SYNC_MODE=1 \
POST_TOOL_USE_LOG="$LOG" \
bash "$H" <<< "not valid json {{{" && rc=0 || rc=$?
assert "$rc" "0" "T6 exit 0 on malformed JSON"

# === Test 7: Missing rebuild binary → silent exit 0 =======================
echo ""
echo "Test 7: Missing rebuild binary → silent exit 0 (slow-path fallback)"
rm -f "$OUT" "$LOG"
EVENT=$(jq -nc --arg fp "$PR/plan-test/manifest.json" '{tool_name: "Edit", tool_input: {file_path: $fp}}')
ACTIVE_GATES_REBUILD_BIN="/nonexistent/regen.sh" \
PLANS_ROOT_OVERRIDE="$PR" \
ACTIVE_GATES_PATH="$OUT" \
POST_TOOL_USE_SYNC_MODE=1 \
POST_TOOL_USE_LOG="$LOG" \
bash "$H" <<< "$EVENT" && rc=0 || rc=$?
assert "$rc" "0" "T7 exit 0 when regen binary unavailable"
[[ ! -f "$OUT" ]] && assert "absent" "absent" "T7 active-gates.json NOT written" \
  || assert "present" "absent" "T7 active-gates.json NOT written"

# === Summary ==============================================================
echo ""
echo "Tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
echo "All T-13 post-tool-use-manifest assertions PASSED."
exit 0
