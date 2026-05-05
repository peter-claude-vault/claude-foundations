#!/usr/bin/env bash
# onboarding/auto-author/surface-9-architect-prior-seed.sh — SP12 T-10 (Plan 71 SP12 Session 3)
#
# Surface #9 — Auto-author architect prompt-tuning artifacts that make
# /architect skill-aware of the user's industry vocabulary. Two manifest
# fields written under .architect.*:
#   - prior_seed[]       (≥3 industry-tuned concern entries)
#   - research_topics[]  (≥3 industry-tuned search-prompt seeds)
#
# Inputs (user-manifest.json):
#   .identity.industry    (str) — drives industry-keyed phrasing
#   .architect.prior_seed (str[]) — existing concerns preserved as additive
#                                    base; surface adds industry-tuned
#                                    entries via union.
#
# Industry-keyed phrasing tables. Free-form values fall through to the LLM-
# compose path, which currently emits a generic-but-structured set (mock-LLM
# mode for tests; real claude -p invocation deferred to v2.0.0-rc fast-follow
# per Session 2 carry-forward).
#
# Three-step gate (single-target via gate_generate + gate_apply against
# user-manifest). Provenance recorded at file-level via _provenance fields
# would pollute the schema — instead, each composed entry is namespaced with
# a leading source marker (`[architect-prior-seed:<industry>] `) for downstream auditing.
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - $USER_MANIFEST (jq-patched .architect.{prior_seed, research_topics})
#   Schema-types:
#     - JSON; user-manifest-schema.json declares both fields. research_topics
#       is 1.5.x additive (added in same commit). Pre/post jq-parse validation.
#   Pre-write validation:
#     - user-manifest readable + parseable
#     - proposed prior_seed is array length >=3, all entries non-empty strings
#     - proposed research_topics is array length >=3, all entries non-empty strings
#   Failure mode: BLOCK AND LOG.
#
# CONSTRAINTS (R-23): bash 3.2; jq required.
#
# USAGE:
#   surface-9-architect-prior-seed.sh
#     [--user-manifest PATH]
#     [--industry-override STR]   # bypass .identity.industry read
#     [--auto-apply] [--skip-preview] [--dry-run]
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP12 Session 3

set -u

diag() { printf 'surface-9 FAIL: %s\n' "$1" >&2; }
info() { printf 'surface-9: %s\n' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONBOARDING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GATE_LIB="$ONBOARDING_DIR/lib/three-step-gate.sh"
[ -r "$GATE_LIB" ] || { diag "three-step-gate.sh not readable"; exit 2; }
# shellcheck source=/dev/null
. "$GATE_LIB"

# --- defaults + arg parsing ---
USER_MANIFEST="${USER_MANIFEST:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
INDUSTRY_OVERRIDE=""
SURFACE_ID="surface-9-architect-prior-seed"
GENERATED_FROM="identity.industry+architect-concerns-interview"
AUTO_APPLY=0
SKIP_PREVIEW=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user-manifest)      USER_MANIFEST="$2"; shift 2 ;;
    --industry-override)  INDUSTRY_OVERRIDE="$2"; shift 2 ;;
    --auto-apply)         AUTO_APPLY=1; shift ;;
    --skip-preview)       SKIP_PREVIEW=1; shift ;;
    --dry-run)            DRY_RUN=1; gate_set_dry_run 1; shift ;;
    -h|--help)            sed -n '2,46p' "$0"; exit 0 ;;
    *)                    diag "unknown arg: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { diag "jq required on PATH"; exit 2; }
[ -f "$USER_MANIFEST" ] || { diag "user-manifest not found: $USER_MANIFEST"; exit 2; }
jq -e . "$USER_MANIFEST" >/dev/null 2>&1 || { diag "user-manifest invalid JSON"; exit 2; }

# --- read declared industry ---
INDUSTRY=""
if [ -n "$INDUSTRY_OVERRIDE" ]; then
  INDUSTRY="$INDUSTRY_OVERRIDE"
else
  INDUSTRY="$(jq -r '.identity.industry // ""' "$USER_MANIFEST" 2>/dev/null)"
fi
INDUSTRY_LC="$(printf '%s' "$INDUSTRY" | tr 'A-Z' 'a-z')"

