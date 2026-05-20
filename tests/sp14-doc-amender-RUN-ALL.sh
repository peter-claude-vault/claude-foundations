#!/usr/bin/env bash
# tests/sp14-doc-amender-RUN-ALL.sh
#
# SP14 T-32 Theme D — doc-amender fixture driver.
#
# Fixtures covered (5):
#   sp14-doc-amender-packet-pickup.sh                  — full pipeline pickup + claude mock + emit
#   sp14-doc-amender-replacement-emission.sh           — packet_kind=amender-replacement shape
#   sp14-doc-amender-operator-edit-sidecar.sh          — Signal 2 operator-edit-wins → conflict sidecar
#   sp14-doc-amender-amender-paused-survivorship.sh    — Signal 1 amender_paused frontmatter → skip
#   sp14-doc-amender-reviewed-checkpoint.sh            — Signal 3 reviewed:true (NOT YET IMPL)
#
# Expected outcome at T-32 close (pre-substrate-hotfixes):
#   - 2 GREEN: operator-edit-sidecar + amender_paused (survivorship signals 1 + 2 work)
#   - 3 MIXED PASS/FAIL: packet-pickup + replacement-emission + reviewed-checkpoint
#     (substrate gap — doc-amender/process.sh:489 passes `--output-type md` but
#     lib/staging-emit.sh:149 enum accepts `markdown` per canonical
#     vault-writer.md.json convention; AND sig3 reviewed:true survivorship not
#     implemented. Failures anchor regression detection for substrate hotfix batch.)
#
# PATH-shimmed claude mock at tests/fixtures/sp14-doc-amender-mocks/claude per
# [[feedback_claude_p_subscription_cost_semantics]] — never invoke real `claude -p`.
#
# See spec.md §8.5 (doc-amender Bucket-1b runner) + writer-pipeline-layering.md
# L-105..L-107 + §A62 for substrate contracts.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

THEME_D_FIXTURES="
  sp14-doc-amender-packet-pickup.sh
  sp14-doc-amender-replacement-emission.sh
  sp14-doc-amender-operator-edit-sidecar.sh
  sp14-doc-amender-amender-paused-survivorship.sh
  sp14-doc-amender-reviewed-checkpoint.sh
"

PASS=0
FAIL=0
FAILED_FIXTURES=""

printf '=== SP14 T-32 Theme D — RUN-ALL (doc-amender) ===\n'

for fix_name in $THEME_D_FIXTURES; do
  fix="$SCRIPT_DIR/$fix_name"
  if [ ! -f "$fix" ]; then
    printf '[MISSING] %s\n' "$fix_name"
    FAIL=$((FAIL + 1))
    FAILED_FIXTURES="${FAILED_FIXTURES}
  - $fix_name (missing)"
    continue
  fi
  printf '\n--- %s ---\n' "$fix_name"
  bash "$fix"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf '[PASS] %s\n' "$fix_name"
  else
    FAIL=$((FAIL + 1))
    FAILED_FIXTURES="${FAILED_FIXTURES}
  - $fix_name (rc=$rc)"
    printf '[FAIL] %s (rc=%s)\n' "$fix_name" "$rc"
  fi
done

TOTAL=$((PASS + FAIL))
printf '\n=== SP14 T-32 Theme D RUN-ALL SUMMARY ===\n'
printf 'Total fixtures: %d\n' "$TOTAL"
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"

if [ "$FAIL" -ne 0 ]; then
  printf '\nFailed fixtures:%s\n' "$FAILED_FIXTURES"
  printf '\nNOTE: failures expected pre-substrate-hotfix-batch:\n'
  printf '  - doc-amender→staging-emit output-type enum mismatch (`md` vs `markdown`)\n'
  printf '  - sig3_reviewed_checkpoint() not implemented in doc-amender/process.sh\n'
  printf '  - if !cmd; then rc=$? captures inverted rc (cosmetic; affects audit log readability)\n'
  exit 1
fi

printf '\nALL THEME D FIXTURES PASS (%d/%d)\n' "$PASS" "$TOTAL"
exit 0
