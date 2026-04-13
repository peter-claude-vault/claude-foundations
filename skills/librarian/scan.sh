#!/usr/bin/env bash
# skills/librarian/scan.sh — minimal viable `/librarian scan` implementation.
#
# Reads the user manifest, walks the vault root (or $HOME if no vault),
# computes basic conventions (file counts, frontmatter coverage, naming
# pattern), and enriches the manifest at vault.discovered_conventions.
#
# Environment:
#   CLAUDE_HOME      defaults to $HOME/.claude
#   CLAUDE_MANIFEST  defaults to $CLAUDE_HOME/user-manifest.json

set -euo pipefail

CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
MANIFEST="${CLAUDE_MANIFEST:-$CLAUDE_DIR/user-manifest.json}"
SCHEMA_VALIDATOR="$CLAUDE_DIR/manifest/validate-manifest.sh"

die() { echo "[librarian:scan] error: $*" >&2; exit 1; }
info() { echo "[librarian:scan] $*"; }

command -v jq >/dev/null 2>&1 || die "jq is required"

[[ -f "$MANIFEST" ]] || die "no manifest at $MANIFEST. Run /onboard-foundation first."
jq -e . "$MANIFEST" >/dev/null 2>&1 || die "manifest is not valid JSON"

VAULT_ROOT_RAW=$(jq -r '.vault.root // ""' "$MANIFEST")
NO_VAULT=0
if [[ -z "$VAULT_ROOT_RAW" || "$VAULT_ROOT_RAW" == "null" ]]; then
  NO_VAULT=1
  TARGET="$HOME"
  info "no vault.root in manifest — scanning \$HOME ($TARGET) instead"
else
  TARGET="${VAULT_ROOT_RAW/#\~/$HOME}"
fi

[[ -d "$TARGET" ]] || die "scan target does not exist: $TARGET"

PROTECTED=()
while IFS= read -r line; do
  [[ -n "$line" ]] && PROTECTED+=("$line")
done < <(jq -r '.vault.protected_paths // [] | .[]' "$MANIFEST")

is_protected() {
  local rel="$1"
  local p
  for p in "${PROTECTED[@]:-}"; do
    [[ -z "$p" ]] && continue
    [[ "$rel" == "$p" || "$rel" == "$p/"* ]] && return 0
  done
  return 1
}

SKIPPED_JSON='[]'
for p in "${PROTECTED[@]:-}"; do
  [[ -z "$p" ]] && continue
  SKIPPED_JSON=$(jq --arg p "$p" '. + [$p]' <<<"$SKIPPED_JSON")
done

FILE_COUNTS_JSON='{}'
MD_TOTAL=0
MD_WITH_FM=0
KEBAB=0; SNAKE=0; TITLE=0; OTHER=0

while IFS= read -r -d '' f; do
  rel="${f#$TARGET/}"
  top="${rel%%/*}"
  [[ "$top" == .* ]] && continue
  is_protected "$top" && continue
  FILE_COUNTS_JSON=$(jq --arg k "$top" '.[$k] = ((.[$k] // 0) + 1)' <<<"$FILE_COUNTS_JSON")

  if [[ "$f" == *.md ]]; then
    MD_TOTAL=$((MD_TOTAL + 1))
    if head -n 1 "$f" 2>/dev/null | grep -q '^---$'; then
      if awk 'NR==1{if($0!="---")exit 1;next} /^---$/{found=1;exit} END{exit !found}' "$f" 2>/dev/null; then
        MD_WITH_FM=$((MD_WITH_FM + 1))
      fi
    fi
    base=$(basename "$f" .md)
    if [[ "$base" =~ ^[a-z0-9]+(-[a-z0-9]+)+$ ]]; then
      KEBAB=$((KEBAB + 1))
    elif [[ "$base" =~ ^[a-z0-9]+(_[a-z0-9]+)+$ ]]; then
      SNAKE=$((SNAKE + 1))
    elif [[ "$base" =~ ^[A-Z][a-z0-9]*([[:space:]][A-Z][a-z0-9]*)+$ ]]; then
      TITLE=$((TITLE + 1))
    else
      OTHER=$((OTHER + 1))
    fi
  fi
done < <(find "$TARGET" -mindepth 1 -maxdepth 4 -type f -print0 2>/dev/null)

if [[ "$MD_TOTAL" -eq 0 ]]; then
  FM_COVERAGE="n/a"
else
  pct=$(( MD_WITH_FM * 100 / MD_TOTAL ))
  if   [[ "$pct" -ge 90 ]]; then FM_COVERAGE="full"
  elif [[ "$pct" -ge 20 ]]; then FM_COVERAGE="partial"
  elif [[ "$pct" -gt  0 ]]; then FM_COVERAGE="partial"
  else FM_COVERAGE="none"
  fi
fi

max=0; pattern="mixed"
for name in kebab-case:$KEBAB snake_case:$SNAKE "Title Case:$TITLE"; do
  v="${name##*:}"; k="${name%:*}"
  if (( v > max )); then max=$v; pattern="$k"; fi
done
total_classified=$((KEBAB + SNAKE + TITLE + OTHER))
if (( total_classified == 0 )); then
  pattern="n/a"
elif (( max * 2 < total_classified )); then
  pattern="mixed"
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

SUMMARY=$(jq -n \
  --arg ts "$TIMESTAMP" \
  --arg root "$TARGET" \
  --argjson counts "$FILE_COUNTS_JSON" \
  --argjson md "$MD_TOTAL" \
  --arg fm "$FM_COVERAGE" \
  --arg pat "$pattern" \
  --argjson skipped "$SKIPPED_JSON" \
  --arg src "librarian-scan" \
  --argjson novault "$NO_VAULT" \
  '{
    scan_timestamp: $ts,
    target_root: $root,
    scanned_home_fallback: ($novault == 1),
    file_counts: $counts,
    markdown_total: $md,
    frontmatter_coverage: $fm,
    naming_pattern: $pat,
    protected_paths_skipped: $skipped,
    source: $src
  }')

TMP=$(mktemp)
jq --argjson summary "$SUMMARY" --arg ts "$TIMESTAMP" '
  .vault = ((.vault // {}) | . + {
    discovered_conventions: $summary,
    discovered_file_count: ($summary.file_counts | to_entries | map(.value) | add // 0)
  })
  | .system.librarian_last_update = $ts
' "$MANIFEST" > "$TMP"

if [[ -x "$SCHEMA_VALIDATOR" ]]; then
  if ! "$SCHEMA_VALIDATOR" "$TMP" >/dev/null 2>&1; then
    rm -f "$TMP"
    die "pre-write validation failed — manifest not updated"
  fi
fi

mv "$TMP" "$MANIFEST"

echo
echo "=== Librarian Scan Summary ==="
echo "Target:               $TARGET"
[[ "$NO_VAULT" -eq 1 ]] && echo "Mode:                 \$HOME fallback (no vault.root)"
echo "Markdown files:       $MD_TOTAL"
echo "Frontmatter coverage: $FM_COVERAGE"
echo "Naming pattern:       $pattern"
echo "Protected paths:      ${PROTECTED[*]:-(none)}"
echo "Top-level dir counts:"
jq -r 'to_entries | sort_by(-.value) | .[] | "  \(.key): \(.value)"' <<<"$FILE_COUNTS_JSON"
echo
echo "Manifest enriched at $MANIFEST (source: librarian-scan)"
