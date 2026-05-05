#!/usr/bin/env bash
# onboarding/connectors/wizard.sh — SP14 top-level connector-wizard entry.
#
# Orchestrates Beats 1-4 + final gate (T-7..T-11). Supports --reconnect <id>
# (T-15 AC #4) for the one-click reconnect path that re-runs Beat 4 for a
# single connector.
#
# Usage:
#   bash wizard.sh                      # interactive full wizard (Beats 1→4 + final)
#   bash wizard.sh --reconnect <id>     # re-run Beat 4 for one connector
#   bash wizard.sh --skip-role          # bypass Beat 1 (role already set)
#
# All flags forwarded to the underlying beat scripts where applicable.

set -u

_diag() { printf 'wizard FAIL: %s\n' "$1" >&2; }
_info() { printf 'wizard: %s\n' "$1"; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B1="$SELF_DIR/beats/beat-1-role.sh"
B2="$SELF_DIR/beats/beat-2-multiselect.sh"
B3="$SELF_DIR/beats/beat-3-schedule.sh"
B4="$SELF_DIR/beats/beat-4-oauth.sh"
FG="$SELF_DIR/beats/final-gate.sh"

reconnect_id=""
manifest_arg=""
settings_arg=""
extra_args=""

while [ $# -gt 0 ]; do
  case "$1" in
    --reconnect) [ $# -lt 2 ] && { _diag "--reconnect requires id"; exit 2; }; reconnect_id="$2"; shift 2 ;;
    --manifest) [ $# -lt 2 ] && { _diag "--manifest requires path"; exit 2; }; manifest_arg="$2"; shift 2 ;;
    --settings) [ $# -lt 2 ] && { _diag "--settings requires path"; exit 2; }; settings_arg="$2"; shift 2 ;;
    *) extra_args="$extra_args $1"; shift ;;
  esac
done

manifest_arg_str=""
[ -n "$manifest_arg" ] && manifest_arg_str="--manifest $manifest_arg"
settings_arg_str=""
[ -n "$settings_arg" ] && settings_arg_str="--settings $settings_arg"

# --- reconnect mode: flip auth_status:expired → pending, then run Beat 4 for that id ---
if [ -n "$reconnect_id" ]; then
  manifest="${manifest_arg:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
  if [ ! -r "$manifest" ]; then
    _diag "manifest not readable: $manifest"
    exit 2
  fi
  # Reset auth_status to pending so Beat 4 will walk it
  tmp="$manifest.tmp.$$"
  jq --arg id "$reconnect_id" \
    '.connectors |= map(if .id == $id then .auth_status = "pending" else . end)' \
    "$manifest" > "$tmp" || { _diag "jq reset failed"; rm -f "$tmp"; exit 3; }
  mv -f "$tmp" "$manifest" || { _diag "atomic mv failed"; exit 3; }
  _info "reset auth_status:pending for $reconnect_id; invoking Beat 4"

  # shellcheck disable=SC2086
  exec bash "$B4" $manifest_arg_str $settings_arg_str \
    --input-actions "$reconnect_id:confirm" $extra_args
fi

# --- full wizard flow ---
_info "running full wizard (Beats 1→4 + final gate)"
# shellcheck disable=SC2086
bash "$B1" $manifest_arg_str $extra_args || exit $?
# shellcheck disable=SC2086
bash "$B2" $manifest_arg_str $extra_args || exit $?
# shellcheck disable=SC2086
bash "$B3" $manifest_arg_str $extra_args || exit $?
# shellcheck disable=SC2086
bash "$B4" $manifest_arg_str $settings_arg_str $extra_args || exit $?
# shellcheck disable=SC2086
bash "$FG" $manifest_arg_str $extra_args
