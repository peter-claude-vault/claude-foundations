#!/usr/bin/env bash
# onboard.sh — top-level onboarder pipeline runner.
#
# Chains the deterministic pieces of the 5-section flow:
#   Section A (deterministic)
#     -> ux/section-a.sh -> checkpoint --section A
#   Section B/C/D (two-pass, LLM extraction in middle)
#     Pass 1: ux/section-X.sh                       (records transcript, compiles prompt)
#                                                    exits rc=5; runner emits HANDOFF
#     [LLM produces extraction stub at $stub_path]
#     Pass 2: EXTRACTION_OUTPUT_OVERRIDE=$stub_path ux/section-X.sh
#     -> ux/render-summary.sh --section X           (corrections + phases_completed[])
#   Section E (deterministic)
#     -> ux/section-e.sh -> checkpoint --section E
#   Finalize
#     -> bootstrap-schemas.sh                       (consumes all 5 -> writes manifest)
#   Section F (deterministic, SP16 T-2)
#     -> 7 SP12 auto-author surfaces (1, 2, 3, 4, 5, 6, 9)
#     -> infer-vault-structure/orchestrate.sh (if SEED_CONTENT_PATH set)
#     Section F runs AFTER finalize because the surfaces read the populated
#     user-manifest that bootstrap-schemas.sh writes (and surface-2 needs
#     the SP11 done-marker that bootstrap-schemas.sh writes via
#     seed_memories()). SP16 spec L48 said "before run_finalize"; corrected
#     to "after run_finalize" in SP16 Session 2 (data-flow integrity
#     overrides defective spec text per feedback_hard_constraint_overrides_spec).
#
# Section D's Pass 2 invokes initial-job-setup.sh internally (not by this runner)
# unless opt-out #9 is elected. See SKILL.md ## Initial-Job-Setup Integration.
#
# Modes:
#   default       Interactive. Yields rc=5 at each B/C/D Pass-1 boundary so the
#                 caller (LLM driving /onboard, or harness) can do extraction
#                 and re-invoke with --resume --section X --extraction-stub PATH.
#   --test-fixture-dir DIR
#                 Non-interactive. For each section in {B,C,D}, expects
#                 DIR/section-{b,c,d}-extraction-stub.json to exist. Runs the
#                 entire chain end-to-end in one shot. Used by SP07 T-11 Alex
#                 dogfood + SP08 T-7 Lima E2E.
#   --resume      Reads user-manifest.system.phases_completed[] and starts at
#                 the first incomplete phase.
#   --section X   Runs only the indicated section (and its checkpoint), then
#                 exits. Useful for re-running a single section after a quit.
#                 X ∈ {a,b,c,d,e,f}.
#
#   Section F (auto-author + content-seeding) flags (SP16 T-2):
#   --skip-auto-author             Skip the 7 SP12 auto-author surfaces.
#   --skip-content-seeding         Skip the SP13 four-stage orchestrator.
#   --auto-author-only-surfaces=<csv>
#                                  Run a subset of surfaces (e.g. 1,3,5).
#
# Exit codes:
#   0   Pipeline complete (all 5 sections + bootstrap-schemas committed).
#   2   Bad invocation (unknown flag, missing dependency, missing fixture).
#   3   I/O / write failure delegated from a section script.
#   5   Paused at LLM-extraction handoff. State on disk; re-invoke with
#       --resume --section X --extraction-stub PATH after extraction.
#   130 User quit during a section.
#
# Environment:
#   CLAUDE_HOME           Default: $HOME/.claude
#   INPUTS_DIR            Default: $CLAUDE_HOME/onboarding
#   USER_MANIFEST         Default: $CLAUDE_HOME/user-manifest.json
#   ONBOARD_DIR           Default: dir containing this script (foundation runtime)
#
# Bash 3.2 compatible. No associative arrays, no [[ =~ ]] in critical paths.

set -eu

# -----------------------------------------------------------------------------
# Resolve paths.
# -----------------------------------------------------------------------------
: "${CLAUDE_HOME:=$HOME/.claude}"
: "${INPUTS_DIR:=$CLAUDE_HOME/onboarding}"
: "${USER_MANIFEST:=$CLAUDE_HOME/user-manifest.json}"

