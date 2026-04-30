#!/bin/bash
# tests/sp03/idle-watchdog-unit-test.sh — synthetic unit tests for
# orchestrator/lib/idle-watchdog.sh `watchdog_idle`.
#
# Validates the silence-detector contract:
#   1. Empty args rejected with rc=2.
#   2. Synthetic hung process (writes nothing): watchdog fires, returns 124,
#      kills the pid, dispatches the classifier, writes log lines.
#   3. Synthetic active process (writes continuously to ndjson): idle counter
#      resets on growth; pid completes naturally; watchdog returns the pid's
#      exit status.
#   4. Composition — claude-p.sh sourced first → classifier line in log
#      matches one of the documented classifications.
#
# Tests use WATCHDOG_SAMPLE_INTERVAL=1 + timeout=2 to keep runtime under 10s.
#
# Hermetic: per-case tmpdir, per-case backgrounded sleeper. Bash 3.2 clean.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLAUDE_P="$REPO_ROOT/orchestrator/lib/claude-p.sh"
WATCHDOG="$REPO_ROOT/orchestrator/lib/idle-watchdog.sh"

for f in "$CLAUDE_P" "$WATCHDOG"; do
  if [ ! -r "$f" ]; then
    echo "FAIL: cannot read $f"
    exit 1
  fi
done

TEST_ROOT="$(mktemp -d -t idle-watchdog-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1"; }

# Source both helpers into the current shell.
# Tests need fast cycles, so override the sample interval to 1 second.
export WATCHDOG_SAMPLE_INTERVAL=1
# shellcheck source=/dev/null
. "$CLAUDE_P"
# shellcheck source=/dev/null
. "$WATCHDOG"

# --- Test 1: empty args rejected ---
test_rejects_empty_args() {
  local rc
  watchdog_idle "" "" 5 >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then
    pass "rejects empty args (rc=2)"
  else
    fail "rejects empty args expected rc=2 got rc=$rc"
  fi
}

# --- Test 2: synthetic hung process triggers watchdog fire ---
test_hung_process_fires() {
  local ndjson="$TEST_ROOT/hung.ndjson"
  local logfile="$TEST_ROOT/hung.log"
  : > "$ndjson"
  : > "$logfile"

  # Background a sleeper that does not write to the ndjson. Sleep duration
  # exceeds the watchdog timeout so the watchdog must SIGTERM/SIGKILL it.
  ( sleep 30 ) &
  local hung_pid=$!

  local rc
  LOG_FILE="$logfile" watchdog_idle "$hung_pid" "$ndjson" 2 >/dev/null 2>&1
  rc=$?

  # Confirm the pid is no longer alive (watchdog killed it).
  local still_alive=0
  if kill -0 "$hung_pid" 2>/dev/null; then
    still_alive=1
    kill -9 "$hung_pid" 2>/dev/null || true
  fi

  # Confirm the log captured the watchdog-fire signature.
  local has_fire_line=0
  local has_classification=0
  if grep -q "IDLE-WATCHDOG-FIRED" "$logfile"; then
    has_fire_line=1
  fi
  if grep -q "classification:" "$logfile"; then
    has_classification=1
  fi

  if [ "$rc" -eq 124 ] && [ "$still_alive" -eq 0 ] \
     && [ "$has_fire_line" -eq 1 ] && [ "$has_classification" -eq 1 ]; then
    pass "hung process → SIGTERM/SIGKILL → rc=124 + fire-line + classification logged"
  else
    fail "hung process expected rc=124 + killed + fire-line + classification, got rc=$rc still_alive=$still_alive fire=$has_fire_line classify=$has_classification"
    echo "--- log dump ---" >&2
    cat "$logfile" >&2
    echo "--- end log dump ---" >&2
  fi
}

# --- Test 3: active process exits naturally → watchdog returns its rc ---
test_active_process_natural_exit() {
  local ndjson="$TEST_ROOT/active.ndjson"
  local logfile="$TEST_ROOT/active.log"
  : > "$ndjson"
  : > "$logfile"

  # Background a writer that appends to the ndjson every 0.2s for 3 seconds
  # then exits 17. Idle counter must reset on growth, so watchdog must NOT
  # fire even with timeout=2.
  (
    local n=0
    while [ "$n" -lt 15 ]; do
      printf '{"chunk":%d}\n' "$n" >> "$ndjson"
      sleep 0.2
      n=$((n + 1))
    done
    exit 17
  ) &
  local writer_pid=$!

  local rc
  LOG_FILE="$logfile" watchdog_idle "$writer_pid" "$ndjson" 2 >/dev/null 2>&1
  rc=$?

  # Confirm watchdog did NOT fire (no IDLE-WATCHDOG-FIRED line).
  local no_fire=1
  if grep -q "IDLE-WATCHDOG-FIRED" "$logfile"; then
    no_fire=0
  fi

  # Confirm ndjson grew past zero bytes (writer wrote).
  local size
  size=$(stat -f%z "$ndjson" 2>/dev/null || echo 0)
  local grew=0
  if [ "$size" -gt 0 ]; then grew=1; fi

  if [ "$rc" -eq 17 ] && [ "$no_fire" -eq 1 ] && [ "$grew" -eq 1 ]; then
    pass "active process natural exit → rc=17 propagated, no fire line, ndjson grew ($size bytes)"
  else
    fail "active process expected rc=17 + no-fire + grew, got rc=$rc no_fire=$no_fire grew=$grew size=$size"
    echo "--- log dump ---" >&2
    cat "$logfile" >&2
    echo "--- end log dump ---" >&2
  fi
}

# --- Test 4: classifier composition produces a documented classification ---
test_classifier_composition() {
  local ndjson="$TEST_ROOT/compose.ndjson"
  local logfile="$TEST_ROOT/compose.log"
  # Pre-seed the ndjson with the cold-start-hang fingerprint so the
  # classifier must emit "claude-p-never-emitted-output".
  printf '{"type":"system","subtype":"SessionEnd hook fired: Hook cancelled"}\n' > "$ndjson"
  : > "$logfile"

  # Background a sleeper that does not write to the ndjson (the seed already
  # set its size; subsequent samples find no growth).
  ( sleep 30 ) &
  local hung_pid=$!

  LOG_FILE="$logfile" watchdog_idle "$hung_pid" "$ndjson" 2 >/dev/null 2>&1

  if kill -0 "$hung_pid" 2>/dev/null; then
    kill -9 "$hung_pid" 2>/dev/null || true
  fi

  if grep -q "classification: claude-p-never-emitted-output" "$logfile"; then
    pass "classifier composition (cold-start-hang fingerprint dispatched correctly)"
  else
    fail "classifier composition expected cold-start-hang line"
    echo "--- log dump ---" >&2
    cat "$logfile" >&2
    echo "--- end log dump ---" >&2
  fi
}

# --- Run all tests ---
test_rejects_empty_args
test_hung_process_fires
test_active_process_natural_exit
test_classifier_composition

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
