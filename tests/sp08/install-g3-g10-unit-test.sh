#!/bin/bash
# tests/sp08/install-g3-g10-unit-test.sh
#
# Synthetic unit test for SP08 T-1 follow-up (S65) — G3 + G4 + G5 + G8 + G10
# firewall guards (final T-1 batch slice; G9 dry-run-default deferred to S66).
#
# Coverage matrix:
#   T1 (3): G3 happy-path — --backup-dir writable + round-trip → 0 + provenance
#           records g3_proof_of_life_passed=1 + g3_backup_dir recorded
#   T2 (3): G3 unwritable backup dir (read-only parent) → 53 + diagnostic
#   T3 (3): G3 destructive op pending (settings.json pre-exists) + no
#           --backup-dir → 53 + "no backup → no install" diagnostic
#   T4 (3): G4 vault-symlink under $CLAUDE_HOME (creating an actual symlink
#           into ~/Documents/Obsidian Vault) → 54 + diagnostic
#           [Test-mocked vault: synthesize a fake vault dir and reach into
#           $HOME/Documents/Obsidian\ Vault. NO --force override.]
#   T5 (3): G5 PLANS_HOME with NN-*/ + no --retrofit-existing → 55 + diag
#   T6 (3): G5 PLANS_HOME with NN-*/ + --retrofit-existing → 0 + warn
#   T7 (3): G8 UID-0 (PATH-shimmed `id` returning 0 for -u) → 58 + diag
#   T8 (2): G10 provenance write failure (logs/ chmod-blocked) → 11 + diag
#
# Hermetic: each test creates its own $HOME tmpdir; CLAUDE_HOME points under it
# but is intentionally NOT $HOME/.claude (avoids G1-main double-fire). PLANS_HOME
# defaults to $HOME/.claude-plans which is a clean tmpdir-relative path.
# Live ~/.claude is never touched.
#
# R-23: bash 3.2 compat. No associative arrays.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"

# --- harness ---
PASS=0
FAIL=0
TMPDIRS=""

