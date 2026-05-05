#!/bin/bash
# tests/orchestrator/render-launchd-unit-test.sh — synthetic unit tests for SP03 T-11
# installer/render-launchd.sh + installer/bootout-launchd.sh.
#
# Validates:
#   T1 (AC #1): render-launchd librarian → plutil-lint-clean plist with
#     com.claude-stem.librarian-scan label, in staging dir.
#   T2 (AC #1): render-launchd architect → plutil-lint-clean plist with
#     Weekday from schedule.dow[0].
#   T3:        render-launchd production mode → bootout-before-bootstrap
#              call ordering verified via stub trace.
#   T4 (AC #3): bootout-launchd → bootout BEFORE rm. Stub launchctl records
#     plist file existence at bootout time; file must be present.
#   T5 (AC #4): bootout-launchd → only com.claude-stem.* labels get
#     bootout calls; non-foundation labels filtered.
#   T6:        bootout-launchd G6 secondary → tampered plist (filename
#              foundation-prefixed but in-plist Label drifted) preserved
#              with exit rc=56.
#
# AC #2 ("launchctl bootstrap returns 0 on macOS smoke") DEFERRED to SP08
# macOS smoke harness or SP03 T-15 integration test — real launchctl
# would mutate user's actual launchd. Mocked here via PATH-injected stub.
#
# Hermetic: per-test fake $HOME with stub paths.sh + per-test launchctl
# stub on PATH + per-test orchestration.json fixture.
# Bash 3.2 clean (R-23).

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RENDER="$REPO_ROOT/installer/render-launchd.sh"
BOOTOUT="$REPO_ROOT/installer/bootout-launchd.sh"

if [ ! -x "$RENDER" ]; then echo "FAIL: cannot exec $RENDER"; exit 2; fi
if [ ! -x "$BOOTOUT" ]; then echo "FAIL: cannot exec $BOOTOUT"; exit 2; fi

TEST_ROOT="$(mktemp -d -t render-launchd-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1"; }

# Per-test fake $HOME with stub paths.sh + orchestration.json + bin/launchctl.
setup_fake_home() {
  local hroot="$1"
  mkdir -p "$hroot/.claude/hooks/lib" "$hroot/.claude/logs"
  mkdir -p "$hroot/Library/LaunchAgents"
  mkdir -p "$hroot/.claude/Library/LaunchAgents.staging"
  mkdir -p "$hroot/bin"

  cat > "$hroot/.claude/hooks/lib/paths.sh" <<EOF
export CLAUDE_HOME="$hroot/.claude"
export CLAUDE_LOG_DIR="$hroot/.claude/logs"
export ORCHESTRATION_JSON="$hroot/orchestration.json"
EOF

  cat > "$hroot/orchestration.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "platform": "darwin-launchd",
  "jobs": [
    {"id": "librarian", "enabled": true, "schedule": {"hour": 6, "minute": 0}, "command": "x", "log_path": "x", "idle_watchdog_sec": 180},
    {"id": "architect",  "enabled": true, "schedule": {"hour": 22, "minute": 3, "dow": [0]}, "command": "x", "log_path": "x", "idle_watchdog_sec": 180}
  ],
  "tripwires": [],
  "observability": {"morning_brief_staleness_h": 48, "librarian_staleness_h": 24, "sessionstart_banner_staleness_h": 24}
}
EOF
}

# Stub launchctl that records call traces. Variant determines list output.
# Args: $1 = stub path, $2 = list-output mode ("foundation-only"|"mixed"|"empty"|"two-jobs")
make_launchctl_stub() {
  local stub_path="$1" list_mode="$2"
  cat > "$stub_path" <<STUB
#!/bin/bash
LAUNCH_AGENTS="\$HOME/Library/LaunchAgents"
case "\$1" in
  list)
