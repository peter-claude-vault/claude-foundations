#!/usr/bin/env bash
# onboarding/lib/three-step-gate.sh — SP12 T-1 (Plan 71 SP12 Session 1)
#
# Three-step gate UX library: generate -> preview/edit -> apply.
# Pattern adopted from Capacities + GitHub Copilot Workspace per
# _audit-2026-05-03/06-R1-pkm-bootstrapping.md §4.
#
# Every Group B auto-authoring surface invokes this library to flow LLM-
# composed (or deterministically-composed) artifacts through a mandatory
# preview/edit step before any silent overwrite of a user-facing file.
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - target artifact path (when gate_apply succeeds)
#     - $AUTO_AUTHOR_LOG (default: $FOUNDATION_REPO/onboarding/auto-author-log.jsonl
#       OR ${CLAUDE_HOME:-$HOME/.claude}/onboarding/auto-author-log.jsonl when sourced
#       at runtime; one JSONL record per gate invocation)
#   Schema-types:
#     - audit log line: ad-hoc JSONL (event-log shape) with required keys
#       {ts, surface_id, action, target_path, sha_before, sha_after}
#   Pre-write validation:
#     - target path parent dir is writable
#     - tmp staging file exists and is non-empty (unless explicitly empty render)
#   Failure mode: BLOCK AND LOG.
#     Any IO error returns non-zero. Audit log appended with action="error" when
#     a gate operation fails after staging.
#
# API (sourceable):
#
#   gate_generate <surface-id> <generator-fn> [generator-args...]
#     Calls <generator-fn> with [generator-args...]. The generator MUST emit
#     the proposed artifact bytes on stdout. gate_generate captures stdout to
#     a per-call staging file under $TG_STAGE_DIR/<surface-id>.proposed and
#     echoes that staging path on stdout for the caller to feed into
#     gate_preview / gate_apply. Audit-log entry recorded with action="generate".
#
#   gate_preview <staging-path> <target-path>
#     Renders a unified diff of target-vs-staging when target exists, OR a
#     full-content render of staging when target is absent. Output to stdout
#     so callers can paginate or capture. Audit-log entry recorded with
#     action="preview".
#
#   gate_apply <staging-path> <target-path> [--skip-preview] [--accept-on-empty-stdin]
#     Default flow: render preview to stderr, prompt the user with
#     [a]pply / [e]dit / [s]kip / [b]ort, act on the choice. With
#     --skip-preview the prompt fires without re-rendering the diff (caller
#     already showed it). With --accept-on-empty-stdin (used by smoke tests),
#     EOF on stdin is treated as "apply".
#
#     Choice semantics:
#       a/A or empty Enter   -> apply (mv staging -> target, audit "apply")
#       e/E                  -> open ${EDITOR:-vi} on staging tmp; on save,
#                               re-loop the prompt with the edited content
#       s/S                  -> audit "skip"; do NOT write target; rc=0
#       b/B / q/Q            -> audit "abort"; rc=1
#
#     Returns:
#       0  applied (target written) or skipped (intentional)
#       1  user aborted at prompt
#       2  IO error (could not write target / could not stat / etc.)
#
#   gate_set_dry_run [0|1]
#     Toggle dry-run mode. In dry-run, gate_apply renders the preview and
#     records action="dry-run" but never writes the target. Used by T-16
#     smoke test to walk the full auto-author surface without mutating live.
#
#   gate_audit_path
#     Echo the resolved audit log path. Useful for tests + smoke runs that
#     want to assert log records appended.
#
# Env knobs (override defaults):
#   AUTO_AUTHOR_LOG          Path to JSONL audit log
#                            (default: <foundation-repo or CLAUDE_HOME>/
#                                       onboarding/auto-author-log.jsonl)
#   TG_STAGE_DIR             Per-run staging dir for proposed artifacts
#                            (default: mktemp -d /tmp/three-step-gate.XXXXXX)
#   THREE_STEP_GATE_DRY_RUN  Set to 1 for dry-run mode (alternative to gate_set_dry_run)
#   EDITOR                   Editor invoked at the [e]dit step (default: vi)
#
# CONSTRAINTS (R-23): bash 3.2 — no `declare -A`, no `mapfile`, no `${var,,}`.
# `jq` REQUIRED on PATH; `shasum` or `sha256sum` REQUIRED for audit hashing.
#
# Non-goals:
#   - Not a generator. Library consumes generator stdout; surface scripts own
#     their generation logic. This separation lets the gate be reusable across
#     deterministic + LLM-composed generators alike.
#   - Not a schema validator. Provenance-frontmatter validation is T-2 territory.
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP12 Session 1

set -u

