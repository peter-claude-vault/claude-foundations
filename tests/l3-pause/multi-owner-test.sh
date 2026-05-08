#!/bin/bash
# multi-owner-test.sh — T-4 sanity fixture (Plan 80/81 SP01).
#
# Pre-commit smoke test for l3-pause-helper.sh's foundational shape:
# pause/resume/status/validate semantics + multi-owner stack invariants
# (Plan 80 deploys atop Plan 71 paused state inherits stack — resume only
# fully releases when ALL owners drained).
#
# This is NOT the full T-17 fixture suite (6 tests including
# Incident-β regression + launchctl rc surfacing). T-17 is its own
# deliverable; this fixture is an in-development canary catching regressions
# in the helper's primary control flow.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$REPO_ROOT/hooks/lib/l3-pause-helper.sh"
[[ -x "$H" ]] || { echo "FAIL: $H not executable"; exit 1; }

TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

PLANS_ROOT="$TEST_DIR/.claude-plans"
HOOKS_STATE="$TEST_DIR/.claude/hooks/state"
mkdir -p "$PLANS_ROOT/plan-a" "$PLANS_ROOT/plan-b" "$HOOKS_STATE"

REGISTRY="$TEST_DIR/registry.json"
cat > "$REGISTRY" << 'EOF'
{"schema_version": 1, "writers": [
  {"id": "auto-commit-surfaces.sh", "trigger": "SessionEnd hook",
   "hook_path": "$HOME/.claude/hooks/auto-commit-surfaces.sh",
   "write_paths": ["$HOME/.claude/.git/**"],
   "pause_mechanism": "sentinel", "sentinel_path": "$HOOKS_STATE/canary-editing.lock"},
  {"id": "com.foo-cron", "launchd_label": "com.foo-cron",
   "plist_path": "$HOME/Library/LaunchAgents/com.foo-cron.plist",
   "write_paths": ["$HOME/.claude/state/foo.log"],
   "pause_mechanism": "launchctl"}
]}
EOF

cat > "$PLANS_ROOT/plan-a/manifest.json" << EOF
{"schema_version": 1, "project": "Plan A", "spec_path": "x",
 "live_mutation_scope": {"enabled": true, "schema_version": 1,
  "scope_paths": ["\$HOME/.claude/**"],
  "layer_3": {"enabled": true, "expected_quiescence_period_seconds": 0,
    "session_end_hooks": [{"path": "\$HOME/.claude/hooks/auto-commit-surfaces.sh", "pause_via": "sentinel", "sentinel_path": "$HOOKS_STATE/canary-editing.lock"}],
    "launchd_labels": ["com.foo-cron"]}}}
EOF

cat > "$PLANS_ROOT/plan-b/manifest.json" << EOF
{"schema_version": 1, "project": "Plan B", "spec_path": "x",
 "live_mutation_scope": {"enabled": true, "schema_version": 1,
  "scope_paths": ["\$HOME/.claude/**"],
  "layer_3": {"enabled": true, "expected_quiescence_period_seconds": 0,
    "session_end_hooks": [{"path": "\$HOME/.claude/hooks/auto-commit-surfaces.sh", "pause_via": "sentinel", "sentinel_path": "$HOOKS_STATE/canary-editing.lock"}]}}}
EOF

run() {
  HOOKS_STATE_OVERRIDE="$HOOKS_STATE" \
  PLANS_ROOT_OVERRIDE="$PLANS_ROOT" \
  L3_REGISTRY_PATH="$REGISTRY" \
  SKIP_LAUNCHCTL=1 \
  L3_QUIESCENCE_OVERRIDE=0 \
  bash "$H" "$@"
}

assert() { [[ "$1" == "$2" ]] || { echo "FAIL: $3 (expected '$2', got '$1')"; exit 1; }; }

echo "Test: pause plan-a"
out=$(run pause plan-a --quiescence-skip --skip-launchctl)
[[ "$out" == *"writers: 2"* ]] || { echo "FAIL: expected 2 writers paused"; exit 1; }
[[ -e "$HOOKS_STATE/canary-editing.lock" ]] || { echo "FAIL: sentinel not created"; exit 1; }
echo "  PASS"

echo "Test: pause plan-a idempotent (no new owners)"
out=$(run pause plan-a --quiescence-skip --skip-launchctl)
[[ "$out" == *"writers: 0"* ]] || { echo "FAIL: re-pause should be no-op; got: $out"; exit 1; }
echo "  PASS"

echo "Test: multi-owner — pause plan-b stacks atop plan-a"
run pause plan-b --quiescence-skip --skip-launchctl >/dev/null
owners=$(jq -r '.owners | join(",")' "$HOOKS_STATE/l3-pause-state/auto-commit-surfaces_sh.json")
assert "$owners" "plan-a,plan-b" "multi-owner stack ordering"
echo "  PASS"

echo "Test: status filtered by plan-id"
count=$(run status plan-b | jq -s 'length')
assert "$count" "1" "status plan-b should show only writers owned by plan-b"
echo "  PASS"

echo "Test: resume plan-b — plan-a still owns shared writer"
run resume plan-b >/dev/null
[[ -e "$HOOKS_STATE/canary-editing.lock" ]] || { echo "FAIL: sentinel removed prematurely"; exit 1; }
owners=$(jq -r '.owners | join(",")' "$HOOKS_STATE/l3-pause-state/auto-commit-surfaces_sh.json")
assert "$owners" "plan-a" "post-resume-b owner stack"
echo "  PASS"

echo "Test: resume plan-a — full release; sentinel removed; state files cleaned"
run resume plan-a >/dev/null
[[ ! -e "$HOOKS_STATE/canary-editing.lock" ]] || { echo "FAIL: sentinel not removed on full release"; exit 1; }
[[ -z "$(ls -A "$HOOKS_STATE/l3-pause-state/" 2>/dev/null)" ]] || { echo "FAIL: state files leaked after full release"; exit 1; }
echo "  PASS"

echo "Test: validate plan-a clean (writers in registry)"
out=$(run validate plan-a)
[[ "$out" == *"PASS (0 issues)"* ]] || { echo "FAIL: expected clean validate; got: $out"; exit 1; }
echo "  PASS"

echo "Test: validate detects drift for writer not in registry"
mkdir -p "$PLANS_ROOT/plan-d"
cat > "$PLANS_ROOT/plan-d/manifest.json" << EOF
{"schema_version": 1, "project": "Plan D", "spec_path": "x",
 "live_mutation_scope": {"enabled": true, "schema_version": 1,
  "layer_3": {"enabled": true,
    "session_end_hooks": [{"path": "/nonexistent/foo-hook.sh", "pause_via": "sentinel", "sentinel_path": "/tmp/xyz"}]}}}
EOF
out=$(run validate plan-d) || true
[[ "$out" == *"NOT FOUND in registry"* ]] || { echo "FAIL: drift not detected; got: $out"; exit 1; }
echo "  PASS"

echo ""
echo "All multi-owner sanity assertions PASSED. T-4 control flow validated."
echo "Full T-17 fixture suite (6 tests including Incident-β regression"
echo "+ launchctl rc surfacing + atomic-rollback) is its own deliverable."
exit 0
