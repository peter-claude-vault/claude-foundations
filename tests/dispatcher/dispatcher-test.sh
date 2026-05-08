#!/bin/bash
# dispatcher-test.sh — pre-commit-dispatcher.sh fixture suite
#
# (Plan 80/81 SP01 Session 13; T-20 Phase A pre-stage)
#
# Exercises pre-commit-dispatcher.sh as the .git/hooks/pre-commit
# entrypoint, chaining R-37 + R-46-cousin via fail-fast order.
#
# Scenarios covered:
#   T1  both-pass — neither child fires; rc=0; dispatcher logs "allow"
#   T2  R-37 fail-fast — partial coupled-set blocks at R-37; rc=1;
#       harness child NOT invoked (proven via audit log absence)
#   T3  harness fail — flip-to-complete with no fresh harness_validated;
#       R-37 passes, harness rejects; rc=1
#   T4  both-conditions-present — R-37 partial + harness flip; R-37
#       blocks first; harness NOT invoked (fail-fast guarantee)
#   T5  R-37 sentinel override — partial coupled-set + .allow-r37-partial;
#       R-37 allows; dispatcher proceeds to harness
#   T6  harness sentinel override — flip + .allow-harness-validation-skip;
#       R-37 inert (no partial); harness allows; rc=0
#   T7  env-isolation — HOOKS_STATE_OVERRIDE redirects audit log;
#       GATE_CONFIG_PATH redirects R-37 config; both honored
#   T8  child-hook-missing — DISPATCHER_HOOKS_DIR_OVERRIDE points at
#       empty dir; rc=2; dispatcher emits error audit row
#
# Per feedback_test_isolation_for_hooks_state — all writes go through
# HOOKS_STATE_OVERRIDE; never touches live ~/.claude/hooks/state/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION_REPO="${FOUNDATION_REPO_OVERRIDE:-$HOME/Code/claude-stem}"
HOOKS_DIR="$FOUNDATION_REPO/git-hooks"
DISPATCHER="$HOOKS_DIR/pre-commit-dispatcher.sh"
GATE_CONFIG_LIVE="$FOUNDATION_REPO/schemas/gate-config.json"
CAP="$FOUNDATION_REPO/skills/librarian/capabilities/update-harness-validated.sh"

[[ ! -x "$DISPATCHER" ]] && { echo "FAIL: dispatcher not executable at $DISPATCHER" >&2; exit 1; }
[[ ! -f "$GATE_CONFIG_LIVE" ]] && { echo "FAIL: gate-config not found at $GATE_CONFIG_LIVE" >&2; exit 1; }

PASS=0
FAIL=0

assert() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $label" >&2
    echo "    expected: $expected" >&2
    echo "    actual:   $actual" >&2
  fi
}

assert_log_contains() {
  local label="$1" log_path="$2" jq_filter="$3" expected="$4"
  local actual
  actual=$(jq -r "$jq_filter" "$log_path" 2>/dev/null | head -1)
  assert "$label" "$actual" "$expected"
}

assert_log_absent() {
  local label="$1" log_path="$2" needle="$3"
  if [[ ! -f "$log_path" ]] || ! grep -q "$needle" "$log_path"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $label" >&2
    echo "    found unexpected: $needle" >&2
  fi
}

