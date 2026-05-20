#!/usr/bin/env bash
# lib/overlay-master-mutate.sh — atomic-write library for mutating
# ~/.claude/governance/overlay-master.json under R-37 multi-pillar lockstep.
#
# Per Plan 81 SP13 alignment Session 3 A32 (atomic-write contract) +
# Session 6 A48 (system.timezone slot). Authored under SP14 Batch B T-8
# (2026-05-18).
#
# Invoked by:
#   - /govern register skill (T-10; SP14 scope) — semantic-extension flow
#   - Future overlay-mutating capabilities (Class A/B/C/D hook nudges)
#
# R-52 collision tiebreaker: when same key exists in foundation-master AND
# overlay-master, overlay wins (adopter override semantics). The mutation
# library does NOT enforce override-reason capture itself — that is the
# /govern register skill body's responsibility (write-time UX). This library
# trusts caller-supplied payloads conforming to the schema.
#
# R-37 multi-pillar bundling: N>1 pillar mutations in a single invocation
# all apply atomically or NONE apply. Single tempfile; single atomic rename.
#
# bash 3.2 compatible (no `declare -A`, no `mapfile`, no `${var,,}`).
# Canonical lock pattern: /usr/bin/lockf -k -t 0 (per feedback_shell_lock_pattern).

set -u

# ---- defaults ---------------------------------------------------------------

if [ -z "${OVERLAY_MASTER:-}" ]; then
  OVERLAY_MASTER="${HOME}/.claude/governance/overlay-master.json"
fi

if [ -z "${SCHEMA:-}" ]; then
  SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
  SCHEMA="$REPO_ROOT/schemas/overlay-master-schema.json"
fi

if [ -z "${ACTION_LOG:-}" ]; then
  ACTION_LOG="${HOME}/.claude/governance/governance-action-log.jsonl"
fi

# Parallel arrays (bash 3.2 — no associative arrays).
# PILLARS[i] holds the pillar name; PAYLOAD_FILES[i] holds the matching path.
PILLARS=""
PAYLOAD_FILES=""
PILLAR_COUNT=0
DRY_RUN=0
PROPOSED_BY="direct-govern-register-invocation"
KIND=""
TARGET=""

usage() {
  cat <<EOF
overlay-master-mutate.sh — atomic R-37 overlay-master mutation library.

Usage:
  overlay-master-mutate.sh \\
      --pillar <pillar-name> --payload-file <path-to-json-mutation> \\
      [--pillar <name2> --payload-file <path2> ...] \\
      [--kind <folder-registered|file-type-registered|...>] \\
      [--target <target-string>] \\
      [--proposed-by <enum-value>] \\
      [--dry-run]

Required:
  --pillar          Pillar slot name. One of:
                    frontmatter / tagging / naming / mandatory_files /
                    doc_dependencies / file_type_contracts / vault_writers /
                    plans / system.
  --payload-file    Path to JSON file containing the mutation payload for the
                    paired --pillar. Payload is deep-merged into the pillar
                    slot under R-52 (overlay wins on key collision).

Multi-pillar R-37 bundling:
  Repeat --pillar / --payload-file pairs in order. All mutations apply
  atomically or none do (single tempfile, single rename).

Optional:
  --kind            Mutation kind for action-log row. Enum per
                    schemas/governance-action-log-schema.json:
                    folder-registered / file-type-registered /
                    tag-extension-registered / writer-registered /
                    unregistered-write. Required if not --dry-run.
  --target          Target string for action-log (folder path, file-type
                    slug, tag dimension, writer name).
  --proposed-by     Entry-path enum per action-log schema. Default:
                    direct-govern-register-invocation.
  --dry-run         Run validation only; do NOT mv tempfile; do NOT append
                    to action-log. Foundation-repo CI mode.

Env:
  OVERLAY_MASTER    Default ~/.claude/governance/overlay-master.json.
  SCHEMA            Default <repo-root>/schemas/overlay-master-schema.json.
  ACTION_LOG        Default ~/.claude/governance/governance-action-log.jsonl.
  CLAUDE_SESSION_ID Read for action-log session_id field; falls back to
                    "unknown-session" if unset.

Exit codes:
  0   success (or dry-run validation passed)
  2   bad invocation / missing prereq
  3   pre-flight failure
  4   schema validation failure
  5   lock contention
  6   atomic rename or action-log append failure
EOF
}

