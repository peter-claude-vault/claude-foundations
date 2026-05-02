#!/bin/bash
# onboarding/checkpoint.sh — SP07 T-10 per-section completion checkpoint.
#
# Single source of truth for per-section completion writes against
# user-manifest.system.{phases_completed,completion_state}. Invoked by:
#
#   - section-a.sh on commit (no transcript; A is deterministic)
#   - render-summary.sh on accept for sections B/C/D (with transcript path)
#   - section-e.sh on commit (no transcript; E is deterministic)
#
# Operations:
#
#   --section X [--transcript PATH]
#       Idempotent commit. Appends X to phases_completed[] (jq unique
#       dedup) AND merges completion_state[X] = {committed_at, transcript_sha?}.
#       transcript_sha computed via shasum when --transcript given;
#       omitted otherwise. Re-invocation overwrites the prior committed_at
#       (latest checkpoint wins; phases_completed dedupes).
#
#   --remove-section X
#       Idempotent re-record. Removes X from phases_completed[] AND
#       deletes completion_state[X]. Used by render-summary.sh's
#       re-record path.
#
# Manifest absence: creates a minimal {system:{phases_completed:[],
# completion_state:{}}} skeleton on first commit.
#
# Atomicity: every user-manifest write goes through tmp+rename. jq merges
# preserve all unrelated fields.
#
# Reference-leak floor (Hard Rule 9): the only data written here is the
# section_id literal (A..E), an ISO-8601 UTC timestamp, and a hex shasum.
# No user-typed strings, no transcript content, no field values.
#
# Hard invariants:
#   - Bash 3.2 + R-23 compatible (no declare -A, no mapfile, no ${var,,};
#     use tr '[:upper:]' '[:lower:]')
#   - Single-deliverable per R-37
#   - Atomic tmp+rename for every write
#   - Idempotent: re-invocation with same args MUST converge to same state
#
# Env knobs (override defaults; tests + dogfood):
#   USER_MANIFEST              user-manifest.json path
#                              (default: $CLAUDE_HOME/user-manifest.json)
#
# Args:
#   --section {A|B|C|D|E}      section letter (REQUIRED unless --remove-section)
#   --transcript PATH          transcript file path (optional; computes sha)
#   --remove-section {A..E}    re-record path: remove section_id from both
#                              phases_completed[] and completion_state{}
#   --user-manifest PATH       override USER_MANIFEST
#
# Exit codes:
#   0  success (write committed OR no-op idempotent)
#   2  bad invocation / missing dependency
#   3  write error
#
# (See SP07 T-10 spec + tests/sp07/checkpoint-resume-unit-test.sh for the
# 5-AC contract this script ships against.)

set -u

diag() { printf 'checkpoint FAIL: %s\n' "$1" >&2; }

# --- source paths.sh if present (post-install runtime); fall back to env ---
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi

# --- dependency check ---
for tool in jq date shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    diag "$tool required but not on PATH"
    exit 2
  fi
done

# --- defaults + arg parsing ---
USER_MANIFEST="${USER_MANIFEST:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
SECTION=""
TRANSCRIPT=""
REMOVE_SECTION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --section)         SECTION="$2"; shift 2 ;;
    --transcript)      TRANSCRIPT="$2"; shift 2 ;;
    --remove-section)  REMOVE_SECTION="$2"; shift 2 ;;
    --user-manifest)   USER_MANIFEST="$2"; shift 2 ;;
    -h|--help)         sed -n '2,60p' "$0"; exit 0 ;;
    *)                 diag "unknown arg: $1"; exit 2 ;;
  esac
done

# Mode resolution: exactly one of --section, --remove-section.
if [ -n "$SECTION" ] && [ -n "$REMOVE_SECTION" ]; then
  diag "--section and --remove-section are mutually exclusive"
  exit 2
fi
if [ -z "$SECTION" ] && [ -z "$REMOVE_SECTION" ]; then
  diag "one of --section or --remove-section required"
  exit 2
fi

