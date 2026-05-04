#!/usr/bin/env bash
# review-gate.sh — SP13 T-7. User review/edit UX gate over T-6 import-plan.md.
#
# Wires SP12's three-step gate library (`onboarding/lib/three-step-gate.sh`)
# around the T-6 import-plan.md output. Surfaces 4 user actions at the
# preview prompt:
#   apply  → write approved plan to state/approved-import-plan.md (Stage 3
#            consumption target). gate audits "apply".
#   edit   → open ${EDITOR:-vi} on the staged plan; saved content is what
#            apply writes. Re-loops back to preview after editor returns so
#            user can review their own edits before committing.
#   skip   → exit Stage 2 cleanly without proceeding to Stage 3. Audit
#            "skip"; rc=0; no vault writes.
#   abort  → exit non-zero. Audit "abort"; no vault writes.
#
# UX-quality acceptance per spec L240 #6 + R1 §6 risk #3 ("gate UX must be
# GOOD not just CORRECT"): a "what happens next" block is rendered at the
# preview surface BEFORE the prompt, so the user understands the
# consequence of each action without having to infer it.
#
# Edit-diff UX (carry-forward from T-6 Session 4 close): when the user
# returns from the editor with mutations, a SECOND diff is rendered showing
# their own edits against the originally-generated plan (in addition to
# gate_preview's diff against the eventual target). Surfaces "what *I*
# changed" separately from "what's about to be written."
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - state/approved-import-plan.md (only on `apply` choice)
#     - audit log entries appended via gate_generate / gate_preview /
#       gate_apply (single audit stream — REUSES SP12's auto-author-log
#       per session-prompt design recommendation; differentiation comes
#       from surface_id="seed-import-plan" + the action field)
#   Schema-types:
#     - Input: T-6 import-plan.md MUST carry `schema_version: sp13-t6/1`
#       in YAML frontmatter; T-7 refuses to consume non-conformant plans.
#     - Output: same schema (sp13-t6/1) round-trips through user edits.
#       Validation enforces the schema_version anchor stays intact post-
#       edit; full Draft-07 re-validation against
#       schemas/import-plan-schema.json is deferred (would require
#       reassembling the wrapper from the markdown — a post-T-7 follow-on
#       per session-prompt scope cap).
#   Pre-write validation:
#     - SP12 T-1 done-marker present (dev-mode only — production adopters
#       have no plan tree, check is no-op)
#     - Input plan exists + carries sp13-t6/1 schema_version
#     - Gate library exists at the expected location + sources cleanly
#     - Post-edit: schema_version line still intact in staged content
#       BEFORE invoking gate_apply
#   Failure mode: BLOCK AND LOG.
#     - Missing SP12 T-1 in dev mode → exit 2 (clean halt with message)
#     - Missing/malformed input plan → exit 2
#     - User abort → exit 1 (audit "abort")
#     - User skip → exit 0 (audit "skip"; no target write)
#     - Post-edit schema_version drift → re-prompt (do not proceed to apply)
#
# CONSTRAINTS (R-23): bash 3.2 — no `declare -A`, no `mapfile`,
# no `${var,,}`. `jq` REQUIRED on PATH (carried through from gate library).
#
# Author: Claude Opus 4.7 — Plan 71 SP13 Session 5

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
DEFAULT_GATE_LIB="$REPO_ROOT/onboarding/lib/three-step-gate.sh"
DEFAULT_INPUT_PLAN="$REPO_ROOT/onboarding/seed-content/state/import-plan.md"
DEFAULT_APPROVED_OUT="$REPO_ROOT/onboarding/seed-content/state/approved-import-plan.md"
DEFAULT_PLAN_TREE="$HOME/.claude-plans/71-claude-foundations-engine-v2"

INPUT_PLAN="$DEFAULT_INPUT_PLAN"
APPROVED_OUT="$DEFAULT_APPROVED_OUT"
GATE_LIB="$DEFAULT_GATE_LIB"
PLAN_TREE="$DEFAULT_PLAN_TREE"
ACCEPT_ON_EOF="${REVIEW_GATE_ACCEPT_ON_EOF:-0}"
PROMPT_CHOICE="${REVIEW_GATE_PROMPT_CHOICE:-}"