# Locate the foundation onboarding tree. When installed, this is
# $CLAUDE_HOME/onboarding/ux/ and $CLAUDE_HOME/onboarding/. When run from
# foundation-repo at dev time, it's repo-root/onboarding/ux/ and
# repo-root/onboarding/. We resolve relative to this script's location so
# either context works.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# skills/onboarder/onboard.sh lives one level under skills/, two under repo-root.
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
ONBOARDING_ROOT="$REPO_ROOT/onboarding"
UX_DIR="$ONBOARDING_ROOT/ux"

# Sanity check.
for required in "$UX_DIR/section-a.sh" "$UX_DIR/section-b.sh" \
                "$UX_DIR/section-c.sh" "$UX_DIR/section-d.sh" \
                "$UX_DIR/section-e.sh" "$UX_DIR/render-summary.sh" \
                "$ONBOARDING_ROOT/bootstrap-schemas.sh" \
                "$ONBOARDING_ROOT/checkpoint.sh"; do
  if [ ! -f "$required" ]; then
    printf 'onboard.sh: required script missing: %s\n' "$required" >&2
    exit 2
  fi
done

mkdir -p "$INPUTS_DIR"

# -----------------------------------------------------------------------------
# argv parsing.
# -----------------------------------------------------------------------------
TEST_FIXTURE_DIR=""
RESUME=0
ONLY_SECTION=""
EXTRACTION_STUB=""
DRY_RUN=0
SEED_CONTENT=""
SEED_BATCH_CAP=100
SKIP_AUTO_AUTHOR=0
SKIP_CONTENT_SEEDING=0
AUTO_AUTHOR_ONLY_SURFACES=""

usage() {
  sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --test-fixture-dir)
      shift
      [ $# -gt 0 ] || { echo "onboard.sh: --test-fixture-dir requires a path" >&2; exit 2; }
      TEST_FIXTURE_DIR="$1"
      ;;
    --resume)
      RESUME=1
      ;;
    --section)
      shift
      [ $# -gt 0 ] || { echo "onboard.sh: --section requires a letter (a|b|c|d|e)" >&2; exit 2; }
      ONLY_SECTION="$1"
      ;;
    --extraction-stub)
      shift
      [ $# -gt 0 ] || { echo "onboard.sh: --extraction-stub requires a path" >&2; exit 2; }
      EXTRACTION_STUB="$1"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --seed-content)
      shift
      [ $# -gt 0 ] || { echo "onboard.sh: --seed-content requires <path-or-paste>" >&2; exit 2; }
      SEED_CONTENT="$1"
      ;;
    --seed-batch-cap)
      shift
      [ $# -gt 0 ] || { echo "onboard.sh: --seed-batch-cap requires N" >&2; exit 2; }
      SEED_BATCH_CAP="$1"
      ;;
    --skip-auto-author)
      SKIP_AUTO_AUTHOR=1
      ;;
    --skip-content-seeding)
      SKIP_CONTENT_SEEDING=1
      ;;
    --auto-author-only-surfaces)
      shift
      [ $# -gt 0 ] || { echo "onboard.sh: --auto-author-only-surfaces requires <csv>" >&2; exit 2; }
      AUTO_AUTHOR_ONLY_SURFACES="$1"
      ;;
    --auto-author-only-surfaces=*)
      AUTO_AUTHOR_ONLY_SURFACES="${1#--auto-author-only-surfaces=}"
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "onboard.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------
log() { printf 'onboard.sh: %s\n' "$*" >&2; }

emit_handoff() {
  # Structured handoff signal — read by both LLM-driven /onboard flow and by
  # harness scripts. Format: '# HANDOFF: <action> [<arg>=<val> ...]'
  printf '# HANDOFF: %s\n' "$*"
}

phase_completed() {
  # Returns 0 if the given section ID (A|B|C|D|E) is in
  # user-manifest.system.phases_completed[]. Returns 1 if absent or manifest
  # not present.
  local section="$1"
  [ -f "$USER_MANIFEST" ] || return 1
  jq -e --arg s "$section" '.system.phases_completed // [] | index($s) // empty' \
     "$USER_MANIFEST" >/dev/null 2>&1
}

