#!/usr/bin/env bash
# lib/consultation-gate.sh — SP15 T-1 (Plan 71 SP15 Session 1)
#
# Consultation gate UX library: propose-with-rationale -> discuss -> generate.
# Wraps SP12's three-step gate (generate -> preview -> apply) for foundational
# decisions where users deserve research-backed rationale before sign-off.
#
# Pattern: composition. Never forks lib/three-step-gate.sh; sources it and
# orchestrates an upstream rationale gate ahead of the existing 3-step chain.
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - $AUTO_AUTHOR_LOG (delegated to onboarding/lib/three-step-gate.sh; the
#       new "consult" action records appended alongside existing
#       generate/preview/apply/skip/abort/dry-run/error records)
#     - target artifact path (only when consultation accepts AND gate_apply
#       succeeds — same as the underlying 3-step gate)
#   Schema-types:
#     - audit log line for "consult" action: {ts, surface_id, action,
#       rationale_sha, response, response_text}
#   Pre-write validation:
#     - rationale_fn + generator_fn callable in current shell
#     - rationale_fn produces stdout to a buffer file
#     - CG_TARGET_PATH env var set when accept-path orchestrates the 3-step gate
#   Failure mode: BLOCK AND LOG. IO errors return non-zero; an error to the
#     audit log is appended on the underlying gate's error contract.
#
# API (sourceable):
#
#   consultation_propose <surface-id> <rationale-fn> <generator-fn> [generator-args...]
#     1. Invokes <rationale-fn> with no args; captures stdout to a rationale
#        buffer (mktemp file).
#     2. Renders the buffer to stderr (formatted block with header/footer).
#     3. Captures user disposition from stdin: [a]ccept (default) / [r]eject /
#        [e]dit-rationale.
#     4. On accept: appends consult/accept audit record (rationale_sha = sha256
#        of buffer at acceptance), then orchestrates the 3-step gate:
#           gate_generate <surface-id> <generator-fn> [generator-args...]
#           gate_preview  <stage> $CG_TARGET_PATH
#           gate_apply    <stage> $CG_TARGET_PATH --skip-preview
#        Requires CG_TARGET_PATH env var. Generator-fn invocation count = 1.
#     5. On reject: appends consult/reject audit record; rc=1; gate_generate
#        is NOT invoked (mock-generator-fn invocation count stays 0 — AC4).
#     6. On edit: opens ${EDITOR:-vi} on the rationale buffer; appends a
#        consult/edit audit record (rationale_sha re-hashed post-edit); loops
#        back to step 2. Edit may repeat until user accepts or rejects.
#
#     Returns:
#       0  consultation accepted; full gate chain succeeded (or gate_apply [s]kip)
#       1  consultation rejected OR gate_apply aborted
#       2  IO/lib error (rationale_fn failed, missing CG_TARGET_PATH on accept,
#          missing tool, etc.)
#
# Audit-log shape for new "consult" action (one JSONL record per state):
#   {
#     "ts":             ISO-8601 UTC timestamp
#     "surface_id":     surface identifier (e.g., "surface-3-vault-claude-md")
#     "action":         literal "consult"
#     "rationale_sha":  sha256 of rationale buffer at the moment of action
#     "response":       "accept" | "reject" | "edit"
#     "response_text":  optional free-text comment ("" when none)
#   }
# Heterogeneous JSONL: lib/three-step-gate.sh records carry different fields
# (target_path, sha_before, sha_after, note). Both shapes coexist in the same
# log file; the action field discriminates. Consumers select by action.
#
# Env knobs:
#   CG_TARGET_PATH      Required for accept-path orchestration (target artifact
#                       path passed to gate_preview + gate_apply). NOT required
#                       for reject-only paths.
#   CG_ALLOWLIST_PATH   Override allowlist file path (default:
#                       $_cg_repo_root/lib/consultation-gate.allowlist).
#                       Test-isolation knob; production callers leave unset.
#   CG_RATIONALE_SHA    EXPORTED by consultation_propose accept-path before
#                       invoking gate_generate; cleared once gate_apply
#                       returns. Generator functions read this and pass it
#                       to `pf_emit --response-hash` so the artifact's
#                       provenance frontmatter records the rationale digest
#                       the user signed off on (SP15 T-4 contract). DO NOT
#                       set externally.
#   CG_CONSULTED_AT     EXPORTED alongside CG_RATIONALE_SHA. ISO-8601 UTC
#                       timestamp; same string as the audit-log accept
#                       record's `ts` field (single source of truth).
#                       Generator functions read this and pass it to
#                       `pf_emit --consulted-at` (SP15 T-4 contract).
#                       Cleared once gate_apply returns. DO NOT set externally.
#   AUTO_AUTHOR_LOG     Inherited from three-step-gate.sh (audit log path).
#   TG_STAGE_DIR        Inherited (per-call staging dir for proposed artifacts).
#   EDITOR              Editor invoked at [e]dit (default: vi).
#
# CONSTRAINTS (R-23): bash 3.2 — no `declare -A`, no `mapfile`, no `${var,,}`.
# `jq` REQUIRED on PATH (also a three-step-gate.sh dep). `shasum` or
# `sha256sum` REQUIRED for rationale hashing.
#
# Allowlist (SP15 T-2): consultation_propose checks the foundational-decision
# allowlist FIRST — before _cg_require, before rationale_fn invocation. Non-
# allowlisted surface-id returns rc=2 + an audit-log {action:"consult-blocked",
# reason:"not-allowlisted"} record (sibling to the consult-action shape; see
# _cg_audit_log_blocked). Default allowlist file:
#   $_cg_repo_root/lib/consultation-gate.allowlist
# Override via env $CG_ALLOWLIST_PATH (intended for self-test isolation only —
# production callers must let the default resolve). Modifying the allowlist
# file requires peter_diff_review on the modifying task. Rationale grounding
# (consent fatigue, Boehm cost-of-change, status-quo bias) lives as an inline
# comment block at the top of the allowlist file.
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP15 Sessions 1 (T-1) + 2 (T-2) + 4 (T-4)

set -u

# --- guard against re-source ---
if [ -n "${CG_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
CG_LOADED=1

# --- locate + source three-step-gate.sh (composition, never fork) ---
_cg_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_cg_repo_root="$(cd "$_cg_script_dir/.." 2>/dev/null && pwd)"
_cg_gate_lib="$_cg_repo_root/onboarding/lib/three-step-gate.sh"
if [ ! -r "$_cg_gate_lib" ]; then
  printf 'consultation-gate FAIL: three-step-gate.sh not readable at %s\n' "$_cg_gate_lib" >&2
  return 2 2>/dev/null || exit 2
fi
# shellcheck source=/dev/null
. "$_cg_gate_lib"

# --- private helpers ---

_cg_require() {
  command -v jq >/dev/null 2>&1 || {
    printf 'consultation-gate FAIL: jq required on PATH\n' >&2
    return 2
  }
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    printf 'consultation-gate FAIL: shasum or sha256sum required\n' >&2
    return 2
  fi
  return 0
}

_cg_sha_of() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  else
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  fi
}

_cg_audit_log() {
  # $1=surface_id $2=rationale_sha $3=response $4=response_text(optional) $5=ts(optional)
  # SP15 T-4: $5 is an optional pre-captured ISO-8601 UTC timestamp. The
  # accept-path passes the same `consulted_at` value it exports as
  # CG_CONSULTED_AT, so the audit record's ts and the env var byte-match
  # (single source of truth). Reject/edit paths omit $5 → fall back to a
  # fresh `date -u` (preserves pre-T-4 byte-for-byte behavior).
  _cg_require || return 2
  local log
  log="$(gate_audit_path)" || return 2
  local log_dir
  log_dir="$(dirname "$log")"
  mkdir -p "$log_dir" 2>/dev/null || {
    printf 'consultation-gate FAIL: cannot create audit log dir: %s\n' "$log_dir" >&2
    return 2
  }
  local _ts="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  jq -nc \
    --arg ts "$_ts" \
    --arg surface_id "$1" \
    --arg action "consult" \
    --arg rationale_sha "$2" \
    --arg response "$3" \
    --arg response_text "${4:-}" \
    '{ts:$ts, surface_id:$surface_id, action:$action, rationale_sha:$rationale_sha, response:$response, response_text:$response_text}' \
    >> "$log" || {
      printf 'consultation-gate FAIL: audit append failed at %s\n' "$log" >&2
      return 2
    }
  return 0
}

