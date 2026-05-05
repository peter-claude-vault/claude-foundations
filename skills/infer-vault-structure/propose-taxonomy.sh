#!/usr/bin/env bash
# propose-taxonomy.sh — SP13 T-5 Stage 2: thin shell wrapper over
# propose-taxonomy.py. Consumes T-4 cluster-output.json (cluster-output/1) plus
# the source IR JSONL; produces propose-taxonomy-output.json (propose-taxonomy/1).
#
# Usage:
#   propose-taxonomy.sh --cluster-output <path> --ir <ir.jsonl> \
#                       [--out <propose-taxonomy-output.json>] \
#                       [--llm-mode {stub|live|auto}] \
#                       [--model-pass1 <model-id>] \
#                       [--model-pass2 <model-id>] \
#                       [--max-passes {2|3}] \
#                       [--low-mapped-threshold F]
#
# Defaults:
#   --cluster-output      onboarding/seed-content/state/cluster-output.json
#   --ir                  required (no default; T-5 needs the source IR for
#                         live-mode prompts and pass-orchestration parity)
#   --out                 onboarding/seed-content/state/propose-taxonomy-output.json
#                         (relative to foundation-repo root)
#   --llm-mode            auto (live when ANTHROPIC_API_KEY set; stub otherwise)
#   --model-pass1         claude-haiku-4-5-20251001
#   --model-pass2         claude-sonnet-4-6
#   --max-passes          3 (minimum 2 enforced inside helper)
#   --low-mapped-threshold 0.80
#
# Output schema (propose-taxonomy/1) declared at
# schemas/propose-taxonomy-schema.json. Bash 3.2 compatible (R-23). Pure
# stdlib python3 helper (no requests / numpy / pydantic).

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SELF_DIR/propose-taxonomy.py"

if [ ! -f "$HELPER" ]; then
  echo "propose-taxonomy.sh: propose-taxonomy.py helper missing at $HELPER" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "propose-taxonomy.sh: python3 not found on PATH" >&2
  exit 2
fi

CLUSTER_OUTPUT=""
IR=""
OUT=""
LLM_MODE="auto"
MODEL_PASS1="claude-haiku-4-5-20251001"
MODEL_PASS2="claude-sonnet-4-6"
MAX_PASSES="3"
LOW_MAPPED_THRESHOLD="0.80"

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster-output)
      shift
      [ $# -gt 0 ] || { echo "propose-taxonomy.sh: --cluster-output requires a path" >&2; exit 2; }
      CLUSTER_OUTPUT="$1"
      ;;
    --ir)
      shift
      [ $# -gt 0 ] || { echo "propose-taxonomy.sh: --ir requires a path" >&2; exit 2; }
      IR="$1"
      ;;
    --out)
      shift
      [ $# -gt 0 ] || { echo "propose-taxonomy.sh: --out requires a path" >&2; exit 2; }
      OUT="$1"
      ;;
    --llm-mode)
      shift
      [ $# -gt 0 ] || { echo "propose-taxonomy.sh: --llm-mode requires {stub|live|auto}" >&2; exit 2; }
      LLM_MODE="$1"
      ;;
    --model-pass1)
      shift
      [ $# -gt 0 ] || { echo "propose-taxonomy.sh: --model-pass1 requires a model id" >&2; exit 2; }
      MODEL_PASS1="$1"
      ;;
    --model-pass2)
      shift
      [ $# -gt 0 ] || { echo "propose-taxonomy.sh: --model-pass2 requires a model id" >&2; exit 2; }
      MODEL_PASS2="$1"
      ;;
    --max-passes)
      shift
      [ $# -gt 0 ] || { echo "propose-taxonomy.sh: --max-passes requires {2|3}" >&2; exit 2; }
      MAX_PASSES="$1"
      ;;
    --low-mapped-threshold)
      shift
      [ $# -gt 0 ] || { echo "propose-taxonomy.sh: --low-mapped-threshold requires F" >&2; exit 2; }
      LOW_MAPPED_THRESHOLD="$1"
      ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "propose-taxonomy.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

if [ -z "$CLUSTER_OUTPUT" ]; then
  CLUSTER_OUTPUT="$REPO_ROOT/onboarding/seed-content/state/cluster-output.json"
fi
[ -f "$CLUSTER_OUTPUT" ] || { echo "propose-taxonomy.sh: cluster-output not found: $CLUSTER_OUTPUT" >&2; exit 2; }

[ -n "$IR" ] || { echo "propose-taxonomy.sh: --ir required" >&2; exit 2; }
[ -f "$IR" ] || { echo "propose-taxonomy.sh: ir not found: $IR" >&2; exit 2; }

case "$LLM_MODE" in
  stub|live|auto) ;;
  *) echo "propose-taxonomy.sh: --llm-mode must be stub | live | auto" >&2; exit 2 ;;
esac

case "$MAX_PASSES" in
  2|3) ;;
  *) echo "propose-taxonomy.sh: --max-passes must be 2 or 3" >&2; exit 2 ;;
esac

if [ -z "$OUT" ]; then
  OUT="$REPO_ROOT/onboarding/seed-content/state/propose-taxonomy-output.json"
fi

mkdir -p "$(dirname "$OUT")"

python3 "$HELPER" \
  --cluster-output "$CLUSTER_OUTPUT" \
  --ir "$IR" \
  --out "$OUT" \
  --llm-mode "$LLM_MODE" \
  --model-pass1 "$MODEL_PASS1" \
  --model-pass2 "$MODEL_PASS2" \
  --max-passes "$MAX_PASSES" \
  --low-mapped-threshold "$LOW_MAPPED_THRESHOLD"
RC=$?

if [ "$RC" -ne 0 ]; then
  echo "propose-taxonomy.sh: propose-taxonomy.py exited $RC" >&2
  exit "$RC"
fi

if [ ! -s "$OUT" ]; then
  echo "propose-taxonomy.sh: propose-taxonomy-output.json missing or empty at $OUT" >&2
  exit 1
fi

n_records=$(jq -r '.n_records' "$OUT" 2>/dev/null || echo "?")
n_passes=$(jq -r '.n_passes' "$OUT" 2>/dev/null || echo "?")
n_candidates=$(jq -r '.candidates | length' "$OUT" 2>/dev/null || echo "?")
mode=$(jq -r '.llm_mode' "$OUT" 2>/dev/null || echo "?")
pct=$(jq -r '.items_mapped_pct' "$OUT" 2>/dev/null || echo "?")
printf 'propose-taxonomy.sh: %s records → %s candidates over %s passes (mode=%s mapped_pct=%s) → %s\n' \
  "$n_records" "$n_candidates" "$n_passes" "$mode" "$pct" "$OUT" >&2

exit 0
