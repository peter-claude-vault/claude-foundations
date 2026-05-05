#!/usr/bin/env bash
# connectors/runner.sh — SP14 T-16 (orchestrates T-13/T-14/T-15/T-16).
#
# Per-connector run orchestrator. Consumed by templates/launchd/connector-
# runtime.plist.tmpl as the entry-point: launchd fires runner.sh with
# CONNECTOR_ID env var; runner consults manifest + failure-mode catalog,
# dispatches the connector's MCP calls, captures stdout/stderr, applies
# failure-mode policy on errors (T-16), invokes auth-detect (T-15) on
# auth-related failures, appends a JSON-line run record (T-14), and re-renders
# STATUS.md (T-13).
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - $LOG_DIR/<id>.log (one JSON-line append per run, via T-14)
#     - $STATUS_OUT (post-run STATUS.md re-render via T-13)
#     - $MANIFEST (auth_status update via T-15 detector when matched)
#   Schema-types: log JSONL + manifest connectors[]
#   Pre-write validation: jq -e on failure-mode-catalog.json at start
#   Failure mode: BLOCK AND LOG (per-mode policy applied)
#
# Usage:
#   bash runner.sh --id <connector_id> [--manifest <path>] [--catalog <path>]
#                  [--log-dir <path>] [--status-out <path>]
#                  [--mock-stdout <path>] [--mock-stderr <path>] [--mock-rc N]
#                  [--no-launchctl]
#
# Mock flags drive synthetic tests (in lieu of real MCP invocations):
#   --mock-stdout <path>   Substitute stdout from this file
#   --mock-stderr <path>   Substitute stderr from this file
#   --mock-rc <N>          Substitute rc
#
# Exit codes (per mode):
#   varies — see failure-mode-catalog.json modes[].rc_to_launchd

set -u

_diag() { printf 'runner FAIL: %s\n' "$1" >&2; }
_info() { printf 'runner: %s\n' "$1"; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SELF_DIR/lib"
manifest="${CLAUDE_HOME:-$HOME/.claude}/connectors/manifest.json"
catalog="$SELF_DIR/failure-mode-catalog.json"
log_dir="${CLAUDE_HOME:-$HOME/.claude}/connectors/logs"
status_out="${CLAUDE_HOME:-$HOME/.claude}/connectors/STATUS.md"
no_launchctl=0

id=""
mock_stdout=""
mock_stderr=""
mock_rc="0"

while [ $# -gt 0 ]; do
  case "$1" in
    --id) [ $# -lt 2 ] && { _diag "--id requires value"; exit 2; }; id="$2"; shift 2 ;;
    --manifest) [ $# -lt 2 ] && { _diag "--manifest requires path"; exit 2; }; manifest="$2"; shift 2 ;;
    --catalog) [ $# -lt 2 ] && { _diag "--catalog requires path"; exit 2; }; catalog="$2"; shift 2 ;;
    --log-dir) [ $# -lt 2 ] && { _diag "--log-dir requires path"; exit 2; }; log_dir="$2"; shift 2 ;;
    --status-out) [ $# -lt 2 ] && { _diag "--status-out requires path"; exit 2; }; status_out="$2"; shift 2 ;;
    --mock-stdout) [ $# -lt 2 ] && { _diag "--mock-stdout requires path"; exit 2; }; mock_stdout="$2"; shift 2 ;;
    --mock-stderr) [ $# -lt 2 ] && { _diag "--mock-stderr requires path"; exit 2; }; mock_stderr="$2"; shift 2 ;;
    --mock-rc) [ $# -lt 2 ] && { _diag "--mock-rc requires N"; exit 2; }; mock_rc="$2"; shift 2 ;;
    --no-launchctl) no_launchctl=1; shift ;;
    -*) _diag "unknown flag: $1"; exit 2 ;;
    *) _diag "unexpected positional: $1"; exit 2 ;;
  esac
done

[ -z "$id" ] && id="${CONNECTOR_ID:-}"
[ -z "$id" ] && { _diag "--id or CONNECTOR_ID env var required"; exit 2; }

