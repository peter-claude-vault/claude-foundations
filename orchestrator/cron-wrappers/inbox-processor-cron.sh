#!/bin/bash
# inbox-processor-cron.sh — launchd entry-point for the standing Inbox processor.
#
# Resolves vault root from $CLAUDE_HOME/user-manifest.json (jq path
# .vault.root // .paths.vault_root) and invokes
# $CLAUDE_HOME/skills/inbox-processor/process.sh once per tick. Mirrors the
# librarian/architect cron-wrapper pattern (sources paths.sh, sets PATH,
# logs under $CLAUDE_LOG_DIR, lock-protects the tick).
#
# Bash 3.2 compatible (R-23). jq REQUIRED.

set -uo pipefail

PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi
LOCK_LIB="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/lockf.sh"
if [ -r "$LOCK_LIB" ]; then
  # shellcheck source=/dev/null
  . "$LOCK_LIB"
fi

export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CH="${CLAUDE_HOME:-$HOME/.claude}"
LOG_DIR="${CLAUDE_LOG_DIR:-$CH/logs}"
LOG_FILE="$LOG_DIR/inbox-processor-$(date +%Y%m%d-%H%M%S).log"
STATE_DIR="${HOOKS_STATE:-$CH/hooks/state}"
LOCK_FILE="$STATE_DIR/inbox-processor-cron.lock"

mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

echo "=== inbox-processor-cron launchd-fire-received: $(date -Iseconds) pid=$$ ===" >> "$LOG_FILE"

if command -v claude_lockf_reexec >/dev/null 2>&1; then
  claude_lockf_reexec "$LOCK_FILE" "$@"
fi

USER_MANIFEST="$CH/user-manifest.json"
if [ ! -f "$USER_MANIFEST" ]; then
  echo "$(date -Iseconds) inbox-processor-cron: user-manifest.json missing at $USER_MANIFEST; skipping tick" >> "$LOG_FILE"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "$(date -Iseconds) inbox-processor-cron: jq not on PATH; aborting tick" >> "$LOG_FILE"
  exit 2
fi

VAULT_ROOT=$(jq -r '.vault.root // .paths.vault_root // empty' "$USER_MANIFEST" 2>/dev/null)
if [ -z "$VAULT_ROOT" ] || [ "$VAULT_ROOT" = "null" ]; then
  echo "$(date -Iseconds) inbox-processor-cron: vault root not set in user-manifest.json; skipping tick" >> "$LOG_FILE"
  exit 0
fi

if [ ! -d "$VAULT_ROOT" ]; then
  echo "$(date -Iseconds) inbox-processor-cron: vault root not a directory: $VAULT_ROOT; skipping tick" >> "$LOG_FILE"
  exit 0
fi

PROCESS_SH="$CH/skills/inbox-processor/process.sh"
if [ ! -r "$PROCESS_SH" ]; then
  echo "$(date -Iseconds) inbox-processor-cron: process.sh missing at $PROCESS_SH; aborting tick" >> "$LOG_FILE"
  exit 2
fi

AUDIT_LOG="$LOG_DIR/inbox-processor-audit.log"
echo "$(date -Iseconds) inbox-processor-cron: invoking process.sh --vault-root $VAULT_ROOT" >> "$LOG_FILE"

bash "$PROCESS_SH" \
  --vault-root "$VAULT_ROOT" \
  --audit-log "$AUDIT_LOG" \
  --state-file "$CH/inbox-processor-state.json" \
  >> "$LOG_FILE" 2>&1

rc=$?
echo "$(date -Iseconds) inbox-processor-cron: process.sh exit rc=$rc" >> "$LOG_FILE"
exit "$rc"
