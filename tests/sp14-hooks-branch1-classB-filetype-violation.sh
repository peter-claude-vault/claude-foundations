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
# Substrate divergence finding (DOCUMENTED, NOT FIXED per fixture-only scope):
#   pre-write-guard.sh:861 jq filter `.types // {} | keys[]?,
#   .r32_type_aliases // {} | keys[]?` is malformed — the comma binds
#   to the second filter so jq pipes `.r32_type_aliases // {}` into
#   `keys[]?` which fails (the value is an object but the intermediate
#   step yields strings on iteration). Result: B1_KNOWN_TYPES is always
#   empty, Class C nudge NEVER fires for any unregistered type. The
#   downstream 3-tier R-32 UNKNOWN TYPE deny catches the unregistered
#   type instead, but with a different message + behavior (DENY vs nudge).
#
#   Corrected filter: `(.types // {} | keys[]?), (.r32_type_aliases // {} | keys[]?)`
#
# This fixture asserts the substrate's CURRENT behavior so the divergence
# is surfaced in test failures when it gets fixed (then update the fixture
# expectations to match the spec). Filename retained per dispatch brief
# inventory.

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

# Current substrate behavior: Branch #1 Class C never fires (jq malformed),
# falls through to 3-tier R-32 Tier 2 DENY. rc=0 (hook always exits 0 in
# the format_output path; deny is signaled in JSON, not rc).
assert_rc "exit code is 0 (deny via JSON, not rc)" 0 "$rc"
assert_contains "names the offending type slug" "$out" "bogus-unregistered-type"
# When substrate is fixed, swap the next two assertions:
#   - desired: assert_contains "Class C nudge fragment" "$out" "SP14 Branch #1 Class C"
#   - desired: assert_contains "/govern register hint" "$out" "/govern register --kind file-type"
# Until fix lands, assert the actual fall-through behavior:
assert_contains "current substrate falls through to R-32 Tier 2 deny" "$out" "R-32 UNKNOWN TYPE"
assert_contains "permissionDecision is deny" "$out" "\"permissionDecision\": \"deny\""

fixture_summary
