#!/bin/bash
# tests/installer/install-asq-matcher-registration-unit-test.sh
#
# Synthetic unit test for Step 12.6 — idempotent AskUserQuestion matcher
# registration in PreToolUse chain → pre-asq-guard.sh (SP15 T-1d §A46 + §A50).
#
# Coverage (4 cases per spec AC):
#   T1: Fresh install — matcher registered automatically (from template)
#   T2: Re-install (idempotent) — matcher NOT duplicated
#   T3: Pre-existing PreToolUse customizations preserved — adopter Edit|Write
#       matcher (and any custom matchers) preserved AND AskUserQuestion matcher
#       appended when absent
#   T4: Dry-run JSON contains step 12.6 entry
#
# Sister test to install-spec-inject-registration-unit-test.sh (Step 12.5).
# Same problem class: hook declared in template but jq deep-merge `template *
# user` lets user PreToolUse array win on array conflicts; re-install adopters
# without the matcher would silently drop it without Step 12.6 idempotent
# registration.
#
# Isolation: each test creates its own tmpdir CLAUDE_HOME; SOURCE_REPO points
# at the foundation-repo top. No mutation of live ~/.claude.
#
# R-23: bash 3.2 compat.

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
  d="$(mktemp -d -t asq-matcher-reg-test.XXXXXX)"
  TMPDIRS="$TMPDIRS $d"
  printf '%s' "$d"
}

assert_eq() {
  expected="$1"; actual="$2"; label="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: expected=[%s] actual=[%s]\n' "$label" "$expected" "$actual" >&2
    FAIL=$((FAIL+1))
  fi
}

# --- prereq sanity ---
if [ ! -x "$INSTALL_SH" ]; then
  printf 'FATAL: install.sh not executable at %s\n' "$INSTALL_SH" >&2
  exit 7
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'FATAL: jq required\n' >&2
  exit 7
fi

# Helper: count occurrences of pre-asq-guard.sh in PreToolUse chain
count_asq_matcher() {
  jq -r '
    [.hooks.PreToolUse[]?.hooks[]?.command // ""]
    | map(test("pre-asq-guard\\.sh"))
    | map(select(.))
    | length
  ' "$1" 2>/dev/null || echo "-1"
}

# Helper: check if a hook command path is present in PreToolUse chain
has_pretooluse_cmd() {
  jq -r --arg needle "$2" '
    [.hooks.PreToolUse[]?.hooks[]?.command // ""]
    | map(. == $needle)
    | any
  ' "$1" 2>/dev/null || echo "error"
}

# Helper: check if a matcher value is present in PreToolUse
has_pretooluse_matcher() {
  jq -r --arg needle "$2" '
    [.hooks.PreToolUse[]?.matcher // ""]
    | map(. == $needle)
    | any
  ' "$1" 2>/dev/null || echo "error"
}

# =====================================================================
# T1 — Fresh install: matcher registered automatically from template
# =====================================================================
printf 'T1: fresh install registers AskUserQuestion matcher from template\n'

CH1="$(mk_tmp)"
USERBASE="$(python3 -m site --user-base 2>/dev/null || true)"
rc=0
HOME="$CH1" CLAUDE_HOME="$CH1" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply >"$CH1/.stdout" 2>"$CH1/.stderr" || rc=$?
assert_eq "0" "$rc" "T1.1: install.sh exits 0 on fresh install"

count1=$(count_asq_matcher "$CH1/settings.json")
assert_eq "1" "$count1" "T1.2: pre-asq-guard.sh present exactly once in fresh-install settings.json"

# Verify the AskUserQuestion matcher value is present
asq_matcher_present=$(has_pretooluse_matcher "$CH1/settings.json" "AskUserQuestion")
assert_eq "true" "$asq_matcher_present" "T1.3: AskUserQuestion matcher value present in PreToolUse array"

# Verify pre-write-guard.sh (existing Edit|Write matcher) is preserved
pwg_present=$(has_pretooluse_cmd "$CH1/settings.json" "~/.claude/hooks/pre-write-guard.sh")
assert_eq "true" "$pwg_present" "T1.4: pre-write-guard.sh (Edit|Write matcher) preserved alongside AskUserQuestion matcher"

# =====================================================================
# T2 — Re-install: matcher NOT duplicated (idempotent)
# =====================================================================
# Note: re-install over an existing CLAUDE_HOME hits G2 (sha256 baseline drift).
# Use --force-install + sentinel pipe to bypass per Step 12.5 test precedent.
printf 'T2: re-install does not duplicate pre-asq-guard matcher (idempotency)\n'

rc=0
T2_BACKUP="$CH1/.backup-t2"
printf 'I-UNDERSTAND-OVERWRITE-RISK\n' | HOME="$CH1" CLAUDE_HOME="$CH1" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply --force-install --backup-dir "$T2_BACKUP" >"$CH1/.stdout2" 2>"$CH1/.stderr2" || rc=$?
assert_eq "0" "$rc" "T2.1: re-install exits 0 (G2-sentinel + G3-backup; bypasses pre-existing foundation drift)"

count2=$(count_asq_matcher "$CH1/settings.json")
assert_eq "1" "$count2" "T2.2: pre-asq-guard.sh still present exactly once after re-install (idempotent)"

# =====================================================================
# T3 — Pre-existing PreToolUse hooks preserved AND new matcher appended
# =====================================================================
printf 'T3: pre-existing PreToolUse hooks preserved + AskUserQuestion matcher appended\n'

CH3="$(mk_tmp)"
# Pre-seed settings.json with an adopter-customized PreToolUse chain that
# includes the Edit|Write matcher + a custom matcher, but NOT AskUserQuestion
cat > "$CH3/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/pre-write-guard.sh"
          },
          {
            "type": "command",
            "command": "~/.claude/hooks/my-custom-edit-hook.sh"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/my-custom-bash-hook.sh"
          }
        ]
      }
    ]
  },
  "userCustom": {
    "preserveMe": true
  }
}
JSON

