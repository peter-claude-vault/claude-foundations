#!/usr/bin/env bash
# tests/sp14-hooks-preasq-hc-trivial-silent.sh
#
# SP14 T-18 fixture — pre-asq-guard.sh hard_constraints_branch().
# Permutation: SKIP (trivial single-option confirmation → no HC fragment).
#
# Contract under test:
#   Single-option AskUserQuestion (clarification/confirmation pattern) is
#   non-substantive — HC fragment must NOT fire.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] pre-asq-guard HC — single-option confirmation (silent)\n'

# Single-option confirm pattern — must avoid KEYWORDS regex
# (approach|option|path|strategy|direction|which way|should we). Use a
# bland clarification question with no keywords + single option.
questions_json='[
  {
    "question": "Use the filename you mentioned earlier?",
    "options": [
      {"label": "Confirm", "description": "ack"}
    ]
  }
]'

payload=$(build_askuserquestion_payload "$questions_json")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-asq-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0" 0 "$rc"
assert_not_contains "no HC fragment for single-option" "$out" "Hard Constraints Override Spec Text"
assert_not_contains "no DQP fragment for single-option" "$out" "Decision-Quality Protocol"

# Telemetry row records this as not-substantive.
if [ -f "$DQ_EVENTS_PATH" ]; then
  emit_pass "telemetry row appended"
  row_substantive=$(tail -1 "$DQ_EVENTS_PATH" | jq -r '.substantive_shape_detected' 2>/dev/null)
  if [ "$row_substantive" = "false" ]; then
    emit_pass "telemetry substantive_shape_detected = false"
  else
    emit_fail "telemetry substantive_shape_detected: expected false, got $row_substantive"
  fi
else
  emit_fail "DQ telemetry file not created"
fi

fixture_summary
