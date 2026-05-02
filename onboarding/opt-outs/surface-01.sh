#!/bin/bash
# onboarding/opt-outs/surface-01.sh — SP07 T-8 opt-out surface #1
# (discovery_skipped) → Section A.
#
# Manifest contract per skills/onboarder/SKILL.md L89 row #1:
#   Empty discovery context + `system.opt_outs[]` appends `discovery_skipped`.
#
# Dispatcher: invokes onboarding/ux/section-a.sh with --auto-opt-out
# prepended. Caller's argv ($@) passes through, so hermetic env knobs
# (--inputs-dir / --audit-log / --transcript-dir / --prompt-card / --typed-only)
# can be appended without surface-handler intermediation. The deterministic
# manifest-record contract is satisfied transitively — section-a.sh owns
# the populated extraction-output-A.json shape (S74 close, foundation
# commit `98f194b`).
#
# Test override: SECTION_BIN_OVERRIDE replaces the section script path,
# enabling stub-binary substitution for surface-handler dispatch tests.
#
# AC #5 (any surface individually selectable without forcing downstream
# opt-outs): structurally satisfied — Section A has only one surface, so
# "individually" is trivially the whole section.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECTION_BIN="${SECTION_BIN_OVERRIDE:-$SCRIPT_DIR/../ux/section-a.sh}"
exec "$SECTION_BIN" --auto-opt-out "$@"
