#!/bin/bash
# tests/sp08/install-g2-unit-test.sh
#
# Synthetic unit test for SP08 T-1 follow-up (S64) — G2 firewall:
#   T1: clean fresh-install (no foundation files seeded) → G2 no-op → exit 0
#       + provenance g2_violation_count=0 (no g2_violations: block)
#   T2: pre-seed edited foundation file (hooks/pre-write-guard.sh sha256 drift)
#       + no --force-install → exit 52 + per-violation diagnostic + path on stderr
#   T3: same pre-seed + --force-install + correct I-UNDERSTAND-APRIL-13 sentinel
#       → exit 0 + sentinel-verified info + cp -n preserves user edit byte-identical
#       + provenance g2_violation_count > 0 with g2_violations: listing
#   T4: same pre-seed + --force-install + EOF stdin → exit 52 + EOF diagnostic
#       distinct from G1-main (prefix "G2 fired:" vs "G1-main fired:")
#
# Hermetic: each test creates its own $HOME tmpdir; CLAUDE_HOME points under it
# but is intentionally NOT $HOME/.claude (avoids G1-main double-fire). Live
# ~/.claude is never touched.
#
# R-23: bash 3.2 compat. No associative arrays.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
MANIFEST="$REPO_ROOT/foundation-manifest.json"

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
  d="$(mktemp -d -t install-g2.XXXXXX)"
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

assert_no_grep() {
  local pattern="$1" file="$2" label="$3"
  if grep -q -- "$pattern" "$file" 2>/dev/null; then
    printf '  FAIL %s (unexpected pattern present: %s in %s)\n' "$label" "$pattern" "$file" >&2
    FAIL=$((FAIL+1))
  else
    printf '  PASS %s (pattern absent: %s)\n' "$label" "$pattern"
    PASS=$((PASS+1))
  fi
}

# --- prereq sanity ---
if [ ! -x "$INSTALL_SH" ]; then
  printf 'FAIL: install.sh not executable at %s\n' "$INSTALL_SH" >&2
  exit 7
fi
if [ ! -f "$MANIFEST" ]; then
  printf 'FAIL: foundation-manifest.json not present at %s\n' "$MANIFEST" >&2
  exit 7
fi

# Confirm hooks/pre-write-guard.sh is in baseline (used as drift target T2-T4)
if ! jq -e '.files[] | select(.path == "hooks/pre-write-guard.sh")' "$MANIFEST" >/dev/null 2>&1; then
  printf 'FAIL: foundation-manifest.json baseline missing hooks/pre-write-guard.sh\n' >&2
  exit 7
fi

printf '\n=== T1: clean fresh-install (no foundation files seeded) → G2 no-op ===\n'

t1_home="$(mk_tmp)"
t1_claude="$t1_home/foundation-claude"   # NOT $HOME/.claude → no G1-main risk
mkdir -p "$t1_claude"                    # exists but empty
t1_stderr="$t1_home/stderr.log"
t1_rc=0
( HOME="$t1_home" CLAUDE_HOME="$t1_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" >/dev/null 2>"$t1_stderr" ) || t1_rc=$?
assert_eq "0" "$t1_rc" "T1.1: empty CLAUDE_HOME → install proceeds (G2 no-op)"

t1_log="$(find "$t1_claude/logs" -name 'install-*.log' 2>/dev/null | head -1)"
if [ -n "$t1_log" ] && [ -f "$t1_log" ]; then
  assert_grep "g2_violation_count: 0" "$t1_log" "T1.2: provenance records g2_violation_count=0"
  assert_no_grep "g2_violations:" "$t1_log" "T1.3: provenance omits g2_violations: block when count=0"
else
  printf '  FAIL T1.2/T1.3: provenance log missing under %s/logs\n' "$t1_claude" >&2
  FAIL=$((FAIL+2))
fi

printf '\n=== T2: edited foundation file + no --force-install → exit 52 ===\n'

