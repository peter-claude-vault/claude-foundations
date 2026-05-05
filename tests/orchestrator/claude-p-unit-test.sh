#!/bin/bash
# tests/orchestrator/claude-p-unit-test.sh — synthetic unit tests for
# orchestrator/lib/claude-p.sh `classify_claude_p_exit`.
#
# Validates both fingerprint branches against synthetic ndjson fixtures:
#   1. Empty arg rejected with rc=2.
#   2. Cold-start-hang: ≤120 bytes + "SessionEnd hook.*Hook cancelled" line.
#   3. Stalled-mid-run: >120 bytes regardless of grep match.
#   4. Stalled-mid-run: ≤120 bytes but missing grep marker.
#   5. Missing ndjson file: classifies as stalled-mid-run with bytes=0.
#
# Hermetic: per-case tmpdir, per-case fixture write, no live filesystem
# touches. Bash 3.2 clean.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$REPO_ROOT/orchestrator/lib/claude-p.sh"

if [ ! -r "$HELPER" ]; then
  echo "FAIL: cannot read $HELPER"
  exit 1
fi

TEST_ROOT="$(mktemp -d -t claude-p-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1"; }

# Source helper into the current shell so the function is callable.
# shellcheck source=/dev/null
. "$HELPER"

# --- Test 1: empty arg rejected ---
test_rejects_empty_arg() {
  local out rc
  out=$(classify_claude_p_exit "" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 2 ] && [ -z "$out" ]; then
    pass "rejects empty ndjson_path arg (rc=2)"
  else
    fail "rejects empty arg expected rc=2 + empty stdout, got rc=$rc out=[$out]"
  fi
}

# --- Test 2: cold-start-hang fingerprint ---
test_cold_start_hang() {
  local fixture="$TEST_ROOT/cold-start.ndjson"
  # Death-rattle: SessionEnd hook line + framing, ≤120 bytes.
  printf '{"type":"system","subtype":"SessionEnd hook fired: Hook cancelled"}\n' > "$fixture"
  local size
  size=$(stat -f%z "$fixture")
  if [ "$size" -gt 120 ]; then
    fail "fixture setup error: cold-start fixture is $size bytes (>120)"
    return
  fi
  local out
  out=$(classify_claude_p_exit "$fixture")
  if [ "$out" = "claude-p-never-emitted-output (cold-start-hang)" ]; then
    pass "cold-start-hang ($size bytes + marker → never-emitted-output)"
  else
    fail "cold-start-hang expected never-emitted-output, got [$out]"
  fi
}

# --- Test 3: stalled-mid-run via large file ---
test_stalled_large_file() {
  local fixture="$TEST_ROOT/stalled-large.ndjson"
  # Real claude -p output: thousands of bytes of stream-json.
  local i=0
  while [ "$i" -lt 50 ]; do
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"working on task chunk %d"}]}}\n' "$i" >> "$fixture"
    i=$((i + 1))
  done
  local size
  size=$(stat -f%z "$fixture")
  if [ "$size" -le 120 ]; then
    fail "fixture setup error: large fixture is $size bytes (≤120)"
    return
  fi
  local out
  out=$(classify_claude_p_exit "$fixture")
  if [ "$out" = "claude-p-stalled-mid-run (bytes=$size)" ]; then
    pass "stalled-mid-run via large file ($size bytes → stalled-mid-run)"
  else
    fail "stalled-large expected stalled-mid-run (bytes=$size), got [$out]"
  fi
}

# --- Test 4: small file but no marker → stalled-mid-run ---
test_small_no_marker() {
  local fixture="$TEST_ROOT/small-no-marker.ndjson"
  printf '{"type":"system","subtype":"init"}\n' > "$fixture"
  local size
  size=$(stat -f%z "$fixture")
  if [ "$size" -gt 120 ]; then
    fail "fixture setup error: small-no-marker fixture is $size bytes (>120)"
    return
  fi
  local out
  out=$(classify_claude_p_exit "$fixture")
  if [ "$out" = "claude-p-stalled-mid-run (bytes=$size)" ]; then
    pass "small file without marker ($size bytes, no marker → stalled-mid-run)"
  else
    fail "small-no-marker expected stalled-mid-run (bytes=$size), got [$out]"
  fi
}

# --- Test 5: missing ndjson file ---
test_missing_file() {
  local fixture="$TEST_ROOT/does-not-exist.ndjson"
  local out
  out=$(classify_claude_p_exit "$fixture")
  # stat -f%z on missing file → "echo 0" fallback → size=0; grep on missing
  # file → no match. AND fails (size=0 ≤120 but grep -q false), so falls
  # to stalled-mid-run with bytes=0. Documented contract.
  if [ "$out" = "claude-p-stalled-mid-run (bytes=0)" ]; then
    pass "missing ndjson file → stalled-mid-run (bytes=0)"
  else
    fail "missing-file expected stalled-mid-run (bytes=0), got [$out]"
  fi
}

# --- Run all tests ---
test_rejects_empty_arg
test_cold_start_hang
test_stalled_large_file
test_small_no_marker
test_missing_file

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
