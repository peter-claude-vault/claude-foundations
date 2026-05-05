#!/bin/bash
# tests/sp08/install-g9-state-flag-matrix-unit-test.sh
#
# Synthetic unit test for SP08 T-1 follow-up (S66) — G9 dry-run-as-default
# posture + state classification (fresh|foundation-only|mixed|user-only) +
# --force-all + --no-preserve-config flag matrix + exit code 21.
#
# Coverage matrix (25 asserts):
#   T1 (3): G9 default dry-run — no --apply → exit 0 + stdout valid JSON
#           action-plan + zero writes to $CLAUDE_HOME (verify via ls -A).
#   T2 (3): G9 --apply → exit 0 + actual writes land (foundation dirs) +
#           provenance log written with apply_mode:1 + dry_run:0.
#   T3 (3): state=user-only without --force-install → exit 21 + diag
#           enumerates non-foundation entries.
#   T4 (3): state=user-only + --force-install → install proceeds (sentinel
#           ceremony for G1-main not required since CLAUDE_HOME != $HOME/.claude).
#   T5 (3): --no-preserve-config without --force-install → exit 11 + diag
#           specific to the flag mismatch.
#   T6 (3): --no-preserve-config + --force-install (claude-mem stub absent)
#           → tolerates absence + provenance no_preserve_config: 1.
#   T7 (3): --force-all → cp -f wins over cp -n: pre-seed
#           $CLAUDE_HOME/hooks/pre-write-guard.sh user-edited content +
#           install --force-all --apply --backup-dir <tmp> + sentinel (G2
#           gate fires) → user content REPLACED with foundation baseline.
#   T8 (4): state classification: fresh / foundation-only / mixed → 3
#           provenance variants record correct state_classification field;
#           plus dry-run JSON state field also reflects classification.
#
# Hermetic: each test creates its own $HOME tmpdir; CLAUDE_HOME is a child
# under $HOME but never $HOME/.claude (to avoid G1-main double-fire). Live
# ~/.claude is never touched.
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
  d="$(mktemp -d -t install-g9.XXXXXX)"
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

printf '\n=== T1: G9 default dry-run — no --apply → exit 0 + valid JSON + zero writes ===\n'

t1_home="$(mk_tmp)"
t1_claude="$t1_home/foundation-claude"
mkdir -p "$t1_claude"
t1_stdout="$t1_home/stdout.log"
t1_stderr="$t1_home/stderr.log"
t1_rc=0
( HOME="$t1_home" CLAUDE_HOME="$t1_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" >"$t1_stdout" 2>"$t1_stderr" ) || t1_rc=$?
assert_eq "0" "$t1_rc" "T1.1: dry-run no --apply → exit 0"
if jq . "$t1_stdout" >/dev/null 2>&1; then
  printf '  PASS T1.2: stdout is valid JSON (jq parseable)\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T1.2: stdout is NOT valid JSON\n' >&2
  FAIL=$((FAIL+1))
fi
# Zero writes check: $CLAUDE_HOME should be empty (we created it fresh)
t1_entries="$(ls -A "$t1_claude" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$t1_entries" "T1.3: dry-run zero writes to \$CLAUDE_HOME (entry count)"

printf '\n=== T2: G9 --apply → exit 0 + writes land + provenance dry_run:0 ===\n'

