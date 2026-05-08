#!/bin/bash
# dry-run-test.sh — Tier-1 fixture for SP01 T-3.6.
#
# Validates the `--dry-run <path>` CLI surface added to live-guard.sh:
#   (1) positional <path> arg is accepted and overrides FILE_PATH env;
#   (2) decision JSON is emitted (same shape as production callers see);
#   (3) nonce overrides are NOT consumed in dry-run mode (file persists);
#   (4) gate-decisions.log rows are tagged `dry_run: true`;
#   (5) production env-var contract is preserved (no flag → no dry-run).
#
# Resolves SP04 §3.8 binding-contract gap: writers can pre-flight a path
# without burning task-bound nonces or polluting the audit log indistinguishably.
#
# Per feedback_test_isolation_for_hooks_state, every fixture call sets
# HOOKS_STATE_OVERRIDE + PLANS_ROOT_OVERRIDE so we never touch real $HOME state.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$REPO_ROOT/hooks/lib/live-guard.sh"

[[ -x "$GUARD" ]] || { echo "FAIL: $GUARD not executable"; exit 1; }

TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

PLANS_ROOT="$TEST_DIR/.claude-plans"
HOOKS_STATE="$TEST_DIR/.claude/hooks/state"
CLAUDE_HOME="$TEST_DIR/.claude"
NONCE_DIR="$HOOKS_STATE/synthetic-dryrun-nonces"
SENTINEL_PATH="$HOOKS_STATE/.allow-synthetic-dryrun"
DECISIONS_LOG="$HOOKS_STATE/gate-decisions.log"

mkdir -p "$PLANS_ROOT/synthetic-dryrun-plan" "$HOOKS_STATE" "$CLAUDE_HOME" "$NONCE_DIR"

# Init a tag-anchorable git repo at $CLAUDE_HOME for nonce SHA validation
cd "$CLAUDE_HOME"
git init -q .
echo "x" > .gitkeep
git -c user.name=t -c user.email=t@t add .gitkeep
git -c user.name=t -c user.email=t@t commit -q -m initial
git tag synthetic-dryrun/pre-flight
PRE_FLIGHT_SHA=$(git rev-parse synthetic-dryrun/pre-flight)
cd - >/dev/null

# === Synthetic plan: deny match_action, basename_match_env nonce strategy ===
cat > "$PLANS_ROOT/synthetic-dryrun-plan/manifest.json" <<EOF
{
  "schema_version": 1,
  "project": "synthetic-dryrun-plan",
  "spec_path": "x",
  "top_level_status": "in_progress",
  "live_mutation_scope": {
    "enabled": true,
    "schema_version": 1,
    "scope_paths": ["$TEST_DIR/.claude/**"],
    "exempt_paths": ["$TEST_DIR/.claude/projects/**"],
    "detection_signals": {
      "plan_mode_env_var": "SYNTHETIC_DRYRUN_MODE",
      "deterministic_only": true
    },
    "override": {
      "nonce_dir": "$NONCE_DIR",
      "nonce_sha_anchor": "synthetic-dryrun/pre-flight",
      "nonce_min_reason_length": 12,
      "nonce_consume_strategy": "basename_match_env",
      "nonce_affinity_env": "SYNTHETIC_DRYRUN_NONCE_TASK",
      "sentinel_override_path": "$SENTINEL_PATH",
      "bypass_env_var": "SYNTHETIC_DRYRUN_BYPASS"
    },
    "enforcement": {
      "match_action": "deny",
      "error_action": "deny"
    }
  }
}
EOF

