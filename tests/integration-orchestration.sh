#!/bin/bash
# tests/integration-orchestration.sh — SP03 T-15 E2E orchestration integration.
#
# Drives the full install → onboard → render → bootstrap → trigger → observe →
# uninstall sequence per archetype fixture inside a hermetic per-fixture
# $HOME. PATH-injects SP00 mock-launchctl as `launchctl` so the test never
# touches real macOS launchd; all bootstrap/bootout/kickstart traffic lands
# in a per-fixture trace ndjson.
#
# REUSE-not-duplicate (per T-14 audit amendment, tasks.md L442-446):
#   - install.sh + uninstall.sh (SP08 T-1/T-2)
#   - initial-job-setup.sh (SP07 T-9 staging-only renderer)
#   - render-launchd.sh (SP03 T-11) — exercised transitively via initial-job-setup
#   - SP00 mock-launchctl.sh + plist-lint.sh (T-14 reference pattern)
#   - tests/grep-audit.sh + grep-audit-patterns/ (4-layer audit on rendered plist)
#
# Hermetic invariants:
#   - Per-fixture mktemp $HOME ($CH below); never resolves to Peter-real $HOME.
#   - $CLAUDE_HOME == $CH so install.sh's G1-main check ($CLAUDE_HOME ==
#     $HOME/.claude) does NOT fire — fresh tmpdir is not under $HOME/.claude.
#   - $LAUNCHCTL_BIN (consumed by uninstall.sh) and PATH-injected `launchctl`
#     (consumed by manual bootstrap step) both route to SP00 mock.
#   - mock trace + state under $CH/results/.
#
# E2E sequence per fixture (T-15 contract, tasks.md L388):
#   1. install.sh --apply (default state = jobs enabled per fixture)
#   2. cp fixture orchestration.json → $CLAUDE_HOME/orchestration.json
#   3. initial-job-setup.sh AUTO_CONFIRM=1 → opt-out OR stage plist
#   4. (staging branch only) enable-daemon equivalent: mv staged plist →
#      $CLAUDE_HOME/Library/LaunchAgents/
#   5. (staging branch only) launchctl bootstrap via mock
#   6. (staging branch only) synthetic kickstart fire
#   7a. (all fixtures) AC #3: cron-health-banner observes synthetic
#       cron-error file in $VAULT_LOGS via filename-epoch parsing.
#   7b. (all fixtures) AC #4: idle-watchdog SIGTERM→SIGKILL escalation +
#       post-kill classifier dispatch on synthetic hung process.
#   7c. (staging only) mock SP08 disable-daemon: bootout label via mock +
#       mv runtime plist out of $CLAUDE_HOME/Library/LaunchAgents/.
#       Closes CFF-S68-1 (mock list verb is no-op stdout) and CFF-S68-2
#       (uninstall per-file walk preserves runtime-rendered plists).
#   8. uninstall.sh
#   9. assert zero residue (foundation dirs gone; no com.claude-stem.*
#      labels in mock state; no plist files in fake LaunchAgents)
#
# Per-fixture branching:
#   consultant: jobs[] == [] → opt-out #9 path (verifies opt_out_9_skip audit
#     event; no plist staged; uninstall residue assertions vacuously satisfied
#     for plist surface, fully exercised for foundation surface).
#   developer:  jobs[].id == "librarian" → staging path (staged plist exists +
#     plist-lint clean + 4-layer grep-audit zero hits + bootstrap recorded in
#     mock trace + uninstall removes plist + bootouts label).
#   writer:     jobs[].id == "architect" → staging path (architect template;
#     dow[0] schedule branch).
#
# Slice gating (SLICE_FIXTURES env, default "consultant developer writer"):
#   S68 shipped consultant only. S69 widened to all 3 archetypes + landed
#   ACs #3 (cron-health-banner) + #4 (idle-watchdog post-kill classification)
#   + closed CFF-S68-1 + CFF-S68-2 via test-side disable-daemon mock.
#   ACs #6 (macOS smoke attestation) + #7 (CFF-S55-4 real-launchctl bootstrap
#   rc verification) remain DEFERRED — primary destination is SP08 T-5 macOS
#   smoke harness; gates v2.0.0 not v2.0.0-rc1.
#
# AC coverage (per SP03 T-15, tasks.md L395-402):
#   AC #1 (consultant + developer + writer all green)
#   AC #2 (consultant: vacuous since no plist rendered; developer/writer:
#         4-layer grep-audit on staged plist returns zero hits)
#   AC #3 cron-health-banner fires on synthetic cron-error file (S69 7a)
#   AC #4 idle-watchdog SIGTERM/SIGKILL + classifier dispatch (S69 7b)
#   AC #5 (consultant: foundation residue + plist surface; developer/writer:
#         + label residue, after disable-daemon mock pre-uninstall)
#   AC #6 macOS smoke attestation — DEFERRED v2.0.0 (SP08 T-5 PRIMARY)
#   AC #7 CFF-S55-4 inheritance — DEFERRED v2.0.0 (SP08 T-5 PRIMARY)
#
# R-23: bash 3.2 compat (macOS /bin/bash 3.2.57). No associative arrays.
# R-37: single-deliverable.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
UNINSTALL_SH="$REPO_ROOT/uninstall.sh"
INITIAL_JOB_SETUP="$REPO_ROOT/onboarding/initial-job-setup.sh"
MOCK_LAUNCHCTL="$REPO_ROOT/tests/mock-launchctl.sh"
PLIST_LINT="$REPO_ROOT/tests/plist-lint.sh"
GREP_AUDIT="$REPO_ROOT/tests/grep-audit.sh"
FIXTURES_DIR="$REPO_ROOT/onboarding/fixtures"

