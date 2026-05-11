#!/bin/bash
# Status line script: writes context_window.used_percentage to per-session state file.
# Registered as statusLineCommand in settings.json.
# Other hooks (prompt-context.sh, stop-checkpoint-check.sh) read this state.
# Plan 84 SP02 T-2 (2026-05-11): per-session pressure file path
# `sessions/<sid>/context-pressure.json`. Legacy bare path retired same day.

STATE_DIR="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/state}}"

# Read stdin (status line JSON)
input=$(cat)

# Extract fields — default to 0 if missing/null
pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
sid=$(echo "$input" | jq -r '.session_id // empty')
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Per-session write: skip file write if no session_id (keep status display intact).
if [[ -n "$sid" ]]; then
  SESSION_DIR="$STATE_DIR/sessions/$sid"
  STATE_FILE="$SESSION_DIR/context-pressure.json"
  mkdir -p "$SESSION_DIR"
  tmp="${STATE_FILE}.tmp.$$"
  printf '{"pct":%s,"session_id":"%s","timestamp":"%s"}\n' "$pct" "$sid" "$ts" > "$tmp"
  mv "$tmp" "$STATE_FILE"
fi

# Display context percentage in status line
if (( $(echo "$pct > 70" | bc -l 2>/dev/null || echo 0) )); then
  printf '\033[31m[CTX %s%%]\033[0m' "$pct"
elif (( $(echo "$pct > 50" | bc -l 2>/dev/null || echo 0) )); then
  printf '\033[33m[CTX %s%%]\033[0m' "$pct"
fi