cleanup() {
  for d in $TMPDIRS; do
    [ -n "$d" ] && [ -d "$d" ] && chmod -R u+w "$d" 2>/dev/null
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM

mk_tmp() {
  local d
  d="$(mktemp -d -t install-g3g10.XXXXXX)"
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

assert_grep() {
  local pattern="$1" file="$2" label="$3"
  if grep -q -- "$pattern" "$file" 2>/dev/null; then
    printf '  PASS %s (pattern: %s)\n' "$label" "$pattern"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (pattern not found: %s in %s)\n' "$label" "$pattern" "$file" >&2
    FAIL=$((FAIL+1))
  fi
}

# --- prereq sanity ---
if [ ! -x "$INSTALL_SH" ]; then
  printf 'FAIL: install.sh not executable at %s\n' "$INSTALL_SH" >&2
  exit 7
fi

printf '\n=== T1: G3 happy-path — --backup-dir writable + round-trip → exit 0 ===\n'

t1_home="$(mk_tmp)"
t1_claude="$t1_home/foundation-claude"
mkdir -p "$t1_claude"
t1_backup="$t1_home/backup-target"
t1_stdout="$t1_home/stdout.log"
t1_stderr="$t1_home/stderr.log"
t1_rc=0
( HOME="$t1_home" CLAUDE_HOME="$t1_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --backup-dir "$t1_backup" --apply >"$t1_stdout" 2>"$t1_stderr" ) || t1_rc=$?
assert_eq "0" "$t1_rc" "T1.1: --backup-dir writable + round-trip → exit 0"
assert_grep "G3: backup proof-of-life passed" "$t1_stdout" "T1.2: G3 success info emitted"

t1_log="$(find "$t1_claude/logs" -name 'install-*.log' 2>/dev/null | head -1)"
if [ -n "$t1_log" ] && [ -f "$t1_log" ]; then
  assert_grep "g3_proof_of_life_passed: 1" "$t1_log" "T1.3: provenance records g3_proof_of_life_passed=1"
else
  printf '  FAIL T1.3: provenance log missing under %s/logs\n' "$t1_claude" >&2
  FAIL=$((FAIL+1))
fi

printf '\n=== T2: G3 unwritable backup dir → exit 53 ===\n'

t2_home="$(mk_tmp)"
t2_claude="$t2_home/foundation-claude"
mkdir -p "$t2_claude"
# Read-only parent: backup-dir cannot be created
t2_ro_parent="$t2_home/readonly-parent"
mkdir -p "$t2_ro_parent"
chmod 0555 "$t2_ro_parent"
t2_backup="$t2_ro_parent/backup-target"
t2_stderr="$t2_home/stderr.log"
t2_rc=0
( HOME="$t2_home" CLAUDE_HOME="$t2_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --backup-dir "$t2_backup" 2>"$t2_stderr" ) || t2_rc=$?
chmod 0755 "$t2_ro_parent" 2>/dev/null  # restore for cleanup
assert_eq "53" "$t2_rc" "T2.1: unwritable --backup-dir → exit 53"
assert_grep "G3 fired" "$t2_stderr" "T2.2: G3 diagnostic emitted"
assert_grep "not creatable\|not writable" "$t2_stderr" "T2.3: G3 unwritable diagnostic specific"

printf '\n=== T3: G3 settings.json pre-exists + no --backup-dir → exit 53 ===\n'

t3_home="$(mk_tmp)"
t3_claude="$t3_home/foundation-claude"
mkdir -p "$t3_claude"
# Pre-seed settings.json (the destructive-op trigger for G3)
printf '{"userKey": "preexisting"}\n' > "$t3_claude/settings.json"
t3_stderr="$t3_home/stderr.log"
t3_rc=0
( HOME="$t3_home" CLAUDE_HOME="$t3_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" 2>"$t3_stderr" ) || t3_rc=$?
assert_eq "53" "$t3_rc" "T3.1: pre-existing settings.json + no --backup-dir → exit 53"
assert_grep "G3 fired" "$t3_stderr" "T3.2: G3 diagnostic emitted"
assert_grep "destructive op pending" "$t3_stderr" "T3.3: G3 'destructive op pending' diagnostic specific"

printf '\n=== T4: G4 vault-symlink under $CLAUDE_HOME → exit 54 (no override) ===\n'

t4_home="$(mk_tmp)"
t4_claude="$t4_home/foundation-claude"
mkdir -p "$t4_claude"
# Synthesize a fake vault under HOME/Documents/Obsidian Vault and reach
# from CLAUDE_HOME via symlink (simulates April-13 vault-clobber scenario).
t4_fake_vault="$t4_home/Documents/Obsidian Vault"
mkdir -p "$t4_fake_vault/Plans"
ln -s "$t4_fake_vault/Plans" "$t4_claude/Plans"
t4_stderr="$t4_home/stderr.log"
t4_rc=0
( HOME="$t4_home" CLAUDE_HOME="$t4_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --force-install 2>"$t4_stderr" <<<"I-UNDERSTAND-OVERWRITE-RISK" ) || t4_rc=$?
assert_eq "54" "$t4_rc" "T4.1: vault symlink under \$CLAUDE_HOME + --force-install → exit 54 (NO override)"
assert_grep "G4 fired" "$t4_stderr" "T4.2: G4 diagnostic emitted"
assert_grep "Plans -> .*Obsidian Vault" "$t4_stderr" "T4.3: G4 per-violation symlink path listed"

printf '\n=== T5: G5 PLANS_HOME with NN-*/ + no --retrofit-existing → exit 55 ===\n'

t5_home="$(mk_tmp)"
t5_claude="$t5_home/foundation-claude"
mkdir -p "$t5_claude"
mkdir -p "$t5_home/.claude-plans/01-existing-plan"
mkdir -p "$t5_home/.claude-plans/42-another-plan"
t5_stderr="$t5_home/stderr.log"
t5_rc=0
( HOME="$t5_home" CLAUDE_HOME="$t5_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" 2>"$t5_stderr" ) || t5_rc=$?
assert_eq "55" "$t5_rc" "T5.1: PLANS_HOME with NN-*/ + no --retrofit-existing → exit 55"
assert_grep "G5 fired" "$t5_stderr" "T5.2: G5 diagnostic emitted"
assert_grep "01-existing-plan\|42-another-plan" "$t5_stderr" "T5.3: G5 per-plan listing emitted"

printf '\n=== T6: G5 PLANS_HOME with NN-*/ + --retrofit-existing → exit 0 + warn ===\n'

t6_home="$(mk_tmp)"
t6_claude="$t6_home/foundation-claude"
mkdir -p "$t6_claude"
mkdir -p "$t6_home/.claude-plans/01-existing-plan"
t6_stderr="$t6_home/stderr.log"
t6_stdout="$t6_home/stdout.log"
t6_rc=0
( HOME="$t6_home" CLAUDE_HOME="$t6_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --retrofit-existing --apply >"$t6_stdout" 2>"$t6_stderr" ) || t6_rc=$?
assert_eq "0" "$t6_rc" "T6.1: PLANS_HOME with NN-*/ + --retrofit-existing → exit 0"
assert_grep "G5: --retrofit-existing supplied" "$t6_stderr" "T6.2: G5 retrofit-stub warning emitted"
assert_grep "v2.1 retrofit logic NOT YET IMPLEMENTED" "$t6_stderr" "T6.3: G5 v2.1-deferred warning specific"

printf '\n=== T7: G8 UID-0 (PATH-shimmed id -u) → exit 58 ===\n'

t7_home="$(mk_tmp)"
t7_claude="$t7_home/foundation-claude"
mkdir -p "$t7_claude"
t7_shim_dir="$(mk_tmp)"
cat > "$t7_shim_dir/id" <<'IDSHIM'
#!/bin/bash
# Test shim — only on PATH for this test invocation. Returns UID 0 unconditionally.
if [ "$1" = "-u" ]; then echo "0"; exit 0; fi
exec /usr/bin/id "$@"
IDSHIM
chmod +x "$t7_shim_dir/id"
t7_stderr="$t7_home/stderr.log"
t7_rc=0
( PATH="$t7_shim_dir:$PATH" HOME="$t7_home" CLAUDE_HOME="$t7_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" 2>"$t7_stderr" ) || t7_rc=$?
assert_eq "58" "$t7_rc" "T7.1: shimmed UID-0 → exit 58"
assert_grep "G8 fired" "$t7_stderr" "T7.2: G8 diagnostic emitted"
assert_grep "UID 0\|root" "$t7_stderr" "T7.3: G8 root-refuse diagnostic specific"

printf '\n=== T8: G10 provenance write failure (logs/ unwritable) → exit 11 ===\n'

t8_home="$(mk_tmp)"
t8_claude="$t8_home/foundation-claude"
# Pre-create $CLAUDE_HOME with logs/ as a regular file (not a directory) —
# install.sh's mkdir -p succeeds for other dirs but the provenance write at
# Step 14 will fail because logs/ exists as a file, not a directory.
# Wait: Step 1 mkdir -p "$CLAUDE_HOME/logs" would CONVERT a regular file to a
# directory? No — mkdir -p fails with EEXIST if path is a file, returning
# non-zero. install.sh exits 11 from mkdir failure (Step 1 short-circuit).
#
# Alternative G10-isolated test: let install.sh proceed normally through
# Step 1-13, then make logs/ unwritable (chmod 0555) just before Step 14.
# Cannot inject mid-script without modifying install.sh, so the cleanest
# G10-only fixture is: Step 1 mkdir succeeds (logs/ created with default
# mode), then we chmod logs/ read-only, then... no, Step 1 happens after
# argv parse + all guards, and we can't intervene.
#
# Pragmatic approach: prove G10 path via mkdir failure on logs/ specifically.
# Pre-seed CLAUDE_HOME/logs as a read-only directory (mkdir -p is idempotent
# on existing dirs; cp -n won't write into it; the provenance write at
# Step 14 (`> "$log_path"`) WILL fail since the directory rejects new files).
mkdir -p "$t8_claude/logs"
chmod 0555 "$t8_claude/logs"
t8_stderr="$t8_home/stderr.log"
t8_rc=0
( HOME="$t8_home" CLAUDE_HOME="$t8_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --apply 2>"$t8_stderr" ) || t8_rc=$?
chmod 0755 "$t8_claude/logs" 2>/dev/null  # restore for cleanup
assert_eq "11" "$t8_rc" "T8.1: provenance log write failure → exit 11"
assert_grep "G10: provenance log write failed\|provenance log write failed" "$t8_stderr" "T8.2: G10 diagnostic emitted"

printf '\n=== install-g3-g10-unit-test ===\n'
printf 'PASS: %s\n' "$PASS"
printf 'FAIL: %s\n' "$FAIL"
[ "$FAIL" = "0" ]
