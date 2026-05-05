#!/bin/bash
# tests/orchestrator/cron-health-banner-unit-test.sh — synthetic unit tests for
# hooks/cron-health-banner.sh SessionStart banner.
#
# Validates the banner contract:
#   1. Synthetic cron-error file (filename-epoch < 24h) → banner emits
#      hookSpecificOutput.additionalContext JSON containing the CRON HEALTH
#      banner text.
#   2. R-41 contents-not-existence: empty log surfaces → silent (no stdout).
#   3. R-41 contents-not-existence: stale cron-error file (> 24h) → silent.
#   4. Filename-epoch parsing: banner output contains the parsed timestamp
#      in display form (YYYY-MM-DD HH:MM).
#
# Hermetic: per-test fake $HOME with stub paths.sh + per-test surfaces.
# Bash 3.2 clean.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BANNER="$REPO_ROOT/hooks/cron-health-banner.sh"

if [ ! -x "$BANNER" ]; then
  echo "FAIL: cannot exec $BANNER"
  exit 1
fi

TEST_ROOT="$(mktemp -d -t cron-health-banner-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1"; }

# Build a fake $HOME with a stub paths.sh that exports the env vars the
# banner consumes. The banner sources $HOME/.claude/hooks/hooks/lib/paths.sh
# at L21; downstream `${VAR:-default}` forms cover MANIFEST_PATH_LOCAL,
# RESEARCH_QUEUE_PATH, AUTO_COMMIT_LOG_PATH from VAULT_LOGS + HOOKS_STATE.
setup_fake_home() {
  local hroot="$1"
  mkdir -p "$hroot/.claude/hooks/lib"
  mkdir -p "$hroot/vault-logs"
  mkdir -p "$hroot/hooks-state"
  cat > "$hroot/.claude/hooks/lib/paths.sh" <<EOF
#!/bin/bash
export VAULT_LOGS="$hroot/vault-logs"
export HOOKS_STATE="$hroot/hooks-state"
EOF
  chmod +x "$hroot/.claude/hooks/lib/paths.sh"
}

# --- Test 1: synthetic recent cron-error file → banner fires ---
test_recent_error_fires() {
  local hroot="$TEST_ROOT/t1"
  setup_fake_home "$hroot"
  # Create a cron-error file dated 1 hour ago (well within 24h cutoff).
  local epoch ts
  epoch=$(($(date +%s) - 3600))
  ts=$(date -j -r "$epoch" +%Y%m%d-%H%M%S)
  local errfile="$hroot/vault-logs/librarian-cron-error-$ts.md"
  printf '%s\n' \
    "---" \
    "type: log" \
    "log-type: librarian-cron-error" \
    "date: $(date -j -r "$epoch" +%Y-%m-%d)" \
    "---" \
    "" \
    "$(date -j -r "$epoch" -Iseconds) librarian-cron FAIL example" \
    > "$errfile"

  local stdout rc has_json=0 has_banner=0
  stdout=$(HOME="$hroot" "$BANNER" 2>/dev/null)
  rc=$?

  case "$stdout" in
    *hookSpecificOutput*) has_json=1 ;;
  esac
  case "$stdout" in
    *"CRON HEALTH"*) has_banner=1 ;;
  esac

  if [ "$rc" -eq 0 ] && [ "$has_json" -eq 1 ] && [ "$has_banner" -eq 1 ]; then
    pass "recent error fires banner (rc=0 + JSON + CRON HEALTH text)"
  else
    fail "recent error expected rc=0 + JSON + banner, got rc=$rc json=$has_json banner=$has_banner"
    echo "--- stdout ---" >&2
    echo "$stdout" >&2
    echo "--- end stdout ---" >&2
  fi
}

# --- Test 2: empty surfaces → silent (R-41 contents-not-existence) ---
test_empty_surfaces_silent() {
  local hroot="$TEST_ROOT/t2"
  setup_fake_home "$hroot"
  # No fixture files. All 5 surfaces empty.

  local stdout rc
  stdout=$(HOME="$hroot" "$BANNER" 2>/dev/null)
  rc=$?

  if [ "$rc" -eq 0 ] && [ -z "$stdout" ]; then
    pass "empty surfaces → silent (rc=0, no stdout)"
  else
    fail "empty surfaces expected rc=0 + empty stdout, got rc=$rc stdout=[$stdout]"
  fi
}

# --- Test 3: stale (> 24h) cron-error file → silent (R-41) ---
test_stale_error_silent() {
  local hroot="$TEST_ROOT/t3"
  setup_fake_home "$hroot"
  # Create a cron-error file dated 30h ago (past 24h cutoff).
  local epoch ts
  epoch=$(($(date +%s) - 30*3600))
  ts=$(date -j -r "$epoch" +%Y%m%d-%H%M%S)
  local errfile="$hroot/vault-logs/librarian-cron-error-$ts.md"
  printf '%s\n' \
    "---" \
    "type: log" \
    "log-type: librarian-cron-error" \
    "---" \
    "old fail" \
    > "$errfile"

  local stdout rc
  stdout=$(HOME="$hroot" "$BANNER" 2>/dev/null)
  rc=$?

  if [ "$rc" -eq 0 ] && [ -z "$stdout" ]; then
    pass "stale error (>24h) → silent (R-41 contents-not-existence)"
  else
    fail "stale error expected rc=0 + empty stdout, got rc=$rc stdout=[$stdout]"
  fi
}

# --- Test 4: filename-epoch parsing emits parsed timestamp ---
test_filename_epoch_parsing() {
  local hroot="$TEST_ROOT/t4"
  setup_fake_home "$hroot"
  # Fixed timestamp 2 hours ago. Banner output line 192 emits the parsed
  # epoch via `date -r EPOCH "+%Y-%m-%d %H:%M"`. Test asserts that string.
  local epoch ts expected_disp
  epoch=$(($(date +%s) - 7200))
  ts=$(date -j -r "$epoch" +%Y%m%d-%H%M%S)
  expected_disp=$(date -j -r "$epoch" "+%Y-%m-%d %H:%M")
  local errfile="$hroot/vault-logs/architect-cron-error-$ts.md"
  printf '%s\n' \
    "---" \
    "type: log" \
    "log-type: architect-cron-error" \
    "---" \
    "architect fail" \
    > "$errfile"

  local stdout rc has_disp=0
  stdout=$(HOME="$hroot" "$BANNER" 2>/dev/null)
  rc=$?

  case "$stdout" in
    *"$expected_disp"*) has_disp=1 ;;
  esac

  if [ "$rc" -eq 0 ] && [ "$has_disp" -eq 1 ]; then
    pass "filename-epoch parsing emits [$expected_disp]"
  else
    fail "filename-epoch expected [$expected_disp] in stdout, got rc=$rc"
    echo "--- stdout ---" >&2
    echo "$stdout" >&2
    echo "--- end stdout ---" >&2
  fi
}

# --- Run all tests ---
test_recent_error_fires
test_empty_surfaces_silent
test_stale_error_silent
test_filename_epoch_parsing

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
