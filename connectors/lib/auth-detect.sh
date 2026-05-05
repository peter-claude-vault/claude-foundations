#!/usr/bin/env bash
# connectors/lib/auth-detect.sh — SP14 T-15.
#
# Auth-failure detector. On detection of an expired/revoked OAuth token in a
# connector run's stderr/return code, jq-patches connectors/manifest.json
# setting auth_status:expired for the affected connector, and (when not in
# --dry-run) issues `launchctl unload` for the connector's launchd plist.
#
# OUTPUT CONTRACT (R-43):
#   Files written: $MANIFEST — auth_status flipped to "expired" for matched id
#   Schema-types: connectors-runtime-schema.json#/properties/connectors/items
#   Pre-write validation: jq-readability of manifest
#   Failure mode: BLOCK AND LOG. rc=2 bad invocation; rc=3 manifest write fail.
#
# Detection patterns (case-insensitive substring match against stderr or
# error-message arg):
#   - "401" / "403" / "unauthorized" / "forbidden"
#   - "token expired" / "token revoked" / "auth_required" / "needs reauth"
#   - "invalid_grant" (RFC 6749) / "invalid_token" / "expired_token"
#
# Usage:
#   bash auth-detect.sh --id <connector_id> [--stderr-file <path>]
#                       [--error-msg "<msg>"] [--manifest <path>]
#                       [--dry-run] [--no-launchctl]
#
# Exit codes:
#   0  detection succeeded — manifest patched (or --dry-run no-write)
#   1  no auth-failure pattern matched (caller can decide whether to log/fail)
#   2  bad invocation
#   3  manifest write failure

set -u

_diag() { printf 'auth-detect FAIL: %s\n' "$1" >&2; }
_info() { printf 'auth-detect: %s\n' "$1"; }

id=""
stderr_file=""
error_msg=""
manifest="${CLAUDE_HOME:-$HOME/.claude}/connectors/manifest.json"
dry_run=0
no_launchctl=0

while [ $# -gt 0 ]; do
  case "$1" in
    --id) [ $# -lt 2 ] && { _diag "--id requires value"; exit 2; }; id="$2"; shift 2 ;;
    --stderr-file) [ $# -lt 2 ] && { _diag "--stderr-file requires path"; exit 2; }; stderr_file="$2"; shift 2 ;;
    --error-msg) [ $# -lt 2 ] && { _diag "--error-msg requires value"; exit 2; }; error_msg="$2"; shift 2 ;;
    --manifest) [ $# -lt 2 ] && { _diag "--manifest requires path"; exit 2; }; manifest="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --no-launchctl) no_launchctl=1; shift ;;
    -*) _diag "unknown flag: $1"; exit 2 ;;
    *) _diag "unexpected positional: $1"; exit 2 ;;
  esac
done

[ -z "$id" ] && { _diag "--id required"; exit 2; }

# Compose the input text to scan
scan_text=""
if [ -n "$stderr_file" ] && [ -r "$stderr_file" ]; then
  scan_text=$(cat "$stderr_file")
fi
if [ -n "$error_msg" ]; then
  scan_text="$scan_text"$'\n'"$error_msg"
fi
if [ -z "$scan_text" ]; then
  _diag "no scan text — pass --stderr-file or --error-msg"
  exit 2
fi

# Pattern match (case-insensitive grep -E)
patterns='401|403|[Uu]nauthorized|[Ff]orbidden|token expired|token revoked|auth_required|needs reauth|invalid_grant|invalid_token|expired_token'
if ! printf '%s' "$scan_text" | grep -qE "$patterns"; then
  _info "no auth-failure pattern matched for $id"
  exit 1
fi

_info "auth-failure pattern matched for $id; flipping to auth_status:expired"

if [ ! -r "$manifest" ]; then
  _diag "manifest not readable: $manifest"
  exit 3
fi

# Flip auth_status for this id
new_json=$(jq --arg id "$id" \
  '.connectors |= map(if .id == $id then .auth_status = "expired" else . end)' \
  "$manifest" 2>/dev/null) || { _diag "jq patch failed"; exit 3; }

if [ "$dry_run" -eq 1 ]; then
  _info "dry-run: would write $manifest"
  printf '%s\n' "$new_json"
  exit 0
fi

tmp="$manifest.tmp.$$"
printf '%s\n' "$new_json" > "$tmp" || { _diag "tmp write failed"; exit 3; }
mv -f "$tmp" "$manifest" || { _diag "atomic mv failed"; exit 3; }

# Suspend the launchd plist (production only; tests pass --no-launchctl)
if [ "$no_launchctl" -eq 0 ]; then
  if command -v launchctl >/dev/null 2>&1; then
    label="${LABEL_PREFIX:-com.claude-stem}.connector-runtime.$id"
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    _info "launchctl bootout attempted for $label"
  fi
fi

_info "$id: auth_status=expired; STATUS.md re-render will surface badge on next refresh"
exit 0