resolve_fixture() {
  # Map section letter to expected fixture filename.
  local section="$1"
  case "$section" in
    B) printf '%s/section-b-extraction-stub.json' "$TEST_FIXTURE_DIR" ;;
    C) printf '%s/section-c-extraction-stub.json' "$TEST_FIXTURE_DIR" ;;
    D) printf '%s/section-d-extraction-stub.json' "$TEST_FIXTURE_DIR" ;;
    *) printf '' ;;
  esac
}

# -----------------------------------------------------------------------------
# Phase runners.
# -----------------------------------------------------------------------------
run_section_a() {
  log "Section A — discovery review"
  [ "$DRY_RUN" -eq 1 ] && { emit_handoff "would-run section-a"; return 0; }
  bash "$UX_DIR/section-a.sh"
  bash "$ONBOARDING_ROOT/checkpoint.sh" --section A
}

run_section_e() {
  log "Section E — final checkboxes"
  [ "$DRY_RUN" -eq 1 ] && { emit_handoff "would-run section-e"; return 0; }
  bash "$UX_DIR/section-e.sh"
  bash "$ONBOARDING_ROOT/checkpoint.sh" --section E
}

run_two_pass_section() {
  # Section B/C/D have two passes with an LLM extraction in between.
  local section="$1"   # B | C | D
  local lc
  lc="$(echo "$section" | tr '[:upper:]' '[:lower:]')"
  local script="$UX_DIR/section-${lc}.sh"
  log "Section ${section} — Pass 1 (transcript + prompt-card compile)"

  [ "$DRY_RUN" -eq 1 ] && { emit_handoff "would-run section-${lc}"; return 0; }

  # If a stub was supplied via --extraction-stub or via test fixtures, skip
  # Pass 1's exit-5 yield and go straight to Pass 2 with EXTRACTION_OUTPUT_OVERRIDE.
  local stub=""
  if [ -n "$EXTRACTION_STUB" ]; then
    stub="$EXTRACTION_STUB"
  elif [ -n "$TEST_FIXTURE_DIR" ]; then
    stub="$(resolve_fixture "$section")"
    [ -r "$stub" ] || { log "test fixture missing: $stub"; exit 2; }
  fi

  if [ -n "$stub" ]; then
    EXTRACTION_OUTPUT_OVERRIDE="$stub" bash "$script"
    log "Section ${section} — Pass 2 complete; running render-summary"
    bash "$UX_DIR/render-summary.sh" --section "$section"
    return 0
  fi

  # Interactive mode: run Pass 1, expect rc=5, emit HANDOFF for caller.
  set +e
  bash "$script"
  local rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then
    log "Section ${section} — Pass 1 complete; awaiting LLM extraction"
    emit_handoff "extract-section-${section} resume-with=\"--resume --section ${section} --extraction-stub <path>\""
    exit 5
  elif [ "$rc" -ne 0 ]; then
    log "Section ${section} — Pass 1 failed rc=${rc}"
    exit "$rc"
  fi
  # rc=0 from Pass-1 invocation means EXTRACTION_OUTPUT_OVERRIDE was already
  # in env (rare; honor it).
  log "Section ${section} — Pass 1 returned rc=0 (extraction inline); running render-summary"
  bash "$UX_DIR/render-summary.sh" --section "$section"
}

run_finalize() {
  log "Finalize — bootstrap-schemas (consumes all 5 extraction-output-*.json)"
  [ "$DRY_RUN" -eq 1 ] && { emit_handoff "would-run bootstrap-schemas"; return 0; }
  bash "$ONBOARDING_ROOT/bootstrap-schemas.sh"
}

