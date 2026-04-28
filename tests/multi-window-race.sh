#!/usr/bin/env bash
# multi-window-race.sh — SP02 T-10 commit 5.
#
# Concurrent-shell race-condition probe for cross-hook registry.json writes.
# Tests the lockf wrapper around registry-op.sh (per session-register.sh L42,
# track-vault-write.sh L36, session-deregister.sh L28). Lock contract:
# concurrent registry mutations serialize via lockf -k $REGISTRY_LOCK.
#
# Two race patterns exercised:
#   Round 1: N concurrent session-register.sh — assert all N sessions
#            present and JSON valid (no corrupted/lost writes)
#   Round 2: N concurrent track-vault-write.sh — assert each session lists
#            its unique file (no cross-session blow-away)
#
# Implementation note: registry.sh:clean_stale() removes sessions whose PID
# is dead. Test holds each subshell alive (sleep) so registered PIDs stay
# valid throughout the test window. This mirrors real-world behavior where
# Claude Code sessions hold registry entries while their bash process is
# alive.
#
# Failure signature for SP02 T-13 lock-wrapper retrofit: missing entries,
# JSON parse error, or session lacks its file → reproducible repro for the
# Plan 42 T-2e shared-state race surface.
#
# N=10 default (RACE_N env override).
#
# Bash 3.2 compatible (R-23).

set -u

SBX="/tmp/multi-window-race-sbx-$$"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
N="${RACE_N:-10}"
HOLD_SECS="${HOLD_SECS:-15}"

HOLDER_PIDS=""
trap 'cleanup' EXIT INT TERM

cleanup() {
  if [ -n "$HOLDER_PIDS" ]; then
    # Kill backgrounded holder subshells (silently — they're sleep-blocked)
    for pid in $HOLDER_PIDS; do
      kill -TERM "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
  fi
  rm -rf "$SBX"
}

pass=0
fail=0
fail_log=""

record_pass() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
record_fail() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
  fail_log="${fail_log}
  FAIL: $1
    detail: $2"
}

