#!/usr/bin/env bash
# tests/sp14-hooks-preasq-dqp-substantive-fires.sh
#
# SP14 T-18 fixture — pre-asq-guard.sh decision_quality_branch().
# Permutation: HAPPY/FIRES (substantive option set → DQP nudge composed in
# additionalContext + telemetry row appended).
#
# Contract under test (per spec.md §1 + alignment Session 6 L-83):
#   AskUserQuestion JSON with substantive option set (≥2 options each with
#   description > 50 chars OR keyword in question text) and NO
#   `research_complete:` annotation → composer emits a DQP fragment in
#   additionalContext + writes JSONL row to $DQ_EVENTS_PATH. Decision is
#   "allow" in Phase 1 (default).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] pre-asq-guard DQP — substantive option set (fires)\n'

# 4-option strategic choice with long descriptions → substantive shape.
questions_json='[
  {
    "question": "Which strategic approach should we pursue for the migration?",
    "options": [
      {"label": "A: Lift-and-shift", "description": "Move the existing system as-is to the new platform with minimal changes — fastest but carries forward all tech debt."},
      {"label": "B: Strangler-fig refactor", "description": "Build new alongside old; redirect traffic feature-by-feature. Lower risk but longer schedule, requires coordination."},
      {"label": "C: Full rewrite", "description": "Reauthor from scratch using the new-platform idioms. Maximum cleanliness, maximum schedule risk."},
      {"label": "D: Hybrid bridge", "description": "Lift-and-shift the core, rewrite the edges. Compromise on both axes but no clear win."}
    ]
  }
]'

payload=$(build_askuserquestion_payload "$questions_json")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-asq-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0" 0 "$rc"
assert_contains "additionalContext carries DQP marker" "$out" "Decision-Quality Protocol"
assert_contains "DQP cites Plan 83 SP01/SP05" "$out" "Plan 83 SP01"
assert_contains "4-element pass enumerated" "$out" "4-element research pass"
assert_contains "permissionDecision is allow" "$out" "\"permissionDecision\": \"allow\""

# Telemetry row written.
if [ -f "$DQ_EVENTS_PATH" ]; then
  emit_pass "DQ telemetry row appended to DQ_EVENTS_PATH"
  row_decision=$(tail -1 "$DQ_EVENTS_PATH" | jq -r '.decision' 2>/dev/null)
  if [ "$row_decision" = "nudge" ]; then
    emit_pass "telemetry decision = nudge"
  else
    emit_fail "telemetry decision: expected nudge, got $row_decision"
  fi
  row_substantive=$(tail -1 "$DQ_EVENTS_PATH" | jq -r '.substantive_shape_detected' 2>/dev/null)
  if [ "$row_substantive" = "true" ]; then
    emit_pass "telemetry substantive_shape_detected = true"
  else
    emit_fail "telemetry substantive_shape_detected: expected true, got $row_substantive"
  fi
else
  emit_fail "DQ telemetry file not created at $DQ_EVENTS_PATH"
fi

# Hard-constraints fragment co-fires on substantive option sets.
assert_contains "HC fragment co-composed with DQP" "$out" "Hard Constraints Override Spec Text"

fixture_summary