_cg_render_rationale() {
  # $1=rationale_buf
  printf '\n=== consultation gate: PROPOSAL + RATIONALE ===\n' >&2
  cat "$1" >&2
  printf '\n=== end PROPOSAL ===\n' >&2
}

# Resolve allowlist path with $CG_ALLOWLIST_PATH override, fallback to
# $_cg_repo_root/lib/consultation-gate.allowlist.
_cg_allowlist_path() {
  printf '%s\n' "${CG_ALLOWLIST_PATH:-$_cg_repo_root/lib/consultation-gate.allowlist}"
}

# Return 0 if surface-id appears as an exact-match line in the allowlist
# (after stripping `#`-prefixed comments and blank lines). Return 1 on miss
# OR when the allowlist file is unreadable (fail-closed: missing allowlist
# means nothing is allowlisted).
_cg_check_allowlist() {
  local surface_id="$1"
  local allowlist
  allowlist="$(_cg_allowlist_path)"
  if [ ! -r "$allowlist" ]; then
    printf 'consultation-gate FAIL: allowlist not readable at %s\n' "$allowlist" >&2
    return 1
  fi
  # Strip comments + blank lines + leading/trailing whitespace, then exact-match.
  # `grep -Fxq` = fixed-string, full-line, quiet.
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' "$allowlist" \
    | grep -Fxq "$surface_id"
}

