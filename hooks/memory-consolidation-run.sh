#!/bin/bash
# Background consolidation runner — performs mechanical auto-fix operations.
# Spawned by memory-consolidation-check.sh. Runs detached.
# Only does auto-fix checks: staleness, orphans, dead refs, temporal hygiene, budget.
# Manual checks (overlap, status verification, conflicts) stay in /librarian invocation.
set -euo pipefail

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
MEMORY_DIR="$(resolve_memory_dir)"
STATE_FILE="$MEMORY_DIR/.consolidation-state.json"
LOCK_FILE="$MEMORY_DIR/.consolidation.lock"
LOG_FILE="$MEMORY_DIR/.consolidation-log.md"
INDEX_FILE="$MEMORY_DIR/MEMORY.md"

# Section E-2 toggle (Plan 71 SP10 T-5): short-circuit when user opted out via
# /onboard. Default-enabled; opt-out is explicit `false`. Audit log entry
# written to $LOG_FILE before exit so absence-of-runs is observable.
hook_enabled="$(_manifest_get .behavioral.hook_preferences.memory_consolidation_enabled 2>/dev/null || true)"
if [ "$hook_enabled" = "false" ]; then
  mkdir -p "$MEMORY_DIR"
  printf '\n## Skipped — %s\n- Reason: user-manifest hook_preferences.memory_consolidation_enabled=false\n' \
    "$(date +"%Y-%m-%d %H:%M")" >> "$LOG_FILE" 2>/dev/null || true
  exit 0
fi

START_TIME=$(date +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date +%Y-%m-%d)

FILES_SCANNED=0
STALE_FLAGGED=0
ORPHANS_ADDED=0
DEAD_REFS_REMOVED=0
TEMPORAL_FIXES=0
BUDGET_STATUS="GREEN"
ERRORS=""

cleanup() {
  rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# --- Check 1: Staleness scan ---
# Flag files with last_verified >7 days old or missing
for f in "$MEMORY_DIR"/*.md; do
  [[ "$(basename "$f")" == "MEMORY.md" ]] && continue
  [[ ! -f "$f" ]] && continue
  FILES_SCANNED=$((FILES_SCANNED + 1))

  # Extract last_verified from frontmatter
  LAST_VERIFIED=$(awk '/^---$/{n++; next} n==1 && /^last_verified:/{sub(/^last_verified: */, ""); print; exit}' "$f")

  if [[ -z "$LAST_VERIFIED" ]]; then
    STALE_FLAGGED=$((STALE_FLAGGED + 1))
    continue
  fi

  # Calculate age in days
  LV_EPOCH=$(date -jf "%Y-%m-%d" "$LAST_VERIFIED" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  AGE_DAYS=$(( (NOW_EPOCH - LV_EPOCH) / 86400 ))

  if [[ "$AGE_DAYS" -gt 7 ]]; then
    STALE_FLAGGED=$((STALE_FLAGGED + 1))
  fi
done

# --- Check 4: Orphan check ---
# Memory files not referenced in MEMORY.md
if [[ -f "$INDEX_FILE" ]]; then
  for f in "$MEMORY_DIR"/*.md; do
    BASE=$(basename "$f")
    [[ "$BASE" == "MEMORY.md" ]] && continue
    [[ ! -f "$f" ]] && continue

    if ! grep -q "$BASE" "$INDEX_FILE" 2>/dev/null; then
      # Extract name and description from frontmatter for index entry
      NAME=$(awk '/^---$/{n++; next} n==1 && /^name:/{sub(/^name: */, ""); print; exit}' "$f")
      DESC=$(awk '/^---$/{n++; next} n==1 && /^description:/{sub(/^description: */, ""); print; exit}' "$f")
      TYPE=$(awk '/^---$/{n++; next} n==1 && /^type:/{sub(/^type: */, ""); print; exit}' "$f")

      if [[ -n "$NAME" ]]; then
        # Find the right section header and append
        SECTION_HEADER=""
        case "$TYPE" in
          user) SECTION_HEADER="## User" ;;
          feedback) SECTION_HEADER="## Feedback" ;;
          project) SECTION_HEADER="## Project" ;;
          reference) SECTION_HEADER="## Reference" ;;
        esac

        if [[ -n "$SECTION_HEADER" ]] && grep -q "^$SECTION_HEADER" "$INDEX_FILE"; then
          # Append entry after the section header
          ENTRY="- [${BASE}](memory/${BASE}) — ${DESC}"
          # Use awk to insert after the section header's last entry (or right after header if empty)
          awk -v hdr="$SECTION_HEADER" -v entry="$ENTRY" '
            $0 == hdr { in_section=1; print; next }
            in_section && /^$/ { print entry; in_section=0 }
            in_section && /^## / { print entry; print ""; in_section=0 }
            { print }
            END { if (in_section) print entry }
          ' "$INDEX_FILE" > "${INDEX_FILE}.tmp" && mv "${INDEX_FILE}.tmp" "$INDEX_FILE"
          ORPHANS_ADDED=$((ORPHANS_ADDED + 1))
        fi
      fi
    fi
  done
fi

# --- Check 5: Index accuracy ---
# Entries in MEMORY.md pointing to files that don't exist
if [[ -f "$INDEX_FILE" ]]; then
  TEMP_INDEX="${INDEX_FILE}.tmp.$$"
  REMOVED=false
  while IFS= read -r line; do
    if [[ "$line" =~ ^\-\ \[([^\]]+)\] ]]; then
      REF_FILE="${BASH_REMATCH[1]}"
      if [[ ! -f "$MEMORY_DIR/$REF_FILE" ]]; then
        DEAD_REFS_REMOVED=$((DEAD_REFS_REMOVED + 1))
        REMOVED=true
        continue  # Skip this line
      fi
    fi
    printf '%s\n' "$line" >> "$TEMP_INDEX"
  done < "$INDEX_FILE"

  if [[ "$REMOVED" == "true" ]]; then
    mv "$TEMP_INDEX" "$INDEX_FILE"
  else
    rm -f "$TEMP_INDEX"
  fi