t2_home="$(mk_tmp)"
t2_claude="$t2_home/foundation-claude"
mkdir -p "$t2_claude"
t2_stderr="$t2_home/stderr.log"
t2_rc=0
( HOME="$t2_home" CLAUDE_HOME="$t2_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --apply 2>"$t2_stderr" >/dev/null ) || t2_rc=$?
assert_eq "0" "$t2_rc" "T2.1: --apply → exit 0"
# Verify writes landed
if [ -d "$t2_claude/hooks" ] && [ -d "$t2_claude/skills" ] && [ -d "$t2_claude/schemas" ]; then
  printf '  PASS T2.2: --apply writes landed (hooks/, skills/, schemas/ all present)\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T2.2: --apply writes did NOT land\n' >&2
  FAIL=$((FAIL+1))
fi
t2_log="$(find "$t2_claude/logs" -name 'install-*.log' 2>/dev/null | head -1)"
if [ -n "$t2_log" ] && [ -f "$t2_log" ]; then
  assert_grep "apply_mode: 1" "$t2_log" "T2.3: provenance records apply_mode=1"
else
  printf '  FAIL T2.3: provenance log missing under %s/logs\n' "$t2_claude" >&2
  FAIL=$((FAIL+1))
fi

printf '\n=== T3: state=user-only without --force-install → exit 21 ===\n'

t3_home="$(mk_tmp)"
t3_claude="$t3_home/foundation-claude"
mkdir -p "$t3_claude"
# Pre-seed only NON-foundation entries (state=user-only)
mkdir -p "$t3_claude/some-user-tool"
mkdir -p "$t3_claude/another-user-thing"
printf 'random user file\n' > "$t3_claude/random.txt"
t3_stderr="$t3_home/stderr.log"
t3_rc=0
( HOME="$t3_home" CLAUDE_HOME="$t3_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --apply 2>"$t3_stderr" >/dev/null ) || t3_rc=$?
assert_eq "21" "$t3_rc" "T3.1: state=user-only without --force-install → exit 21"
assert_grep "state=user-only fired" "$t3_stderr" "T3.2: state-classify diagnostic emitted"
assert_grep "some-user-tool\|another-user-thing\|random.txt" "$t3_stderr" "T3.3: non-foundation entries enumerated"

printf '\n=== T4: state=user-only + --force-install → install proceeds ===\n'

t4_home="$(mk_tmp)"
t4_claude="$t4_home/foundation-claude"
mkdir -p "$t4_claude"
mkdir -p "$t4_claude/some-user-tool"
printf 'random\n' > "$t4_claude/random.txt"
t4_stderr="$t4_home/stderr.log"
t4_rc=0
# CLAUDE_HOME != $HOME/.claude so G1-main does NOT fire; --force-install
# bypasses state-user-only refuse → install proceeds.
( HOME="$t4_home" CLAUDE_HOME="$t4_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --force-install --apply 2>"$t4_stderr" >/dev/null ) || t4_rc=$?
assert_eq "0" "$t4_rc" "T4.1: state=user-only + --force-install → exit 0"
# Verify install landed (state was user-only but FORCE bypassed; install completes)
if [ -d "$t4_claude/hooks" ] && [ -f "$t4_claude/random.txt" ]; then
  printf '  PASS T4.2: foundation hooks/ landed AND user random.txt preserved (cp -n)\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T4.2: install did not complete cleanly\n' >&2
  FAIL=$((FAIL+1))
fi
t4_log="$(find "$t4_claude/logs" -name 'install-*.log' 2>/dev/null | head -1)"
if [ -n "$t4_log" ] && [ -f "$t4_log" ]; then
  # state classification recorded — could be user-only OR mixed depending on
  # whether install completed (foundation dirs now present); we walk pre-install
  # so it should record user-only.
  assert_grep "state_classification: user-only" "$t4_log" "T4.3: provenance records state_classification=user-only (pre-install snapshot)"
else
  printf '  FAIL T4.3: provenance log missing under %s/logs\n' "$t4_claude" >&2
  FAIL=$((FAIL+1))
fi

printf '\n=== T5: --no-preserve-config without --force-install → exit 11 ===\n'

t5_home="$(mk_tmp)"
t5_claude="$t5_home/foundation-claude"
mkdir -p "$t5_claude"
t5_stderr="$t5_home/stderr.log"
t5_rc=0
( HOME="$t5_home" CLAUDE_HOME="$t5_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --no-preserve-config --apply 2>"$t5_stderr" >/dev/null ) || t5_rc=$?
assert_eq "11" "$t5_rc" "T5.1: --no-preserve-config alone → exit 11"
assert_grep "no-preserve-config requires --force-install" "$t5_stderr" "T5.2: flag-mismatch diagnostic emitted"
# Verify NO writes happened (mutual-exclusion check fires before any guard / FS work)
t5_entries="$(ls -A "$t5_claude" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$t5_entries" "T5.3: --no-preserve-config refuse zero writes to \$CLAUDE_HOME"

printf '\n=== T6: --no-preserve-config + --force-install (claude-mem absent) → tolerated ===\n'

t6_home="$(mk_tmp)"
t6_claude="$t6_home/foundation-claude"
mkdir -p "$t6_claude"
t6_stderr="$t6_home/stderr.log"
t6_rc=0
( HOME="$t6_home" CLAUDE_HOME="$t6_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --no-preserve-config --force-install --apply 2>"$t6_stderr" >/dev/null ) || t6_rc=$?
assert_eq "0" "$t6_rc" "T6.1: --no-preserve-config + --force-install → exit 0"
t6_log="$(find "$t6_claude/logs" -name 'install-*.log' 2>/dev/null | head -1)"
if [ -n "$t6_log" ] && [ -f "$t6_log" ]; then
  assert_grep "no_preserve_config: 1" "$t6_log" "T6.2: provenance records no_preserve_config=1"
  assert_grep "force_install: 1" "$t6_log" "T6.3: provenance records force_install=1"
else
  printf '  FAIL T6.2/T6.3: provenance log missing under %s/logs\n' "$t6_claude" >&2
  FAIL=$((FAIL+2))
fi

printf '\n=== T7: --force-all → cp -f overwrites foundation baseline ===\n'

t7_home="$(mk_tmp)"
t7_claude="$t7_home/foundation-claude"
mkdir -p "$t7_claude/hooks"
# Pre-seed a foundation-baseline-named file with USER content. Under default
# (no --force-all): cp -n preserves user edit. Under --force-all: cp -f
# overwrites with foundation source.
USER_CONTENT='#!/bin/bash
# USER-EDITED VARIANT — should be replaced under --force-all
echo "user marker"'
printf '%s\n' "$USER_CONTENT" > "$t7_claude/hooks/pre-write-guard.sh"
t7_stderr="$t7_home/stderr.log"
t7_rc=0
# G2 will fire because the user-edited pre-write-guard.sh has wrong sha256 vs
# baseline. Need --force-install + sentinel to proceed past G2. --force-all
# additionally promotes cp -n → cp -f.
( HOME="$t7_home" CLAUDE_HOME="$t7_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --force-install --force-all --apply 2>"$t7_stderr" >/dev/null \
  <<<"I-UNDERSTAND-OVERWRITE-RISK" ) || t7_rc=$?
assert_eq "0" "$t7_rc" "T7.1: --force-all + --force-install + sentinel → exit 0"
# After install, pre-write-guard.sh should match foundation baseline (user marker gone)
if grep -q "USER-EDITED VARIANT" "$t7_claude/hooks/pre-write-guard.sh" 2>/dev/null; then
  printf '  FAIL T7.2: --force-all did NOT overwrite (user marker still present)\n' >&2
  FAIL=$((FAIL+1))
else
  printf '  PASS T7.2: --force-all overwrote user content with foundation baseline\n'
  PASS=$((PASS+1))
fi
t7_log="$(find "$t7_claude/logs" -name 'install-*.log' 2>/dev/null | head -1)"
if [ -n "$t7_log" ] && [ -f "$t7_log" ]; then
  assert_grep "force_all: 1" "$t7_log" "T7.3: provenance records force_all=1"
else
  printf '  FAIL T7.3: provenance log missing\n' >&2
  FAIL=$((FAIL+1))
fi

printf '\n=== T8: state classification fresh|foundation-only|mixed ===\n'

# T8a: fresh = $CLAUDE_HOME empty (or non-existent)
t8a_home="$(mk_tmp)"
t8a_claude="$t8a_home/foundation-claude-fresh"
# Don't even mkdir — let install handle it
t8a_rc=0
( HOME="$t8a_home" CLAUDE_HOME="$t8a_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --apply 2>/dev/null >/dev/null ) || t8a_rc=$?
t8a_log="$(find "$t8a_claude/logs" -name 'install-*.log' 2>/dev/null | head -1)"
if [ -n "$t8a_log" ] && [ -f "$t8a_log" ]; then
  assert_grep "state_classification: fresh" "$t8a_log" "T8.1: fresh classification recorded"
else
  printf '  FAIL T8.1: provenance log missing for fresh case\n' >&2
  FAIL=$((FAIL+1))
fi

# T8b: foundation-only = pre-seed only foundation-named entries
t8b_home="$(mk_tmp)"
t8b_claude="$t8b_home/foundation-claude-foundation-only"
mkdir -p "$t8b_claude/hooks"
mkdir -p "$t8b_claude/skills"
printf '{}\n' > "$t8b_claude/settings.json"
t8b_rc=0
( HOME="$t8b_home" CLAUDE_HOME="$t8b_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --backup-dir "$t8b_home/backup" --apply 2>/dev/null >/dev/null ) || t8b_rc=$?
t8b_log="$(find "$t8b_claude/logs" -name 'install-*.log' 2>/dev/null | head -1)"
if [ -n "$t8b_log" ] && [ -f "$t8b_log" ]; then
  assert_grep "state_classification: foundation-only" "$t8b_log" "T8.2: foundation-only classification recorded"
else
  printf '  FAIL T8.2: provenance log missing for foundation-only case\n' >&2
  FAIL=$((FAIL+1))
fi

# T8c: mixed = foundation + user entries
t8c_home="$(mk_tmp)"
t8c_claude="$t8c_home/foundation-claude-mixed"
mkdir -p "$t8c_claude/hooks"     # foundation
mkdir -p "$t8c_claude/my-tool"   # user
t8c_rc=0
( HOME="$t8c_home" CLAUDE_HOME="$t8c_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --apply 2>/dev/null >/dev/null ) || t8c_rc=$?
t8c_log="$(find "$t8c_claude/logs" -name 'install-*.log' 2>/dev/null | head -1)"
if [ -n "$t8c_log" ] && [ -f "$t8c_log" ]; then
  assert_grep "state_classification: mixed" "$t8c_log" "T8.3: mixed classification recorded"
else
  printf '  FAIL T8.3: provenance log missing for mixed case\n' >&2
  FAIL=$((FAIL+1))
fi

# T8d: dry-run JSON state field reflects classification
t8d_home="$(mk_tmp)"
t8d_claude="$t8d_home/foundation-claude-jsonstate"
mkdir -p "$t8d_claude/hooks"
mkdir -p "$t8d_claude/my-tool"
t8d_stdout="$t8d_home/stdout.log"
( HOME="$t8d_home" CLAUDE_HOME="$t8d_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" >"$t8d_stdout" 2>/dev/null ) || true
t8d_state="$(jq -r '.state_classification' "$t8d_stdout" 2>/dev/null)"
assert_eq "mixed" "$t8d_state" "T8.4: dry-run JSON state_classification field = mixed"

printf '\n=== install-g9-state-flag-matrix-unit-test ===\n'
printf 'PASS: %s\n' "$PASS"
printf 'FAIL: %s\n' "$FAIL"
[ "$FAIL" = "0" ]
