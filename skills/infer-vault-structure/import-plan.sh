#!/usr/bin/env bash
# import-plan.sh — SP13 T-6 Stage 2: thin shell wrapper over import-plan.py.
# Consumes T-5 propose-taxonomy-output.json (sp13-t5/1); produces a
# user-reviewable import-plan.md (sp13-t6/1) for the T-7 review gate.
#
# Usage:
#   import-plan.sh [--propose-taxonomy <path>] [--out <path>]
#                  [--generated-at <ISO-8601>]
#
# Defaults:
#   --propose-taxonomy   onboarding/seed-content/state/propose-taxonomy-output.json
#   --out                onboarding/seed-content/state/import-plan.md
#   --generated-at       (current UTC; helper auto-fills)
#
# Output schema (sp13-t6/1) declared at schemas/import-plan-schema.json.
# Bash 3.2 compatible (R-23). Pure stdlib python3 helper (no requests /
# numpy / pyyaml / markdown deps).

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SELF_DIR/import-plan.py"

if [ ! -f "$HELPER" ]; then
  echo "import-plan.sh: import-plan.py helper missing at $HELPER" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "import-plan.sh: python3 not found on PATH" >&2
  exit 2
fi

PROPOSE_TAXONOMY=""
OUT=""
GENERATED_AT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --propose-taxonomy)
      shift
      [ $# -gt 0 ] || { echo "import-plan.sh: --propose-taxonomy requires a path" >&2; exit 2; }
      PROPOSE_TAXONOMY="$1"
      ;;
    --out)
      shift
      [ $# -gt 0 ] || { echo "import-plan.sh: --out requires a path" >&2; exit 2; }
      OUT="$1"
      ;;
    --generated-at)
      shift
      [ $# -gt 0 ] || { echo "import-plan.sh: --generated-at requires an ISO-8601 timestamp" >&2; exit 2; }
      GENERATED_AT="$1"
      ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "import-plan.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

if [ -z "$PROPOSE_TAXONOMY" ]; then
  PROPOSE_TAXONOMY="$REPO_ROOT/onboarding/seed-content/state/propose-taxonomy-output.json"
fi
[ -f "$PROPOSE_TAXONOMY" ] || { echo "import-plan.sh: propose-taxonomy not found: $PROPOSE_TAXONOMY" >&2; exit 2; }

if [ -z "$OUT" ]; then
  OUT="$REPO_ROOT/onboarding/seed-content/state/import-plan.md"
fi

mkdir -p "$(dirname "$OUT")"

if [ -n "$GENERATED_AT" ]; then
  python3 "$HELPER" \
    --propose-taxonomy "$PROPOSE_TAXONOMY" \
    --out "$OUT" \
    --generated-at "$GENERATED_AT"
  RC=$?
else
  python3 "$HELPER" \
    --propose-taxonomy "$PROPOSE_TAXONOMY" \
    --out "$OUT"
  RC=$?
fi

if [ "$RC" -ne 0 ]; then
  echo "import-plan.sh: import-plan.py exited $RC" >&2
  exit "$RC"
fi

if [ ! -s "$OUT" ]; then
  echo "import-plan.sh: import-plan.md missing or empty at $OUT" >&2
  exit 1
fi

n_proj=$(grep -cE '^### .* — `Engagements/' "$OUT" 2>/dev/null || echo 0)
n_routes=$(grep -cE '^\| [0-9]+ \| ' "$OUT" 2>/dev/null || echo 0)
n_unc=$(grep -cE '^> ⚠️ \*\*Review the unclassified pile' "$OUT" 2>/dev/null || echo 0)
printf 'import-plan.sh: rendered %s project sections, %s routing rows, %s unclassified call-out (out=%s)\n' \
  "$n_proj" "$n_routes" "$n_unc" "$OUT" >&2

exit 0