rc=0
HOME="$CH3" CLAUDE_HOME="$CH3" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --backup-dir "$CH3/.backup" --apply >"$CH3/.stdout" 2>"$CH3/.stderr" || rc=$?
assert_eq "0" "$rc" "T3.1: install.sh exits 0 with pre-existing customized PreToolUse chain"

# pre-asq-guard.sh added
count3=$(count_asq_matcher "$CH3/settings.json")
assert_eq "1" "$count3" "T3.2: pre-asq-guard.sh appended exactly once"

# AskUserQuestion matcher value present
asq_matcher_present3=$(has_pretooluse_matcher "$CH3/settings.json" "AskUserQuestion")
assert_eq "true" "$asq_matcher_present3" "T3.3: AskUserQuestion matcher value appended to PreToolUse array"

# User's pre-write-guard.sh preserved (Edit|Write matcher)
pwg_present3=$(has_pretooluse_cmd "$CH3/settings.json" "~/.claude/hooks/pre-write-guard.sh")
assert_eq "true" "$pwg_present3" "T3.4: pre-existing pre-write-guard.sh preserved"

# User's CUSTOM Edit|Write hook preserved (load-bearing: must not clobber)
custom_edit_present=$(has_pretooluse_cmd "$CH3/settings.json" "~/.claude/hooks/my-custom-edit-hook.sh")
assert_eq "true" "$custom_edit_present" "T3.5: pre-existing my-custom-edit-hook.sh preserved"

# User's CUSTOM Bash matcher preserved
custom_bash_present=$(has_pretooluse_cmd "$CH3/settings.json" "~/.claude/hooks/my-custom-bash-hook.sh")
assert_eq "true" "$custom_bash_present" "T3.6: pre-existing my-custom-bash-hook.sh (Bash matcher) preserved"

# Bash matcher value preserved
bash_matcher_present=$(has_pretooluse_matcher "$CH3/settings.json" "Bash")
assert_eq "true" "$bash_matcher_present" "T3.7: pre-existing Bash matcher value preserved"

# User's non-hook top-level key preserved (G7 baseline check is install.sh's
# job, but re-verify here as defense-in-depth for Step 12.6)
preserved=$(jq -r '.userCustom.preserveMe' "$CH3/settings.json" 2>/dev/null)
assert_eq "true" "$preserved" "T3.8: userCustom.preserveMe preserved through Step 12 + 12.5 + 12.6"

# =====================================================================
# T4 — Dry-run JSON contains step 12.6 entry
# =====================================================================
printf 'T4: dry-run JSON contains step 12.6 jq-register entry\n'

CH4="$(mk_tmp)"
HOME="$CH4" CLAUDE_HOME="$CH4" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" >"$CH4/.dry-run.json" 2>"$CH4/.dry-run.stderr" || true

# Strip leading non-JSON noise if any; the dry-run output is a single JSON object
if ! jq -e '.actions' "$CH4/.dry-run.json" >/dev/null 2>&1; then
  printf '  FAIL T4.0: dry-run output is not valid JSON\n' >&2
  FAIL=$((FAIL+1))
else
  printf '  PASS T4.0: dry-run output is valid JSON\n'
  PASS=$((PASS+1))
fi

# Step 12.6 entry present in actions array
step126_present=$(jq -r '[.actions[]? | select(.step == 12.6)] | length' "$CH4/.dry-run.json" 2>/dev/null || echo "0")
assert_eq "1" "$step126_present" "T4.1: step 12.6 entry present in dry-run actions array"

# Step 12.6 op == "jq-register"
step126_op=$(jq -r '[.actions[]? | select(.step == 12.6)][0].op // ""' "$CH4/.dry-run.json" 2>/dev/null || echo "")
assert_eq "jq-register" "$step126_op" "T4.2: step 12.6 op is jq-register"

# Step 12.6 target is settings.json
step126_target=$(jq -r '[.actions[]? | select(.step == 12.6)][0].target // ""' "$CH4/.dry-run.json" 2>/dev/null || echo "")
case "$step126_target" in
  *settings.json) assert_eq "ok" "ok" "T4.3: step 12.6 target points at settings.json ($step126_target)";;
  *) assert_eq "*settings.json" "$step126_target" "T4.3: step 12.6 target points at settings.json";;
esac

# =====================================================================
printf '\n=== install-asq-matcher-registration-unit-test ===\n'
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
