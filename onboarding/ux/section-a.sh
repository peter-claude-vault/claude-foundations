#!/bin/bash
# onboarding/ux/section-a.sh — SP07 T-2 Section A deterministic discovery flow.
#
# Renders a single-screen confirmation card over filesystem-derived pre-fills,
# accepts Enter-to-accept-all OR per-field numeric edit, optionally elects
# opt-out #1 (skip discovery), then writes:
#
#   1. $INPUTS_DIR/extraction-output-A.json     (engine-consumable shape per
#                                                extraction-prompts/section-A.md
#                                                — section_id="A",
#                                                extraction_mode="deterministic",
#                                                populated map, empty confidence
#                                                + source_spans, follow_up=null)
#   2. $AUDIT_LOG                               (single JSONL line per
#                                                SKILL.md L141: section_id +
#                                                run_id + ts + opt_outs[] +
#                                                confidence_map + source_spans
#                                                + corrections[] + follow_ups[]
#                                                + manifest_paths_written[])
#
# No transcript. No LLM. No confidence gates. Per design (onboarder-design.md
# §3) and stub extraction prompt (extraction-prompts/section-A.md), Section A
# is a pure UX-state-to-JSON pass.
#
# Hard invariants:
#   - Bash 3.2 + R-23 compatible (no declare -A, no mapfile, no ${var,,}).
#   - Single-deliverable per R-37.
#   - JSONL audit emits structural metadata only — no user-provided strings
#     in diagnostic fields (SKILL.md L146 reference-leak floor).
#   - Probes are READ-ONLY against the user's live host (Bucket C).
#   - Timezone probe uses readlink /etc/localtime per CFF-S56-5 (privilege-
#     free, launchd-context-safe; NOT systemsetup -gettimezone).
#
# Env knobs (override defaults; tests + dogfood):
#   AUTO_ACCEPT=1               Non-interactive Enter-accept (tests + dogfood)
#   AUTO_OPT_OUT=1              Non-interactive opt-out-#1 (tests)
#   INPUTS_DIR                  Where extraction-output-A.json lands
#                               (default: $CLAUDE_HOME/onboarding)
#   AUDIT_LOG                   JSONL audit path
#                               (default: $CLAUDE_HOME/onboarding/audit/section-a.jsonl)
#   SETTINGS_JSON               MCP-discovery source
#                               (default: $HOME/.claude/settings.json)
#   DISCOVERY_TZ_OVERRIDE       Skip readlink /etc/localtime probe (tests)
#   DISCOVERY_DEV_ENV_OVERRIDE  Skip `command -v` editor probe (tests)
#
# Exit codes:
#   0   success | opt-out #1 elected
#   2   bad invocation / missing dependency
#   3   write error
#   130 user quit (q/Q at prompt)

set -u

diag() { printf 'section-a FAIL: %s\n' "$1" >&2; }
info() { printf 'section-a: %s\n' "$1"; }

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
AUDIT_LOG="${AUDIT_LOG:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/audit/section-a.jsonl}"
SETTINGS_JSON="${SETTINGS_JSON:-$HOME/.claude/settings.json}"
AUTO_ACCEPT="${AUTO_ACCEPT:-0}"
AUTO_OPT_OUT="${AUTO_OPT_OUT:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --inputs-dir)    INPUTS_DIR="$2"; shift 2 ;;
    --audit-log)     AUDIT_LOG="$2"; shift 2 ;;
    --settings-json) SETTINGS_JSON="$2"; shift 2 ;;
    --auto-accept)   AUTO_ACCEPT=1; shift ;;
    --auto-opt-out)  AUTO_OPT_OUT=1; shift ;;
    -h|--help)       sed -n '2,46p' "$0"; exit 0 ;;
    *)               diag "unknown arg: $1"; exit 2 ;;
  esac
done

# --- run constants ---
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXTRACTION_OUT="$INPUTS_DIR/extraction-output-A.json"

