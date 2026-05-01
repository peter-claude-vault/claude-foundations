#!/bin/bash
# tests/sp08/uninstall-happy-path-unit-test.sh
#
# Synthetic unit test for SP08 T-2 slice (S61):
#   - T1: install + uninstall round-trip — foundation files removed, user
#         content preserved, .pre-uninstall-<ts>/ backup created
#   - T2: backup integrity — entry count + sha256 spot-check round-trip
#   - T3: G6 — foreign-label-with-foundation-substring → exit 56
#         (LAUNCHCTL_BIN mock pre-seeds offending label)
#   - T4: missing provenance log → exit 10 + diagnostic
#   - T5: provenance log header content on success
#   - T6: foundation-known allowlist symmetric — both pre-seeded; only
#         foundation removed
#   - T7: hooks/state/ preserved across hooks/ removal (nested-state guarantee)
#
# Hermetic: each test creates its own tmpdir CLAUDE_HOME; SOURCE_REPO points
# at the foundation-repo top. LAUNCHCTL_BIN injects a mock launchctl that
# does not require system launchd.
#
# R-23: bash 3.2 compat (macOS /bin/bash 3.2.57). No associative arrays.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
UNINSTALL_SH="$REPO_ROOT/uninstall.sh"

# --- harness ---
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
  d="$(mktemp -d -t uninstall-test.XXXXXX)"
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
  local path="$1" label="$2"
  if [ -e "$path" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (path missing: %s)\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_path_absent() {
  local path="$1" label="$2"
  if [ ! -e "$path" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (path still exists: %s)\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_grep() {
  local pattern="$1" file="$2" label="$3"
  if grep -q -- "$pattern" "$file" 2>/dev/null; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (pattern not found: %s in %s)\n' "$label" "$pattern" "$file" >&2
    FAIL=$((FAIL+1))
  fi
}

# --- mock launchctl factory ---
# Writes a mock launchctl into $1; honors $MOCK_LAUNCHCTL_LABELS env at
# invocation time (space-separated label list returned in `list`).
# `bootout` always succeeds. `version` accepted (silent).
write_mock_launchctl() {
  local target="$1"
  cat > "$target" <<'MOCK'
#!/bin/bash
# Mock launchctl for SP08 T-2 hermetic tests.
# Honored env: MOCK_LAUNCHCTL_LABELS (space-separated).
case "${1:-}" in
  list)
    printf 'PID\tStatus\tLabel\n'
    if [ -n "${MOCK_LAUNCHCTL_LABELS:-}" ]; then
      for label in $MOCK_LAUNCHCTL_LABELS; do
        printf '12345\t0\t%s\n' "$label"
      done
    fi
    exit 0
    ;;
  bootout)
    # Record bootout invocation if recorder set
    if [ -n "${MOCK_LAUNCHCTL_BOOTOUT_LOG:-}" ]; then
      printf 'bootout %s\n' "$2" >> "$MOCK_LAUNCHCTL_BOOTOUT_LOG"
    fi
    exit 0
    ;;
  version)
    printf 'mock-launchctl 0.1\n'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCK
  chmod +x "$target"
}

# --- prereq sanity ---
if [ ! -x "$INSTALL_SH" ]; then
  printf 'FAIL: install.sh not executable at %s\n' "$INSTALL_SH" >&2
  exit 7
fi
if [ ! -x "$UNINSTALL_SH" ]; then
  printf 'FAIL: uninstall.sh not executable at %s\n' "$UNINSTALL_SH" >&2
  exit 7
fi

# =====================================================================
# T1 — Install + uninstall round-trip
# =====================================================================
printf 'T1: install + uninstall round-trip — foundation removed, user preserved, backup created\n'

CH1="$(mk_tmp)"
MOCK_DIR1="$(mk_tmp)"
write_mock_launchctl "$MOCK_DIR1/mock-launchctl"

# Install first (consumes real CLAUDE_HOME-first installer)
rc=0
CLAUDE_HOME="$CH1" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" \
  >"$CH1/.install-stdout" 2>"$CH1/.install-stderr" || rc=$?
