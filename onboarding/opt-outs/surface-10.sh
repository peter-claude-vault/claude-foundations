#!/bin/bash
# onboarding/opt-outs/surface-10.sh — SP07 T-8 opt-out surface #10
# (tripwires_skipped) → Section D.
#
# Manifest contract per skills/onboarder/SKILL.md L98 row #10:
#   Cron trilayer not installed; user can re-enable later via /setup-job.
#
# Dispatcher: invokes onboarding/ux/section-d.sh with --opt-out-tripwires
# prepended. Caller's argv ($@) passes through. Section D's per-flag
# opt-out is independent of #7/#8/#9; AC #5 satisfied at section-d.sh's
# argparse.
#
# Test override: SECTION_BIN_OVERRIDE replaces the section script path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECTION_BIN="${SECTION_BIN_OVERRIDE:-$SCRIPT_DIR/../ux/section-d.sh}"
exec "$SECTION_BIN" --opt-out-tripwires "$@"
