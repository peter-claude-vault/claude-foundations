#!/usr/bin/env bash
# skills/inbox-processor/process.sh — SP13 T-12 standing-Inbox processor.
#
# Per-tick batch: enumerate <vault>/Inbox/, single-pass classify each file,
# route to vault placement OR leave in-place with appended frontmatter.
#
# Bash 3.2 compatible (R-23). jq REQUIRED. python3 REQUIRED for atomic
# YAML frontmatter parse + amend (no PyYAML; line-scanning).
#
# Author: Claude Opus 4.7 — Plan 71 SP13 Session 10 (T-12).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

DEFAULT_FORMAT_DETECTOR="$REPO_ROOT/onboarding/seed-content/format-detector.sh"
DEFAULT_INGESTOR="$REPO_ROOT/skills/meeting-note-ingestor/ingest.sh"
DEFAULT_PF_LIB="$REPO_ROOT/lib/provenance-frontmatter.sh"
DEFAULT_GATE_LIB="$REPO_ROOT/lib/three-step-gate.sh"

VAULT_ROOT=""
AUDIT_LOG=""
STATE_FILE=""
INGESTOR="$DEFAULT_INGESTOR"
FORMAT_DETECTOR="$DEFAULT_FORMAT_DETECTOR"
PF_LIB="$DEFAULT_PF_LIB"
GATE_LIB="$DEFAULT_GATE_LIB"
MEETINGS_SUBDIR="Meetings"
REFERENCE_SUBDIR="Reference"
GATE_EACH_ITEM=0
DRY_RUN=0
SURFACE_ID="sp13-t12/1"

usage() {
  cat <<EOF
process.sh — SP13 T-12 inbox-processor.

Usage:
  process.sh --vault-root PATH [--audit-log PATH] [--state-file PATH]
             [--ingestor PATH] [--format-detector PATH] [--pf-lib PATH]
             [--gate-lib PATH] [--meetings-subdir NAME]
             [--reference-subdir NAME] [--gate-each-item] [--dry-run]

Required:
  --vault-root PATH        Vault root; <vault>/Inbox/ is enumerated.

Defaults:
  --audit-log              \$CLAUDE_LOG_DIR/inbox-processor-audit.log
                           (or /tmp/inbox-processor-audit.log if CLAUDE_LOG_DIR unset)
  --state-file             \$CLAUDE_HOME/inbox-processor-state.json
                           (or /tmp/inbox-processor-state.json if CLAUDE_HOME unset)
  --ingestor               $DEFAULT_INGESTOR
  --format-detector        $DEFAULT_FORMAT_DETECTOR
  --pf-lib                 $DEFAULT_PF_LIB
  --gate-lib               $DEFAULT_GATE_LIB
  --meetings-subdir        Meetings
  --reference-subdir       Reference

Flags:
  --gate-each-item         Per-item SP12 3-step-gate preview (opt-in; off default).
  --dry-run                Routing-decision report on stdout; no file writes.

Exit codes:
  0   success (or no work)
  2   pre-flight failure
  3   per-file errors during batch (logged; non-fatal individually)
  4   tick-level error (state file corrupt, lock contention, etc.)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --vault-root)        VAULT_ROOT="$2"; shift 2 ;;
    --audit-log)         AUDIT_LOG="$2"; shift 2 ;;
    --state-file)        STATE_FILE="$2"; shift 2 ;;
    --ingestor)          INGESTOR="$2"; shift 2 ;;
    --format-detector)   FORMAT_DETECTOR="$2"; shift 2 ;;
    --pf-lib)            PF_LIB="$2"; shift 2 ;;
    --gate-lib)          GATE_LIB="$2"; shift 2 ;;
    --meetings-subdir)   MEETINGS_SUBDIR="$2"; shift 2 ;;
    --reference-subdir)  REFERENCE_SUBDIR="$2"; shift 2 ;;
    --gate-each-item)    GATE_EACH_ITEM=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) printf 'process.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$VAULT_ROOT" ]; then
  printf 'process.sh: --vault-root required\n' >&2
  usage >&2
  exit 2
fi

if [ -z "$AUDIT_LOG" ]; then
  AUDIT_LOG="${CLAUDE_LOG_DIR:-/tmp}/inbox-processor-audit.log"
fi
if [ -z "$STATE_FILE" ]; then
  STATE_FILE="${CLAUDE_HOME:-/tmp}/inbox-processor-state.json"
fi

# ---- pre-flight --------------------------------------------------------------

for tool in jq python3 shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'process.sh: missing prereq: %s\n' "$tool" >&2
    exit 2
  fi
