#!/usr/bin/env bash
# inbox-disposition.sh — SP13 T-10 wrapper around inbox-disposition.py.
#
# Invokes inbox-disposition.py to walk the non-project H3 section of a
# T-7 user-approved import plan and stage Inbox files. Emits the manifest
# JSON on stdout for seed.sh to combine with seed.py's project-triad
# manifest before the single batched gate fires.
#
# This wrapper is normally called from seed.sh as part of Stage 3 staging.
# Direct invocation is supported for unit testing the Inbox-only path.
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - $STAGE_DIR/seed-projects/Inbox/<date>-<slug>.md per non-project
#       source_item (only on staging — no vault writes from this script;
#       seed.sh's apply path copies them in).
#     - manifest JSON on stdout (inbox-disposition/1).
#   Schema-types:
#     - Input: import-plan/1 (validated by h3_walker via inbox-disposition.py).
#     - Output staged files carry SP12 provenance frontmatter.
#   Pre-write validation:
#     - approved-import-plan.md exists + carries import-plan/1.
#     - lib/provenance-frontmatter.sh exists + sourceable.
#     - Vault root exists (caller's responsibility).
#   Failure mode: BLOCK AND LOG.
#     - Pre-flight failure → exit 2.
#     - inbox-disposition.py failure → exit 2.
#
# CONSTRAINTS (R-23): bash 3.2 — no `declare -A`, no `mapfile`,
# no `${var,,}`. `python3` REQUIRED. `jq` REQUIRED.
#
# Author: Claude Opus 4.7 — Plan 71 SP13 Session 8 (T-10).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
DEFAULT_APPROVED_PLAN="$REPO_ROOT/onboarding/seed-content/state/approved-import-plan.md"
DEFAULT_PF_LIB="$REPO_ROOT/lib/provenance-frontmatter.sh"

APPROVED_PLAN="$DEFAULT_APPROVED_PLAN"
VAULT_ROOT=""
STAGE_DIR=""
PF_LIB="$DEFAULT_PF_LIB"
AUDIENCE="self"
GENERATED_AT="${SEED_PROJECTS_GENERATED_AT:-}"

usage() {
  cat <<EOF
inbox-disposition.sh — SP13 T-10 Inbox-routing helper.

Usage:
  inbox-disposition.sh --vault-root PATH --stage-dir PATH \
                       [--approved-plan PATH] [--pf-lib PATH] \
                       [--audience SELF|TEAM|...] [--generated-at ISO-8601]

Required:
  --vault-root PATH        Vault root; Inbox files target <vault>/Inbox/.
  --stage-dir PATH         Staging dir; Inbox files land at
                           <stage-dir>/seed-projects/Inbox/.

Defaults:
  --approved-plan          $DEFAULT_APPROVED_PLAN
  --pf-lib                 $DEFAULT_PF_LIB
  --audience               self
  --generated-at           now (UTC, ISO-8601)

Env hooks:
  SEED_PROJECTS_GENERATED_AT  reproducible-test timestamp override

Exit codes:
  0   manifest emitted on stdout
  2   pre-flight failure or staging error
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --vault-root)        VAULT_ROOT="$2"; shift 2 ;;
    --stage-dir)         STAGE_DIR="$2"; shift 2 ;;
    --approved-plan)     APPROVED_PLAN="$2"; shift 2 ;;
    --pf-lib)            PF_LIB="$2"; shift 2 ;;
    --audience)          AUDIENCE="$2"; shift 2 ;;
    --generated-at)      GENERATED_AT="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) printf 'inbox-disposition.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$VAULT_ROOT" ] || [ -z "$STAGE_DIR" ]; then
  printf 'inbox-disposition.sh: --vault-root and --stage-dir are required\n' >&2
  usage >&2
  exit 2
fi

if [ ! -f "$APPROVED_PLAN" ]; then
  printf 'inbox-disposition.sh: approved plan not found: %s\n' "$APPROVED_PLAN" >&2
  exit 2
fi
if ! grep -q '^schema_version: import-plan/1$' "$APPROVED_PLAN"; then
  printf 'inbox-disposition.sh: approved plan schema_version mismatch (expected import-plan/1)\n' >&2
  exit 2
fi
if [ ! -f "$PF_LIB" ]; then
  printf 'inbox-disposition.sh: pf-lib not found: %s\n' "$PF_LIB" >&2
  exit 2
fi
if [ ! -d "$STAGE_DIR" ]; then
  if ! mkdir -p "$STAGE_DIR"; then
    printf 'inbox-disposition.sh: cannot create stage dir: %s\n' "$STAGE_DIR" >&2
    exit 2
  fi
fi

DISPO_PY="$SCRIPT_DIR/inbox-disposition.py"
if [ ! -f "$DISPO_PY" ]; then
  printf 'inbox-disposition.sh: inbox-disposition.py helper not found: %s\n' "$DISPO_PY" >&2
  exit 2
fi

GEN_AT_ARG=""
if [ -n "$GENERATED_AT" ]; then
  GEN_AT_ARG="--generated-at $GENERATED_AT"
fi

if ! python3 "$DISPO_PY" \
  --approved-plan "$APPROVED_PLAN" \
  --vault-root "$VAULT_ROOT" \
  --stage-dir "$STAGE_DIR" \
  --pf-lib "$PF_LIB" \
  --audience "$AUDIENCE" \
  $GEN_AT_ARG; then
  printf 'inbox-disposition.sh: inbox-disposition.py failed\n' >&2
  exit 2
fi

exit 0
