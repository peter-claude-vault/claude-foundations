#!/usr/bin/env bash
# tests/connectors/reliability-infra-unit-test.sh — synthetic unit tests for SP14
# T-13 (STATUS.md), T-14 (run-history + log-rotate), T-15 (auth-expiry +
# reconnect), T-16 (failure-mode catalog + runner).
#
# Run: bash tests/connectors/reliability-infra-unit-test.sh
# Exit: 0 on all-pass; 1 on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SR="$REPO_ROOT/connectors/lib/status-render.sh"
LA="$REPO_ROOT/connectors/lib/log-append.sh"
LR="$REPO_ROOT/connectors/lib/log-rotate.sh"
AD="$REPO_ROOT/connectors/lib/auth-detect.sh"
RUN="$REPO_ROOT/connectors/runner.sh"
CAT="$REPO_ROOT/connectors/failure-mode-catalog.json"
WIZ="$REPO_ROOT/onboarding/connectors/wizard.sh"
B4="$REPO_ROOT/onboarding/connectors/beats/beat-4-oauth.sh"

PASS=0; FAIL=0
check() {
  if [ "$1" = "$2" ]; then
    PASS=$((PASS+1)); echo "PASS $3"
  else
    FAIL=$((FAIL+1)); echo "FAIL $3 (got '$1' expected '$2')" >&2
  fi
}

TMPDIR="$(mktemp -d -t sp14-relinfra-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
MANIFEST="$TMPDIR/manifest.json"
LOG_DIR="$TMPDIR/logs"
STATUS="$TMPDIR/STATUS.md"

# 3-connector manifest fixture
cat > "$MANIFEST" <<'JSON'
{
  "connectors": [
    {"id": "granola", "mcp_server": "claude_ai_Granola",
     "auth_status": "connected", "auth_expires_at": "2026-08-01T00:00:00Z",
     "schedule": "0 6 * * *", "last_run": null, "last_status": null,
     "failure_mode": "block-and-log"},
    {"id": "gcal", "mcp_server": "claude_ai_Google_Calendar",
     "auth_status": "pending", "auth_expires_at": null,
     "schedule": "*/15 * * * *", "last_run": null, "last_status": null,
     "failure_mode": "skip-and-log"},
    {"id": "gmail", "mcp_server": "claude_ai_Gmail",
     "auth_status": "connected", "auth_expires_at": "2026-09-01T00:00:00Z",
     "schedule": "0 7 * * *", "last_run": null, "last_status": null,
     "failure_mode": "auto-disable"}
  ]
}
JSON

# ============================================================
# T-13: status-render.sh
# ============================================================
echo "=== T-13: status-render ==="
[ -r "$SR" ] && PASS=$((PASS+1)) && echo "PASS T-13 AC1: status-render.sh exists" || { FAIL=$((FAIL+1)); echo "FAIL T-13 AC1"; }
bash -n "$SR" && PASS=$((PASS+1)) && echo "PASS T-13 AC1: bash -n OK" || { FAIL=$((FAIL+1)); echo "FAIL T-13 AC1"; }

bash "$SR" --manifest "$MANIFEST" --out "$STATUS" >/dev/null 2>&1
check "$?" "0" "T-13 AC2: status-render rc=0 on 3-conn fixture"
[ -r "$STATUS" ] && PASS=$((PASS+1)) && echo "PASS T-13 AC2: STATUS.md written" || { FAIL=$((FAIL+1)); echo "FAIL T-13 AC2"; }

# Verify table structure
header_seen=$(grep -c '| Connector | Last Run | Status | Auth | Next Run |' "$STATUS")
check "$header_seen" "1" "T-13 AC2: header row present"
sep_seen=$(grep -c '|-----------|----------|--------|------|----------|' "$STATUS")
check "$sep_seen" "1" "T-13 AC2: separator row present"
data_rows=$(grep -cE '^\| (granola|gcal|gmail) ' "$STATUS")
check "$data_rows" "3" "T-13 AC2: 3 data rows"

# AC3: markdown renders cleanly (no broken pipes); count cells per data row
broken=$(awk -F'|' '/^\| (granola|gcal|gmail) /{ if (NF != 7) print "broken"}' "$STATUS")
check "$broken" "" "T-13 AC3: all data rows have 7 cells (5 columns + 2 boundary pipes)"