usage() {
  cat <<EOF
review-gate.sh — SP13 T-7 user review/edit UX gate over the import plan.

Usage:
  review-gate.sh [--import-plan PATH] [--approved-out PATH]
                 [--gate-lib PATH] [--plan-tree PATH]
                 [--accept-on-eof]

Defaults:
  --import-plan   $DEFAULT_INPUT_PLAN
  --approved-out  $DEFAULT_APPROVED_OUT
  --gate-lib      $DEFAULT_GATE_LIB
  --plan-tree     $DEFAULT_PLAN_TREE
                  (used only to detect dev-mode SP12 T-1 done-marker; if
                   the plan tree dir is absent, the SP12 check is skipped
                   — production adopters have no plan tree)

Env hooks (test-only):
  REVIEW_GATE_ACCEPT_ON_EOF=1   treat EOF on stdin as 'apply' (smoke tests)
  REVIEW_GATE_PROMPT_CHOICE=X   pre-canned single choice (smoke tests; X is
                                a/e/s/b — applied once, then EOF respected)

Exit codes:
  0   apply or skip (intentional, no error)
  1   user abort
  2   pre-flight failure (SP12 done-marker, input missing, gate lib missing,
      schema_version mismatch)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --import-plan|--input) INPUT_PLAN="$2"; shift 2 ;;
    --approved-out|--out) APPROVED_OUT="$2"; shift 2 ;;
    --gate-lib) GATE_LIB="$2"; shift 2 ;;
    --plan-tree) PLAN_TREE="$2"; shift 2 ;;
    --accept-on-eof) ACCEPT_ON_EOF=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'review-gate.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# ----- pre-flight 1: SP12 T-1 done-marker (dev-mode only) -----

SP12_DONE_RELPATH="12-auto-authored-personalization/state/T-1.done"
SP12_DONE="$PLAN_TREE/$SP12_DONE_RELPATH"
if [ -d "$PLAN_TREE" ] && [ ! -f "$SP12_DONE" ]; then
  cat <<EOF >&2
review-gate.sh: HARD ABORT — SP12 T-1 done-marker not found.
  Expected at: $SP12_DONE
  Plan tree:   $PLAN_TREE

SP12 T-1 ships onboarding/lib/three-step-gate.sh, which T-7 sources for
its preview/edit/apply flow. SP13 T-7 cannot proceed until SP12 T-1 is
closed and the done-marker exists.

Re-run after SP12 T-1 completes. If you are running outside a Plan 71 dev
checkout (i.e., as a foundation-repo adopter), this check is automatically
skipped — the absence of the plan tree directory itself is the signal.
EOF
  exit 2
fi

# ----- pre-flight 2: input plan exists + schema_version sp13-t6/1 -----

if [ ! -f "$INPUT_PLAN" ]; then
  printf 'review-gate.sh: input plan not found: %s\n' "$INPUT_PLAN" >&2
  printf '  Run T-6 import-plan.sh first to generate it.\n' >&2
  exit 2
fi
if ! grep -q '^schema_version: sp13-t6/1$' "$INPUT_PLAN"; then
  cat <<EOF >&2
review-gate.sh: input plan schema_version mismatch (expected 'sp13-t6/1').
  Path: $INPUT_PLAN
This file does not appear to be a valid T-6 import plan. T-7 refuses to
consume non-conformant plans. Re-run T-6 import-plan.sh first to
regenerate.
EOF
  exit 2
fi

# ----- pre-flight 3: gate library available -----

if [ ! -f "$GATE_LIB" ]; then
  printf 'review-gate.sh: gate library not found: %s\n' "$GATE_LIB" >&2
  printf '  Expected SP12 T-1 lib at this location.\n' >&2
  exit 2
fi
# shellcheck disable=SC1090
. "$GATE_LIB"

# ----- gate_generate: stage the import-plan content -----

_seed_import_plan_gen() {
  cat "$INPUT_PLAN"
}

STAGE=$(gate_generate "seed-import-plan" _seed_import_plan_gen) || {
  printf 'review-gate.sh: gate_generate failed\n' >&2
  exit 2
}
if [ -z "$STAGE" ] || [ ! -f "$STAGE" ]; then
  printf 'review-gate.sh: staging path missing after gate_generate: %s\n' "$STAGE" >&2
  exit 2
fi

# Snapshot the original generated content so we can show "what user changed"
# after edit cycles (carry-forward from T-6 Session 4 close).
ORIG_STAGE="$STAGE.orig"
cp "$STAGE" "$ORIG_STAGE" || {
  printf 'review-gate.sh: could not snapshot original staged content\n' >&2
  exit 2
}

cleanup_orig() { [ -f "$ORIG_STAGE" ] && rm -f "$ORIG_STAGE"; }
trap cleanup_orig EXIT

# ----- helpers: UX surfaces -----

