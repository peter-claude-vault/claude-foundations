#!/bin/bash
# onboarding/opt-outs/surface-08.sh — SP07 T-8 opt-out surface #8
# (checkpoint_relaxed) → Section D.
#
# Manifest contract per skills/onboarder/SKILL.md L96 row #8:
#   Raise to 55% OR set `CHECKPOINT_DISABLE_OK=1` in
#   `behavioral.hook_preferences`.
#
# Dispatcher: invokes onboarding/ux/section-d.sh with --opt-out-checkpoint
# prepended. Caller's argv ($@) passes through. Section D's per-flag
# opt-out is independent of #7/#9/#10; AC #5 satisfied at section-d.sh's
# argparse.
#
# Test override: SECTION_BIN_OVERRIDE replaces the section script path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECTION_BIN="${SECTION_BIN_OVERRIDE:-$SCRIPT_DIR/../ux/section-d.sh}"
exec "$SECTION_BIN" --opt-out-checkpoint "$@"