assert_eq "0" "$rc" "T1.1: install.sh prep exits 0"
assert_path_exists "$CH1/hooks/pre-write-guard.sh" "T1.2: install seeded hooks/"

# Pre-seed user content at top-level (not in foundation-known set)
mkdir -p "$CH1/my-user-project"
echo "user data" > "$CH1/my-user-project/notes.md"
echo "another user file" > "$CH1/user-toplevel-file.txt"
mkdir -p "$CH1/.user-dotdir"
echo "user dotdir content" > "$CH1/.user-dotdir/data.txt"

# Run uninstall with mock launchctl (empty labels list — clean bootout path)
rc=0
CLAUDE_HOME="$CH1" LAUNCHCTL_BIN="$MOCK_DIR1/mock-launchctl" \
  bash "$UNINSTALL_SH" >"$CH1/.uninstall-stdout" 2>"$CH1/.uninstall-stderr" || rc=$?
assert_eq "0" "$rc" "T1.3: uninstall.sh exits 0"

# Foundation top-level entries removed
# (hooks/ persists as state-stub if hooks/state/ pre-existed — verified in T7;
#  here we assert the foundation FILE removal vs the dir itself)
assert_path_absent "$CH1/hooks/pre-write-guard.sh" "T1.4: hooks/pre-write-guard.sh removed (foundation code)"
assert_path_absent "$CH1/skills"       "T1.5: skills/ removed"
assert_path_absent "$CH1/schemas"      "T1.6: schemas/ removed"
assert_path_absent "$CH1/onboarding"   "T1.7: onboarding/ removed"
assert_path_absent "$CH1/orchestrator" "T1.8: orchestrator/ removed"
assert_path_absent "$CH1/templates"    "T1.9: templates/ removed"
assert_path_absent "$CH1/installer"    "T1.10: installer/ removed"
assert_path_absent "$CH1/Library"      "T1.11: Library/ removed"
assert_path_absent "$CH1/settings.json" "T1.12: settings.json removed"

# logs/ preserved (uninstall provenance lands here)
assert_path_exists "$CH1/logs"         "T1.13: logs/ preserved"

# User content preserved
assert_path_exists "$CH1/my-user-project/notes.md" "T1.14: user dir preserved"
assert_path_exists "$CH1/user-toplevel-file.txt"   "T1.15: user file preserved"
assert_path_exists "$CH1/.user-dotdir/data.txt"    "T1.16: user dotdir preserved"

# Backup created
backup_count="$(ls -d "$CH1"/.pre-uninstall-* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "1" "$backup_count" "T1.17: exactly one .pre-uninstall-<ts>/ backup"

# Uninstall provenance log written
prov_count="$(ls "$CH1/logs"/uninstall-*.log 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "1" "$prov_count" "T1.18: uninstall provenance log written"

# =====================================================================
# T2 — Backup integrity (sha256 spot-check + entry count)
# =====================================================================
printf 'T2: backup integrity — sha256 spot-check + entry count\n'

# Fresh install for backup-integrity test
CH2="$(mk_tmp)"
MOCK_DIR2="$(mk_tmp)"
write_mock_launchctl "$MOCK_DIR2/mock-launchctl"

CLAUDE_HOME="$CH2" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" \
  >"$CH2/.install-stdout" 2>"$CH2/.install-stderr" || true

# Capture pre-uninstall sha256 of a stable foundation file
pre_sha="$(shasum -a 256 "$CH2/hooks/pre-write-guard.sh" 2>/dev/null | awk '{print $1}')"

CLAUDE_HOME="$CH2" LAUNCHCTL_BIN="$MOCK_DIR2/mock-launchctl" \
  bash "$UNINSTALL_SH" >"$CH2/.uninstall-stdout" 2>"$CH2/.uninstall-stderr" || true

backup_dir="$(ls -d "$CH2"/.pre-uninstall-* 2>/dev/null | head -1)"
assert_path_exists "$backup_dir/hooks/pre-write-guard.sh" "T2.1: pre-write-guard.sh in backup"

# sha256 round-trip
post_sha="$(shasum -a 256 "$backup_dir/hooks/pre-write-guard.sh" 2>/dev/null | awk '{print $1}')"
assert_eq "$pre_sha" "$post_sha" "T2.2: sha256 of backed-up file matches pre-uninstall original"

