#!/bin/bash
# plans-root-override-test.sh — Tier-1 fixture for SP01 T-3.5.
#
# Validates that live-guard.sh's PLANS_ROOT_OVERRIDE env var redirects the
# plan-tree walk to a synthetic root, and that active-gates-rebuild.sh's
# --plans-root flag produces symmetric resolution. Without the override, the
# helper would self-resolve plans-root from $HOME/.claude-plans and the SP08
# fixture `manifest_mechanism_extensibility` would PASS BY COINCIDENCE
# (because Plan 71's gate is already armed in the live tree). This fixture
# proves the override path is structurally honored, not a no-op.
#
# Per master Path D step 4 amendment item (f) + adversarial reviewer probe 2.1
# + discipline reviewer Check L convergent finding (2026-05-07 alignment S9).
#
# A15 anti-success criterion (PLANS_ROOT_OVERRIDE env not honored) is
# refuted by a passing run of this fixture.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$REPO_ROOT/hooks/lib/live-guard.sh"
REBUILD="$REPO_ROOT/skills/librarian/capabilities/active-gates-rebuild.sh"

[[ -x "$GUARD" ]] || { echo "FAIL: $GUARD not executable"; exit 1; }
[[ -x "$REBUILD" ]] || { echo "FAIL: $REBUILD not executable"; exit 1; }

TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

PLANS_ROOT="$TEST_DIR/.claude-plans"
HOOKS_STATE="$TEST_DIR/.claude/hooks/state"
CLAUDE_HOME="$TEST_DIR/.claude"
mkdir -p "$PLANS_ROOT/synthetic-plan-99" "$HOOKS_STATE" "$CLAUDE_HOME"

# Init a tag-anchorable git repo at $CLAUDE_HOME (live-guard.sh nonce SHA path)
cd "$CLAUDE_HOME"
git init -q .
echo "x" > .gitkeep
git -c user.name=t -c user.email=t@t add .gitkeep
git -c user.name=t -c user.email=t@t commit -q -m initial
git tag synthetic-plan-99/pre-flight
cd - >/dev/null

# === Plant a synthetic plan with a UNIQUE plan_id_pattern that does NOT ==
# match anything in the live $HOME/.claude-plans/ tree. If override is
# silently dropped (live-guard.sh self-resolves to $HOME/.claude-plans),
# the synthetic gate is INVISIBLE and no decision will fire. If override
# is honored, the synthetic gate fires and emits a deny.
cat > "$PLANS_ROOT/synthetic-plan-99/manifest.json" <<EOF
{
  "schema_version": 1,
  "project": "synthetic-plan-99",
  "spec_path": "x",
  "top_level_status": "in_progress",
  "live_mutation_scope": {
    "enabled": true,
    "schema_version": 1,
    "scope_paths": ["$TEST_DIR/.claude/**"],
    "exempt_paths": [],
    "detection_signals": {
      "plan_mode_env_var": "SYNTHETIC_PLAN_99_MODE",
      "deterministic_only": true
    },
    "override": {
      "nonce_dir": "$HOOKS_STATE/synthetic-plan-99-nonces",
      "nonce_sha_anchor": "synthetic-plan-99/pre-flight",
      "nonce_min_reason_length": 12,
      "nonce_consume_strategy": "basename_match_env",
      "nonce_affinity_env": "SYNTHETIC_PLAN_99_NONCE_TASK",
      "sentinel_override_path": "$HOOKS_STATE/.allow-synthetic-plan-99",
      "bypass_env_var": "SYNTHETIC_PLAN_99_BYPASS"
    },
    "enforcement": {
      "match_action": "deny",
      "error_action": "deny"
    }
  }
}
EOF

# === Test 1: live-guard.sh PLANS_ROOT_OVERRIDE wired ====================
echo "Test 1: live-guard.sh honors PLANS_ROOT_OVERRIDE"

OUTPUT=$(SYNTHETIC_PLAN_99_MODE=1 \
  FILE_PATH="$TEST_DIR/.claude/somefile" \
  TOOL_NAME="Edit" \
  HOOKS_STATE_OVERRIDE="$HOOKS_STATE" \
  PLANS_ROOT_OVERRIDE="$PLANS_ROOT" \
  CLAUDE_HOME="$CLAUDE_HOME" \
  bash "$GUARD" </dev/null 2>&1 || true)

