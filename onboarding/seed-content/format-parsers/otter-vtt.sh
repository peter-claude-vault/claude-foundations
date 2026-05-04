#!/usr/bin/env bash
# otter-vtt.sh — SP13 T-3 WebVTT parser. Strips header, timestamps, cue numbers.
set -u
[ $# -eq 1 ] || { echo "otter-vtt.sh: usage: otter-vtt.sh <PATH>" >&2; exit 2; }
awk '
  /^WEBVTT/ { next }
  /^[[:space:]]*$/ { next }
  /-->/ { next }
  /^[0-9]+$/ { next }
  { print }
' "$1"
