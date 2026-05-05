#!/usr/bin/env bash
# tests/greenfield-pipeline/_lib/section-f-fixture.sh — SP16 T-2 hermetic fixture.
#
# Sourced (not executed) by tests/greenfield-pipeline/section-f-*.sh. Centralizes:
#   - $TMPDIR sandbox creation with HOOKS_STATE_OVERRIDE + CLAUDE_HOME +
#     INPUTS_DIR + USER_MANIFEST seeded
#   - synthetic 7-surface stub directory (each stub appends a JSONL record
#     to AUTO_AUTHOR_LOG and exits 0); SURFACE_DIR_OVERRIDE redirects
#     run_section_f at this dir
#   - synthetic IR JSONL emission (zero Peter-isms; alpha/beta clusters)
#   - PASS/FAIL accounting helpers reused from orchestrate-fixture.sh shape
#
# Per `feedback_test_isolation_for_hooks_state`: every test invocation
# isolates HOOKS_STATE under $TMPDIR. Per `feedback_universal_vault_safety`:
# no `~/Documents/Obsidian Vault` touches.
#
# Constraints (R-23): bash 3.2 + stdlib; jq required.

set -u

[ -n "${REPO_ROOT:-}" ] || { echo "_lib/section-f-fixture.sh: REPO_ROOT must be set before sourcing" >&2; exit 2; }

ONBOARD_SH="$REPO_ROOT/skills/onboarder/onboard.sh"
ORCHESTRATE_SH="$REPO_ROOT/skills/infer-vault-structure/orchestrate.sh"

# ---------- PASS/FAIL accounting ----------

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS — %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL — %s\n' "$1" >&2; }

# ---------- sandbox ----------

# Args: <test-name>
# Sets globals: TEST_DIR, CLAUDE_HOME, INPUTS_DIR, USER_MANIFEST,
#               STUB_SURFACE_DIR, AUTO_AUTHOR_LOG, SECTION_F_STATE_DIR
make_sandbox() {
  _name="$1"
  TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sp16-t2-${_name}-$$.XXXXXX")
  trap '[ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ] && rm -rf "$TEST_DIR" 2>/dev/null' EXIT INT TERM

  export CLAUDE_HOME="$TEST_DIR/claude-home"
  export INPUTS_DIR="$CLAUDE_HOME/onboarding"
  export USER_MANIFEST="$CLAUDE_HOME/user-manifest.json"
  export HOOKS_STATE_OVERRIDE="$CLAUDE_HOME/state"
  export AUTO_AUTHOR_LOG="$INPUTS_DIR/auto-author-log.jsonl"
  export SECTION_F_STATE_DIR="$INPUTS_DIR/section-f-state"
  unset ANTHROPIC_API_KEY VOYAGE_API_KEY 2>/dev/null || true
  unset SEED_CONTENT_PATH 2>/dev/null || true

  mkdir -p "$CLAUDE_HOME" "$INPUTS_DIR" "$HOOKS_STATE_OVERRIDE"

  # Seed a minimal user-manifest so onboard.sh's --user-manifest pass-through
  # has a real file. Stub surfaces ignore content; this is shape-only.
  printf '{"identity":{},"vault":{},"projects":{},"system":{"phases_completed":[]}}\n' > "$USER_MANIFEST"

  : > "$AUTO_AUTHOR_LOG"

  STUB_SURFACE_DIR="$TEST_DIR/stub-surfaces"
  mkdir -p "$STUB_SURFACE_DIR"
  emit_stub_surfaces "$STUB_SURFACE_DIR"
}

# Args: <stub-surface-dir>
# Writes 7 stub surface scripts (surface-{1,2,3,4,5,6,9}-stub.sh). Each:
#   - Accepts --user-manifest PATH + --auto-apply + --skip-preview (ignored).
#   - Appends one JSONL record to $AUTO_AUTHOR_LOG with action="apply".
#   - Returns 0.
emit_stub_surfaces() {
  _dir="$1"
  for n in 1 2 3 4 5 6 9; do
    cat > "$_dir/surface-${n}-stub.sh" <<STUB
#!/usr/bin/env bash
# Synthetic SP16-T-2 surface-${n} stub. Appends one apply record.
set -u
: "\${AUTO_AUTHOR_LOG:?AUTO_AUTHOR_LOG must be set}"
mkdir -p "\$(dirname "\$AUTO_AUTHOR_LOG")" 2>/dev/null || true
jq -nc \\
  --arg ts "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" \\
  --arg sid "surface-${n}" \\
  '{ts:\$ts, surface_id:\$sid, action:"apply", target_path:"/dev/null", sha_before:"", sha_after:"", note:"section-f stub"}' \\
  >> "\$AUTO_AUTHOR_LOG"
exit 0
STUB
    chmod +x "$_dir/surface-${n}-stub.sh"
  done
}

# Args: <out-path>
# Writes a 6-record synthetic IR with two clusterable signal groups. Mirrors
# the orchestrate-fixture.sh shape so SP16 T-1's orchestrate.sh can chain
# all 4 stages cleanly under stub mode.
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

# Invoke onboard.sh in single-section-F mode with stub-surface dispatch.
# Args: extra onboard.sh argv (e.g. --skip-auto-author).
invoke_section_f() {
  SURFACE_DIR_OVERRIDE="$STUB_SURFACE_DIR" \
  ONBOARDER_SEED_SLUG="t2test" \
    bash "$ONBOARD_SH" --section f "$@" </dev/null
}

# Args: <state-dir> <comma-separated-surface-numbers>
# Returns 0 if every named surface has its done-marker.
assert_surface_markers() {
  _sd="$1"; _list="$2"
  _ok=1
  _IFS_save="$IFS"
  IFS=,
  for _n in $_list; do
    if [ ! -f "$_sd/surface-${_n}.done" ]; then
      _ok=0
      printf '  missing marker: %s/surface-%s.done\n' "$_sd" "$_n" >&2
    fi
  done
  IFS="$_IFS_save"
  [ "$_ok" = "1" ]
}

# Args: <state-dir>
# Returns 0 if NO surface markers exist (used for --skip-auto-author).
assert_no_surface_markers() {
  _sd="$1"
  if [ ! -d "$_sd" ]; then
    return 0
  fi
  _hits=$(find "$_sd" -maxdepth 1 -type f -name 'surface-*.done' 2>/dev/null | wc -l | tr -d ' ')
  [ "$_hits" = "0" ]
}

emit_summary_and_exit() {
  printf '\n=== %s ===\n' "${TEST_LABEL:-T-2 test}"
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
