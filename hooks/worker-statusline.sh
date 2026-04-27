#!/bin/bash
# Status line script: writes context_window.used_percentage to shared state file.
# Registered as statusLineCommand in settings.json.
# Other hooks (prompt-context.sh, stop-checkpoint-check.sh) read this state.

STATE_DIR="$HOME/.claude/hooks/state"
STATE_FILE="$STATE_DIR/context-pressure.json"

# Read stdin (status line JSON)
input=$(cat)

# Extract fields — default to 0 if missing/null
pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
sid=$(echo "$input" | jq -r '.session_id // "unknown"')
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Ensure state dir exists
mkdir -p "$STATE_DIR"

# Atomic write: tmp then rename
tmp="${STATE_FILE}.tmp.$$"
printf '{"pct":%s,"session_id":"%s","timestamp":"%s"}\n' "$pct" "$sid" "$ts" > "$tmp"
mv "$tmp" "$STATE_FILE"

# Display context percentage in status line
if (( $(echo "$pct > 70" | bc -l 2>/dev/null || echo 0) )); then
  printf '\033[31m[CTX %s%%]\033[0m' "$pct"
elif (( $(echo "$pct > 50" | bc -l 2>/dev/null || echo 0) )); then
  printf '\033[33m[CTX %s%%]\033[0m' "$pct"
fi