# Backup contains expected foundation top-levels
assert_path_exists "$backup_dir/hooks"     "T2.3: backup contains hooks/"
assert_path_exists "$backup_dir/schemas"   "T2.4: backup contains schemas/"
assert_path_exists "$backup_dir/installer" "T2.5: backup contains installer/"
assert_path_exists "$backup_dir/settings.json" "T2.6: backup contains settings.json"

# =====================================================================
# T3 — G6 foreign label → exit 56 (impersonation defense)
# =====================================================================
printf 'T3: G6 — foreign label containing prefix substring → exit 56\n'

CH3="$(mk_tmp)"
MOCK_DIR3="$(mk_tmp)"
write_mock_launchctl "$MOCK_DIR3/mock-launchctl"

CLAUDE_HOME="$CH3" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" \
  >"$CH3/.install-stdout" 2>"$CH3/.install-stderr" || true

# Pre-seed mock with impersonation label (contains prefix substring at non-1 position)
rc=0
MOCK_LAUNCHCTL_LABELS="evil.com.claude-foundations.fake" \
  CLAUDE_HOME="$CH3" LAUNCHCTL_BIN="$MOCK_DIR3/mock-launchctl" \
  bash "$UNINSTALL_SH" >"$CH3/.uninstall-stdout" 2>"$CH3/.uninstall-stderr" || rc=$?

assert_eq "56" "$rc" "T3.1: G6 fires exit 56 on impersonation label"
assert_grep "G6 fired" "$CH3/.uninstall-stderr" "T3.2: G6 diagnostic emitted on stderr"

# Foundation files NOT removed (uninstall aborted before rm)
assert_path_exists "$CH3/hooks"     "T3.3: hooks/ retained on G6 abort"
assert_path_exists "$CH3/installer" "T3.4: installer/ retained on G6 abort"
assert_path_exists "$CH3/schemas"   "T3.5: schemas/ retained on G6 abort"

# Backup created (backup happens BEFORE bootout/G6 check)
backup3_count="$(ls -d "$CH3"/.pre-uninstall-* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "1" "$backup3_count" "T3.6: backup retained on G6 abort (forensic preserve)"

# =====================================================================
# T4 — Missing provenance log → exit 10
# =====================================================================
printf 'T4: missing provenance log under CLAUDE_HOME/logs/ → exit 10\n'

CH4="$(mk_tmp)"
MOCK_DIR4="$(mk_tmp)"
write_mock_launchctl "$MOCK_DIR4/mock-launchctl"

# CLAUDE_HOME exists but is empty (no install) — uninstall must refuse
rc=0
CLAUDE_HOME="$CH4" LAUNCHCTL_BIN="$MOCK_DIR4/mock-launchctl" \
  bash "$UNINSTALL_SH" >"$CH4/.stdout" 2>"$CH4/.stderr" || rc=$?
assert_eq "10" "$rc" "T4.1: empty CLAUDE_HOME → exit 10"
assert_grep "no logs/ directory" "$CH4/.stderr" "T4.2: missing-logs diagnostic emitted"

# Now: logs/ exists but no install-*.log inside
mkdir -p "$CH4/logs"
rc=0
CLAUDE_HOME="$CH4" LAUNCHCTL_BIN="$MOCK_DIR4/mock-launchctl" \
  bash "$UNINSTALL_SH" >"$CH4/.stdout2" 2>"$CH4/.stderr2" || rc=$?
assert_eq "10" "$rc" "T4.3: empty logs/ dir → exit 10"
assert_grep "no install-\*.log provenance" "$CH4/.stderr2" "T4.4: missing-provenance diagnostic emitted"

# =====================================================================
# T5 — Provenance log header content (G10 emit)
# =====================================================================
printf 'T5: uninstall provenance log header content\n'

CH5="$(mk_tmp)"
MOCK_DIR5="$(mk_tmp)"
write_mock_launchctl "$MOCK_DIR5/mock-launchctl"

CLAUDE_HOME="$CH5" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" \
  >"$CH5/.install-stdout" 2>"$CH5/.install-stderr" || true