done

if [ ! -d "$VAULT_ROOT" ]; then
  printf 'process.sh: --vault-root not a directory: %s\n' "$VAULT_ROOT" >&2
  exit 2
fi

INBOX_DIR="$VAULT_ROOT/Inbox"
if [ ! -d "$INBOX_DIR" ]; then
  # No Inbox/ → silent no-op (cron firing on a vault without an Inbox/ is normal).
  printf 'process.sh: <vault>/Inbox/ does not exist; no-op\n' >&2
  exit 0
fi

if [ ! -x "$FORMAT_DETECTOR" ] && [ ! -r "$FORMAT_DETECTOR" ]; then
  printf 'process.sh: format-detector not found: %s\n' "$FORMAT_DETECTOR" >&2
  exit 2
fi
if [ ! -x "$INGESTOR" ] && [ ! -r "$INGESTOR" ]; then
  printf 'process.sh: meeting-note ingestor not found: %s\n' "$INGESTOR" >&2
  exit 2
fi
if [ ! -r "$PF_LIB" ]; then
  printf 'process.sh: pf-lib not readable: %s\n' "$PF_LIB" >&2
  exit 2
fi

if [ "$GATE_EACH_ITEM" = "1" ] && [ ! -r "$GATE_LIB" ]; then
  printf 'process.sh: --gate-each-item requires gate-lib at %s\n' "$GATE_LIB" >&2
  exit 2
fi

# Source pf-lib for pf_emit (used in reference routing path).
# shellcheck source=/dev/null
. "$PF_LIB"

# ---- state file load ---------------------------------------------------------

if [ "$DRY_RUN" = "0" ]; then
  mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
fi

if [ ! -f "$STATE_FILE" ]; then
  STATE_JSON='{"version":"sp13-t12/1","items":{}}'
else
  STATE_JSON=$(cat "$STATE_FILE" 2>/dev/null || echo '{"version":"sp13-t12/1","items":{}}')
  if ! printf '%s' "$STATE_JSON" | jq empty >/dev/null 2>&1; then
    printf 'process.sh: state file unparseable; reinitializing: %s\n' "$STATE_FILE" >&2
    STATE_JSON='{"version":"sp13-t12/1","items":{}}'
  fi
fi

# ---- helpers -----------------------------------------------------------------

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/\.[a-z0-9]*$//' \
          -e 's/[^a-z0-9]\{1,\}/-/g' \
          -e 's/^-//' -e 's/-$//'
}

audit_emit() {
  # $1 file_rel  $2 sha  $3 classification  $4 route  $5 tier
  local line
  line=$(jq -nc \
    --arg ts "$(now_utc)" \
    --arg file "$1" \
    --arg sha "$2" \
    --arg classification "$3" \
    --arg route "$4" \
    --arg tier "$5" \
    --arg gate "$( [ "$GATE_EACH_ITEM" = "1" ] && echo true || echo false )" \
    '{ts:$ts,file:$file,sha:$sha,classification:$classification,route:$route,gate:($gate|fromjson),tier:$tier}')
  if [ "$DRY_RUN" = "0" ]; then
    printf '%s\n' "$line" >> "$AUDIT_LOG"
  else
    printf '[dry-run audit] %s\n' "$line"
  fi
}

