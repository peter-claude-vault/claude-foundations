#!/usr/bin/env bash
# tests/sp14-hooks-branch4-skip-non-librarian-path.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #4. Permutation: SKIP
# (env stamp set but path is NOT one of the 3 librarian-only files →
# Branch #4 has no effect; other branches govern).
#
# Contract under test:
#   The env-stamp CLAUDE_LIBRARIAN_WRITE=1 is path-scoped — it only
#   short-circuits the 3 librarian-only filenames at $HOME/.claude-plans/.
#   Writes to other paths with the stamp present must NOT be unconditionally
#   allowed (the stamp is not a bypass for the rest of the hook).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #4 — env stamp set but arbitrary path (skip)\n'

# Target: arbitrary vault path (not under $HOME/.claude-plans/).
target="$VAULT_ROOT/Meetings/some-note.md"
mkdir -p "$(dirname "$target")"

content="---
type: meeting-note
title: Some Note
date: 2026-05-20
attendees:
  - Peter
---

# Notes
"

# Stamp is set but should have no effect for this path.
payload=$(build_write_payload "$target" "$content")
out=$(printf '%s' "$payload" | CLAUDE_LIBRARIAN_WRITE=1 bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0" 0 "$rc"
# Branch #4 deny message must NOT appear (path not in Branch #4 scope).
assert_not_contains "Branch #4 deny NOT present for non-librarian path" "$out" "SP14 Branch #4"
# The stamp must NOT manifest as some unrelated bypass marker.
assert_not_contains "no librarian-only-bypass note for arbitrary path" "$out" "librarian-generated"

fixture_summary
