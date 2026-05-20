#!/usr/bin/env bash
# tests/sp14-hooks-branch1-classB-filetype-violation.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #1 file-type detection
# (inventory-labeled "Class B filetype-violation"; substrate-labeled Class C
# at line 853-872 of pre-write-guard.sh). Permutation: VIOLATION.
#
# Contract under test (per spec.md §1 / hook-branch-implementations.md L-28):
#   Write file with frontmatter `type: <slug>` where <slug> is NOT in
#   foundation-master.types ∪ r32_type_aliases ∪ overlay.types → propose-
#   and-validate fragment fires with /govern register --kind file-type.
#
# Substrate divergence FIXED in Batch J 2026-05-20 (T-33 fix #1):
#   pre-write-guard.sh:861 jq filter now `(.types // {} | keys[]?),
#   (.r32_type_aliases // {} | keys[]?)` — parens group each arm so both
#   key sets contribute to B1_KNOWN_TYPES. Class C nudge now fires
#   correctly for unregistered types (allow + propose-and-validate context).

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #1 Class C (substrate name) — unregistered type slug\n'
printf '          NOTE: documents substrate jq-malformation divergence (see header)\n'

# Use Meetings/ (foundation-registered folder) so Class A does not fire first.
target="$VAULT_ROOT/Meetings/note.md"
mkdir -p "$(dirname "$target")"

# Frontmatter declares a type NOT in foundation-master.
content="---
type: bogus-unregistered-type
title: Test
date: 2026-05-20
attendees:
  - Peter
---

body"

payload=$(build_write_payload "$target" "$content")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc=$?

# Post-fix#1: Branch #1 Class C fires correctly. Hook exits 0 with
# permissionDecision=allow + propose-and-validate additionalContext.
assert_rc "exit code is 0 (Class C nudge is allow-with-context)" 0 "$rc"
assert_contains "names the offending type slug" "$out" "bogus-unregistered-type"
assert_contains "Class C nudge fragment" "$out" "SP14 Branch #1 Class C"
assert_contains "/govern register hint" "$out" "/govern register --kind file-type"
assert_contains "permissionDecision is allow" "$out" "\"permissionDecision\": \"allow\""

fixture_summary
