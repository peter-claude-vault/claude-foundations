#!/usr/bin/env bash
# tests/sp14-hooks-branch4-violation-unstamped.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #4 plans-tree librarian-
# generated file write. Permutation: VIOLATION (unstamped write denied).
#
# Contract under test:
#   Write to $PLANS_DIR/_backlog.md without CLAUDE_LIBRARIAN_WRITE=1 →
#   DENY with reason citing Branch #4 + L-78-L-80 source.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #4 — unstamped write to plans-tree (violation/deny)\n'

# Post-fix#3 (T-33 2026-05-20): substrate line 172 now honors $PLANS_DIR
# (`B4_PT_PARENT="${PLANS_DIR:-$HOME/.claude-plans}"`). Setup helper exports
# PLANS_DIR="$TEMPROOT/plans" so the librarian-files target lives there.
target="$PLANS_DIR/_backlog.md"
mkdir -p "$(dirname "$target")"

content="# System Backlog

(should-be-librarian-generated)
"

# Deliberately NOT setting CLAUDE_LIBRARIAN_WRITE.
unset CLAUDE_LIBRARIAN_WRITE 2>/dev/null || true

payload=$(build_write_payload "$target" "$content")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0 (deny via JSON not rc)" 0 "$rc"
assert_contains "Branch #4 deny marker present" "$out" "SP14 Branch #4"
assert_contains "librarian-generated path constraint cited" "$out" "librarian-generated"
assert_contains "names CLAUDE_LIBRARIAN_WRITE env-var" "$out" "CLAUDE_LIBRARIAN_WRITE"
assert_contains "permissionDecision is deny" "$out" "\"permissionDecision\": \"deny\""

fixture_summary
