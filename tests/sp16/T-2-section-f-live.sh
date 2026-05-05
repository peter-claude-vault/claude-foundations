#!/usr/bin/env bash
# tests/sp16/T-2-section-f-live.sh — SP16 T-2 acceptance: greenfield path with
# real orchestrator chain.
#
# Verifies run_section_f end-to-end:
#   - Stub-surface dispatch produces 7 surface markers + 7 records
#   - SEED_CONTENT_PATH set → real orchestrate.sh from T-1 invokes the 4-stage
#     SP13 chain (cluster → propose-taxonomy → import-plan → review-gate)
#   - REVIEW_GATE_ACCEPT_ON_EOF defaults applied on non-TTY stdin so
#     review-gate doesn't block (T-1 carry-forward)
#   - orchestrate-log.jsonl shows all 4 stages green
#   - approved-import-plan.md present
#
# Hermetic per `feedback_test_isolation_for_hooks_state`. Stub-mode for LLM
# (no API keys); real orchestrate.sh + 4 wrapped scripts.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_LABEL="T-2 section-f live"

# shellcheck disable=SC1090
. "$REPO_ROOT/tests/sp16/_lib/section-f-fixture.sh"

make_sandbox "live"

# Wire SEED_CONTENT_PATH to a synthetic IR fixture.
IR_PATH="$TEST_DIR/ir.jsonl"
emit_synthetic_ir "$IR_PATH"
export SEED_CONTENT_PATH="$IR_PATH"

# Force orchestrate.sh into stub-only modes so this test stays hermetic
# without API keys. Forwarded via env, picked up by orchestrate.sh's wrapped
# scripts via existing --llm-mode / --embedding-mode plumbing.
#
# Note: orchestrate.sh propagates these flags only via argv, not env. The
# existing onboard.sh Section F wiring passes neither — orchestrate.sh
# defaults to --llm-mode auto / --embedding-mode auto, and the wrapped
# scripts auto-detect stub mode when ANTHROPIC_API_KEY / VOYAGE_API_KEY are
# unset (which the sandbox already enforces).
export REVIEW_GATE_ACCEPT_ON_EOF=1

OUT1="$TEST_DIR/run-1.out"
ERR1="$TEST_DIR/run-1.err"
invoke_section_f >"$OUT1" 2>"$ERR1"
RC1=$?

if [ "$RC1" = "0" ]; then
  pass "section F rc=0"
else
  fail "section F rc=$RC1 (expected 0)"
  tail -80 "$ERR1" >&2
  emit_summary_and_exit
fi

# 7 surface markers.
if assert_surface_markers "$SECTION_F_STATE_DIR" "1,2,3,4,5,6,9"; then
  pass "all 7 surface done-markers written"
else
  fail "one or more surface done-markers missing"
fi

# 7 surface records (orchestrator's review-gate also writes generate/preview/
# apply records to the same audit log via three-step-gate; filter to records
# whose surface_id matches the SP12 surface-{1..6,9} pattern).
SURFACE_LINES=$(jq -r 'select(.surface_id | test("^surface-[1-9]$")) | .surface_id' \
                  < "$AUTO_AUTHOR_LOG" | wc -l | tr -d ' ')
if [ "$SURFACE_LINES" = "7" ]; then
  pass "auto-author-log.jsonl has 7 surface records (orchestrator extras allowed)"
else
  fail "auto-author-log.jsonl has $SURFACE_LINES surface records (expected 7)"
fi

# Orchestrator artifacts present.
INFERRED_DIR="$CLAUDE_HOME/projects/t2test/inferred"
for art in cluster-output.json propose-taxonomy-output.json import-plan.md approved-import-plan.md; do
  if [ -s "$INFERRED_DIR/$art" ]; then
    pass "orchestrator artifact present: $art"
  else
    fail "orchestrator artifact missing or empty: $INFERRED_DIR/$art"
  fi
done

# orchestrate-log.jsonl shows all 4 stages.
ORCH_LOG="$INFERRED_DIR/orchestrate-log.jsonl"
if [ ! -s "$ORCH_LOG" ]; then
  fail "orchestrate-log.jsonl missing or empty"
  emit_summary_and_exit
fi
for st in cluster propose-taxonomy import-plan review-gate; do
  if jq -se --arg s "$st" 'map(select(.stage == $s)) | length >= 1' < "$ORCH_LOG" >/dev/null 2>&1; then
    pass "orchestrate-log shows stage: $st"
  else
    fail "orchestrate-log missing stage: $st"
  fi
done

# review-pending.flag must NOT exist after green run.
if [ -f "$INFERRED_DIR/state/review-pending.flag" ]; then
  fail "review-pending.flag present after green run (should be absent)"
else
  pass "review-pending.flag absent after green run"
fi

emit_summary_and_exit
