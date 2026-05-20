#!/usr/bin/env bash
# tests/sp14-hooks-preasq-hc-substantive-fires.sh
#
# SP14 T-18 fixture — pre-asq-guard.sh hard_constraints_branch() (line 187-229).
# Permutation: HAPPY/FIRES (substantive option set → HC fragment composed).
#
# Contract under test (per spec.md §1 + alignment Session 6 L-81+L-82):
#   AskUserQuestion with substantive option set fires the Hard-Constraints-
#   Override-Spec reminder fragment independently of the DQP annotation
#   state. HC is informational, never denies.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] pre-asq-guard HC — substantive option set (fires)\n'

# Use a keyword that triggers KEYWORDS regex ("approach"). HC heuristic
# matches the same substantive-shape detector logic.
questions_json='[
  {
    "question": "Which approach should we take to land the migration?",
    "options": [
      {"label": "A: Cutover weekend", "description": "Single big-bang switchover with a planned outage window; minimum coexistence cost."},
      {"label": "B: Phased dark launches", "description": "Run new and old in parallel; cut over feature-by-feature behind flags; double the operational cost during overlap."}
    ]
  }
]'

payload=$(build_askuserquestion_payload "$questions_json")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-asq-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0" 0 "$rc"
assert_contains "HC fragment marker present" "$out" "Hard Constraints Override Spec Text"
assert_contains "HC cites constraint posture" "$out" "no live mutations"
assert_contains "HC cites spec defective posture" "$out" "DEFECTIVE"
# DQP also fires (keyword present) — both fragments live in same allow.
assert_contains "DQP fragment also fires (keyword overlap)" "$out" "Decision-Quality Protocol"
assert_contains "permissionDecision is allow (HC never denies)" "$out" "\"permissionDecision\": \"allow\""

fixture_summary
