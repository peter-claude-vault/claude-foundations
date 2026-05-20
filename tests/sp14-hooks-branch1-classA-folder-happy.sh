#!/usr/bin/env bash
# tests/sp14-hooks-branch1-classA-folder-happy.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #1 Class A (unregistered
# top-level vault folder). Permutation: HAPPY (the propose-and-validate
# nudge fires as expected). Per spec.md §7 + handoff.md Session 7 / Batch G
# T-4 (A/B/C).
#
# Contract under test:
#   Write to vault path under an unregistered top-level folder (not in the
#   foundation system folders + overlay path_routing keys) → hook emits an
#   allow with additionalContext fragment "[Propose-and-Validate — SP14
#   Branch #1 Class A / L-28]" containing /govern register --kind folder.
#   rc=0.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #1 Class A — unregistered top-level folder (happy)\n'

# Target: vault/FooBar/some-file.md   (FooBar is unregistered)
target="$VAULT_ROOT/FooBar/some-file.md"
mkdir -p "$(dirname "$target")"
payload=$(build_write_payload "$target" "type: note
---
body")

out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0 (allow with additionalContext)" 0 "$rc"
assert_contains "additionalContext carries Class A marker" "$out" "SP14 Branch #1 Class A"
assert_contains "additionalContext carries /govern register --kind folder hint" "$out" "/govern register --kind folder"
assert_contains "additionalContext names the unregistered folder" "$out" "FooBar/"
assert_contains "permissionDecision is allow" "$out" "\"permissionDecision\": \"allow\""

fixture_summary
