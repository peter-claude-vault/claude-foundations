#!/usr/bin/env bash
# cluster.sh — SP13 T-4 Stage 2 entry: thin shell wrapper over cluster.py.
#
# Consumes a Stage 1 IR JSONL file (schemas/seed-content-ir-schema.json) and
# produces onboarding/seed-content/state/cluster-output.json (gitignored).
#
# Usage:
#   cluster.sh --ir <ir.jsonl> [--out <cluster-output.json>] \
#              [--min-cluster-size N] [--eps F] \
#              [--embedding-mode {stub|voyage|auto}]
#
# Defaults:
#   --out                 onboarding/seed-content/state/cluster-output.json
#                         (relative to foundation-repo root)
#   --min-cluster-size    3
#   --eps                 0.45 (cosine-distance neighborhood radius)
#   --embedding-mode      auto (voyage when VOYAGE_API_KEY set; stub otherwise)
#
# Output cluster-output.json schema (cluster-output/1):
#   {
#     "schema_version": "cluster-output/1",
#     "embedding_mode": "stub" | "voyage",
#     "n_records": <int>,
#     "n_clusters": <int>,                 # excludes unclassified
#     "min_cluster_size": <int>,
#     "small_corpus": <bool>,
#     "small_corpus_message": <str|null>,
#     "clusters": [
#       {
#         "cluster_id": "c0001" | "unclassified",
#         "members": [{"path": "...", "source_hash": "..."}, ...],
#         "confidence": 0.0..1.0,
#         "centroid_topic_keywords": [...],
#         "low_confidence": <bool>          # confidence < 0.5
#       }, ...
#     ]
#   }
#
# Bash 3.2 compatible (R-23). Pure stdlib python3 (no numpy/sklearn/hdbscan).

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SELF_DIR/cluster.py"

if [ ! -f "$HELPER" ]; then
  echo "cluster.sh: cluster.py helper missing at $HELPER" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "cluster.sh: python3 not found on PATH" >&2
  exit 2
fi

IR=""
OUT=""
MIN_CLUSTER_SIZE=3
EPS="0.45"
EMBEDDING_MODE="auto"

while [ $# -gt 0 ]; do
  case "$1" in
    --ir)
      shift
      [ $# -gt 0 ] || { echo "cluster.sh: --ir requires a path" >&2; exit 2; }
      IR="$1"
      ;;
    --out)
      shift
      [ $# -gt 0 ] || { echo "cluster.sh: --out requires a path" >&2; exit 2; }
      OUT="$1"
      ;;
    --min-cluster-size)
      shift
      [ $# -gt 0 ] || { echo "cluster.sh: --min-cluster-size requires N" >&2; exit 2; }
      MIN_CLUSTER_SIZE="$1"
      ;;
    --eps)
      shift
      [ $# -gt 0 ] || { echo "cluster.sh: --eps requires F" >&2; exit 2; }
      EPS="$1"
      ;;
    --embedding-mode)
      shift
      [ $# -gt 0 ] || { echo "cluster.sh: --embedding-mode requires {stub|voyage|auto}" >&2; exit 2; }
      EMBEDDING_MODE="$1"
      ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "cluster.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

[ -n "$IR" ] || { echo "cluster.sh: --ir required" >&2; exit 2; }
[ -f "$IR" ] || { echo "cluster.sh: ir not found: $IR" >&2; exit 2; }

case "$MIN_CLUSTER_SIZE" in
  ''|*[!0-9]*) echo "cluster.sh: --min-cluster-size must be a positive integer" >&2; exit 2 ;;
esac
[ "$MIN_CLUSTER_SIZE" -ge 2 ] || { echo "cluster.sh: --min-cluster-size must be >= 2" >&2; exit 2; }

case "$EMBEDDING_MODE" in
  stub|voyage|auto) ;;
  *) echo "cluster.sh: --embedding-mode must be stub | voyage | auto" >&2; exit 2 ;;
esac

if [ -z "$OUT" ]; then
  REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
  OUT="$REPO_ROOT/onboarding/seed-content/state/cluster-output.json"
fi

mkdir -p "$(dirname "$OUT")"

python3 "$HELPER" \
  --ir "$IR" \
  --out "$OUT" \
  --min-cluster-size "$MIN_CLUSTER_SIZE" \
  --eps "$EPS" \
  --embedding-mode "$EMBEDDING_MODE"
RC=$?

if [ "$RC" -ne 0 ]; then
  echo "cluster.sh: cluster.py exited $RC" >&2
  exit "$RC"
fi

if [ ! -s "$OUT" ]; then
  echo "cluster.sh: cluster-output.json missing or empty at $OUT" >&2
  exit 1
fi

n_records=$(jq -r '.n_records' "$OUT" 2>/dev/null || echo "?")
n_clusters=$(jq -r '.n_clusters' "$OUT" 2>/dev/null || echo "?")
small=$(jq -r '.small_corpus' "$OUT" 2>/dev/null || echo "?")
mode=$(jq -r '.embedding_mode' "$OUT" 2>/dev/null || echo "?")
printf 'cluster.sh: %s records → %s clusters (mode=%s small_corpus=%s) → %s\n' \
  "$n_records" "$n_clusters" "$mode" "$small" "$OUT" >&2

exit 0
