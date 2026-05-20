#!/usr/bin/env bash
# tests/sp14-reconciler-manifest-RUN-ALL.sh
#
# SP14 T-32 Theme C — writer-reconciler + lib/manifest-record + daily-processing
# JSONL fixture driver.
#
# Fixtures covered (6):
#   sp14-manifest-record-bootstrap.sh             — manifest.sqlite DDL bootstrap
#   sp14-manifest-record-write-row.sh             — record-write row insert
#   sp14-manifest-record-supersession.sh          — logical supersession chain
#   sp14-writer-reconciler-tick-step8.5.sh        — daily-processing JSONL append
#   sp14-writer-reconciler-step8.6-manifest-row.sh — manifest.sqlite row write
#   sp14-daily-processing-day-rollover.sh         — UTC day-rollover immutability
#
# Expected outcome at T-32 close (pre-T-34):
#   - 3 GREEN: manifest-record bootstrap + write-row + supersession
#   - 3 MIXED PASS/FAIL: writer-reconciler step 8.5 + step 8.6 + day-rollover
#     (substrate gap — process.sh does not yet implement step 8.5/8.6; SKILL.md
#     documents per T-27 done. Failures anchor regression detection for T-34.)
#
# See spec.md §7 + §8 (Scope 1 deep-dive) + writer-pipeline-layering.md
# L-95..L-109 + §A60..§A62 for substrate contracts.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

THEME_C_FIXTURES="
  sp14-manifest-record-bootstrap.sh
  sp14-manifest-record-write-row.sh
  sp14-manifest-record-supersession.sh
  sp14-writer-reconciler-tick-step8.5.sh
  sp14-writer-reconciler-step8.6-manifest-row.sh
  sp14-daily-processing-day-rollover.sh
"

PASS=0
FAIL=0
FAILED_FIXTURES=""

printf '=== SP14 T-32 Theme C — RUN-ALL (writer-reconciler + manifest + daily-processing) ===\n'

for fix_name in $THEME_C_FIXTURES; do
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
printf '\n=== SP14 T-32 Theme C RUN-ALL SUMMARY ===\n'
printf 'Total fixtures: %d\n' "$TOTAL"
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"

if [ "$FAIL" -ne 0 ]; then
  printf '\nFailed fixtures:%s\n' "$FAILED_FIXTURES"
  printf '\nNOTE: writer-reconciler step 8.5 / 8.6 / day-rollover fixtures fail by design until T-34\n'
  printf '(implement step 8.5 + 8.6 in writer-reconciler/process.sh per SKILL.md T-27 spec) lands.\n'
  exit 1
fi

printf '\nALL THEME C FIXTURES PASS (%d/%d)\n' "$PASS" "$TOTAL"
exit 0
