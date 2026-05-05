#!/usr/bin/env bash
# connectors/lib/log-rotate.sh — SP14 T-14.
#
# Rotates per-connector logs in ~/.claude/connectors/logs/. A log is rotated
# when its size exceeds 1MB OR when it is older than 90 days. Rotated files
# move to <id>.log.1; existing .1 is overwritten (single-generation rotation).
#
# Usage: bash log-rotate.sh [--log-dir <path>] [--size-cap-bytes N]
#                            [--age-cap-days N]
#
# Exit codes: 0=success (always; per-file failures logged but non-fatal),
#             2=bad invocation

set -u

_diag() { printf 'log-rotate FAIL: %s\n' "$1" >&2; }
_info() { printf 'log-rotate: %s\n' "$1"; }

log_dir="${CLAUDE_HOME:-$HOME/.claude}/connectors/logs"
size_cap=$((1 * 1024 * 1024))
age_cap_days=90

while [ $# -gt 0 ]; do
  case "$1" in
    --log-dir) [ $# -lt 2 ] && { _diag "--log-dir requires path"; exit 2; }; log_dir="$2"; shift 2 ;;
    --size-cap-bytes) [ $# -lt 2 ] && { _diag "--size-cap-bytes requires N"; exit 2; }; size_cap="$2"; shift 2 ;;
    --age-cap-days) [ $# -lt 2 ] && { _diag "--age-cap-days requires N"; exit 2; }; age_cap_days="$2"; shift 2 ;;
    -*) _diag "unknown flag: $1"; exit 2 ;;
    *) _diag "unexpected positional: $1"; exit 2 ;;
  esac
done

[ -d "$log_dir" ] || { _info "log-dir absent: $log_dir; nothing to rotate"; exit 0; }

# Iterate <id>.log files (skip .1 already-rotated)
for f in "$log_dir"/*.log; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in
    *.log.1) continue ;;
  esac

  # Check size — BSD vs GNU stat
  if size=$(stat -f%z "$f" 2>/dev/null); then
    :
  elif size=$(stat -c%s "$f" 2>/dev/null); then
    :
  else
    size=0
  fi

  rotate=0
  if [ "$size" -ge "$size_cap" ]; then
    rotate=1
    _info "rotating $f (size $size ≥ $size_cap)"
  fi

  # Check age
  if [ "$rotate" = "0" ]; then
    if mtime=$(stat -f%m "$f" 2>/dev/null); then
      :
    elif mtime=$(stat -c%Y "$f" 2>/dev/null); then
      :
    else
      mtime=$(date +%s)
    fi
    now=$(date +%s)
    age_sec=$((now - mtime))
    age_cap_sec=$((age_cap_days * 86400))
    if [ "$age_sec" -ge "$age_cap_sec" ]; then
      rotate=1
      _info "rotating $f (age $age_sec sec ≥ $age_cap_sec)"
    fi
  fi

  if [ "$rotate" = "1" ]; then
    mv -f "$f" "$f.1" || { _info "rotate failed for $f (continuing)"; continue; }
    : > "$f"  # truncate fresh
  fi
done

exit 0