STUB
  case "$list_mode" in
    foundation-only)
      cat >> "$stub_path" <<'STUB'
    printf 'PID\tStatus\tLabel\n100\t0\tcom.claude-stem.librarian-scan\n101\t0\tcom.claude-stem.architect-analysis\n'
STUB
      ;;
    mixed)
      cat >> "$stub_path" <<'STUB'
    printf 'PID\tStatus\tLabel\n50\t0\tcom.apple.something\n51\t0\tcom.user.unrelated\n100\t0\tcom.claude-stem.librarian-scan\n101\t0\tcom.claude-stem.architect-analysis\n'
STUB
      ;;
    empty)
      cat >> "$stub_path" <<'STUB'
    printf 'PID\tStatus\tLabel\n'
STUB
      ;;
    two-jobs)
      cat >> "$stub_path" <<'STUB'
    printf 'PID\tStatus\tLabel\n100\t0\tcom.claude-stem.librarian-scan\n101\t0\tcom.claude-stem.architect-analysis\n'
STUB
      ;;
  esac
  cat >> "$stub_path" <<'STUB'
    ;;
  bootout)
    # Record call. Also record plist-file existence AT TIME OF BOOTOUT
    # (T4 AC #3: bootout BEFORE rm — file must still be present here).
    # $2 format is "gui/501/com.claude-stem.librarian-scan";
    # ${2##*/} strips up to LAST slash → just the label.
    label_path="${2##*/}"
    plist_path="$LAUNCH_AGENTS/$label_path.plist"
    if [ -f "$plist_path" ]; then
      echo "bootout-FILE-PRESENT: $@" >> "$LAUNCHCTL_TRACE"
    else
      echo "bootout-FILE-ABSENT:  $@" >> "$LAUNCHCTL_TRACE"
    fi
    exit 0
    ;;
  bootstrap)
    echo "bootstrap: $@" >> "$LAUNCHCTL_TRACE"
    exit 0
    ;;
  *)
    echo "unknown verb: $@" >> "$LAUNCHCTL_TRACE"
    exit 1
    ;;
esac
STUB
  chmod +x "$stub_path"
}

write_plist() {
  local path="$1" label="$2"
  cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/true</string></array>
</dict>
</plist>
PLIST
}

# --- T1 (AC #1): render-launchd librarian staging → plutil-lint clean ---
test_render_librarian_lint_clean() {
  local hroot="$TEST_ROOT/t1"
  setup_fake_home "$hroot"
  make_launchctl_stub "$hroot/bin/launchctl" empty
  local trace="$hroot/launchctl-trace.log"
  : > "$trace"
  local staging="$hroot/.claude/Library/LaunchAgents.staging"

  HOME="$hroot" PATH="$hroot/bin:$PATH" LAUNCHCTL_TRACE="$trace" \
    bash "$RENDER" --staging-dir "$staging" librarian >/dev/null 2>&1
  local rc=$?

  local final="$staging/com.claude-stem.librarian-scan.plist"
  if [ "$rc" -ne 0 ]; then
    fail "T1: render-launchd rc=$rc (expected 0)"
    return
  fi
  if [ ! -f "$final" ]; then
    fail "T1: expected file not present: $final"
    return
  fi
  if ! plutil -lint -s "$final" >/dev/null 2>&1; then
    fail "T1: plutil -lint rejected $final"
    return
  fi
  if [ -s "$trace" ]; then
    fail "T1: launchctl was called in staging mode (trace non-empty: $(cat "$trace"))"
    return
  fi
  pass "T1 (AC #1): librarian staging render → plutil-lint clean, no launchctl"
}

