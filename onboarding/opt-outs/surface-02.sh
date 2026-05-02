#!/bin/bash
# onboarding/opt-outs/surface-02.sh — SP07 T-8 opt-out surface #2
# (organization_skipped) → Section B.
#
# Manifest contract per skills/onboarder/SKILL.md L90 row #2:
#   `identity.organization: null`.
#
# Dispatcher: invokes onboarding/ux/section-b.sh with --opt-out-org
# prepended. Caller's argv ($@) passes through. Section B's per-flag
# opt-out is independent of #3 (people_skipped) and #4 (tools_skipped) —
# AC #5 (any surface individually selectable without forcing downstream
# opt-outs) is structurally satisfied at section-b.sh's argparse layer
# (no flag implies any other).
#
# Test override: SECTION_BIN_OVERRIDE replaces the section script path,
# enabling stub-binary substitution for surface-handler dispatch tests.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECTION_BIN="${SECTION_BIN_OVERRIDE:-$SCRIPT_DIR/../ux/section-b.sh}"
exec "$SECTION_BIN" --opt-out-org "$@"
