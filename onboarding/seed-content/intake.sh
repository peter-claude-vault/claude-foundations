#!/usr/bin/env bash
# intake.sh — SP13 T-1 Stage 1 INGEST entry point.
#
# Walks --source (directory or single file) or stores --source (paste content)
# and emits a JSONL manifest of intake records consumed by Stage 1's downstream
# format-detector + IR-builder (T-3).
#
# Usage:
#   intake.sh --source <DIR|FILE|PASTE_STRING> --manifest <OUT_PATH>
#
# Each manifest record (JSONL):
#   {"path": "<abs-or-paste-tmp>", "size_bytes": N, "source_type": "file|paste"}
#
# Dispatch heuristic (priority order):
#   1. --source resolves to a directory  -> recursive find -type f
#   2. --source resolves to a regular file -> single record
#   3. otherwise                          -> treat as paste content
#
# Format detection lands at SP13 T-3; T-1 emits intake records only.
# Bash 3.2 compatible (R-23).

set -u

SOURCE=""
MANIFEST=""

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      shift
      [ $# -gt 0 ] || { echo "intake.sh: --source requires an arg" >&2; exit 2; }
      SOURCE="$1"
      ;;
    --manifest)
      shift
      [ $# -gt 0 ] || { echo "intake.sh: --manifest requires a path" >&2; exit 2; }
      MANIFEST="$1"
      ;;
    -h|--help) usage ;;
    *) echo "intake.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$SOURCE" ]   || { echo "intake.sh: --source required" >&2; exit 2; }
[ -n "$MANIFEST" ] || { echo "intake.sh: --manifest required" >&2; exit 2; }

mkdir -p "$(dirname "$MANIFEST")"
: > "$MANIFEST"

emit_record() {
  # emit_record <path> <size_bytes> <source_type>
  jq -nc --arg path "$1" --argjson size "$2" --arg st "$3" \
    '{path: $path, size_bytes: $size, source_type: $st}' >> "$MANIFEST"
}

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
FILTER="$SELF_DIR/seedignore-filter.sh"

if [ -d "$SOURCE" ]; then
  if [ -f "$FILTER" ]; then
    find "$SOURCE" -type f -print | bash "$FILTER" --root "$SOURCE" | while IFS= read -r f; do
      sz=$(wc -c < "$f" | tr -d ' ')
      emit_record "$f" "$sz" "file"
    done
  else
    find "$SOURCE" -type f -print | while IFS= read -r f; do
      sz=$(wc -c < "$f" | tr -d ' ')
      emit_record "$f" "$sz" "file"
    done
  fi
elif [ -f "$SOURCE" ]; then
  sz=$(wc -c < "$SOURCE" | tr -d ' ')
  emit_record "$SOURCE" "$sz" "file"
else
  paste_dir="$(dirname "$MANIFEST")/paste"
  mkdir -p "$paste_dir"
  hash=$(printf '%s' "$SOURCE" | shasum | awk '{print $1}' | cut -c1-12)
  paste_file="$paste_dir/paste-${hash}.txt"
  printf '%s' "$SOURCE" > "$paste_file"
  sz=$(wc -c < "$paste_file" | tr -d ' ')
  emit_record "$paste_file" "$sz" "paste"
fi

count=$(wc -l < "$MANIFEST" | tr -d ' ')
printf 'intake.sh: %s records emitted to %s\n' "$count" "$MANIFEST" >&2
exit 0
