#!/usr/bin/env bash
# tests/greenfield-pipeline/_lib/orchestrate-fixture.sh
#
# Shared helper for SP16 T-1 hermetic orchestrate.sh tests. Sourced (not
# executed) by each tests/greenfield-pipeline/orchestrate-*.sh script. Centralizes:
#   - synthetic IR JSONL emission (zero Peter-isms; alpha/beta/gamma synthetic)
#   - $TMPDIR sandbox creation with HOOKS_STATE_OVERRIDE + CLAUDE_HOME
#   - stub-mode env (unset ANTHROPIC_API_KEY / VOYAGE_API_KEY)
#   - PASS/FAIL accounting helpers
#
# Per `feedback_test_isolation_for_hooks_state` (R-26 lineage, SP09 S22 source):
# every test invocation isolates HOOKS_STATE under $TMPDIR — no production
# `~/.claude/` writes. Per `feedback_universal_vault_safety`: no
# `~/Documents/Obsidian Vault` touches.
#
# Constraints (R-23): bash 3.2 + stdlib; jq + python3 required.

set -u

# Caller MUST export REPO_ROOT before sourcing.
[ -n "${REPO_ROOT:-}" ] || { echo "_lib/orchestrate-fixture.sh: REPO_ROOT must be set before sourcing" >&2; exit 2; }

ORCHESTRATE_SH="$REPO_ROOT/skills/infer-vault-structure/orchestrate.sh"

# ---------- PASS/FAIL accounting ----------

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS — %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL — %s\n' "$1" >&2; }

# ---------- sandbox setup ----------

# Args: <test-name>
# Sets globals: TEST_DIR, IR_PATH, STATE_DIR_EXPECTED, INFERRED_DIR
make_sandbox() {
  _name="$1"
  TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sp16-t1-${_name}-$$.XXXXXX")
  trap '[ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ] && rm -rf "$TEST_DIR" 2>/dev/null' EXIT INT TERM

  export CLAUDE_HOME="$TEST_DIR/claude-home"
  export HOOKS_STATE_OVERRIDE="$CLAUDE_HOME/state"
  unset ANTHROPIC_API_KEY VOYAGE_API_KEY 2>/dev/null || true

  mkdir -p "$CLAUDE_HOME" "$HOOKS_STATE_OVERRIDE"

  IR_PATH="$TEST_DIR/ir.jsonl"
  emit_synthetic_ir "$IR_PATH"

  INFERRED_DIR="$CLAUDE_HOME/projects/$_name/inferred"
}

# Args: <out-path>
# Writes a 6-record synthetic IR with two clusterable signal groups. Zero
# Peter-isms; nothing client-identifiable.
emit_synthetic_ir() {
  _out="$1"
  cat > "$_out" <<'IR_JSONL'
{"path":"/syn/alpha-1.md","format":"markdown","detected_at":"2026-05-05T10:00:00Z","raw_bytes":120,"normalized_text":"alpha engagement strategy growth analytics customer expansion","metadata":{},"source_hash":"sha256-aaaa1111"}
{"path":"/syn/alpha-2.md","format":"markdown","detected_at":"2026-05-05T10:01:00Z","raw_bytes":118,"normalized_text":"alpha team growth analytics workstream stakeholder engagement","metadata":{},"source_hash":"sha256-aaaa2222"}
{"path":"/syn/alpha-3.md","format":"markdown","detected_at":"2026-05-05T10:02:00Z","raw_bytes":115,"normalized_text":"alpha engagement strategy customer growth analytics quarterly","metadata":{},"source_hash":"sha256-aaaa3333"}
{"path":"/syn/beta-1.md","format":"markdown","detected_at":"2026-05-05T10:03:00Z","raw_bytes":140,"normalized_text":"beta launch readiness rollout enterprise pilot deployment","metadata":{},"source_hash":"sha256-bbbb1111"}
{"path":"/syn/beta-2.md","format":"markdown","detected_at":"2026-05-05T10:04:00Z","raw_bytes":135,"normalized_text":"beta enterprise rollout launch readiness gating pilot windows","metadata":{},"source_hash":"sha256-bbbb2222"}
{"path":"/syn/beta-3.md","format":"markdown","detected_at":"2026-05-05T10:05:00Z","raw_bytes":138,"normalized_text":"beta launch enterprise rollout sequence readiness sign-off","metadata":{},"source_hash":"sha256-bbbb3333"}
IR_JSONL
}

# Convenience: invoke orchestrate.sh with stub-mode defaults + isolated plan-tree.
# Args: <slug> [extra-orchestrate-flags...]
# Caller is responsible for setting REVIEW_GATE_PROMPT_CHOICE / REVIEW_GATE_ACCEPT_ON_EOF
# and redirecting stdin appropriately.
invoke_orchestrate_stub() {
  _slug="$1"; shift
  "$ORCHESTRATE_SH" \
    --slug "$_slug" \
    --ir-path "$IR_PATH" \
    --llm-mode stub \
    --embedding-mode stub \
    --min-cluster-size 2 \
    "$@"
}

# Args: <log-path> <expected-stage>
# Returns 0 if the most recent record for <expected-stage> in the JSONL log
# has the right shape (timestamp + stage + exit_code + duration_ms +
# evidence_path keys present).
assert_log_record_shape() {
  _log="$1"; _stage="$2"
  jq -se --arg s "$_stage" '
    map(select(.stage == $s)) | last |
      (has("timestamp") and has("stage") and has("exit_code")
       and has("duration_ms") and has("evidence_path"))
  ' < "$_log" >/dev/null 2>&1
}

# Args: <state-dir> <comma-separated stage list>
# Returns 0 if every named stage has a state/<stage>.done marker.
assert_markers_exist() {
  _sd="$1"; _stages="$2"
  _ok=1
  _IFS_save="$IFS"
  IFS=,
  for _st in $_stages; do
    if [ ! -f "$_sd/state/${_st}.done" ]; then
      _ok=0
      printf '  missing marker: %s/state/%s.done\n' "$_sd" "$_st" >&2
    fi
  done
  IFS="$_IFS_save"
  [ "$_ok" = "1" ]
}

# Final summary line — caller invokes at end-of-test.
emit_summary_and_exit() {
  printf '\n=== %s ===\n' "${TEST_LABEL:-T-1 test}"
  printf 'PASS: %d\n' "$PASS_COUNT"
  printf 'FAIL: %d\n' "$FAIL_COUNT"
  if [ "$FAIL_COUNT" = "0" ] && [ "$PASS_COUNT" -gt 0 ]; then
    printf 'PASS 1/1 — %s\n' "${TEST_LABEL:-test}"
    exit 0
  else
    printf 'FAIL — %s\n' "${TEST_LABEL:-test}" >&2
    exit 1
  fi
}