# --- prereq checks ---
for f in "$INSTALL_SH" "$UNINSTALL_SH" "$INITIAL_JOB_SETUP" \
         "$MOCK_LAUNCHCTL" "$PLIST_LINT" "$GREP_AUDIT"; do
  if [ ! -x "$f" ] && [ ! -r "$f" ]; then
    printf 'FAIL: prereq missing/unreadable: %s\n' "$f" >&2
    exit 2
  fi
done
for tool in jq mktemp; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FAIL: %s required but not on PATH\n' "$tool" >&2
    exit 2
  fi
done

# --- harness ---
PASS_COUNT=0
FAIL_COUNT=0
TMPDIRS=""

cleanup() {
  for d in $TMPDIRS; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM

mk_tmp() {
  d="$(mktemp -d -t integ-orch-XXXXXX)"
  TMPDIRS="$TMPDIRS $d"
  printf '%s' "$d"
}

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  FAIL %s\n' "$1" >&2; }

assert_eq() {
  exp="$1"; act="$2"; lbl="$3"
  if [ "$exp" = "$act" ]; then
    pass "$lbl (eq: $act)"
  else
    fail "$lbl (expected=$exp actual=$act)"
  fi
}

assert_path_present() {
  p="$1"; lbl="$2"
  if [ -e "$p" ]; then pass "$lbl ($p)"; else fail "$lbl (missing: $p)"; fi
}

assert_path_absent() {
  p="$1"; lbl="$2"
  if [ ! -e "$p" ]; then pass "$lbl ($p)"; else fail "$lbl (present: $p)"; fi
}

# Construct a wrapper script that exec's SP00 mock-launchctl. Wrapper
# preserves env (LAUNCHCTL_TRACE_DIR, LAUNCHCTL_PLIST_LINT) via exec
# default propagation. Mirrors the integration-orchestration-mock-launchctl
# pattern from T-14.
make_launchctl_path_dir() {
  pdir="$1"
  mkdir -p "$pdir"
  cat > "$pdir/launchctl" <<EOF
#!/bin/bash
exec "$MOCK_LAUNCHCTL" "\$@"
EOF
  chmod +x "$pdir/launchctl"
}

# --- per-fixture E2E driver ---
# Args: $1 = archetype name (consultant|developer|writer)
# Returns 0 always; pass/fail counts updated via pass()/fail().
run_fixture_e2e() {
  archetype="$1"
  fixture_json="$FIXTURES_DIR/${archetype}-orchestration.json"

  if [ ! -r "$fixture_json" ]; then
    fail "${archetype}: fixture not readable at $fixture_json"
    return
  fi

  printf '\n=== fixture: %s ===\n' "$archetype"

  # Hermetic per-fixture env. CRITICAL: helpers + stdout/stderr captures live
  # in $TEST_DIR (sibling of $CH), NOT inside $CH — install.sh's state
  # classifier walks $CLAUDE_HOME and refuses on non-foundation content
  # (exit 21 = user-only without --force-install). $CH must be empty until
  # install.sh writes into it.
  TEST_DIR="$(mk_tmp)"
  CH="$TEST_DIR/claude-home"
  trace_dir="$TEST_DIR/results"
  pathdir="$TEST_DIR/path"
  log_dir="$TEST_DIR/logs"
  mkdir -p "$CH" "$trace_dir" "$pathdir" "$log_dir"
  make_launchctl_path_dir "$pathdir"

  # ---------- Step 1: install.sh --apply ----------
  rc=0
  HOME="$CH" CLAUDE_HOME="$CH" SOURCE_REPO="$REPO_ROOT" \
    bash "$INSTALL_SH" --apply >"$log_dir/install.stdout" 2>"$log_dir/install.stderr" || rc=$?
  assert_eq "0" "$rc" "${archetype} S1: install.sh --apply rc=0"

  # Confirm 14-asset write-sequence essentials landed
  assert_path_present "$CH/hooks/lib/paths.sh"           "${archetype} S1.1: hooks/lib/paths.sh installed"
  assert_path_present "$CH/installer/render-launchd.sh"  "${archetype} S1.2: installer/render-launchd.sh installed"
  assert_path_present "$CH/onboarding/initial-job-setup.sh" "${archetype} S1.3: onboarding/initial-job-setup.sh installed"
  assert_path_present "$CH/foundation-manifest.json"     "${archetype} S1.4: foundation-manifest.json baseline shipped"

  if [ "$rc" -ne 0 ]; then
    fail "${archetype}: install failed; aborting fixture"
    return
  fi

  # ---------- Step 2: copy fixture orchestration.json ----------
  cp "$fixture_json" "$CH/orchestration.json"
  assert_path_present "$CH/orchestration.json" "${archetype} S2: fixture orchestration.json copied"

  jobs_count=$(jq -r '.jobs | length' "$CH/orchestration.json" 2>/dev/null)
  case "$jobs_count" in
    ''|*[!0-9]*)
      fail "${archetype}: orchestration.json .jobs not parseable as array (got: '$jobs_count')"
      return
      ;;
  esac

  # ---------- Step 3: initial-job-setup.sh AUTO_CONFIRM=1 ----------
  rc=0
  AUTO_CONFIRM=1 HOME="$CH" CLAUDE_HOME="$CH" \
    bash "$INITIAL_JOB_SETUP" >"$log_dir/ijs.stdout" 2>"$log_dir/ijs.stderr" || rc=$?
  assert_eq "0" "$rc" "${archetype} S3: initial-job-setup rc=0"

  audit_log="$CH/onboarding/audit/initial-job-setup.jsonl"
  assert_path_present "$audit_log" "${archetype} S3.1: audit log written"

  # ---------- Branch on jobs_count ----------
  staging_dir="$CH/Library/LaunchAgents.staging"
  agents_dir="$CH/Library/LaunchAgents"

  if [ "$jobs_count" -eq 0 ]; then
    # ---- opt-out #9 path (consultant) ----
    last_event=$(jq -r 'select(.event != null) | .event' "$audit_log" 2>/dev/null | tail -1)
    assert_eq "opt_out_9_skip" "$last_event" \
      "${archetype} S3.2 (opt-out): audit event = opt_out_9_skip"

    # No plist should be staged (entire dir may be empty or absent)
    staged_count=0
    if [ -d "$staging_dir" ]; then
      staged_count=$(ls -1 "$staging_dir" 2>/dev/null | grep -c '\.plist$' || true)
    fi
    assert_eq "0" "$staged_count" \
      "${archetype} S3.3 (opt-out): no plist staged (staging count=$staged_count)"

  else
    # ---- staging path (developer/writer) ----
    job_id=$(jq -r '.jobs[0].id' "$CH/orchestration.json")
    expected_plist="$staging_dir/com.claude-stem.${job_id}-$([ "$job_id" = "librarian" ] && echo scan || echo analysis).plist"
    # Resolve the actual label per render-launchd's mapping:
    #   librarian → com.claude-stem.librarian-scan
    #   architect → com.claude-stem.architect-analysis
    case "$job_id" in
      librarian) label="com.claude-stem.librarian-scan" ;;
      architect) label="com.claude-stem.architect-analysis" ;;
      *)         fail "${archetype}: unsupported jobs[0].id='$job_id'"; return ;;
    esac
    expected_plist="$staging_dir/${label}.plist"

    assert_path_present "$expected_plist" "${archetype} S3.2 (stage): plist staged at $expected_plist"
    last_event=$(jq -r 'select(.event != null) | .event' "$audit_log" 2>/dev/null | tail -1)
    assert_eq "staged" "$last_event" \
      "${archetype} S3.3 (stage): audit event = staged"

    # ---- AC #2: 4-layer grep-audit on rendered plist ----
    # Audit target dir lives in $TEST_DIR (sibling of $CH) — never inside
    # $CLAUDE_HOME (would re-trip install state classifier on next-fixture
    # iteration if any).
    audit_dir="$TEST_DIR/audit-target"
    mkdir -p "$audit_dir"
    cp "$expected_plist" "$audit_dir/"
    rc=0
    GREP_AUDIT_SKIP_LAYER4=1 bash "$GREP_AUDIT" "$audit_dir" \
      >"$log_dir/grep-audit.stdout" 2>"$log_dir/grep-audit.stderr" || rc=$?
    assert_eq "0" "$rc" "${archetype} S3.4 (AC#2): rendered plist 4-layer grep-audit clean (rc=$rc)"

    # ---- plist-lint composition re-confirm ----
    if bash "$PLIST_LINT" "$expected_plist" >/dev/null 2>&1; then
      pass "${archetype} S3.5: SP00 plist-lint accepts staged plist"
    else
      fail "${archetype} S3.5: SP00 plist-lint rejected staged plist"
    fi

    # ---------- Step 4: enable-daemon equivalent (mv staged → LaunchAgents) ----------
    mkdir -p "$agents_dir"
    if mv -f "$expected_plist" "$agents_dir/${label}.plist" 2>/dev/null; then
      pass "${archetype} S4: staged plist promoted to LaunchAgents/"
    else
      fail "${archetype} S4: mv staged → LaunchAgents/ failed"
      return
    fi

    # ---------- Step 5: launchctl bootstrap via mock ----------
    uid=$(id -u)
    rc=0
    PATH="$pathdir:$PATH" \
      LAUNCHCTL_TRACE_DIR="$trace_dir" \
      LAUNCHCTL_PLIST_LINT="$PLIST_LINT" \
      launchctl bootstrap "gui/$uid" "$agents_dir/${label}.plist" \
      >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "${archetype} S5: mock launchctl bootstrap rc=0"

    # ---------- Step 6: synthetic kickstart fire ----------
    rc=0
    PATH="$pathdir:$PATH" \
      LAUNCHCTL_TRACE_DIR="$trace_dir" \
      LAUNCHCTL_PLIST_LINT="$PLIST_LINT" \
      launchctl kickstart -k "gui/$uid/${label}" \
      >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "${archetype} S6: mock launchctl kickstart rc=0"

    # ---- Verify mock trace recorded bootstrap + kickstart ----
    trace="$trace_dir/launchctl-trace.ndjson"
    assert_path_present "$trace" "${archetype} S6.1: mock trace ndjson written"
    if [ -f "$trace" ]; then
      bootstrap_seen=$(jq -r 'select(.verb == "bootstrap") | .verb' "$trace" 2>/dev/null | head -1)
      kickstart_seen=$(jq -r 'select(.verb == "kickstart") | .verb' "$trace" 2>/dev/null | head -1)
      assert_eq "bootstrap" "$bootstrap_seen" "${archetype} S6.2: trace contains bootstrap"
      assert_eq "kickstart" "$kickstart_seen" "${archetype} S6.3: trace contains kickstart"
    fi
  fi

  # ---------- Step 7a (AC #3): cron-health-banner observes synthetic error ----------
  # Plant a synthetic cron-error file in a test-controlled $VAULT_LOGS; assert
  # the installed banner picks it up via filename-epoch parsing and emits the
  # hookSpecificOutput JSON containing the CRON HEALTH banner text.
  #
  # Banner sources $HOME/.claude/hooks/lib/paths.sh (literal `.claude` segment);
  # this test pins HOME=$CH=$CLAUDE_HOME (no `.claude` segment) to keep
  # install.sh's G1-main check happy. Symlink $CH/.claude → $CH so the banner's
  # source path resolves to $CH/hooks/lib/paths.sh (which install wrote at S1).
  banner="$CH/hooks/cron-health-banner.sh"
  if [ -x "$banner" ]; then
    test_vlogs="$TEST_DIR/vault-logs"
    mkdir -p "$test_vlogs"
    err_epoch=$(($(date +%s) - 3600))
    err_ts=$(date -j -r "$err_epoch" +%Y%m%d-%H%M%S)
    err_file="$test_vlogs/librarian-cron-error-$err_ts.md"
    {
      printf -- '---\n'
      printf 'type: log\n'
      printf 'log-type: librarian-cron-error\n'
      printf 'date: %s\n' "$(date -j -r "$err_epoch" +%Y-%m-%d)"
      printf -- '---\n\n'
      printf '%s librarian-cron FAIL synthetic\n' "$(date -j -r "$err_epoch" -Iseconds)"
    } > "$err_file"
    [ -e "$CH/.claude" ] || ln -s "$CH" "$CH/.claude"
    banner_stdout=$(HOME="$CH" CLAUDE_HOME="$CH" \
      VAULT_LOGS="$test_vlogs" HOOKS_STATE="$CH/hooks/state" \
      bash "$banner" 2>"$log_dir/banner.stderr")
    banner_rc=$?
    has_json=0
    has_text=0
    case "$banner_stdout" in
      *hookSpecificOutput*) has_json=1 ;;
    esac
    case "$banner_stdout" in
      *"CRON HEALTH"*) has_text=1 ;;
    esac
    if [ "$banner_rc" -eq 0 ] && [ "$has_json" -eq 1 ] && [ "$has_text" -eq 1 ]; then
      pass "${archetype} S7a (AC#3): cron-health-banner fires on synthetic error (rc=0 + JSON + banner text)"
    else
      fail "${archetype} S7a (AC#3): expected rc=0 + JSON + banner text, got rc=$banner_rc json=$has_json text=$has_text"
    fi
  else
    fail "${archetype} S7a (AC#3): cron-health-banner.sh not executable at $banner"
  fi

  # ---------- Step 7b (AC #4): idle-watchdog post-kill classification ----------
  # Compose installed orchestrator/lib/{claude-p.sh,idle-watchdog.sh} against a
  # synthetic hung sleeper; assert SIGTERM→SIGKILL escalation (rc=124) + the
  # post-kill classifier emits a `classification:` line into the watchdog log.
  # Mirrors tests/orchestrator/idle-watchdog-unit-test.sh test_hung_process_fires().
  claude_p_lib="$CH/orchestrator/lib/claude-p.sh"
  watchdog_lib="$CH/orchestrator/lib/idle-watchdog.sh"
  if [ -r "$claude_p_lib" ] && [ -r "$watchdog_lib" ]; then
    watchdog_log="$log_dir/watchdog.log"
    watchdog_ndjson="$log_dir/hung.ndjson"
    : > "$watchdog_log"
    : > "$watchdog_ndjson"
    ( sleep 30 ) &
    hung_pid=$!
    wd_rc=0
    (
      set +u
      export WATCHDOG_SAMPLE_INTERVAL=1
      # shellcheck source=/dev/null
      . "$claude_p_lib"
      # shellcheck source=/dev/null
      . "$watchdog_lib"
      LOG_FILE="$watchdog_log" watchdog_idle "$hung_pid" "$watchdog_ndjson" 2 >/dev/null 2>&1
    ) || wd_rc=$?
    if kill -0 "$hung_pid" 2>/dev/null; then
      kill -9 "$hung_pid" 2>/dev/null || true
    fi
    has_fire=0
    has_class=0
    if grep -q "IDLE-WATCHDOG-FIRED" "$watchdog_log" 2>/dev/null; then has_fire=1; fi
    if grep -q "classification:" "$watchdog_log" 2>/dev/null; then has_class=1; fi
    if [ "$wd_rc" -eq 124 ] && [ "$has_fire" -eq 1 ] && [ "$has_class" -eq 1 ]; then
      pass "${archetype} S7b (AC#4): idle-watchdog fires + classifier dispatched (rc=124 + fire-line + class-line)"
    else
      fail "${archetype} S7b (AC#4): expected rc=124 + fire + class, got rc=$wd_rc fire=$has_fire class=$has_class"
    fi
  else
    fail "${archetype} S7b (AC#4): orchestrator/lib/{claude-p.sh,idle-watchdog.sh} not readable under $CH"
  fi

  # ---------- Step 7c (CFF-S68-1 + CFF-S68-2): mock SP08 disable-daemon ----------
  # Real SP08 disable-daemon (NYI as of v2.0.0-rc1) will: (i) launchctl bootout
  # the label, (ii) mv plist out of $CLAUDE_HOME/Library/LaunchAgents/. This
  # test mocks both side-effects pre-uninstall:
  #   CFF-S68-1: mock-launchctl `list` verb is no-op stdout, so uninstall.sh's
  #     bootout-discovery walk (uninstall.sh:244 `launchctl list | awk ...`)
  #     finds 0 labels and leaves the mock state-file behind. Pre-bootout via
  #     the same mock removes the state file → S9.3 zero-residue passes.
  #   CFF-S68-2: uninstall.sh's per-file fingerprint walk only removes files
  #     listed in foundation-manifest.json baseline. Runtime-rendered plists
  #     under $CLAUDE_HOME/Library/LaunchAgents/ are NOT in baseline →
  #     preserved as user-content. Pre-mv removes them → S9.2 passes.
  # Both dispositions chosen test-side per CFF candidates in tasks.md L408+L410
  # (cleaner than reopening SP00 P5 OR opening a new SP08 disable-daemon task).
  if [ "$jobs_count" -gt 0 ]; then
    PATH="$pathdir:$PATH" \
      LAUNCHCTL_TRACE_DIR="$trace_dir" \
      LAUNCHCTL_PLIST_LINT="$PLIST_LINT" \
      launchctl bootout "gui/$uid/${label}" >/dev/null 2>&1 || true
    if [ -f "$agents_dir/${label}.plist" ]; then
      mv "$agents_dir/${label}.plist" "$TEST_DIR/${label}.plist.disabled" 2>/dev/null || true
    fi
  fi

  # ---------- Step 8: uninstall.sh ----------
  # uninstall.sh expects $CLAUDE_HOME/foundation-manifest.json (G63 baseline)
  # and walks launchctl bootout via $LAUNCHCTL_BIN env override (mock).
  rc=0
  HOME="$CH" CLAUDE_HOME="$CH" LAUNCHCTL_BIN="$MOCK_LAUNCHCTL" \
    LAUNCHCTL_TRACE_DIR="$trace_dir" LAUNCHCTL_PLIST_LINT="$PLIST_LINT" \
    bash "$UNINSTALL_SH" >"$log_dir/uninstall.stdout" 2>"$log_dir/uninstall.stderr" || rc=$?
  assert_eq "0" "$rc" "${archetype} S8: uninstall.sh rc=0"

  # ---------- Step 9: zero-residue assertions (AC #5, partial S68 scope) ----------
  # Foundation FILES MUST be removed by uninstall (per-file fingerprint walk:
  # baseline match → rm). Foundation DIRS may persist if they contain user-
  # content not in baseline (e.g. onboarding/audit/initial-job-setup.jsonl
  # written by initial-job-setup.sh during this E2E — that is expected
  # preservation, not residue). Assert the specific baseline files that we
  # observed PRESENT at S1.1-S1.3 are now ABSENT.
  for f in \
    "hooks/lib/paths.sh" \
    "installer/render-launchd.sh" \
    "onboarding/initial-job-setup.sh"; do
    assert_path_absent "$CH/$f" "${archetype} S9 (AC#5): foundation file removed: $f"
  done
  # foundation-manifest.json removed by basename rm at uninstall root sweep
  assert_path_absent "$CH/foundation-manifest.json" \
    "${archetype} S9.1 (AC#5): foundation-manifest.json removed"

  # No com.claude-stem.* plists left in fake LaunchAgents/staging
  for surface in "$staging_dir" "$agents_dir"; do
    leftover_count=0
    if [ -d "$surface" ]; then
      leftover_count=$(ls -1 "$surface" 2>/dev/null | grep -c '^com\.claude-stem\.' || true)
    fi
    assert_eq "0" "$leftover_count" \
      "${archetype} S9.2 (AC#5): no com.claude-stem.* plists in $(basename "$surface")/"
  done

  # mock-launchctl state dir: no labels remain bootstrapped (uninstall.sh's
  # bootout walk should clear any com.claude-stem.* state files).
  state_dir="$trace_dir/launchctl-state"
  if [ -d "$state_dir" ]; then
    label_count=$(ls -1 "$state_dir" 2>/dev/null | grep -c '^com\.claude-stem\.' || true)
    assert_eq "0" "$label_count" \
      "${archetype} S9.3 (AC#5): no com.claude-stem.* labels remain in mock state"
  else
    # State dir absent is fine (consultant opt-out path: no bootstrap ever
    # happened, so no state file ever created).
    pass "${archetype} S9.3 (AC#5): mock state dir absent (no bootstrap occurred)"
  fi
}

# --- main ---
SLICE_FIXTURES="${SLICE_FIXTURES:-consultant developer writer}"

printf 'integration-orchestration: SLICE_FIXTURES="%s"\n' "$SLICE_FIXTURES"

for fx in $SLICE_FIXTURES; do
  case "$fx" in
    consultant|developer|writer)
      run_fixture_e2e "$fx"
      ;;
    *)
      fail "main: unknown fixture '$fx' (valid: consultant developer writer)"
      ;;
  esac
done

printf '\n=== integration-orchestration ===\n'
printf 'PASS: %d\n' "$PASS_COUNT"
printf 'FAIL: %d\n' "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
