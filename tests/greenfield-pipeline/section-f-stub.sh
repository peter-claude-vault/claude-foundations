#!/usr/bin/env bash
# tests/greenfield-pipeline/section-f-stub.sh — SP16 T-2 acceptance: canonical stub case.
#
# Verifies run_section_f orchestration logic against synthetic stub surfaces:
#   - Invokes 7 surfaces (1, 2, 3, 4, 5, 6, 9) in declared order
#   - Writes 7 done-markers under section-f-state/
#   - Produces exactly 7 records in auto-author-log.jsonl
#   - Idempotent on re-run (second invocation skips all 7)
#   - With no SEED_CONTENT_PATH, content-seeding orchestrator is skipped
#
# Hermetic per `feedback_test_isolation_for_hooks_state`. Stub-mode forces
# ANTHROPIC / VOYAGE keys unset.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_LABEL="T-2 section-f stub"

# shellcheck disable=SC1090
. "$REPO_ROOT/tests/greenfield-pipeline/_lib/section-f-fixture.sh"

make_sandbox "stub"

# --- 1st invocation: 7 surfaces run, no orchestrator ---

OUT1="$TEST_DIR/run-1.out"
ERR1="$TEST_DIR/run-1.err"
invoke_section_f >"$OUT1" 2>"$ERR1"
RC1=$?

if [ "$RC1" = "0" ]; then
  pass "1st invocation rc=0"
else
  fail "1st invocation rc=$RC1 (expected 0)"
  tail -40 "$ERR1" >&2
  emit_summary_and_exit
fi

# 7 done-markers present.
if assert_surface_markers "$SECTION_F_STATE_DIR" "1,2,3,4,5,6,9"; then
  pass "all 7 surface done-markers written"
else
  fail "one or more surface done-markers missing"
fi

# auto-author-log.jsonl has exactly 7 records.
LOG_LINES=$(wc -l < "$AUTO_AUTHOR_LOG" | tr -d ' ')
if [ "$LOG_LINES" = "7" ]; then
  pass "auto-author-log.jsonl has exactly 7 records"
else
  fail "auto-author-log.jsonl has $LOG_LINES records (expected 7)"
fi

# Each record has shape {ts, surface_id, action} and surface_id covers 1,2,3,4,5,6,9.
if jq -se 'all(.[]; has("ts") and has("surface_id") and has("action"))' < "$AUTO_AUTHOR_LOG" >/dev/null 2>&1; then
  pass "all log records have required shape"
else
  fail "log records missing required keys"
fi

EXPECTED="surface-1
surface-2
surface-3
surface-4
surface-5
surface-6
surface-9"
ACTUAL=$(jq -r '.surface_id' < "$AUTO_AUTHOR_LOG" | sort)
if [ "$ACTUAL" = "$EXPECTED" ]; then
  pass "log records cover all 7 declared surfaces"
else
  fail "log records surface_id mismatch (got: $ACTUAL)"
fi

# Order assertion: stderr log should mention surface-1 before surface-2 etc.
ORDER_OK=1
PREV_POS=0
for n in 1 2 3 4 5 6 9; do
  POS=$(grep -n "surface-${n} — RUN" "$ERR1" | head -1 | cut -d: -f1)
  if [ -z "$POS" ]; then ORDER_OK=0; break; fi
  if [ "$POS" -le "$PREV_POS" ]; then ORDER_OK=0; break; fi
  PREV_POS="$POS"
done
if [ "$ORDER_OK" = "1" ]; then
  pass "surfaces invoked in declared order (1,2,3,4,5,6,9)"
else
  fail "surfaces NOT in declared order — see $ERR1"
fi

# Orchestrator should NOT have run (no SEED_CONTENT_PATH).
if grep -q "Section F orchestrator — RUN" "$ERR1" 2>/dev/null; then
  fail "orchestrator ran despite no SEED_CONTENT_PATH"
else
  pass "orchestrator skipped (no SEED_CONTENT_PATH)"
fi

# --- 2nd invocation: idempotent skip-all ---

OUT2="$TEST_DIR/run-2.out"
ERR2="$TEST_DIR/run-2.err"
invoke_section_f >"$OUT2" 2>"$ERR2"
RC2=$?

if [ "$RC2" = "0" ]; then
  pass "2nd invocation rc=0 (idempotent)"
else
  fail "2nd invocation rc=$RC2"
  tail -20 "$ERR2" >&2
fi

# 2nd invocation should report SKIP for each surface.
SKIP_COUNT=$(grep -c 'Section F surface-.* — SKIP (marker exists)' "$ERR2" 2>/dev/null || echo 0)
SKIP_COUNT=$(printf '%s' "$SKIP_COUNT" | tr -d ' \n')
if [ "$SKIP_COUNT" = "7" ]; then
  pass "2nd invocation skipped all 7 surfaces"
else
  fail "2nd invocation SKIP count = $SKIP_COUNT (expected 7)"
fi

# Log line count unchanged (still 7) since stubs were not re-invoked.
LOG_LINES2=$(wc -l < "$AUTO_AUTHOR_LOG" | tr -d ' ')
if [ "$LOG_LINES2" = "7" ]; then
  pass "auto-author-log.jsonl still has 7 records after re-run"
else
  fail "auto-author-log.jsonl has $LOG_LINES2 records after re-run (expected 7)"
fi

emit_summary_and_exit
