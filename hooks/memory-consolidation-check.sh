#!/bin/bash
# Hook: SessionEnd — Evaluate consolidation gates and spawn background runner.
# Must complete in <100ms. Actual consolidation runs detached.
set -euo pipefail

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
MEMORY_DIR="$(resolve_memory_dir)"
STATE_FILE="$MEMORY_DIR/.consolidation-state.json"
LOCK_FILE="$MEMORY_DIR/.consolidation.lock"
RUNNER="$(cd "$(dirname "$0")" && pwd)/memory-consolidation-run.sh"

# Parse stdin for session_id
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# --- Ensure state file exists (bootstrap) ---
if [[ ! -f "$STATE_FILE" ]]; then
  cat > "$STATE_FILE" <<'INIT'
{
  "config": {"hours_threshold": 24, "sessions_threshold": 5},
  "last_consolidation": "1970-01-01T00:00:00Z",
  "sessions_since": 5,
  "last_session_id": "",
  "total_consolidations": 0,
  "last_result": null,
  "last_error": null
}
INIT
fi

# --- Read state ---
STATE=$(cat "$STATE_FILE")

SESSIONS_SINCE=$(echo "$STATE" | jq -r '.sessions_since // 0')
LAST_CONSOLIDATION=$(echo "$STATE" | jq -r '.last_consolidation // "1970-01-01T00:00:00Z"')
HOURS_THRESHOLD=$(echo "$STATE" | jq -r '.config.hours_threshold // 24')
SESSIONS_THRESHOLD=$(echo "$STATE" | jq -r '.config.sessions_threshold // 5')

# --- Increment session counter and write back ---
SESSIONS_SINCE=$((SESSIONS_SINCE + 1))
STATE=$(echo "$STATE" | jq \
  --argjson s "$SESSIONS_SINCE" \
  --arg sid "${SESSION_ID:-unknown}" \
  '.sessions_since = $s | .last_session_id = $sid')

printf '%s\n' "$STATE" > "$STATE_FILE"

# --- Evaluate gates ---
NOW_EPOCH=$(date +%s)
# Parse ISO timestamp to epoch (macOS date)
LAST_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%S" "${LAST_CONSOLIDATION%[Z+-]*}" +%s 2>/dev/null || echo 0)
HOURS_ELAPSED=$(( (NOW_EPOCH - LAST_EPOCH) / 3600 ))

GATE_A=false
GATE_B=false
[[ "$HOURS_ELAPSED" -ge "$HOURS_THRESHOLD" ]] && GATE_A=true
[[ "$SESSIONS_SINCE" -ge "$SESSIONS_THRESHOLD" ]] && GATE_B=true

if [[ "$GATE_A" != "true" ]] || [[ "$GATE_B" != "true" ]]; then
  exit 0
fi

# --- Both gates met — check lock ---
if [[ -f "$LOCK_FILE" ]]; then
  LOCK_PID=$(jq -r '.pid // 0' "$LOCK_FILE" 2>/dev/null || echo 0)
  LOCK_TS=$(jq -r '.timestamp // ""' "$LOCK_FILE" 2>/dev/null || echo "")

  # Check if locked process is still running
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    exit 0  # Consolidation already running
  fi

  # Stale lock detection: >30 minutes old and PID gone
  if [[ -n "$LOCK_TS" ]]; then
    LOCK_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%S" "${LOCK_TS%[Z+-]*}" +%s 2>/dev/null || echo 0)
    LOCK_AGE=$(( NOW_EPOCH - LOCK_EPOCH ))
    if [[ "$LOCK_AGE" -lt 1800 ]]; then
      exit 0  # Lock is recent, process may have just died — be conservative
    fi
  fi

  # Stale lock — remove it
  rm -f "$LOCK_FILE"
fi

# --- Create lock and spawn runner ---
jq -n --arg pid "$$" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{"pid": ($pid | tonumber), "timestamp": $ts}' > "$LOCK_FILE"

# Spawn detached — runner will update its own PID in the lock
nohup bash "$RUNNER" > /dev/null 2>&1 &
RUNNER_PID=$!

# Update lock with actual runner PID
jq -n --argjson pid "$RUNNER_PID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{"pid": $pid, "timestamp": $ts}' > "$LOCK_FILE"

exit 0
