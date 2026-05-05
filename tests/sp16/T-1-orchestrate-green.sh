#!/usr/bin/env bash
# tests/sp16/T-1-orchestrate-green.sh — SP16 T-1 acceptance: green path.
#
# End-to-end stub-mode chain through all 4 stages with the user defaulting to
# [a]pply at review-gate. Verifies orchestrate.sh:
#   - chains the 4 wrapped scripts in declared order
#   - emits one orchestrate-log.jsonl record per stage with the required shape
#   - writes per-stage state/<stage>.done markers
#   - produces approved-import-plan.md after stage 4
#   - second invocation is idempotent (skips all stages)
#
# Hermetic per `feedback_test_isolation_for_hooks_state`: $TMPDIR sandbox,
# HOOKS_STATE_OVERRIDE + CLAUDE_HOME redirected. Stub-mode forces ANTHROPIC /
# VOYAGE keys unset.
#
# Author: Plan 71 SP16 Session 1 (T-1).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_LABEL="T-1 orchestrate green"

# shellcheck disable=SC1090
. "$REPO_ROOT/tests/sp16/_lib/orchestrate-fixture.sh"

make_sandbox "green"

# --- 1st invocation: full chain runs ---
# Auto-default review choice = [a]pply (REVIEW_GATE_ACCEPT_ON_EOF=1 + stdin EOF).

OUT1="$TEST_DIR/run-1.out"
ERR1="$TEST_DIR/run-1.err"
REVIEW_GATE_ACCEPT_ON_EOF=1 \
  invoke_orchestrate_stub "green" </dev/null >"$OUT1" 2>"$ERR1"
RC1=$?

if [ "$RC1" = "0" ]; then
  pass "1st invocation rc=0 (full chain green)"
else
  fail "1st invocation rc=$RC1 (expected 0)"
  tail -40 "$ERR1" >&2
  emit_summary_and_exit
fi

# Per-stage artifacts present.
for art in cluster-output.json propose-taxonomy-output.json import-plan.md approved-import-plan.md; do
  if [ -s "$INFERRED_DIR/$art" ]; then
    pass "artifact present: $art"
  else
    fail "artifact missing or empty: $INFERRED_DIR/$art"
  fi
done

# All 4 done-markers written.
if assert_markers_exist "$INFERRED_DIR" "cluster,propose-taxonomy,import-plan,review-gate"; then
  pass "all 4 done-markers written"
else
  fail "one or more done-markers missing"
fi

# orchestrate-log.jsonl has the right shape per stage.
LOG="$INFERRED_DIR/orchestrate-log.jsonl"
if [ ! -s "$LOG" ]; then
  fail "orchestrate-log.jsonl missing or empty"
  emit_summary_and_exit
fi

for st in cluster propose-taxonomy import-plan review-gate; do
  if assert_log_record_shape "$LOG" "$st"; then
    pass "log record shape ok: $st"
  else
    fail "log record shape mismatch or missing: $st"
  fi
done

# review-gate log record has exit_code 0 and evidence_path = approved-import-plan.md.
RG_LAST=$(jq -c 'select(.stage=="review-gate")' < "$LOG" | tail -1)
RG_EC=$(printf '%s' "$RG_LAST" | jq -r '.exit_code')
RG_EV=$(printf '%s' "$RG_LAST" | jq -r '.evidence_path')
if [ "$RG_EC" = "0" ] && [ "$RG_EV" = "$INFERRED_DIR/approved-import-plan.md" ]; then
  pass "review-gate log record: exit_code=0, evidence_path → approved plan"
else
  fail "review-gate log record mismatch (exit_code=$RG_EC evidence=$RG_EV)"
fi

# review-pending.flag must NOT exist after green run.
if [ -f "$INFERRED_DIR/state/review-pending.flag" ]; then
  fail "review-pending.flag present after green run (should be absent / cleared)"
else
  pass "review-pending.flag absent after green run"
fi

# --- 2nd invocation: idempotent skip-all ---

OUT2="$TEST_DIR/run-2.out"
ERR2="$TEST_DIR/run-2.err"
REVIEW_GATE_ACCEPT_ON_EOF=1 \
  invoke_orchestrate_stub "green" --resume </dev/null >"$OUT2" 2>"$ERR2"
RC2=$?

if [ "$RC2" = "0" ]; then
  pass "2nd invocation rc=0 (idempotent)"
else
  fail "2nd invocation rc=$RC2"
  tail -20 "$ERR2" >&2
fi

# Confirm 2nd invocation skipped all 4 stages (look for SKIP markers in stderr).
SKIP_COUNT=$(grep -c '— SKIP (marker exists)' "$ERR2" 2>/dev/null || echo 0)
SKIP_COUNT=$(printf '%s' "$SKIP_COUNT" | tr -d ' \n')
if [ "$SKIP_COUNT" = "4" ]; then
  pass "2nd invocation skipped all 4 stages"
else
  fail "2nd invocation SKIP count = $SKIP_COUNT (expected 4)"
  grep -E 'SKIP|RUN' "$ERR2" >&2 || true
fi

# orchestrate-log.jsonl now has 8 records (2 invocations × 4 stages).
LOG_LINES=$(wc -l < "$LOG" | tr -d ' ')
if [ "$LOG_LINES" = "8" ]; then
  pass "orchestrate-log.jsonl has 8 records (2 invocations × 4 stages)"
else
  fail "orchestrate-log.jsonl has $LOG_LINES records (expected 8)"
fi

emit_summary_and_exit