# AC4: empty connectors[] fixture
echo '{"connectors": []}' > "$TMPDIR/empty.json"
EMPTY_OUT="$TMPDIR/empty-status.md"
bash "$SR" --manifest "$TMPDIR/empty.json" --out "$EMPTY_OUT" >/dev/null 2>&1
check "$?" "0" "T-13 AC4: empty connectors[] rc=0"
grep -q 'No connectors configured' "$EMPTY_OUT" && PASS=$((PASS+1)) && echo "PASS T-13 AC4: 'No connectors configured' placeholder" || { FAIL=$((FAIL+1)); echo "FAIL T-13 AC4"; }

# Bonus: gmail with auto-disable + connected shows expiry
if grep -qE '\| gmail \|.*\| connected \(exp 2026-09-01' "$STATUS"; then
  PASS=$((PASS+1)); echo "PASS T-13 bonus: gmail auth_status with expiry rendered"
else
  FAIL=$((FAIL+1)); echo "FAIL T-13 bonus: gmail auth_status not rendered with expiry"
fi

# ============================================================
# T-14: log-append + log-rotate
# ============================================================
echo
echo "=== T-14: log-append + log-rotate ==="
[ -r "$LA" ] && PASS=$((PASS+1)) && echo "PASS T-14 AC1: log-append.sh exists" || { FAIL=$((FAIL+1)); echo "FAIL T-14 AC1"; }
bash -n "$LA" && PASS=$((PASS+1)) && echo "PASS T-14 AC1: log-append.sh bash -n OK" || { FAIL=$((FAIL+1)); echo "FAIL T-14 AC1"; }

# 3-run fixture
for i in 1 2 3; do
  bash "$LA" --id granola --status ok --items-pulled "$i" --duration-ms "$((i*100))" --log-dir "$LOG_DIR" >/dev/null 2>&1
done
[ -r "$LOG_DIR/granola.log" ] && PASS=$((PASS+1)) && echo "PASS T-14 AC2: granola.log created" || { FAIL=$((FAIL+1)); echo "FAIL T-14 AC2"; }

n=$(wc -l < "$LOG_DIR/granola.log" | tr -d ' ')
check "$n" "3" "T-14 AC2: 3 JSON-line records"

# Each line is valid JSON
all_valid=1
while IFS= read -r line; do
  jq -e . <<<"$line" >/dev/null 2>&1 || all_valid=0
done < "$LOG_DIR/granola.log"
check "$all_valid" "1" "T-14 AC2: all JSON-lines valid"

# Required keys present
ts_count=$(jq -r '.ts' "$LOG_DIR/granola.log" 2>/dev/null | wc -l | tr -d ' ')
# shellcheck disable=SC2126
status_count=$(jq -r '.status' "$LOG_DIR/granola.log" 2>/dev/null | grep -c .)
check "$ts_count" "3" "T-14 AC2: ts present in all records"
check "$status_count" "3" "T-14 AC2: status present in all records"

# Error-only fixture
bash "$LA" --id gcal --status error --error "401 unauthorized" --log-dir "$LOG_DIR" >/dev/null 2>&1
err_msg=$(jq -r '.error' "$LOG_DIR/gcal.log")
check "$err_msg" "401 unauthorized" "T-14: error field captured"

# Bad inputs
bash "$LA" --id BAD-ID --status ok --log-dir "$LOG_DIR" >/dev/null 2>&1
check "$?" "2" "T-14: invalid id rc=2"
bash "$LA" --id granola --status invalid --log-dir "$LOG_DIR" >/dev/null 2>&1
check "$?" "2" "T-14: invalid status rc=2"

# log-rotate
[ -r "$LR" ] && PASS=$((PASS+1)) && echo "PASS T-14 AC3: log-rotate.sh exists" || { FAIL=$((FAIL+1)); echo "FAIL T-14 AC3"; }
bash -n "$LR" && PASS=$((PASS+1)) && echo "PASS T-14 AC3: log-rotate.sh bash -n OK" || { FAIL=$((FAIL+1)); echo "FAIL T-14 AC3"; }