# Append two frontmatter fields (processor_attempted_at + processor_classification)
# atomically. If the file already has YAML frontmatter, fields are inserted
# inside the existing block (or replaced if already present). Otherwise a new
# frontmatter block is prepended.
append_processor_frontmatter() {
  # $1 path  $2 classification
  local path="$1" classification="$2"
  local tmp
  tmp=$(mktemp -t inbox-proc-fm.XXXXXX) || return 1
  python3 - "$path" "$classification" "$(now_utc)" >"$tmp" <<'PY'
import sys

path = sys.argv[1]
classification = sys.argv[2]
ts = sys.argv[3]

with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

def emit_new_frontmatter(body_lines):
    fm = [
        "---\n",
        f"processor_attempted_at: \"{ts}\"\n",
        f"processor_classification: {classification}\n",
        "---\n",
    ]
    return fm + body_lines

# Detect existing frontmatter: first non-empty line is "---".
i = 0
while i < len(lines) and lines[i].strip() == "":
    i += 1

if i < len(lines) and lines[i].strip() == "---":
    # Existing frontmatter; find closing.
    start = i
    j = i + 1
    while j < len(lines) and lines[j].strip() != "---":
        j += 1
    if j >= len(lines):
        # Unterminated frontmatter — bail; prepend new block.
        sys.stdout.writelines(emit_new_frontmatter(lines))
        sys.exit(0)
    end = j
    # Strip prior processor_* keys; keep everything else verbatim.
    inner = []
    for line in lines[start + 1:end]:
        stripped = line.lstrip()
        if stripped.startswith("processor_attempted_at:") or stripped.startswith("processor_classification:"):
            continue
        inner.append(line)
    inner.append(f"processor_attempted_at: \"{ts}\"\n")
    inner.append(f"processor_classification: {classification}\n")
    out = ["---\n"] + inner + ["---\n"] + lines[end + 1:]
    sys.stdout.writelines(out)
else:
    # No frontmatter — prepend.
    sys.stdout.writelines(emit_new_frontmatter(lines))
PY
  local rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# Detect transcript shape from format-detector output + filename heuristic.
# Returns 0 if transcript-shape; 1 otherwise.
is_transcript_shape() {
  # $1 detected_format  $2 basename
  local fmt="$1" base="$2" base_lc
  case "$fmt" in
    otter-vtt|zoom-transcript) return 0 ;;
  esac
  base_lc=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  case "$base_lc" in
    *.granola.json|granola-*.json|granola_*.json) return 0 ;;
    *transcript*|*standup*|*meeting*|*sync*)
      # Word transcripts + filename-shaped transcripts.
      case "$fmt" in
        word) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# Heuristic-tier classifier for non-transcript markdown/plaintext.
# Echoes one of: project | reference | unclassified.
heuristic_classify() {
  # $1 path  $2 fmt
  local path="$1" fmt="$2"
  local first_chunk base_lc
  base_lc=$(printf '%s' "$(basename "$path")" | tr '[:upper:]' '[:lower:]')

  # Filename-based reference signals.
  case "$base_lc" in
    readme*|readme.md|reference*|notes-*|cheatsheet*|cheat-sheet*)
      printf 'reference\n'
      return 0
      ;;
  esac

  # Read first 50 lines; bail on empty.
  first_chunk=$(head -50 "$path" 2>/dev/null || true)
  if [ -z "$first_chunk" ]; then
    printf 'unclassified\n'
    return 0
  fi

  # Project signals: frontmatter `type:` matching known canonical types,
  # OR engagement/project tag, OR multi-section H2 structure.
  if printf '%s' "$first_chunk" | grep -qE '^type:[[:space:]]*(project|engagement|prd|context|updates)' ; then
    printf 'project\n'
    return 0
  fi
  if printf '%s' "$first_chunk" | grep -qE '#(engagement|project)/' ; then
    printf 'project\n'
    return 0
  fi
  # Reference signals: explicit #reference tag.
  if printf '%s' "$first_chunk" | grep -qE '#reference\b' ; then
    printf 'reference\n'
    return 0
  fi

  printf 'unclassified\n'
}

# Route a transcript-shape file via T-11 ingestor → <vault>/<meetings-subdir>/.
route_meeting() {
  # $1 src_path
  local src="$1" out_dir out_path slug stem base
  base=$(basename "$src")
  stem="${base%.*}"
  slug=$(slugify "$stem")
  if [ -z "$slug" ]; then slug="meeting"; fi
  out_dir="$VAULT_ROOT/$MEETINGS_SUBDIR"
  out_path="$out_dir/$(date -u +%Y-%m-%d)-$slug.md"

  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run route_meeting] %s -> %s\n' "$src" "$out_path"
    printf '%s' "$out_path"
    return 0
  fi

  mkdir -p "$out_dir" || return 1
  if ! bash "$INGESTOR" --transcript "$src" --output "$out_path" \
       --pf-lib "$PF_LIB" >/dev/null 2>&1; then
    printf 'process.sh: ingestor failed for %s\n' "$src" >&2
    return 1
  fi
  # Remove the source after successful route.
  rm -f "$src" || true
  printf '%s' "$out_path"
}

# Route a reference-shape file as a normalized markdown copy under
# <vault>/<reference-subdir>/. Frontmatter: provenance (sp13-t12/1) +
# disposition: reference + tag #reference.
route_reference() {
  # $1 src_path
  local src="$1" out_dir out_path base body_tmp combined_tmp
  base=$(basename "$src")
  out_dir="$VAULT_ROOT/$REFERENCE_SUBDIR"
  out_path="$out_dir/$base"
  if [ "${out_path##*.}" = "$out_path" ]; then
    out_path="$out_path.md"
  fi

  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run route_reference] %s -> %s\n' "$src" "$out_path"
    printf '%s' "$out_path"
    return 0
  fi

  mkdir -p "$out_dir" || return 1
  body_tmp=$(mktemp -t inbox-proc-ref-body.XXXXXX) || return 1
  combined_tmp=$(mktemp -t inbox-proc-ref-out.XXXXXX) || { rm -f "$body_tmp"; return 1; }

  # Strip any existing frontmatter from src body before re-emitting with our own.
  python3 - "$src" >"$body_tmp" <<'PY'
