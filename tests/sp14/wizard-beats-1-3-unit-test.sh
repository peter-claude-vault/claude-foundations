#!/usr/bin/env bash
# tests/sp14/wizard-beats-1-3-unit-test.sh — synthetic unit tests for SP14 T-7,
# T-8, T-9 (wizard Beats 1, 2, 3).
#
# T-7 ACs:
#   1. beat-1-role.sh exists; bash -n clean
#   2. --input consultant writes connectors_meta.user_role: "consultant"
#   3. invalid input rc=2 with diagnostic
#   4. --skip-role bypasses cleanly (no manifest write)
#
# T-8 ACs:
#   1. beat-2-multiselect.sh exists; bash -n clean
#   2. role=consultant pre-checks consultant subset (visible in stderr render)
#   3. --search filters the rendered grid
#   4. --installed-list adds [installed] badge
#   5. apply writes connectors[] with N entries matching N --input-checks
#
# T-9 ACs:
#   1. beat-3-schedule.sh exists; bash -n clean
#   2. 3-connector fixture renders 3-row table
#   3. --input-overrides applies per-connector schedule edits
#   4. --input-overrides applies target_vault_path edits
#   5. defaults preserved when override absent for that connector
#   6. SP12 three-step gate fires before manifest write (--accept-on-empty-stdin
#      success path; --no-gate skips for synthetic mode comparison)
#
# Run: bash tests/sp14/wizard-beats-1-3-unit-test.sh
# Exit: 0 on all-pass; 1 on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
B1="$REPO_ROOT/onboarding/connectors/beats/beat-1-role.sh"
B2="$REPO_ROOT/onboarding/connectors/beats/beat-2-multiselect.sh"
B3="$REPO_ROOT/onboarding/connectors/beats/beat-3-schedule.sh"
CATALOG="$REPO_ROOT/onboarding/connectors/catalog.json"

PASS=0; FAIL=0
check() {
  if [ "$1" = "$2" ]; then
    PASS=$((PASS+1)); echo "PASS $3"
  else
    FAIL=$((FAIL+1)); echo "FAIL $3 (got '$1' expected '$2')" >&2
  fi
}

TMPDIR="$(mktemp -d -t sp14-beats-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
MANIFEST="$TMPDIR/user-manifest.json"

# ============================================================
# T-7: Beat 1 — Role question
# ============================================================
echo "=== T-7: Beat 1 (role) ==="
[ -r "$B1" ] && PASS=$((PASS+1)) && echo "PASS T-7 AC1: beat-1-role.sh exists" || { FAIL=$((FAIL+1)); echo "FAIL T-7 AC1"; }
bash -n "$B1" && PASS=$((PASS+1)) && echo "PASS T-7 AC1: bash -n OK" || { FAIL=$((FAIL+1)); echo "FAIL T-7 AC1: bash -n"; }

# AC2: --input consultant writes the role
bash "$B1" --input consultant --manifest "$MANIFEST" >/dev/null 2>&1
got=$(jq -r '.connectors_meta.user_role' "$MANIFEST" 2>/dev/null)
check "$got" "consultant" "T-7 AC2: --input consultant persists"

# AC2 numeric shortcut
rm -f "$MANIFEST"
bash "$B1" --input 3 --manifest "$MANIFEST" >/dev/null 2>&1
got=$(jq -r '.connectors_meta.user_role' "$MANIFEST" 2>/dev/null)
check "$got" "engineer" "T-7 AC2: --input 3 maps to engineer"

# AC3: invalid input rc=2
bash "$B1" --input not-a-role --manifest "$MANIFEST" >/dev/null 2>&1
check "$?" "2" "T-7 AC3: invalid input rc=2"

# AC4: --skip-role bypasses (no manifest write)
rm -f "$MANIFEST"
bash "$B1" --skip-role --manifest "$MANIFEST" >/dev/null 2>&1
[ ! -f "$MANIFEST" ] && PASS=$((PASS+1)) && echo "PASS T-7 AC4: --skip-role no-manifest-write" || { FAIL=$((FAIL+1)); echo "FAIL T-7 AC4: manifest exists"; }

