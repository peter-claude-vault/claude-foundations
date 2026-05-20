#!/usr/bin/env bash
# tests/sp14-hooks-branch2-skip-futuredate.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #2 historical-data-warning.
# Permutation: SKIP (future-dated file silent pass-through per L-77).
#
# Contract under test (line 931 — `[[ "$B2_PARSED_DATE" < "$B2_TODAY" ]]`):
#   File whose basename matches the date regex but parsed date is in the
#   future → no warning fragment, no deny. Hook proceeds silently through
#   Branch #2.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #2 — future-dated meeting note (silent skip / L-77)\n'

# 1 year in the future, deterministic.
future_date=$(date -v+365d +%F 2>/dev/null || date -d '+365 days' +%F)

target="$VAULT_ROOT/Meetings/${future_date} - Future Standup.md"
mkdir -p "$(dirname "$target")"

content="---
type: meeting-note
title: Future Standup
date: ${future_date}
attendees:
  - Peter
---

# Notes
"

payload=$(build_write_payload "$target" "$content")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0" 0 "$rc"
# Branch #2 warning fragment MUST NOT appear (future date).
assert_not_contains "Branch #2 warning fragment NOT present for future-dated file" "$out" "Historical Data Warning — SP14 Branch #2"

fixture_summary