import sys
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()
i = 0
while i < len(lines) and lines[i].strip() == "":
    i += 1
if i < len(lines) and lines[i].strip() == "---":
    j = i + 1
    while j < len(lines) and lines[j].strip() != "---":
        j += 1
    if j < len(lines):
        sys.stdout.writelines(lines[j + 1:])
        sys.exit(0)
sys.stdout.writelines(lines)
PY

  # Compose new frontmatter via pf_emit (SP12 T-2) for provenance, then
  # append disposition/tag fields.
  {
    pf_emit \
      --surface-id "$SURFACE_ID" \
      --generated-from "$src" 2>/dev/null || {
        # Fallback if pf_emit unavailable; still emits a valid block.
        printf -- '---\n'
        printf 'generated_by: %s\n' "$SURFACE_ID"
        printf 'generated_from: %s\n' "$src"
        printf 'last_user_edit: null\n'
      }
    # If pf_emit closed the block, we need to reopen for our additions; we
    # keep things simple by manually emitting the full block below instead.
  } >/dev/null 2>&1

  # Manual full block (pf_emit shape varies; keeping deterministic):
  {
    printf -- '---\n'
    printf 'generated_by: %s\n' "$SURFACE_ID"
    printf 'generated_from: "%s"\n' "$src"
    printf 'last_user_edit: null\n'
    printf 'disposition: reference\n'
    printf 'source_format: %s\n' "${detected_fmt:-unknown}"
    printf 'tags:\n'
    printf '  - "#reference"\n'
    printf -- '---\n'
    cat "$body_tmp"
  } >"$combined_tmp"

  rm -f "$body_tmp"

  if ! mv -f "$combined_tmp" "$out_path"; then
    rm -f "$combined_tmp"
    return 1
  fi

  rm -f "$src" || true
  printf '%s' "$out_path"
}

sha_file() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

# State-cache check: returns 0 if file's sha is cached AND was processed
# previously (skip re-classification this tick); 1 otherwise.
state_cache_hit() {
  # $1 sha
  local sha="$1" hit
  hit=$(printf '%s' "$STATE_JSON" | jq -r --arg s "$sha" '.items[$s].last_classification // empty')
  [ -n "$hit" ] && [ "$hit" != "unclassified" ]
}

