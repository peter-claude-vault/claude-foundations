#!/bin/bash
# onboarding/opt-outs/surface-05.sh — SP07 T-8 opt-out surface #5
# (vault_skipped) → Section C.
#
# Manifest contract per skills/onboarder/SKILL.md L93 row #5:
#   `vault: null` (downstream vault writes go stub-mode until a vault
#   is created).
#
# Dispatcher: invokes onboarding/ux/section-c.sh with --opt-out-vault
# prepended. Caller's argv ($@) passes through. Section C's per-flag
# opt-out is independent of #6 (sensitive_skipped); AC #5 satisfied at
# section-c.sh's argparse.
#
# Test override: SECTION_BIN_OVERRIDE replaces the section script path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECTION_BIN="${SECTION_BIN_OVERRIDE:-$SCRIPT_DIR/../ux/section-c.sh}"
exec "$SECTION_BIN" --opt-out-vault "$@"