if echo "$OUTPUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  echo "  PASS: synthetic-plan-99 gate fired deny (override honored)"
else
  echo "  FAIL: expected deny from synthetic gate; got:"
  echo "$OUTPUT" | sed 's/^/    /'
  exit 1
fi

# === Test 2: defaulting (no override) does NOT walk synthetic tree ======
# Without the override, the helper walks $HOME/.claude-plans which does NOT
# contain synthetic-plan-99. Setting SYNTHETIC_PLAN_99_MODE=1 should be a
# no-op detection signal because no manifest declares it.
echo "Test 2: live-guard.sh defaults to \$HOME/.claude-plans (synthetic invisible)"

# Use a fake $HOME so the helper won't accidentally see real plans either.
# This is a NEGATIVE test: prove the synthetic gate ONLY fires when override
# is set. Run without PLANS_ROOT_OVERRIDE.
NO_OVERRIDE_OUTPUT=$(SYNTHETIC_PLAN_99_MODE=1 \
  FILE_PATH="$TEST_DIR/.claude/somefile" \
  TOOL_NAME="Edit" \
  HOOKS_STATE_OVERRIDE="$HOOKS_STATE" \
  HOME="$TEST_DIR/empty-home" \
  CLAUDE_HOME="$CLAUDE_HOME" \
  bash "$GUARD" </dev/null 2>&1 || true)

if [[ -z "$NO_OVERRIDE_OUTPUT" ]]; then
  echo "  PASS: no override → empty stdout (synthetic gate invisible to default walk)"
else
  echo "  FAIL: expected empty stdout (no synthetic gate match); got:"
  echo "$NO_OVERRIDE_OUTPUT" | sed 's/^/    /'
  exit 1
fi

# === Test 3: active-gates-rebuild.sh --plans-root symmetric =============
echo "Test 3: active-gates-rebuild.sh --plans-root resolves symmetrically"

REPLICA_OUT="$TEST_DIR/active-gates.json"
bash "$REBUILD" --plans-root "$PLANS_ROOT" --output "$REPLICA_OUT" >/dev/null

if jq -e '.gates[] | select(.plan_id == "synthetic-plan-99")' "$REPLICA_OUT" >/dev/null 2>&1; then
  echo "  PASS: replica contains synthetic-plan-99 gate"
else
  echo "  FAIL: replica does not contain synthetic-plan-99:"
  jq . "$REPLICA_OUT" | sed 's/^/    /'
  exit 1
fi

if jq -e '.plans_root | endswith(".claude-plans")' "$REPLICA_OUT" >/dev/null 2>&1; then
  echo "  PASS: replica records plans_root = $PLANS_ROOT"
else
  echo "  FAIL: replica plans_root field mismatch"
  exit 1
fi

# === Test 4: live-guard.sh fast-path reads replica via ACTIVE_GATES_PATH =
echo "Test 4: live-guard.sh ACTIVE_GATES_PATH read-replica fast-path"

# Run guard against the replica (synthesized in Test 3). PLANS_ROOT_OVERRIDE
# UNSET — should still detect synthetic-plan-99 via the read-replica.
RR_OUTPUT=$(SYNTHETIC_PLAN_99_MODE=1 \
  FILE_PATH="$TEST_DIR/.claude/somefile" \
  TOOL_NAME="Edit" \
  HOOKS_STATE_OVERRIDE="$HOOKS_STATE" \
  HOME="$TEST_DIR/empty-home" \
  ACTIVE_GATES_PATH="$REPLICA_OUT" \
  CLAUDE_HOME="$CLAUDE_HOME" \
  bash "$GUARD" </dev/null 2>&1 || true)

if echo "$RR_OUTPUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  echo "  PASS: fast-path read-replica fires deny (gates: $(jq -r '.gates | length' "$REPLICA_OUT"))"
else
  echo "  FAIL: expected deny via read-replica; got:"
  echo "$RR_OUTPUT" | sed 's/^/    /'
  exit 1
fi

echo ""
echo "All 4 tier-1 PLANS_ROOT_OVERRIDE assertions PASSED."
echo "T-3.5 acceptance criteria 1, 2, 3 satisfied. SP08 fixture"
echo "live_guard_root_resolution_determinism is structurally testable."
echo "A15 anti-success criterion REFUTED."
exit 0
