#!/bin/bash
# rebuild-test.sh — T-8 acceptance fixture (Plan 80/81 SP01).
#
# Validates active-gates-rebuild.sh full-ship behavior:
#   1. Empty plans-root: 0 gates, passed
#   2. Single master gate: collected; passed
#   3. Sub-plan UNION-merging via inherits_from: scope_paths/exempt_paths/
#      launchd_labels/session_end_hooks all UNION'd; provenance stamped under
#      _merged_sub_plans[].
#   4. Two non-overlapping masters: passed
#   5. Two overlapping masters (one prefix-contains the other): FAILED;
#      finding lists both pairs; --strict exits non-zero.
#   6. Sub-plan with absent inherits_from target: orphan surfaced in metadata.
#   7. --skip-overlap-check: status="skipped" regardless of conflict.
#   8. --plans-root override: synthetic plan-tree resolution honored.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$REPO_ROOT/skills/librarian/capabilities/active-gates-rebuild.sh"
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

assert_contains() {
  if [[ "$1" == *"$2"* ]]; then
    echo "  PASS: $3"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: $3 (expected to contain '$2', got '$1')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# === Test 1: empty plans-root =============================================
echo "Test 1: empty plans-root → 0 gates, passed"
PR1="$TEST_DIR/test1/.claude-plans"
mkdir -p "$PR1"
OUT1="$TEST_DIR/test1/active-gates.json"
"$H" --plans-root "$PR1" --output "$OUT1" 2>/dev/null

assert "$(jq -r '.metadata.master_gate_count' "$OUT1")" "0" "T1 master_gate_count=0"
assert "$(jq -r '.scope_overlap_check' "$OUT1")" "passed" "T1 overlap check passed"
assert "$(jq -r '.metadata.sub_plan_merge_count' "$OUT1")" "0" "T1 sub_plan_merge_count=0"

# === Test 2: single master gate ===========================================
echo ""
echo "Test 2: single master gate"
PR2="$TEST_DIR/test2/.claude-plans"
mkdir -p "$PR2/plan-alpha"
cat > "$PR2/plan-alpha/manifest.json" <<'EOF'
{
  "schema_version": 1,
  "live_mutation_scope": {
    "enabled": true,
    "scope_paths": ["$HOME/.local/share/alpha/**"],
    "exempt_paths": ["$HOME/.local/share/alpha/cache/**"],
    "layer_3": {"enabled": true, "launchd_labels": ["com.alpha.cron"]}
  }
}
EOF
OUT2="$TEST_DIR/test2/active-gates.json"
"$H" --plans-root "$PR2" --output "$OUT2" 2>/dev/null

assert "$(jq -r '.metadata.master_gate_count' "$OUT2")" "1" "T2 master_gate_count=1"
assert "$(jq -r '.gates[0].plan_id' "$OUT2")" "plan-alpha" "T2 plan_id=plan-alpha"
assert "$(jq -r '.gates[0].scope_paths[0]' "$OUT2")" '$HOME/.local/share/alpha/**' "T2 scope_paths preserved"
assert "$(jq -r '.scope_overlap_check' "$OUT2")" "passed" "T2 overlap check passed"

# === Test 3: sub-plan UNION-merging via inherits_from =====================
echo ""
echo "Test 3: sub-plan UNION-merging via inherits_from"
PR3="$TEST_DIR/test3/.claude-plans"
mkdir -p "$PR3/plan-master/01-feature-a" "$PR3/plan-master/02-feature-b"
cat > "$PR3/plan-master/manifest.json" <<'EOF'
{
  "schema_version": 1,
  "live_mutation_scope": {
    "enabled": true,
    "scope_paths": ["$HOME/.local/share/master/**"],
    "exempt_paths": ["$HOME/.local/share/master/cache/**"],
    "layer_3": {
      "enabled": true,
      "launchd_labels": ["com.master.daily"],
      "session_end_hooks": [{"path": "/hooks/master-end.sh", "pause_via": "sentinel"}]
    },
    "g2_commit_denylist": ["dist/**"]
  }
}
EOF
cat > "$PR3/plan-master/01-feature-a/manifest.json" <<'EOF'
{
  "schema_version": 1,
  "parent_plan": "plan-master",
  "live_mutation_scope": {
    "enabled": true,
    "inherits_from": "plan-master",
    "scope_paths": ["$HOME/.local/share/master/feature-a/**"],
    "layer_3": {
      "launchd_labels": ["com.master.feature-a-hourly"],
      "session_end_hooks": [{"path": "/hooks/feature-a-end.sh", "pause_via": "env"}]
    }
  }
}
EOF
cat > "$PR3/plan-master/02-feature-b/manifest.json" <<'EOF'
{
  "schema_version": 1,
  "parent_plan": "plan-master",
  "live_mutation_scope": {
    "enabled": true,
    "inherits_from": "plan-master",
    "exempt_paths": ["$HOME/.local/share/master/feature-b-tmp/**"],
    "g2_commit_denylist": ["coverage/**"]
  }
}
EOF
OUT3="$TEST_DIR/test3/active-gates.json"
"$H" --plans-root "$PR3" --output "$OUT3" 2>/dev/null

assert "$(jq -r '.metadata.master_gate_count' "$OUT3")" "1" "T3 master_gate_count=1"
assert "$(jq -r '.metadata.sub_plan_merge_count' "$OUT3")" "2" "T3 sub_plan_merge_count=2"
# UNION on scope_paths (master + feature-a's contribution)
sp_count=$(jq -r '.gates[0].scope_paths | length' "$OUT3")
assert "$sp_count" "2" "T3 scope_paths UNION (2 entries)"
# UNION on launchd_labels (master + feature-a's)
ll_count=$(jq -r '.gates[0].layer_3.launchd_labels | length' "$OUT3")
assert "$ll_count" "2" "T3 launchd_labels UNION (2 entries)"
# UNION on session_end_hooks
seh_count=$(jq -r '.gates[0].layer_3.session_end_hooks | length' "$OUT3")
assert "$seh_count" "2" "T3 session_end_hooks UNION (2 entries)"
# UNION on exempt_paths
ep_count=$(jq -r '.gates[0].exempt_paths | length' "$OUT3")
assert "$ep_count" "2" "T3 exempt_paths UNION (2 entries)"
# UNION on g2_commit_denylist
g2_count=$(jq -r '.gates[0].g2_commit_denylist | length' "$OUT3")
assert "$g2_count" "2" "T3 g2_commit_denylist UNION (2 entries)"
# Provenance stamped
sp_prov_count=$(jq -r '.gates[0]._merged_sub_plans | length' "$OUT3")
assert "$sp_prov_count" "2" "T3 _merged_sub_plans provenance count"

# === Test 4: two non-overlapping masters → passed =========================
echo ""
echo "Test 4: two non-overlapping masters → passed"
PR4="$TEST_DIR/test4/.claude-plans"
mkdir -p "$PR4/plan-x" "$PR4/plan-y"
cat > "$PR4/plan-x/manifest.json" <<'EOF'
{"schema_version": 1, "live_mutation_scope": {"enabled": true, "scope_paths": ["$HOME/.local/share/x/**"]}}
EOF
cat > "$PR4/plan-y/manifest.json" <<'EOF'
{"schema_version": 1, "live_mutation_scope": {"enabled": true, "scope_paths": ["$HOME/.local/share/y/**"]}}
EOF
OUT4="$TEST_DIR/test4/active-gates.json"
"$H" --plans-root "$PR4" --output "$OUT4" 2>/dev/null

assert "$(jq -r '.metadata.master_gate_count' "$OUT4")" "2" "T4 master_gate_count=2"
assert "$(jq -r '.scope_overlap_check' "$OUT4")" "passed" "T4 overlap check passed (no overlap)"
assert "$(jq -r '.metadata.scope_overlap_findings | length' "$OUT4")" "0" "T4 zero overlap findings"

# === Test 5: two overlapping masters → FAILED + --strict rc=2 ============
echo ""
echo "Test 5: two overlapping masters → FAILED + --strict rc=2"
PR5="$TEST_DIR/test5/.claude-plans"
mkdir -p "$PR5/plan-broad" "$PR5/plan-narrow"
cat > "$PR5/plan-broad/manifest.json" <<'EOF'
{"schema_version": 1, "live_mutation_scope": {"enabled": true, "scope_paths": ["$HOME/.local/share/**"]}}
EOF
cat > "$PR5/plan-narrow/manifest.json" <<'EOF'
{"schema_version": 1, "live_mutation_scope": {"enabled": true, "scope_paths": ["$HOME/.local/share/narrow/**"]}}
EOF
OUT5="$TEST_DIR/test5/active-gates.json"
"$H" --plans-root "$PR5" --output "$OUT5" 2>/dev/null

assert "$(jq -r '.scope_overlap_check' "$OUT5")" "FAILED" "T5 overlap check FAILED"
findings_count=$(jq -r '.metadata.scope_overlap_findings | length' "$OUT5")
[[ "$findings_count" -ge 1 ]] && {
  PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: T5 ≥1 finding ($findings_count)"
} || {
  FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: T5 finding count $findings_count"
}

# --strict mode exits non-zero
"$H" --plans-root "$PR5" --output "$TEST_DIR/test5/strict.json" --strict 2>/dev/null && \
  rc_strict=0 || rc_strict=$?
assert "$rc_strict" "2" "T5 --strict exit code = 2"

# === Test 6: orphan sub-plan (inherits_from points to absent master) ======
echo ""
echo "Test 6: orphan sub-plan surfaced in metadata"
PR6="$TEST_DIR/test6/.claude-plans"
mkdir -p "$PR6/plan-master/01-orphan"
cat > "$PR6/plan-master/manifest.json" <<'EOF'
{"schema_version": 1, "live_mutation_scope": {"enabled": false}}
EOF
cat > "$PR6/plan-master/01-orphan/manifest.json" <<'EOF'
{
  "schema_version": 1,
  "parent_plan": "plan-master",
  "live_mutation_scope": {
    "enabled": true,
    "inherits_from": "plan-master",
    "scope_paths": ["$HOME/.local/share/orphan/**"]
  }
}
EOF
OUT6="$TEST_DIR/test6/active-gates.json"
"$H" --plans-root "$PR6" --output "$OUT6" 2>/dev/null

assert "$(jq -r '.metadata.orphan_sub_plans | length' "$OUT6")" "1" "T6 orphan_sub_plans count=1"
assert "$(jq -r '.metadata.orphan_sub_plans[0].sub_plan_id' "$OUT6")" "01-orphan" "T6 orphan sub_plan_id"
assert "$(jq -r '.metadata.orphan_sub_plans[0].master_plan_id' "$OUT6")" "plan-master" "T6 orphan master_plan_id"

# === Test 7: --skip-overlap-check produces "skipped" ======================
echo ""
echo "Test 7: --skip-overlap-check → status=skipped (overrides conflict)"
"$H" --plans-root "$PR5" --output "$TEST_DIR/test7/skipped.json" --skip-overlap-check 2>/dev/null
assert "$(jq -r '.scope_overlap_check' "$TEST_DIR/test7/skipped.json")" "skipped" "T7 overlap check skipped"

# === Test 8: --plans-root override (T-3.5 contract) =======================
echo ""
echo "Test 8: --plans-root override honored"
PR8="$TEST_DIR/test8/.synthetic-plans"
mkdir -p "$PR8/synthetic-plan"
cat > "$PR8/synthetic-plan/manifest.json" <<'EOF'
{"schema_version": 1, "live_mutation_scope": {"enabled": true, "scope_paths": ["$HOME/.synthetic/**"]}}
EOF
OUT8="$TEST_DIR/test8/active-gates.json"
"$H" --plans-root "$PR8" --output "$OUT8" 2>/dev/null
assert "$(jq -r '.plans_root' "$OUT8")" "$PR8" "T8 plans_root resolves from --plans-root"
assert "$(jq -r '.gates[0].plan_id' "$OUT8")" "synthetic-plan" "T8 synthetic-plan visible only via override"

# === Summary ==============================================================
echo ""
echo "Tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
echo "All T-8 active-gates-rebuild assertions PASSED."
exit 0
