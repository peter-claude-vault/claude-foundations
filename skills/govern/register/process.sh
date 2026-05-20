#!/usr/bin/env bash
# skills/govern/register/process.sh — orchestrator for the /govern register
# 4-mode skill family (folder / file-type / tag-extension / writer).
#
# Per Plan 81 SP13 alignment Session 3 A31 + Session 5 A44 (Class D writer
# mode). Implements the 6-step propose-and-validate protocol per canonical
# §A6 + §A30. Authored under SP14 Batch H T-10 (2026-05-19).
#
# Sub-verbs:
#   propose <kind> <target> [...args...]   → emit proposal JSON to stdout
#   commit  <kind> --proposal <validated.json>  → atomic mutate via library
#   skip    <kind> --target <T> [--reason <R>]  → frictionless-skip action log
#
# Overlay-master mutations route through lib/overlay-master-mutate.sh
# (single mutation library; schema-drift prevention; lockf serialization).
# The skip path appends an action-log row inline (no overlay mutation to
# atomicize; library row composer hardcodes `unregistered: false` for the
# success path, so the frictionless-skip row shape — which requires
# `unregistered: true` per L-34 — is composed here using the same schema
# fields. Schema source of truth: schemas/governance-action-log-schema.json.
#
# Mode-specific propose/commit logic lives in modes/<kind>.sh; the
# orchestrator dispatches by sourcing the matching handler.
#
# bash 3.2 compatible.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MODES_DIR="$SCRIPT_DIR/modes"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
LIB_MUTATE="$REPO_ROOT/lib/overlay-master-mutate.sh"

# Allow tests to override via env.
if [ -n "${GOVERN_REGISTER_LIB_MUTATE:-}" ]; then
  LIB_MUTATE="$GOVERN_REGISTER_LIB_MUTATE"
fi

# Action-log path mirrors library default; ACTION_LOG env override honored.
if [ -z "${ACTION_LOG:-}" ]; then
  ACTION_LOG="${HOME}/.claude/governance/governance-action-log.jsonl"
fi

usage() {
  cat <<EOF
process.sh — /govern register orchestrator.

Sub-verbs:
  propose <kind> [...args...]
      Emit proposal JSON to stdout. Claude renders for user; user
      validates per-field; composes validated.json.

  commit <kind> --proposal <validated.json>
      Atomically apply validated mutations via lib/overlay-master-mutate.sh.
      Returns rc=0 on success; library exit codes (2/3/4/5/6) surface
      verbatim on failure.

  skip <kind> --target <T> [--reason <R>] [--proposed-by <enum>]
      Append a frictionless-skip action-log row (unregistered: true).
      No overlay mutation. No vault writes.

Modes (per --kind):
  folder         New top-level vault folder        (frontmatter + mandatory_files)
  file-type      New file-type in existing folder  (frontmatter + file_type_contracts; R-37 atomic)
  tag-extension  New tag dimension                 (tagging.taxonomy)
  writer         New vault-writer registration     (Vault Writers/<slug>.md + no-op vault_writers)

Per-mode argv shapes — see SKILL.md §"Invocation contracts".

Env:
  OVERLAY_MASTER, SCHEMA, ACTION_LOG    forwarded to library
  GOVERN_REGISTER_LIB_MUTATE            override library path (testing)
  CLAUDE_SESSION_ID                     forwarded to library for action-log
EOF
}

if [ $# -lt 1 ]; then
  usage >&2
  exit 2
fi

VERB="$1"
shift

case "$VERB" in
  -h|--help)
    usage
    exit 0
    ;;
  propose|commit|skip)
    ;;
  *)
    printf 'process.sh: unknown verb: %s\n' "$VERB" >&2
    usage >&2
    exit 2
    ;;
esac

if [ $# -lt 1 ]; then
  printf 'process.sh: %s requires a --kind value\n' "$VERB" >&2
  exit 2
fi

# Pop --kind (positional OR flag).
KIND=""
if [ "${1:-}" = "--kind" ]; then
  if [ $# -lt 2 ]; then
    printf 'process.sh: --kind requires a value\n' >&2
    exit 2
  fi
  KIND="$2"
  shift 2
else
  KIND="$1"
  shift
fi

case "$KIND" in
  folder|file-type|tag-extension|writer)
    ;;
  plan)
    printf 'process.sh: --kind plan is ORTHOGONAL — use /new-plan or /backlog-research instead.\n' >&2
    exit 2
    ;;
  *)
    printf 'process.sh: unknown --kind: %s (valid: folder, file-type, tag-extension, writer)\n' "$KIND" >&2
    exit 2
    ;;
