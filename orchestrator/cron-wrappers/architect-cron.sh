#!/bin/bash
# architect-cron.sh — Wrapper for scheduled architect analysis via launchd
# Runs weekly Sunday. Full 7-dimension analysis with convergence tracking.
#
# Genericized SP03 T-8b (foundation-repo): leak-stripped (LOG_DIR now
# resolves via $CLAUDE_LOG_DIR seeded by lib/paths.sh). Architect is a
# single-capability invocation with no concurrent write paths and no
# stream-json output, so it consumes only paths.sh — lockf / idle-watchdog
# / claude-p classifier / tripwire are not applicable here (S51 precedent:
# do not source what is not used). The portable run_with_timeout helper
# remains inline because it predates orchestrator/lib/ and has no other
# callers to justify extraction.

set -euo pipefail

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"

# --- PATH (launchd provides minimal PATH) ---
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# --- Config ---
TIMEOUT_SEC=2400  # 40 minutes (architect is comprehensive)
LOG_DIR="$CLAUDE_LOG_DIR"
LOG_FILE="$LOG_DIR/architect-$(date +%Y%m%d-%H%M%S).log"
CLAUDE="$HOME/.local/bin/claude"

mkdir -p "$LOG_DIR"

# --- Start-time diagnostic (parity with librarian-cron; captures actual
# launchd fire time before any work begins) ---
echo "=== architect-cron launchd-fire-received: $(date -Iseconds) pid=$$ ===" >> "$LOG_FILE"

# --- Portable timeout (macOS has no coreutils timeout) ---
run_with_timeout() {
  local timeout=$1; shift
  "$@" &
  local pid=$!
  ( sleep "$timeout" && kill "$pid" 2>/dev/null ) &
  local watchdog=$!
  if wait "$pid" 2>/dev/null; then
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    return 0
  else
    local rc=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    if [ "$rc" -eq 143 ] || ! kill -0 "$pid" 2>/dev/null; then
      return 124
    fi
    return "$rc"
  fi
}

# --- Find previous architect report for convergence tracking ---
PREV_REPORT=""
if [ -n "${VAULT_LOGS:-}" ]; then
  PREV_REPORT=$(ls -t "$VAULT_LOGS"/architect-????-??-??.md 2>/dev/null | head -1)
fi

# --- Run ---
echo "=== architect-cron start: $(date -Iseconds) ===" >> "$LOG_FILE"

if [ -n "$PREV_REPORT" ]; then
  PROMPT="You are running as an automated scheduled task. Perform the weekly architect analysis.

Run /architect --adaptive --compare \"$PREV_REPORT\"

This runs the full 7-dimension analysis with adaptive depth and convergence tracking against the previous report. Report: dimension depth allocation, key findings, new recommendations in R-NNN format, convergence trends."
else
  PROMPT='You are running as an automated scheduled task. Perform the weekly architect analysis.

Run /architect --adaptive

This runs the full 7-dimension analysis with adaptive depth. Report: dimension depth allocation, key findings, new recommendations in R-NNN format.'
fi

# --- Invoke claude -p; --add-dir VAULT_ROOT only when resolved ---
run_claude() {
  if [ -n "${VAULT_ROOT:-}" ]; then
    "$CLAUDE" -p "$PROMPT" \
      --add-dir "$HOME" \
      --add-dir "$VAULT_ROOT" \
      --permission-mode bypassPermissions \
      --model opus \
      --max-budget-usd 10
  else
    "$CLAUDE" -p "$PROMPT" \
      --add-dir "$HOME" \
      --permission-mode bypassPermissions \
      --model opus \
      --max-budget-usd 10
  fi
}

if run_with_timeout "$TIMEOUT_SEC" run_claude >> "$LOG_FILE" 2>&1; then
  STATUS="success"
else
  EXIT_CODE=$?
  if [ "$EXIT_CODE" -eq 124 ]; then
    STATUS="timeout"
  else
    STATUS="error (exit $EXIT_CODE)"
  fi
fi

echo "=== architect-cron end: $(date -Iseconds) status=$STATUS ===" >> "$LOG_FILE"

# --- Error logging to vault ---
if [ "$STATUS" != "success" ] && [ -n "${VAULT_LOGS:-}" ]; then
  ERROR_FILE="$VAULT_LOGS/architect-cron-error-$(date +%Y%m%d-%H%M%S).md"
  cat > "$ERROR_FILE" <<EOF
---
type: log
log-type: architect-cron-error
date: $(date +%Y-%m-%d)
timestamp: $(date -Iseconds)
status: $STATUS
---

# Architect Cron Error

**Status:** $STATUS
**Log:** $LOG_FILE

## Last 50 lines of log
\`\`\`
$(tail -50 "$LOG_FILE")
\`\`\`
EOF
fi
