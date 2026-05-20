#!/usr/bin/env bash
# SP14 T-18 Theme B — RUN-ALL driver for skill + library fixtures.
#
# ============================================================================
# Invocation:
#   bash tests/sp14-skill-lib-RUN-ALL.sh
#
# Optional env:
#   FOUNDATION_REPO=<path>   default $HOME/Code/claude-stem
#
# Each fixture script self-creates a TEMPROOT and exports OVERLAY_MASTER,
# ACTION_LOG, VAULT_ROOT pointing inside it; the parent /usr/.claude/ + vault
# are NEVER touched. Per fixture cleans up its own TEMPROOT via trap.
#
# Isolation contract (per [[feedback_no_live_edits_during_foundation_repo_build]]
# + [[feedback_universal_vault_safety]]):
#   - TEMPROOT=$(mktemp -d) trap rm -rf
#   - OVERLAY_MASTER + ACTION_LOG + VAULT_ROOT jailed under TEMPROOT
#   - Refuse-to-run guard: OVERLAY_MASTER must resolve inside TEMPROOT
#
# ============================================================================
# Fixture coverage matrix
#
# /govern register skill (spec.md §2 "Skill + library bodies" L41 + §7 L86):
#   sp14-govern-register-folder-propose.sh        — Class A propose JSON shape
#   sp14-govern-register-folder-commit.sh         — R-37 atomic across 2 pillars + sidecar
#   sp14-govern-register-folder-skip.sh           — unregistered:true row
#   sp14-govern-register-filetype-propose.sh      — Class B/C MV contract stub
#   sp14-govern-register-filetype-commit.sh       — R-37 atomic frontmatter + file_type_contracts
#   sp14-govern-register-filetype-skip.sh         — unregistered:true row
#   sp14-govern-register-tagext-propose.sh        — single-pillar comma-list parse
#   sp14-govern-register-tagext-commit.sh         — single-pillar tagging.taxonomy
#   sp14-govern-register-tagext-skip.sh           — unregistered:true row
#   sp14-govern-register-writer-propose.sh        — Class D connector kind w/ conditional fields
#   sp14-govern-register-writer-commit.sh         — writer-reference .md + atomic library invocation
#   sp14-govern-register-writer-invalid-kind.sh   — invalid --writer-kind rejected rc=2
#
# lib/overlay-master-mutate.sh (spec.md §2 L43 + §7 L87):
#   sp14-overlay-mutate-atomic-write.sh           — tempfile+rename + schema validation
#   sp14-overlay-mutate-r37-bundling.sh           — N=2 happy + atomicity on failure
#   sp14-overlay-mutate-r52-collision.sh          — adopter override semantics
#   sp14-overlay-mutate-lockf-contention.sh       — lockf -k -t 0 fail-fast contract
#   sp14-overlay-mutate-action-log-schema.sh      — full schema validation + bare-noun kind enum
#
# Total: 17 fixtures.
# ============================================================================

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
TESTS_DIR="$FOUNDATION_REPO/tests"

GOVERN_FIXTURES="
sp14-govern-register-folder-propose.sh
sp14-govern-register-folder-commit.sh
sp14-govern-register-folder-skip.sh
sp14-govern-register-filetype-propose.sh
sp14-govern-register-filetype-commit.sh
sp14-govern-register-filetype-skip.sh
sp14-govern-register-tagext-propose.sh
sp14-govern-register-tagext-commit.sh
sp14-govern-register-tagext-skip.sh
sp14-govern-register-writer-propose.sh
sp14-govern-register-writer-commit.sh
sp14-govern-register-writer-invalid-kind.sh
"

LIB_FIXTURES="
sp14-overlay-mutate-atomic-write.sh
sp14-overlay-mutate-r37-bundling.sh
sp14-overlay-mutate-r52-collision.sh
sp14-overlay-mutate-lockf-contention.sh
sp14-overlay-mutate-action-log-schema.sh
"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_FIXTURES=""

run_group() {
  local label="$1"
  local fixtures="$2"
  printf '\n##### %s #####\n' "$label"
  for f in $fixtures; do
    local path="$TESTS_DIR/$f"
    if [ ! -x "$path" ]; then
      printf '\n--- %s --- (missing or not executable; FAIL)\n' "$f"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_FIXTURES="$FAILED_FIXTURES\n  - $f (missing/not-executable)"
      continue
    fi
    printf '\n--- %s ---\n' "$f"
    if bash "$path"; then
      PASS_COUNT=$((PASS_COUNT + 1))
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_FIXTURES="$FAILED_FIXTURES\n  - $f"
    fi
  done
}

printf '=== SP14 T-18 Theme B — Skill + Library Fixtures RUN-ALL ===\n'
printf 'FOUNDATION_REPO=%s\n' "$FOUNDATION_REPO"
printf 'TESTS_DIR=%s\n' "$TESTS_DIR"

run_group "GROUP A — /govern register skill (12 fixtures)" "$GOVERN_FIXTURES"
run_group "GROUP B — lib/overlay-master-mutate.sh (5 fixtures)" "$LIB_FIXTURES"

TOTAL=$((PASS_COUNT + FAIL_COUNT))
printf '\n=============================================================\n'
printf 'SP14 T-18 Theme B RUN-ALL: %s/%s PASS\n' "$PASS_COUNT" "$TOTAL"

if [ "$FAIL_COUNT" -gt 0 ]; then
  printf 'FAILED fixtures:%b\n' "$FAILED_FIXTURES"
  exit 1
fi
exit 0
