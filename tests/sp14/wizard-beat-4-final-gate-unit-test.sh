#!/usr/bin/env bash
# tests/sp14/wizard-beat-4-final-gate-unit-test.sh — synthetic unit tests for
# SP14 T-10 (Beat 4 OAuth) and T-11 (final gate).
#
# T-10 ACs:
#   1. beat-4-oauth.sh exists; bash -n clean
#   2. 3-connector all-pending fixture: walk completes 3 OAuth steps; all 3
#      flip to auth_status:connected
#   3. skip mid-walk: skipped connector remains pending; subsequent walked
#   4. resume: re-invocation walks remaining pending connectors
#   5. settings.json merge: mcpServers.<id> appears with placeholder env vars;
#      SP12 three-step gate fires per merge
#   6. auth_expires_at populated when --mock-expiry provided
#
# T-11 ACs:
#   1. final-gate.sh exists; bash -n clean
#   2. 3-job + 3-connector fixture renders 6 rows (3 jobs + 3 connectors with
#      non-manual schedule)
#   3. --input abort: rc=2 (clean refusal distinct from error)
#   4. --input accept: rc=0 (proceeds to apply)
#   5. accept-on-empty-stdin: EOF treated as accept
#
# Run: bash tests/sp14/wizard-beat-4-final-gate-unit-test.sh
# Exit: 0 on all-pass; 1 on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
B4="$REPO_ROOT/onboarding/connectors/beats/beat-4-oauth.sh"
FG="$REPO_ROOT/onboarding/connectors/beats/final-gate.sh"

PASS=0; FAIL=0
check() {
  if [ "$1" = "$2" ]; then
    PASS=$((PASS+1)); echo "PASS $3"
  else
    FAIL=$((FAIL+1)); echo "FAIL $3 (got '$1' expected '$2')" >&2
  fi
}

TMPDIR="$(mktemp -d -t sp14-beat4-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
MANIFEST="$TMPDIR/user-manifest.json"
SETTINGS="$TMPDIR/settings.json"
ORCH="$TMPDIR/orchestration.json"

# Fixture: 3 connectors all pending
cat > "$MANIFEST" <<'JSON'
{
  "connectors_meta": {"user_role": "consultant", "wizard_version": "1.0.0"},
  "connectors": [
    {"id": "granola", "mcp_server": "claude_ai_Granola",
     "auth_status": "pending", "auth_expires_at": null,
     "schedule": "0 6 * * *", "scope": "read",
     "target_vault_path": "Inbox/Meetings/", "processor_skill": "meeting-processor",
     "last_run": null, "last_status": null, "failure_mode": "block-and-log"},
    {"id": "gcal", "mcp_server": "claude_ai_Google_Calendar",
     "auth_status": "pending", "auth_expires_at": null,
     "schedule": "*/15 * * * *", "scope": "read",
     "target_vault_path": "Inbox/", "processor_skill": null,
     "last_run": null, "last_status": null, "failure_mode": "skip-and-log"},
    {"id": "gmail", "mcp_server": "claude_ai_Gmail",
     "auth_status": "pending", "auth_expires_at": null,
     "schedule": "0 7 * * *", "scope": "read",
     "target_vault_path": "Inbox/Email/", "processor_skill": null,
     "last_run": null, "last_status": null, "failure_mode": "block-and-log"}
  ]
}
JSON

echo '{"mcpServers": {}}' > "$SETTINGS"

# ============================================================
# T-10: Beat 4 — OAuth walk
# ============================================================
echo "=== T-10: Beat 4 (OAuth walk) ==="
[ -r "$B4" ] && PASS=$((PASS+1)) && echo "PASS T-10 AC1: beat-4-oauth.sh exists" || { FAIL=$((FAIL+1)); echo "FAIL T-10 AC1"; }
bash -n "$B4" && PASS=$((PASS+1)) && echo "PASS T-10 AC1: bash -n OK" || { FAIL=$((FAIL+1)); echo "FAIL T-10 AC1: bash -n"; }

# AC2: 3-connector all-pending fixture: confirm all 3
bash "$B4" --manifest "$MANIFEST" --settings "$SETTINGS" \
  --input-actions "granola:confirm,gcal:confirm,gmail:confirm" \
  --mock-expiry "2026-08-01T00:00:00Z" \
  --no-gate >/dev/null 2>&1
rc=$?
check "$rc" "0" "T-10 AC2: full walk rc=0"

connected_count=$(jq '[.connectors[] | select(.auth_status == "connected")] | length' "$MANIFEST")
check "$connected_count" "3" "T-10 AC2: all 3 connectors flipped to connected"

# AC6: auth_expires_at populated
exp_count=$(jq '[.connectors[] | select(.auth_expires_at == "2026-08-01T00:00:00Z")] | length' "$MANIFEST")
check "$exp_count" "3" "T-10 AC6: auth_expires_at populated for all 3"

# AC5: settings.json merge — 3 mcpServers entries appended
mcp_count=$(jq '.mcpServers | length' "$SETTINGS")
check "$mcp_count" "3" "T-10 AC5: 3 mcpServers entries in settings.json"

placeholder_count=$(jq '[.mcpServers | to_entries[] | select(.value.placeholder == true)] | length' "$SETTINGS")
check "$placeholder_count" "3" "T-10 AC5: each entry has placeholder:true"