# -----------------------------------------------------------------------------
# Section F — auto-author personalization surfaces + content-seeding (SP16 T-2).
# -----------------------------------------------------------------------------
# Invokes the seven SP12 Tier-1 surfaces (1, 2, 3, 4, 5, 6, 9) in declared
# order, then the SP13 four-stage infer-vault chain via SP16 T-1's
# orchestrate.sh — but only if Stage-1 INGEST produced a seed-content IR.
#
# Idempotency: each surface and the orchestrator are skipped on re-run if
# their done-marker exists under $SECTION_F_STATE_DIR.
#
# Test affordance: SURFACE_DIR_OVERRIDE (env) re-roots the surface dispatch
# at a synthetic stub directory for hermetic Section-F orchestration tests.

SECTION_F_STATE_DIR="${SECTION_F_STATE_DIR:-$INPUTS_DIR/section-f-state}"
SECTION_F_SURFACE_DIR="${SURFACE_DIR_OVERRIDE:-$ONBOARDING_ROOT/auto-author}"
SECTION_F_ORCHESTRATE_SH="${ORCHESTRATE_SH_OVERRIDE:-$REPO_ROOT/skills/infer-vault-structure/orchestrate.sh}"

section_f_surfaces_in_order() {
  # Echo the per-run surface list (default 7; subset honored).
  if [ -n "$AUTO_AUTHOR_ONLY_SURFACES" ]; then
    echo "$AUTO_AUTHOR_ONLY_SURFACES" | tr ',' ' '
  else
    echo "1 2 3 4 5 6 9"
  fi
}

resolve_surface_script() {
  # $1 = surface number; echoes resolved path, or empty if not found.
  local n="$1"
  local cand
  for cand in "$SECTION_F_SURFACE_DIR"/surface-${n}-*.sh; do
    [ -f "$cand" ] || continue
    printf '%s\n' "$cand"
    return 0
  done
  return 1
}

run_section_f_surface() {
  local n="$1"
  local marker="$SECTION_F_STATE_DIR/surface-${n}.done"
  if [ -f "$marker" ]; then
    log "Section F surface-${n} — SKIP (marker exists)"
    return 0
  fi

  local script_path
  script_path="$(resolve_surface_script "$n" || true)"
  if [ -z "$script_path" ]; then
    log "Section F surface-${n} — script not found under $SECTION_F_SURFACE_DIR; skipping"
    return 0
  fi

  log "Section F surface-${n} — RUN ($(basename "$script_path"))"
  bash "$script_path" \
    --user-manifest "$USER_MANIFEST" \
    --auto-apply --skip-preview </dev/null
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    log "Section F surface-${n} FAILED rc=$rc"
    return "$rc"
  fi
  printf 'surface-%s\t%s\n' "$n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker"
  return 0
}

run_section_f_orchestrator() {
  if [ ! -x "$SECTION_F_ORCHESTRATE_SH" ]; then
    log "Section F orchestrator — script not found/executable: $SECTION_F_ORCHESTRATE_SH; skipping"
    return 0
  fi
  if [ ! -f "$SEED_CONTENT_PATH" ]; then
    log "Section F orchestrator — SEED_CONTENT_PATH not a file: $SEED_CONTENT_PATH; skipping"
    return 0
  fi

  # T-1 carry-forward: review-gate.sh's interactive prompt blocks indefinitely
  # on non-TTY stdin unless one of these env vars is set. Default-apply on the
  # documented `/onboard --seed-content <vault>` greenfield UX.
  if [ ! -t 0 ] \
     && [ -z "${REVIEW_GATE_ACCEPT_ON_EOF:-}" ] \
     && [ -z "${REVIEW_GATE_PROMPT_CHOICE:-}" ]; then
    REVIEW_GATE_ACCEPT_ON_EOF=1
    export REVIEW_GATE_ACCEPT_ON_EOF
  fi

  local slug="${ONBOARDER_SEED_SLUG:-onboarding}"
  log "Section F orchestrator — RUN (slug=$slug, ir=$SEED_CONTENT_PATH)"
  # No --resume: orchestrate.sh's per-stage state/<stage>.done markers handle
  # idempotency unconditionally; --resume only affects the review-pending
  # halt-message path, not stage-skipping.
  "$SECTION_F_ORCHESTRATE_SH" \
    --slug "$slug" \
    --ir-path "$SEED_CONTENT_PATH"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    log "Section F orchestrator FAILED rc=$rc"
    return "$rc"
  fi
  return 0
}

