#!/bin/bash
# tests/sp03/tripwire-unit-test.sh — synthetic unit tests for
# orchestrator/lib/tripwire.sh `tripwire_fire`.
#
# Validates the write contract:
#   1. Empty args rejected with rc=2.
#   2. Unset $HOOKS_STATE rejected with rc=2.
#   3. Bad cutoff-seconds (non-integer) rejected with rc=2.
#   4. Fire writes ISO-prefixed TSV line to $HOOKS_STATE/tripwire.log.
#   5. Fire with cutoff-seconds, no prior entry: writes.
#   6. Fire with cutoff-seconds, prior entry within window: deduped (no
#      new line).
#   7. Fire with cutoff-seconds, prior entry outside window: writes (new
#      line appears).
#   8. Reader pattern: cutoff_iso string-compare correctly identifies
#      fresh fires (R-41 contents-not-existence semantics — caller
#      observes content, helper records).
#
# Hermetic: per-test $HOOKS_STATE override pointing at a tmpdir.
# Bash 3.2 clean.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$REPO_ROOT/orchestrator/lib/tripwire.sh"

if [ ! -r "$HELPER" ]; then
  echo "FAIL: cannot read $HELPER"
  exit 1
fi

TEST_ROOT="$(mktemp -d -t tripwire-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1"; }

# Source helper into current shell. Each test sets HOOKS_STATE to a
# per-test subdir so writes do not collide.
# shellcheck source=/dev/null
. "$HELPER"

# --- Test 1: empty surface arg rejected ---
test_rejects_empty_surface() {
  local rc
  HOOKS_STATE="$TEST_ROOT/t1" tripwire_fire "" "some reason" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then
    pass "rejects empty surface (rc=2)"
  else
    fail "empty surface expected rc=2 got rc=$rc"
  fi
}

# --- Test 2: unset HOOKS_STATE rejected ---
test_rejects_unset_hooks_state() {
  local rc
  ( unset HOOKS_STATE; tripwire_fire "test" "reason" ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then
    pass "rejects unset \$HOOKS_STATE (rc=2)"
  else
    fail "unset HOOKS_STATE expected rc=2 got rc=$rc"
  fi
}

# --- Test 3: bad cutoff-seconds rejected ---
test_rejects_bad_cutoff() {
  local rc
  HOOKS_STATE="$TEST_ROOT/t3" tripwire_fire "test" "reason" "abc" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then
    pass "rejects non-integer cutoff (rc=2)"
  else
    fail "bad cutoff expected rc=2 got rc=$rc"
  fi
}

# --- Test 4: basic fire writes ISO-prefixed TSV ---
test_basic_fire_writes() {
  local hs="$TEST_ROOT/t4"
  mkdir -p "$hs"
  local rc
  HOOKS_STATE="$hs" tripwire_fire "denylist-path" "found /tmp/x"
  rc=$?
  local logfile="$hs/tripwire.log"
  if [ "$rc" -ne 0 ] || [ ! -f "$logfile" ]; then
    fail "basic fire expected rc=0 + log file present, got rc=$rc log=$([ -f "$logfile" ] && echo present || echo missing)"
    return
  fi
  # Line shape: ISO\tsurface\treason
  local line
  line=$(head -1 "$logfile")
  # Match: starts with 4-digit-year + T-separator; field 2 is surface; field 3 is reason.
  local iso surface reason
  iso=$(printf '%s\n' "$line" | awk -F'\t' '{print $1}')
  surface=$(printf '%s\n' "$line" | awk -F'\t' '{print $2}')
  reason=$(printf '%s\n' "$line" | awk -F'\t' '{print $3}')
  case "$iso" in
    20[0-9][0-9]-*T*) ;;
    *) fail "basic fire ISO prefix malformed: [$iso]"; return ;;
  esac
  if [ "$surface" = "denylist-path" ] && [ "$reason" = "found /tmp/x" ]; then
    pass "basic fire writes ISO-prefixed TSV ($iso)"
  else
    fail "basic fire fields mismatch: surface=[$surface] reason=[$reason]"
  fi
}

