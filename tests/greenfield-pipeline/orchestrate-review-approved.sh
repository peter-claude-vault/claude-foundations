#!/usr/bin/env bash
# tests/greenfield-pipeline/orchestrate-review-approved.sh — SP16 T-1 acceptance:
# explicit user-approve at review gate.
#
# Variant of the green test where the user actively chooses [a]pply via
# REVIEW_GATE_PROMPT_CHOICE=a (rather than defaulting on EOF). Confirms
# orchestrate.sh forwards env to review-gate.sh and acts on rc=0 +
# approved-plan-present by writing the review-gate.done marker.
#
# Author: Plan 71 SP16 Session 1 (T-1).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_LABEL="T-1 orchestrate review-approved"

# shellcheck disable=SC1090
. "$REPO_ROOT/tests/greenfield-pipeline/_lib/orchestrate-fixture.sh"

make_sandbox "review-approved"

OUT1="$TEST_DIR/run.out"
ERR1="$TEST_DIR/run.err"
REVIEW_GATE_PROMPT_CHOICE=a \
REVIEW_GATE_ACCEPT_ON_EOF=1 \
  invoke_orchestrate_stub "review-approved" </dev/null >"$OUT1" 2>"$ERR1"
RC=$?

if [ "$RC" = "0" ]; then
  pass "rc=0 (apply via REVIEW_GATE_PROMPT_CHOICE=a)"
else
  fail "rc=$RC (expected 0 on apply)"
  tail -40 "$ERR1" >&2
  emit_summary_and_exit
fi

# approved-import-plan.md must exist and be non-empty.
if [ -s "$INFERRED_DIR/approved-import-plan.md" ]; then
  pass "approved-import-plan.md written"
else
  fail "approved-import-plan.md missing or empty"
fi

# Schema-version round-trip preserved (import-plan/1).
if grep -q '^schema_version: import-plan/1$' "$INFERRED_DIR/approved-import-plan.md" 2>/dev/null; then
  pass "approved plan preserves schema_version: import-plan/1"
else
  fail "approved plan missing schema_version: import-plan/1"
fi

# review-gate.done marker written, review-pending.flag absent.
if [ -f "$INFERRED_DIR/state/review-gate.done" ]; then
  pass "state/review-gate.done marker present"
else
  fail "state/review-gate.done marker missing"
fi
if [ ! -f "$INFERRED_DIR/state/review-pending.flag" ]; then
  pass "review-pending.flag absent (clean approval)"
else
  fail "review-pending.flag unexpectedly present"
fi

# Done-marker has the documented schema: <stage>\t<timestamp>\t<evidence>.
M_CONTENT=$(head -n1 "$INFERRED_DIR/state/review-gate.done")
case "$M_CONTENT" in
  review-gate"	"*"	"*"approved-import-plan.md")
    pass "review-gate.done marker schema valid (<stage>\\t<ts>\\t<approved-path>)"
    ;;
  *)
    fail "review-gate.done marker schema mismatch: $M_CONTENT"
    ;;
esac

# Log: review-gate record exit_code=0, evidence_path = approved plan.
LOG="$INFERRED_DIR/orchestrate-log.jsonl"
RG_REC=$(jq -c 'select(.stage=="review-gate")' < "$LOG" | tail -1)
RG_EC=$(printf '%s' "$RG_REC" | jq -r '.exit_code')
if [ "$RG_EC" = "0" ]; then
  pass "review-gate log exit_code=0"
else
  fail "review-gate log exit_code=$RG_EC (expected 0)"
fi

emit_summary_and_exit
