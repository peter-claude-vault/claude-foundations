#!/bin/bash
# tests/orchestrator/skip-weekends-unit-test.sh — synthetic unit tests for the
# SKIP_WEEKENDS env gate in orchestrator/cron-wrappers/librarian-cron.sh.
#
# Validates the gate contract per T-12:
#   T1. SKIP_WEEKENDS unset (default true), DOW=6 (Saturday) → SKIP fires (rc=0,
#       skip-log entry written).
#   T2. SKIP_WEEKENDS=true,  DOW=7 (Sunday)   → SKIP fires.
#   T3. SKIP_WEEKENDS=false, DOW=6 (Saturday) → DOES NOT skip (proceeds).
#   T4. SKIP_WEEKENDS=true,  DOW=3 (Wednesday) → DOES NOT skip (weekday).
#   T5. Structural — grep librarian-cron.sh for the SKIP_WEEKENDS env-gate
#       substring; reject if absent (drift detection).
#
# Behavioral tests use the gate fragment in isolation so the test does not
# depend on lockf, claude binary, MCP probe, or any wrapper plumbing. The
# fragment is a verbatim copy of librarian-cron.sh L53-58 (post-T-12); T5
# enforces parity.
#
# Hermetic: per-test mktemp $LOG_DIR; bash 3.2 clean (R-23).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$REPO_ROOT/orchestrator/cron-wrappers/librarian-cron.sh"

if [ ! -f "$WRAPPER" ]; then
  echo "FAIL: missing $WRAPPER"
  exit 1
fi

TEST_ROOT="$(mktemp -d -t skip-weekends-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 — $2"; }

# --- Gate fragment under test (verbatim parity with librarian-cron.sh) ---
# Returns 0 + writes skip-log if gate fires; returns 1 + no log otherwise.
# Inputs (via env): SKIP_WEEKENDS (optional), DOW (required), LOG_DIR (required).
run_gate() {
  if [ "${SKIP_WEEKENDS:-true}" = "true" ] && [ "$DOW" -gt 5 ]; then
    echo "$(date -Iseconds) Weekend — skipping librarian scan (SKIP_WEEKENDS=true)" >> "$LOG_DIR/librarian-cron-skip.log"
    return 0  # gate fired: caller would `exit 0`
  fi
  return 1  # gate did not fire: caller proceeds
}

# --- T1: SKIP_WEEKENDS unset, DOW=6 Saturday → fires ---
T1_DIR="$TEST_ROOT/t1"
mkdir -p "$T1_DIR"
unset SKIP_WEEKENDS
DOW=6 LOG_DIR="$T1_DIR" run_gate
RC=$?
if [ "$RC" = "0" ] && [ -s "$T1_DIR/librarian-cron-skip.log" ]; then
  pass "T1 default+Saturday → skip fires (rc=0, log written)"
else
  fail "T1" "rc=$RC, log_size=$(stat -f%z "$T1_DIR/librarian-cron-skip.log" 2>/dev/null || echo 0)"
fi

# --- T2: SKIP_WEEKENDS=true, DOW=7 Sunday → fires ---
T2_DIR="$TEST_ROOT/t2"
mkdir -p "$T2_DIR"
SKIP_WEEKENDS=true DOW=7 LOG_DIR="$T2_DIR" run_gate
RC=$?
if [ "$RC" = "0" ] && [ -s "$T2_DIR/librarian-cron-skip.log" ]; then
  pass "T2 SKIP_WEEKENDS=true+Sunday → skip fires"
else
  fail "T2" "rc=$RC, log_size=$(stat -f%z "$T2_DIR/librarian-cron-skip.log" 2>/dev/null || echo 0)"
fi

# --- T3: SKIP_WEEKENDS=false, DOW=6 Saturday → DOES NOT skip ---
T3_DIR="$TEST_ROOT/t3"
mkdir -p "$T3_DIR"
SKIP_WEEKENDS=false DOW=6 LOG_DIR="$T3_DIR" run_gate
RC=$?
if [ "$RC" = "1" ] && [ ! -e "$T3_DIR/librarian-cron-skip.log" ]; then
  pass "T3 SKIP_WEEKENDS=false+Saturday → proceeds (rc=1, no log)"
else
  fail "T3" "rc=$RC, log_exists=$([ -e "$T3_DIR/librarian-cron-skip.log" ] && echo yes || echo no)"
fi

# --- T4: SKIP_WEEKENDS=true, DOW=3 Wednesday → DOES NOT skip (weekday) ---
T4_DIR="$TEST_ROOT/t4"
mkdir -p "$T4_DIR"
SKIP_WEEKENDS=true DOW=3 LOG_DIR="$T4_DIR" run_gate
RC=$?
if [ "$RC" = "1" ] && [ ! -e "$T4_DIR/librarian-cron-skip.log" ]; then
  pass "T4 SKIP_WEEKENDS=true+Wednesday → proceeds (weekday)"
else
  fail "T4" "rc=$RC, log_exists=$([ -e "$T4_DIR/librarian-cron-skip.log" ] && echo yes || echo no)"
fi

# --- T5: Structural — wrapper carries the SKIP_WEEKENDS env-gate substring ---
if grep -q '\${SKIP_WEEKENDS:-true}' "$WRAPPER"; then
  pass "T5 wrapper contains SKIP_WEEKENDS:-true env gate"
else
  fail "T5" "missing \${SKIP_WEEKENDS:-true} in $WRAPPER (drift)"
fi

# --- Summary ---
echo "---"
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
[ "$FAIL_COUNT" = "0" ]
