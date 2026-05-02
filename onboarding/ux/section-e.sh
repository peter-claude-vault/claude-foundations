#!/bin/bash
# onboarding/ux/section-e.sh — SP07 T-7 Section E checkbox screen.
#
# Renders three deterministic privacy/automation toggles per
# onboarder-design.md §7. All default OFF. No transcript, no extraction,
# no confidence gates. Pure UX-state-to-JSON pass; mirrors the Section A
# (S74) deterministic-section pattern.
#
# Toggles (per q-field-map.json `section_e_binaries`):
#   E-1 — Auto-commit + push ~/.claude/ at session end
#         → U.behavioral.hook_preferences.auto_commit_enabled
#   E-2 — Cross-session memory consolidation via claude-mem
#         → U.behavioral.hook_preferences.memory_consolidation_enabled
#   E-3 — Multi-session coordination
#         → U.behavioral.hook_preferences.multi_session_enabled
#
# Outputs (R-43; both atomic tmp+rename):
#   1. $INPUTS_DIR/extraction-output-E.json
#      Per extraction-prompts/section-E.md deterministic shape:
#      section_id="E", extraction_mode="deterministic", populated
#      booleans, empty confidence + source_spans, follow_up=null.
#   2. $AUDIT_LOG (single JSONL line per SKILL.md L141)
#      9-key shape: section_id, run_id, ts, opt_outs[], confidence_map{},
#      source_spans{}, corrections[], follow_ups[], manifest_paths_written[].
#      corrections[] carries Q-IDs (E-1/E-2/E-3) of toggles flipped from
#      default OFF — reference-leak floor (no user-typed strings).
#
# Hard invariants:
#   - Bash 3.2 + R-23 compatible (no declare -A, no mapfile, no ${var,,}).
#   - Single deliverable per R-37: section-e.sh + 3-toggle deterministic
#     write contract.
#   - JSONL audit emits structural metadata only (SKILL.md L146).
#   - Section E has no opt-outs (deterministic; SKILL.md L66).
#   - Section E has no transcript (no recording per SKILL.md L48).
#   - Section E does NOT invoke initial-job-setup (Section D owns that).
#
# Env knobs:
#   AUTO_ACCEPT=1               Non-interactive accept-defaults (all OFF)
#   AUTO_SET="E-1=true,E-2=false,E-3=true"
#                               Non-interactive set (hermetic test).
#                               Comma-separated; missing IDs default OFF.
#   INPUTS_DIR                  Where extraction-output-E.json lands
#                               (default: $CLAUDE_HOME/onboarding)
#   AUDIT_LOG                   JSONL audit path
#                               (default: $CLAUDE_HOME/onboarding/audit/section-e.jsonl)
#
# Exit codes:
#   0   success (defaults persisted OR user-set values written)
#   2   bad invocation / missing dependency
#   3   write error
#   130 user quit (q/Q at prompt)

set -u

diag() { printf 'section-e FAIL: %s\n' "$1" >&2; }
info() { printf 'section-e: %s\n' "$1"; }

# --- source paths.sh if present (post-install runtime); fall back to env ---
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi

# --- dependency check ---
for tool in jq date; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    diag "$tool required but not on PATH"
    exit 2
  fi
done

# --- defaults + arg parsing ---
INPUTS_DIR="${INPUTS_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding}"
AUDIT_LOG="${AUDIT_LOG:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/audit/section-e.jsonl}"
AUTO_ACCEPT="${AUTO_ACCEPT:-0}"
AUTO_SET="${AUTO_SET:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --inputs-dir)    INPUTS_DIR="$2"; shift 2 ;;
    --audit-log)     AUDIT_LOG="$2"; shift 2 ;;
    --auto-accept)   AUTO_ACCEPT=1; shift ;;
    --auto-set)      AUTO_SET="$2"; shift 2 ;;
    -h|--help)       sed -n '2,49p' "$0"; exit 0 ;;
    *)               diag "unknown arg: $1"; exit 2 ;;
  esac
done

# --- run constants ---
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXTRACTION_OUT="$INPUTS_DIR/extraction-output-E.json"

# --- foundation-repo source resolution (Bucket A) — for checkpoint.sh ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONBOARDING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
USER_MANIFEST="${USER_MANIFEST:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"

mkdir -p "$INPUTS_DIR" "$(dirname "$AUDIT_LOG")" 2>/dev/null || {
  diag "cannot create output directories"
  exit 3
}

# --- toggle state (parallel scalars per R-23 — no declare -A) ---
# All default OFF.
E1=false   # auto_commit_enabled
E2=false   # memory_consolidation_enabled
E3=false   # multi_session_enabled

# --- AUTO_SET parser (hermetic test) ---
# Accepts "E-1=true,E-2=false,E-3=true" or any subset; missing IDs stay false.
# Values: true|false (lowercase per R-23 — use tr to normalize).
parse_auto_set() {
  local spec="$1"
  [ -z "$spec" ] && return 0
  local pair id val val_lc
  local IFS_SAVE="$IFS"
  IFS=','
  set -- $spec
  IFS="$IFS_SAVE"
  for pair in "$@"; do
    id="${pair%%=*}"
    val="${pair#*=}"
    val_lc="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
    case "$val_lc" in
      true|1|yes|on)   val_lc=true ;;
      false|0|no|off|"") val_lc=false ;;
      *)
        diag "AUTO_SET invalid value for $id: $val (expect true|false)"
        exit 2 ;;
    esac
    case "$id" in
      E-1) E1="$val_lc" ;;
      E-2) E2="$val_lc" ;;
      E-3) E3="$val_lc" ;;
      *)
        diag "AUTO_SET unknown Q-ID: $id (expect E-1|E-2|E-3)"
        exit 2 ;;
    esac
  done
}