# AC4: synthetic large-log fixture (>1MB) → rotated to .1
ROT_DIR="$TMPDIR/rot-logs"
mkdir -p "$ROT_DIR"
# Create a 2MB log file
yes ok | head -c $((2 * 1024 * 1024)) > "$ROT_DIR/big.log"
bash "$LR" --log-dir "$ROT_DIR" >/dev/null 2>&1
[ -r "$ROT_DIR/big.log.1" ] && PASS=$((PASS+1)) && echo "PASS T-14 AC4: large log rotated to .1" || { FAIL=$((FAIL+1)); echo "FAIL T-14 AC4"; }
new_size=$(stat -f%z "$ROT_DIR/big.log" 2>/dev/null || stat -c%s "$ROT_DIR/big.log")
check "$new_size" "0" "T-14 AC4: post-rotate log truncated"

# ============================================================
# T-15: auth-detect + reconnect
# ============================================================
echo
echo "=== T-15: auth-detect + reconnect ==="
[ -r "$AD" ] && PASS=$((PASS+1)) && echo "PASS T-15 AC1: auth-detect.sh exists" || { FAIL=$((FAIL+1)); echo "FAIL T-15 AC1"; }
bash -n "$AD" && PASS=$((PASS+1)) && echo "PASS T-15 AC1: auth-detect.sh bash -n OK" || { FAIL=$((FAIL+1)); echo "FAIL T-15 AC1"; }

# AC2: synthetic expired-token fixture flips auth_status:expired
bash "$AD" --id gmail --error-msg "401 unauthorized: token expired" \
  --manifest "$MANIFEST" --no-launchctl >/dev/null 2>&1
check "$?" "0" "T-15 AC2: detector matched + patched manifest"
new_auth=$(jq -r '.connectors[] | select(.id=="gmail") | .auth_status' "$MANIFEST")
check "$new_auth" "expired" "T-15 AC2: gmail auth_status flipped to expired"

# AC5: cascade test — granola + gcal NOT touched
gran_auth=$(jq -r '.connectors[] | select(.id=="granola") | .auth_status' "$MANIFEST")
check "$gran_auth" "connected" "T-15 AC5: granola auth_status NOT cascaded"
gcal_auth=$(jq -r '.connectors[] | select(.id=="gcal") | .auth_status' "$MANIFEST")
check "$gcal_auth" "pending" "T-15 AC5: gcal auth_status NOT cascaded"

# AC3: STATUS.md re-render shows RECONNECT REQUIRED for gmail
bash "$SR" --manifest "$MANIFEST" --out "$STATUS" >/dev/null 2>&1
if grep -qE '\| gmail \|.*RECONNECT REQUIRED' "$STATUS"; then
  PASS=$((PASS+1)); echo "PASS T-15 AC3: gmail badge 'RECONNECT REQUIRED' in STATUS.md"
else
  FAIL=$((FAIL+1)); echo "FAIL T-15 AC3"
fi

# AC4: wizard.sh --reconnect <id> re-runs Beat 4 + flips back to connected
[ -r "$WIZ" ] && PASS=$((PASS+1)) && echo "PASS T-15 AC4: wizard.sh exists" || { FAIL=$((FAIL+1)); echo "FAIL T-15 AC4"; }
bash -n "$WIZ" && PASS=$((PASS+1)) && echo "PASS T-15 AC4: wizard.sh bash -n OK" || { FAIL=$((FAIL+1)); echo "FAIL T-15 AC4"; }

bash "$WIZ" --manifest "$MANIFEST" --reconnect gmail \
  --mock-expiry "2026-12-01T00:00:00Z" \
  --no-gate >/dev/null 2>&1
check "$?" "0" "T-15 AC4: reconnect rc=0"
new_auth=$(jq -r '.connectors[] | select(.id=="gmail") | .auth_status' "$MANIFEST")
check "$new_auth" "connected" "T-15 AC4: reconnect flipped gmail back to connected"

# Negative case: detector rc=1 on no match
bash "$AD" --id granola --error-msg "some other error" --manifest "$MANIFEST" --no-launchctl >/dev/null 2>&1
check "$?" "1" "T-15: detector rc=1 on no-match"

# ============================================================
# T-16: failure-mode catalog + runner
# ============================================================
echo
echo "=== T-16: failure-mode catalog + runner ==="
[ -r "$CAT" ] && PASS=$((PASS+1)) && echo "PASS T-16: catalog exists" || { FAIL=$((FAIL+1)); echo "FAIL T-16"; }
jq -e . "$CAT" >/dev/null 2>&1 && PASS=$((PASS+1)) && echo "PASS T-16: catalog valid JSON" || { FAIL=$((FAIL+1)); echo "FAIL T-16"; }

