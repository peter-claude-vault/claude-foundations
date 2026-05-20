#!/usr/bin/env bash
# tests/sp14-hooks-branch3-scopemiss-index-md.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #3 vault-writer frontmatter
# validation. Permutation: SCOPE-MISS (excluded_paths bypass).
#
# Contract under test (line 950-953):
#   Writes to Vault Writers/_index.md and Vault Writers/_overlap-matrix.md
#   are skipped via the case ... in branch (librarian-managed paths per
#   vault-writer.md.json :: excluded_paths).
#
# Distinct from branch1-classD-writer-scopemiss.sh by passing content that
# would FAIL the frontmatter contract if it ran — confirming the case-stmt
# bypass IS the gate.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #3 — _index.md / _overlap-matrix.md excluded_paths\n'

# 1) _index.md — content has ZERO frontmatter (would fail Branch #3 if run).
target1="$VAULT_ROOT/Vault Writers/_index.md"
mkdir -p "$(dirname "$target1")"
content1="# Writers — Auto Index

(librarian-generated)
"
payload1=$(build_write_payload "$target1" "$content1")
out1=$(printf '%s' "$payload1" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc1=$?

assert_rc "_index.md write exit 0" 0 "$rc1"
assert_not_contains "_index.md does NOT trigger Branch #3 deny" "$out1" "SP14 Branch #3"
assert_not_contains "_index.md does NOT trigger schema violation" "$out1" "Vault Writers/ schema violation"

# 2) _overlap-matrix.md — same minimal content.
target2="$VAULT_ROOT/Vault Writers/_overlap-matrix.md"
content2="| Writer | Destination |
|--------|-------------|
| foo    | bar         |
"
payload2=$(build_write_payload "$target2" "$content2")
out2=$(printf '%s' "$payload2" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc2=$?

assert_rc "_overlap-matrix.md write exit 0" 0 "$rc2"
assert_not_contains "_overlap-matrix.md does NOT trigger Branch #3 deny" "$out2" "SP14 Branch #3"

fixture_summary
