#!/bin/bash
# librarian-cron.sh — Wrapper for scheduled librarian scan via launchd
#
# Fires once weekday morning (06:00 via launchd).
# Monday: /librarian full (weekly deep scan)
# Tue-Fri: /librarian (default recent scope)
# Sat/Sun: skip
#
# Architecture: three independent `claude -p` calls, each with its own
# size-based stream-idle watchdog (180s default). Failures in one call
# do not abort subsequent calls.
#
# Genericized SP03 T-8a (foundation-repo): leak-stripped (LOG_DIR now
# resolves via $CLAUDE_LOG_DIR seeded by lib/paths.sh) and inline lockf
# re-exec / idle-watchdog / post-kill classifier extracted into the
# sibling lib helpers under hooks/lib/ + orchestrator/lib/.

set -uo pipefail

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/lockf.sh"
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/orchestrator/lib/claude-p.sh"
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/orchestrator/lib/idle-watchdog.sh"
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/orchestrator/lib/tripwire.sh"

# --- PATH (launchd provides minimal PATH; node lives in /opt/homebrew/bin) ---
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# --- Config ---
LOG_DIR="$CLAUDE_LOG_DIR"
LOG_FILE="$LOG_DIR/librarian-$(date +%Y%m%d-%H%M%S).log"
CLAUDE="$HOME/.local/bin/claude"
LOCK_FILE="$HOOKS_STATE/librarian-cron.lock"
IDLE_LIMIT=180  # seconds of stream-json silence before watchdog fires

mkdir -p "$LOG_DIR" "$(dirname "$LOCK_FILE")"

# --- Start-time diagnostic (captures actual launchd fire time) ---
echo "=== librarian-cron launchd-fire-received: $(date -Iseconds) pid=$$ ===" >> "$LOG_FILE"

# --- Lock acquisition via lib/lockf.sh ---
# Re-execs $0 under `/usr/bin/lockf -k -t 0` so the entire body runs while
# holding an exclusive advisory lock. Outer call exits with the inner
# script's status (or exits 0 + writes a skip line on rc=75 contention).
# Inner call returns 0 immediately so this script proceeds.
claude_lockf_reexec "$LOCK_FILE" "$@"

# --- Weekday guard ---
DOW=$(date +%u)  # 1=Mon ... 7=Sun
if [ "$DOW" -gt 5 ]; then
  echo "$(date -Iseconds) Weekend — skipping librarian scan" >> "$LOG_DIR/librarian-cron-skip.log"
  exit 0
fi

# --- Day-of-week: Monday = full, Tue-Fri = recent ---
if [ "$DOW" -eq 1 ]; then
  SCOPE_PROMPT="/librarian full"
  SCOPE_LABEL="full"
else
  SCOPE_PROMPT="/librarian"
  SCOPE_LABEL="recent"
fi

echo "=== librarian-cron start: $(date -Iseconds) scope=$SCOPE_LABEL ===" >> "$LOG_FILE"

# --- Cold-wake warm-up probe (Session 18, ENFORCEMENT-MAP Gap #6) ---
# At launchd cold-wake (laptop just resumed, missed jobs batch-dispatched),
# `claude -p` can hang during MCP server init for ≥180s with zero stream-json
# output, tripping the idle-watchdog on all three downstream calls. The
# fingerprint is a small ndjson containing only a "SessionEnd hook ...
# Hook cancelled" death-rattle emitted when our SIGTERM interrupts the
# graceful-shutdown hook chain.
#
# This probe runs a trivial `claude -p "ok"` with a bash-3.2 pure-shell
# 45s timeout. If the probe fails, we sleep 30s and retry once. If the
# retry also fails, we write a distinct error file (status=skipped-cold-start-hang)
# and skip the three expensive calls to avoid wasting the launchd slot.
PROBE_TIMEOUT=45
PROBE_LOG="$HOOKS_STATE/librarian-cron-probe.ndjson"

probe_claude() {
  : > "$PROBE_LOG"
  "$CLAUDE" -p "ok" \
    --permission-mode bypassPermissions \
    --model sonnet \
    --max-budget-usd 1 \
    --output-format stream-json \
    --verbose \
    > "$PROBE_LOG" 2>&1 &
  local ppid=$!
  local waited=0
  while kill -0 "$ppid" 2>/dev/null; do
    sleep 5
    waited=$((waited + 5))
    if [ "$waited" -ge "$PROBE_TIMEOUT" ]; then
      kill "$ppid" 2>/dev/null || true
      wait "$ppid" 2>/dev/null
      return 124
    fi
  done
  wait "$ppid" 2>/dev/null
  return $?
}