_cg_audit_log_blocked() {
  # $1=surface_id $2=reason
  # Sibling of _cg_audit_log carrying a different schema:
  #   {ts, surface_id, action:"consult-blocked", reason}
  # No rationale_sha / response fields — block fires before rationale_fn runs.
  _cg_require || return 2
  local log
  log="$(gate_audit_path)" || return 2
  local log_dir
  log_dir="$(dirname "$log")"
  mkdir -p "$log_dir" 2>/dev/null || {
    printf 'consultation-gate FAIL: cannot create audit log dir: %s\n' "$log_dir" >&2
    return 2
  }
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg surface_id "$1" \
    --arg action "consult-blocked" \
    --arg reason "$2" \
    '{ts:$ts, surface_id:$surface_id, action:$action, reason:$reason}' \
    >> "$log" || {
      printf 'consultation-gate FAIL: audit append failed at %s\n' "$log" >&2
      return 2
    }
  return 0
}

_cg_run_editor() {
  local buf="$1"
  local ed="${EDITOR:-vi}"
  if ! command -v "$ed" >/dev/null 2>&1; then
    for cand in vi nano vim; do
      if command -v "$cand" >/dev/null 2>&1; then ed="$cand"; break; fi
    done
  fi
  if ! command -v "$ed" >/dev/null 2>&1; then
    printf 'consultation-gate FAIL: no editor found (tried $EDITOR, vi, nano, vim)\n' >&2
    return 2
  fi
  "$ed" "$buf"
  return $?
}

# --- public API ---