t2_home="$(mk_tmp)"
t2_claude="$t2_home/foundation-claude"
mkdir -p "$t2_claude/hooks"
# Pre-seed hooks/pre-write-guard.sh with edited content (sha256 drift vs baseline)
printf '#!/bin/bash\n# user-edited content (S64 T2 drift)\n' > "$t2_claude/hooks/pre-write-guard.sh"
t2_stderr="$t2_home/stderr.log"
t2_rc=0
( HOME="$t2_home" CLAUDE_HOME="$t2_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" >/dev/null 2>"$t2_stderr" ) || t2_rc=$?
assert_eq "52" "$t2_rc" "T2.1: drift + no --force-install → exit 52"
assert_grep "G2 fired" "$t2_stderr" "T2.2: G2 diagnostic emitted"
assert_grep "hooks/pre-write-guard.sh" "$t2_stderr" "T2.3: per-violation path listed"

printf '\n=== T3: edited foundation file + --force-install + sentinel → exit 0 + cp -n preserves ===\n'

t3_home="$(mk_tmp)"
t3_claude="$t3_home/foundation-claude"
mkdir -p "$t3_claude/hooks"
t3_user_content='#!/bin/bash
# user-edited content (S64 T3 — must survive cp -n)
'
printf '%s' "$t3_user_content" > "$t3_claude/hooks/pre-write-guard.sh"
t3_pre_sha="$(shasum -a 256 "$t3_claude/hooks/pre-write-guard.sh" | awk '{print $1}')"
t3_stderr="$t3_home/stderr.log"
t3_stdout="$t3_home/stdout.log"
t3_rc=0
( HOME="$t3_home" CLAUDE_HOME="$t3_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --force-install >"$t3_stdout" 2>"$t3_stderr" \
  <<<"I-UNDERSTAND-APRIL-13" ) || t3_rc=$?
assert_eq "0" "$t3_rc" "T3.1: drift + --force-install + sentinel → exit 0"
assert_grep "G2 sentinel verified" "$t3_stdout" "T3.2: G2 sentinel-verified info emitted"
t3_post_sha="$(shasum -a 256 "$t3_claude/hooks/pre-write-guard.sh" | awk '{print $1}')"
assert_eq "$t3_pre_sha" "$t3_post_sha" "T3.3: cp -n preserves user-edited file byte-identical"

t3_log="$(find "$t3_claude/logs" -name 'install-*.log' 2>/dev/null | head -1)"
if [ -n "$t3_log" ] && [ -f "$t3_log" ]; then
  if grep -qE 'g2_violation_count: [1-9]' "$t3_log" 2>/dev/null; then
    printf '  PASS T3.4: provenance records g2_violation_count > 0\n'
    PASS=$((PASS+1))
  else
    printf '  FAIL T3.4: provenance g2_violation_count not > 0 in %s\n' "$t3_log" >&2
    FAIL=$((FAIL+1))
  fi
  assert_grep "g2_violations:" "$t3_log" "T3.5: provenance includes g2_violations: listing"
  assert_grep "hooks/pre-write-guard.sh" "$t3_log" "T3.6: g2_violations: lists drifted path"
else
  printf '  FAIL T3.4/T3.5/T3.6: provenance log missing\n' >&2
  FAIL=$((FAIL+3))
fi

printf '\n=== T4: edited foundation file + --force-install + EOF stdin → exit 52 (G2-distinct) ===\n'

t4_home="$(mk_tmp)"
t4_claude="$t4_home/foundation-claude"
mkdir -p "$t4_claude/hooks"
printf '#!/bin/bash\n# user-edited (S64 T4 EOF case)\n' > "$t4_claude/hooks/pre-write-guard.sh"
t4_stderr="$t4_home/stderr.log"
t4_rc=0
( HOME="$t4_home" CLAUDE_HOME="$t4_claude" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --force-install </dev/null >/dev/null 2>"$t4_stderr" ) || t4_rc=$?
assert_eq "52" "$t4_rc" "T4.1: drift + --force-install + EOF stdin → exit 52"
assert_grep "G2 fired: sentinel not provided" "$t4_stderr" "T4.2: G2 EOF diagnostic emitted"
assert_no_grep "G1-main fired: sentinel not provided" "$t4_stderr" "T4.3: G2 EOF diagnostic distinct from G1-main"

printf '\n=== install-g2-unit-test ===\n'
printf 'PASS: %s\n' "$PASS"
printf 'FAIL: %s\n' "$FAIL"
[ "$FAIL" = "0" ]
