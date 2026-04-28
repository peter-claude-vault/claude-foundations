#!/usr/bin/env bash
# archetype-inference.sh — SP01 T-7a
#
# Consumes a Section B + C extracted-transcript JSON (on stdin or as a
# file arg) and emits a strict JSON decision:
#   {archetype, confidence, margin, score_top, score_runner_up}
#
# Keyword tables are loaded at runtime from
#   $HOME/.claude/onboarding/archetype-keywords.json
# Override with KEYWORDS_FILE=<path> for testing. No hardcoded bucket
# names or keyword lists — archetypes are enumerated via
#   jq '.archetypes | keys[]'
# and positive/negative lists are read per archetype.
#
# Tokenization
#   The transcript JSON is flattened to its string leaves
#   (jq '[.. | strings] | .[]'), lowercased, and joined into a single
#   space-separated corpus line. Each token is matched with
#   `grep -Fwi` (fixed string, case-insensitive, word-boundary). Single
#   words therefore require surrounding non-word characters (so "deploy"
#   does NOT match "deployable"); multi-word phrases require the exact
#   phrase bounded by word boundaries at both ends. Each token in a
#   positive/negative list contributes 0 or 1 (distinct-token count) per
#   the design contract.
#
# Scoring
#   positive_hits(A) = #distinct positive tokens present in corpus
#   negative_hits(A) = #distinct negative tokens present in corpus
#   score(A)         = positive_hits(A) - 0.5 * negative_hits(A)
#
#   Integer math: the script carries scores as (2 * score) so the
#   half-weight on negatives stays exact; the final JSON divides back.
#
# Selection
#   top       = argmax_A score(A)
#   runner_up = second-highest score(A)
#   IF score(top) >= 2 AND (score(top) - score(runner_up)) >= 1:
#       archetype = top
#   ELSE:
#       archetype = "generalist"
#
# Confidence
#   max(0.0, min(1.0, score(top) / 6.0))
#   The divisor 6 is a tuning surface (design doc §9) — retune at T-13's
#   round-trip fixture gate. Unit tests surface observed score_top per
#   fixture to inform that pass.
#
# bash 3.2 compatible (R-23): no `declare -A`, no `mapfile`/`readarray`,
# no `${var,,}` (uses `tr '[:upper:]' '[:lower:]'`), no regex capture
# groups beyond BASH_REMATCH.

set -u

KEYWORDS_FILE="${KEYWORDS_FILE:-$HOME/.claude/onboarding/archetype-keywords.json}"

if [ ! -r "$KEYWORDS_FILE" ]; then
  echo "archetype-inference: keyword file not readable: $KEYWORDS_FILE" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "archetype-inference: jq not on PATH" >&2
  exit 2
fi

# --- Read transcript ---------------------------------------------------
if [ "$#" -ge 1 ] && [ -n "$1" ] && [ "$1" != "-" ]; then
  if [ ! -r "$1" ]; then
    echo "archetype-inference: transcript file not readable: $1" >&2
    exit 2
  fi
  transcript_json=$(cat "$1")
else
  transcript_json=$(cat)
fi

# --- Build corpus: all string leaves, lowercased, space-joined ---------
# jq '[.. | strings]' emits every string value at any depth. Empty
# transcripts yield an empty corpus and all scores collapse to zero.
corpus=$(printf '%s' "$transcript_json" \
  | jq -r '[.. | strings] | .[]' 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' \
  | tr '\n' ' ')

# Ensure corpus is at least an empty string (never unset)
corpus="${corpus:-}"

# --- Hit counter -------------------------------------------------------
# Args: archetype, polarity (positive|negative)
# Echoes the count of distinct tokens from that list present in corpus.
count_hits() {
  arch="$1"
  polarity="$2"
  hits=0
  # Use --arg for safe interpolation
  tokens=$(jq -r --arg a "$arch" --arg p "$polarity" \
    '.archetypes[$a][$p] // [] | .[]' "$KEYWORDS_FILE")
  # Empty list → no hits (generalist path)
  if [ -z "$tokens" ]; then
    printf '%s' 0
    return 0
  fi
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    tok_lc=$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]')
    # grep -Fwiq: fixed, word-boundary, case-insensitive, quiet
    if printf '%s\n' "$corpus" | grep -Fwiq -- "$tok_lc"; then
      hits=$((hits + 1))
    fi
  done <<EOF
$tokens
EOF
  printf '%s' "$hits"
}

