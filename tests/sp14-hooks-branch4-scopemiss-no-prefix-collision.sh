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

# Target: $HOME/.claude-plans/something-else.md
# Branch #4 only protects {_index, _backlog, _archive}.md. This basename
# is NOT in that set — Branch #4 does not fire.
target="$HOME/.claude-plans/some-other-file.md"
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

# Substrate divergence finding (DOCUMENTED, NOT FIXED per fixture-only scope):
#   pre-write-guard.sh:457 references PL_CONTENT under `set -u` without first
#   initializing it. When PL_EXPECTED_TYPE is empty (basename not one of the 4
#   canonical plan-artifact filenames: spec.md / tasks.md / handoff.md /
#   00-ideation-brief.md), the line-411 init block is skipped, so line 457
#   hits "PL_CONTENT: unbound variable" → hook exits 1 with no JSON output.
#
# Real-world impact: ANY .md write under ~/.claude-plans/ whose basename is
# not in the 4-canonical set triggers this — including research notes,
# session logs, AND the very librarian-managed _index/_backlog/_archive files
# when CLAUDE_LIBRARIAN_WRITE=1 short-circuits Branch #4 (since the short-
# circuit exit 0 at line 184 happens BEFORE line 457). Confirmed via repro.
#
# Suggested fix: insert `PL_CONTENT=""` immediately after the outer if at
# line 400 (before the case ... in block).
#
# Until fix lands, this fixture asserts the substrate's CURRENT behavior
# (rc=1 + unbound-variable stderr message) so a regression is visible
# once authored fix lands.

assert_rc "current substrate exits 1 (PL_CONTENT unbound variable bug)" 1 "$rc"
assert_contains "stderr cites unbound variable" "$out" "PL_CONTENT: unbound variable"
assert_contains "error references substrate line 457" "$out" "line 457"
# Branch #4 itself never gets to fire for this path → no Branch #4 marker.
assert_not_contains "Branch #4 deny NOT present" "$out" "SP14 Branch #4"

fixture_summary