# ============================================================
# T-8: Beat 2 — Multiselect catalog
# ============================================================
echo
echo "=== T-8: Beat 2 (multiselect) ==="
[ -r "$B2" ] && PASS=$((PASS+1)) && echo "PASS T-8 AC1: beat-2-multiselect.sh exists" || { FAIL=$((FAIL+1)); echo "FAIL T-8 AC1"; }
bash -n "$B2" && PASS=$((PASS+1)) && echo "PASS T-8 AC1: bash -n OK" || { FAIL=$((FAIL+1)); echo "FAIL T-8 AC1: bash -n"; }

# AC2: role=consultant pre-checks consultant subset (visible in stderr render)
rm -f "$MANIFEST"
bash "$B1" --input consultant --manifest "$MANIFEST" >/dev/null 2>&1
render=$(bash "$B2" --catalog "$CATALOG" --manifest "$MANIFEST" --input-checks "" 2>&1 >/dev/null)
checked_count=$(printf '%s' "$render" | grep -c '^\s*\[x\]')
[ "$checked_count" -ge 7 ] && PASS=$((PASS+1)) && echo "PASS T-8 AC2: ≥7 checked entries for consultant ($checked_count)" || { FAIL=$((FAIL+1)); echo "FAIL T-8 AC2: only $checked_count checked"; }

# AC3: --search filters the grid
render=$(bash "$B2" --catalog "$CATALOG" --manifest "$MANIFEST" --input-checks "" --search "calendar" 2>&1 >/dev/null)
gcal_seen=$(printf '%s' "$render" | grep -c 'gcal')
others_seen=$(printf '%s' "$render" | grep -E 'github|linear|asana|figma' | wc -l | tr -d ' ')
[ "$gcal_seen" -ge 1 ] && PASS=$((PASS+1)) && echo "PASS T-8 AC3: --search 'calendar' shows gcal" || { FAIL=$((FAIL+1)); echo "FAIL T-8 AC3"; }
[ "$others_seen" = "0" ] && PASS=$((PASS+1)) && echo "PASS T-8 AC3: --search 'calendar' filters out non-calendar" || { FAIL=$((FAIL+1)); echo "FAIL T-8 AC3: $others_seen non-calendar lines leaked"; }

# AC4: --installed-list adds [installed] badge
echo "claude_ai_Granola" > "$TMPDIR/installed.txt"
render=$(bash "$B2" --catalog "$CATALOG" --manifest "$MANIFEST" --input-checks "" --installed-list "$TMPDIR/installed.txt" 2>&1 >/dev/null)
if printf '%s' "$render" | grep -E 'granola.*\[installed\]' >/dev/null; then
  PASS=$((PASS+1)); echo "PASS T-8 AC4: granola has [installed] badge"
else
  FAIL=$((FAIL+1)); echo "FAIL T-8 AC4: missing [installed] badge"
fi

# AC5: apply writes connectors[] with N entries matching --input-checks
rm -f "$MANIFEST"
bash "$B1" --input consultant --manifest "$MANIFEST" >/dev/null 2>&1
bash "$B2" --catalog "$CATALOG" --manifest "$MANIFEST" --input-checks "granola,gcal,gmail" 2>/dev/null >/dev/null
n=$(jq '.connectors | length' "$MANIFEST" 2>/dev/null)
check "$n" "3" "T-8 AC5: 3 connectors written for 3 --input-checks"

# Verify each entry has correct shape
ids=$(jq -r '.connectors[] | .id' "$MANIFEST" | sort | tr '\n' ',' | sed 's/,$//')
check "$ids" "gcal,gmail,granola" "T-8 AC5: correct ids written"

