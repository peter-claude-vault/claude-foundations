#!/bin/bash
# Multi-session coordination — shared constants and utility functions.
# Sourced by all hook scripts and registry-op.sh.

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/hook-journal.sh"
source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/validate-hook-output.sh"

COORD_DIR="$VAULT_LOGS/.coordination"
REGISTRY_FILE="$COORD_DIR/session-registry.json"
REGISTRY_LOCK="$COORD_DIR/registry.lock"
MANIFEST_LOCK="$COORD_DIR/manifest.lock"
TASKS_LOCK="$COORD_DIR/tasks.lock"
RECONCILE_LOCK="$COORD_DIR/reconcile.lock"

EMPTY_REGISTRY='{"sessions":{},"pending_reconciliation":false,"last_reconciled":""}'

# Manifest-driven thresholds with hardcoded fallbacks (Lead 2 §2 defaults).
_t="$(_manifest_get .hooks.multi_session.stale_threshold_secs)"
if [ -n "$_t" ]; then STALE_THRESHOLD_SECS="$_t"; else STALE_THRESHOLD_SECS=1800; fi
unset _t

_c="$(_manifest_get .hooks.multi_session.touched_files_cap)"
if [ -n "$_c" ]; then TOUCHED_FILES_CAP="$_c"; else TOUCHED_FILES_CAP=100; fi
unset _c

ensure_coord_dir() {
  mkdir -p "$COORD_DIR"
}

# Read registry file. Returns empty registry if missing/empty.
read_registry() {
  if [[ -f "$REGISTRY_FILE" ]] && [[ -s "$REGISTRY_FILE" ]]; then
    cat "$REGISTRY_FILE"
  else
    echo "$EMPTY_REGISTRY"
  fi
}

# Atomic write via write-then-rename. Arg: JSON content.
write_registry() {
  local tmp="${REGISTRY_FILE}.tmp.$$"
  printf '%s\n' "$1" > "$tmp"
  mv "$tmp" "$REGISTRY_FILE"
}

# Remove stale sessions. Reads JSON from stdin, writes cleaned JSON to stdout.
clean_stale() {
  local reg now sids sid pid hb hb_epoch is_stale
  reg=$(cat)
  now=$(date +%s)
  sids=$(echo "$reg" | jq -r '.sessions | keys[]' 2>/dev/null) || true

  for sid in $sids; do
    pid=$(echo "$reg" | jq -r ".sessions[\"$sid\"].pid")
    hb=$(echo "$reg" | jq -r ".sessions[\"$sid\"].last_heartbeat")
    is_stale=false

    if ! kill -0 "$pid" 2>/dev/null; then
      is_stale=true
    fi

    if [[ -n "$hb" && "$hb" != "null" ]]; then
      hb_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$hb" +%s 2>/dev/null || echo 0)
      if (( now - hb_epoch > STALE_THRESHOLD_SECS )); then
        is_stale=true
      fi
    fi

    if $is_stale; then
      reg=$(echo "$reg" | jq "del(.sessions[\"$sid\"])")
      echo "[msc] Removed stale session $sid (pid=$pid)" >&2
    fi
  done

  echo "$reg"
}

# Format hookSpecificOutput JSON. Args: event_name, context_text.
# Plan 84 SP03: pipes through pre-emit validator + NDJSON journal.
# Returns 0 + emits payload to stdout on validator-pass.
# Returns 1 + emits NOTHING on validator-reject (caller's emission is suppressed);
#   journal records schema_valid:false for audit. Stderr surfaces rejection reason.
format_output() {
  local event="$1" ctx="$2" payload
  payload=$(jq -n --arg event "$event" --arg ctx "$ctx" \
    '{"hookSpecificOutput":{"hookEventName":$event,"additionalContext":$ctx}}')

  if printf '%s' "$payload" | validate_hook_output; then
    journal_emission "$event" "$payload" 0 "true"
    printf '%s\n' "$payload"
    return 0
  else
    journal_emission "$event" "$payload" 1 "false"
    return 1
  fi
}

# Peer summary string. Args: registry_json, own_session_id. Empty if solo.
get_peer_summary() {
  local reg="$1" own_sid="$2" peer_count summaries
  peer_count=$(echo "$reg" | jq --arg sid "$own_sid" \
    '[.sessions | to_entries[] | select(.key != $sid) | select(.value.status == "active")] | length')

  if (( peer_count == 0 )); then
    return
  fi

  summaries=$(echo "$reg" | jq -r --arg sid "$own_sid" '
    .sessions | to_entries[] | select(.key != $sid) | select(.value.status == "active") |
    "- Session \(.key[0:8])... (pid \(.value.pid), touched \(.value.touched_files | length) files)"
  ')

  printf '%d active peer session(s):\n%s' "$peer_count" "$summaries"
}

# File overlap list. Args: registry_json, own_session_id. One file per line, empty if none.
get_file_overlaps() {
  local reg="$1" own_sid="$2"
  echo "$reg" | jq -r --arg sid "$own_sid" '
    (.sessions[$sid].touched_files // []) as $own |
    [.sessions | to_entries[] | select(.key != $sid) | select(.value.status == "active") |
     .value.touched_files[] | select(. as $f | $own | index($f))] | unique | .[]
  ' 2>/dev/null || true
}

# Pending reconciliation info. Args: registry_json, own_session_id. Empty if none.
get_pending_info() {
  local reg="$1" own_sid="$2" pending closed_summaries
  pending=$(echo "$reg" | jq -r '.pending_reconciliation')

  if [[ "$pending" == "true" ]]; then
    closed_summaries=$(echo "$reg" | jq -r --arg sid "$own_sid" '
      .sessions | to_entries[] | select(.key != $sid) |
      select(.value.status == "closed-pending-reconciliation") |
      "- Session \(.key[0:8])...: \(.value.close_summary // "no summary")"
    ')
    printf 'Previous sessions left pending reconciliation:\n%s' "$closed_summaries"
  fi
}

# Relative path from vault root. Arg: absolute file path.
vault_relative() {
  local path="$1"
  if [[ "$path" == "$VAULT_ROOT/"* ]]; then
    echo "${path#$VAULT_ROOT/}"
  else
    echo ""
  fi
}