mkdir -p "$INPUTS_DIR" "$(dirname "$AUDIT_LOG")" 2>/dev/null || {
  diag "cannot create output directories"
  exit 3
}

# --- discovery probes (Bucket C — read-only) ---

probe_name() {
  git config --global user.name 2>/dev/null
}

probe_email() {
  git config --global user.email 2>/dev/null
}

probe_timezone() {
  if [ -n "${DISCOVERY_TZ_OVERRIDE:-}" ]; then
    printf '%s\n' "$DISCOVERY_TZ_OVERRIDE"
    return 0
  fi
  # CFF-S56-5: readlink /etc/localtime — privilege-free, launchd-context-safe,
  # IANA Continent/City form. Byte-identical to installer/render-launchd.sh
  # post-S55 (commit 48cee95). NOT systemsetup -gettimezone (admin-required +
  # restricted-env-fail) and NOT date +%Z (returns abbreviation, not IANA).
  readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||'
}

probe_vault_root() {
  # Per q-field-map.json discovery_prefills.vault_root.scan_paths.
  # Returns the first match; user picks elsewhere via inline edit.
  local candidate
  for pat in "$HOME/Documents"/*Vault* "$HOME/Vault" "$HOME/Obsidian"; do
    # Glob may not expand if no match; check for literal asterisk.
    case "$pat" in
      *\**) continue ;;
    esac
    if [ -d "$pat" ]; then
      candidate="$pat"
      break
    fi
  done
  printf '%s\n' "${candidate:-}"
}

probe_mcp_keys_matching() {
  # Echoes mcpServer keys (one per line) whose name matches the pattern (case-
  # insensitive). Pattern is a `jq test()` regex.
  local pattern="$1"
  [ -f "$SETTINGS_JSON" ] || return 0
  jq -r --arg p "$pattern" '
    (.mcpServers // {}) | keys[]? | select(test($p; "i"))
  ' "$SETTINGS_JSON" 2>/dev/null
}

probe_calendar()      { probe_mcp_keys_matching 'calendar|gcal'                              | head -1; }
probe_messaging_arr() { probe_mcp_keys_matching 'slack|teams|gchat|chat|discord|telegram|signal|whatsapp'; }
probe_email_client()  { probe_mcp_keys_matching 'gmail|email|outlook|^mail'                  | head -1; }
probe_transcription() { probe_mcp_keys_matching 'granola|whisper|transcrib'                  | head -1; }
probe_tasks()         { probe_mcp_keys_matching 'asana|linear|jira|todoist|^task'            | head -1; }

probe_dev_env() {
  if [ -n "${DISCOVERY_DEV_ENV_OVERRIDE:-}" ]; then
    printf '%s\n' "$DISCOVERY_DEV_ENV_OVERRIDE"
    return 0
  fi
  for editor in code cursor zed nvim; do
    if command -v "$editor" >/dev/null 2>&1; then
      printf '%s\n' "$editor"
      return 0
    fi
  done
}

# --- collect discovery state into parallel arrays (bash 3.2 — no assoc) ---
# Field index → label, value, schema-path (newline-separated multi-value for messaging).
# Order is the user-visible numbering 1..10.

V_NAME="$(probe_name)"
V_EMAIL="$(probe_email)"
V_TZ="$(probe_timezone)"
V_VAULT="$(probe_vault_root)"
V_CAL="$(probe_calendar)"
V_MSG="$(probe_messaging_arr)"           # newline-separated; may be empty
V_EMAIL_CLIENT="$(probe_email_client)"
V_TRANS="$(probe_transcription)"
V_TASKS="$(probe_tasks)"
V_DEV="$(probe_dev_env)"

# --- UX rendering ---

fmt_or_empty() {
  if [ -z "$1" ]; then printf '(none detected)'; else printf '%s' "$1"; fi
}

fmt_msg_arr() {
  if [ -z "$V_MSG" ]; then
    printf '(none detected)'
  else
    printf '%s' "$V_MSG" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g'
  fi
}

display_card() {
  printf '\n=== Section A — Welcome & Discovery Review ===\n\n'
  printf "Here's what we already know. Confirm or correct.\n\n"
  printf '  1. Name:           %s\n'  "$(fmt_or_empty "$V_NAME")"
  printf '  2. Email:          %s\n'  "$(fmt_or_empty "$V_EMAIL")"
  printf '  3. Timezone:       %s\n'  "$(fmt_or_empty "$V_TZ")"
  printf '  4. Vault root:     %s\n'  "$(fmt_or_empty "$V_VAULT")"
  printf '\nTools detected on this machine:\n\n'
  printf '  5. Calendar:       %s\n'  "$(fmt_or_empty "$V_CAL")"
  printf '  6. Messaging:      %s\n'  "$(fmt_msg_arr)"
  printf '  7. Email:          %s\n'  "$(fmt_or_empty "$V_EMAIL_CLIENT")"
  printf '  8. Transcription:  %s\n'  "$(fmt_or_empty "$V_TRANS")"
  printf '  9. Tasks:          %s\n'  "$(fmt_or_empty "$V_TASKS")"
  printf ' 10. Dev env:        %s\n'  "$(fmt_or_empty "$V_DEV")"
  printf '\n[Enter] = accept all   1-10 = edit field   o = opt out   q = quit\n'
  printf '> '
}

# Tracks user-edited field numbers for corrections[] in JSONL audit.
CORRECTIONS=""    # space-separated field-numbers (no user-typed strings)

note_correction() {
  case " $CORRECTIONS " in
    *" $1 "*) ;;
    *) CORRECTIONS="${CORRECTIONS}${CORRECTIONS:+ }$1" ;;
  esac
}

edit_field() {
  local n="$1"
  case "$n" in
    1)  printf 'New value for Name (blank = keep): '
        read -r v; [ -n "$v" ] && { V_NAME="$v"; note_correction "$n"; } ;;
    2)  printf 'New value for Email (blank = keep): '
        read -r v; [ -n "$v" ] && { V_EMAIL="$v"; note_correction "$n"; } ;;
    3)  printf 'New value for Timezone (IANA, e.g. America/New_York; blank = keep): '
        read -r v; [ -n "$v" ] && { V_TZ="$v"; note_correction "$n"; } ;;
    4)  printf 'New value for Vault root (absolute path, or "none" = no vault yet; blank = keep): '
        read -r v
        if [ "$v" = "none" ]; then V_VAULT=""; note_correction "$n"
        elif [ -n "$v" ]; then V_VAULT="$v"; note_correction "$n"
        fi ;;
    5)  printf 'New value for Calendar tool (blank = keep, "none" = clear): '
        read -r v
        if [ "$v" = "none" ]; then V_CAL=""; note_correction "$n"
        elif [ -n "$v" ]; then V_CAL="$v"; note_correction "$n"
        fi ;;
    6)  printf 'New Messaging tools (comma-separated, "none" = clear, blank = keep): '
        read -r v
        if [ "$v" = "none" ]; then V_MSG=""; note_correction "$n"
        elif [ -n "$v" ]; then
          V_MSG="$(printf '%s' "$v" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')"
          note_correction "$n"
        fi ;;
    7)  printf 'New value for Email client (blank = keep, "none" = clear): '
        read -r v
        if [ "$v" = "none" ]; then V_EMAIL_CLIENT=""; note_correction "$n"
        elif [ -n "$v" ]; then V_EMAIL_CLIENT="$v"; note_correction "$n"
        fi ;;
    8)  printf 'New value for Transcription tool (blank = keep, "none" = clear): '
        read -r v
        if [ "$v" = "none" ]; then V_TRANS=""; note_correction "$n"
        elif [ -n "$v" ]; then V_TRANS="$v"; note_correction "$n"
        fi ;;
    9)  printf 'New value for Tasks tool (blank = keep, "none" = clear): '
        read -r v
        if [ "$v" = "none" ]; then V_TASKS=""; note_correction "$n"
        elif [ -n "$v" ]; then V_TASKS="$v"; note_correction "$n"
        fi ;;
    10) printf 'New value for Dev env (blank = keep, "none" = clear): '
        read -r v
        if [ "$v" = "none" ]; then V_DEV=""; note_correction "$n"
        elif [ -n "$v" ]; then V_DEV="$v"; note_correction "$n"
        fi ;;
    *)  info "field $n out of range (1-10)" ;;
  esac
}

# --- emitters ---

emit_extraction_output() {
  # $1 = "0" for non-opt-out, "1" for opt-out (empty discovery + opt_outs append)
  local opted="$1"
  local tmp="$EXTRACTION_OUT.tmp.$$"

  # Build messaging JSON array from newline-separated V_MSG.
  local msg_json
  if [ -z "$V_MSG" ]; then
    msg_json='[]'
  else
    msg_json="$(printf '%s\n' "$V_MSG" | jq -R . | jq -s .)"
  fi

  if [ "$opted" = "1" ]; then
    jq -n \
      --arg run_id "$RUN_ID" \
      --arg ts "$RUN_TS" \
      '{
        section_id: "A",
        extraction_mode: "deterministic",
        populated: {
          "U.system.opt_outs": ["discovery_skipped"]
        },
        confidence: {},
        source_spans: {},
        missing_required: [],
        conflicts: [],
        follow_up: null,
        run_id: $run_id,
        timestamp: $ts
      }' > "$tmp" || return 1
  else
    jq -n \
      --arg run_id "$RUN_ID" \
      --arg ts "$RUN_TS" \
      --arg name "$V_NAME" \
      --arg email "$V_EMAIL" \
      --arg tz "$V_TZ" \
      --arg vault "$V_VAULT" \
      --arg cal "$V_CAL" \
      --argjson msg "$msg_json" \
      --arg emc "$V_EMAIL_CLIENT" \
      --arg trans "$V_TRANS" \
      --arg tasks "$V_TASKS" \
      --arg dev "$V_DEV" \
      '{
        section_id: "A",
        extraction_mode: "deterministic",
        populated: (({
          "U.identity.name":       (if $name  == "" then null else $name  end),
          "U.identity.email":      (if $email == "" then null else $email end),
          "U.system.timezone":     (if $tz    == "" then null else $tz    end),
          "U.tools.calendar":      (if $cal   == "" then null else $cal   end),
          "U.tools.messaging":     $msg,
          "U.tools.email":         (if $emc   == "" then null else $emc   end),
          "U.tools.transcription": (if $trans == "" then null else $trans end),
          "U.tools.tasks":         (if $tasks == "" then null else $tasks end),
          "U.tools.dev_env":       (if $dev   == "" then null else $dev   end)
        } | with_entries(select(.value != null))) + {
          "U.paths.vault_root": (if $vault == "" then null else $vault end),
          "U.vault.root":       (if $vault == "" then null else $vault end)
        }),
        confidence: {},
        source_spans: {},
        missing_required: [],
        conflicts: [],
        follow_up: null,
        run_id: $run_id,
        timestamp: $ts
      }' > "$tmp" || return 1
  fi

  mv "$tmp" "$EXTRACTION_OUT" || return 1
  return 0
}

emit_audit_jsonl() {
  # $1 = "0" for non-opt-out, "1" for opt-out
  local opted="$1"
  local opt_outs_json="[]"
  local manifest_paths_json
  local corrections_json

  if [ "$opted" = "1" ]; then
    opt_outs_json='["discovery_skipped"]'
    manifest_paths_json='["U.system.opt_outs"]'
  else
    # Manifest paths ACTUALLY written (omit nulls).
    manifest_paths_json="$(jq -c '
      [
        (if .name        != "" then "U.identity.name"        else empty end),
        (if .email       != "" then "U.identity.email"       else empty end),
        (if .tz          != "" then "U.system.timezone"      else empty end),
        "U.paths.vault_root",
        "U.vault.root",
        (if .cal         != "" then "U.tools.calendar"       else empty end),
        "U.tools.messaging",
        (if .emc         != "" then "U.tools.email"          else empty end),
        (if .trans       != "" then "U.tools.transcription"  else empty end),
        (if .tasks       != "" then "U.tools.tasks"          else empty end),
        (if .dev         != "" then "U.tools.dev_env"        else empty end)
      ]
    ' <<EOF
{
  "name":  $(printf '%s' "$V_NAME"          | jq -Rs .),
  "email": $(printf '%s' "$V_EMAIL"         | jq -Rs .),
  "tz":    $(printf '%s' "$V_TZ"            | jq -Rs .),
  "vault": $(printf '%s' "$V_VAULT"         | jq -Rs .),
  "cal":   $(printf '%s' "$V_CAL"           | jq -Rs .),
  "msg":   $(if [ -z "$V_MSG" ]; then printf '[]'; else printf '%s\n' "$V_MSG" | jq -R . | jq -s .; fi),
  "emc":   $(printf '%s' "$V_EMAIL_CLIENT"  | jq -Rs .),
  "trans": $(printf '%s' "$V_TRANS"         | jq -Rs .),
  "tasks": $(printf '%s' "$V_TASKS"         | jq -Rs .),
  "dev":   $(printf '%s' "$V_DEV"           | jq -Rs .)
}
EOF
)"
  fi

  # corrections[] carries field-numbers (integers), no user strings — per
  # SKILL.md L146 reference-leak floor.
  if [ -z "$CORRECTIONS" ]; then
    corrections_json='[]'
  else
    corrections_json="$(printf '%s\n' $CORRECTIONS | jq -R 'tonumber' | jq -s .)"
  fi

  jq -nc \
    --arg section_id "A" \
    --arg run_id "$RUN_ID" \
    --arg ts "$RUN_TS" \
    --argjson opt_outs "$opt_outs_json" \
    --argjson corrections "$corrections_json" \
    --argjson manifest_paths "$manifest_paths_json" \
    '{
      section_id: $section_id,
      run_id: $run_id,
      ts: $ts,
      opt_outs: $opt_outs,
      confidence_map: {},
      source_spans: {},
      corrections: $corrections,
      follow_ups: [],
      manifest_paths_written: $manifest_paths
    }' >> "$AUDIT_LOG" || return 1
  return 0
}

# --- main flow ---

elect_opt_out_and_exit() {
  info "Discovery opt-out elected. Manifest will record discovery_skipped."
  emit_extraction_output 1 || { diag "extraction-output write failed"; exit 3; }
  emit_audit_jsonl 1       || { diag "audit JSONL write failed"; exit 3; }
  info "Section A complete (opt-out path). Continuing to Section B."
  exit 0
}

emit_accepted_and_exit() {
  emit_extraction_output 0 || { diag "extraction-output write failed"; exit 3; }
  emit_audit_jsonl 0       || { diag "audit JSONL write failed"; exit 3; }
  info "Section A complete. extraction-output-A.json staged at $EXTRACTION_OUT."
  exit 0
}

if [ "$AUTO_OPT_OUT" = "1" ]; then
  elect_opt_out_and_exit
fi

if [ "$AUTO_ACCEPT" = "1" ]; then
  emit_accepted_and_exit
fi

# Interactive loop.
while :; do
  display_card
  if ! IFS= read -r choice; then
    # EOF on stdin (e.g. interactive run with closed stdin) — accept defaults.
    printf '\n'
    emit_accepted_and_exit
  fi
  case "$choice" in
    "")           emit_accepted_and_exit ;;
    o|O)          elect_opt_out_and_exit ;;
    q|Q)          info "Section A aborted at user request. Re-run /onboard to resume."
                  exit 130 ;;
    [1-9]|10)     edit_field "$choice" ;;
    *)            info "Invalid input: '$choice'. Press Enter, 1-10, o, or q." ;;
  esac
done