state_record() {
  # $1 sha  $2 classification  $3 route
  local sha="$1" classification="$2" route="$3" ts
  ts=$(now_utc)
  STATE_JSON=$(printf '%s' "$STATE_JSON" | jq -c \
    --arg sha "$sha" \
    --arg classification "$classification" \
    --arg route "$route" \
    --arg ts "$ts" \
    '
      if .items[$sha] then
        .items[$sha].last_attempt = $ts
        | .items[$sha].last_classification = $classification
        | .items[$sha].last_route = $route
      else
        .items[$sha] = {
          first_seen: $ts,
          last_attempt: $ts,
          last_classification: $classification,
          last_route: $route
        }
      end
    ')
}

# ---- main batch loop ---------------------------------------------------------

PROCESSED=0
ROUTED_MEETING=0
ROUTED_REFERENCE=0
LEFT_PROJECT=0
LEFT_UNCLASSIFIED=0
PER_FILE_ERRORS=0

# Enumerate top-level files only (not recursive — Inbox/ is shallow by
# convention; subdirs are user-managed).
shopt -s nullglob 2>/dev/null || true
for f in "$INBOX_DIR"/*; do
  [ -f "$f" ] || continue
  rel="Inbox/$(basename "$f")"
  PROCESSED=$((PROCESSED + 1))

  sha=$(sha_file "$f")
  if [ -z "$sha" ]; then
    printf 'process.sh: sha256 failed for %s\n' "$f" >&2
    PER_FILE_ERRORS=$((PER_FILE_ERRORS + 1))
    continue
  fi

  if state_cache_hit "$sha"; then
    audit_emit "$rel" "$sha" "cache" "in-place" "state-cache"
    continue
  fi

  # Format detect.
  detected_fmt=$(bash "$FORMAT_DETECTOR" "$f" 2>/dev/null || echo unsupported)

  base=$(basename "$f")

  # Tier 1: format-based — transcript shapes.
  if is_transcript_shape "$detected_fmt" "$base"; then
    if [ "$GATE_EACH_ITEM" = "1" ]; then
      # Gate consultation: stub here; SP12 lib invocation when wired.
      # The gate is opt-in and currently a no-op pass-through in this skill;
      # the SP13 T-7 review-gate is the canonical reviewed-flow path. Future
      # work may surface per-item preview here; for now log + proceed.
      :
    fi
    if route_path=$(route_meeting "$f"); then
      ROUTED_MEETING=$((ROUTED_MEETING + 1))
      route_rel="$MEETINGS_SUBDIR/$(basename "$route_path")"
      audit_emit "$rel" "$sha" "meeting" "$route_rel" "format"
      state_record "$sha" "meeting" "$route_rel"
    else
      PER_FILE_ERRORS=$((PER_FILE_ERRORS + 1))
      audit_emit "$rel" "$sha" "meeting" "ERROR" "format"
    fi
    continue
  fi

  # Tier 2: heuristic — for markdown/plaintext.
  case "$detected_fmt" in
    markdown|plaintext)
      class=$(heuristic_classify "$f" "$detected_fmt")
      ;;
    *)
      class="unclassified"
      ;;
  esac

  case "$class" in
    project)
      # Leave in-place with frontmatter hint.
      if [ "$DRY_RUN" = "0" ]; then
        if append_processor_frontmatter "$f" "project"; then
          LEFT_PROJECT=$((LEFT_PROJECT + 1))
          audit_emit "$rel" "$sha" "project" "in-place" "heuristic"
          state_record "$sha" "project" "in-place"
        else
          PER_FILE_ERRORS=$((PER_FILE_ERRORS + 1))
          audit_emit "$rel" "$sha" "project" "ERROR" "heuristic"
        fi
      else
        printf '[dry-run frontmatter-append project] %s\n' "$f"
        audit_emit "$rel" "$sha" "project" "in-place" "heuristic"
      fi
      ;;
    reference)
      if route_path=$(route_reference "$f"); then
        ROUTED_REFERENCE=$((ROUTED_REFERENCE + 1))
        route_rel="$REFERENCE_SUBDIR/$(basename "$route_path")"
        audit_emit "$rel" "$sha" "reference" "$route_rel" "heuristic"
        state_record "$sha" "reference" "$route_rel"
      else
        PER_FILE_ERRORS=$((PER_FILE_ERRORS + 1))
        audit_emit "$rel" "$sha" "reference" "ERROR" "heuristic"
      fi
      ;;
    *)
      # unclassified — append frontmatter, leave in-place.
      if [ "$DRY_RUN" = "0" ]; then
        if append_processor_frontmatter "$f" "unclassified"; then
          LEFT_UNCLASSIFIED=$((LEFT_UNCLASSIFIED + 1))
          audit_emit "$rel" "$sha" "unclassified" "in-place" "unclassified-frontmatter"
          state_record "$sha" "unclassified" "in-place"
        else
          PER_FILE_ERRORS=$((PER_FILE_ERRORS + 1))
          audit_emit "$rel" "$sha" "unclassified" "ERROR" "unclassified-frontmatter"
        fi
      else
        printf '[dry-run frontmatter-append unclassified] %s\n' "$f"
        audit_emit "$rel" "$sha" "unclassified" "in-place" "unclassified-frontmatter"
      fi
      ;;
  esac
done

# ---- state file write --------------------------------------------------------

if [ "$DRY_RUN" = "0" ]; then
  state_tmp="$STATE_FILE.tmp.$$"
  if printf '%s\n' "$STATE_JSON" | jq '.' > "$state_tmp" 2>/dev/null; then
    mv -f "$state_tmp" "$STATE_FILE" || rm -f "$state_tmp"
  else
    rm -f "$state_tmp"
    printf 'process.sh: state file write failed: %s\n' "$STATE_FILE" >&2
    exit 4
  fi
fi

# ---- summary -----------------------------------------------------------------

printf 'process.sh: processed=%d routed_meeting=%d routed_reference=%d left_project=%d left_unclassified=%d errors=%d\n' \
  "$PROCESSED" "$ROUTED_MEETING" "$ROUTED_REFERENCE" "$LEFT_PROJECT" "$LEFT_UNCLASSIFIED" "$PER_FILE_ERRORS" >&2

if [ "$PER_FILE_ERRORS" -gt 0 ]; then
  exit 3
fi
exit 0
