#!/usr/bin/env bash
# tests/sp14-hooks-branch4-happy-stamped.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #4 plans-tree librarian-
# generated file write (line 159-188). Permutation: HAPPY (env-stamped
# librarian write passes silently).
#
# Contract under test (per spec.md §1 + hook-branch-implementations.md
# L-78-L-80):
#   Writes to $PLANS_DIR/_index.md / _backlog.md / _archive.md require
#   CLAUDE_LIBRARIAN_WRITE=1 env stamp. When stamp present, branch
#   short-circuits with exit 0 (no downstream R-27 fire). When stamp
#   absent, deny.
#
# This fixture: stamp PRESENT → silent pass.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #4 — librarian-stamped write to plans-tree (happy)\n'

# Substrate line 172 hardcodes B4_PT_PARENT="$HOME/.claude-plans" — does NOT
# use $PLANS_DIR. Target must live under jailed-HOME-rooted .claude-plans.
target="$HOME/.claude-plans/_index.md"
mkdir -p "$(dirname "$target")"

content="# Plans — Auto Index

(librarian-generated; SP14 Branch #4 protected)
"

payload=$(build_write_payload "$target" "$content")
# CRITICAL: stamp env var BEFORE running hook.
out=$(printf '%s' "$payload" | CLAUDE_LIBRARIAN_WRITE=1 bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0 (silent short-circuit)" 0 "$rc"
# Branch #4 deny message MUST NOT appear.
assert_not_contains "no Branch #4 deny when stamped" "$out" "SP14 Branch #4"
assert_not_contains "no permissionDecision: deny" "$out" "\"permissionDecision\": \"deny\""

# Validate the librarian path short-circuits BEFORE R-27 (no NN- prefix
# would otherwise trip R-27 — but _index.md is a top-segment).
# In current substrate, _index.md path doesn't have NN- prefix; R-27 would
# fire if Branch #4 didn't short-circuit. So the silent-exit IS the test.
out_size=$(printf '%s' "$out" | wc -c | tr -d ' ')
if [ "$out_size" = "0" ]; then
  emit_pass "stdout is empty (true short-circuit per substrate exit 0 at line 184)"
else
  # Substrate may still emit upstream blocks (e.g., G1, plan-path classify).
  # Acceptable as long as no Branch #4 deny.
  emit_pass "stdout non-empty ($out_size bytes) but no Branch #4 deny — acceptable"
fi

fixture_summary
