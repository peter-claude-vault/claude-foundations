#!/bin/bash
# onboarding/opt-outs/surface-07.sh — SP07 T-8 opt-out surface #7
# (hook_advisory) → Section D.
#
# Manifest contract per skills/onboarder/SKILL.md L95 row #7:
#   Advisory-mode install for R-43 family hooks.
#
# Dispatcher: invokes onboarding/ux/section-d.sh with --opt-out-hooks
# prepended (note section-d argparse uses --opt-out-hooks plural; surface
# canonical name `hook_advisory` is the audit tag, not the CLI flag).
# Caller's argv ($@) passes through. Section D's per-flag opt-out is
# independent of #8/#9/#10; AC #5 satisfied at section-d.sh's argparse.
#
# Test override: SECTION_BIN_OVERRIDE replaces the section script path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECTION_BIN="${SECTION_BIN_OVERRIDE:-$SCRIPT_DIR/../ux/section-d.sh}"
exec "$SECTION_BIN" --opt-out-hooks "$@"