consultation_propose() {
  # $1=surface_id $2=rationale_fn $3=generator_fn [generator-args...]
  local surface_id="${1:-}"
  local rationale_fn="${2:-}"
  local generator_fn="${3:-}"
  if [ -z "$surface_id" ] || [ -z "$rationale_fn" ] || [ -z "$generator_fn" ]; then
    printf 'consultation_propose FAIL: surface_id + rationale_fn + generator_fn required\n' >&2
    return 2
  fi
  shift 3

  # Allowlist check FIRST (T-2): non-allowlisted surface returns rc=2 + audit
  # consult-blocked entry. Fires before _cg_require + before rationale_fn so
  # gate-creep attempts cost nothing beyond a log line.
  if ! _cg_check_allowlist "$surface_id"; then
    _cg_audit_log_blocked "$surface_id" "not-allowlisted" || :
    printf 'consultation_propose BLOCKED: surface_id "%s" not on allowlist (%s)\n' \
      "$surface_id" "$(_cg_allowlist_path)" >&2
    return 2
  fi

  _cg_require || return 2
  if ! command -v "$rationale_fn" >/dev/null 2>&1 && ! type "$rationale_fn" >/dev/null 2>&1; then
    printf 'consultation_propose FAIL: rationale_fn not callable: %s\n' "$rationale_fn" >&2
    return 2
  fi
  if ! command -v "$generator_fn" >/dev/null 2>&1 && ! type "$generator_fn" >/dev/null 2>&1; then
    printf 'consultation_propose FAIL: generator_fn not callable: %s\n' "$generator_fn" >&2
    return 2
  fi

  # Rationale buffer. Re-evaluated at every [e]dit (sha changes).
  local rationale_buf
  rationale_buf="$(mktemp "${TMPDIR:-/tmp}/consultation-gate-rationale.XXXXXX")" || {
    printf 'consultation_propose FAIL: mktemp rationale buffer\n' >&2
    return 2
  }
  if ! "$rationale_fn" > "$rationale_buf"; then
    printf 'consultation_propose FAIL: rationale_fn returned non-zero\n' >&2
    rm -f "$rationale_buf" 2>/dev/null
    return 2
  fi

  local choice rationale_sha consulted_at rc stage_path
  while :; do
    _cg_render_rationale "$rationale_buf"
    printf '\nAccept this proposal? [a]ccept (default) / [r]eject / [e]dit-rationale: ' >&2
    if ! IFS= read -r choice; then
      # stdin EOF — treat as reject (conservative; never silently accept)
      printf 'consultation-gate: stdin EOF; treating as reject\n' >&2
      choice="r"
    fi
    case "$choice" in
      ""|a|A)
        # SP15 T-4: capture consulted_at ONCE, then thread the same value
        # through (a) the audit-log accept record's ts and (b) the
        # CG_CONSULTED_AT env var the generator reads. Single source of
        # truth — env var byte-matches audit record on disk.
        rationale_sha="$(_cg_sha_of "$rationale_buf")"
        consulted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if ! _cg_audit_log "$surface_id" "$rationale_sha" "accept" "" "$consulted_at"; then
          rm -f "$rationale_buf" 2>/dev/null
          return 2
        fi
        if [ -z "${CG_TARGET_PATH:-}" ]; then
          printf 'consultation_propose FAIL: CG_TARGET_PATH env var must be set for accept-path orchestration\n' >&2
          rm -f "$rationale_buf" 2>/dev/null
          return 2
        fi
        # Export consultation values for the generator. gen_<surface>()
        # functions read these and pass to `pf_emit --consulted-at +
        # --response-hash` so the output frontmatter records the
        # consultation event (SP15 T-3 schema fields). Always unset
        # on return so values do not leak to the parent shell.
        export CG_RATIONALE_SHA="$rationale_sha"
        export CG_CONSULTED_AT="$consulted_at"
        if ! stage_path="$(gate_generate "$surface_id" "$generator_fn" "$@")"; then
          unset CG_RATIONALE_SHA CG_CONSULTED_AT
          rm -f "$rationale_buf" 2>/dev/null
          return 2
        fi
        if ! gate_preview "$stage_path" "$CG_TARGET_PATH"; then
          unset CG_RATIONALE_SHA CG_CONSULTED_AT
          rm -f "$rationale_buf" 2>/dev/null
          return 2
        fi
        gate_apply "$stage_path" "$CG_TARGET_PATH" --skip-preview
        rc=$?
        unset CG_RATIONALE_SHA CG_CONSULTED_AT
        rm -f "$rationale_buf" 2>/dev/null
        return $rc
        ;;
      r|R)
        rationale_sha="$(_cg_sha_of "$rationale_buf")"
        if ! _cg_audit_log "$surface_id" "$rationale_sha" "reject" ""; then
          rm -f "$rationale_buf" 2>/dev/null
          return 2
        fi
        rm -f "$rationale_buf" 2>/dev/null
        return 1
        ;;
      e|E)
        if ! _cg_run_editor "$rationale_buf"; then
          printf 'consultation-gate: editor returned non-zero; re-prompting\n' >&2
        fi
        rationale_sha="$(_cg_sha_of "$rationale_buf")"
        if ! _cg_audit_log "$surface_id" "$rationale_sha" "edit" ""; then
          rm -f "$rationale_buf" 2>/dev/null
          return 2
        fi
        # Loop back to render + prompt with the (possibly edited) buffer.
        continue
        ;;
      *)
        printf 'consultation-gate: invalid choice "%s"; press a, r, or e\n' "$choice" >&2
        # Loop again without re-rendering (keep prompt context tight).
        ;;
    esac
  done
}

