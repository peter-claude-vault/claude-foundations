#!/bin/bash
# tests/sp08/install-g1-unit-test.sh
#
# Synthetic unit test for SP08 T-1 follow-up (S60) — G1 firewall family:
#   T1: G1-pre exit-code + diagnostic + 100ms timing + write-suppression
#   T2: G1-main equality + non-foundation content + no --force-install → exit 51
#   T3: G1-main + --force-install + correct I-UNDERSTAND-OVERWRITE-RISK sentinel → exit 0
#   T4: G1-main + --force-install + wrong sentinel → exit 51
#   T5: G1-main + --force-install + sentinel + foundation-only content → exit 0
#   T6: G1-main NOT triggered when CLAUDE_HOME != $HOME/.claude (regression sanity)
#   T7: G1-main NOT triggered when target dir empty (fresh-install path)
#
# Hermetic: each test creates its own tmpdir as $HOME (so $HOME/.claude is
# under tmpdir, not Peter's live tree). No mutation of live ~/.claude.
#
# R-23: bash 3.2 compat (macOS /bin/bash 3.2.57). No associative arrays.

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
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM

mk_tmp() {
  local d
  d="$(mktemp -d -t install-g1.XXXXXX)"
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

assert_le() {
  local actual="$1" upper="$2" label="$3"
  if [ "$actual" -le "$upper" ]; then
    printf '  PASS %s (%s ≤ %s)\n' "$label" "$actual" "$upper"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: %s > %s\n' "$label" "$actual" "$upper" >&2
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

assert_path_exists() {
  local path="$1" label="$2"
  if [ -e "$path" ]; then
    printf '  PASS %s (path exists: %s)\n' "$label" "$path"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (path missing: %s)\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

# --- prereq sanity ---
if [ ! -x "$INSTALL_SH" ]; then
  printf 'FAIL: install.sh not executable at %s\n' "$INSTALL_SH" >&2
  exit 7
fi

printf '\n=== T1: G1-pre (CLAUDE_HOME unset/empty preflight) ===\n'

# T1.1: exit 10 when CLAUDE_HOME unset
t1_root="$(mk_tmp)"
t1_stderr="$t1_root/stderr.log"
t1_rc=0
( unset CLAUDE_HOME; bash "$INSTALL_SH" >/dev/null 2>"$t1_stderr" ) || t1_rc=$?
assert_eq "10" "$t1_rc" "T1.1: CLAUDE_HOME unset → exit 10"

# T1.2: diagnostic message present
assert_grep "CLAUDE_HOME not set" "$t1_stderr" "T1.2: G1-pre diagnostic emitted"

# T1.3: timing under 100ms (warmed; cold-cache forgiveness)
# Warm bash + install.sh parse twice, then measure third invocation.
warm_root="$(mk_tmp)"
( unset CLAUDE_HOME; bash "$INSTALL_SH" >/dev/null 2>&1 ) || true
( unset CLAUDE_HOME; bash "$INSTALL_SH" >/dev/null 2>&1 ) || true
elapsed_ms=$(python3 - "$INSTALL_SH" <<'PY'
import os, subprocess, sys, time
env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}
# Drop CLAUDE_HOME explicitly
env.pop("CLAUDE_HOME", None)
start = time.monotonic_ns()
r = subprocess.run(["bash", sys.argv[1]], env=env, capture_output=True, timeout=5)
end = time.monotonic_ns()
print(int((end - start) / 1_000_000))
PY
)
assert_le "$elapsed_ms" "100" "T1.3: G1-pre exits within 100ms"

# T1.4: zero filesystem writes under $HOME when CLAUDE_HOME unset
# Strategy: empty $HOME tmpdir → run with CLAUDE_HOME unset → assert tree
# unchanged (only $HOME root entry remains; no children).
t14_home="$(mk_tmp)"
before_count=$(find "$t14_home" 2>/dev/null | wc -l | awk '{print $1}')
( unset CLAUDE_HOME; HOME="$t14_home" bash "$INSTALL_SH" >/dev/null 2>&1 ) || true
after_count=$(find "$t14_home" 2>/dev/null | wc -l | awk '{print $1}')
assert_eq "$before_count" "$after_count" "T1.4: G1-pre creates no files under \$HOME"

printf '\n=== T2: G1-main equality + non-foundation + no --force-install → exit 51 ===\n'

t2_home="$(mk_tmp)"
mkdir -p "$t2_home/.claude"
# Pre-seed non-foundation entry
printf 'arbitrary user content\n' > "$t2_home/.claude/random_user_file.txt"
t2_stderr="$t2_home/stderr.log"
t2_rc=0
( HOME="$t2_home" CLAUDE_HOME="$t2_home/.claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" >/dev/null 2>"$t2_stderr" ) || t2_rc=$?
assert_eq "51" "$t2_rc" "T2.1: non-foundation + no --force-install → exit 51"
assert_grep "G1-main fired" "$t2_stderr" "T2.2: G1-main diagnostic emitted"
assert_grep "I-UNDERSTAND-OVERWRITE-RISK" "$t2_stderr" "T2.3: G1-main diagnostic names sentinel"

printf '\n=== T3: G1-main + --force-install + correct sentinel → exit 0 ===\n'

t3_home="$(mk_tmp)"
mkdir -p "$t3_home/.claude"
printf 'arbitrary user content\n' > "$t3_home/.claude/random_user_file.txt"
t3_stderr="$t3_home/stderr.log"
t3_stdout="$t3_home/stdout.log"
t3_rc=0
( HOME="$t3_home" CLAUDE_HOME="$t3_home/.claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --force-install --apply >"$t3_stdout" 2>"$t3_stderr" \
  <<<"I-UNDERSTAND-OVERWRITE-RISK" ) || t3_rc=$?
assert_eq "0" "$t3_rc" "T3.1: correct sentinel + --force-install → exit 0"
assert_grep "sentinel verified" "$t3_stdout" "T3.2: sentinel-verified info line emitted (stdout)"
# Verify install actually proceeded (provenance log written)
t3_log_count=$(find "$t3_home/.claude/logs" -name 'install-*.log' 2>/dev/null | wc -l | awk '{print $1}')
if [ "$t3_log_count" -ge "1" ]; then
  printf '  PASS T3.3: provenance log written (count=%s)\n' "$t3_log_count"
  PASS=$((PASS+1))
else
  printf '  FAIL T3.3: no provenance log under %s/.claude/logs\n' "$t3_home" >&2
  FAIL=$((FAIL+1))
fi

printf '\n=== T4: G1-main + --force-install + wrong sentinel → exit 51 ===\n'

t4_home="$(mk_tmp)"
mkdir -p "$t4_home/.claude"
printf 'arbitrary\n' > "$t4_home/.claude/random.txt"
t4_stderr="$t4_home/stderr.log"
t4_rc=0
( HOME="$t4_home" CLAUDE_HOME="$t4_home/.claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --force-install >/dev/null 2>"$t4_stderr" \
  <<<"WRONG-STRING" ) || t4_rc=$?
assert_eq "51" "$t4_rc" "T4.1: wrong sentinel → exit 51"
assert_grep "sentinel mismatch" "$t4_stderr" "T4.2: sentinel-mismatch diagnostic emitted"

# T4.5: stdin EOF (no sentinel typed at all) → exit 51
t45_home="$(mk_tmp)"
mkdir -p "$t45_home/.claude"
printf 'arbitrary\n' > "$t45_home/.claude/random.txt"
t45_stderr="$t45_home/stderr.log"
t45_rc=0
( HOME="$t45_home" CLAUDE_HOME="$t45_home/.claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --force-install </dev/null >/dev/null 2>"$t45_stderr" ) || t45_rc=$?
assert_eq "51" "$t45_rc" "T4.5: stdin EOF → exit 51"
assert_grep "stdin EOF" "$t45_stderr" "T4.6: EOF-specific diagnostic emitted"

printf '\n=== T5: G1-main + --force-install + sentinel + foundation-only target → exit 0 ===\n'

t5_home="$(mk_tmp)"
# Foundation-only: pre-seed only foundation-known top-level entries (empty)
mkdir -p "$t5_home/.claude/hooks" "$t5_home/.claude/skills"
t5_stderr="$t5_home/stderr.log"
t5_rc=0
( HOME="$t5_home" CLAUDE_HOME="$t5_home/.claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --force-install --apply >/dev/null 2>"$t5_stderr" \
  <<<"I-UNDERSTAND-OVERWRITE-RISK" ) || t5_rc=$?
assert_eq "0" "$t5_rc" "T5.1: foundation-only content → exit 0"
# Note: g1_main_has_non_foundation_content returns 1 for foundation-only,
# so G1-main is skipped entirely; sentinel handshake is a no-op (no prompt
# emitted). We assert install proceeded:
t5_log_count=$(find "$t5_home/.claude/logs" -name 'install-*.log' 2>/dev/null | wc -l | awk '{print $1}')
if [ "$t5_log_count" -ge "1" ]; then
  printf '  PASS T5.2: provenance log written (foundation-only path)\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T5.2: no provenance log written\n' >&2
  FAIL=$((FAIL+1))
fi

printf '\n=== T6: G1-main NOT triggered when CLAUDE_HOME != $HOME/.claude ===\n'

t6_home="$(mk_tmp)"
t6_claude="$(mk_tmp)"  # Different tmpdir; CLAUDE_HOME != $HOME/.claude
# Pre-seed CLAUDE_HOME with non-foundation content — should still proceed
# because equality-with-$HOME/.claude is false.
printf 'arbitrary\n' > "$t6_claude/random.txt"
t6_stderr="$t6_home/stderr.log"
t6_rc=0
( HOME="$t6_home" CLAUDE_HOME="$t6_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --force-install --apply >/dev/null 2>"$t6_stderr" ) || t6_rc=$?
assert_eq "0" "$t6_rc" "T6.1: CLAUDE_HOME != \$HOME/.claude → install proceeds"

printf '\n=== T7: G1-main NOT triggered when target dir empty (fresh install path) ===\n'

t7_home="$(mk_tmp)"
# Don't pre-create $HOME/.claude — install will mkdir it. G1-main has
# `[ -d "$CLAUDE_HOME" ]` guard, so it's a no-op for non-existent target.
t7_stderr="$t7_home/stderr.log"
t7_rc=0
( HOME="$t7_home" CLAUDE_HOME="$t7_home/.claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --apply >/dev/null 2>"$t7_stderr" ) || t7_rc=$?
assert_eq "0" "$t7_rc" "T7.1: fresh \$HOME/.claude → install proceeds (no G1-main trip)"

printf '\n=== install-g1-unit-test ===\n'
printf 'PASS: %s\n' "$PASS"
printf 'FAIL: %s\n' "$FAIL"
[ "$FAIL" = "0" ]