esac

MODE_HANDLER="$MODES_DIR/$KIND.sh"
if [ ! -r "$MODE_HANDLER" ]; then
  printf 'process.sh: mode handler missing or unreadable: %s\n' "$MODE_HANDLER" >&2
  exit 3
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'process.sh: jq is required (orchestrator + mode handlers)\n' >&2
  exit 3
fi

export LIB_MUTATE
export ACTION_LOG

# Source the mode handler; it must define mode_propose / mode_commit funcs.
# Skip is mode-agnostic and lives in the orchestrator.
# shellcheck disable=SC1090
. "$MODE_HANDLER"

for fn in mode_propose mode_commit; do
  if ! command -v "$fn" >/dev/null 2>&1; then
    printf 'process.sh: mode handler %s missing function: %s\n' "$MODE_HANDLER" "$fn" >&2
    exit 3
  fi
done

# Skip-path action-log row composer — mode-agnostic. Mirrors
# schemas/governance-action-log-schema.json field set. Skip path is
# distinct from library success/failure paths (library hardcodes
# unregistered:false in both row composers).
append_skip_row() {
  # $1=target, $2=reason (optional), $3=proposed_by (default: skipped)
  local target reason proposed_by ts session_id row
  target="$1"
  reason="${2:-}"
  proposed_by="${3:-skipped}"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  session_id="${CLAUDE_SESSION_ID:-unknown-session}"

  mkdir -p "$(dirname "$ACTION_LOG")" 2>/dev/null || true

  row=$(jq -nc \
    --arg timestamp "$ts" \
    --arg kind "$KIND" \
    --arg proposed_by "$proposed_by" \
    --arg session_id "$session_id" \
    --arg target "$target" \
    --arg reason "$reason" \
    '
      {
        timestamp: $timestamp,
        kind: $kind,
        proposed_by: $proposed_by,
        session_id: $session_id,
        target: ($target | if . == "" then null else . end),
        unregistered: true,
        rejected_fields: ($reason | if . == "" then null else {skip_reason: .} end)
      }
      | with_entries(select(.value != null))
    ' 2>/dev/null)

  if [ -z "$row" ]; then
    printf 'process.sh: skip-row composition failed\n' >&2
    return 6
  fi
  if ! printf '%s\n' "$row" >> "$ACTION_LOG"; then
    printf 'process.sh: skip-row append failed: %s\n' "$ACTION_LOG" >&2
    return 6
  fi
  return 0
}

case "$VERB" in
  propose)
    mode_propose "$@"
    exit $?
    ;;
  commit)
    PROPOSAL=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --proposal)
          if [ $# -lt 2 ]; then
            printf 'process.sh: --proposal requires a path\n' >&2
            exit 2
          fi
          PROPOSAL="$2"
          shift 2
          ;;
        *)
          break
          ;;
      esac
    done
    if [ -z "$PROPOSAL" ]; then
      printf 'process.sh: commit requires --proposal <validated.json>\n' >&2
      exit 2
    fi
    if [ ! -r "$PROPOSAL" ]; then
      printf 'process.sh: --proposal file not readable: %s\n' "$PROPOSAL" >&2
      exit 2
    fi
    if ! jq empty "$PROPOSAL" >/dev/null 2>&1; then
      printf 'process.sh: --proposal file is not valid JSON: %s\n' "$PROPOSAL" >&2
      exit 2
    fi
    PROPOSAL_KIND=$(jq -r '.kind // ""' "$PROPOSAL")
    if [ "$PROPOSAL_KIND" != "$KIND" ]; then
      printf 'process.sh: --proposal .kind (%s) does not match argv --kind (%s)\n' "$PROPOSAL_KIND" "$KIND" >&2
      exit 2
    fi
    mode_commit "$PROPOSAL" "$@"
    exit $?
    ;;
  skip)
    TARGET=""
    REASON=""
    PROPOSED_BY="skipped"
    while [ $# -gt 0 ]; do
      case "$1" in
        --target)       TARGET="$2";       shift 2 ;;
        --reason)       REASON="$2";       shift 2 ;;
        --proposed-by)  PROPOSED_BY="$2";  shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -z "$TARGET" ]; then
      printf 'process.sh: skip requires --target <T>\n' >&2
      exit 2
    fi
    append_skip_row "$TARGET" "$REASON" "$PROPOSED_BY"
    exit $?
    ;;
esac
