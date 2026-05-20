#!/usr/bin/env bash
# tests/sp14-hooks-branch2-happy-pastdate.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #2 historical-data-warning
# TZ-aware (line 881-939). Permutation: HAPPY (warning fires).
#
# Contract under test (per spec.md §1 + hook-branch-implementations.md
# L-74-L-77):
#   Meeting note named `YYYY-MM-DD - Title.md` matches per-type
#   `historical_data_warning_pattern` from governance/file-type-contracts/
#   meeting-note.md.json. When parsed_date < today (in America/New_York
#   per L-76 default), branch emits allow + additionalContext with
#   "Historical Data Warning" fragment. rc=0.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #2 — past-dated meeting note (warning fires)\n'

# Construct a past date deterministically (use today minus 30 days; bash 3.2
# compatible BSD-date variant on macOS).
past_date=$(date -v-30d +%F 2>/dev/null || date -d '30 days ago' +%F)

target="$VAULT_ROOT/Meetings/${past_date} - Standup.md"
mkdir -p "$(dirname "$target")"

content="---
type: meeting-note
title: Standup
date: ${past_date}
attendees:
  - Peter
---

# Notes
"

payload=$(build_write_payload "$target" "$content")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0 (allow + warn)" 0 "$rc"
assert_contains "additionalContext carries Branch #2 marker" "$out" "Historical Data Warning — SP14 Branch #2"
assert_contains "names the parsed past date" "$out" "$past_date"
assert_contains "cites meeting-note.md.json per-type pattern source" "$out" "file-type-contracts/meeting-note.md.json"

fixture_summary
