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
#   7. (deferred S69) cron-health-banner + librarian-cron + morning-brief
#      observation; cold-wake probe; post-kill classification
#   8. uninstall.sh
#   9. assert zero residue (foundation dirs gone; no com.claude-foundations.*
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
# Slice gating (SLICE_FIXTURES env, default "consultant"):
#   S68 ships consultant only. S69 sets SLICE_FIXTURES="consultant developer
#   writer" and lands ACs #3 (cold-wake), #4 (post-kill), #6 (macOS smoke
#   attestation), #7 (CFF-S55-4 inheritance).
#
# AC coverage (per SP03 T-15, tasks.md L395-402):
#   AC #1 (consultant slice partial; full = SLICE_FIXTURES widened in S69)
#   AC #2 (consultant: vacuous since no plist rendered; developer/writer:
#         4-layer grep-audit on staged plist returns zero hits)
#   AC #3 cold-wake probe — DEFERRED S69
#   AC #4 post-kill classification — DEFERRED S69
#   AC #5 (consultant: foundation residue + plist surface; developer/writer:
#         + label residue)
#   AC #6 macOS smoke attestation — DEFERRED S69 (gates v2.0.0 not v2.0.0-rc1)
#   AC #7 CFF-S55-4 inheritance — DEFERRED S69 (SP08 T-5 PRIMARY)
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
    expected_plist="$staging_dir/com.claude-foundations.${job_id}-$([ "$job_id" = "librarian" ] && echo scan || echo analysis).plist"
    # Resolve the actual label per render-launchd's mapping:
    #   librarian → com.claude-foundations.librarian-scan
    #   architect → com.claude-foundations.architect-analysis
    case "$job_id" in
      librarian) label="com.claude-foundations.librarian-scan" ;;
      architect) label="com.claude-foundations.architect-analysis" ;;
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

  # No com.claude-foundations.* plists left in fake LaunchAgents/staging
  for surface in "$staging_dir" "$agents_dir"; do
    leftover_count=0
    if [ -d "$surface" ]; then
      leftover_count=$(ls -1 "$surface" 2>/dev/null | grep -c '^com\.claude-foundations\.' || true)
    fi
    assert_eq "0" "$leftover_count" \
      "${archetype} S9.2 (AC#5): no com.claude-foundations.* plists in $(basename "$surface")/"
  done

  # mock-launchctl state dir: no labels remain bootstrapped (uninstall.sh's
  # bootout walk should clear any com.claude-foundations.* state files).
  state_dir="$trace_dir/launchctl-state"
  if [ -d "$state_dir" ]; then
    label_count=$(ls -1 "$state_dir" 2>/dev/null | grep -c '^com\.claude-foundations\.' || true)
    assert_eq "0" "$label_count" \
      "${archetype} S9.3 (AC#5): no com.claude-foundations.* labels remain in mock state"
  else
    # State dir absent is fine (consultant opt-out path: no bootstrap ever
    # happened, so no state file ever created).
    pass "${archetype} S9.3 (AC#5): mock state dir absent (no bootstrap occurred)"
  fi
}

# --- main ---
SLICE_FIXTURES="${SLICE_FIXTURES:-consultant}"

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
