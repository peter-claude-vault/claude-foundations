#!/usr/bin/env bash
# retrofit-collision-matrix.sh — SP13 T-13 thin wrapper over
# retrofit-collision-matrix.py.
#
# Appends a `## Collision matrix` section to an existing import-plan.md
# (sp13-t6/1) using metadata from a retrofit-matrix.json (sp13-t13/1).
#
# Usage:
#   retrofit-collision-matrix.sh --matrix <path> --import-plan <path>
#
# Bash 3.2 compatible (R-23). python3 REQUIRED.

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SELF_DIR/retrofit-collision-matrix.py"

if [ ! -f "$HELPER" ]; then
  echo "retrofit-collision-matrix.sh: helper missing at $HELPER" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "retrofit-collision-matrix.sh: python3 not found on PATH" >&2
  exit 2
fi

MATRIX=""
IMPORT_PLAN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --matrix)
      shift
      [ $# -gt 0 ] || { echo "retrofit-collision-matrix.sh: --matrix requires a path" >&2; exit 2; }
      MATRIX="$1"
      ;;
    --import-plan)
      shift
      [ $# -gt 0 ] || { echo "retrofit-collision-matrix.sh: --import-plan requires a path" >&2; exit 2; }
      IMPORT_PLAN="$1"
      ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "retrofit-collision-matrix.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

[ -n "$MATRIX" ]      || { echo "retrofit-collision-matrix.sh: --matrix required" >&2; exit 2; }
[ -n "$IMPORT_PLAN" ] || { echo "retrofit-collision-matrix.sh: --import-plan required" >&2; exit 2; }
[ -f "$MATRIX" ]      || { echo "retrofit-collision-matrix.sh: matrix not found: $MATRIX" >&2; exit 2; }
[ -f "$IMPORT_PLAN" ] || { echo "retrofit-collision-matrix.sh: import-plan not found: $IMPORT_PLAN" >&2; exit 2; }

python3 "$HELPER" --matrix "$MATRIX" --import-plan "$IMPORT_PLAN"
exit $?
