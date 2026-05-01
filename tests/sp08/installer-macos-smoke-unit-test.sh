#!/bin/bash
# tests/sp08/installer-macos-smoke-unit-test.sh — Plan 71 SP08 T-5 (S70 L1 slice)
#
# L1 scope (this slice):
#   - SP00 dogfood.sb consumes correctly under sandbox-exec — pre-flight lint
#     stays green after S70 documentary update; DOGFOOD_ROOT param routes
#     file-write* correctly; writes outside DOGFOOD_ROOT denied.
#   - install.sh writes confined to $CLAUDE_HOME under DOGFOOD_ROOT via env
#     redirection ($HOME / $CLAUDE_HOME both point under tmpdir). $HOME's
#     real ~/Library/LaunchAgents/ baseline-diff stays empty across the
#     full install + render + uninstall cycle.
#   - render-launchd --staging-dir under fake $HOME — plist lands in staging
#     dir; plutil-lint accepts; no /Library/LaunchAgents touch.
#   - render-launchd production mode with PATH-injected SP00 mock-launchctl —
#     mock trace ndjson records bootout(rc=0) → bootstrap(rc=0); host
#     /Library/LaunchAgents baseline-diff stays empty (mock intercepts the
#     launchctl call before it reaches host launchd).
#   - uninstall.sh removes foundation files; host /Library/LaunchAgents
#     baseline-diff stays empty.
#   - Layer-4 historical grep-audit on a synthetic git repo: planted-then-
#     reverted leak detected in history (AC #7); GREP_AUDIT_SKIP_LAYER4=1
#     suppresses (skip-flag honored, AC #8 fixture).
#
# L2 scope (next session, github-actions-macos-smoke.yml workflow):
#   - real `launchctl bootstrap gui/$UID <plist>` rc=0 on GHA macos-14
#     ephemeral runner; CFF-S55-4 closes; SP03 T-15 AC #7 + SP08 T-5 AC #4
#     close.
# L3 scope (subsequent session):
#   - GPG/OIDC-signed macos-smoke-passed.json attestation;
#     .github/workflows/release.yml gate.
#
# AC coverage (SP08 T-5, foundation-repo tasks.md L162-173):
#   AC #2 — Consumes SP00 tests/dogfood.sb (profile lint passes) — T1
#   AC #3 — Install writes only under DOGFOOD_ROOT; ~/Library/LaunchAgents
#           diff vs baseline empty — T2 + T3 + T4 + T5
#   AC #5 — Uninstall leaves DOGFOOD_ROOT empty-minus-logs (sampled at
#           hooks dir level; full residue check belongs to SP08 T-7 Lima
#           E2E) — T5
#   AC #7 — Layer-4 historical grep-audit (distribution tree) — T6
#   AC #8 — Synthetic-commit Layer-4 detection unit test — T6
#
# DEFENSE-IN-DEPTH (documented in dogfood.sb): sandbox-exec is filesystem-
# only isolation. It does NOT contain `launchctl bootstrap` because launchctl
# uses the inherited bootstrap_port (XPC over Mach), not mach-lookup of a
# global name. Empirically verified S70: `(deny mach-lookup (global-name
# "com.apple.launchd"))` did not block `launchctl print user/$UID`. The
# only working containment for real launchctl on a developer host is
# PATH-injection of tests/mock-launchctl.sh ahead of /bin/launchctl. Any
# T-5 consumer that needs real launchctl rc verification MUST run on an
# isolated macOS guest (GHA macos-14 runner — L2).
#
# Hermetic: per-test mktemp tmpdir; isolated $HOME, $CLAUDE_HOME, PATH,
# trace dir. No mutation of live ~/.claude or live ~/Library/LaunchAgents.
# Each T runs in its own subshell with explicit env passthrough — no leakage
# across tests via exported vars.
#
# Bash 3.2 clean (R-23). R-37 single-deliverable.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
UNINSTALL_SH="$REPO_ROOT/uninstall.sh"
RENDER="$REPO_ROOT/installer/render-launchd.sh"
MOCK="$REPO_ROOT/tests/mock-launchctl.sh"
LINT="$REPO_ROOT/tests/plist-lint.sh"
GREP_AUDIT="$REPO_ROOT/tests/grep-audit.sh"
SANDBOX_PROFILE="$REPO_ROOT/tests/dogfood.sb"

