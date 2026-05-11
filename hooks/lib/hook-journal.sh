# ~/.claude/hooks/lib/hook-journal.sh
# Plan 84 SP03 — NDJSON emission journal helper.
#
# Source this file — do not execute it.
#   source "$HOME/.claude/hooks/lib/hook-journal.sh"
#
# Public function:
#   journal_emission EVENT PAYLOAD EXIT_CODE [SCHEMA_VALID] [SOURCE]
#     EVENT         — hookEventName (PreToolUse|UserPromptSubmit|PostToolUse|SessionStart|Stop)
#     PAYLOAD       — emitted JSON string (or state-write summary for state writers)
#     EXIT_CODE     — integer exit code of the emission action (0 on success, non-0 on reject/error)
#     SCHEMA_VALID  — "true"|"false" (optional; auto-derived from EXIT_CODE if absent)
#     SOURCE        — event subtype string (optional; e.g. "compact" for SessionStart)
#
# Output: appends ONE NDJSON line to
#   $HOOKS_STATE_OVERRIDE | $HOOKS_STATE | $CLAUDE_HOME/hooks/state | $HOME/.claude/hooks/state
#     /sessions/<sid>/events.log
#
# Schema (locked T-1):
#   {ts, session_id, hook, event, source, exit_code,
#    emitted_chars, content_sha, schema_valid, emission_id, schema_version}
#
# Atomicity: printf '%s\n' >>  is atomic for writes <PIPE_BUF (4096B macOS).
# Records ≤256B; no lockfile required.
#
# Graceful degradation: empty $CLAUDE_SESSION_ID → routes to sessions/no-sid/events.log
# so no emission is lost. No exit/return failure surfaces to caller.

# Resolve HOOKS_STATE chain (test-isolation parity with SP01/SP02).
__hj_resolve_state_dir() {
  printf '%s' "${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/state}}"
}

# Resolve session id chain (env-var preferred; stdin fallback handled by caller).
__hj_resolve_sid() {
  printf '%s' "${CLAUDE_SESSION_ID:-${SESSION_ID:-no-sid}}"
}

# Compute content sha (12-char prefix of sha256).
__hj_content_sha() {
  printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1 | head -c 12
}

# Compute emission_id from ts + sha[0:8].
__hj_emission_id() {
  local ts="$1" sha="$2" ts_compact
  ts_compact=$(printf '%s' "$ts" | tr -d ':-')
  printf 'em-%s-%s' "$ts_compact" "${sha:0:8}"
}

# Public: emit one NDJSON journal record.
journal_emission() {
  local event="${1:-unknown}"
  local payload="${2:-}"
  local exit_code="${3:-0}"
  local schema_valid="${4:-}"
  local source_subtype="${5:-}"

  # Auto-derive schema_valid from exit_code if not explicitly passed.
  if [[ -z "$schema_valid" ]]; then
    if [[ "$exit_code" == "0" ]]; then
      schema_valid="true"
    else
      schema_valid="false"
    fi
  fi

  local state_dir sid sid_dir events_log
  state_dir=$(__hj_resolve_state_dir)
  sid=$(__hj_resolve_sid)
  sid_dir="$state_dir/sessions/$sid"
  events_log="$sid_dir/events.log"

  mkdir -p "$sid_dir" 2>/dev/null || return 0  # never block caller

  local ts sha emitted_chars hook eid
  ts=$(date -u +%FT%TZ)
  sha=$(__hj_content_sha "$payload")
  emitted_chars=$(printf '%s' "$payload" | wc -c | tr -d ' ')
  hook="${BASH_SOURCE[1]##*/}"
  [[ -z "$hook" || "$hook" == "hook-journal.sh" ]] && hook="${0##*/}"
  eid=$(__hj_emission_id "$ts" "$sha")

  # Build the record via jq (defensive against payload-injection of quotes/newlines).
  # If jq is unavailable, fall back to printf with manual escaping (deny-on-doubt).
  local record
  if command -v jq >/dev/null 2>&1; then
    record=$(jq -nc \
      --arg ts "$ts" \
      --arg sid "$sid" \
      --arg hook "$hook" \
      --arg event "$event" \
      --arg source "$source_subtype" \
      --argjson exit_code "$exit_code" \
      --argjson emitted_chars "$emitted_chars" \
      --arg content_sha "$sha" \
      --argjson schema_valid "$schema_valid" \
      --arg emission_id "$eid" \
      --argjson schema_version 1 \
      '{ts:$ts, session_id:$sid, hook:$hook, event:$event, source:$source,
        exit_code:$exit_code, emitted_chars:$emitted_chars,
        content_sha:$content_sha, schema_valid:$schema_valid,
        emission_id:$emission_id, schema_version:$schema_version}' 2>/dev/null) || record=""
  fi

  if [[ -z "$record" ]]; then
    # jq missing or failed — manual minimal record (no payload injection risk; no payload field).
    record=$(printf '{"ts":"%s","session_id":"%s","hook":"%s","event":"%s","source":"%s","exit_code":%s,"emitted_chars":%s,"content_sha":"%s","schema_valid":%s,"emission_id":"%s","schema_version":1}' \
      "$ts" "$sid" "$hook" "$event" "$source_subtype" "$exit_code" "$emitted_chars" "$sha" "$schema_valid" "$eid")
  fi

  printf '%s\n' "$record" >> "$events_log" 2>/dev/null || return 0
  return 0
}
