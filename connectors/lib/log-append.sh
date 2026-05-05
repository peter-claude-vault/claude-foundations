#!/usr/bin/env bash
# connectors/lib/log-append.sh — SP14 T-14.
#
# Appends a single JSON-line run record to ~/.claude/connectors/logs/<id>.log.
# Record shape: {ts, connector_id, status, items_pulled, duration_ms, error?}.
#
# OUTPUT CONTRACT (R-43):
#   Files written: $LOG_DIR/<id>.log (one JSON-line append per invocation)
#   Schema-types: ad-hoc JSONL; required keys ts + connector_id + status
#   Pre-write validation: input fields validated; jq composes the record
#   Failure mode: BLOCK AND LOG. rc=2 bad invocation; rc=3 file write failure.
#
# Usage:
#   bash log-append.sh --id <connector_id> --status <ok|error|skipped|no-op>
#                       [--items-pulled N] [--duration-ms N] [--error "<msg>"]
#                       [--log-dir <path>]
#
# Exit codes: 0=success, 2=bad invocation, 3=write failure

set -u

_diag() { printf 'log-append FAIL: %s\n' "$1" >&2; }

id=""
status=""
items_pulled=""
duration_ms=""
error_msg=""
log_dir="${CLAUDE_HOME:-$HOME/.claude}/connectors/logs"

while [ $# -gt 0 ]; do
  case "$1" in
    --id) [ $# -lt 2 ] && { _diag "--id requires value"; exit 2; }; id="$2"; shift 2 ;;
    --status) [ $# -lt 2 ] && { _diag "--status requires value"; exit 2; }; status="$2"; shift 2 ;;
    --items-pulled) [ $# -lt 2 ] && { _diag "--items-pulled requires N"; exit 2; }; items_pulled="$2"; shift 2 ;;
    --duration-ms) [ $# -lt 2 ] && { _diag "--duration-ms requires N"; exit 2; }; duration_ms="$2"; shift 2 ;;
    --error) [ $# -lt 2 ] && { _diag "--error requires msg"; exit 2; }; error_msg="$2"; shift 2 ;;
    --log-dir) [ $# -lt 2 ] && { _diag "--log-dir requires path"; exit 2; }; log_dir="$2"; shift 2 ;;
    -*) _diag "unknown flag: $1"; exit 2 ;;
    *) _diag "unexpected positional: $1"; exit 2 ;;
  esac
done

[ -z "$id" ] && { _diag "--id required"; exit 2; }
[ -z "$status" ] && { _diag "--status required"; exit 2; }

case "$status" in
  ok|error|skipped|no-op) ;;
  *) _diag "--status invalid: '$status' (allowed: ok|error|skipped|no-op)"; exit 2 ;;
esac
if ! printf '%s' "$id" | grep -qE '^[a-z][a-z0-9-]*$'; then
  _diag "--id must match ^[a-z][a-z0-9-]*\$"
  exit 2
fi

mkdir -p "$log_dir" || { _diag "mkdir failed: $log_dir"; exit 3; }

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
record=$(jq -nc \
  --arg ts "$ts" \
  --arg id "$id" \
  --arg status "$status" \
  --arg items "$items_pulled" \
  --arg dur "$duration_ms" \
  --arg err "$error_msg" \
  '
    {ts: $ts, connector_id: $id, status: $status}
    | (if $items != "" then .items_pulled = ($items | tonumber) else . end)
    | (if $dur != "" then .duration_ms = ($dur | tonumber) else . end)
    | (if $err != "" then .error = $err else . end)
  ' 2>/dev/null) || { _diag "jq compose failed"; exit 3; }

printf '%s\n' "$record" >> "$log_dir/$id.log" || { _diag "append failed: $log_dir/$id.log"; exit 3; }
exit 0
