#!/usr/bin/env bash
# tests/sp16/T-1-orchestrate-review-rejected.sh — SP16 T-1 acceptance:
# user-abort at review gate.
#
# Drives review-gate.sh via REVIEW_GATE_PROMPT_CHOICE=b so the user actively
# rejects the import plan. Confirms orchestrate.sh:
#   - completes stages 1–3 successfully (markers present)
#   - propagates review-gate's rc=1 to its own exit code
#   - does NOT write review-gate.done (no apply)
#   - does NOT produce approved-import-plan.md
#   - logs the review-gate stage with exit_code=1
#
# Author: Plan 71 SP16 Session 1 (T-1).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_LABEL="T-1 orchestrate review-rejected"

# shellcheck disable=SC1090
. "$REPO_ROOT/tests/sp16/_lib/orchestrate-fixture.sh"

make_sandbox "review-rejected"

OUT1="$TEST_DIR/run.out"
ERR1="$TEST_DIR/run.err"
# Pre-can a single 'b'(ort) choice. After it's consumed, EOF would otherwise
# fall back; we set ACCEPT_ON_EOF=0 to keep the abort path deterministic.
REVIEW_GATE_PROMPT_CHOICE=b \
  invoke_orchestrate_stub "review-rejected" </dev/null >"$OUT1" 2>"$ERR1"
RC=$?

# review-gate.sh exits 1 on user abort; orchestrate.sh propagates.
if [ "$RC" = "1" ]; then
  pass "rc=1 (user abort propagated from review-gate)"
else
  fail "rc=$RC (expected 1 on user abort)"
  tail -40 "$ERR1" >&2
  emit_summary_and_exit
fi

# Stages 1–3 completed; their markers exist.
if assert_markers_exist "$INFERRED_DIR" "cluster,propose-taxonomy,import-plan"; then
  pass "stages 1–3 markers present after rejection"
else
  fail "stages 1–3 markers incomplete"
fi

# review-gate.done must NOT exist (user aborted, no apply).
if [ ! -f "$INFERRED_DIR/state/review-gate.done" ]; then
  pass "state/review-gate.done absent (correct — no apply on abort)"
else
  fail "state/review-gate.done present (wrong — should not exist on abort)"
fi

# approved-import-plan.md must NOT exist.
if [ ! -s "$INFERRED_DIR/approved-import-plan.md" ]; then
  pass "approved-import-plan.md absent on abort"
else
  fail "approved-import-plan.md unexpectedly present after abort"
fi

# Log: review-gate record exit_code=1.
LOG="$INFERRED_DIR/orchestrate-log.jsonl"
RG_REC=$(jq -c 'select(.stage=="review-gate")' < "$LOG" | tail -1)
RG_EC=$(printf '%s' "$RG_REC" | jq -r '.exit_code')
if [ "$RG_EC" = "1" ]; then
  pass "review-gate log exit_code=1 (user abort recorded)"
else
  fail "review-gate log exit_code=$RG_EC (expected 1)"
fi

# import-plan.md exists (stage 3 ran successfully before user aborted).
if [ -s "$INFERRED_DIR/import-plan.md" ]; then
  pass "import-plan.md present (stage 3 ran before abort)"
else
  fail "import-plan.md missing"
fi

emit_summary_and_exit