# ---- failure-mode helper ----------------------------------------------------
#
# Called from pre-commit failure paths to ensure block-and-log discipline:
# tempfile already deleted by caller; this writes an action-log row with the
# failure reason so librarian governance-parity-audit surfaces the rejection.
# Variables (KIND/DRY_RUN/PROPOSED_BY/TARGET/ACTION_LOG/CLAUDE_SESSION_ID)
# resolve at call-time, so they may be set by arg-parsing below.

_append_failed_action_log() {
  # $1 pillar(s) string, $2 payload-files string, $3 reason
  if [ -z "${KIND:-}" ]; then
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  local pillar_s="$1" reason="$3"
  local ts session_id
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  session_id="${CLAUDE_SESSION_ID:-unknown-session}"
  mkdir -p "$(dirname "$ACTION_LOG")" 2>/dev/null || true
  local row
  row=$(jq -nc \
    --arg timestamp "$ts" \
    --arg kind "$KIND" \
    --arg proposed_by "$PROPOSED_BY" \
    --arg session_id "$session_id" \
    --arg target "$TARGET" \
    --arg pillar "$pillar_s" \
    --arg reason "$reason" \
    '
      {
        timestamp: $timestamp,
        kind: $kind,
        proposed_by: $proposed_by,
        session_id: $session_id,
        target: ($target | if . == "" then null else . end),
        rejected_fields: { ($pillar): { reason: $reason } },
        unregistered: false
      }
      | with_entries(select(.value != null))
    ' 2>/dev/null)
  if [ -n "$row" ]; then
    printf '%s\n' "$row" >> "$ACTION_LOG" 2>/dev/null || true
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pillar)
      PILLARS="$PILLARS $2"
      shift 2
      ;;
    --payload-file)
      PAYLOAD_FILES="$PAYLOAD_FILES $2"
      PILLAR_COUNT=$((PILLAR_COUNT + 1))
      shift 2
      ;;
    --kind)            KIND="$2"; shift 2 ;;
    --target)          TARGET="$2"; shift 2 ;;
    --proposed-by)     PROPOSED_BY="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) printf 'overlay-master-mutate.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- argv validation --------------------------------------------------------

if [ "$PILLAR_COUNT" = "0" ]; then
  printf 'overlay-master-mutate.sh: at least one --pillar + --payload-file pair required\n' >&2
  exit 2
fi

# Validate parity: count of pillar args must match count of payload args.
PILLAR_ARG_COUNT=$(printf '%s\n' $PILLARS | wc -w | tr -d ' ')
if [ "$PILLAR_ARG_COUNT" != "$PILLAR_COUNT" ]; then
  printf 'overlay-master-mutate.sh: unmatched --pillar/--payload-file pairs (pillars=%s, payloads=%s)\n' \
    "$PILLAR_ARG_COUNT" "$PILLAR_COUNT" >&2
  exit 2
fi

# Validate pillar names against schema's known top-level slots.
VALID_PILLARS="frontmatter tagging naming mandatory_files doc_dependencies file_type_contracts vault_writers plans system"
for p in $PILLARS; do
  found=0
  for valid in $VALID_PILLARS; do
    if [ "$p" = "$valid" ]; then
      found=1
      break
    fi
  done
  if [ "$found" = "0" ]; then
    printf 'overlay-master-mutate.sh: unknown pillar: %s (valid: %s)\n' "$p" "$VALID_PILLARS" >&2
    exit 2
  fi
done

# Validate --kind required if not dry-run.
if [ "$DRY_RUN" = "0" ] && [ -z "$KIND" ]; then
  printf 'overlay-master-mutate.sh: --kind required (unless --dry-run)\n' >&2
  exit 2
fi

# ---- pre-flight -------------------------------------------------------------

for tool in jq python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'overlay-master-mutate.sh: missing prereq: %s\n' "$tool" >&2
    exit 3
  fi
done

# Validate jsonschema is available via python3.
if ! python3 -c 'import jsonschema' 2>/dev/null; then
  printf 'overlay-master-mutate.sh: python3 jsonschema module required\n' >&2
  exit 3
fi

if [ ! -r "$SCHEMA" ]; then
  printf 'overlay-master-mutate.sh: SCHEMA not readable: %s\n' "$SCHEMA" >&2
  exit 3
fi

# Validate schema itself can be loaded by Python.
if ! python3 -c "
import json, sys
with open('$SCHEMA') as f:
    schema = json.load(f)