# --- Test 5: fire with cutoff, no prior entry → writes ---
test_cutoff_no_prior_writes() {
  local hs="$TEST_ROOT/t5"
  mkdir -p "$hs"
  local rc
  HOOKS_STATE="$hs" tripwire_fire "test-surface" "first fire" 60
  rc=$?
  local logfile="$hs/tripwire.log"
  local count
  count=$(wc -l < "$logfile" 2>/dev/null | tr -d ' ')
  if [ "$rc" -eq 0 ] && [ "$count" = "1" ]; then
    pass "cutoff fire with no prior entry writes (1 line in log)"
  else
    fail "cutoff-no-prior expected rc=0 + 1 line, got rc=$rc count=$count"
  fi
}

# --- Test 6: fire with cutoff, prior entry within window → deduped ---
test_cutoff_within_window_dedup() {
  local hs="$TEST_ROOT/t6"
  mkdir -p "$hs"
  HOOKS_STATE="$hs" tripwire_fire "test-surface" "first fire" 60
  HOOKS_STATE="$hs" tripwire_fire "test-surface" "second fire" 60
  local logfile="$hs/tripwire.log"
  local count
  count=$(wc -l < "$logfile" 2>/dev/null | tr -d ' ')
  if [ "$count" = "1" ]; then
    pass "cutoff dedup within window (1 line, second fire suppressed)"
  else
    fail "dedup-within expected 1 line, got count=$count"
    cat "$logfile" >&2
  fi
}

# --- Test 7: fire with cutoff, prior entry outside window → writes ---
test_cutoff_outside_window_writes() {
  local hs="$TEST_ROOT/t7"
  mkdir -p "$hs"
  local logfile="$hs/tripwire.log"
  # Seed an old entry (ISO from 1 hour ago) directly so we can simulate
  # an entry outside a 60-second cutoff without sleeping.
  local old_epoch
  old_epoch=$(($(date +%s) - 3600))
  local old_iso
  old_iso=$(date -j -r "$old_epoch" -Iseconds)
  printf '%s\ttest-surface\told fire\n' "$old_iso" > "$logfile"
  # Now fire with cutoff=60 — old entry is 3600s old, well outside window,
  # so the helper must write a new line.
  HOOKS_STATE="$hs" tripwire_fire "test-surface" "fresh fire" 60
  local count
  count=$(wc -l < "$logfile" 2>/dev/null | tr -d ' ')
  if [ "$count" = "2" ]; then
    pass "cutoff outside window writes (2 lines: old + fresh)"
  else
    fail "outside-window expected 2 lines, got count=$count"
    cat "$logfile" >&2
  fi
}

# --- Test 8: reader pattern (cutoff_iso string-compare) ---
test_reader_pattern() {
  local hs="$TEST_ROOT/t8"
  mkdir -p "$hs"
  local logfile="$hs/tripwire.log"
  # Seed two entries: one 2-hours-old, one fresh.
  local old_iso fresh_iso
  old_iso=$(date -j -r $(($(date +%s) - 7200)) -Iseconds)
  fresh_iso=$(date -Iseconds)
  printf '%s\told-surface\told event\n' "$old_iso" > "$logfile"
  printf '%s\tfresh-surface\tfresh event\n' "$fresh_iso" >> "$logfile"
  # Reader: cutoff_iso = now - 1 hour. Fresh entries should pass.
  local cutoff_iso
  cutoff_iso=$(date -j -r $(($(date +%s) - 3600)) -Iseconds)
  local fresh_lines
  fresh_lines=$(awk -F'\t' -v c="$cutoff_iso" '$1 > c' "$logfile")
  # Expect exactly 1 fresh line (the fresh-surface entry).
  local fresh_count
  fresh_count=$(printf '%s\n' "$fresh_lines" | grep -c "fresh-surface")
  local old_count
  old_count=$(printf '%s\n' "$fresh_lines" | grep -c "old-surface")
  if [ "$fresh_count" = "1" ] && [ "$old_count" = "0" ]; then
    pass "reader pattern (cutoff_iso string-compare keeps fresh, drops old)"
  else
    fail "reader pattern expected fresh=1 old=0, got fresh=$fresh_count old=$old_count"
    echo "fresh_lines: $fresh_lines" >&2
  fi
}

# --- Run all tests ---
test_rejects_empty_surface
test_rejects_unset_hooks_state
test_rejects_bad_cutoff
test_basic_fire_writes
test_cutoff_no_prior_writes
test_cutoff_within_window_dedup
test_cutoff_outside_window_writes
test_reader_pattern

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