# All 5 modes present
for mode in block-and-log auto-disable backoff-retry skip-and-log no-op; do
  if jq -e --arg m "$mode" '.modes[$m]' "$CAT" >/dev/null 2>&1; then
    PASS=$((PASS+1)); echo "PASS T-16: catalog has mode '$mode'"
  else
    FAIL=$((FAIL+1)); echo "FAIL T-16: catalog missing mode '$mode'"
  fi
done

[ -r "$RUN" ] && PASS=$((PASS+1)) && echo "PASS T-16: runner.sh exists" || { FAIL=$((FAIL+1)); echo "FAIL T-16"; }
bash -n "$RUN" && PASS=$((PASS+1)) && echo "PASS T-16: runner.sh bash -n OK" || { FAIL=$((FAIL+1)); echo "FAIL T-16"; }

# Reset manifest for runner test
cat > "$MANIFEST" <<'JSON'
{
  "connectors": [
    {"id": "granola", "mcp_server": "claude_ai_Granola",
     "auth_status": "connected", "schedule": "0 6 * * *",
     "failure_mode": "block-and-log"}
  ]
}
JSON
RUN_LOG_DIR="$TMPDIR/run-logs"
RUN_STATUS="$TMPDIR/run-status.md"

# Successful run
echo '{"items": [1,2,3]}' > "$TMPDIR/mock-stdout.json"
bash "$RUN" --id granola --manifest "$MANIFEST" --catalog "$CAT" \
  --log-dir "$RUN_LOG_DIR" --status-out "$RUN_STATUS" \
  --mock-stdout "$TMPDIR/mock-stdout.json" --mock-rc 0 \
  --no-launchctl >/dev/null 2>&1
check "$?" "0" "T-16: runner rc=0 on success"
[ -r "$RUN_LOG_DIR/granola.log" ] && PASS=$((PASS+1)) && echo "PASS T-16: log appended" || { FAIL=$((FAIL+1)); echo "FAIL T-16"; }
status_in_log=$(jq -r '.status' "$RUN_LOG_DIR/granola.log" | head -1)
check "$status_in_log" "ok" "T-16: status='ok' on success"

# Source-empty mock
echo '{"items": []}' > "$TMPDIR/empty-stdout.json"
bash "$RUN" --id granola --manifest "$MANIFEST" --catalog "$CAT" \
  --log-dir "$RUN_LOG_DIR" --status-out "$RUN_STATUS" \
  --mock-stdout "$TMPDIR/empty-stdout.json" --mock-rc 0 \
  --no-launchctl >/dev/null 2>&1
last_status=$(tail -1 "$RUN_LOG_DIR/granola.log" | jq -r '.status')
check "$last_status" "no-op" "T-16: status='no-op' on source-empty"

# Auto-disable mode + 401 stderr triggers auth-detect
cat > "$MANIFEST" <<'JSON'
{
  "connectors": [
    {"id": "gmail", "mcp_server": "claude_ai_Gmail",
     "auth_status": "connected", "schedule": "0 7 * * *",
     "failure_mode": "auto-disable"}
  ]
}
JSON
echo "401 unauthorized: token expired" > "$TMPDIR/auth-stderr.txt"
bash "$RUN" --id gmail --manifest "$MANIFEST" --catalog "$CAT" \
  --log-dir "$RUN_LOG_DIR" --status-out "$RUN_STATUS" \
  --mock-stderr "$TMPDIR/auth-stderr.txt" --mock-rc 1 \
  --no-launchctl >/dev/null 2>&1
new_auth=$(jq -r '.connectors[] | select(.id=="gmail") | .auth_status' "$MANIFEST")
check "$new_auth" "expired" "T-16: auto-disable mode triggers auth-detect → expired"

# Catalog refusal: invalid catalog
echo '{not valid json' > "$TMPDIR/bad-catalog.json"
bash "$RUN" --id gmail --manifest "$MANIFEST" --catalog "$TMPDIR/bad-catalog.json" \
  --log-dir "$RUN_LOG_DIR" --status-out "$RUN_STATUS" \
  --no-launchctl >/dev/null 2>&1
check "$?" "1" "T-16: invalid catalog rc=1 (refuses to start)"

echo
echo "==========================="
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] && exit 0 || exit 1