print_what_happens_next() {
  cat <<EOF >&2

=== what happens next ===
On [a]pply  → write your approved plan to:
                $APPROVED_OUT
              Stage 3 (T-8) will then scaffold each approved candidate
              as a folder + PRD/Context/Updates triad using SP12's
              provenance frontmatter contract and 3-step gate per file.
              No vault writes happen yet — you will see another preview
              gate at Stage 3 before any project folder is created.

On [e]dit   → open \${EDITOR:-vi} on the staged plan in place. Save and
              quit your editor to return to this prompt; whatever you
              saved is what apply will write. (Cancel / quit without
              saving to return unchanged.) Note: a split-flagged
              candidate isn't "broken" — it's flagged for explicit
              confirmation. Edit it, accept it, or merge it as you see
              fit.

On [s]kip   → exit Stage 2 cleanly without proceeding to Stage 3. No
              vault writes occur. You can re-run T-7 later, or skip
              Stage 2/3 entirely if you do not want a content seed.

On [b]ort   → exit with non-zero rc. No vault writes occur.
=== end what happens next ===

EOF
}

show_user_edit_diff() {
  if ! cmp -s "$ORIG_STAGE" "$STAGE" 2>/dev/null; then
    printf '\n=== your edits (vs original generated plan) ===\n' >&2
    diff -u "$ORIG_STAGE" "$STAGE" >&2 || true
    printf '=== end your edits ===\n\n' >&2
  fi
}

validate_stage_schema_version() {
  if ! grep -q '^schema_version: sp13-t6/1$' "$STAGE"; then
    cat <<MSG >&2

review-gate.sh: STAGED PLAN VALIDATION FAILED.
  Expected:  schema_version: sp13-t6/1   (in YAML frontmatter)
  Got:       (line missing or value differs)

User edits must preserve the schema_version anchor — it is the
round-trip contract between T-6 and Stage 3 (T-8). Either:
  - re-edit ([e]) to restore the line, or
  - abort ([b]) and re-run T-6 to regenerate.

MSG
    return 1
  fi
  return 0
}

# ----- prompt loop -----

# Read one choice from stdin OR the REVIEW_GATE_PROMPT_CHOICE env hook.
# Smoke tests pre-can a single choice; interactive runs read from terminal.
# Returns the choice in CHOICE_OUT (global — function MUST NOT run in a
# subshell, or PROMPT_CHOICE clears would not stick across iterations).
CHOICE_OUT=""
read_choice() {
  CHOICE_OUT=""
  if [ -n "${PROMPT_CHOICE:-}" ]; then
    CHOICE_OUT="$PROMPT_CHOICE"
    PROMPT_CHOICE=""
    return 0
  fi
  if IFS= read -r CHOICE_OUT; then
    return 0
  fi
  if [ "$ACCEPT_ON_EOF" = "1" ]; then
    CHOICE_OUT="a"
    return 0
  fi
  return 1
}

while :; do
  gate_preview "$STAGE" "$APPROVED_OUT" || {
    printf 'review-gate.sh: gate_preview failed\n' >&2
    exit 2
  }
  show_user_edit_diff
  print_what_happens_next
  printf 'Apply this plan? [a]pply (default) / [e]dit / [s]kip / [b]ort: ' >&2
  if ! read_choice; then
    printf '\nreview-gate.sh: stdin EOF; aborting (use --accept-on-eof to default-apply)\n' >&2
    printf 'b\n' | gate_apply "$STAGE" "$APPROVED_OUT" --skip-preview --accept-on-empty-stdin >/dev/null 2>&1 || true
    exit 1
  fi
  choice="$CHOICE_OUT"
  case "$choice" in
    ""|a|A)
      if ! validate_stage_schema_version; then
        printf 'review-gate.sh: re-prompting after validation failure.\n' >&2
        continue
      fi
      printf 'a\n' | gate_apply "$STAGE" "$APPROVED_OUT" --skip-preview --accept-on-empty-stdin
      rc=$?
      exit $rc
      ;;
    e|E)
      ed="${EDITOR:-vi}"
      if ! command -v "$ed" >/dev/null 2>&1; then
        for cand in vi nano vim; do
          if command -v "$cand" >/dev/null 2>&1; then ed="$cand"; break; fi
        done
      fi
      if ! command -v "$ed" >/dev/null 2>&1; then
        printf 'review-gate.sh: no editor available; cannot edit. Re-prompting.\n' >&2
        continue
      fi
      "$ed" "$STAGE" || printf 'review-gate.sh: editor returned non-zero; re-prompting unchanged.\n' >&2
      ;;
    s|S)
      printf 's\n' | gate_apply "$STAGE" "$APPROVED_OUT" --skip-preview --accept-on-empty-stdin
      rc=$?
      exit $rc
      ;;
    b|B|q|Q)
      printf 'b\n' | gate_apply "$STAGE" "$APPROVED_OUT" --skip-preview --accept-on-empty-stdin
      rc=$?
      exit $rc
      ;;
    *)
      printf 'review-gate.sh: invalid choice "%s"; press a, e, s, or b\n' "$choice" >&2
      ;;
  esac
done