# --- Score each archetype ---------------------------------------------
archetypes=$(jq -r '.archetypes | keys[]' "$KEYWORDS_FILE")

scored=""
while IFS= read -r arch; do
  [ -z "$arch" ] && continue
  pos=$(count_hits "$arch" "positive")
  neg=$(count_hits "$arch" "negative")
  # score = pos - 0.5*neg → carry as 2*score = 2*pos - neg
  score_x2=$(( 2 * pos - neg ))
  scored="${scored}${arch} ${score_x2} ${pos} ${neg}
"
done <<EOF
$archetypes
EOF

# --- Rank: top + runner_up --------------------------------------------
# Sort descending by score_x2 (numeric, reverse). Ties fall back to
# whatever lexical order `sort` gives — the margin check eliminates
# real ties anyway.
sorted=$(printf '%s' "$scored" | awk 'NF >= 4' | sort -t' ' -k2,2 -n -r)

top_line=$(printf '%s\n' "$sorted" | sed -n 1p)
runner_up_line=$(printf '%s\n' "$sorted" | sed -n 2p)

top_arch=$(printf '%s' "$top_line" | awk '{print $1}')
top_score_x2=$(printf '%s' "$top_line" | awk '{print $2}')
runner_up_score_x2=$(printf '%s' "$runner_up_line" | awk '{print $2}')
[ -z "$top_score_x2" ] && top_score_x2=0
[ -z "$runner_up_score_x2" ] && runner_up_score_x2=0

# --- Selection ---------------------------------------------------------
# Read scoring constants from JSON (no hardcoded values, no hardcoded
# fallback-label — everything is sourced from archetype-keywords.json).
min_score=$(jq -r '.scoring.min_score'          "$KEYWORDS_FILE")
min_margin=$(jq -r '.scoring.min_margin'        "$KEYWORDS_FILE")
neg_weight=$(jq -r '.scoring.negative_weight'   "$KEYWORDS_FILE")
fallback=$(jq -r   '.scoring.fallback_archetype' "$KEYWORDS_FILE")

# Internal scores are 2*score to keep half-weights exact; thresholds
# therefore multiply by 2 as well. This assumes negative_weight=0.5 —
# assert it so a future JSON change surfaces here rather than silently
# miscounting.
if [ "$neg_weight" != "0.5" ]; then
  echo "archetype-inference: negative_weight=$neg_weight not supported (expected 0.5)" >&2
  echo "  Update the integer-scaling in archetype-inference.sh before changing this." >&2
  exit 2
fi

min_score_x2=$(( min_score * 2 ))
min_margin_x2=$(( min_margin * 2 ))
margin_x2=$(( top_score_x2 - runner_up_score_x2 ))

if [ "$top_score_x2" -ge "$min_score_x2" ] && [ "$margin_x2" -ge "$min_margin_x2" ]; then
  chosen="$top_arch"
else
  chosen="$fallback"
fi

# --- Format output (floats via awk; bash 3.2 has no float math) --------
emit=$(awk -v chosen="$chosen" \
           -v st2="$top_score_x2" \
           -v sr2="$runner_up_score_x2" \
           -v m2="$margin_x2" '
BEGIN {
  top_score       = st2 / 2.0
  runner_up_score = sr2 / 2.0
  margin          = m2 / 2.0
  conf            = top_score / 6.0
  if (conf > 1.0) conf = 1.0
  if (conf < 0.0) conf = 0.0
  printf "{\n"
  printf "  \"archetype\": \"%s\",\n", chosen
  printf "  \"confidence\": %.3f,\n", conf
  printf "  \"margin\": %.1f,\n", margin
  printf "  \"score_top\": %.1f,\n", top_score
  printf "  \"score_runner_up\": %.1f\n", runner_up_score
  printf "}\n"
}
')

# Validate our own JSON before emitting (belt and suspenders)
if ! printf '%s' "$emit" | jq -e . >/dev/null 2>&1; then
  echo "archetype-inference: internal error — emitted non-JSON" >&2
  printf '%s\n' "$emit" >&2
  exit 3
fi

printf '%s' "$emit"
