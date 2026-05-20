#!/usr/bin/env bash
# tests/sp14-hooks-branch4-scopemiss-no-prefix-collision.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #4. Permutation:
# SCOPE-MISS (writes to other governance files in .claude-plans/ that
# are NOT one of the 3 librarian-only basenames pass through Branch #4
# entirely; R-27 or other branches govern).
#
# Contract under test (line 174-186 — case ... in _index.md|_backlog.md|_archive.md):
#   Only those 3 basenames inside $HOME/.claude-plans/ engage Branch #4.
#   A write to $HOME/.claude-plans/99-some-plan/spec.md is OUT of Branch
#   #4 scope (it lives in a subdirectory). A write to
#   $HOME/.claude-plans/some-other-file.md (NOT one of 3 protected
#   names) is also out of Branch #4 scope.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #4 — non-protected basename in .claude-plans/ (scope-miss)\n'

# Target: $PLANS_DIR/something-else.md (post-fix#3 honors $PLANS_DIR).
# Branch #4 only protects {_index, _backlog, _archive}.md. This basename
# is NOT in that set — Branch #4 does not fire.
target="$PLANS_DIR/some-other-file.md"
mkdir -p "$(dirname "$target")"

content="---
status: planned
---

# Some other file (not librarian-managed)
"

# Deliberately no stamp.
unset CLAUDE_LIBRARIAN_WRITE 2>/dev/null || true

payload=$(build_write_payload "$target" "$content")
# Capture both stdout and stderr to detect the documented unbound-variable bug.
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>&1)
rc=$?

# Substrate divergence FIXED in Batch J 2026-05-20 (T-33 fix #2):
#   pre-write-guard.sh now initializes PL_CONTENT="" at top of the plan-tree .md
#   block (immediately after the outer if-guard, before the case statement).
#   This fixture now anchors to the post-fix behavior: hook allows (rc=0), no
#   unbound-variable error, Branch #4 falls through cleanly (this basename is
#   not in the {_index,_backlog,_archive}.md protected set).

assert_rc "post-fix#2: hook completes cleanly (rc=0)" 0 "$rc"
assert_not_contains "post-fix#2: no PL_CONTENT unbound error" "$out" "PL_CONTENT: unbound variable"
# Branch #4 itself never gets to fire for this basename → no Branch #4 marker.
assert_not_contains "Branch #4 deny NOT present" "$out" "SP14 Branch #4"

fixture_summary
