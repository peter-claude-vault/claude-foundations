#!/usr/bin/env bash
# skills/meeting-note-ingestor-granola/from-granola.sh — SP13 T-11 connector wrapper.
#
# Granola MCP transcript JSON → foundation-portable meeting-note-ingestor.
# This is a thin orchestration layer; the JSON parsing + frontmatter assembly
# lives in skills/meeting-note-ingestor/.
#
# OUTPUT CONTRACT (R-43):
#   Files written: pass-through to the portable ingestor; zero by default
#                  (stdout). With --output PATH, writes one structured note file.
#   Schema-types:  inherited from meeting-note-ingestor (pf-conformant +
#                  meeting-note fields).
#   Pre-write validation: Granola JSON existence checked. Portable ingestor
#                  existence checked. JSON shape validated by the portable
#                  ingestor's granola.sh parser (not re-validated here).
#   Failure mode:  BLOCK AND LOG. Non-zero exit on missing inputs or missing
#                  ingestor. Otherwise inherits the portable ingestor's exit
#                  semantics (rc passes through).
#
# CONSTRAINTS (R-23): bash 3.2.57.
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP13 Session 9

set -u

_usage() {
  cat >&2 <<'EOF'
Usage: from-granola.sh --granola-json PATH [options]

Required:
  --granola-json PATH       Granola transcript JSON file.

Options:
  --output PATH|-           Pass-through to portable ingestor; - = stdout (default).
  --ingestor PATH           Override portable ingestor path (default:
                            ../meeting-note-ingestor/ingest.sh sibling).
  --title STR               Pass-through.
  --date YYYY-MM-DD         Pass-through.
  --surface-id ID           Pass-through.
  --pf-lib PATH             Pass-through.
  -h|--help                 Show this help.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEFAULT_INGESTOR="$(cd "$SCRIPT_DIR/../meeting-note-ingestor" 2>/dev/null && pwd)/ingest.sh"

GRANOLA_JSON=""
OUTPUT="-"
INGESTOR="$DEFAULT_INGESTOR"
TITLE_OVERRIDE=""
DATE_OVERRIDE=""
SURFACE_ID=""
PF_LIB=""

while [ $# -gt 0 ]; do
  case "$1" in
    --granola-json) GRANOLA_JSON="$2"; shift 2 ;;
    --output)       OUTPUT="$2"; shift 2 ;;
    --ingestor)     INGESTOR="$2"; shift 2 ;;
    --title)        TITLE_OVERRIDE="$2"; shift 2 ;;
    --date)         DATE_OVERRIDE="$2"; shift 2 ;;
    --surface-id)   SURFACE_ID="$2"; shift 2 ;;
    --pf-lib)       PF_LIB="$2"; shift 2 ;;
    -h|--help)      _usage; exit 0 ;;
    *)
      printf 'from-granola.sh: unknown arg: %s\n' "$1" >&2
      _usage
      exit 2
      ;;
  esac
done

if [ -z "$GRANOLA_JSON" ]; then
  printf 'from-granola.sh FAIL: --granola-json required\n' >&2
  exit 2
fi
if [ ! -f "$GRANOLA_JSON" ]; then
  printf 'from-granola.sh FAIL: granola JSON not found: %s\n' "$GRANOLA_JSON" >&2
  exit 2
fi
if [ ! -f "$INGESTOR" ]; then
  printf 'from-granola.sh FAIL: portable ingestor not found: %s\n' "$INGESTOR" >&2
  exit 2
fi

# Build pass-through arg vector.
set -- --transcript "$GRANOLA_JSON" --format granola --output "$OUTPUT"
[ -n "$TITLE_OVERRIDE" ] && set -- "$@" --title "$TITLE_OVERRIDE"
[ -n "$DATE_OVERRIDE" ]  && set -- "$@" --date  "$DATE_OVERRIDE"
[ -n "$SURFACE_ID" ]     && set -- "$@" --surface-id "$SURFACE_ID"
[ -n "$PF_LIB" ]         && set -- "$@" --pf-lib "$PF_LIB"

exec bash "$INGESTOR" "$@"
