#!/usr/bin/env bash
# tests/greenfield-pipeline/section-f-flag-skip-auto-author.sh — SP16 T-2 flag honoring.
#
# Verifies --skip-auto-author:
#   - Zero surface invocations (no markers, no log records)
#   - Content-seeding orchestrator still runs when SEED_CONTENT_PATH is set
#
# Hermetic per `feedback_test_isolation_for_hooks_state`.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_LABEL="T-2 section-f --skip-auto-author"

# shellcheck disable=SC1090
. "$REPO_ROOT/tests/greenfield-pipeline/_lib/section-f-fixture.sh"

make_sandbox "flag-skip-auto-author"

# Provide a seed-content IR so the orchestrator runs (proves --skip-auto-author
# is scoped to surfaces only, not the whole section).
IR_PATH="$TEST_DIR/ir.jsonl"
emit_synthetic_ir "$IR_PATH"
export SEED_CONTENT_PATH="$IR_PATH"
export REVIEW_GATE_ACCEPT_ON_EOF=1

OUT1="$TEST_DIR/run-1.out"
ERR1="$TEST_DIR/run-1.err"
invoke_section_f --skip-auto-author >"$OUT1" 2>"$ERR1"
RC1=$?

if [ "$RC1" = "0" ]; then
  pass "section F rc=0 with --skip-auto-author"
else
  fail "section F rc=$RC1 (expected 0)"
  tail -40 "$ERR1" >&2
  emit_summary_and_exit
fi

# Zero surface markers.
if assert_no_surface_markers "$SECTION_F_STATE_DIR"; then
  pass "no surface done-markers written"
else
  fail "surface markers exist despite --skip-auto-author"
  ls -la "$SECTION_F_STATE_DIR" 2>&1 >&2
fi

# Zero SURFACE log records (orchestrator's review-gate writes its own
# generate/preview/apply entries through the same audit log; we only assert
# that no surface-{1..6,9} entries exist).
SURFACE_LINES=$(jq -r 'select(.surface_id | test("^surface-[1-9]$")) | .surface_id' \
                  < "$AUTO_AUTHOR_LOG" 2>/dev/null | wc -l | tr -d ' ')
if [ "$SURFACE_LINES" = "0" ]; then
  pass "auto-author-log.jsonl has 0 surface records"
else
  fail "auto-author-log.jsonl has $SURFACE_LINES surface records (expected 0)"
fi

# Skip-message in stderr.
if grep -q 'auto-author surfaces SKIPPED via --skip-auto-author' "$ERR1"; then
  pass "skip-message logged"
else
  fail "skip-message NOT logged"
fi

# Orchestrator should have run (SEED_CONTENT_PATH set, --skip-content-seeding NOT set).
if grep -q 'Section F orchestrator — RUN' "$ERR1"; then
  pass "orchestrator ran (SEED_CONTENT_PATH set, content-seeding not skipped)"
else
  fail "orchestrator did NOT run despite SEED_CONTENT_PATH set"
fi

emit_summary_and_exit
