#!/usr/bin/env bash
# tests/sp16/T-2-section-f-flag-subset.sh — SP16 T-2 subset surface dispatch.
#
# Verifies --auto-author-only-surfaces=<csv>:
#   - Only the named surfaces invoked (subset of {1,2,3,4,5,6,9})
#   - Done-markers + log records match the subset cardinality + identity
#   - Surfaces outside the subset have no markers / no records
#
# Hermetic per `feedback_test_isolation_for_hooks_state`.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_LABEL="T-2 section-f --auto-author-only-surfaces=1,3,9"

# shellcheck disable=SC1090
. "$REPO_ROOT/tests/sp16/_lib/section-f-fixture.sh"

make_sandbox "flag-subset"

OUT1="$TEST_DIR/run-1.out"
ERR1="$TEST_DIR/run-1.err"
invoke_section_f --auto-author-only-surfaces=1,3,9 >"$OUT1" 2>"$ERR1"
RC1=$?

if [ "$RC1" = "0" ]; then
  pass "section F rc=0 with --auto-author-only-surfaces=1,3,9"
else
  fail "section F rc=$RC1 (expected 0)"
  tail -40 "$ERR1" >&2
  emit_summary_and_exit
fi

# Subset markers present.
if assert_surface_markers "$SECTION_F_STATE_DIR" "1,3,9"; then
  pass "subset markers (1,3,9) all written"
else
  fail "one or more subset markers missing"
fi

# Surfaces outside the subset have no markers.
EXTRA_HITS=0
for n in 2 4 5 6; do
  if [ -f "$SECTION_F_STATE_DIR/surface-${n}.done" ]; then
    EXTRA_HITS=$((EXTRA_HITS + 1))
    printf '  unexpected marker: surface-%s.done\n' "$n" >&2
  fi
done
if [ "$EXTRA_HITS" = "0" ]; then
  pass "no markers for surfaces outside subset"
else
  fail "$EXTRA_HITS unexpected markers found"
fi

# auto-author-log.jsonl has exactly 3 records.
LOG_LINES=$(wc -l < "$AUTO_AUTHOR_LOG" | tr -d ' ')
if [ "$LOG_LINES" = "3" ]; then
  pass "auto-author-log.jsonl has exactly 3 records"
else
  fail "auto-author-log.jsonl has $LOG_LINES records (expected 3)"
fi

# Identity of records matches subset.
EXPECTED="surface-1
surface-3
surface-9"
ACTUAL=$(jq -r '.surface_id' < "$AUTO_AUTHOR_LOG" | sort)
if [ "$ACTUAL" = "$EXPECTED" ]; then
  pass "log record surface_ids = {1, 3, 9}"
else
  fail "log record surface_ids mismatch (got: $ACTUAL)"
fi

# Order assertion within subset (1 before 3 before 9 in stderr RUN log).
POS_1=$(grep -n 'surface-1 — RUN' "$ERR1" | head -1 | cut -d: -f1)
POS_3=$(grep -n 'surface-3 — RUN' "$ERR1" | head -1 | cut -d: -f1)
POS_9=$(grep -n 'surface-9 — RUN' "$ERR1" | head -1 | cut -d: -f1)
if [ -n "$POS_1" ] && [ -n "$POS_3" ] && [ -n "$POS_9" ] \
   && [ "$POS_1" -lt "$POS_3" ] && [ "$POS_3" -lt "$POS_9" ]; then
  pass "subset surfaces invoked in declared order (1, 3, 9)"
else
  fail "subset NOT in declared order (POS_1=$POS_1 POS_3=$POS_3 POS_9=$POS_9)"
fi

emit_summary_and_exit