CLAUDE_HOME="$CH5" LAUNCHCTL_BIN="$MOCK_DIR5/mock-launchctl" \
  bash "$UNINSTALL_SH" >"$CH5/.uninstall-stdout" 2>"$CH5/.uninstall-stderr" || true

prov="$(ls "$CH5/logs"/uninstall-*.log 2>/dev/null | head -1)"
if [ -n "$prov" ] && [ -f "$prov" ]; then
  assert_grep "Plan 71 SP08 T-2 slice" "$prov" "T5.1: provenance header tags slice"
  assert_grep "CLAUDE_HOME: $CH5"      "$prov" "T5.2: CLAUDE_HOME recorded"
  assert_grep "consumed_install_log:"  "$prov" "T5.3: consumed install log recorded"
  assert_grep "backup_dir:"            "$prov" "T5.4: backup_dir recorded"
  assert_grep "bootout_count:"         "$prov" "T5.5: bootout_count recorded"
  assert_grep "removed_count:"         "$prov" "T5.6: removed_count recorded"
  assert_grep "uninstall.sh sha256:"   "$prov" "T5.7: uninstall.sh sha256 recorded"
  assert_grep "deferred:"              "$prov" "T5.8: deferred-scope marker recorded"
else
  printf '  FAIL T5: no uninstall provenance log found\n' >&2
  FAIL=$((FAIL+1))
fi

# =====================================================================
# T6 — Foundation-known allowlist symmetric (mixed pre-seed)
# =====================================================================
printf 'T6: allowlist symmetry — only foundation top-levels removed\n'

CH6="$(mk_tmp)"
MOCK_DIR6="$(mk_tmp)"
write_mock_launchctl "$MOCK_DIR6/mock-launchctl"

CLAUDE_HOME="$CH6" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" \
  >"$CH6/.install-stdout" 2>"$CH6/.install-stderr" || true

# Mix in foundation-adjacent and clearly-non-foundation top-level entries
mkdir -p "$CH6/projects"            # not in allowlist
echo "x" > "$CH6/projects/x.txt"
mkdir -p "$CH6/file-history"        # not in allowlist; brief preserve target
echo "history" > "$CH6/file-history/h.txt"
echo "user readme" > "$CH6/MY-README.md"  # not in allowlist
echo "settings ish" > "$CH6/settings.local.json.bak"  # not in allowlist

CLAUDE_HOME="$CH6" LAUNCHCTL_BIN="$MOCK_DIR6/mock-launchctl" \
  bash "$UNINSTALL_SH" >"$CH6/.uninstall-stdout" 2>"$CH6/.uninstall-stderr" || true

# Foundation removed
assert_path_absent "$CH6/skills"     "T6.1: skills/ removed (foundation)"
assert_path_absent "$CH6/templates"  "T6.2: templates/ removed (foundation)"
assert_path_absent "$CH6/plugins"    "T6.3: plugins/ removed (foundation)"

# Non-foundation preserved
assert_path_exists "$CH6/projects/x.txt"             "T6.4: projects/ preserved"
assert_path_exists "$CH6/file-history/h.txt"         "T6.5: file-history/ preserved (not in allowlist)"
assert_path_exists "$CH6/MY-README.md"               "T6.6: MY-README.md preserved"
assert_path_exists "$CH6/settings.local.json.bak"    "T6.7: .bak suffix preserved (not equal to settings.local.json)"

# =====================================================================
# T7 — hooks/state/ preservation across hooks/ removal
# =====================================================================
printf 'T7: hooks/state/ preserved across hooks/ removal (nested-state guarantee)\n'

CH7="$(mk_tmp)"
MOCK_DIR7="$(mk_tmp)"
write_mock_launchctl "$MOCK_DIR7/mock-launchctl"

CLAUDE_HOME="$CH7" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" \
  >"$CH7/.install-stdout" 2>"$CH7/.install-stderr" || true

# Pre-seed session state inside hooks/state/
echo "session checkpoint" > "$CH7/hooks/state/checkpoint.md"
echo "lock" > "$CH7/hooks/state/canary-editing.lock"

CLAUDE_HOME="$CH7" LAUNCHCTL_BIN="$MOCK_DIR7/mock-launchctl" \
  bash "$UNINSTALL_SH" >"$CH7/.uninstall-stdout" 2>"$CH7/.uninstall-stderr" || true

