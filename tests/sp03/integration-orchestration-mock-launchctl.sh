#!/bin/bash
# tests/sp03/integration-orchestration-mock-launchctl.sh — SP03 T-14
# integration verification: SP03 wrappers + dispatch.sh + render-launchd.sh
# interact correctly with SP00-shipped mock-launchctl.sh + plist-lint.sh.
#
# REUSE pattern (no new stub implementations):
#   - PATH-injects SP00 tests/mock-launchctl.sh as `launchctl` via a thin
#     wrapper script in a per-test PATH dir. The wrapper exec's the mock so
#     env (LAUNCHCTL_TRACE_DIR, LAUNCHCTL_PLIST_LINT) propagates through.
#   - Sets LAUNCHCTL_PLIST_LINT explicitly to bypass mock's `readlink -f`
#     resolution (BSD readlink on macOS lacks -f; mock falls back to
#     BASH_SOURCE-relative resolution but the explicit env is more robust).
#   - Re-confirms SP00 plist-lint.sh accepts render-launchd's staged output
#     (composition with the SP00 lint shim, distinct from render-launchd-
#     unit-test.sh T1+T2 which use plutil directly).
#
# AC coverage (per SP03 T-14, tasks.md L369-376):
#   IT1 (AC #2 + AC #3):
#     render-launchd librarian production mode → mock trace ndjson row 1 =
#     {verb:bootout, exit:0}, row 2 = {verb:bootstrap, exit:0}; both rows
#     have non-empty argv arrays (records bootout-then-bootstrap lifecycle).
#   IT2 (AC #1):
#     SP00 plist-lint.sh directly accepts render-launchd's staged plist.
#   IT3 (AC #4 known verbs):
#     SP00 mock returns exit 0 for bootout/print/list/kickstart.
#   IT4 (AC #4 unknown verb):
#     SP00 mock returns exit 3 for an unknown verb (typo guard).
#
#   AC #5 (handoff to SP08 tasks T-4a..T-4f) is doc-side; covered by SP03
#     tasks.md T-14 closure note + SP08 tasks.md cross-reference at S57 c2.
#
# Intentionally not covered here (deferred per spec):
#   - Architect job production render — symmetry already covered by
#     render-launchd-unit-test.sh T2.
#   - Real launchctl bootstrap on macOS — CFF-S55-4 routes AC #2 to SP08 T-5
#     PRIMARY + SP03 T-15 SECONDARY FALLBACK.
#   - Lima/sandbox-exec/MOCK_LAUNCHCTL container path — SP08 T-4a..T-4f own.
#
# Hermetic: per-test mktemp; isolated $HOME, PATH, LAUNCHCTL_TRACE_DIR.
# Bash 3.2 clean (R-23).

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RENDER="$REPO_ROOT/installer/render-launchd.sh"
MOCK="$REPO_ROOT/tests/mock-launchctl.sh"
LINT="$REPO_ROOT/tests/plist-lint.sh"

if [ ! -x "$RENDER" ]; then echo "FAIL: cannot exec $RENDER"; exit 2; fi
if [ ! -x "$MOCK" ];   then echo "FAIL: cannot exec $MOCK";   exit 2; fi
if [ ! -x "$LINT" ];   then echo "FAIL: cannot exec $LINT";   exit 2; fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq required by SP00 mock-launchctl trace emitter"
  exit 2
fi

TEST_ROOT="$(mktemp -d -t sp03-integ-mock-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1"; }

# Per-test fake $HOME with stub paths.sh + orchestration.json.
# Mirrors render-launchd-unit-test.sh setup_fake_home (librarian-only).
setup_fake_home() {
  hroot="$1"
  mkdir -p "$hroot/.claude/hooks/lib" "$hroot/.claude/logs"
  mkdir -p "$hroot/Library/LaunchAgents"
  mkdir -p "$hroot/.claude/Library/LaunchAgents.staging"

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
    {"id": "librarian", "enabled": true, "schedule": {"hour": 6, "minute": 0}, "command": "x", "log_path": "x", "idle_watchdog_sec": 180}
  ],
  "tripwires": [],
  "observability": {"morning_brief_staleness_h": 48, "librarian_staleness_h": 24, "sessionstart_banner_staleness_h": 24}
}
EOF
}

# Wrapper script that exec's SP00 mock as `launchctl`. Wrapper preserves env
# (including LAUNCHCTL_TRACE_DIR + LAUNCHCTL_PLIST_LINT) via exec's default
# env propagation.
make_launchctl_path_dir() {
  dir="$1"
  mkdir -p "$dir"
  cat > "$dir/launchctl" <<EOF
#!/bin/bash
exec "$MOCK" "\$@"
EOF
  chmod +x "$dir/launchctl"
}

