#!/usr/bin/env bash
# format-detector.sh — SP13 T-3 per-format probe.
#
# Usage:
#   format-detector.sh <PATH>
#
# Emits one of: markdown | plaintext | word | pdf | otter-vtt |
#               zoom-transcript | llm-export | unsupported
#
# Detection priority:
#   1. Extension match
#   2. Filename heuristics (zoom-transcript, llm-export naming)
#   3. JSON content sniff (llm-export shape)
#   4. Magic-byte fallback (docx zip, pdf header)
#   5. unsupported
#
# Bash 3.2 compatible (R-23).

set -u

[ $# -eq 1 ] || { echo "format-detector.sh: usage: format-detector.sh <PATH>" >&2; exit 2; }
P="$1"

if [ ! -f "$P" ]; then
  printf 'unsupported\n'
  exit 0
fi

base=$(basename "$P")
ext="${base##*.}"
ext_lc=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
base_lc=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')

case "$ext_lc" in
  md|markdown) printf 'markdown\n'; exit 0 ;;
  txt|text)
    case "$base_lc" in
      *zoom*) printf 'zoom-transcript\n'; exit 0 ;;
    esac
    printf 'plaintext\n'; exit 0
    ;;
  docx|doc)    printf 'word\n'; exit 0 ;;
  pdf)         printf 'pdf\n'; exit 0 ;;
  vtt)         printf 'otter-vtt\n'; exit 0 ;;
  json)
    if jq -e '
      (type=="array" and (.[0] | (has("role") and has("content")))) or
      (type=="object" and has("messages") and (.messages | type=="array") and (.messages[0] | has("role")))
    ' "$P" >/dev/null 2>&1; then
      printf 'llm-export\n'; exit 0
    fi
    printf 'plaintext\n'; exit 0
    ;;
esac

# Filename heuristic for zoom transcripts without .txt extension.
case "$base_lc" in
  *zoom*transcript*|*zoom-recording*|*zoom-meeting*) printf 'zoom-transcript\n'; exit 0 ;;
esac

# Magic-byte fallback.
hex=$(xxd -p -l 5 "$P" 2>/dev/null | tr -d '\n')
case "$hex" in
  504b0304*)   printf 'word\n'; exit 0 ;;
  255044462d*) printf 'pdf\n'; exit 0 ;;
esac

printf 'unsupported\n'
exit 0
