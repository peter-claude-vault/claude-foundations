#!/usr/bin/env bash
# markdown.sh — SP13 T-3 markdown parser. Strips YAML frontmatter; passes body.
set -u
[ $# -eq 1 ] || { echo "markdown.sh: usage: markdown.sh <PATH>" >&2; exit 2; }
awk '
  BEGIN { state = "head" }
  state == "head" {
    if ($0 ~ /^---[[:space:]]*$/) { state = "fm"; next }
    state = "body"; print; next
  }
  state == "fm" {
    if ($0 ~ /^---[[:space:]]*$/) { state = "body"; next }
    next
  }
  { print }
' "$1"