# Reset for AC3 (skip mid-walk) — fresh fixture
cat > "$MANIFEST" <<'JSON'
{
  "connectors_meta": {"user_role": "consultant"},
  "connectors": [
    {"id": "granola", "mcp_server": "claude_ai_Granola",
     "auth_status": "pending", "auth_expires_at": null,
     "schedule": "0 6 * * *", "failure_mode": "block-and-log"},
    {"id": "gcal", "mcp_server": "claude_ai_Google_Calendar",
     "auth_status": "pending", "auth_expires_at": null,
     "schedule": "*/15 * * * *", "failure_mode": "skip-and-log"},
    {"id": "gmail", "mcp_server": "claude_ai_Gmail",
     "auth_status": "pending", "auth_expires_at": null,
     "schedule": "0 7 * * *", "failure_mode": "block-and-log"}
  ]
}
JSON
echo '{"mcpServers": {}}' > "$SETTINGS"

bash "$B4" --manifest "$MANIFEST" --settings "$SETTINGS" \
  --input-actions "granola:confirm,gcal:skip,gmail:confirm" \
  --no-gate >/dev/null 2>&1

# AC3: skipped connector (gcal) remains pending; granola + gmail connected
gcal_status=$(jq -r '.connectors[] | select(.id=="gcal") | .auth_status' "$MANIFEST")
check "$gcal_status" "pending" "T-10 AC3: skipped connector remains pending"
granola_status=$(jq -r '.connectors[] | select(.id=="granola") | .auth_status' "$MANIFEST")
check "$granola_status" "connected" "T-10 AC3: pre-skip connector connected"
gmail_status=$(jq -r '.connectors[] | select(.id=="gmail") | .auth_status' "$MANIFEST")
check "$gmail_status" "connected" "T-10 AC3: post-skip connector still walked"

# AC4: resume — re-invoke; only gcal still pending; confirm it
bash "$B4" --manifest "$MANIFEST" --settings "$SETTINGS" \
  --input-actions "gcal:confirm" \
  --no-gate >/dev/null 2>&1
gcal_status=$(jq -r '.connectors[] | select(.id=="gcal") | .auth_status' "$MANIFEST")
check "$gcal_status" "connected" "T-10 AC4: resume walked the remaining pending"

# ============================================================
# T-11: Final gate
# ============================================================
echo
echo "=== T-11: Final gate ==="
[ -r "$FG" ] && PASS=$((PASS+1)) && echo "PASS T-11 AC1: final-gate.sh exists" || { FAIL=$((FAIL+1)); echo "FAIL T-11 AC1"; }
bash -n "$FG" && PASS=$((PASS+1)) && echo "PASS T-11 AC1: bash -n OK" || { FAIL=$((FAIL+1)); echo "FAIL T-11 AC1: bash -n"; }

# 3-job orchestration + manifest with 3 connectors (all non-manual schedule)
cat > "$ORCH" <<'JSON'
{
  "schema_version": "1.0.0", "platform": "darwin-launchd",
  "jobs": [
    {"id": "librarian", "enabled": true, "schedule": {"hour": 6, "minute": 0},
     "command": "/x", "log_path": "/tmp/x", "idle_watchdog_sec": 180},
    {"id": "digest-run", "enabled": true, "schedule": {"hour": 7, "minute": 30},
     "command": "/y", "log_path": "/tmp/y", "idle_watchdog_sec": 180},
    {"id": "chat-scrape", "enabled": true, "schedule": {"interval_sec": 1800},
     "command": "/z", "log_path": "/tmp/z", "idle_watchdog_sec": 180}
  ],
  "tripwires": [], "observability": {"log_dir": "/tmp"}
}
JSON

# Manifest already has 3 connectors all with non-manual schedule
# AC2: 6 rows rendered (3 jobs + 3 connectors)
render=$(bash "$FG" --manifest "$MANIFEST" --orchestration "$ORCH" --input accept 2>&1 >/dev/null)
job_rows=$(printf '%s' "$render" | grep -E '^\s+(librarian|digest-run|chat-scrape) ' | wc -l | tr -d ' ')
conn_rows=$(printf '%s' "$render" | grep -E '^\s+(granola|gcal|gmail) ' | wc -l | tr -d ' ')
check "$job_rows" "3" "T-11 AC2: 3 job rows rendered"
check "$conn_rows" "3" "T-11 AC2: 3 connector rows rendered"

# AC3: --input abort rc=2
bash "$FG" --manifest "$MANIFEST" --orchestration "$ORCH" --input abort >/dev/null 2>&1
check "$?" "2" "T-11 AC3: --input abort rc=2"

# AC4: --input accept rc=0
bash "$FG" --manifest "$MANIFEST" --orchestration "$ORCH" --input accept >/dev/null 2>&1
check "$?" "0" "T-11 AC4: --input accept rc=0"

# AC5: --accept-on-empty-stdin
bash "$FG" --manifest "$MANIFEST" --orchestration "$ORCH" --accept-on-empty-stdin </dev/null >/dev/null 2>&1
check "$?" "0" "T-11 AC5: --accept-on-empty-stdin EOF treated as accept"

# Bonus: with no connectors having non-manual schedule, conn_rows=0
echo '{"connectors": [{"id": "figma", "mcp_server": "x", "schedule": "manual", "failure_mode": "skip-and-log"}]}' > "$TMPDIR/m-manual.json"
render=$(bash "$FG" --manifest "$TMPDIR/m-manual.json" --orchestration "$ORCH" --input accept 2>&1 >/dev/null)
manual_conn_rows=$(printf '%s' "$render" | grep -E '^\s+figma ' | wc -l | tr -d ' ')
check "$manual_conn_rows" "0" "T-11: 'manual' schedule connectors excluded from final gate"

echo
echo "==========================="
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] && exit 0 || exit 1
