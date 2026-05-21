#!/bin/bash
# tests/installer/install-vault-init-ship-unit-test.sh
#
# Synthetic unit test for Step 8.7 — vault-init/ subtree ship via install.sh
# (SP15 T-1e §A53 + Session 7 L-86).
#
# Coverage:
#   T1: Fresh install — vault-init/ subtree fully shipped (recursive file count
#       matches source; subdirs preserved incl. spaces in names)
#   T2: Re-install idempotent (cp -n default) — user-edited file in vault-init/
#       preserved across second install
#   T3: --force-all (cp -f) — user-edited file in vault-init/ overwritten back
#       to canonical content
#   T4: Dry-run JSON contains Step 8.7 entry pointing at vault-init/
#   T5: foundation_known_entries protection list includes "vault-init"
#
# Isolation: each test creates its own tmpdir CLAUDE_HOME; SOURCE_REPO points
# at the foundation-repo top. No mutation of live ~/.claude.
#
# R-23: bash 3.2 compat.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
VAULT_INIT_SRC="$REPO_ROOT/vault-init"
USERBASE="$(python3 -m site --user-base 2>/dev/null || true)"

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
  d="$(mktemp -d -t vault-init-ship-test.XXXXXX)"
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

assert_path_exists() {
  path="$1"; label="$2"
  if [ -e "$path" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: path does not exist [%s]\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

# --- prereq sanity ---
if [ ! -x "$INSTALL_SH" ]; then
  printf 'FATAL: install.sh not executable at %s\n' "$INSTALL_SH" >&2
  exit 7
fi
if [ ! -d "$VAULT_INIT_SRC" ]; then
  printf 'FATAL: vault-init/ source missing at %s\n' "$VAULT_INIT_SRC" >&2
  exit 7
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'FATAL: jq required\n' >&2
  exit 7
fi

SRC_FILE_COUNT="$(find "$VAULT_INIT_SRC" -type f | wc -l | tr -d ' ')"

printf '=== install-vault-init-ship-unit-test ===\n'
printf 'Source file count in vault-init/: %s\n' "$SRC_FILE_COUNT"

# =====================================================================
# T1 — Fresh install: vault-init/ subtree shipped
# =====================================================================
printf '\nT1: Fresh install — vault-init/ subtree shipped\n'

CH1="$(mk_tmp)"
rc=0
HOME="$CH1" CLAUDE_HOME="$CH1" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply >"$CH1/.stdout" 2>"$CH1/.stderr" || rc=$?
assert_eq "0" "$rc" "T1.0 install.sh exits 0 on fresh install"

assert_path_exists "$CH1/vault-init" "T1.1 vault-init/ root exists"
assert_path_exists "$CH1/vault-init/README.md" "T1.2 README.md shipped"
assert_path_exists "$CH1/vault-init/System Governance" "T1.3 System Governance/ subdir present (space in name)"
assert_path_exists "$CH1/vault-init/Vault Writers" "T1.4 Vault Writers/ subdir present (space in name)"
assert_path_exists "$CH1/vault-init/file-type-contracts" "T1.5 file-type-contracts/ subdir present"
assert_path_exists "$CH1/vault-init/Logs/Archive" "T1.6 Logs/Archive/ subdir present"
assert_path_exists "$CH1/vault-init/Logs/backlog-progress/_template.md" "T1.7 v2 _template.md preserved"
assert_path_exists "$CH1/vault-init/Meetings" "T1.8 Meetings/ subdir present"
assert_path_exists "$CH1/vault-init/System Backlog.md" "T1.9 System Backlog.md carryover"
assert_path_exists "$CH1/vault-init/System Backlog - Archive.md" "T1.10 System Backlog - Archive.md carryover"

T1_DEST_FILE_COUNT="$(find "$CH1/vault-init" -type f | wc -l | tr -d ' ')"
assert_eq "$SRC_FILE_COUNT" "$T1_DEST_FILE_COUNT" "T1.11 recursive file count matches source ($SRC_FILE_COUNT files)"

# =====================================================================
# T2 — Re-install idempotent (cp -n default): user edit preserved
# =====================================================================
printf '\nT2: Re-install idempotent — cp -n preserves user edits\n'

# Reuse $CH1 (already has vault-init/ from T1)
echo "USER EDIT MARKER" > "$CH1/vault-init/README.md"

rc=0
T2_BACKUP="$CH1/.backup-t2"
printf 'I-UNDERSTAND-OVERWRITE-RISK\n' | \
  HOME="$CH1" CLAUDE_HOME="$CH1" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply --force-install --backup-dir "$T2_BACKUP" \
  >"$CH1/.stdout2" 2>"$CH1/.stderr2" || rc=$?
assert_eq "0" "$rc" "T2.0 re-install exits 0 (G2-sentinel + G3-backup)"

T2_CONTENT="$(cat "$CH1/vault-init/README.md")"
assert_eq "USER EDIT MARKER" "$T2_CONTENT" "T2.1 user-edited README.md preserved via cp -n"

# =====================================================================
# T3 — --force-all (cp -f): user edit overwritten
# =====================================================================
printf '\nT3: --force-all overwrites user edits (cp -f)\n'

CH3="$(mk_tmp)"
rc=0
HOME="$CH3" CLAUDE_HOME="$CH3" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply >"$CH3/.stdout" 2>"$CH3/.stderr" || rc=$?
assert_eq "0" "$rc" "T3.0 fresh install exits 0"

echo "USER EDIT TO OVERWRITE" > "$CH3/vault-init/README.md"

rc=0
T3_BACKUP="$CH3/.backup-t3"
printf 'I-UNDERSTAND-OVERWRITE-RISK\n' | \
  HOME="$CH3" CLAUDE_HOME="$CH3" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply --force-install --force-all --backup-dir "$T3_BACKUP" \
  >"$CH3/.stdout2" 2>"$CH3/.stderr2" || rc=$?
assert_eq "0" "$rc" "T3.1 re-install --force-all exits 0"

T3_FIRST_LINE="$(head -1 "$CH3/vault-init/README.md")"
T3_EXPECTED_FIRST_LINE="# vault-init/"
assert_eq "$T3_EXPECTED_FIRST_LINE" "$T3_FIRST_LINE" "T3.2 user edit overwritten by canonical README via --force-all"

# =====================================================================
# T4 — Dry-run JSON contains Step 8.7 entry
# =====================================================================
printf '\nT4: Dry-run JSON contains Step 8.7 vault-init/ entry\n'

CH4="$(mk_tmp)"
HOME="$CH4" CLAUDE_HOME="$CH4" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" >"$CH4/.dry-run.json" 2>"$CH4/.dry-run.stderr" || true

# Strip any leading non-JSON noise then validate
jq . "$CH4/.dry-run.json" >/dev/null 2>&1
JQ_RC=$?
assert_eq "0" "$JQ_RC" "T4.0 dry-run output is valid JSON"

STEP_87_STEP="$(jq -r '.actions[] | select(.step == 8.7) | .step' "$CH4/.dry-run.json" 2>/dev/null)"
assert_eq "8.7" "$STEP_87_STEP" "T4.1 step 8.7 entry present in dry-run actions array"

STEP_87_OP="$(jq -r '.actions[] | select(.step == 8.7) | .op' "$CH4/.dry-run.json" 2>/dev/null)"
assert_eq "cp" "$STEP_87_OP" "T4.2 step 8.7 op is cp"

STEP_87_TARGET="$(jq -r '.actions[] | select(.step == 8.7) | .target' "$CH4/.dry-run.json" 2>/dev/null)"
assert_eq "$CH4/vault-init/" "$STEP_87_TARGET" "T4.3 step 8.7 target points at vault-init/"

STEP_1_TARGET="$(jq -r '.actions[] | select(.step == 1) | .target' "$CH4/.dry-run.json" 2>/dev/null)"
case "$STEP_1_TARGET" in
  *vault-init*) assert_eq "found" "found" "T4.4 step 1 mkdir target includes vault-init" ;;
  *) assert_eq "found" "NOT-FOUND" "T4.4 step 1 mkdir target includes vault-init" ;;
esac

# =====================================================================
# T5 — foundation_known_entries includes "vault-init"
# =====================================================================
printf '\nT5: foundation_known_entries protection list includes vault-init\n'

if grep -q '^foundation_known_entries=".*vault-init.*"' "$INSTALL_SH"; then
  assert_eq "found" "found" "T5.0 foundation_known_entries includes vault-init"
else
  assert_eq "found" "NOT-FOUND" "T5.0 foundation_known_entries includes vault-init"
fi

# =====================================================================
# Summary
# =====================================================================
printf '\n=== install-vault-init-ship-unit-test ===\n'
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