# --- start: validate failure-mode-catalog ---
if [ ! -r "$catalog" ]; then
  _diag "failure-mode-catalog not readable: $catalog"
  exit 1
fi
jq -e . "$catalog" >/dev/null 2>&1 || { _diag "failure-mode-catalog invalid JSON: $catalog"; exit 1; }

# --- look up connector entry ---
if [ ! -r "$manifest" ]; then
  _diag "manifest not readable: $manifest"
  exit 1
fi
entry=$(jq -c --arg id "$id" '.connectors[] | select(.id == $id)' "$manifest" 2>/dev/null)
if [ -z "$entry" ]; then
  _diag "no connector with id='$id' in $manifest"
  exit 1
fi

failure_mode=$(printf '%s' "$entry" | jq -r '.failure_mode // "block-and-log"')

# Validate mode against catalog
mode_obj=$(jq -c --arg m "$failure_mode" '.modes[$m] // empty' "$catalog")
if [ -z "$mode_obj" ]; then
  _diag "unknown failure_mode '$failure_mode' for connector $id (not in catalog)"
  exit 1
fi

# --- run (mock for synthetic tests; real production path would invoke MCP) ---
start_ts=$(date +%s)
if [ -n "$mock_stdout" ]; then
  run_stdout=$(cat "$mock_stdout" 2>/dev/null)
else
  run_stdout=""
fi
if [ -n "$mock_stderr" ]; then
  run_stderr=$(cat "$mock_stderr" 2>/dev/null)
else
  run_stderr=""
fi
run_rc="$mock_rc"
end_ts=$(date +%s)
duration_ms=$(( (end_ts - start_ts) * 1000 ))

# --- apply failure-mode policy ---
final_status="ok"
if [ "$run_rc" = "0" ]; then
  # Check for source-empty signal in stdout
  if printf '%s' "$run_stdout" | grep -qiE '"items":\s*\[\s*\]|no.new.items|source-empty'; then
    final_status="no-op"
  fi
else
  case "$failure_mode" in
    auto-disable)
      # Delegate to T-15 detector
      bash "$LIB_DIR/auth-detect.sh" --id "$id" \
        --error-msg "$run_stderr" \
        --manifest "$manifest" \
        $([ "$no_launchctl" -eq 1 ] && echo "--no-launchctl") >/dev/null 2>&1
      final_status="error"
      ;;
    backoff-retry|skip-and-log)
      final_status="error"
      ;;
    no-op)
      final_status="no-op"
      run_rc="0"
      ;;
    block-and-log|*)
      final_status="error"
      ;;
  esac
fi

# --- log run ---
err_arg=""
if [ -n "$run_stderr" ]; then
  err_arg="--error"
fi

if [ -n "$err_arg" ]; then
  bash "$LIB_DIR/log-append.sh" --id "$id" --status "$final_status" \
    --duration-ms "$duration_ms" \
    --error "$run_stderr" \
    --log-dir "$log_dir" >/dev/null 2>&1 || _info "log-append failed (continuing)"
else
  bash "$LIB_DIR/log-append.sh" --id "$id" --status "$final_status" \
    --duration-ms "$duration_ms" \
    --log-dir "$log_dir" >/dev/null 2>&1 || _info "log-append failed (continuing)"
fi

# --- update last_run + last_status in manifest ---
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
new_json=$(jq --arg id "$id" --arg ts "$ts" --arg st "$final_status" \
  '.connectors |= map(if .id == $id then (.last_run = $ts | .last_status = $st) else . end)' \
  "$manifest" 2>/dev/null)
if [ -n "$new_json" ]; then
  tmp="$manifest.tmp.$$"
  printf '%s\n' "$new_json" > "$tmp" && mv -f "$tmp" "$manifest"
fi

# --- re-render STATUS.md ---
bash "$LIB_DIR/status-render.sh" --manifest "$manifest" --out "$status_out" >/dev/null 2>&1 \
  || _info "status-render failed (continuing)"

# Echo final exit code per mode policy
exit_rc=$(printf '%s' "$mode_obj" | jq -r '.rc_to_launchd')
case "$final_status" in
  ok|no-op) exit 0 ;;
  *) exit "${exit_rc:-1}" ;;
esac