# === Per-test sandbox ==================================================
TEST_ROOT=$(mktemp -d -t dispatcher-XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

make_sandbox() {
  local name="$1"
  TEST_DIR="$TEST_ROOT/$name"
  HOOKS_STATE="$TEST_DIR/hooks-state"
  REPO="$TEST_DIR/repo"
  DIFF_FIXTURES="$TEST_DIR/diff-fixtures"
  AUDIT_LOG="$HOOKS_STATE/gate-decisions.log"

  mkdir -p "$HOOKS_STATE" "$REPO" "$DIFF_FIXTURES"
  git -C "$REPO" init -q
  git -C "$REPO" -c user.email=t@t -c user.name=t commit --allow-empty -q -m boot
  SHA=$(git -C "$REPO" rev-parse HEAD)
}

create_manifest_pair() {
  local name="$1" before_status="$2" after_status="$3" sub_plan_id="$4" hv_entries="$5"
  cat > "$DIFF_FIXTURES/${name}.before.json" <<JSON
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
  cat > "$DIFF_FIXTURES/${name}.after.json" <<JSON
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

# Run dispatcher with full env contract. STAGED is newline-separated.
run_dispatcher() {
  local staged="$1"
  cd "$REPO"
  HOOKS_STATE_OVERRIDE="$HOOKS_STATE" \
  GATE_CONFIG_PATH="$GATE_CONFIG_LIVE" \
  PRE_COMMIT_STAGED_OVERRIDE="$staged" \
  PRE_COMMIT_DIFF_OVERRIDE="$DIFF_FIXTURES" \
  FOUNDATION_REPO_OVERRIDE="$REPO" \
  FOUNDATION_SHA_OVERRIDE="$SHA" \
  UPDATE_HARNESS_CAP="$CAP" \
  R37_ENFORCEMENT_OVERRIDE="${R37_ENFORCEMENT_OVERRIDE:-deny}" \
  "$DISPATCHER"
}

# Ground-truth sets read from gate-config.json::r37.coupled_surfaces
VAULT_SCHEMA_FULL=(
  "schemas/vault-schema.json"
  "hooks/pre-write-guard.sh"
  "hooks/post-write-verify.sh"
  "CLAUDE.md"
)

# ========================================================================
# T1 — both-pass: nothing partial, no flip-to-complete → rc=0
# ========================================================================
echo "[T1] both-pass"
make_sandbox t1
# Stage a non-coupled, non-manifest file
STAGED="docs/random.md"
run_dispatcher "$STAGED" >/dev/null 2>&1
rc=$?
assert "T1.1 rc=0" "$rc" "0"
assert_log_contains "T1.2 dispatcher logs allow" "$AUDIT_LOG" \
  'select(.hook == "pre-commit-dispatcher") | .decision' "allow"
assert_log_contains "T1.3 dispatcher reason=both-children-passed" "$AUDIT_LOG" \
  'select(.hook == "pre-commit-dispatcher") | .reason' "both-children-passed"

# ========================================================================
# T2 — R-37 fail-fast: partial coupled-set; harness NOT invoked
# ========================================================================
echo "[T2] R-37 fail-fast"
make_sandbox t2
# Stage 2/4 of vault-schema-add → R-37 partial → deny
STAGED=$'schemas/vault-schema.json\nhooks/pre-write-guard.sh'
run_dispatcher "$STAGED" >/dev/null 2>&1
rc=$?
assert "T2.1 rc=1 (R-37 rejects)" "$rc" "1"
assert_log_contains "T2.2 dispatcher reason=blocked-at-r37" "$AUDIT_LOG" \
  'select(.hook == "pre-commit-dispatcher") | .reason' "blocked-at-r37"
# Harness child must NOT have logged anything (fail-fast)
assert_log_absent "T2.3 harness-validated NOT invoked" "$AUDIT_LOG" \
  '"hook":"pre-commit-harness-validated"'

# ========================================================================
# T3 — harness fail: R-37 passes, harness rejects flip-to-complete
# ========================================================================
echo "[T3] harness fail"
make_sandbox t3
# Empty harness_validated[] + flip in_progress→complete
create_manifest_pair "t3-manifest" "in_progress" "complete" "01-test" "[]"
STAGED="t3-manifest.json"
run_dispatcher "$STAGED" >/dev/null 2>&1
rc=$?
assert "T3.1 rc=1 (harness rejects)" "$rc" "1"
assert_log_contains "T3.2 dispatcher reason=blocked-at-harness-validated" "$AUDIT_LOG" \
  'select(.hook == "pre-commit-dispatcher") | .reason' "blocked-at-harness-validated"
# Harness child MUST have logged a reject row (proves it was invoked)
harness_decision=$(jq -r 'select(.hook == "pre-commit-harness-validated") | .decision' "$AUDIT_LOG" 2>/dev/null | head -1)
assert "T3.3 harness-validated logged reject" "$harness_decision" "reject"

# ========================================================================
# T4 — both-conditions-present: R-37 blocks first; harness NOT invoked
# ========================================================================
echo "[T4] both-conditions-present"
make_sandbox t4
# Stage partial coupled-set AND a flip manifest
create_manifest_pair "t4-manifest" "in_progress" "complete" "04-test" "[]"
STAGED=$'schemas/vault-schema.json\nhooks/pre-write-guard.sh\nt4-manifest.json'
run_dispatcher "$STAGED" >/dev/null 2>&1
rc=$?
assert "T4.1 rc=1 (R-37 blocks first)" "$rc" "1"
assert_log_contains "T4.2 dispatcher reason=blocked-at-r37" "$AUDIT_LOG" \
  'select(.hook == "pre-commit-dispatcher") | .reason' "blocked-at-r37"
assert_log_absent "T4.3 harness-validated NOT invoked" "$AUDIT_LOG" \
  '"hook":"pre-commit-harness-validated"'

# ========================================================================
# T5 — R-37 sentinel override: dispatcher proceeds to harness
# ========================================================================
echo "[T5] R-37 sentinel override"
make_sandbox t5
touch "$REPO/.allow-r37-partial"
# Partial coupled-set; sentinel allows; harness then runs (no flip → allow)
STAGED=$'schemas/vault-schema.json'
run_dispatcher "$STAGED" >/dev/null 2>&1
rc=$?
assert "T5.1 rc=0 (R-37 sentinel + no harness flip)" "$rc" "0"
# R-37 logged sentinel-override
r37_sentinel=$(jq -r 'select(.hook == "pre-commit-r37" and (.reason | tostring | test("sentinel"))) | .decision' "$AUDIT_LOG" 2>/dev/null | head -1)
assert "T5.2 R-37 logged sentinel-override allow" "$r37_sentinel" "allow"
# Dispatcher logged its own allow
assert_log_contains "T5.3 dispatcher reached allow" "$AUDIT_LOG" \
  'select(.hook == "pre-commit-dispatcher") | .decision' "allow"

# ========================================================================
# T6 — harness sentinel override: flip-to-complete + sentinel → allow
# ========================================================================
echo "[T6] harness sentinel override"
make_sandbox t6
touch "$REPO/.allow-harness-validation-skip"
create_manifest_pair "t6-manifest" "in_progress" "complete" "06-test" "[]"
STAGED="t6-manifest.json"
run_dispatcher "$STAGED" >/dev/null 2>&1
rc=$?
assert "T6.1 rc=0 (harness sentinel)" "$rc" "0"
# Harness logged sentinel allow
harness_sentinel=$(jq -r 'select(.hook == "pre-commit-harness-validated" and (.reason | tostring | test("sentinel"))) | .decision' "$AUDIT_LOG" 2>/dev/null | head -1)
assert "T6.2 harness logged sentinel-override allow" "$harness_sentinel" "allow"

# ========================================================================
# T7 — env-isolation: HOOKS_STATE_OVERRIDE + GATE_CONFIG_PATH propagate
# ========================================================================
echo "[T7] env-isolation"
make_sandbox t7
# Build alternate gate-config that DISABLES R-37 entirely → R-37 allows
ALT_CONFIG="$TEST_DIR/alt-gate-config.json"
jq '.r37.enabled = false' "$GATE_CONFIG_LIVE" > "$ALT_CONFIG"
STAGED=$'schemas/vault-schema.json\nhooks/pre-write-guard.sh'  # would normally trigger R-37 partial
cd "$REPO"
HOOKS_STATE_OVERRIDE="$HOOKS_STATE" \
GATE_CONFIG_PATH="$ALT_CONFIG" \
PRE_COMMIT_STAGED_OVERRIDE="$STAGED" \
PRE_COMMIT_DIFF_OVERRIDE="$DIFF_FIXTURES" \
FOUNDATION_REPO_OVERRIDE="$REPO" \
FOUNDATION_SHA_OVERRIDE="$SHA" \
UPDATE_HARNESS_CAP="$CAP" \
R37_ENFORCEMENT_OVERRIDE="deny" \
"$DISPATCHER" >/dev/null 2>&1
rc=$?
assert "T7.1 rc=0 (R-37 disabled via alt config)" "$rc" "0"
# Audit log must be at the override path (not live state)
[[ -f "$AUDIT_LOG" ]] && audit_present=yes || audit_present=no
assert "T7.2 audit log at HOOKS_STATE_OVERRIDE path" "$audit_present" "yes"
# Live state path must NOT have received writes from this test
assert_log_contains "T7.3 R-37 logged disabled-passthrough" "$AUDIT_LOG" \
  'select(.hook == "pre-commit-r37") | .reason' "r37-disabled-in-config"

# ========================================================================
# T8 — child-hook-missing: empty hooks dir → rc=2 + error audit row
# ========================================================================
echo "[T8] child-hook-missing"
make_sandbox t8
EMPTY_DIR="$TEST_DIR/empty-hooks"
mkdir -p "$EMPTY_DIR"
cd "$REPO"
HOOKS_STATE_OVERRIDE="$HOOKS_STATE" \
DISPATCHER_HOOKS_DIR_OVERRIDE="$EMPTY_DIR" \
"$DISPATCHER" >/dev/null 2>&1
rc=$?
assert "T8.1 rc=2 (internal error)" "$rc" "2"
assert_log_contains "T8.2 dispatcher logged error decision" "$AUDIT_LOG" \
  'select(.hook == "pre-commit-dispatcher") | .decision' "error"

# ========================================================================
# Summary
# ========================================================================
echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
