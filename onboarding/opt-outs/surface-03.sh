#!/bin/bash
# onboarding/opt-outs/surface-03.sh — SP07 T-8 opt-out surface #3
# (people_skipped) → Section B.
#
# Manifest contract per skills/onboarder/SKILL.md L91 row #3:
#   `people: []` (librarian people-audit skips downstream).
#
# Dispatcher: invokes onboarding/ux/section-b.sh with --opt-out-people
# prepended. Caller's argv ($@) passes through. Section B's per-flag
# opt-out is independent of #2 (organization_skipped) and #4
# (tools_skipped); AC #5 satisfied at section-b.sh's argparse.
#
# Test override: SECTION_BIN_OVERRIDE replaces the section script path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECTION_BIN="${SECTION_BIN_OVERRIDE:-$SCRIPT_DIR/../ux/section-b.sh}"
exec "$SECTION_BIN" --opt-out-people "$@"
