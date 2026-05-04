#!/usr/bin/env bash
# llm-export.sh — SP13 T-3 generic LLM export parser. Handles two shapes:
#   1. Top-level array of {role, content}
#   2. Object with .messages = [{role, content}]
set -u
[ $# -eq 1 ] || { echo "llm-export.sh: usage: llm-export.sh <PATH>" >&2; exit 2; }
in="$1"
if jq -e 'type=="array" and (.[0] | has("role"))' "$in" >/dev/null 2>&1; then
  jq -r '.[] | "\(.role): \(.content)"' "$in"
elif jq -e 'has("messages") and (.messages | type=="array")' "$in" >/dev/null 2>&1; then
  jq -r '.messages[] | "\(.role): \(.content)"' "$in"
else
  cat "$in"
fi