# --- T2 (AC #1): render-launchd architect staging → plutil-lint clean + Weekday ---
test_render_architect_lint_clean() {
  local hroot="$TEST_ROOT/t2"
  setup_fake_home "$hroot"
  make_launchctl_stub "$hroot/bin/launchctl" empty
  local trace="$hroot/launchctl-trace.log"
  : > "$trace"
  local staging="$hroot/.claude/Library/LaunchAgents.staging"

  HOME="$hroot" PATH="$hroot/bin:$PATH" LAUNCHCTL_TRACE="$trace" \
    bash "$RENDER" --staging-dir "$staging" architect >/dev/null 2>&1
  local rc=$?
  local final="$staging/com.claude-stem.architect-analysis.plist"

  if [ "$rc" -ne 0 ] || [ ! -f "$final" ]; then
    fail "T2: render-launchd architect rc=$rc, file present=$([ -f "$final" ] && echo yes || echo no)"
    return
  fi
  if ! plutil -lint -s "$final" >/dev/null 2>&1; then
    fail "T2: plutil -lint rejected $final"
    return
  fi
  # Verify Weekday integer present (from schedule.dow[0] = 0)
  local weekday
  weekday=$(plutil -extract StartCalendarInterval.Weekday raw -o - "$final" 2>/dev/null)
  if [ "$weekday" != "0" ]; then
    fail "T2: expected Weekday=0, got '$weekday'"
    return
  fi
  pass "T2 (AC #1): architect staging render → plutil-lint clean + Weekday=0"
}

# --- T3: render-launchd production mode → bootout BEFORE bootstrap ---
test_render_bootout_before_bootstrap() {
  local hroot="$TEST_ROOT/t3"
  setup_fake_home "$hroot"
  make_launchctl_stub "$hroot/bin/launchctl" empty
  local trace="$hroot/launchctl-trace.log"
  : > "$trace"

  HOME="$hroot" PATH="$hroot/bin:$PATH" LAUNCHCTL_TRACE="$trace" \
    bash "$RENDER" librarian >/dev/null 2>&1
  local rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "T3: render-launchd production rc=$rc (expected 0)"
    return
  fi

  local first_verb second_verb
  first_verb=$(awk -F: 'NR==1 {print $1; exit}' "$trace" | tr -d ' ')
  second_verb=$(awk -F: 'NR==2 {print $1; exit}' "$trace" | tr -d ' ')

  case "$first_verb" in
    bootout-FILE-PRESENT|bootout-FILE-ABSENT) ;;
    *)
      fail "T3: expected first launchctl verb=bootout, got '$first_verb' (trace: $(cat "$trace"))"
      return
      ;;
  esac
  if [ "$second_verb" != "bootstrap" ]; then
    fail "T3: expected second launchctl verb=bootstrap, got '$second_verb' (trace: $(cat "$trace"))"
    return
  fi
  pass "T3: render-launchd production → bootout BEFORE bootstrap"
}

# --- T4 (AC #3): bootout-launchd → bootout BEFORE rm ---
test_bootout_before_rm() {
  local hroot="$TEST_ROOT/t4"
  setup_fake_home "$hroot"
  # Stub launchctl returns both foundation labels; bootout call records
  # whether plist file was still present at bootout call time. T4 asserts:
  # every bootout call must observe FILE-PRESENT (rm hasn't fired yet).
  make_launchctl_stub "$hroot/bin/launchctl" two-jobs
  local trace="$hroot/launchctl-trace.log"
  : > "$trace"

  write_plist "$hroot/Library/LaunchAgents/com.claude-stem.librarian-scan.plist" "com.claude-stem.librarian-scan"
  write_plist "$hroot/Library/LaunchAgents/com.claude-stem.architect-analysis.plist" "com.claude-stem.architect-analysis"

  HOME="$hroot" PATH="$hroot/bin:$PATH" LAUNCHCTL_TRACE="$trace" \
    bash "$BOOTOUT" >/dev/null 2>&1
  local rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "T4: bootout-launchd rc=$rc (expected 0)"
    return
  fi

  # All bootout entries must show FILE-PRESENT (file existed at bootout time)
  local absent_count present_count
  absent_count=$(grep -c '^bootout-FILE-ABSENT:' "$trace" 2>/dev/null)
  present_count=$(grep -c '^bootout-FILE-PRESENT:' "$trace" 2>/dev/null)
  : "${absent_count:=0}"
  : "${present_count:=0}"
  if [ "$absent_count" -ne 0 ] || [ "$present_count" -lt 2 ]; then
    fail "T4: bootout-BEFORE-rm violated. present=$present_count absent=$absent_count (trace: $(cat "$trace"))"
    return
  fi
  # Files must be removed at end
  if [ -f "$hroot/Library/LaunchAgents/com.claude-stem.librarian-scan.plist" ] || \
     [ -f "$hroot/Library/LaunchAgents/com.claude-stem.architect-analysis.plist" ]; then
    fail "T4: plist files not removed after successful uninstall"
    return
  fi
  pass "T4 (AC #3): bootout BEFORE rm — both bootout calls observed file present, files removed at end"
}

