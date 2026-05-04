#!/usr/bin/env bash
# zoom-transcript.sh — SP13 T-3 Zoom transcript parser. Strips sequence
# numbers, timestamp lines, and blank separators. Keeps speaker + text.
set -u
[ $# -eq 1 ] || { echo "zoom-transcript.sh: usage: zoom-transcript.sh <PATH>" >&2; exit 2; }
awk '
  /^[[:space:]]*$/ { next }
  /^[0-9]+$/ { next }
  /-->/ { next }
  { print }
' "$1"
