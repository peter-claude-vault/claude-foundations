#!/usr/bin/env bash
# tests/greenfield-pipeline/orchestrate-resume.sh — SP16 T-1 acceptance: halt-resume.
#
# Three-phase test:
#   Phase 1: invoke with --halt-before-review → orchestrator runs stages 1–3,
#            writes state/review-pending.flag, exits 64 (EX_USAGE).
#   Phase 2: invoke with --resume (no halt) — orchestrator skips stages 1–3
#            (markers exist), runs stage 4 with auto-apply, completes rc=0.
#   Phase 3: third invocation with --resume — fully idempotent, all 4 stages
#            skipped.
#
# Author: Plan 71 SP16 Session 1 (T-1).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_LABEL="T-1 orchestrate resume"

# shellcheck disable=SC1090
. "$REPO_ROOT/tests/greenfield-pipeline/_lib/orchestrate-fixture.sh"

make_sandbox "resume"

# --- Phase 1: halt before review ---

OUT1="$TEST_DIR/phase-1.out"
ERR1="$TEST_DIR/phase-1.err"
invoke_orchestrate_stub "resume" --halt-before-review </dev/null >"$OUT1" 2>"$ERR1"
RC1=$?

if [ "$RC1" = "64" ]; then
  pass "phase 1 rc=64 (review-pending halt)"
else
  fail "phase 1 rc=$RC1 (expected 64)"
  tail -30 "$ERR1" >&2
  emit_summary_and_exit
fi

# Stages 1–3 ran; their markers exist.
if assert_markers_exist "$INFERRED_DIR" "cluster,propose-taxonomy,import-plan"; then
  pass "phase 1 stages 1–3 markers present"
else
  fail "phase 1 stages 1–3 markers incomplete"
fi

# review-gate.done must NOT exist yet.
if [ ! -f "$INFERRED_DIR/state/review-gate.done" ]; then
  pass "phase 1 review-gate.done absent (halt was before stage 4)"
else
  fail "phase 1 review-gate.done unexpectedly present"
fi

# review-pending.flag must exist + contain import-plan path as evidence.
PENDING="$INFERRED_DIR/state/review-pending.flag"
if [ -f "$PENDING" ]; then
  pass "phase 1 review-pending.flag written"
  if grep -q "import-plan.md" "$PENDING"; then
    pass "phase 1 review-pending.flag references import-plan.md"
  else
    fail "phase 1 review-pending.flag missing import-plan.md reference"
    cat "$PENDING" >&2
  fi
else
  fail "phase 1 review-pending.flag missing"
fi

# Log has a review-gate record with exit_code=64.
LOG="$INFERRED_DIR/orchestrate-log.jsonl"
RG_REC=$(jq -c 'select(.stage=="review-gate")' < "$LOG" | tail -1)
RG_EC=$(printf '%s' "$RG_REC" | jq -r '.exit_code')
if [ "$RG_EC" = "64" ]; then
  pass "phase 1 log review-gate exit_code=64"
else
  fail "phase 1 log review-gate exit_code=$RG_EC (expected 64)"
fi

# --- Phase 2: resume with auto-apply ---

OUT2="$TEST_DIR/phase-2.out"
ERR2="$TEST_DIR/phase-2.err"
REVIEW_GATE_ACCEPT_ON_EOF=1 \
  invoke_orchestrate_stub "resume" --resume </dev/null >"$OUT2" 2>"$ERR2"
RC2=$?

if [ "$RC2" = "0" ]; then
  pass "phase 2 rc=0 (resume → apply)"
else
  fail "phase 2 rc=$RC2 (expected 0)"
  tail -40 "$ERR2" >&2
  emit_summary_and_exit
fi

# Confirm phase 2 SKIPPED stages 1–3 (markers existed) and RAN stage 4.
SKIP_COUNT=$(grep -c '— SKIP (marker exists)' "$ERR2" 2>/dev/null || echo 0)
SKIP_COUNT=$(printf '%s' "$SKIP_COUNT" | tr -d ' \n')
if [ "$SKIP_COUNT" = "3" ]; then
  pass "phase 2 skipped exactly 3 stages (1–3)"
else
  fail "phase 2 SKIP count = $SKIP_COUNT (expected 3)"
  grep -E 'SKIP|RUN' "$ERR2" >&2 || true
fi
if grep -q 'stage 4 (review-gate) — RUN' "$ERR2"; then
  pass "phase 2 ran stage 4 (review-gate)"
else
  fail "phase 2 did not run stage 4"
fi

# All 4 markers now exist.
if assert_markers_exist "$INFERRED_DIR" "cluster,propose-taxonomy,import-plan,review-gate"; then
  pass "phase 2 all 4 markers present"
else
  fail "phase 2 markers incomplete"
fi

# review-pending.flag must be cleared.
if [ ! -f "$PENDING" ]; then
  pass "phase 2 review-pending.flag cleared after apply"
else
  fail "phase 2 review-pending.flag still present"
fi

# approved-import-plan.md exists.
if [ -s "$INFERRED_DIR/approved-import-plan.md" ]; then
  pass "phase 2 approved-import-plan.md written"
else
  fail "phase 2 approved-import-plan.md missing"
fi

# --- Phase 3: idempotent re-resume (skips all 4) ---

OUT3="$TEST_DIR/phase-3.out"
ERR3="$TEST_DIR/phase-3.err"
REVIEW_GATE_ACCEPT_ON_EOF=1 \
  invoke_orchestrate_stub "resume" --resume </dev/null >"$OUT3" 2>"$ERR3"
RC3=$?

if [ "$RC3" = "0" ]; then
  pass "phase 3 rc=0 (full idempotent re-run)"
else
  fail "phase 3 rc=$RC3 (expected 0)"
  tail -20 "$ERR3" >&2
fi

SKIP_COUNT_3=$(grep -c '— SKIP (marker exists)' "$ERR3" 2>/dev/null || echo 0)
SKIP_COUNT_3=$(printf '%s' "$SKIP_COUNT_3" | tr -d ' \n')
if [ "$SKIP_COUNT_3" = "4" ]; then
  pass "phase 3 skipped all 4 stages (idempotent)"
else
  fail "phase 3 SKIP count = $SKIP_COUNT_3 (expected 4)"
fi

emit_summary_and_exit