# --- T5 (AC #4): bootout-launchd refuses non-foundation labels ---
test_bootout_g6_filter() {
  local hroot="$TEST_ROOT/t5"
  setup_fake_home "$hroot"
  make_launchctl_stub "$hroot/bin/launchctl" mixed
  local trace="$hroot/launchctl-trace.log"
  : > "$trace"

  # No actual plist files needed — we're testing the launchctl-list filter.
  HOME="$hroot" PATH="$hroot/bin:$PATH" LAUNCHCTL_TRACE="$trace" \
    bash "$BOOTOUT" >/dev/null 2>&1

  # Trace must NOT contain bootout for com.apple.* or com.user.*
  if grep -q 'bootout.*com\.apple\.' "$trace" 2>/dev/null; then
    fail "T5: G6 violation — com.apple.* label was bootout-ed (trace: $(cat "$trace"))"
    return
  fi
  if grep -q 'bootout.*com\.user\.' "$trace" 2>/dev/null; then
    fail "T5: G6 violation — com.user.* label was bootout-ed (trace: $(cat "$trace"))"
    return
  fi
  # Trace MUST contain bootout for both foundation labels
  if ! grep -q 'bootout.*com\.claude-stem\.librarian-scan' "$trace" 2>/dev/null; then
    fail "T5: foundation label librarian-scan was NOT bootout-ed (trace: $(cat "$trace"))"
    return
  fi
  if ! grep -q 'bootout.*com\.claude-stem\.architect-analysis' "$trace" 2>/dev/null; then
    fail "T5: foundation label architect-analysis was NOT bootout-ed (trace: $(cat "$trace"))"
    return
  fi
  pass "T5 (AC #4): bootout-launchd refuses non-com.claude-stem.* labels"
}

# --- T6: G6 secondary refuses rm of tampered plist ---
test_bootout_g6_secondary() {
  local hroot="$TEST_ROOT/t6"
  setup_fake_home "$hroot"
  make_launchctl_stub "$hroot/bin/launchctl" empty
  local trace="$hroot/launchctl-trace.log"
  : > "$trace"

  # Tampered: filename matches foundation prefix, Label inside drifted.
  local tampered="$hroot/Library/LaunchAgents/com.claude-stem.tampered.plist"
  write_plist "$tampered" "com.evil.bar"

  HOME="$hroot" PATH="$hroot/bin:$PATH" LAUNCHCTL_TRACE="$trace" \
    bash "$BOOTOUT" >/dev/null 2>&1
  local rc=$?

  if [ "$rc" -ne 56 ]; then
    fail "T6: expected rc=56 (G6 violation), got rc=$rc"
    return
  fi
  if [ ! -f "$tampered" ]; then
    fail "T6: tampered plist was removed despite G6 secondary guard"
    return
  fi
  pass "T6: G6 secondary — tampered plist (Label drift) preserved with rc=56"
}

# --- run all tests ---
test_render_librarian_lint_clean
test_render_architect_lint_clean
test_render_bootout_before_bootstrap
test_bootout_before_rm
test_bootout_g6_filter
test_bootout_g6_secondary

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
