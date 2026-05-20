#!/usr/bin/env bash
# tests/sp14-hooks-branch2-scopemiss-no-pattern.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #2 historical-data-warning.
# Permutation: SCOPE-MISS (file-type has NO `historical_data_warning_pattern`
# AND falls back to pillar 7 universal default).
#
# Contract under test (line 925 — `[[ -z "$B2_PATTERN" ]] && B2_PATTERN="$B2_UNIVERSAL"`):
#   When file's `type:` has no per-type pattern in its file-type-contract,
#   the branch falls back to vault-writers-rules.json :: historical_data_warning_default
#   (`^\d{4}-\d{2}-\d{2}`). A file whose basename does NOT match that
#   regex → no warning fires. Source attribution cites
#   vault-writers-rules.json instead of the per-type contract.
#
# This fixture exercises a NON-date-prefixed basename → falls through
# silently.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #2 — no date prefix, no per-type pattern (scope-miss)\n'

# A non-date-prefixed file with a non-meeting type → no pattern matches.
target="$VAULT_ROOT/Meetings/random-no-date-prefix.md"
mkdir -p "$(dirname "$target")"

# Use type without per-type pattern (use "note" or "context" — both lack
# historical_data_warning_pattern in their contracts).
content="---
type: note
title: Random
---

body
"

payload=$(build_write_payload "$target" "$content")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0" 0 "$rc"
# Universal default `^\d{4}-\d{2}-\d{2}` does not match this basename.
assert_not_contains "Branch #2 warning NOT present (basename does not match universal regex)" "$out" "Historical Data Warning — SP14 Branch #2"

fixture_summary