# Common invocation env. Sub-tests vary --dry-run, FILE_PATH, nonce/sentinel state.
common_env() {
  HOOKS_STATE_OVERRIDE="$HOOKS_STATE" \
  PLANS_ROOT_OVERRIDE="$PLANS_ROOT" \
  CLAUDE_HOME="$CLAUDE_HOME" \
  HOME="$TEST_DIR/empty-home" \
  SYNTHETIC_DRYRUN_MODE=1 \
  TOOL_NAME="Edit" \
  bash "$GUARD" "$@" </dev/null
}

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $*"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "  FAIL: $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# === Test 1: control — env-var-only invocation still emits production deny ==
echo "Test 1: env-var-only (no --dry-run) production contract preserved"

OUT1=$(FILE_PATH="$TEST_DIR/.claude/file1" common_env 2>&1 || true)
if echo "$OUT1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "env-var path emits deny (production contract intact)"
else
  fail "expected deny via env-var path; got: $OUT1"
fi

# Audit row should NOT have dry_run flag in production path
LAST1=$(tail -1 "$DECISIONS_LOG" 2>/dev/null || echo "{}")
if echo "$LAST1" | jq -e 'has("dry_run") | not' >/dev/null 2>&1; then
  pass "production audit row has no dry_run field"
else
  fail "production audit row unexpectedly carries dry_run: $LAST1"
fi

# === Test 2: --dry-run reports same deny without dry-run-specific field =====
echo "Test 2: --dry-run for in-scope path returns deny + audit dry_run:true"

OUT2=$(common_env --dry-run "$TEST_DIR/.claude/file2" 2>&1 || true)
if echo "$OUT2" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "dry-run emits deny decision JSON"
else
  fail "expected deny in dry-run; got: $OUT2"
fi

LAST2=$(tail -1 "$DECISIONS_LOG")
if echo "$LAST2" | jq -e '.dry_run == true' >/dev/null 2>&1; then
  pass "dry-run audit row carries dry_run: true"
else
  fail "expected dry_run:true in audit row; got: $LAST2"
fi
if echo "$LAST2" | jq -e ".file == \"$TEST_DIR/.claude/file2\"" >/dev/null 2>&1; then
  pass "dry-run audit row records the positional <path> as file"
else
  fail "audit file field mismatch; got: $LAST2"
fi

# === Test 3: --dry-run with nonce + affinity → allow WITHOUT consuming =====
echo "Test 3: --dry-run honors nonce override BUT does not consume the file"

# Plant a valid nonce
NONCE_FILE="$NONCE_DIR/T-3.6-test.nonce"
printf 'T-3.6-test\tdry-run-pre-flight-check\t%s' "$PRE_FLIGHT_SHA" > "$NONCE_FILE"
[[ -f "$NONCE_FILE" ]] || { echo "FAIL: nonce planting failed"; exit 1; }

OUT3=$(SYNTHETIC_DRYRUN_NONCE_TASK="T-3.6-test" \
  common_env --dry-run "$TEST_DIR/.claude/file3" 2>&1 || true)

if echo "$OUT3" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null 2>&1; then
  pass "dry-run with nonce + affinity emits allow"
else
  fail "expected allow; got: $OUT3"
fi
if [[ -f "$NONCE_FILE" ]]; then
  pass "nonce file persists post-call (NOT consumed in dry-run)"
else
  fail "nonce file was consumed in dry-run mode (should persist)"
fi

LAST3=$(tail -1 "$DECISIONS_LOG")
if echo "$LAST3" | jq -e '.dry_run == true and .decision == "allow-override"' >/dev/null 2>&1; then
  pass "dry-run nonce row tagged dry_run:true with allow-override decision"
else
  fail "audit row mismatch; got: $LAST3"
fi

# === Test 4: regression — production env-var path DOES consume the nonce ===
echo "Test 4: production env-var path still consumes nonce (regression)"

# Same nonce still on disk from Test 3.
OUT4=$(SYNTHETIC_DRYRUN_NONCE_TASK="T-3.6-test" \
  FILE_PATH="$TEST_DIR/.claude/file4" \
  common_env 2>&1 || true)

if echo "$OUT4" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null 2>&1; then
  pass "production path emits allow on valid nonce"
