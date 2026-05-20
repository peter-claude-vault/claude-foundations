#!/usr/bin/env bash
# tests/sp14-hooks-preasq-dqp-trivial-silent.sh
#
# SP14 T-18 fixture — pre-asq-guard.sh decision_quality_branch().
# Permutation: SKIP (trivial yes/no question → no DQP fragment + decision
# allow + telemetry row written but with substantive_shape_detected=false).
#
# Contract under test (per spec.md §1):
#   Yes/no canonical labels → yesno_shape=True, substantive=False.
#   Single-option confirmations → options_count<2, substantive=False.
#   In both cases composer emits NO DQP fragment.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] pre-asq-guard DQP — trivial yes/no (silent)\n'

# Yes/no canonical-label question (skipped by yesno detection).
questions_json='[
  {
    "question": "Proceed with the cleanup?",
    "options": [
      {"label": "yes", "description": "go"},
      {"label": "no", "description": "stop"}
    ]
  }
]'

payload=$(build_askuserquestion_payload "$questions_json")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-asq-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0" 0 "$rc"
# DQP fragment must NOT appear.
assert_not_contains "no DQP nudge for yes/no" "$out" "Decision-Quality Protocol"
assert_not_contains "no HC fragment for yes/no" "$out" "Hard Constraints Override"

# Telemetry row IS written even for non-fires (per L-83 SP05 telemetry every
# AskUserQuestion). decision should be "allow"; substantive_shape_detected
# should be false.
if [ -f "$DQ_EVENTS_PATH" ]; then
  emit_pass "telemetry row appended for trivial question"
  row_decision=$(tail -1 "$DQ_EVENTS_PATH" | jq -r '.decision' 2>/dev/null)
  if [ "$row_decision" = "allow" ]; then
    emit_pass "telemetry decision = allow"
  else
    emit_fail "telemetry decision: expected allow, got $row_decision"
  fi
  row_substantive=$(tail -1 "$DQ_EVENTS_PATH" | jq -r '.substantive_shape_detected' 2>/dev/null)
  if [ "$row_substantive" = "false" ]; then
    emit_pass "telemetry substantive_shape_detected = false"
  else
    emit_fail "telemetry substantive_shape_detected: expected false, got $row_substantive"
  fi
  row_yesno=$(tail -1 "$DQ_EVENTS_PATH" | jq -r '.yesno_shape' 2>/dev/null)
  if [ "$row_yesno" = "true" ]; then
    emit_pass "telemetry yesno_shape = true"
  else
    emit_fail "telemetry yesno_shape: expected true, got $row_yesno"
  fi
else
  emit_fail "DQ telemetry file not created"
fi

fixture_summary