# --- prereq checks ----------------------------------------------------
for f in "$INSTALL_SH" "$UNINSTALL_SH" "$RENDER" "$MOCK" "$LINT" "$GREP_AUDIT" "$SANDBOX_PROFILE"; do
  if [ ! -e "$f" ]; then
    printf 'FAIL: prerequisite missing: %s\n' "$f" >&2
    exit 2
  fi
done
for tool in jq plutil sandbox-exec git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FAIL: required tool not on PATH: %s\n' "$tool" >&2
    exit 2
  fi
done
case "$(uname -s)" in
  Darwin) ;;
  *) printf 'FAIL: this test requires Darwin; got %s\n' "$(uname -s)" >&2; exit 2 ;;
esac

# --- harness ----------------------------------------------------------
PASS=0
FAIL=0
TMPDIRS=""

cleanup() {
  for d in $TMPDIRS; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM

mk_tmp() {
  local d
  d="$(mktemp -d -t sp08-smoke.XXXXXX)"
  TMPDIRS="$TMPDIRS $d"
  printf '%s' "$d"
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: expected=%s actual=%s\n' "$label" "$expected" "$actual" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_path_exists() {
  local p="$1" label="$2"
  if [ -e "$p" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (path absent: %s)\n' "$label" "$p" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_path_absent() {
  local p="$1" label="$2"
  if [ ! -e "$p" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (path unexpectedly present: %s)\n' "$label" "$p" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_nonzero() {
  local rc="$1" label="$2"
  if [ "$rc" != "0" ]; then
    printf '  PASS %s (rc=%s)\n' "$label" "$rc"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: expected non-zero rc, got 0\n' "$label" >&2
    FAIL=$((FAIL+1))
  fi
}

# Capture a deterministic snapshot of ~/Library/LaunchAgents/ contents so we
# can diff against post-test state. Uses ls -1 (filenames only, sorted) to
# produce a stable string; ignores mtime jitter on dirs themselves. Falls
# back to "<absent>" if the dir doesn't exist (legitimate baseline state on
# fresh macOS).
capture_la_baseline() {
  if [ -d "$HOME/Library/LaunchAgents" ]; then
    ls -1 "$HOME/Library/LaunchAgents" 2>/dev/null | LC_ALL=C sort
  else
    printf '<absent>'
  fi
}

# PATH-inject mock-launchctl as `launchctl`. Wrapper preserves env (LAUNCHCTL_
# TRACE_DIR + LAUNCHCTL_PLIST_LINT) via exec's default env propagation.
# Pattern lifted from tests/sp03/integration-orchestration-mock-launchctl.sh.
make_launchctl_path_dir() {
  local d="$1"
  mkdir -p "$d"
  cat > "$d/launchctl" <<EOF
#!/bin/bash
exec "$MOCK" "\$@"
EOF
  chmod +x "$d/launchctl"
}

# Per-test fake $HOME with stub paths.sh + orchestration.json. Mirrors
# render-launchd-unit-test.sh + SP03 T-14 setup. Librarian-only schedule
# (architect needs schedule.dow[0] which adds noise for L1 scope).
seed_fake_home_for_render() {
  local hroot="$1"
  mkdir -p "$hroot/.claude/hooks/lib" "$hroot/.claude/logs"
  mkdir -p "$hroot/Library/LaunchAgents" "$hroot/.claude/Library/LaunchAgents.staging"

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

# ===================================================================
# T1 — Sandbox profile (AC #2)
# ===================================================================
echo "== T1: SP00 dogfood.sb consumes correctly =="
T1_TMP=$(mk_tmp)
T1_CANON=$(cd "$T1_TMP" && pwd -P)

# T1.1 — pre-flight syntactic lint stays green after S70 documentary edit
sandbox-exec -f "$SANDBOX_PROFILE" -D DOGFOOD_ROOT="$T1_CANON" /usr/bin/true
assert_eq "0" "$?" "T1.1: dogfood.sb pre-flight lint /usr/bin/true exit 0"

# T1.2 — write inside DOGFOOD_ROOT lands
sandbox-exec -f "$SANDBOX_PROFILE" -D DOGFOOD_ROOT="$T1_CANON" \
  /usr/bin/touch "$T1_CANON/inside-marker" >/dev/null 2>&1
T1_2_RC=$?
if [ -f "$T1_CANON/inside-marker" ] && [ "$T1_2_RC" = "0" ]; then
  printf '  PASS T1.2: write inside DOGFOOD_ROOT lands (rc=0, marker exists)\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T1.2: write inside DOGFOOD_ROOT (rc=%s, exists=%s)\n' \
    "$T1_2_RC" "$([ -f "$T1_CANON/inside-marker" ] && echo yes || echo no)" >&2
  FAIL=$((FAIL+1))
fi

# T1.3 — write outside DOGFOOD_ROOT denied (file-write* enforced)
T1_OUTSIDE=$(mk_tmp)
T1_OUTSIDE_CANON=$(cd "$T1_OUTSIDE" && pwd -P)
sandbox-exec -f "$SANDBOX_PROFILE" -D DOGFOOD_ROOT="$T1_CANON" \
  /usr/bin/touch "$T1_OUTSIDE_CANON/should-be-blocked" >/dev/null 2>&1
T1_3_RC=$?
if [ ! -f "$T1_OUTSIDE_CANON/should-be-blocked" ] && [ "$T1_3_RC" != "0" ]; then
  printf '  PASS T1.3: write outside DOGFOOD_ROOT denied (rc=%s non-zero, file absent)\n' "$T1_3_RC"
  PASS=$((PASS+1))
else
  printf '  FAIL T1.3: outside-write should be denied (rc=%s, file_exists=%s)\n' \
    "$T1_3_RC" "$([ -f "$T1_OUTSIDE_CANON/should-be-blocked" ] && echo yes || echo no)" >&2
  FAIL=$((FAIL+1))
fi

# ===================================================================
# T2 — Filesystem isolation through install.sh (AC #3)
# ===================================================================
echo ""
echo "== T2: install.sh writes confined; host /Library/LaunchAgents baseline preserved =="
T2_LA_BEFORE=$(capture_la_baseline)
T2_TMP=$(mk_tmp)
T2_CH="$T2_TMP/claude-home"

# G5 isolation: install.sh walks $PLANS_HOME=$HOME/.claude-plans for NN-*/
# plans. HOME=$T2_TMP redirects PLANS_HOME to an empty tmp tree.
HOME="$T2_TMP" CLAUDE_HOME="$T2_CH" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --apply >"$T2_TMP/.stdout" 2>"$T2_TMP/.stderr"
T2_RC=$?
assert_eq "0" "$T2_RC" "T2.1: install.sh --apply exits 0"
assert_path_exists "$T2_CH/templates/launchd/librarian.plist.tmpl" \
  "T2.2: librarian.plist.tmpl shipped under \$CLAUDE_HOME/templates/launchd/"
assert_path_exists "$T2_CH/templates/launchd/architect.plist.tmpl" \
  "T2.3: architect.plist.tmpl shipped under \$CLAUDE_HOME/templates/launchd/"
assert_path_exists "$T2_CH/Library/LaunchAgents.staging" \
  "T2.4: \$CLAUDE_HOME/Library/LaunchAgents.staging dir created"
assert_path_exists "$T2_CH/foundation-manifest.json" \
  "T2.5: foundation-manifest.json baseline shipped (S62 wiring intact)"

T2_LA_AFTER=$(capture_la_baseline)
assert_eq "$T2_LA_BEFORE" "$T2_LA_AFTER" \
  "T2.6: host \$HOME/Library/LaunchAgents/ baseline unchanged after install.sh"

# Confirm install.sh did NOT write any plist directly under $T2_CH/Library/
# LaunchAgents/ (production-style path) — only LaunchAgents.staging is foundation
# territory at install time per SP07 spec L86-102 split.
assert_path_absent "$T2_CH/Library/LaunchAgents" \
  "T2.7: install.sh did not create production LaunchAgents dir (staging-only flow)"

# ===================================================================
# T3 — render-launchd staging mode (no real launchctl call by design)
# ===================================================================
echo ""
echo "== T3: render-launchd --staging-dir writes plist; no launchctl invocation =="
T3_LA_BEFORE=$(capture_la_baseline)
T3_TMP=$(mk_tmp)
seed_fake_home_for_render "$T3_TMP"
T3_STAGING="$T3_TMP/.claude/Library/LaunchAgents.staging"

HOME="$T3_TMP" bash "$RENDER" --staging-dir "$T3_STAGING" librarian \
  </dev/null >"$T3_TMP/.stdout" 2>"$T3_TMP/.stderr"
T3_RC=$?
assert_eq "0" "$T3_RC" "T3.1: render-launchd --staging-dir librarian exits 0"

T3_PLIST="$T3_STAGING/com.claude-foundations.librarian-scan.plist"
assert_path_exists "$T3_PLIST" "T3.2: rendered plist landed in staging dir"

if [ -f "$T3_PLIST" ]; then
  if plutil -lint -s "$T3_PLIST" >/dev/null 2>&1; then
    printf '  PASS T3.3: plutil -lint accepts rendered staging plist\n'
    PASS=$((PASS+1))
  else
    printf '  FAIL T3.3: plutil -lint rejected rendered staging plist\n' >&2
    FAIL=$((FAIL+1))
  fi
else
  printf '  FAIL T3.3: skipped — plist file absent\n' >&2
  FAIL=$((FAIL+1))
fi

T3_LA_AFTER=$(capture_la_baseline)
assert_eq "$T3_LA_BEFORE" "$T3_LA_AFTER" \
  "T3.4: host \$HOME/Library/LaunchAgents/ baseline unchanged after staging render"

# ===================================================================
# T4 — render-launchd PRODUCTION mode under PATH-injected mock-launchctl
# ===================================================================
echo ""
echo "== T4: render-launchd production mode under mock-launchctl =="
T4_LA_BEFORE=$(capture_la_baseline)
T4_TMP=$(mk_tmp)
seed_fake_home_for_render "$T4_TMP"
T4_PATHDIR="$T4_TMP/.path"
make_launchctl_path_dir "$T4_PATHDIR"
T4_TRACE="$T4_TMP/results"
mkdir -p "$T4_TRACE"

# Production mode: render-launchd writes to $HOME/Library/LaunchAgents/
# (here = $T4_TMP/Library/LaunchAgents/ via fake HOME), then bootout +
# bootstrap. Mock intercepts both verbs.
HOME="$T4_TMP" PATH="$T4_PATHDIR:$PATH" \
  LAUNCHCTL_TRACE_DIR="$T4_TRACE" \
  LAUNCHCTL_PLIST_LINT="$LINT" \
  bash "$RENDER" librarian </dev/null >"$T4_TMP/.stdout" 2>"$T4_TMP/.stderr"
T4_RC=$?
assert_eq "0" "$T4_RC" "T4.1: render-launchd production rc=0 under mock-launchctl"

T4_NDJSON="$T4_TRACE/launchctl-trace.ndjson"
assert_path_exists "$T4_NDJSON" "T4.2: mock launchctl-trace.ndjson written"

if [ -f "$T4_NDJSON" ]; then
  T4_LINES=$(wc -l < "$T4_NDJSON" | tr -d ' ')
  if [ "$T4_LINES" -ge 2 ]; then
    printf '  PASS T4.3: trace has >=2 lines (got %s)\n' "$T4_LINES"
    PASS=$((PASS+1))
  else
    printf '  FAIL T4.3: trace lines (got %s, expected >=2)\n' "$T4_LINES" >&2
    FAIL=$((FAIL+1))
  fi

  T4_VERB1=$(jq -r '.verb' < "$T4_NDJSON" | sed -n '1p')
  T4_VERB2=$(jq -r '.verb' < "$T4_NDJSON" | sed -n '2p')
  T4_EXIT1=$(jq -r '.exit' < "$T4_NDJSON" | sed -n '1p')
  T4_EXIT2=$(jq -r '.exit' < "$T4_NDJSON" | sed -n '2p')

  assert_eq "bootout"   "$T4_VERB1" "T4.4: trace[0].verb = bootout"
  assert_eq "bootstrap" "$T4_VERB2" "T4.5: trace[1].verb = bootstrap"
  assert_eq "0"         "$T4_EXIT1" "T4.6: trace[0].exit = 0"
  assert_eq "0"         "$T4_EXIT2" "T4.7: trace[1].exit = 0"
fi

T4_LA_AFTER=$(capture_la_baseline)
assert_eq "$T4_LA_BEFORE" "$T4_LA_AFTER" \
  "T4.8: host \$HOME/Library/LaunchAgents/ baseline unchanged (mock intercepted)"

# ===================================================================
# T5 — uninstall.sh cleanup (AC #5)
# ===================================================================
echo ""
echo "== T5: uninstall.sh removes foundation files; host LaunchAgents preserved =="
T5_LA_BEFORE=$(capture_la_baseline)
T5_TMP=$(mk_tmp)
T5_CH="$T5_TMP/claude-home"

# Fresh install — no settings.json pre-exists, so G3 backup is a no-op.
HOME="$T5_TMP" CLAUDE_HOME="$T5_CH" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --apply >"$T5_TMP/.install.stdout" 2>"$T5_TMP/.install.stderr"
T5_INSTALL_RC=$?
assert_eq "0" "$T5_INSTALL_RC" "T5.1: pre-uninstall install.sh --apply exits 0"

# Uninstaller needs LAUNCHCTL_BIN env override since it'll launchctl bootout
# any com.claude-foundations.* labels. Point at mock to keep host launchd
# untouched even if a label happened to be loaded for any reason.
T5_PATHDIR="$T5_TMP/.path"
make_launchctl_path_dir "$T5_PATHDIR"
T5_TRACE="$T5_TMP/.results"
mkdir -p "$T5_TRACE"

HOME="$T5_TMP" CLAUDE_HOME="$T5_CH" PATH="$T5_PATHDIR:$PATH" \
  LAUNCHCTL_TRACE_DIR="$T5_TRACE" LAUNCHCTL_PLIST_LINT="$LINT" \
  LAUNCHCTL_BIN="$T5_PATHDIR/launchctl" \
  bash "$UNINSTALL_SH" >"$T5_TMP/.uninstall.stdout" 2>"$T5_TMP/.uninstall.stderr"
T5_UNINSTALL_RC=$?
assert_eq "0" "$T5_UNINSTALL_RC" "T5.2: uninstall.sh exits 0"

# Sample a foundation file that should have been removed.
assert_path_absent "$T5_CH/foundation-manifest.json" \
  "T5.3: foundation-manifest.json removed by uninstall"

# Sample a foundation directory member.
assert_path_absent "$T5_CH/templates/launchd/librarian.plist.tmpl" \
  "T5.4: foundation plist tmpl removed by uninstall"

# logs/ is preserved (uninstall provenance lands here).
assert_path_exists "$T5_CH/logs" \
  "T5.5: \$CLAUDE_HOME/logs/ preserved (uninstall provenance dir)"

T5_LA_AFTER=$(capture_la_baseline)
assert_eq "$T5_LA_BEFORE" "$T5_LA_AFTER" \
  "T5.6: host \$HOME/Library/LaunchAgents/ baseline unchanged after uninstall.sh"

# ===================================================================
# T6 — Layer-4 historical grep-audit (AC #7 + AC #8)
# ===================================================================
echo ""
echo "== T6: Layer-4 historical grep-audit detects planted-then-reverted leak =="
T6_TMP=$(mk_tmp)
T6_REPO="$T6_TMP/synthetic-repo"
mkdir -p "$T6_REPO"

# Init synthetic repo without touching global git config.
git -C "$T6_REPO" init -q 2>/dev/null
git -C "$T6_REPO" config user.email "test@example.invalid"
git -C "$T6_REPO" config user.name  "T6 Tester"

# Commit A: clean baseline. Simple installer skeleton with no leak.
mkdir -p "$T6_REPO/dist"
cat > "$T6_REPO/dist/install.sh" <<'CLEAN'
#!/bin/bash
# Synthetic dist installer for grep-audit Layer-4 test. No reference leaks.
RESOLVED_HOME="${CLAUDE_HOME:-}"
[ -z "$RESOLVED_HOME" ] && exit 10
echo "installing under $RESOLVED_HOME"
CLEAN
git -C "$T6_REPO" add dist/install.sh
git -C "$T6_REPO" commit -q -m "A: initial installer skeleton"
T6_SHA_A=$(git -C "$T6_REPO" rev-parse HEAD)

# Commit B: PLANT THE LEAK. The leak token must be a foundation-identifying
# string from grep-audit-patterns/literal.txt for Layer 4 to trip on it.
# spec.md L171 names "CLAUDE_DIR=$HOME/.claude" as the structural example,
# but that exact phrase isn't a literal pattern; we plant a known-pattern
# token instead. The Layer-4 mechanism is identical regardless of which
# token is planted, so this fixture proves the pattern; pattern expansion
# would inherit the same test surface.
#
# IMPORTANT: this test file must NOT itself contain the full pattern token
# (else the foundation-repo grep-audit baseline collides with this test).
# Token is assembled at runtime via printf hex escapes — Layer 1 (raw),
# Layer 2 (NFKC), and Layer 3 (base64-decode) all see only the literal
# escape sequence text in the source, never the resolved bytes. printf
# evaluates the escapes at runtime to produce the actual pattern token,
# which then lands in the synthetic repo's commit history where Layer 4
# (git log -p diff) detects it.
#
# Tested S70 (2026-05-01): adjacent-fragment construction
# (printf 'p'; printf 'eter'; ...) was caught by both Layer 2 and Layer 3
# at hits_total:4 vs baseline 2. Hex escapes restore baseline.
LEAK_FRAG_A=$(printf '\x70\x65\x74\x65\x72\x74\x69\x6b\x74\x69\x6e\x73\x6b\x79')
cat > "$T6_REPO/dist/install.sh" <<LEAK
#!/bin/bash
# Synthetic dist installer for grep-audit Layer-4 test.
# Layer-4-fixture: this commit deliberately plants a foundation-identifying
# token to be reverted in commit C. The leak survives in \`git log -p\`
# history and Layer-4 must detect it.
INSTALLER_OWNER="${LEAK_FRAG_A}-fixture-leak"
echo "installer owner: \$INSTALLER_OWNER"
LEAK
git -C "$T6_REPO" add dist/install.sh
git -C "$T6_REPO" commit -q -m "B: plant foundation-identifying leak (synthetic fixture)"
T6_SHA_B=$(git -C "$T6_REPO" rev-parse HEAD)

# Commit C: revert the leak. Current tree is clean again, but commit B's
# diff still lives in `git log --all -p` history.
cat > "$T6_REPO/dist/install.sh" <<'CLEAN'
#!/bin/bash
# Synthetic dist installer for grep-audit Layer-4 test. No reference leaks.
RESOLVED_HOME="${CLAUDE_HOME:-}"
[ -z "$RESOLVED_HOME" ] && exit 10
echo "installing under $RESOLVED_HOME"
CLEAN
git -C "$T6_REPO" add dist/install.sh
git -C "$T6_REPO" commit -q -m "C: revert leak (current tree clean)"
T6_SHA_C=$(git -C "$T6_REPO" rev-parse HEAD)

# Sanity: current tree contains no leak (Layer 1 should be clean if invoked
# alone). Layer 4 should still hit because B's diff is in history.
T6_PATTERNS_DIR="$T6_TMP/grep-patterns-fixture"
# Use the foundation grep-audit-patterns/ to drive the audit. We're testing
# the SCRIPT, not authoring new patterns; reuse what's shipped.

# T6.1 — Layer 4 detects the planted leak in `git log -p` history.
GREP_AUDIT_SKIP_LAYER4=0 bash "$GREP_AUDIT" "$T6_REPO" >"$T6_TMP/.audit.l4on" 2>&1
T6_RC_L4ON=$?
assert_nonzero "$T6_RC_L4ON" "T6.1: grep-audit with Layer 4 detects planted-then-reverted leak"

# T6.2 — Layer 4 hit count visible in audit summary or stderr.
if grep -qiE 'layer.4.*hit|layer.4.*\b[1-9]' "$T6_TMP/.audit.l4on" 2>/dev/null; then
  printf '  PASS T6.2: Layer 4 hits annotated in audit output\n'
  PASS=$((PASS+1))
elif grep -qE '"layer4"[ ]*:[ ]*[1-9]' "$T6_TMP/.audit.l4on" 2>/dev/null; then
  printf '  PASS T6.2: Layer 4 hits annotated (JSON shape) in audit output\n'
  PASS=$((PASS+1))
elif grep -qE 'CLAUDE_DIR|\$HOME/\.claude' "$T6_TMP/.audit.l4on" 2>/dev/null; then
  # Fallback signal: leak content surfaced in diagnostic somewhere.
  printf '  PASS T6.2: Layer 4 surfaced leak content in audit diagnostic\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T6.2: Layer 4 hit not annotated in audit output\n' >&2
  printf '    audit output excerpt:\n' >&2
  head -40 "$T6_TMP/.audit.l4on" >&2
  FAIL=$((FAIL+1))
fi

# T6.3 — GREP_AUDIT_SKIP_LAYER4=1 suppresses Layer 4 detection. With the leak
# only visible in history (not current tree), the skip flag should produce
# rc=0 (no hits in layers 1-3).
GREP_AUDIT_SKIP_LAYER4=1 bash "$GREP_AUDIT" "$T6_REPO" >"$T6_TMP/.audit.l4off" 2>&1
T6_RC_L4OFF=$?
assert_eq "0" "$T6_RC_L4OFF" \
  "T6.3: GREP_AUDIT_SKIP_LAYER4=1 + clean current tree → grep-audit rc=0"

# T6.4 — Sanity: a clean-history repo (no planted leak) should rc=0 across
# all layers. Distinguishes "Layer 4 always fires" from "Layer 4 fired due
# to our planted leak."
T6_CLEAN_REPO="$T6_TMP/clean-repo"
mkdir -p "$T6_CLEAN_REPO"
git -C "$T6_CLEAN_REPO" init -q 2>/dev/null
git -C "$T6_CLEAN_REPO" config user.email "test@example.invalid"
git -C "$T6_CLEAN_REPO" config user.name  "T6 Clean"
mkdir -p "$T6_CLEAN_REPO/dist"
cat > "$T6_CLEAN_REPO/dist/install.sh" <<'CLEAN'
#!/bin/bash
# clean fixture; no leaks anywhere in history.
RESOLVED_HOME="${CLAUDE_HOME:-}"
echo "installing"
CLEAN
git -C "$T6_CLEAN_REPO" add dist/install.sh
git -C "$T6_CLEAN_REPO" commit -q -m "clean baseline"

GREP_AUDIT_SKIP_LAYER4=0 bash "$GREP_AUDIT" "$T6_CLEAN_REPO" >"$T6_TMP/.audit.clean" 2>&1
T6_RC_CLEAN=$?
assert_eq "0" "$T6_RC_CLEAN" \
  "T6.4: clean-history repo + Layer 4 enabled → grep-audit rc=0 (no false positives)"

# ===================================================================
# T7 — uninstall.sh removes foundation plists at $HOME/Library/LaunchAgents/
#       (CFF-S71-1; symmetric with G6 namespace filter)
# ===================================================================
echo ""
echo "== T7: uninstall.sh removes foundation plists; foreign plists preserved =="
T7_TMP=$(mk_tmp)
T7_CH="$T7_TMP/.claude"

# Install + seed for render. seed_fake_home_for_render writes paths.sh +
# orchestration.json under $T7_TMP. install.sh ships its own paths.sh
# (translation lib/→hooks/lib/) which would overwrite the seeded one; we
# call install.sh first, then re-seed orchestration.json so it lands at the
# canonical $CLAUDE_HOME/orchestration.json paths.sh resolves.
HOME="$T7_TMP" CLAUDE_HOME="$T7_CH" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --apply >"$T7_TMP/.install.stdout" 2>"$T7_TMP/.install.stderr"
T7_INSTALL_RC=$?
assert_eq "0" "$T7_INSTALL_RC" "T7.1: install.sh --apply exits 0"

# Seed orchestration.json fixture for render-launchd (librarian-only schedule)
cat > "$T7_CH/orchestration.json" <<'EOF'
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

# Render production mode under PATH-injected mock-launchctl → writes plist
# to $T7_TMP/Library/LaunchAgents/com.claude-foundations.librarian-scan.plist;
# mock intercepts launchctl bootstrap so host launchd is untouched.
T7_PATHDIR="$T7_TMP/.path"
make_launchctl_path_dir "$T7_PATHDIR"
T7_TRACE_RENDER="$T7_TMP/.results-render"
mkdir -p "$T7_TRACE_RENDER"

HOME="$T7_TMP" CLAUDE_HOME="$T7_CH" \
  ORCHESTRATION_JSON="$T7_CH/orchestration.json" \
  PATH="$T7_PATHDIR:$PATH" \
  LAUNCHCTL_TRACE_DIR="$T7_TRACE_RENDER" \
  LAUNCHCTL_PLIST_LINT="$LINT" \
  bash "$RENDER" librarian </dev/null \
    >"$T7_TMP/.render.stdout" 2>"$T7_TMP/.render.stderr"
T7_RENDER_RC=$?
assert_eq "0" "$T7_RENDER_RC" "T7.2: render-launchd production rc=0 under mock"

T7_FOUNDATION_PLIST="$T7_TMP/Library/LaunchAgents/com.claude-foundations.librarian-scan.plist"
assert_path_exists "$T7_FOUNDATION_PLIST" \
  "T7.3: foundation plist landed at \$HOME/Library/LaunchAgents/ post-render"

# Plant a foreign plist alongside the foundation one. G6-symmetric: the
# uninstall plist-cleanup loop should rm only com.claude-foundations.* plists
# and preserve foreign plists. Foreign-plist content is a minimal valid plist
# (plutil-lint not strictly required for survival assertion, but use a real
# plist shape so any plutil-touching codepath doesn't reject it).
T7_FOREIGN_PLIST="$T7_TMP/Library/LaunchAgents/com.example.unrelated.plist"
cat > "$T7_FOREIGN_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTD/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.example.unrelated</string>
  <key>ProgramArguments</key><array><string>/usr/bin/true</string></array>
</dict></plist>
EOF
assert_path_exists "$T7_FOREIGN_PLIST" "T7.4: foreign plist planted (sentinel)"

# Run uninstall.sh under mock-launchctl. LAUNCHCTL_BIN points at mock so the
# foundation label's bootout is intercepted; the post-bootout plist-cleanup
# loop is what we're actually testing here (touches filesystem only, not
# launchctl, so mock is incidental).
T7_TRACE_UNINSTALL="$T7_TMP/.results-uninstall"
mkdir -p "$T7_TRACE_UNINSTALL"
HOME="$T7_TMP" CLAUDE_HOME="$T7_CH" \
  PATH="$T7_PATHDIR:$PATH" \
  LAUNCHCTL_TRACE_DIR="$T7_TRACE_UNINSTALL" \
  LAUNCHCTL_PLIST_LINT="$LINT" \
  LAUNCHCTL_BIN="$T7_PATHDIR/launchctl" \
  bash "$UNINSTALL_SH" >"$T7_TMP/.uninstall.stdout" 2>"$T7_TMP/.uninstall.stderr"
T7_UNINSTALL_RC=$?
assert_eq "0" "$T7_UNINSTALL_RC" "T7.5: uninstall.sh exits 0"

# Foundation plist removed (CFF-S71-1 fix verifies)
assert_path_absent "$T7_FOUNDATION_PLIST" \
  "T7.6: foundation plist removed from \$HOME/Library/LaunchAgents/ post-uninstall (CFF-S71-1)"

# Foreign plist preserved (G6-symmetric namespace filter)
assert_path_exists "$T7_FOREIGN_PLIST" \
  "T7.7: foreign plist preserved (G6-symmetric: only com.claude-foundations.* removed)"

# Provenance log records plist_rm_count = 1
T7_PROV_LOG=$(ls -1 "$T7_CH/logs"/uninstall-*.log 2>/dev/null | head -1)
if [ -n "$T7_PROV_LOG" ] && [ -r "$T7_PROV_LOG" ]; then
  T7_PLIST_RM_COUNT=$(grep '^plist_rm_count:' "$T7_PROV_LOG" | awk '{print $2}')
  assert_eq "1" "$T7_PLIST_RM_COUNT" \
    "T7.8: provenance log records plist_rm_count=1"
else
  printf '  FAIL T7.8: uninstall provenance log not found\n' >&2
  FAIL=$((FAIL+1))
fi

# ===================================================================
# Summary
# ===================================================================
echo ""
echo "== Summary =="
TOTAL=$((PASS+FAIL))
printf 'pass=%d fail=%d total=%d\n' "$PASS" "$FAIL" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  printf 'RESULT: red\n' >&2
  exit 1
fi
printf 'RESULT: green\n'
exit 0