echo "--- probe start: $(date -Iseconds) timeout=${PROBE_TIMEOUT}s ---" >> "$LOG_FILE"
probe_claude
PROBE_RC=$?
echo "--- probe end: $(date -Iseconds) rc=$PROBE_RC bytes=$(stat -f%z "$PROBE_LOG" 2>/dev/null || echo 0) ---" >> "$LOG_FILE"

if [ "$PROBE_RC" -ne 0 ]; then
  echo "--- probe FAIL → sleeping 30s and retrying ---" >> "$LOG_FILE"
  sleep 30
  echo "--- probe retry start: $(date -Iseconds) ---" >> "$LOG_FILE"
  probe_claude
  PROBE_RC=$?
  echo "--- probe retry end: $(date -Iseconds) rc=$PROBE_RC bytes=$(stat -f%z "$PROBE_LOG" 2>/dev/null || echo 0) ---" >> "$LOG_FILE"

  if [ "$PROBE_RC" -ne 0 ]; then
    echo "=== librarian-cron skipped: cold-start-hang (probe failed twice) ===" >> "$LOG_FILE"
    if [ -n "${VAULT_LOGS:-}" ]; then
      ERROR_FILE="$VAULT_LOGS/librarian-cron-error-$(date +%Y%m%d-%H%M%S).md"
      cat > "$ERROR_FILE" <<EOF
---
type: log
log-type: librarian-cron-error
date: $(date +%Y-%m-%d)
timestamp: $(date -Iseconds)
status: skipped-cold-start-hang
error-class: claude-p-init-stall
probe-rc: $PROBE_RC
---

# Librarian Cron Skipped — Cold-Start Hang