" 2>/dev/null; then
  printf 'overlay-master-mutate.sh: SCHEMA is not parseable JSON: %s\n' "$SCHEMA" >&2
  exit 3
fi

# Validate every payload file is parseable JSON.
for pf in $PAYLOAD_FILES; do
  if [ ! -r "$pf" ]; then
    printf 'overlay-master-mutate.sh: payload-file not readable: %s\n' "$pf" >&2
    exit 3
  fi
  if ! jq empty "$pf" >/dev/null 2>&1; then
    printf 'overlay-master-mutate.sh: payload-file not valid JSON: %s\n' "$pf" >&2
    exit 3
  fi
done

# Ensure overlay-master parent dir exists.
OVERLAY_DIR=$(dirname "$OVERLAY_MASTER")
mkdir -p "$OVERLAY_DIR" 2>/dev/null || {
  printf 'overlay-master-mutate.sh: cannot create overlay dir: %s\n' "$OVERLAY_DIR" >&2
  exit 3
}

# Initialize overlay-master if absent (empty stub conforming to schema).
if [ ! -f "$OVERLAY_MASTER" ]; then
  if [ "$DRY_RUN" = "0" ]; then
    printf '{}\n' > "$OVERLAY_MASTER"
  fi
fi

LOCK_FILE="$OVERLAY_DIR/.overlay-master.lock"

# ---- lock acquisition (re-exec under lockf) --------------------------------

if [ -z "${OVERLAY_MASTER_LOCKED:-}" ]; then
  export OVERLAY_MASTER_LOCKED=1
  # Build re-exec argv: forward all params verbatim.
  set -- "$@"
  # Build forwarded args (PILLARS/PAYLOAD_FILES are space-delimited token lists).
  REEXEC_ARGS=""
  # Re-iterate pillars + payloads via paired walk.
  i=1
  for p in $PILLARS; do
    # find ith payload by word index
    pf=$(printf '%s\n' $PAYLOAD_FILES | awk -v n="$i" 'NR==n')
    REEXEC_ARGS="$REEXEC_ARGS --pillar $p --payload-file $pf"
    i=$((i + 1))
  done
  if [ -n "$KIND" ]; then
    REEXEC_ARGS="$REEXEC_ARGS --kind $KIND"
  fi
  if [ -n "$TARGET" ]; then
    REEXEC_ARGS="$REEXEC_ARGS --target $TARGET"
  fi
  if [ -n "$PROPOSED_BY" ]; then
    REEXEC_ARGS="$REEXEC_ARGS --proposed-by $PROPOSED_BY"
  fi
  if [ "$DRY_RUN" = "1" ]; then
    REEXEC_ARGS="$REEXEC_ARGS --dry-run"
  fi
  # shellcheck disable=SC2086
  rc=0
  /usr/bin/lockf -k -t 0 "$LOCK_FILE" "$0" $REEXEC_ARGS || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" = "75" ]; then
      printf 'overlay-master-mutate.sh: lock contention on %s\n' "$LOCK_FILE" >&2
      exit 5
    fi
    exit "$rc"
  fi
  exit 0
fi

# ---- multi-pillar bundled mutation (under lock) -----------------------------

TMPFILE="$OVERLAY_MASTER.tmp.$$"

# Read current overlay-master (or empty stub) into the working JSON state.
if [ -s "$OVERLAY_MASTER" ]; then
  CURRENT=$(cat "$OVERLAY_MASTER")
else
  CURRENT='{}'
fi

# Validate current overlay-master parses as JSON.
if ! printf '%s' "$CURRENT" | jq empty >/dev/null 2>&1; then
  printf 'overlay-master-mutate.sh: current overlay-master is not valid JSON: %s\n' "$OVERLAY_MASTER" >&2
  exit 3
fi

# Apply each pillar payload as deep-merge into the pillar slot.
# Per R-52 collision tiebreaker: overlay wins on key collision (adopter
# overrides). This library performs the merge; the /govern register skill
# is responsible for collision-flagging + override-reason capture upstream.
WORKING="$CURRENT"
i=1
for p in $PILLARS; do
  pf=$(printf '%s\n' $PAYLOAD_FILES | awk -v n="$i" 'NR==n')
  PAYLOAD=$(cat "$pf")
  # Deep-merge: overlay (.[pillar]) gets a recursive merge with payload.
  # Using jq's `* ` operator with --argjson for proper deep object merge.
  WORKING=$(printf '%s' "$WORKING" | jq -c \
    --arg pillar "$p" \
    --argjson payload "$PAYLOAD" \
    '
      if has($pillar) then
        .[$pillar] = (.[$pillar] * $payload)
      else
        .[$pillar] = $payload
      end
    ' 2>/dev/null) || {
      printf 'overlay-master-mutate.sh: deep-merge failed for pillar %s\n' "$p" >&2
      rm -f "$TMPFILE"
      _append_failed_action_log "$p" "$pf" "deep-merge-failed"
      exit 6
    }
  i=$((i + 1))
