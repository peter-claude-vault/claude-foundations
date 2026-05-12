#!/bin/bash
# tests/installer/install-spec-inject-registration-unit-test.sh
#
# Synthetic unit test for Step 12.5 — idempotent spec-context-inject hook
# registration in UserPromptSubmit chain (Plan 81 SP09 T-4).
#
# Coverage (3 cases per spec AC):
#   T1: Fresh install — hook registered automatically (from template)
#   T2: Re-install (idempotent) — hook NOT duplicated
#   T3: Pre-existing UserPromptSubmit hooks preserved — user customizations intact
#       AND spec-context-inject appended when absent
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
  d="$(mktemp -d -t spec-inject-reg-test.XXXXXX)"
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

# Helper: count occurrences of spec-context-inject.sh in UserPromptSubmit chain
count_spec_inject() {
  jq -r '
    [.hooks.UserPromptSubmit[]?.hooks[]?.command // ""]
    | map(test("spec-context-inject\\.sh"))
    | map(select(.))
    | length
  ' "$1" 2>/dev/null || echo "-1"
}

# Helper: check if a hook command path is present in UserPromptSubmit chain
has_hook_cmd() {
  jq -r --arg needle "$2" '
    [.hooks.UserPromptSubmit[]?.hooks[]?.command // ""]
    | map(. == $needle)
    | any
  ' "$1" 2>/dev/null || echo "error"
}

# =====================================================================
# T1 — Fresh install: hook registered automatically from template
# =====================================================================
printf 'T1: fresh install registers spec-context-inject hook from template\n'

CH1="$(mk_tmp)"
USERBASE="$(python3 -m site --user-base 2>/dev/null || true)"
rc=0
HOME="$CH1" CLAUDE_HOME="$CH1" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply >"$CH1/.stdout" 2>"$CH1/.stderr" || rc=$?
assert_eq "0" "$rc" "T1.1: install.sh exits 0 on fresh install"

count1=$(count_spec_inject "$CH1/settings.json")
assert_eq "1" "$count1" "T1.2: spec-context-inject.sh present exactly once in fresh-install settings.json"

# Verify the prompt-context.sh hook is also preserved (template's pre-existing hook)
pc_present=$(has_hook_cmd "$CH1/settings.json" "~/.claude/hooks/prompt-context.sh")
assert_eq "true" "$pc_present" "T1.3: prompt-context.sh preserved alongside spec-context-inject.sh"

# =====================================================================
# T2 — Re-install: hook NOT duplicated (idempotent)
# =====================================================================
# Note: re-install over an existing CLAUDE_HOME hits G2 (sha256 baseline drift)
# in the foundation-repo's current state — `lib/paths.sh` vs `hooks/lib/paths.sh`
# inconsistency is a pre-existing condition outside SP09 scope. Use
# --force-install + sentinel pipe to bypass; the idempotency check is unaffected.
printf 'T2: re-install does not duplicate spec-context-inject (idempotency)\n'

rc=0
T2_BACKUP="$CH1/.backup-t2"
printf 'I-UNDERSTAND-OVERWRITE-RISK\n' | HOME="$CH1" CLAUDE_HOME="$CH1" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply --force-install --backup-dir "$T2_BACKUP" >"$CH1/.stdout2" 2>"$CH1/.stderr2" || rc=$?
assert_eq "0" "$rc" "T2.1: re-install exits 0 (G2-sentinel + G3-backup; bypasses pre-existing foundation drift)"

count2=$(count_spec_inject "$CH1/settings.json")
assert_eq "1" "$count2" "T2.2: spec-context-inject.sh still present exactly once after re-install (idempotent)"

# =====================================================================
# T3 — Pre-existing UserPromptSubmit hooks preserved AND new hook appended
# =====================================================================
printf 'T3: pre-existing UserPromptSubmit hooks preserved + spec-context-inject appended\n'

CH3="$(mk_tmp)"
# Pre-seed settings.json with an adopter-customized UserPromptSubmit chain
# that includes prompt-context.sh + a custom hook, but NOT spec-context-inject.sh
cat > "$CH3/settings.json" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/prompt-context.sh",
            "timeout": 5
          },
          {
            "type": "command",
            "command": "~/.claude/hooks/my-custom-prompt-hook.sh",
            "timeout": 7
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
assert_eq "0" "$rc" "T3.1: install.sh exits 0 with pre-existing customized UserPromptSubmit chain"

# spec-context-inject.sh added
count3=$(count_spec_inject "$CH3/settings.json")
assert_eq "1" "$count3" "T3.2: spec-context-inject.sh appended exactly once"

# User's prompt-context.sh preserved
pc_present3=$(has_hook_cmd "$CH3/settings.json" "~/.claude/hooks/prompt-context.sh")
assert_eq "true" "$pc_present3" "T3.3: pre-existing prompt-context.sh preserved"

# User's CUSTOM hook preserved (this is the load-bearing case — Step 12.5 must
# not clobber adopter-customized hooks)
custom_present=$(has_hook_cmd "$CH3/settings.json" "~/.claude/hooks/my-custom-prompt-hook.sh")
assert_eq "true" "$custom_present" "T3.4: pre-existing my-custom-prompt-hook.sh preserved"

# User's non-hook top-level key preserved (G7 baseline check is install.sh's
# job, but re-verify here as defense-in-depth for Step 12.5)
preserved=$(jq -r '.userCustom.preserveMe' "$CH3/settings.json" 2>/dev/null)
assert_eq "true" "$preserved" "T3.5: userCustom.preserveMe preserved through Step 12 + 12.5"

# =====================================================================
printf '\n=== install-spec-inject-registration-unit-test ===\n'
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