else
  fail "expected allow via production path; got: $OUT4"
fi
if [[ ! -f "$NONCE_FILE" ]]; then
  pass "nonce consumed by production path (single-use semantics intact)"
else
  fail "nonce should have been consumed in production path"
fi

# === Test 5: --dry-run with sentinel → allow-sentinel ======================
echo "Test 5: --dry-run with sentinel reports allow-sentinel"

touch "$SENTINEL_PATH"
OUT5=$(common_env --dry-run "$TEST_DIR/.claude/file5" 2>&1 || true)
if echo "$OUT5" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null 2>&1; then
  pass "dry-run with sentinel emits allow"
else
  fail "expected allow; got: $OUT5"
fi
LAST5=$(tail -1 "$DECISIONS_LOG")
if echo "$LAST5" | jq -e '.dry_run == true and .decision == "allow-sentinel"' >/dev/null 2>&1; then
  pass "dry-run sentinel row tagged dry_run:true"
else
  fail "audit row mismatch; got: $LAST5"
fi
[[ -f "$SENTINEL_PATH" ]] || { fail "sentinel was deleted (should persist)"; }
rm -f "$SENTINEL_PATH"

# === Test 6: --dry-run for exempt_paths carve-out → allow-carve-out ========
echo "Test 6: --dry-run for exempt_paths returns allow-carve-out"

EXEMPT_PATH="$TEST_DIR/.claude/projects/foo.md"
mkdir -p "$(dirname "$EXEMPT_PATH")"
OUT6=$(common_env --dry-run "$EXEMPT_PATH" 2>&1 || true)
if echo "$OUT6" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null 2>&1; then
  pass "dry-run for exempt path emits allow"
else
  fail "expected allow; got: $OUT6"
fi
LAST6=$(tail -1 "$DECISIONS_LOG")
if echo "$LAST6" | jq -e '.dry_run == true and .decision == "allow-carve-out"' >/dev/null 2>&1; then
  pass "dry-run exempt-path row tagged dry_run:true"
else
  fail "audit row mismatch; got: $LAST6"
fi

# === Test 7: --dry-run for path NOT under scope → silent pass-through ======
echo "Test 7: --dry-run for out-of-scope path is silent pass-through"

OUT7=$(common_env --dry-run "/tmp/not-under-scope.txt" 2>&1 || true)
if [[ -z "$OUT7" ]]; then
  pass "out-of-scope dry-run yields empty stdout (silent pass-through)"
else
  fail "expected empty stdout; got: $OUT7"
fi

# === Test 8: --dry-run requires <path> argument ============================
echo "Test 8: --dry-run without <path> exits non-zero"

set +e
OUT8=$(common_env --dry-run 2>&1)
RC8=$?
set -e
if [[ "$RC8" != "0" ]] && echo "$OUT8" | grep -q "requires <path>"; then
  pass "missing <path> produces error message + non-zero rc"
else
  fail "expected non-zero rc + error message; got rc=$RC8 out=$OUT8"
fi

# === Test 9: unknown CLI arg also rejected =================================
echo "Test 9: unknown CLI arg rejected"

set +e
OUT9=$(FILE_PATH="$TEST_DIR/.claude/file9" common_env --bogus-flag 2>&1)
RC9=$?
set -e
if [[ "$RC9" != "0" ]] && echo "$OUT9" | grep -q "unknown argument"; then
  pass "unknown arg produces error message + non-zero rc"
else
  fail "expected non-zero rc + error message; got rc=$RC9 out=$OUT9"
fi

echo ""
echo "Results: $PASS_COUNT pass / $FAIL_COUNT fail"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "T-3.6 dry-run-test FAILED"
  exit 1
fi
echo "All T-3.6 dry-run-test assertions PASSED ($PASS_COUNT/$PASS_COUNT)."
echo "SP04 §3.8 writer pre-flight binding-contract gap CLOSED."
exit 0