# --- guard against re-source ---
if [ -n "${TG_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
TG_LOADED=1

# --- dependency check (deferred until a gate fn actually fires) ---
_tg_require() {
  local missing=""
  for tool in jq; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  # shasum or sha256sum
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    missing="$missing shasum-or-sha256sum"
  fi
  if [ -n "$missing" ]; then
    printf 'three-step-gate FAIL: missing required tool(s):%s\n' "$missing" >&2
    return 2
  fi
  return 0
}

# --- runtime state ---
TG_DRY_RUN="${THREE_STEP_GATE_DRY_RUN:-0}"

# Resolve audit log: if AUTO_AUTHOR_LOG env override set, use it; else infer
# from foundation-repo location (when sourced from the repo) or fall back to
# CLAUDE_HOME/onboarding (post-install runtime).
_tg_resolve_audit_log() {
  if [ -n "${AUTO_AUTHOR_LOG:-}" ]; then
    printf '%s\n' "$AUTO_AUTHOR_LOG"
    return 0
  fi
  # Heuristic: this script lives at <foundation-repo>/onboarding/lib/three-step-gate.sh.
  # Walk up two parents to find foundation-repo onboarding/.
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  local onboarding_dir
  onboarding_dir="$(cd "$script_dir/.." 2>/dev/null && pwd)"
  if [ -n "$onboarding_dir" ] && [ -d "$onboarding_dir" ]; then
    # Detect foundation-repo vs runtime: foundation-repo has a `bootstrap-schemas.sh` sibling.
    if [ -f "$onboarding_dir/bootstrap-schemas.sh" ]; then
      printf '%s/auto-author-log.jsonl\n' "$onboarding_dir"
      return 0
    fi
  fi
  # Runtime fallback.
  printf '%s/onboarding/auto-author-log.jsonl\n' "${CLAUDE_HOME:-$HOME/.claude}"
}

_tg_init_stage_dir() {
  if [ -z "${TG_STAGE_DIR:-}" ]; then
    TG_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/three-step-gate.XXXXXX")" || return 2
    # Best-effort cleanup: caller (surface script) is responsible for explicit
    # teardown; we install a trap only when the caller hasn't already.
  fi
  mkdir -p "$TG_STAGE_DIR" 2>/dev/null || return 2
  return 0
}

_tg_sha_of() {
  # Echo SHA-256 of file contents. Empty string when file missing.
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  else
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  fi
}

_tg_audit_append() {
  # $1=surface_id $2=action $3=target_path $4=sha_before $5=sha_after [$6=note]
  _tg_require || return 2
  local log
  log="$(_tg_resolve_audit_log)" || return 2
  local log_dir
  log_dir="$(dirname "$log")"
  mkdir -p "$log_dir" 2>/dev/null || {
    printf 'three-step-gate FAIL: cannot create audit log dir: %s\n' "$log_dir" >&2
    return 2
  }
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg surface_id "$1" \
    --arg action "$2" \
    --arg target_path "$3" \
    --arg sha_before "$4" \
    --arg sha_after "$5" \
    --arg note "${6:-}" \
    '{ts:$ts, surface_id:$surface_id, action:$action, target_path:$target_path, sha_before:$sha_before, sha_after:$sha_after, note:$note}' \
    >> "$log" || {
      printf 'three-step-gate FAIL: audit append failed at %s\n' "$log" >&2
      return 2
    }
  return 0
}

# --- public API ---

gate_set_dry_run() {
  TG_DRY_RUN="${1:-1}"
  return 0
}

gate_audit_path() {
  _tg_resolve_audit_log
}

gate_generate() {
  # $1=surface_id $2=generator_fn [args...]
  _tg_require || return 2
  _tg_init_stage_dir || return 2
  local surface_id="$1"; shift
  local generator_fn="$1"; shift
  if [ -z "$surface_id" ] || [ -z "$generator_fn" ]; then
    printf 'gate_generate FAIL: surface_id + generator_fn required\n' >&2
    return 2
  fi
  if ! command -v "$generator_fn" >/dev/null 2>&1 && ! type "$generator_fn" >/dev/null 2>&1; then
    printf 'gate_generate FAIL: generator_fn not callable: %s\n' "$generator_fn" >&2
    return 2
  fi
  local stage_path="$TG_STAGE_DIR/${surface_id}.proposed"
  if ! "$generator_fn" "$@" > "$stage_path"; then
    printf 'gate_generate FAIL: generator returned non-zero for surface %s\n' "$surface_id" >&2
    _tg_audit_append "$surface_id" "error" "$stage_path" "" "" "generator-failure"
    return 2
  fi
  _tg_audit_append "$surface_id" "generate" "$stage_path" "" "$(_tg_sha_of "$stage_path")" || return 2
  printf '%s\n' "$stage_path"
  return 0
}

gate_preview() {
  # $1=staging_path $2=target_path
  _tg_require || return 2
  local stage="$1"
  local target="$2"
  if [ -z "$stage" ] || [ ! -f "$stage" ]; then
    printf 'gate_preview FAIL: staging path missing or not a file: %s\n' "$stage" >&2
    return 2
  fi
  if [ -z "$target" ]; then
    printf 'gate_preview FAIL: target path required\n' >&2
    return 2
  fi
  printf '\n=== three-step gate: PREVIEW ===\n' >&2
  printf 'Surface staging: %s\n' "$stage" >&2
  printf 'Target path:     %s\n' "$target" >&2
  printf '\n' >&2
  if [ -f "$target" ]; then
    printf '%s\n' "--- diff $target vs proposed staging ---" >&2
    diff -u "$target" "$stage" >&2 || true
  else
    printf '%s\n' "--- target absent; full proposed content follows ---" >&2
    cat "$stage" >&2
  fi
  printf '\n=== end PREVIEW ===\n\n' >&2
  # Surface_id is encoded into staging filename (basename minus suffix).
  local sid
  sid="$(basename "$stage" .proposed)"
  _tg_audit_append "$sid" "preview" "$target" "$(_tg_sha_of "$target")" "$(_tg_sha_of "$stage")" || return 2
  return 0
}

_tg_run_editor() {
  # $1=staging_path. Open ${EDITOR:-vi} against the staging file in place.
  local stage="$1"
  local ed="${EDITOR:-vi}"
  if ! command -v "$ed" >/dev/null 2>&1; then
    # Fallback chain.
    for cand in vi nano vim; do
      if command -v "$cand" >/dev/null 2>&1; then ed="$cand"; break; fi
    done
  fi
  if ! command -v "$ed" >/dev/null 2>&1; then
    printf 'three-step-gate FAIL: no editor found (tried $EDITOR, vi, nano, vim)\n' >&2
    return 2
  fi
  "$ed" "$stage"
  return $?
}

gate_apply() {
  # $1=staging_path $2=target_path [--skip-preview] [--accept-on-empty-stdin]
  _tg_require || return 2
  local stage="$1"; shift
  local target="$1"; shift
  local skip_preview=0
  local accept_on_eof=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --skip-preview) skip_preview=1; shift ;;
      --accept-on-empty-stdin) accept_on_eof=1; shift ;;
      *) printf 'gate_apply FAIL: unknown arg: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if [ -z "$stage" ] || [ ! -f "$stage" ]; then
    printf 'gate_apply FAIL: staging path missing or not a file: %s\n' "$stage" >&2
    return 2
  fi
  if [ -z "$target" ]; then
    printf 'gate_apply FAIL: target path required\n' >&2
    return 2
  fi
  local sid
  sid="$(basename "$stage" .proposed)"

  # Dry-run path: render preview (if not already shown) + audit + return 0
  # without writing target.
  if [ "$TG_DRY_RUN" = "1" ]; then
    if [ "$skip_preview" != "1" ]; then
      gate_preview "$stage" "$target" || return $?
    fi
    _tg_audit_append "$sid" "dry-run" "$target" "$(_tg_sha_of "$target")" "$(_tg_sha_of "$stage")" || return 2
    printf 'three-step-gate: dry-run; no apply\n' >&2
    return 0
  fi

  # Loop allows the [e]dit choice to re-prompt after the editor returns.
  while :; do
    if [ "$skip_preview" != "1" ]; then
      gate_preview "$stage" "$target" || return $?
    fi
    printf 'Apply this change? [a]pply (default) / [e]dit / [s]kip / [b]ort: ' >&2
    local choice=""
    if ! IFS= read -r choice; then
      if [ "$accept_on_eof" = "1" ]; then
        choice="a"
      else
        printf 'three-step-gate: stdin EOF; aborting (use --accept-on-empty-stdin to default-apply)\n' >&2
        _tg_audit_append "$sid" "abort" "$target" "$(_tg_sha_of "$target")" "$(_tg_sha_of "$stage")" "stdin-eof" || return 2
        return 1
      fi
    fi
    case "$choice" in
      ""|a|A)
        # Apply.
        local target_dir
        target_dir="$(dirname "$target")"
        if [ ! -d "$target_dir" ]; then
          mkdir -p "$target_dir" 2>/dev/null || {
            printf 'gate_apply FAIL: cannot create target dir: %s\n' "$target_dir" >&2
            _tg_audit_append "$sid" "error" "$target" "$(_tg_sha_of "$target")" "$(_tg_sha_of "$stage")" "mkdir-failed" || true
            return 2
          }
        fi
        local sha_before sha_after
        sha_before="$(_tg_sha_of "$target")"
        # Atomic write via .tmp+rename on same filesystem.
        local final_tmp="${target}.tmp.$$"
        if ! cp "$stage" "$final_tmp"; then
          printf 'gate_apply FAIL: could not stage final tmp at %s\n' "$final_tmp" >&2
          _tg_audit_append "$sid" "error" "$target" "$sha_before" "" "stage-tmp-failed" || true
          return 2
        fi
        if ! mv "$final_tmp" "$target"; then
          printf 'gate_apply FAIL: could not mv tmp -> target: %s\n' "$target" >&2
          rm -f "$final_tmp" 2>/dev/null
          _tg_audit_append "$sid" "error" "$target" "$sha_before" "" "rename-failed" || true
          return 2
        fi
        sha_after="$(_tg_sha_of "$target")"
        _tg_audit_append "$sid" "apply" "$target" "$sha_before" "$sha_after" || return 2
        printf 'three-step-gate: applied to %s\n' "$target" >&2
        return 0
        ;;
      e|E)
        if ! _tg_run_editor "$stage"; then
          printf 'three-step-gate: editor returned non-zero; re-prompting\n' >&2
        fi
        # Re-loop with the (possibly edited) staging content. Don't skip preview
        # next round — user wants to see the post-edit diff.
        skip_preview=0
        continue
        ;;
      s|S)
        _tg_audit_append "$sid" "skip" "$target" "$(_tg_sha_of "$target")" "$(_tg_sha_of "$stage")" || return 2
        printf 'three-step-gate: skipped %s\n' "$target" >&2
        return 0
        ;;
      b|B|q|Q)
        _tg_audit_append "$sid" "abort" "$target" "$(_tg_sha_of "$target")" "$(_tg_sha_of "$stage")" || return 2
        printf 'three-step-gate: aborted at %s\n' "$target" >&2
        return 1
        ;;
      *)
        printf 'three-step-gate: invalid choice "%s"; press a, e, s, or b\n' "$choice" >&2
        # Keep skip_preview where it was; loop again.
        ;;
    esac
  done
}