# --- UX rendering ---

mark() { case "$1" in true) printf '[x]' ;; *) printf '[ ]' ;; esac; }

display_card() {
  printf '\n=== Section E — Final Checkboxes ===\n\n'
  printf 'Three privacy and automation toggles. All default OFF.\n\n'
  printf '  1. %s Auto-commit and push ~/.claude/ changes to a git remote\n' "$(mark "$E1")"
  printf '        at session end. (Requires a configured remote.)\n\n'
  printf '  2. %s Let Claude consolidate cross-session memory via claude-mem.\n\n' "$(mark "$E2")"
  printf '  3. %s Enable multi-session coordination. Useful if you run\n' "$(mark "$E3")"
  printf '        multiple Claude Code windows simultaneously.\n\n'
  printf '[Enter] = accept   1-3 = toggle   y1/n1 (etc.) = set explicit   q = quit\n'
  printf '> '
}

toggle_field() {
  local n="$1"
  case "$n" in
    1) case "$E1" in true) E1=false ;; *) E1=true ;; esac ;;
    2) case "$E2" in true) E2=false ;; *) E2=true ;; esac ;;
    3) case "$E3" in true) E3=false ;; *) E3=true ;; esac ;;
    *) info "field $n out of range (1-3)" ;;
  esac
}

set_field() {
  # $1 = "y" or "n"; $2 = "1"|"2"|"3"
  local v="$1"; local n="$2"
  local b
  case "$v" in y|Y) b=true ;; n|N) b=false ;; *) info "expected y/n got: $v"; return ;; esac
  case "$n" in
    1) E1="$b" ;;
    2) E2="$b" ;;
    3) E3="$b" ;;
    *) info "field $n out of range (1-3)" ;;
  esac
}

# --- emitters ---

emit_extraction_output() {
  local tmp="$EXTRACTION_OUT.tmp.$$"
  jq -n \
    --arg run_id "$RUN_ID" \
    --arg ts "$RUN_TS" \
    --argjson e1 "$E1" \
    --argjson e2 "$E2" \
    --argjson e3 "$E3" \
    '{
      section_id: "E",
      extraction_mode: "deterministic",
      populated: {
        "U.behavioral.hook_preferences.auto_commit_enabled": $e1,
        "U.behavioral.hook_preferences.memory_consolidation_enabled": $e2,
        "U.behavioral.hook_preferences.multi_session_enabled": $e3
      },
      confidence: {},
      source_spans: {},
      missing_required: [],
      conflicts: [],
      follow_up: null,
      run_id: $run_id,
      timestamp: $ts
    }' > "$tmp" || return 1
  mv "$tmp" "$EXTRACTION_OUT" || return 1
  return 0
}

# corrections[] holds Q-IDs (E-1/E-2/E-3) for toggles flipped from default OFF.
# Reference-leak floor: structural identifiers only — no user strings.
build_corrections_json() {
  local items=""
  [ "$E1" = "true" ] && items="${items}${items:+ }\"E-1\""
  [ "$E2" = "true" ] && items="${items}${items:+ }\"E-2\""
  [ "$E3" = "true" ] && items="${items}${items:+ }\"E-3\""
  if [ -z "$items" ]; then
    printf '[]'
  else
    printf '[%s]' "$(printf '%s' "$items" | sed 's/ /,/g')"
  fi
}

emit_audit_jsonl() {
  local corrections_json
  corrections_json="$(build_corrections_json)"

  jq -nc \
    --arg section_id "E" \
    --arg run_id "$RUN_ID" \
    --arg ts "$RUN_TS" \
    --argjson corrections "$corrections_json" \
    '{
      section_id: $section_id,
      run_id: $run_id,
      ts: $ts,
      opt_outs: [],
      confidence_map: {},
      source_spans: {},
      corrections: $corrections,
      follow_ups: [],
      manifest_paths_written: [
        "U.behavioral.hook_preferences.auto_commit_enabled",
        "U.behavioral.hook_preferences.memory_consolidation_enabled",
        "U.behavioral.hook_preferences.multi_session_enabled"
      ]
    }' >> "$AUDIT_LOG" || return 1
  return 0
}

emit_and_exit() {
  emit_extraction_output || { diag "extraction-output write failed"; exit 3; }
  emit_audit_jsonl       || { diag "audit JSONL write failed"; exit 3; }
  # SP07 T-10: per-section checkpoint (E has no transcript).
  "$ONBOARDING_DIR/checkpoint.sh" --section E --user-manifest "$USER_MANIFEST" \
    || { diag "checkpoint.sh write failed for section E"; exit 3; }
  info "Section E complete. extraction-output-E.json staged at $EXTRACTION_OUT."
  exit 0
}

# --- main flow ---

# AUTO_SET applied first (override defaults), then AUTO_ACCEPT short-circuits.
parse_auto_set "$AUTO_SET"

if [ "$AUTO_ACCEPT" = "1" ] || [ -n "$AUTO_SET" ]; then
  emit_and_exit
fi

# Interactive loop.
while :; do
  display_card
  if ! IFS= read -r choice; then
    # EOF on stdin — accept current state.
    printf '\n'
    emit_and_exit
  fi
  case "$choice" in
    "")          emit_and_exit ;;
    q|Q)         info "Section E aborted at user request. Re-run /onboard to resume."
                 exit 130 ;;
    [1-3])       toggle_field "$choice" ;;
    [yYnN][1-3]) set_field "${choice%?}" "${choice#?}" ;;
    *)           info "Invalid input: '$choice'. Press Enter, 1-3, y1/n1 (etc.), or q." ;;
  esac
done
