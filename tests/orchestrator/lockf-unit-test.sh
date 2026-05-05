#!/bin/bash
# tests/orchestrator/lockf-unit-test.sh — synthetic unit tests for lib/lockf.sh.
#
# Validates claude_lockf_reexec contract:
#   1. Outer call when lock is FREE: re-execs, exits with inner script status.
#   2. Outer call when lock is HELD by another process: lockf returns 75,
#      helper writes skip-log entry and exits 0 (clean skip).
#   3. Inner call (sentinel set): returns 0 so caller proceeds.
#   4. Helper rejects empty lockfile arg with non-zero return.
#
# All tests are hermetic: HOME-isolated tmpdir + per-case cleanup. No live
# filesystem touches, no global lockfile reuse across runs.
#
# Bash 3.2 clean.
#
# Intentionally NOT `set -e`: tests deliberately invoke claude_lockf_reexec
# in error/contention paths that return non-zero. Outcomes are aggregated
# via explicit PASS/FAIL counters.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCKF_HELPER="$REPO_ROOT/lib/lockf.sh"

if [ ! -r "$LOCKF_HELPER" ]; then
  echo "FAIL: cannot read $LOCKF_HELPER"
  exit 1
fi

# Per-test isolation root. Removed unconditionally on exit.
TEST_ROOT="$(mktemp -d -t lockf-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: $1"
}

# --- Test 1: rejects empty lockfile arg ---
test_rejects_empty_arg() {
  local rc
  (
    # shellcheck source=/dev/null
    . "$LOCKF_HELPER"
    claude_lockf_reexec ""
  ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then
    pass "rejects empty lockfile arg (rc=2)"
  else
    fail "rejects empty lockfile arg expected rc=2 got rc=$rc"
  fi
}

# --- Test 2: inner call short-circuits to return 0 ---
test_inner_returns_zero() {
  local rc
  (
    export CLAUDE_LOCKF_REEXECED=1
    # shellcheck source=/dev/null
    . "$LOCKF_HELPER"
    claude_lockf_reexec "$TEST_ROOT/inner.lock"
  ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "inner call (sentinel set) returns 0"
  else
    fail "inner call expected rc=0 got rc=$rc"
  fi
}

# --- Test 3: outer call with FREE lock acquires + runs work + exits inner status ---
test_outer_free_lock_runs_work() {
  local script="$TEST_ROOT/wrapper-free.sh"
  local lockfile="$TEST_ROOT/wrapper-free.lock"
  local marker="$TEST_ROOT/marker-free.txt"

  cat > "$script" <<EOF
#!/bin/bash
set -e
export LOG_DIR="$TEST_ROOT"
. "$LOCKF_HELPER"
claude_lockf_reexec "$lockfile" "\$@"
# inside-lock marker — only written if we successfully acquired.
echo "ran" > "$marker"
exit 42
EOF
  chmod +x "$script"

  local rc
  "$script" >/dev/null 2>&1
  rc=$?

  if [ "$rc" -eq 42 ] && [ -f "$marker" ] && [ "$(cat "$marker")" = "ran" ]; then
    pass "outer call with free lock runs work + exits inner status (rc=42)"
  else
    fail "outer-free expected rc=42 + marker present, got rc=$rc marker=$([ -f "$marker" ] && echo present || echo missing)"
  fi
}

# --- Test 4: outer call with HELD lock skips cleanly + writes skip-log + exits 0 ---
test_outer_held_lock_skips_cleanly() {
  local script="$TEST_ROOT/wrapper-held.sh"
  local lockfile="$TEST_ROOT/wrapper-held.lock"
  local marker="$TEST_ROOT/marker-held.txt"

  cat > "$script" <<EOF
#!/bin/bash
set -e
export LOG_DIR="$TEST_ROOT"
. "$LOCKF_HELPER"
claude_lockf_reexec "$lockfile" "\$@"
# inside-lock marker — must NOT be written when lock is held.
echo "ran" > "$marker"
exit 42
EOF
  chmod +x "$script"

  # Hold the lock in a background subshell. Sleep 5s — long enough for the
  # contention test to fire and exit, short enough that the test does not
  # hang if assertion fails. PID captured so we can clean up.
  /usr/bin/lockf -k -t 0 "$lockfile" sleep 5 &
  local holder_pid=$!

  # Give the holder a moment to acquire before the contender fires.
  sleep 1

  local rc
  "$script" >/dev/null 2>&1
  rc=$?

  # Clean up the holder regardless of test outcome.
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  local skip_log="$TEST_ROOT/wrapper-held-skip.log"
  local skip_log_present=0
  local skip_log_has_entry=0
  if [ -f "$skip_log" ]; then
    skip_log_present=1
    if grep -q "lockf contention on $lockfile" "$skip_log"; then
      skip_log_has_entry=1
    fi
  fi

  if [ "$rc" -eq 0 ] && [ ! -f "$marker" ] && [ "$skip_log_present" -eq 1 ] && [ "$skip_log_has_entry" -eq 1 ]; then
    pass "outer call with held lock skips cleanly (rc=0, no marker, skip-log entry written)"
  else
    fail "outer-held expected rc=0 + no marker + skip-log; got rc=$rc marker=$([ -f "$marker" ] && echo present || echo missing) skip_log_present=$skip_log_present skip_log_entry=$skip_log_has_entry"
  fi
}

# --- Run all tests ---
test_rejects_empty_arg
test_inner_returns_zero
test_outer_free_lock_runs_work
test_outer_held_lock_skips_cleanly

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