# --- self-test entrypoint (only when invoked directly with --self-test) ---
# Allows `bash three-step-gate.sh --self-test` to run a synthetic gate cycle
# against an isolated tmpdir. Used by SP12 T-1 acceptance verification.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    --self-test)
      shift
      # Force isolated audit log + stage dir so the test is hermetic.
      _TG_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/three-step-gate-self.XXXXXX")"
      export AUTO_AUTHOR_LOG="$_TG_TEST_DIR/audit.jsonl"
      export TG_STAGE_DIR="$_TG_TEST_DIR/stage"
      mkdir -p "$TG_STAGE_DIR"
      _target="$_TG_TEST_DIR/target.txt"
      noop_gen() { printf 'hello world\n'; }
      _stage="$(gate_generate self-test noop_gen)" || { echo "FAIL: gate_generate" >&2; exit 1; }
      gate_preview "$_stage" "$_target" || { echo "FAIL: gate_preview" >&2; exit 1; }
      gate_set_dry_run 1
      gate_apply "$_stage" "$_target" --skip-preview || { echo "FAIL: gate_apply dry-run" >&2; exit 1; }
      [ ! -f "$_target" ] || { echo "FAIL: dry-run wrote target" >&2; exit 1; }
      gate_set_dry_run 0
      printf 'a\n' | gate_apply "$_stage" "$_target" --skip-preview || { echo "FAIL: gate_apply piped-apply" >&2; exit 1; }
      [ -f "$_target" ] || { echo "FAIL: target not written after apply" >&2; exit 1; }
      grep -q 'hello world' "$_target" || { echo "FAIL: target content mismatch" >&2; exit 1; }
      records="$(wc -l < "$AUTO_AUTHOR_LOG" | tr -d ' ')"
      # Expected records: generate + preview + dry-run + apply = 4 minimum.
      [ "$records" -ge 4 ] || { echo "FAIL: audit log expected >=4 records, got $records" >&2; exit 1; }
      # Also verify rejection-non-zero semantics: pipe 'b' to a fresh apply.
      _stage2="$(gate_generate self-test-reject noop_gen)" || { echo "FAIL: gen for reject" >&2; exit 1; }
      _target2="$_TG_TEST_DIR/target2.txt"
      if printf 'b\n' | gate_apply "$_stage2" "$_target2" --skip-preview; then
        echo "FAIL: gate_apply abort returned rc=0 (expected non-zero)" >&2; exit 1
      fi
      [ ! -f "$_target2" ] || { echo "FAIL: abort wrote target2" >&2; exit 1; }
      printf 'self-test PASS: stage=%s target=%s audit=%s records=%s\n' \
        "$_stage" "$_target" "$AUTO_AUTHOR_LOG" "$records"
      rm -rf "$_TG_TEST_DIR"
      exit 0
      ;;
    "") : ;;
    *) printf 'three-step-gate: unknown direct invocation arg: %s\n' "$1" >&2; exit 2 ;;
  esac
fi