# --- self-test entrypoint ---
# `bash consultation-gate.sh --self-test` runs accept/reject/edit-then-accept
# paths against a hermetic tmpdir with mock rationale_fn + mock generator_fn.
# Verifies AC2 (callable; paths work), AC3 (audit log shape), AC4 (no
# gate_generate on reject), AC6 (self-test passes).
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    --self-test)
      shift
      _CG_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/consultation-gate-self.XXXXXX")"
      export AUTO_AUTHOR_LOG="$_CG_TEST_DIR/audit.jsonl"
      export TG_STAGE_DIR="$_CG_TEST_DIR/stage"
      mkdir -p "$TG_STAGE_DIR"
      export CG_TARGET_PATH="$_CG_TEST_DIR/target.txt"
      # Hermetic editor: no-op (preserves buffer contents). Tests the [e]dit
      # control-flow path, not editor UX.
      export EDITOR=":"

      # Hermetic allowlist (T-2): "self-test" surface for sub-tests 1-3 +
      # the 4 production entries. Keeps the production allowlist out of the
      # test environment per feedback_test_isolation_for_hooks_state.
      export CG_ALLOWLIST_PATH="$_CG_TEST_DIR/allowlist"
      cat > "$CG_ALLOWLIST_PATH" <<'ALLOWLIST'
