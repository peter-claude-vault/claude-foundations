#!/usr/bin/env bash
# seedignore-filter.sh — SP13 T-2 .seedignore scope filter.
#
# Reads patterns from <root>/.seedignore (gitignore-compatible subset) and
# emits the subset of stdin paths that DO NOT match any pattern. Default
# permissive: missing .seedignore -> pass-through.
#
# Usage:
#   seedignore-filter.sh --root <DIR> < paths-stdin > filtered-stdout
#
# Pattern rules:
#   - blank lines and # comments ignored
#   - trailing /  -> directory pattern, matches any path component
#   - shell glob  -> matched against basename and relative path
#
# Bash 3.2 compatible (R-23).

set -u

ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      shift
      [ $# -gt 0 ] || { echo "seedignore-filter.sh: --root requires a path" >&2; exit 2; }
      ROOT="$1"
      ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "seedignore-filter.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

[ -n "$ROOT" ] || { echo "seedignore-filter.sh: --root required" >&2; exit 2; }

ignore_file="$ROOT/.seedignore"
if [ ! -f "$ignore_file" ]; then
  cat
  exit 0
fi

patterns=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  case "$line" in
    ''|\#*) continue ;;
  esac
  patterns[${#patterns[@]}]="$line"
done < "$ignore_file"

# If file existed but contained only comments/blanks, behave like missing.
if [ "${#patterns[@]}" -eq 0 ]; then
  cat
  exit 0
fi

matches_any() {
  local path="$1" relpath="$2" base pat d
  base=$(basename "$path")
  for pat in "${patterns[@]}"; do
    case "$pat" in
      */)
        d="${pat%/}"
        case "/$relpath/" in
          */"$d"/*) return 0 ;;
        esac
        ;;
      *)
        case "$base" in
          $pat) return 0 ;;
        esac
        case "$relpath" in
          $pat) return 0 ;;
        esac
        ;;
    esac
  done
  return 1
}

while IFS= read -r p; do
  case "$p" in
    "$ROOT"/*) relpath="${p#${ROOT}/}" ;;
    "$ROOT")   relpath="" ;;
    *)         relpath="$p" ;;
  esac
  if matches_any "$p" "$relpath"; then
    continue
  fi
  printf '%s\n' "$p"
done
exit 0
