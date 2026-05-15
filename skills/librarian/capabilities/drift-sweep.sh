#!/bin/bash
# drift-sweep — Standalone drift-sweep capability for librarian integration
# Phase 0 shell: dry-run mode only. Live wiring in Phase 4.
#
# Usage: drift-sweep.sh [--dry-run] [--batch-size N] [--output FILE]
#
# Scans vault .md files for frontmatter drift against governance/foundation-master.json (bundle).
# Emits structured findings compatible with librarian manifest format.
# Batch-with-progress: emits every N files to reset stream-json idle watchdog.
set -euo pipefail

source "$HOME/.claude/hooks/lib/paths.sh"
# Plan 61: source canonical findings emitter; replaces inline emit_progress.
source "$HOME/.claude/skills/librarian/lib/findings.sh"

FOUNDATION_MASTER="${FOUNDATION_MASTER:-$GOVERNANCE_DIR/foundation-master.json}"
DRY_RUN=true
BATCH_SIZE=50
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --live)       DRY_RUN=false; shift ;;
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    --output)     OUTPUT="$2"; shift 2 ;;
    *)            echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Route findings emission via findings.sh (writes to FINDINGS_OUTPUT or stdout).
export FINDINGS_OUTPUT="$OUTPUT"

if [[ ! -f "$FOUNDATION_MASTER" ]]; then
  echo "ERROR: foundation-master.json not found at $FOUNDATION_MASTER" >&2
  exit 1
fi

SCAN_COUNT=0
FINDING_COUNT=0
BATCH_COUNT=0

emit_event "{ \"drift_sweep_start\": \"$(date -Iseconds)\", \"mode\": \"$([ "$DRY_RUN" = true ] && echo 'dry-run' || echo 'live')\" }"

# Relax strict error handling inside the scan loop — per-file errors are soft
# findings, not audit-fatal (e.g., malformed YAML, grep misses, python import
# failures on pathological files should emit a finding, not halt the sweep).
set +e
set +o pipefail

while IFS= read -r -d '' file; do
  SCAN_COUNT=$((SCAN_COUNT + 1))
  REL="${file#$VAULT_ROOT/}"

  # Skip operational files
  [[ "$REL" == "Logs/librarian-manifest"* ]] && continue
  [[ "$REL" == "Logs/.coordination/"* ]] && continue
  [[ "$REL" == "CLAUDE.md" ]] && continue
  # Skip auto-memory files (claude-mem projects dir under vault root — different schema domain)
  [[ "$REL" == .claude/projects/* ]] && continue
  # Skip test/sandbox scratch paths
  [[ "$REL" == _test* ]] && continue

  # Extract frontmatter
  FM=$(awk '/^---$/{c++;next} c==1{print} c>=2{exit}' "$file" 2>/dev/null)
  [[ -z "$FM" ]] && continue

  # Check type against foundation-master bundle
  FILE_TYPE=$(echo "$FM" | grep -E '^type:' 2>/dev/null | head -1 | sed 's/^type:[[:space:]]*//' || true)
  if [[ -n "$FILE_TYPE" ]]; then
    SCHEMA_KEY=$(python3 -c "
import json, sys
bundle = json.load(open('$FOUNDATION_MASTER'))
t = sys.argv[1]
type_map = bundle.get('r32_type_aliases', {})
key = type_map.get(t, t)
types = bundle.get('frontmatter', {}).get('types', {})
if key in types and not key.startswith('_'):
    print(key)
else:
    print('')
" "$FILE_TYPE" 2>/dev/null)

    if [[ -z "$SCHEMA_KEY" ]]; then
      FINDING_COUNT=$((FINDING_COUNT + 1))
      emit_finding "unregistered_type" "$REL" "type" "$FILE_TYPE"
    else
      # Check required fields
      MISSING=$(python3 -c "
import json, yaml, sys
bundle = json.load(open('$FOUNDATION_MASTER'))
fm = yaml.safe_load(sys.stdin)
if not isinstance(fm, dict):
    sys.exit(0)
key = sys.argv[1]
types = bundle.get('frontmatter', {}).get('types', {})
req = types.get(key, {}).get('required', [])
missing = [f for f in req if f not in fm or fm[f] is None]
if missing:
    print(','.join(missing))
" "$SCHEMA_KEY" <<< "$FM" 2>/dev/null)
      if [[ -n "$MISSING" ]]; then
        FINDING_COUNT=$((FINDING_COUNT + 1))
        emit_finding "missing_required" "$REL" "schema_key" "$SCHEMA_KEY" "missing" "$MISSING"
      fi
    fi
  fi

  # Batch progress emit
  BATCH_COUNT=$((BATCH_COUNT + 1))
  if [[ $BATCH_COUNT -ge $BATCH_SIZE ]]; then
    emit_event "{ \"progress\": $SCAN_COUNT, \"findings_so_far\": $FINDING_COUNT }"
    BATCH_COUNT=0
  fi
done < <(find "$VAULT_ROOT" -name "*.md" -print0 2>/dev/null)

# Re-arm strict error handling for the final emit.
set -e
set -o pipefail

emit_event "{ \"drift_sweep_end\": \"$(date -Iseconds)\", \"files_scanned\": $SCAN_COUNT, \"findings\": $FINDING_COUNT }"
