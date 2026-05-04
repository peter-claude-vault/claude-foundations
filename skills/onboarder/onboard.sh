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
fi

# Single-section mode.
if [ -n "$ONLY_SECTION" ]; then
  uc="$(echo "$ONLY_SECTION" | tr '[:lower:]' '[:upper:]')"
  case "$uc" in
    A) run_section_a ;;
    B|C|D) run_two_pass_section "$uc" ;;
    E) run_section_e ;;
    *) echo "onboard.sh: --section must be one of a|b|c|d|e" >&2; exit 2 ;;
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

log "Pipeline complete."
exit 0