# Verify entry has catalog defaults
sched=$(jq -r '.connectors[] | select(.id=="granola") | .schedule' "$MANIFEST")
check "$sched" "0 6 * * *" "T-8 AC5: granola.schedule from catalog default"
ts_path=$(jq -r '.connectors[] | select(.id=="granola") | .target_vault_path' "$MANIFEST")
check "$ts_path" "Inbox/Meetings/" "T-8 AC5: granola.target_vault_path from catalog default"
fmode=$(jq -r '.connectors[] | select(.id=="granola") | .failure_mode' "$MANIFEST")
check "$fmode" "block-and-log" "T-8 AC5: granola.failure_mode from catalog default"
auth=$(jq -r '.connectors[] | select(.id=="granola") | .auth_status' "$MANIFEST")
check "$auth" "pending" "T-8 AC5: granola.auth_status starts as 'pending'"

# ============================================================
# T-9: Beat 3 — Per-app schedule confirm
# ============================================================
echo
echo "=== T-9: Beat 3 (schedule confirm) ==="
[ -r "$B3" ] && PASS=$((PASS+1)) && echo "PASS T-9 AC1: beat-3-schedule.sh exists" || { FAIL=$((FAIL+1)); echo "FAIL T-9 AC1"; }
bash -n "$B3" && PASS=$((PASS+1)) && echo "PASS T-9 AC1: bash -n OK" || { FAIL=$((FAIL+1)); echo "FAIL T-9 AC1: bash -n"; }

# Manifest already has 3 connectors from T-8 above
# AC2: 3-row table renders
render=$(bash "$B3" --manifest "$MANIFEST" --no-gate 2>&1 >/dev/null)
row_count=$(printf '%s' "$render" | grep -E '^\s+(granola|gcal|gmail)' | wc -l | tr -d ' ')
check "$row_count" "3" "T-9 AC2: 3-row table rendered"

# AC3: --input-overrides applies schedule edit
overrides='{"granola":{"schedule":"0 8 * * *"}}'
bash "$B3" --manifest "$MANIFEST" --input-overrides "$overrides" --no-gate >/dev/null 2>&1
got_sched=$(jq -r '.connectors[] | select(.id=="granola") | .schedule' "$MANIFEST")
check "$got_sched" "0 8 * * *" "T-9 AC3: schedule override persisted"

# AC4: --input-overrides applies target_vault_path edit
overrides='{"granola":{"target_vault_path":"Inbox/Custom/"}}'
bash "$B3" --manifest "$MANIFEST" --input-overrides "$overrides" --no-gate >/dev/null 2>&1
got_path=$(jq -r '.connectors[] | select(.id=="granola") | .target_vault_path' "$MANIFEST")
check "$got_path" "Inbox/Custom/" "T-9 AC4: target_vault_path override persisted"

# AC5: defaults preserved when override absent
got_sched=$(jq -r '.connectors[] | select(.id=="gcal") | .schedule' "$MANIFEST")
check "$got_sched" "*/15 * * * *" "T-9 AC5: gcal.schedule default preserved (no override)"
got_path=$(jq -r '.connectors[] | select(.id=="gmail") | .target_vault_path' "$MANIFEST")
check "$got_path" "Inbox/Email/" "T-9 AC5: gmail.target_vault_path default preserved"

# AC6: SP12 three-step gate fires before manifest write — --accept-on-empty-stdin
overrides='{"granola":{"schedule":"0 9 * * *"}}'
bash "$B3" --manifest "$MANIFEST" --input-overrides "$overrides" --accept-on-empty-stdin </dev/null >/dev/null 2>&1
rc=$?
check "$rc" "0" "T-9 AC6: three-step gate accept-on-empty-stdin path rc=0"
got_sched=$(jq -r '.connectors[] | select(.id=="granola") | .schedule' "$MANIFEST")
check "$got_sched" "0 9 * * *" "T-9 AC6: gate-accepted change persisted"

echo
echo "==========================="
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] && exit 0 || exit 1