EXISTING_PRIOR_SEED_JSON="$(jq -c '.architect.prior_seed // []' "$USER_MANIFEST")"
EXISTING_RESEARCH_TOPICS_JSON="$(jq -c '.architect.research_topics // []' "$USER_MANIFEST")"

# --- industry-tuned phrasing tables (mock-LLM mode) ---
prior_seed_for_industry() {
  case "$1" in
    consulting|management-consulting)
      printf '[architect-prior-seed:consulting] engagement-cluster drift across overlapping client portfolios\n'
      printf '[architect-prior-seed:consulting] under-documented decision history in long-running engagements\n'
      printf '[architect-prior-seed:consulting] meeting-output-to-deliverable cascade gaps (notes never become PRDs)\n'
      printf '[architect-prior-seed:consulting] stakeholder-context churn (people files outdated by reorg)\n'
      ;;
    academic-research|research|academia)
      printf '[architect-prior-seed:research] dataset-version skew between draft and submission revisions\n'
      printf '[architect-prior-seed:research] citation graph drift (works-cited entries that vanish from notes)\n'
      printf '[architect-prior-seed:research] reproducibility gaps between method-section claims and code\n'
      printf '[architect-prior-seed:research] under-linked literature reviews (orphaned paper notes)\n'
      ;;
    software|engineering|software-engineering|tech)
      printf '[architect-prior-seed:software] decision-record decay (ADRs that no longer match the codebase)\n'
      printf '[architect-prior-seed:software] stale postmortem context (incident notes lose their tickets)\n'
      printf '[architect-prior-seed:software] feature-flag debt accumulation in long-running projects\n'
      printf '[architect-prior-seed:software] under-linked library/API references in implementation notes\n'
      ;;
    education|teaching)
      printf '[architect-prior-seed:education] curriculum-version drift between syllabus and module content\n'
      printf '[architect-prior-seed:education] under-tracked student-query patterns across cohorts\n'
      printf '[architect-prior-seed:education] orphaned reference materials between term boundaries\n'
      printf '[architect-prior-seed:education] assessment-feedback cascade gaps (rubric-to-grade traceability)\n'
      ;;
    product|product-management|design)
      printf '[architect-prior-seed:product] PRD-vs-shipped-feature drift (specs that no longer match)\n'
      printf '[architect-prior-seed:product] customer-feedback orphaning (themes never reconciled with roadmap)\n'
      printf '[architect-prior-seed:product] competitor-research staleness in long-running positioning docs\n'
      printf '[architect-prior-seed:product] design-decision rationale that decays without artifact links\n'
      ;;
    *)
      # Fallback for unknown/empty industries — generic-but-structured.
      printf '[architect-prior-seed:generic] decision-record drift over time (rationale becomes orphaned)\n'
      printf '[architect-prior-seed:generic] under-linked reference material accumulating in capture buffers\n'
      printf '[architect-prior-seed:generic] stakeholder/context-file staleness as priorities shift\n'
      printf '[architect-prior-seed:generic] orphaned long-running notes that never reconcile with deliverables\n'
      ;;
  esac
}

research_topics_for_industry() {
  case "$1" in
    consulting|management-consulting)
      printf '[architect-prior-seed:consulting] PKM patterns for client-engagement vaults — structure, frequency, retrieval\n'
      printf '[architect-prior-seed:consulting] meeting-note-to-deliverable cascade tooling for consulting workflows\n'
      printf '[architect-prior-seed:consulting] cross-engagement knowledge transfer techniques in professional services\n'
      ;;
    academic-research|research|academia)
      printf '[architect-prior-seed:research] literature-review knowledge management for graduate research\n'
      printf '[architect-prior-seed:research] dataset-versioning best practices in computational research\n'
      printf '[architect-prior-seed:research] PKM patterns for thesis-in-progress writing surfaces\n'
      ;;
    software|engineering|software-engineering|tech)
      printf '[architect-prior-seed:software] ADR drift detection patterns in long-running codebases\n'
      printf '[architect-prior-seed:software] postmortem-knowledge retention across team rotations\n'
      printf '[architect-prior-seed:software] feature-flag lifecycle management documentation patterns\n'
      ;;
    education|teaching)
      printf '[architect-prior-seed:education] curriculum-versioning patterns for multi-cohort instruction\n'
      printf '[architect-prior-seed:education] cross-term student-feedback synthesis workflows\n'
      printf '[architect-prior-seed:education] reference-material lifecycle in evergreen courses\n'
      ;;
    product|product-management|design)
      printf '[architect-prior-seed:product] PRD-vs-shipped reconciliation tooling for product teams\n'
      printf '[architect-prior-seed:product] customer-discovery synthesis patterns at scale\n'
      printf '[architect-prior-seed:product] competitor-tracking knowledge bases — refresh cadence + structure\n'
      ;;
    *)
      printf '[architect-prior-seed:generic] PKM best practices for the user-declared workflow\n'
      printf '[architect-prior-seed:generic] decision-record retention patterns across long-running projects\n'
      printf '[architect-prior-seed:generic] reference-material organization techniques for multi-context vaults\n'
      ;;
  esac
}