# --- IT1 (AC #2 + AC #3): render-launchd → mock trace bootout-then-bootstrap ---
test_render_via_sp00_mock() {
  hroot="$TEST_ROOT/it1"
  setup_fake_home "$hroot"
  pathdir="$hroot/.path"
  make_launchctl_path_dir "$pathdir"
  trace_dir="$hroot/results"
  mkdir -p "$trace_dir"

  HOME="$hroot" PATH="$pathdir:$PATH" \
    LAUNCHCTL_TRACE_DIR="$trace_dir" \
    LAUNCHCTL_PLIST_LINT="$LINT" \
    bash "$RENDER" librarian </dev/null >/dev/null 2>&1
  rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "IT1: render-launchd production rc=$rc (expected 0)"
    return
  fi

  trace="$trace_dir/launchctl-trace.ndjson"
  if [ ! -f "$trace" ]; then
    fail "IT1: mock trace ndjson not written at $trace"
    return
  fi

  line_count=$(wc -l < "$trace" | tr -d ' ')
  if [ "$line_count" -lt 2 ]; then
    fail "IT1: expected >=2 trace lines, got $line_count (trace: $(cat "$trace"))"
    return
  fi

  first_verb=$(jq -r '.verb' < "$trace" | sed -n '1p')
  second_verb=$(jq -r '.verb' < "$trace" | sed -n '2p')
  first_exit=$(jq -r '.exit' < "$trace" | sed -n '1p')
  second_exit=$(jq -r '.exit' < "$trace" | sed -n '2p')
  first_argv_len=$(jq -r '.argv | length' < "$trace" | sed -n '1p')
  second_argv_len=$(jq -r '.argv | length' < "$trace" | sed -n '2p')

  if [ "$first_verb" != "bootout" ]; then
    fail "IT1: expected first verb=bootout, got '$first_verb' (trace: $(cat "$trace"))"
    return
  fi
  if [ "$second_verb" != "bootstrap" ]; then
    fail "IT1: expected second verb=bootstrap, got '$second_verb' (trace: $(cat "$trace"))"
    return
  fi
  if [ "$first_exit" != "0" ] || [ "$second_exit" != "0" ]; then
    fail "IT1: expected both exits=0, got first=$first_exit second=$second_exit"
    return
  fi
  # AC #2: argv must be recorded for both invocations.
  # bootout argv = [bootout, gui/<uid>/<label>] → len 2.
  # bootstrap argv = [bootstrap, gui/<uid>, /path/to/plist] → len 3.
  if [ "$first_argv_len" -lt 2 ] || [ "$second_argv_len" -lt 3 ]; then
    fail "IT1: argv length insufficient (first=$first_argv_len second=$second_argv_len; trace: $(cat "$trace"))"
    return
  fi

  pass "IT1 (AC #2 + AC #3): render-launchd → mock trace bootout(exit 0) → bootstrap(exit 0); argv recorded"
}

# --- IT2 (AC #1): SP00 plist-lint accepts render-launchd's staged plist ---
test_plist_lint_accepts_render_output() {
  hroot="$TEST_ROOT/it2"
  setup_fake_home "$hroot"
  staging="$hroot/.claude/Library/LaunchAgents.staging"

  HOME="$hroot" \
    bash "$RENDER" --staging-dir "$staging" librarian </dev/null >/dev/null 2>&1
  rc=$?
  plist="$staging/com.claude-stem.librarian-scan.plist"

  if [ "$rc" -ne 0 ] || [ ! -f "$plist" ]; then
    file_present=no
    [ -f "$plist" ] && file_present=yes
    fail "IT2: render-launchd staging rc=$rc, file present=$file_present"
    return
  fi

  if ! bash "$LINT" "$plist" >/dev/null 2>&1; then
    fail "IT2: SP00 plist-lint.sh rejected render-launchd output ($plist)"
    return
  fi

  pass "IT2 (AC #1): SP00 plist-lint.sh accepts render-launchd's staged plist"
}

# --- IT3 (AC #4 known verbs): mock returns exit 0 for known verbs ---
test_mock_known_verbs() {
  hroot="$TEST_ROOT/it3"
  trace_dir="$hroot/results"
  mkdir -p "$trace_dir"

  for v in bootout print list kickstart; do
    LAUNCHCTL_TRACE_DIR="$trace_dir" LAUNCHCTL_PLIST_LINT="$LINT" \
      bash "$MOCK" "$v" gui/501/com.claude-stem.librarian-scan </dev/null >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      fail "IT3: mock verb=$v expected rc=0, got rc=$rc"
      return
    fi
  done

  pass "IT3 (AC #4 known verbs): mock returns exit 0 for bootout/print/list/kickstart"
}

# --- IT4 (AC #4 unknown verb): mock returns exit 3 for typo'd verb ---
test_mock_unknown_verb() {
  hroot="$TEST_ROOT/it4"
  trace_dir="$hroot/results"
  mkdir -p "$trace_dir"

  LAUNCHCTL_TRACE_DIR="$trace_dir" LAUNCHCTL_PLIST_LINT="$LINT" \
    bash "$MOCK" not-a-real-verb foo </dev/null >/dev/null 2>&1
  rc=$?

  if [ "$rc" -ne 3 ]; then
    fail "IT4: mock unknown verb expected rc=3, got rc=$rc"
    return
  fi

  pass "IT4 (AC #4 unknown verb): mock returns exit 3 for unknown verb"
}

# --- run all tests ---
test_render_via_sp00_mock
test_plist_lint_accepts_render_output
test_mock_known_verbs
test_mock_unknown_verb

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
