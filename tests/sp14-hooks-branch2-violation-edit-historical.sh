#!/usr/bin/env bash
# tests/sp14-hooks-branch2-violation-edit-historical.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #2 historical-data-warning,
# Edit-op path (line 913-914). Permutation: VIOLATION (Edit on past-dated
# meeting note fires the warning).
#
# Contract under test:
#   The Edit branch reads file content from disk (TOOL_NAME==Edit) instead
#   of from tool_input.content. Same downstream date-parse + comparison
#   produces the warning fragment.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #2 — Edit on past-dated meeting note (violation/warn)\n'

past_date=$(date -v-15d +%F 2>/dev/null || date -d '15 days ago' +%F)

target="$VAULT_ROOT/Meetings/${past_date} - Existing Standup.md"
mkdir -p "$(dirname "$target")"
# Pre-seed file on disk so Edit branch reads content from it.
cat > "$target" <<EOF
---
type: meeting-note
title: Existing Standup
date: $past_date
attendees:
  - Peter
---

# Notes

Old content line.
EOF

payload=$(build_edit_payload "$target" "Old content line." "Updated content line.")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0 (allow + warn on Edit)" 0 "$rc"
assert_contains "Edit-op path also fires Branch #2 warning" "$out" "Historical Data Warning — SP14 Branch #2"
assert_contains "names the past date" "$out" "$past_date"

fixture_summary