run_section_f() {
  log "Section F — auto-author personalization + content-seeding orchestrator"
  [ "$DRY_RUN" -eq 1 ] && { emit_handoff "would-run section-f"; return 0; }

  mkdir -p "$SECTION_F_STATE_DIR"

  if [ "$SKIP_AUTO_AUTHOR" -eq 1 ]; then
    log "Section F — auto-author surfaces SKIPPED via --skip-auto-author"
  else
    local n
    for n in $(section_f_surfaces_in_order); do
      run_section_f_surface "$n" || return $?
    done
  fi

  if [ "$SKIP_CONTENT_SEEDING" -eq 1 ]; then
    log "Section F — content-seeding orchestrator SKIPPED via --skip-content-seeding"
  elif [ -n "${SEED_CONTENT_PATH:-}" ]; then
    run_section_f_orchestrator || return $?
  else
    log "Section F — no SEED_CONTENT_PATH; content-seeding orchestrator skipped"
  fi
}

# -----------------------------------------------------------------------------
# Main control flow.
# -----------------------------------------------------------------------------

# Stage 1 INGEST — seed content intake (SP13 T-1). Fires before interview-Q
# surface so seeded content acts as discovery input alongside interview answers.
if [ -n "$SEED_CONTENT" ]; then
  intake_sh="$ONBOARDING_ROOT/seed-content/intake.sh"
  if [ ! -f "$intake_sh" ]; then
    printf 'onboard.sh: --seed-content requires %s\n' "$intake_sh" >&2
    exit 2
  fi
  log "Stage 1 INGEST — seed content intake"
  seed_dir="$INPUTS_DIR/seed-content"
  mkdir -p "$seed_dir"
  bash "$intake_sh" --source "$SEED_CONTENT" --manifest "$seed_dir/intake-manifest.jsonl"
  seed_count=$(wc -l < "$seed_dir/intake-manifest.jsonl" | tr -d ' ')
  printf 'seed content detected: %s items\n' "$seed_count"

  ir_builder_sh="$ONBOARDING_ROOT/seed-content/ir-builder.sh"
  if [ -f "$ir_builder_sh" ] && [ "$seed_count" -gt 0 ]; then
    log "Stage 1 INGEST — IR build (batch cap=$SEED_BATCH_CAP)"
    bash "$ir_builder_sh" \
      --manifest "$seed_dir/intake-manifest.jsonl" \
      --ir "$seed_dir/ir.jsonl" \
      --batch-cap "$SEED_BATCH_CAP"
  fi

  # Wire IR path forward to Section F's content-seeding orchestrator.
  if [ -s "$seed_dir/ir.jsonl" ]; then
    SEED_CONTENT_PATH="$seed_dir/ir.jsonl"
    export SEED_CONTENT_PATH
  fi
fi

# Single-section mode.
if [ -n "$ONLY_SECTION" ]; then
  uc="$(echo "$ONLY_SECTION" | tr '[:lower:]' '[:upper:]')"
  case "$uc" in
    A) run_section_a ;;
    B|C|D) run_two_pass_section "$uc" ;;
    E) run_section_e ;;
    F) run_section_f ;;
    *) echo "onboard.sh: --section must be one of a|b|c|d|e|f" >&2; exit 2 ;;
  esac
  exit 0
fi

# Full pipeline.
if [ "$RESUME" -eq 1 ] || phase_completed A; then
  log "Section A already complete; skipping"
else
  run_section_a
fi

for sec in B C D; do
  if [ "$RESUME" -eq 1 ] && phase_completed "$sec"; then
    log "Section ${sec} already complete; skipping"
    continue
  fi
  run_two_pass_section "$sec"
done

if [ "$RESUME" -eq 1 ] && phase_completed E; then
  log "Section E already complete; skipping"
else
  run_section_e
fi

run_finalize

# Section F runs post-finalize: surfaces require the populated user-manifest
# that bootstrap-schemas.sh writes (and surface-2 needs the SP11 done-marker
# bootstrap-schemas writes via seed_memories()). See run_section_f docstring
# for the spec-defect correction history.
run_section_f

log "Pipeline complete."
exit 0