done

# Write composed JSON to tempfile (pretty-print for human inspection).
if ! printf '%s\n' "$WORKING" | jq '.' > "$TMPFILE" 2>/dev/null; then
  rm -f "$TMPFILE"
  printf 'overlay-master-mutate.sh: tempfile write failed: %s\n' "$TMPFILE" >&2
  exit 6
fi

# ---- JSON Schema 2020-12 validation against tempfile ------------------------

if ! python3 - "$SCHEMA" "$TMPFILE" <<'PY' 2>/dev/null
import json, sys, jsonschema
schema_path = sys.argv[1]
candidate_path = sys.argv[2]
with open(schema_path) as f:
    schema = json.load(f)
with open(candidate_path) as f:
    candidate = json.load(f)
validator = jsonschema.Draft202012Validator(schema)
errors = sorted(validator.iter_errors(candidate), key=lambda e: e.path)
if errors:
    for err in errors:
        print(f"schema-error: {list(err.path)}: {err.message}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
then
  printf 'overlay-master-mutate.sh: schema validation failed for tempfile\n' >&2
  rm -f "$TMPFILE"
  _append_failed_action_log "${PILLARS# }" "${PAYLOAD_FILES# }" "schema-validation-failed"
  exit 4
fi

# ---- dry-run exit gate ------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  printf 'overlay-master-mutate.sh: dry-run validation PASS; tempfile not committed: %s\n' "$TMPFILE" >&2
  rm -f "$TMPFILE"
  exit 0
fi

# ---- atomic swap ------------------------------------------------------------

if ! mv -f "$TMPFILE" "$OVERLAY_MASTER"; then
  rm -f "$TMPFILE"
  printf 'overlay-master-mutate.sh: atomic rename failed: %s -> %s\n' "$TMPFILE" "$OVERLAY_MASTER" >&2
  exit 6
fi

# ---- action-log append (one row per pillar mutated; R-37 atomic) -----------

SESSION_ID="${CLAUDE_SESSION_ID:-unknown-session}"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$(dirname "$ACTION_LOG")" 2>/dev/null || true

i=1
for p in $PILLARS; do
  pf=$(printf '%s\n' $PAYLOAD_FILES | awk -v n="$i" 'NR==n')
  # Per A31 + L-34: row shape is one row per pillar mutated.
  # validated_fields gets pillar name as key + the payload's top-level keys
  # as proof of accepted shape (downstream reconciliation reads this).
  PAYLOAD_KEYS=$(jq -c 'keys' "$pf" 2>/dev/null || echo '[]')
  ROW=$(jq -nc \
    --arg timestamp "$TS" \
    --arg kind "$KIND" \
    --arg proposed_by "$PROPOSED_BY" \
    --arg session_id "$SESSION_ID" \
    --arg target "$TARGET" \
    --arg pillar "$p" \
    --argjson payload_keys "$PAYLOAD_KEYS" \
    '
      {
        timestamp: $timestamp,
        kind: $kind,
        proposed_by: $proposed_by,
        session_id: $session_id,
        target: ($target | if . == "" then null else . end),
        validated_fields: { ($pillar): $payload_keys },
        unregistered: false
      }
      | with_entries(select(.value != null))
    ' 2>/dev/null)
  if [ -z "$ROW" ]; then
    printf 'overlay-master-mutate.sh: action-log row composition failed for pillar %s\n' "$p" >&2
    exit 6
  fi
  if ! printf '%s\n' "$ROW" >> "$ACTION_LOG"; then
    printf 'overlay-master-mutate.sh: action-log append failed for pillar %s\n' "$p" >&2
    exit 6
  fi
  i=$((i + 1))
done

printf 'overlay-master-mutate.sh: committed %s mutation(s) to %s\n' "$PILLAR_COUNT" "$OVERLAY_MASTER" >&2
exit 0
