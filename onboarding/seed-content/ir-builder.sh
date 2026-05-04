#!/usr/bin/env bash
# ir-builder.sh — SP13 T-3 Stage 1 IR builder.
#
# Consumes intake manifest + format-detector + per-format parsers; emits a
# JSONL IR file conforming to schemas/seed-content-ir-schema.json.
#
# Usage:
#   ir-builder.sh --manifest <intake.jsonl> --ir <ir.jsonl> [--batch-cap N]
#
# Default batch cap: 100 (Capacities precedent, SP13 spec L125).
# Progress emitted on stderr per batch:
#   [batch K/N] processing items <start>..<end>
#
# "Format not supported" is REPORTED (not silently skipped) — a record with
# format="unsupported" is emitted carrying a marker in normalized_text.
#
# Bash 3.2 compatible (R-23).

set -u

MANIFEST=""
IR_OUT=""
BATCH_CAP=100

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)
      shift
      [ $# -gt 0 ] || { echo "ir-builder.sh: --manifest requires a path" >&2; exit 2; }
      MANIFEST="$1"
      ;;
    --ir)
      shift
      [ $# -gt 0 ] || { echo "ir-builder.sh: --ir requires a path" >&2; exit 2; }
      IR_OUT="$1"
      ;;
    --batch-cap)
      shift
      [ $# -gt 0 ] || { echo "ir-builder.sh: --batch-cap requires N" >&2; exit 2; }
      BATCH_CAP="$1"
      ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ir-builder.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

[ -n "$MANIFEST" ] || { echo "ir-builder.sh: --manifest required" >&2; exit 2; }
[ -n "$IR_OUT" ]   || { echo "ir-builder.sh: --ir required" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "ir-builder.sh: manifest not found: $MANIFEST" >&2; exit 2; }

case "$BATCH_CAP" in
  ''|*[!0-9]*) echo "ir-builder.sh: --batch-cap must be a positive integer" >&2; exit 2 ;;
esac
[ "$BATCH_CAP" -gt 0 ] || { echo "ir-builder.sh: --batch-cap must be > 0" >&2; exit 2; }

mkdir -p "$(dirname "$IR_OUT")"
: > "$IR_OUT"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
DETECTOR="$SELF_DIR/format-detector.sh"
PARSER_DIR="$SELF_DIR/format-parsers"

[ -x "$DETECTOR" ] || { echo "ir-builder.sh: format-detector.sh missing or not executable" >&2; exit 2; }
[ -d "$PARSER_DIR" ] || { echo "ir-builder.sh: format-parsers/ missing" >&2; exit 2; }

total=$(wc -l < "$MANIFEST" | tr -d ' ')
if [ "$total" -eq 0 ]; then
  printf 'ir-builder.sh: empty manifest; no IR records emitted\n' >&2
  exit 0
fi

cap="$BATCH_CAP"
n_batches=$(( (total + cap - 1) / cap ))

batch=0
while [ "$batch" -lt "$n_batches" ]; do
  start=$(( batch * cap ))
  end=$(( start + cap ))
  [ "$end" -gt "$total" ] && end="$total"
  printf '[batch %s/%s] processing items %s..%s\n' \
    "$((batch + 1))" "$n_batches" "$((start + 1))" "$end" >&2

  sed -n "$((start + 1)),${end}p" "$MANIFEST" | while IFS= read -r record; do
    p=$(printf '%s' "$record" | jq -r '.path')
    rb=$(printf '%s' "$record" | jq -r '.size_bytes')

    fmt=$(bash "$DETECTOR" "$p")

    sh=""
    if [ -f "$p" ]; then
      sh=$(shasum -a 256 "$p" 2>/dev/null | awk '{print $1}' | cut -c1-16)
    fi
    [ -n "$sh" ] || sh="0000000000000000"

    nt_file=$(mktemp "${TMPDIR:-/tmp}/sp13-ir-nt-XXXXXX")
    parser="$PARSER_DIR/${fmt}.sh"

    if [ "$fmt" = "unsupported" ] || [ ! -f "$parser" ]; then
      printf '[format not supported: %s]\n' "$fmt" > "$nt_file"
      fmt="unsupported"
    else
      bash "$parser" "$p" > "$nt_file" 2>/dev/null || true
      [ -s "$nt_file" ] || printf '[parser produced empty output]\n' > "$nt_file"
    fi

    jq -nc \
      --arg path "$p" \
      --arg format "$fmt" \
      --arg detected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson raw_bytes "$rb" \
      --rawfile normalized_text "$nt_file" \
      --arg source_hash "$sh" \
      '{path:$path, format:$format, detected_at:$detected_at, raw_bytes:$raw_bytes, normalized_text:$normalized_text, metadata:{}, source_hash:$source_hash}' \
      >> "$IR_OUT"

    rm -f "$nt_file"
  done

  batch=$((batch + 1))
done

count=$(wc -l < "$IR_OUT" | tr -d ' ')
printf 'ir-builder.sh: %s IR records emitted to %s\n' "$count" "$IR_OUT" >&2
exit 0