# Validate the section letter (whichever flavor was supplied).
TARGET_SECTION="${SECTION:-$REMOVE_SECTION}"
TARGET_UPPER="$(printf '%s' "$TARGET_SECTION" | tr '[:lower:]' '[:upper:]')"
case "$TARGET_UPPER" in
  A|B|C|D|E) : ;;
  *)
    diag "section must be one of A|B|C|D|E (got: $TARGET_SECTION)"
    exit 2
    ;;
esac

# Transcript validation (only meaningful in --section mode).
TRANSCRIPT_SHA=""
if [ -n "$SECTION" ] && [ -n "$TRANSCRIPT" ]; then
  if [ ! -r "$TRANSCRIPT" ]; then
    diag "--transcript not readable: $TRANSCRIPT"
    exit 2
  fi
  TRANSCRIPT_SHA="$(shasum "$TRANSCRIPT" 2>/dev/null | awk '{print $1}')"
  if [ -z "$TRANSCRIPT_SHA" ]; then
    diag "shasum on --transcript failed: $TRANSCRIPT"
    exit 3
  fi
fi

# --- ensure manifest exists with skeleton ---
ensure_manifest_skeleton() {
  if [ -f "$USER_MANIFEST" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$USER_MANIFEST")" 2>/dev/null || {
    diag "cannot create manifest directory: $(dirname "$USER_MANIFEST")"
    return 3
  }
  printf '{"system":{"phases_completed":[],"completion_state":{}}}\n' \
    > "$USER_MANIFEST" || {
      diag "user-manifest skeleton creation failed: $USER_MANIFEST"
      return 3
    }
  return 0
}

# --- branch: --section X commit ---
do_commit() {
  ensure_manifest_skeleton || return 3

  local committed_at
  committed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local final_tmp="$USER_MANIFEST.tmp.$$"
  local entry_json
  if [ -n "$TRANSCRIPT_SHA" ]; then
    entry_json="$(jq -nc \
      --arg ts "$committed_at" \
      --arg sha "$TRANSCRIPT_SHA" \
      '{committed_at: $ts, transcript_sha: $sha}')"
  else
    entry_json="$(jq -nc \
      --arg ts "$committed_at" \
      '{committed_at: $ts}')"
  fi

  jq -c \
    --arg s "$TARGET_UPPER" \
    --argjson entry "$entry_json" \
    '
      .system = (.system // {})
      | .system.phases_completed = (
          (.system.phases_completed // []) + [$s] | unique
        )
      | .system.completion_state = (
          (.system.completion_state // {}) + ({($s): $entry})
        )
    ' "$USER_MANIFEST" > "$final_tmp" || {
      diag "user-manifest checkpoint merge failed"
      rm -f "$final_tmp"
      return 3
    }
  mv "$final_tmp" "$USER_MANIFEST" || {
    diag "user-manifest rename failed"
    rm -f "$final_tmp"
    return 3
  }
  return 0
}

# --- branch: --remove-section X re-record ---
do_remove() {
  if [ ! -f "$USER_MANIFEST" ]; then
    # Nothing to remove from. Idempotent no-op.
    return 0
  fi

  local final_tmp="$USER_MANIFEST.tmp.$$"
  jq -c \
    --arg s "$TARGET_UPPER" \
    '
      .system = (.system // {})
      | .system.phases_completed = (
          if (.system.phases_completed // []) | type == "array"
          then ((.system.phases_completed // []) - [$s])
          else (.system.phases_completed // [])
          end
        )
      | .system.completion_state = (
          (.system.completion_state // {}) | del(.[$s])
        )
    ' "$USER_MANIFEST" > "$final_tmp" || {
      diag "user-manifest remove merge failed"
      rm -f "$final_tmp"
      return 3
    }
  mv "$final_tmp" "$USER_MANIFEST" || {
    diag "user-manifest rename failed"
    rm -f "$final_tmp"
    return 3
  }
  return 0
}

# --- main flow ---
if [ -n "$REMOVE_SECTION" ]; then
  do_remove
  exit $?
fi

do_commit
exit $?