# self-test allowlist
self-test
surface-3-vault-claude-md
surface-4-tag-prefixes
surface-6-frontmatter-enforce
sp13-stage-2-5-import-plan
ALLOWLIST

      # Mock rationale_fn: emits canned proposal + citation block on stdout.
      mock_rationale() {
        printf 'PROPOSAL: tag prefixes = engagement, project, scope (3 prefixes)\n'
        printf 'RATIONALE: Cowan (2001) working memory cap 4 +/- 1 supports keeping\n'
        printf '           top-level taxonomy at single digits.\n'
        printf 'CITATION: Cowan, N. (2001). The magical number 4 in short-term memory.\n'
      }

      # Mock generator_fn: increments a count file each time it fires + emits
      # canned content on stdout. Count file lets us verify AC4 (no fire on
      # reject) and AC2 (does fire on accept).
      _gen_count_file="$_CG_TEST_DIR/gen-count"
      printf '0\n' > "$_gen_count_file"
      mock_generator() {
        local n
        n=$(cat "$_gen_count_file")
        echo $((n + 1)) > "$_gen_count_file"
        printf 'mock-generator-output\n'
      }
      get_gen_count() { cat "$_gen_count_file"; }

      # --- Sub-test 1: accept path ---
      # Stdin feed: first 'a' -> consultation_propose accepts rationale;
      # second 'a' -> gate_apply accepts the staged artifact.
      printf 'a\na\n' | consultation_propose self-test mock_rationale mock_generator || {
        echo "FAIL: accept path rc=$? (expected 0)" >&2; exit 1; }
      [ -f "$CG_TARGET_PATH" ] || { echo "FAIL: target not written on accept" >&2; exit 1; }
      grep -q 'mock-generator-output' "$CG_TARGET_PATH" || {
        echo "FAIL: target content mismatch" >&2; exit 1; }
      [ "$(get_gen_count)" = "1" ] || {
        echo "FAIL: generator count after accept != 1 (got $(get_gen_count))" >&2; exit 1; }

      # --- Sub-test 2: reject path ---
      rm -f "$CG_TARGET_PATH"
      printf '0\n' > "$_gen_count_file"
      if printf 'r\n' | consultation_propose self-test mock_rationale mock_generator; then
        echo "FAIL: reject path returned rc=0 (expected 1)" >&2; exit 1
      fi
      [ ! -f "$CG_TARGET_PATH" ] || {
        echo "FAIL: reject path wrote target" >&2; exit 1; }
      [ "$(get_gen_count)" = "0" ] || {
        echo "FAIL: generator count after reject != 0 (got $(get_gen_count)) [AC4 BREACH]" >&2; exit 1; }

      # --- Sub-test 3: edit-then-accept path (EDITOR=':' no-ops the file) ---
      rm -f "$CG_TARGET_PATH"
      printf '0\n' > "$_gen_count_file"
      printf 'e\na\na\n' | consultation_propose self-test mock_rationale mock_generator || {
        echo "FAIL: edit-then-accept rc=$? (expected 0)" >&2; exit 1; }
      [ -f "$CG_TARGET_PATH" ] || {
        echo "FAIL: edit-accept did not write target" >&2; exit 1; }
      [ "$(get_gen_count)" = "1" ] || {
        echo "FAIL: edit-accept generator count != 1 (got $(get_gen_count))" >&2; exit 1; }

      # --- Sub-test 4: audit log shape (AC3) ---
      records="$(wc -l < "$AUTO_AUTHOR_LOG" | tr -d ' ')"
      [ "$records" -ge 6 ] || {
        echo "FAIL: audit log <6 records (got $records)" >&2; exit 1; }

      # Verify at least one consult record per response type.
      grep -q '"action":"consult"' "$AUTO_AUTHOR_LOG" || {
        echo "FAIL: no consult action in audit log" >&2; exit 1; }
      grep -q '"response":"accept"' "$AUTO_AUTHOR_LOG" || {
        echo "FAIL: no consult/accept record" >&2; exit 1; }
      grep -q '"response":"reject"' "$AUTO_AUTHOR_LOG" || {
        echo "FAIL: no consult/reject record" >&2; exit 1; }
      grep -q '"response":"edit"' "$AUTO_AUTHOR_LOG" || {
        echo "FAIL: no consult/edit record" >&2; exit 1; }

      # Verify rationale_sha is non-empty on every consult record.
      if grep '"action":"consult"' "$AUTO_AUTHOR_LOG" | grep -q '"rationale_sha":""'; then
        echo "FAIL: a consult record has empty rationale_sha" >&2; exit 1
      fi

      # Verify the consult record carries all expected fields (per spec
      # action shape: ts, surface_id, action, rationale_sha, response, response_text).
      sample="$(grep -m1 '"action":"consult"' "$AUTO_AUTHOR_LOG")"
      for field in ts surface_id action rationale_sha response response_text; do
        printf '%s' "$sample" | grep -q "\"$field\":" || {
          echo "FAIL: consult record missing field '$field': $sample" >&2; exit 1; }
      done

      # --- Sub-test 5: allowlist enforcement (T-2) ---
      # Non-allowlisted surface-id "not-on-allowlist" must return rc=2 and
      # write a {action:"consult-blocked", reason:"not-allowlisted"} audit
      # record. mock_generator must NOT fire (gate-block precedes orchestration).
      rm -f "$CG_TARGET_PATH"
      printf '0\n' > "$_gen_count_file"
      _records_before_5="$(wc -l < "$AUTO_AUTHOR_LOG" | tr -d ' ')"
      consultation_propose not-on-allowlist mock_rationale mock_generator
      _rc5=$?
      [ "$_rc5" = "2" ] || {
        echo "FAIL: non-allowlisted surface rc=$_rc5 (expected 2)" >&2; exit 1; }
      [ "$(get_gen_count)" = "0" ] || {
        echo "FAIL: gate-blocked surface fired generator (count=$(get_gen_count))" >&2; exit 1; }
      [ ! -f "$CG_TARGET_PATH" ] || {
        echo "FAIL: gate-blocked surface wrote target" >&2; exit 1; }
      _records_after_5="$(wc -l < "$AUTO_AUTHOR_LOG" | tr -d ' ')"
      [ "$_records_after_5" = "$((_records_before_5 + 1))" ] || {
        echo "FAIL: gate-block did not append exactly 1 audit record (before=$_records_before_5 after=$_records_after_5)" >&2; exit 1; }
      _last_record="$(tail -n 1 "$AUTO_AUTHOR_LOG")"
      printf '%s' "$_last_record" | grep -q '"action":"consult-blocked"' || {
        echo "FAIL: last record missing action=consult-blocked: $_last_record" >&2; exit 1; }
      printf '%s' "$_last_record" | grep -q '"reason":"not-allowlisted"' || {
        echo "FAIL: last record missing reason=not-allowlisted: $_last_record" >&2; exit 1; }
      printf '%s' "$_last_record" | grep -q '"surface_id":"not-on-allowlist"' || {
        echo "FAIL: last record surface_id mismatch: $_last_record" >&2; exit 1; }
      for field in ts surface_id action reason; do
        printf '%s' "$_last_record" | grep -q "\"$field\":" || {
          echo "FAIL: consult-blocked record missing field '$field': $_last_record" >&2; exit 1; }
      done

      # --- Sub-test 6: env-var threading (T-4) ---
      # CG_RATIONALE_SHA + CG_CONSULTED_AT must be visible inside generator_fn
      # during accept-path orchestration, MUST byte-match the audit-log
      # accept record's rationale_sha + ts (single source of truth), and
      # MUST be cleared after consultation_propose returns (no leakage to
      # parent shell).
      rm -f "$CG_TARGET_PATH"
      printf '0\n' > "$_gen_count_file"
      _seen_sha_file="$_CG_TEST_DIR/seen-sha"
      _seen_at_file="$_CG_TEST_DIR/seen-at"
      : > "$_seen_sha_file"
      : > "$_seen_at_file"
      mock_generator_thread() {
        local n
        n=$(cat "$_gen_count_file")
        echo $((n + 1)) > "$_gen_count_file"
        printf '%s' "${CG_RATIONALE_SHA:-}" > "$_seen_sha_file"
        printf '%s' "${CG_CONSULTED_AT:-}" > "$_seen_at_file"
        printf 'mock-generator-output-thread\n'
      }
      unset CG_RATIONALE_SHA CG_CONSULTED_AT
      printf 'a\na\n' | consultation_propose self-test mock_rationale mock_generator_thread || {
        echo "FAIL: env-thread accept rc=$? (expected 0)" >&2; exit 1; }
      seen_sha="$(cat "$_seen_sha_file")"
      seen_at="$(cat "$_seen_at_file")"
      [ -n "$seen_sha" ] || {
        echo "FAIL: CG_RATIONALE_SHA empty inside generator [T-4 BREACH]" >&2; exit 1; }
      [ -n "$seen_at" ] || {
        echo "FAIL: CG_CONSULTED_AT empty inside generator [T-4 BREACH]" >&2; exit 1; }
      printf '%s\n' "$seen_sha" | grep -Eq '^[a-f0-9]{64}$' || {
        echo "FAIL: CG_RATIONALE_SHA not sha256-hex (got '$seen_sha')" >&2; exit 1; }
      printf '%s\n' "$seen_at" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || {
        echo "FAIL: CG_CONSULTED_AT not ISO-8601 UTC (got '$seen_at')" >&2; exit 1; }
      # Cleared after return:
      [ -z "${CG_RATIONALE_SHA:-}" ] || {
        echo "FAIL: CG_RATIONALE_SHA leaked to parent shell after return [T-4 BREACH]" >&2; exit 1; }
      [ -z "${CG_CONSULTED_AT:-}" ] || {
        echo "FAIL: CG_CONSULTED_AT leaked to parent shell after return [T-4 BREACH]" >&2; exit 1; }
      # Byte-match against audit log (single source of truth):
      _last_accept_sha="$(grep '"action":"consult"' "$AUTO_AUTHOR_LOG" | grep '"response":"accept"' | tail -n 1 | jq -r '.rationale_sha')"
      [ "$seen_sha" = "$_last_accept_sha" ] || {
        echo "FAIL: CG_RATIONALE_SHA env mismatch with audit ts: env=$seen_sha audit=$_last_accept_sha" >&2; exit 1; }
      _last_accept_ts="$(grep '"action":"consult"' "$AUTO_AUTHOR_LOG" | grep '"response":"accept"' | tail -n 1 | jq -r '.ts')"
      [ "$seen_at" = "$_last_accept_ts" ] || {
        echo "FAIL: CG_CONSULTED_AT env mismatch with audit ts: env=$seen_at audit=$_last_accept_ts" >&2; exit 1; }
      # Reject path MUST NOT export the env vars:
      rm -f "$CG_TARGET_PATH"
      printf '0\n' > "$_gen_count_file"
      : > "$_seen_sha_file"
      : > "$_seen_at_file"
      printf 'r\n' | consultation_propose self-test mock_rationale mock_generator_thread
      _rc6_reject=$?
      [ "$_rc6_reject" = "1" ] || {
        echo "FAIL: env-thread reject rc=$_rc6_reject (expected 1)" >&2; exit 1; }
      [ -z "${CG_RATIONALE_SHA:-}" ] || {
        echo "FAIL: CG_RATIONALE_SHA set on reject path [T-4 BREACH]" >&2; exit 1; }
      [ -z "${CG_CONSULTED_AT:-}" ] || {
        echo "FAIL: CG_CONSULTED_AT set on reject path [T-4 BREACH]" >&2; exit 1; }

      records="$(wc -l < "$AUTO_AUTHOR_LOG" | tr -d ' ')"
      printf 'self-test PASS: 6/6 sub-tests green; audit_log=%s records=%s\n' \
        "$AUTO_AUTHOR_LOG" "$records"
      rm -rf "$_CG_TEST_DIR"
      exit 0
      ;;
    "") : ;;
    *) printf 'consultation-gate: unknown direct invocation arg: %s\n' "$1" >&2; exit 2 ;;
  esac
fi