# hooks/state/ preserved (nested under removed-foundation hooks/)
assert_path_exists "$CH7/hooks/state/checkpoint.md"        "T7.1: hooks/state/checkpoint.md preserved"
assert_path_exists "$CH7/hooks/state/canary-editing.lock"  "T7.2: hooks/state/canary-editing.lock preserved"

# Other hooks/ contents removed (foundation code)
assert_path_absent "$CH7/hooks/pre-write-guard.sh" "T7.3: hooks/pre-write-guard.sh removed (foundation code)"
assert_path_absent "$CH7/hooks/lib"                "T7.4: hooks/lib/ removed (foundation code)"

# =====================================================================
# T8 — S63 fingerprint match: user-edited foundation file PRESERVED
# =====================================================================
printf 'T8: fingerprint match — user-edited foundation preserved + diagnostic + provenance\n'

CH8="$(mk_tmp)"
MOCK_DIR8="$(mk_tmp)"
write_mock_launchctl "$MOCK_DIR8/mock-launchctl"

CLAUDE_HOME="$CH8" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" \
  >"$CH8/.install-stdout" 2>"$CH8/.install-stderr" || true

# User edit: append a line to a foundation file (sha256 mismatch vs baseline)
echo "# user edit appended at $(date -u +%s)" >> "$CH8/hooks/pre-write-guard.sh"

rc=0
CLAUDE_HOME="$CH8" LAUNCHCTL_BIN="$MOCK_DIR8/mock-launchctl" \
  bash "$UNINSTALL_SH" >"$CH8/.uninstall-stdout" 2>"$CH8/.uninstall-stderr" || rc=$?

assert_eq "0" "$rc" "T8.1: uninstall exits 0 on user-edited foundation"
assert_path_exists "$CH8/hooks/pre-write-guard.sh" "T8.2: user-edited foundation file PRESERVED"
assert_grep "user-edited foundation file preserved: hooks/pre-write-guard.sh" "$CH8/.uninstall-stderr" \
  "T8.3: preservation diagnostic on stderr"

prov8="$(ls "$CH8/logs"/uninstall-*.log 2>/dev/null | head -1)"
assert_grep "user_edited_foundation_count: 1" "$prov8" "T8.4: provenance count=1"
assert_grep "  - hooks/pre-write-guard.sh"     "$prov8" "T8.5: provenance lists edited path"

# =====================================================================
# T9 — S63 clean uninstall: no edits → user_edited_foundation_count=0
# =====================================================================
printf 'T9: clean uninstall — all foundation files match baseline; count=0\n'

CH9="$(mk_tmp)"
MOCK_DIR9="$(mk_tmp)"
write_mock_launchctl "$MOCK_DIR9/mock-launchctl"

CLAUDE_HOME="$CH9" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" \
  >"$CH9/.install-stdout" 2>"$CH9/.install-stderr" || true

rc=0
CLAUDE_HOME="$CH9" LAUNCHCTL_BIN="$MOCK_DIR9/mock-launchctl" \
  bash "$UNINSTALL_SH" >"$CH9/.uninstall-stdout" 2>"$CH9/.uninstall-stderr" || rc=$?

assert_eq "0" "$rc" "T9.1: uninstall exits 0 on clean state"

prov9="$(ls "$CH9/logs"/uninstall-*.log 2>/dev/null | head -1)"
assert_grep "user_edited_foundation_count: 0" "$prov9" "T9.2: provenance count=0"
assert_grep "fingerprint_check_skipped: false" "$prov9" "T9.3: provenance fingerprint not skipped"
assert_path_absent "$CH9/hooks/pre-write-guard.sh" "T9.4: clean foundation file removed"

# =====================================================================
# T10 — S63 --force-rm-edited removes user-edited foundation
# =====================================================================
printf 'T10: --force-rm-edited removes user-edited foundation\n'

CH10="$(mk_tmp)"
MOCK_DIR10="$(mk_tmp)"
write_mock_launchctl "$MOCK_DIR10/mock-launchctl"