PROPOSED_PS_LINES="$(prior_seed_for_industry "$INDUSTRY_LC")"
PROPOSED_RT_LINES="$(research_topics_for_industry "$INDUSTRY_LC")"

PROPOSED_PS_JSON="$(printf '%s\n' "$PROPOSED_PS_LINES" | jq -R . | jq -s 'map(select(. != ""))')"
PROPOSED_RT_JSON="$(printf '%s\n' "$PROPOSED_RT_LINES" | jq -R . | jq -s 'map(select(. != ""))')"

# Validate length >=3.
PS_LEN="$(printf '%s' "$PROPOSED_PS_JSON" | jq -r 'length')"
RT_LEN="$(printf '%s' "$PROPOSED_RT_JSON" | jq -r 'length')"
if [ "$PS_LEN" -lt 3 ]; then diag "proposed prior_seed length $PS_LEN < 3"; exit 2; fi
if [ "$RT_LEN" -lt 3 ]; then diag "proposed research_topics length $RT_LEN < 3"; exit 2; fi

# Compute MERGED (union, deduplicated) — preserve existing user content.
MERGED_PS_JSON="$(printf '%s\n%s\n' "$EXISTING_PRIOR_SEED_JSON" "$PROPOSED_PS_JSON" | jq -s 'add | unique_by(.)')"
MERGED_RT_JSON="$(printf '%s\n%s\n' "$EXISTING_RESEARCH_TOPICS_JSON" "$PROPOSED_RT_JSON" | jq -s 'add | unique_by(.)')"

# --- generator ---
gen_user_manifest() {
  jq \
    --argjson ps "$MERGED_PS_JSON" \
    --argjson rt "$MERGED_RT_JSON" \
    '
      .architect = (.architect // {})
      | .architect.prior_seed = $ps
      | .architect.research_topics = $rt
    ' "$USER_MANIFEST"
}

# --- main ---
if [ -z "${TG_STAGE_DIR:-}" ]; then
  TG_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/surface-9.XXXXXX")"
  export TG_STAGE_DIR
fi

stage="$(gate_generate "$SURFACE_ID" gen_user_manifest)" || { diag "gate_generate failed"; exit 2; }

# Post-validation.
if ! jq -e . "$stage" >/dev/null 2>&1; then
  diag "staged user-manifest failed jq parse"
  exit 2
fi
got_ps_len="$(jq -r '.architect.prior_seed | length' "$stage")"
got_rt_len="$(jq -r '.architect.research_topics | length' "$stage")"
if [ "$got_ps_len" -lt 3 ] || [ "$got_rt_len" -lt 3 ]; then
  diag "staged manifest fails AC: prior_seed=$got_ps_len research_topics=$got_rt_len"
  exit 2
fi

apply_args=""
[ "$SKIP_PREVIEW" = "1" ] && apply_args="$apply_args --skip-preview"
[ "$AUTO_APPLY"   = "1" ] && apply_args="$apply_args --accept-on-empty-stdin"

# shellcheck disable=SC2086
gate_apply "$stage" "$USER_MANIFEST" $apply_args
rc=$?
case "$rc" in
  0) info "surface-9 complete (industry='$INDUSTRY'; prior_seed=$got_ps_len; research_topics=$got_rt_len)" ;;
  1) info "surface-9 aborted at gate prompt" ;;
  *) diag "gate_apply returned rc=$rc" ;;
esac
exit "$rc"
