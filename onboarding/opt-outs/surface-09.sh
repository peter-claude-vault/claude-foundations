#!/bin/bash
# onboarding/opt-outs/surface-09.sh — SP07 T-8 opt-out surface #9
# (initial_job_skipped) → Section D.
#
# Manifest contract per skills/onboarder/SKILL.md L97 row #9:
#   `orchestration.jobs: []` — no plist written, no staging file.
#
# Dispatcher: invokes onboarding/ux/section-d.sh with
# --opt-out-initial-job prepended. Caller's argv ($@) passes through.
# Section D's per-flag opt-out is independent of #7/#8/#10; AC #5
# satisfied at section-d.sh's argparse. Note: opt-out #9 elected upstream
# at the section yields audit tag `initial_job_skipped` and orchestration
# `jobs:[]`; this is structurally distinct from initial-job-setup.sh's
# Q1=none short-circuit which emits `interview_opt_out_9` (S82 close).
#
# Test override: SECTION_BIN_OVERRIDE replaces the section script path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECTION_BIN="${SECTION_BIN_OVERRIDE:-$SCRIPT_DIR/../ux/section-d.sh}"
exec "$SECTION_BIN" --opt-out-initial-job "$@"
