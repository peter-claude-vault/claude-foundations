#!/usr/bin/env bash
# tests/greenfield-pipeline/section-f-flag-skip-content.sh — SP16 T-2 flag honoring.
#
# Verifies --skip-content-seeding:
#   - 7 surface invocations + 7 markers (auto-author still runs)
#   - Orchestrator NOT invoked even with SEED_CONTENT_PATH set
#
# Hermetic per `feedback_test_isolation_for_hooks_state`.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_LABEL="T-2 section-f --skip-content-seeding"

# shellcheck disable=SC1090
. "$REPO_ROOT/tests/greenfield-pipeline/_lib/section-f-fixture.sh"

make_sandbox "flag-skip-content"

# Set SEED_CONTENT_PATH to prove --skip-content-seeding takes precedence.
IR_PATH="$TEST_DIR/ir.jsonl"
emit_synthetic_ir "$IR_PATH"
export SEED_CONTENT_PATH="$IR_PATH"

OUT1="$TEST_DIR/run-1.out"
ERR1="$TEST_DIR/run-1.err"
invoke_section_f --skip-content-seeding >"$OUT1" 2>"$ERR1"
RC1=$?

if [ "$RC1" = "0" ]; then
  pass "section F rc=0 with --skip-content-seeding"
else
  fail "section F rc=$RC1 (expected 0)"
  tail -40 "$ERR1" >&2
  emit_summary_and_exit
fi

# 7 surface markers.
if assert_surface_markers "$SECTION_F_STATE_DIR" "1,2,3,4,5,6,9"; then
  pass "all 7 surface done-markers written"
else
  fail "one or more surface done-markers missing"
fi

# 7 surface log records.
LOG_LINES=$(wc -l < "$AUTO_AUTHOR_LOG" | tr -d ' ')
if [ "$LOG_LINES" = "7" ]; then
  pass "auto-author-log.jsonl has 7 records"
else
  fail "auto-author-log.jsonl has $LOG_LINES records (expected 7)"
fi

# Skip-message in stderr.
if grep -q 'content-seeding orchestrator SKIPPED via --skip-content-seeding' "$ERR1"; then
  pass "skip-message logged"
else
  fail "skip-message NOT logged"
fi

# Orchestrator must NOT have run.
if grep -q 'Section F orchestrator — RUN' "$ERR1"; then
  fail "orchestrator ran despite --skip-content-seeding"
else
  pass "orchestrator did NOT run"
fi

# Orchestrator artifacts must NOT exist.
INFERRED_DIR="$CLAUDE_HOME/projects/t2test/inferred"
if [ -e "$INFERRED_DIR/cluster-output.json" ] || [ -e "$INFERRED_DIR/orchestrate-log.jsonl" ]; then
  fail "orchestrator artifacts present despite --skip-content-seeding"
else
  pass "no orchestrator artifacts (clean skip)"
fi

emit_summary_and_exit