make_sbx() {
  rm -rf "$SBX"
  mkdir -p "$SBX/.claude/hooks/lib" "$SBX/.claude/hooks/state" \
           "$SBX/.claude/hooks/config" "$SBX/.claude/schemas" \
           "$SBX/.claude/skills/librarian/lib" \
           "$SBX/vault/Logs/.coordination"
  cp "$SRC/hooks"/*.sh "$SBX/.claude/hooks/"
  cp "$SRC/lib"/*.sh "$SBX/.claude/hooks/lib/"
  echo '{"version":2,"entries":[]}' > "$SBX/.claude/hooks/config/doc-dependencies.json"
  cat > "$SBX/.claude/schemas/vault-schema.json" <<'JSON'
{"schema_version":"1.0.0","_aliases":{}}
JSON
  cat > "$SBX/.claude/skills/librarian/lib/plan-path.sh" <<'PLANPATH'
classify_plan_path() { echo "0|0|"; }
PLANPATH
  echo '{"sessions":{},"pending_reconciliation":false,"last_reconciled":""}' \
    > "$SBX/vault/Logs/.coordination/session-registry.json"
  cat > "$SBX/.claude/user-manifest.json" <<'JSON'
{
  "identity": {}, "paths": {}, "tools": {"messaging": []}, "vault": {},
  "projects": {"active": []}, "people": [], "behavioral": {"hook_preferences": {}},
  "backlog": {}, "architect": {}, "system": {"schema_version": "1.1.0", "opt_outs": []}
}
JSON
}

REGISTRY="$SBX/vault/Logs/.coordination/session-registry.json"

# Wait until JSON predicate matches OR timeout. Poll every 100ms.
# Args: predicate_label timeout_secs jq_filter expected_value
wait_until() {
  local label="$1" timeout="$2" filter="$3" expected="$4"
  local elapsed=0 max=$((timeout * 10))  # decisecond ticks
  while [ "$elapsed" -lt "$max" ]; do
    local current
    current=$(jq -r "$filter" "$REGISTRY" 2>/dev/null || echo "")
    if [ "$current" = "$expected" ]; then return 0; fi
    sleep 0.1
    elapsed=$((elapsed + 1))
  done
  return 1
}

assert_json_valid() {
  local label="$1"
  if jq -e . "$REGISTRY" >/dev/null 2>&1; then
    record_pass "$label: registry.json is valid JSON"
  else
    record_fail "$label" "registry.json corrupted: $(cat "$REGISTRY" 2>/dev/null)"
  fi
}

# ============================================================================
# Build sandbox
# ============================================================================
make_sbx

# Stage per-session register inputs
i=1
while [ "$i" -le "$N" ]; do
  SID="sid-$(printf '%04d' "$i")"
  jq -nc --arg sid "$SID" '{session_id:$sid,source:"startup"}' \
    > "$SBX/.input-reg-$i.json"
  jq -nc --arg sid "$SID" --arg fp "$SBX/vault/file-$(printf '%04d' "$i").md" \
    '{tool_name:"Write",tool_input:{file_path:$fp,content:"x"},session_id:$sid}' \
    > "$SBX/.input-track-$i.json"
  i=$((i + 1))
done

# ============================================================================
# ROUND 1: N concurrent session-register.sh under holder-PIDs
# ============================================================================
echo "ROUND 1: $N concurrent session-register.sh"

i=1
while [ "$i" -le "$N" ]; do
  bash -c "
    env -i HOME='$SBX' CLAUDE_HOME='$SBX/.claude' \
      PATH='/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin' \
      VAULT_ROOT='$SBX/vault' PLANS_DIR='$SBX/.claude-plans' \
      PWD='$SBX' \
      bash -c \"cd '$SBX'; bash '$SBX/.claude/hooks/session-register.sh' < '$SBX/.input-reg-$i.json' >/dev/null 2>&1; exec sleep $HOLD_SECS\"
  " &
  HOLDER_PIDS="$HOLDER_PIDS $!"
  i=$((i + 1))
done

# Wait until all N registered (or fail-timeout)
if wait_until "register-fanout" 5 '.sessions | keys | length' "$N"; then
  record_pass "round-1 register: all $N sessions registered within 5s"
else
  current=$(jq -r '.sessions | keys | length' "$REGISTRY" 2>/dev/null)
  record_fail "round-1 register" "expected $N sessions within 5s, got $current"
fi
assert_json_valid "round-1 register"

# ============================================================================
# ROUND 2: N concurrent track-vault-write.sh
# ============================================================================
echo "ROUND 2: $N concurrent track-vault-write.sh"

i=1
TRACK_PIDS=""
while [ "$i" -le "$N" ]; do
  (
    env -i HOME="$SBX" CLAUDE_HOME="$SBX/.claude" \
      PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
      VAULT_ROOT="$SBX/vault" PLANS_DIR="$SBX/.claude-plans" \
      PWD="$SBX" \
      bash -c "cd '$SBX'; bash '$SBX/.claude/hooks/track-vault-write.sh' < '$SBX/.input-track-$i.json' >/dev/null 2>&1"
  ) &
  TRACK_PIDS="$TRACK_PIDS $!"
  i=$((i + 1))
done

# Wait for all track invocations to finish (they don't sleep)
for pid in $TRACK_PIDS; do
  wait "$pid" 2>/dev/null || true
done

assert_json_valid "round-2 update-files"

all_files_logged=true
i=1
while [ "$i" -le "$N" ]; do
  SID="sid-$(printf '%04d' "$i")"
  # track-vault-write stores VAULT-RELATIVE paths (registry.sh:vault_relative)
  EXPECTED_FILE="file-$(printf '%04d' "$i").md"
  GOT_FILES=$(jq -r --arg sid "$SID" '.sessions[$sid].touched_files // [] | join(",")' "$REGISTRY" 2>/dev/null)
  if [ "$GOT_FILES" != "$EXPECTED_FILE" ]; then
    all_files_logged=false
    record_fail "round-2 file logging" "session $SID: expected '$EXPECTED_FILE', got '$GOT_FILES'"
    break
  fi
  i=$((i + 1))
done
if $all_files_logged; then
  record_pass "round-2 update-files: all $N sessions have their unique file logged"
fi

# ============================================================================
# Summary
# ============================================================================
printf '\n----------------------------------\n'
printf 'passed: %s\n' "$pass"
printf 'failed: %s\n' "$fail"
printf '%s\n' '----------------------------------'
if [ "$fail" -gt 0 ]; then
  printf '\nFailures:%s\n' "$fail_log"
  printf '\nFinal registry state:\n'
  jq . "$REGISTRY" 2>/dev/null || cat "$REGISTRY"
  exit 1
fi
exit 0