fi

# --- Check 7: Temporal hygiene ---
# Scan for relative date patterns and convert to absolute
# Only fix clear-cut patterns outside quotes
RELATIVE_PATTERNS='(^|[^"'"'"'])\b(yesterday|today|tomorrow|last week|this week|next week|last month|this month|next month)\b([^"'"'"']|$)'

for f in "$MEMORY_DIR"/*.md; do
  [[ "$(basename "$f")" == "MEMORY.md" ]] && continue
  [[ ! -f "$f" ]] && continue

  # Check if file contains any relative date patterns (outside frontmatter)
  BODY=$(awk '/^---$/{n++; next} n>=2{print}' "$f")
  if echo "$BODY" | grep -iEq "$RELATIVE_PATTERNS"; then
    # Get anchor date
    ANCHOR=$(awk '/^---$/{n++; next} n==1 && /^last_verified:/{sub(/^last_verified: */, ""); print; exit}' "$f")
    if [[ -z "$ANCHOR" ]]; then
      ANCHOR=$(stat -f "%Sm" -t "%Y-%m-%d" "$f" 2>/dev/null || echo "$TODAY")
    fi

    # For safety, only fix "yesterday"/"today"/"tomorrow" — the most unambiguous patterns
    # More complex patterns (weekday names, "N days ago") need context and are better left to manual
    ANCHOR_EPOCH=$(date -jf "%Y-%m-%d" "$ANCHOR" +%s 2>/dev/null || continue)

    YESTERDAY=$(date -jf "%s" "$((ANCHOR_EPOCH - 86400))" +%Y-%m-%d)
    TOMORROW=$(date -jf "%s" "$((ANCHOR_EPOCH + 86400))" +%Y-%m-%d)

    # Only replace outside frontmatter, and only if not inside quotes
    CHANGED=false
    TEMP_FILE="${f}.tmp.$$"

    IN_FRONTMATTER=false
    FM_COUNT=0
    while IFS= read -r line; do
      if [[ "$line" == "---" ]]; then
        FM_COUNT=$((FM_COUNT + 1))
        if [[ "$FM_COUNT" -le 2 ]]; then
          IN_FRONTMATTER=true
          [[ "$FM_COUNT" -eq 2 ]] && IN_FRONTMATTER=false
        fi
        printf '%s\n' "$line" >> "$TEMP_FILE"
        continue
      fi

      if [[ "$IN_FRONTMATTER" == "false" ]] && [[ "$FM_COUNT" -ge 2 ]]; then
        # Skip lines that look like quotes
        if echo "$line" | grep -qE '"[^"]*\b(yesterday|today|tomorrow)\b[^"]*"'; then
          printf '%s\n' "$line" >> "$TEMP_FILE"
          continue
        fi

        ORIG="$line"
        # Case-insensitive replacements
        line=$(echo "$line" | sed -E "s/\byesterday\b/$YESTERDAY/gi")
        line=$(echo "$line" | sed -E "s/\btoday\b/$ANCHOR/gi")
        line=$(echo "$line" | sed -E "s/\btomorrow\b/$TOMORROW/gi")

        if [[ "$line" != "$ORIG" ]]; then
          CHANGED=true
          TEMPORAL_FIXES=$((TEMPORAL_FIXES + 1))
        fi
      fi

      printf '%s\n' "$line" >> "$TEMP_FILE"
    done < "$f"

    if [[ "$CHANGED" == "true" ]]; then
      mv "$TEMP_FILE" "$f"
    else
      rm -f "$TEMP_FILE"
    fi
  fi
done

# --- Check 8: Budget monitor ---
if [[ -f "$INDEX_FILE" ]]; then
  LINE_COUNT=$(wc -l < "$INDEX_FILE" | tr -d ' ')
  ENTRY_COUNT=$(grep -c '^\- \[' "$INDEX_FILE" || echo 0)
  PERCENTAGE=$(( LINE_COUNT * 100 / 200 ))

  if [[ "$PERCENTAGE" -ge 90 ]]; then
    BUDGET_STATUS="RED"
  elif [[ "$PERCENTAGE" -ge 75 ]]; then
    BUDGET_STATUS="YELLOW"
  else
    BUDGET_STATUS="GREEN"
  fi
fi

# --- Write consolidation log ---
END_TIME=$(date +%s)
DURATION_MS=$(( (END_TIME - START_TIME) * 1000 ))

# Read current total
TOTAL=$(jq -r '.total_consolidations // 0' "$STATE_FILE")
TOTAL=$((TOTAL + 1))

# Append to log
cat >> "$LOG_FILE" <<EOF

## Consolidation ${TOTAL} — $(date +"%Y-%m-%d %H:%M")
- Files scanned: ${FILES_SCANNED}
- Stale files flagged: ${STALE_FLAGGED}
- Orphans added to index: ${ORPHANS_ADDED}
- Dead references removed: ${DEAD_REFS_REMOVED}
- Temporal fixes applied: ${TEMPORAL_FIXES}
- Budget status: ${BUDGET_STATUS} (${LINE_COUNT:-0}/200)
- Duration: ${DURATION_MS}ms
EOF

# --- Update state ---
jq \
  --arg ts "$NOW_ISO" \
  --argjson total "$TOTAL" \
  '.last_consolidation = $ts | .sessions_since = 0 | .total_consolidations = $total | .last_result = "success" | .last_error = null' \
  "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

# Lock file removed by trap
exit 0