CLAUDE_HOME="$CH10" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" \
  >"$CH10/.install-stdout" 2>"$CH10/.install-stderr" || true

echo "# user edit" >> "$CH10/hooks/pre-write-guard.sh"

rc=0
CLAUDE_HOME="$CH10" LAUNCHCTL_BIN="$MOCK_DIR10/mock-launchctl" \
  bash "$UNINSTALL_SH" --force-rm-edited \
  >"$CH10/.uninstall-stdout" 2>"$CH10/.uninstall-stderr" || rc=$?

assert_eq "0" "$rc" "T10.1: uninstall --force-rm-edited exits 0"
assert_path_absent "$CH10/hooks/pre-write-guard.sh" "T10.2: user-edited foundation REMOVED with flag"
assert_grep "user-edited foundation file removed (--force-rm-edited): hooks/pre-write-guard.sh" \
  "$CH10/.uninstall-stderr" "T10.3: removal warning on stderr"

prov10="$(ls "$CH10/logs"/uninstall-*.log 2>/dev/null | head -1)"
assert_grep "force_rm_edited: 1"               "$prov10" "T10.4: provenance records flag"

# =====================================================================
# T11 — S63 missing foundation-manifest.json (default) → exit 10
# =====================================================================
printf 'T11: missing foundation-manifest.json (default) → exit 10\n'

CH11="$(mk_tmp)"
MOCK_DIR11="$(mk_tmp)"
write_mock_launchctl "$MOCK_DIR11/mock-launchctl"

CLAUDE_HOME="$CH11" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" \
  >"$CH11/.install-stdout" 2>"$CH11/.install-stderr" || true

# Remove the manifest after install to simulate slice-tolerant install scenario
rm -f "$CH11/foundation-manifest.json"

rc=0
CLAUDE_HOME="$CH11" LAUNCHCTL_BIN="$MOCK_DIR11/mock-launchctl" \
  bash "$UNINSTALL_SH" >"$CH11/.uninstall-stdout" 2>"$CH11/.uninstall-stderr" || rc=$?

assert_eq "10" "$rc" "T11.1: missing manifest → exit 10"
assert_grep "foundation-manifest.json missing" "$CH11/.uninstall-stderr" "T11.2: missing-manifest diagnostic"
assert_path_exists "$CH11/hooks/pre-write-guard.sh" "T11.3: foundation files retained on refusal"

# =====================================================================
# T12 — S63 --force-remove falls back to basename allowlist
# =====================================================================
printf 'T12: --force-remove falls back to basename allowlist on missing manifest\n'

CH12="$(mk_tmp)"
MOCK_DIR12="$(mk_tmp)"
write_mock_launchctl "$MOCK_DIR12/mock-launchctl"

CLAUDE_HOME="$CH12" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" \
  >"$CH12/.install-stdout" 2>"$CH12/.install-stderr" || true

# Pre-seed user content to verify it's preserved even in fallback mode
mkdir -p "$CH12/my-user-project"
echo "user data" > "$CH12/my-user-project/notes.md"

rm -f "$CH12/foundation-manifest.json"

rc=0
CLAUDE_HOME="$CH12" LAUNCHCTL_BIN="$MOCK_DIR12/mock-launchctl" \
  bash "$UNINSTALL_SH" --force-remove \
  >"$CH12/.uninstall-stdout" 2>"$CH12/.uninstall-stderr" || rc=$?

assert_eq "0" "$rc" "T12.1: --force-remove exits 0 on missing manifest"
assert_path_absent "$CH12/hooks/pre-write-guard.sh" "T12.2: foundation removed via fallback"
assert_path_absent "$CH12/skills"                    "T12.3: skills/ removed via fallback"
assert_path_exists "$CH12/my-user-project/notes.md"  "T12.4: user content preserved through fallback"

prov12="$(ls "$CH12/logs"/uninstall-*.log 2>/dev/null | head -1)"
assert_grep "fingerprint_check_skipped: true" "$prov12" "T12.5: provenance notes skipped"
assert_grep "force_remove: 1"                 "$prov12" "T12.6: provenance records flag"

# =====================================================================
# Summary
# =====================================================================
printf '\n=== uninstall-happy-path-unit-test ===\n'
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