Warm-up probe (\`claude -p "ok"\`, ${PROBE_TIMEOUT}s timeout) failed twice
with 30s backoff between attempts. The three expensive \`/librarian\` calls
were skipped to avoid wasting the launchd slot and producing misleading
idle-watchdog error files.

**Classification:** harness-stall fingerprint workaround.
Most likely cause: launchd cold-wake dispatch with MCP server init blocking
before any \`claude -p\` stream-json output.

- Wrapper log: $LOG_FILE
- Probe ndjson: $PROBE_LOG
EOF
    fi
    exit 0
  fi
fi

echo "--- probe OK → proceeding to 3 calls ---" >> "$LOG_FILE"

# --- run_librarian_call: claude -p invocation with idle-watchdog composition ---
# Args: label prompt
# Returns: 0 on success, 124 on idle-watchdog-fired, or claude's exit code.
# Composition: backgrounds claude -p, hands pid + ndjson to watchdog_idle
# (lib/idle-watchdog.sh) which dispatches classify_claude_p_exit
# (lib/claude-p.sh) post-kill for two-bucket fingerprint observability.
run_librarian_call() {
  local label="$1"
  local prompt="$2"
  local call_log="$LOG_DIR/librarian-${label}-$(date +%Y%m%d-%H%M%S).ndjson"

  echo "--- call=$label start: $(date -Iseconds) ---" >> "$LOG_FILE"
  echo "    ndjson: $call_log" >> "$LOG_FILE"

  "$CLAUDE" -p "$prompt" \
    --add-dir "$VAULT_ROOT" \
    --add-dir "$CLAUDE_HOME" \
    --permission-mode bypassPermissions \
    --model sonnet \
    --max-budget-usd 5 \
    --output-format stream-json \
    --verbose \
    > "$call_log" 2>&1 &
  local pid=$!

  watchdog_idle "$pid" "$call_log" "$IDLE_LIMIT"
  local rc=$?
  echo "--- call=$label end: $(date -Iseconds) rc=$rc ---" >> "$LOG_FILE"
  return "$rc"
}

# --- Three independent calls; track each status ---
STATUS_SCOPE=""
STATUS_MEMORY=""
STATUS_MINE=""
ANY_FAIL=0

if run_librarian_call "scope" "$SCOPE_PROMPT"; then
  STATUS_SCOPE="success"
else
  rc=$?
  STATUS_SCOPE="error (rc=$rc)"
  ANY_FAIL=1
fi

if run_librarian_call "memory-hygiene" "/librarian memory-hygiene"; then
  STATUS_MEMORY="success"
else
  rc=$?
  STATUS_MEMORY="error (rc=$rc)"
  ANY_FAIL=1
fi

if run_librarian_call "transcript-mine" "/librarian transcript-mine"; then
  STATUS_MINE="success"
else
  rc=$?
  STATUS_MINE="error (rc=$rc)"
  ANY_FAIL=1
fi

echo "=== librarian-cron end: $(date -Iseconds) scope=$STATUS_SCOPE memory=$STATUS_MEMORY mine=$STATUS_MINE ===" >> "$LOG_FILE"

# --- Monday-only: standalone capability shells (drift-sweep, people-audit,
# skill-parity, entity-parity). Failures are additive — they do not flip
# ANY_FAIL because write-time hooks already cover the acute drift classes;
# these are supplemental periodic audits. ---
if [ "$DOW" -eq 1 ]; then
  CAP_DIR="${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities"
  DRIFT_SWEEP="$CAP_DIR/drift-sweep.sh"
  PEOPLE_AUDIT="$CAP_DIR/people-audit.sh"
  SKILL_PARITY="$CAP_DIR/skill-parity.sh"
  ENTITY_PARITY="$CAP_DIR/entity-parity.sh"
  CAP_LOG="$LOG_DIR/librarian-capabilities-$(date +%Y%m%d-%H%M%S).ndjson"

  echo "--- capabilities start: $(date -Iseconds) cap_log=$CAP_LOG ---" >> "$LOG_FILE"

  if [ -x "$DRIFT_SWEEP" ]; then
    echo "=== drift-sweep ===" >> "$CAP_LOG"
    "$DRIFT_SWEEP" --output "$CAP_LOG" 2>>"$LOG_FILE" \
      || echo "drift-sweep exit rc=$? (non-blocking)" >> "$LOG_FILE"
  fi

  if [ -x "$PEOPLE_AUDIT" ]; then
    echo "=== people-audit ===" >> "$CAP_LOG"
    "$PEOPLE_AUDIT" --output "$CAP_LOG" 2>>"$LOG_FILE" \
      || echo "people-audit exit rc=$? (non-blocking)" >> "$LOG_FILE"
  fi

  if [ -x "$SKILL_PARITY" ]; then
    echo "=== skill-parity ===" >> "$CAP_LOG"
    FINDINGS_OUTPUT="$CAP_LOG" "$SKILL_PARITY" 2>>"$LOG_FILE" \
      || echo "skill-parity exit rc=$? (non-blocking)" >> "$LOG_FILE"
  fi

  if [ -x "$ENTITY_PARITY" ]; then
    echo "=== entity-parity ===" >> "$CAP_LOG"
    FINDINGS_OUTPUT="$CAP_LOG" "$ENTITY_PARITY" 2>>"$LOG_FILE" \
      || echo "entity-parity exit rc=$? (non-blocking)" >> "$LOG_FILE"
  fi

  echo "--- capabilities end: $(date -Iseconds) ---" >> "$LOG_FILE"
fi

# --- Error log to vault if any call failed ---
if [ "$ANY_FAIL" -eq 1 ] && [ -n "${VAULT_LOGS:-}" ]; then
  ERROR_FILE="$VAULT_LOGS/librarian-cron-error-$(date +%Y%m%d-%H%M%S).md"
  cat > "$ERROR_FILE" <<EOF
---
type: log
log-type: librarian-cron-error
date: $(date +%Y-%m-%d)
timestamp: $(date -Iseconds)
status: partial-or-failed
scope-status: $STATUS_SCOPE
memory-status: $STATUS_MEMORY
mine-status: $STATUS_MINE
---

# Librarian Cron Error

**scope ($SCOPE_LABEL):** $STATUS_SCOPE
**memory-hygiene:** $STATUS_MEMORY
**transcript-mine:** $STATUS_MINE

**Log:** $LOG_FILE

## Last 80 lines of log
\`\`\`
$(tail -80 "$LOG_FILE")
\`\`\`
EOF
fi

exit $ANY_FAIL
