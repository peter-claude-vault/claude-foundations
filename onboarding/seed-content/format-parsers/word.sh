#!/usr/bin/env bash
# word.sh — SP13 T-3 Word document parser. Uses pandoc when available;
# otherwise emits a graceful-degrade marker. Format detection still
# identified the file as `word`, so the IR record carries that classification.
set -u
[ $# -eq 1 ] || { echo "word.sh: usage: word.sh <PATH>" >&2; exit 2; }
in="$1"
if command -v pandoc >/dev/null 2>&1; then
  pandoc -t plain -- "$in" 2>/dev/null || \
    printf '[binary content not extracted: pandoc parse error]\n'
else
  printf '[binary content not extracted: pandoc unavailable]\n'
fi
