#!/usr/bin/env bash
# onboarding/connectors/beats/beat-1-role.sh — SP14 T-7 (Plan 71 SP14 Session 3a).
#
# Beat 1 of the connector wizard: ask the user one multi-choice question
# ("Consultant | Solo founder | Engineer | Researcher | Operator") and persist
# the choice to user-manifest.json#/connectors_meta/user_role. Drives Beat 2's
# pre-checked subset selection.
#
# OUTPUT CONTRACT (R-43):
#   Files written: $USER_MANIFEST (default: $CLAUDE_HOME/user-manifest.json) —
#                  jq-merge sets .connectors_meta.user_role + .connectors_meta.last_wizard_run
#   Schema-types: user-manifest-schema.json#/properties/connectors_meta
#                 (validated post-write via jq -e probe)
#   Pre-write validation: jq -e on input value against the role enum
#                 (consultant | solo-founder | engineer | researcher | operator)
#   Failure mode: BLOCK AND LOG. Invalid input re-prompts (interactive); rc=2
#                 on bad-invocation; rc=3 on user-manifest write failure.
#
# Usage:
#   bash beat-1-role.sh [--skip-role] [--input <role>] [--manifest <path>]
#
# Flags:
#   --skip-role        Bypass beat 1 cleanly (re-run scenario when role
#                      already set in manifest). rc=0; no manifest write.
#   --input <role>     Non-interactive mode: take the role from arg, validate,
#                      write to manifest, exit. Used by synthetic tests.
#   --manifest <path>  Override default user-manifest.json path. Default:
#                      $CLAUDE_HOME/user-manifest.json (or $HOME/.claude/...).
#
# Exit codes:
#   0  success (role written or --skip-role bypass)
#   2  bad invocation
#   3  manifest write failure
#
# Dependencies: bash 3.2, jq.

set -u

_diag() { printf 'beat-1-role FAIL: %s\n' "$1" >&2; }
_info() { printf 'beat-1-role: %s\n' "$1"; }

VALID_ROLES="consultant solo-founder engineer researcher operator"

skip_role=0
input_role=""
manifest_arg=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-role) skip_role=1; shift ;;
    --input)
      [ $# -lt 2 ] && { _diag "--input requires value"; exit 2; }
      input_role="$2"; shift 2 ;;
    --manifest)
      [ $# -lt 2 ] && { _diag "--manifest requires path"; exit 2; }
      manifest_arg="$2"; shift 2 ;;
    -*) _diag "unknown flag: $1"; exit 2 ;;
    *) _diag "unexpected positional: $1"; exit 2 ;;
  esac
done

USER_MANIFEST="${manifest_arg:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"

if [ "$skip_role" -eq 1 ]; then
  _info "skip-role flag set — bypassing Beat 1"
  exit 0
fi

is_valid_role() {
  local candidate="$1"
  local r
  for r in $VALID_ROLES; do
    if [ "$r" = "$candidate" ]; then return 0; fi
  done
  return 1
}

resolve_role_from_input() {
  local raw="$1"
  # Allow "1" through "5" as numeric shortcuts
  case "$raw" in
    1|consultant)   printf 'consultant'   ;;
    2|solo-founder|"solo founder") printf 'solo-founder' ;;
    3|engineer)     printf 'engineer'     ;;
    4|researcher)   printf 'researcher'   ;;
    5|operator)     printf 'operator'     ;;
    *) printf '%s' "$raw" ;;
  esac
}

prompt_role() {
  cat >&2 <<'PROMPT'

Connector Wizard — Beat 1 of 4
What kind of work does this vault primarily support? (Drives recommended-connector defaults; you can override later.)

  1) Consultant      — client engagements, meetings, multi-project rotation
  2) Solo founder    — building a thing solo; PM + eng + ops fused
  3) Engineer        — code-heavy; shipping software inside an org
  4) Researcher      — academic/industry research; deep reading + writing
  5) Operator        — running a team or function; ops + people management

PROMPT
  local raw resolved
  while true; do
    printf 'Pick (1-5 or name): ' >&2
    if ! IFS= read -r raw; then
      _diag "EOF on stdin without selection"
      exit 2
    fi
    raw=$(printf '%s' "$raw" | tr -d '[:space:]')
    [ -z "$raw" ] && continue
    resolved=$(resolve_role_from_input "$raw")
    if is_valid_role "$resolved"; then
      printf '%s' "$resolved"
      return 0
    fi
    printf 'Invalid: "%s". Try again.\n' "$raw" >&2
  done
}

# --- choose role ---
role=""
if [ -n "$input_role" ]; then
  role=$(resolve_role_from_input "$input_role")
  if ! is_valid_role "$role"; then
    _diag "--input value invalid: '$input_role' (allowed: $VALID_ROLES)"
    exit 2
  fi
else
  role=$(prompt_role)
fi

# --- persist to user-manifest.json ---
mkdir -p "$(dirname "$USER_MANIFEST")"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ -r "$USER_MANIFEST" ]; then
  base_json=$(cat "$USER_MANIFEST")
else
  base_json='{}'
fi

new_json=$(printf '%s' "$base_json" | jq \
  --arg role "$role" \
  --arg ts "$ts" \
  '
    .connectors_meta = ((.connectors_meta // {}) + {
      user_role: $role,
      last_wizard_run: $ts
    })
  ' 2>/dev/null) || {
  _diag "jq merge failed; manifest may be malformed: $USER_MANIFEST"
  exit 3
}

tmp="$USER_MANIFEST.tmp.$$"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$new_json" > "$tmp" || { _diag "tmp write failed: $tmp"; exit 3; }
mv -f "$tmp" "$USER_MANIFEST" || { _diag "atomic mv failed"; exit 3; }
trap - EXIT

_info "user_role set to '$role' (manifest: $USER_MANIFEST)"
exit 0
