#!/bin/bash
# Hook: SessionEnd — Deregister or mark session for reconciliation.
# Also evaluates whether to spawn auto session-close for vault files.
# Cannot inject context (session is closing). Output ignored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh"

# Parse stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
if [[ -z "$SESSION_ID" ]]; then
  exit 0
fi

# No registry → nothing to deregister
if [[ ! -f "$REGISTRY_FILE" ]]; then
  exit 0
fi

# --- Snapshot touched files BEFORE deregistration ---
TOUCHED_FILES=$(jq -r --arg sid "$SESSION_ID" \
  '(.sessions[$sid].touched_files // []) | .[]' "$REGISTRY_FILE" 2>/dev/null || true)

# Deregister under lock
export MSC_SESSION_ID="$SESSION_ID"
lockf -k "$REGISTRY_LOCK" "$SCRIPT_DIR/lib/registry-op.sh" deregister

# --- Plan 42 Phase 2: reconcile pending peers if we were the last active ---
# After dereg, re-read the registry. If zero active sessions remain AND at
# least one closed-pending-reconciliation entry sits in the registry, fire
# the reconciler in the background so pending entries do not pile up.
# Fire-and-forget: reconciler is lock-guarded and idempotent.
if [[ -f "$REGISTRY_FILE" ]]; then
  ACTIVE_COUNT=$(jq '[.sessions[] | select(.status == "active")] | length' "$REGISTRY_FILE" 2>/dev/null || echo 0)
  PENDING_COUNT=$(jq '[.sessions[] | select(.status == "closed-pending-reconciliation")] | length' "$REGISTRY_FILE" 2>/dev/null || echo 0)
  if [[ "$ACTIVE_COUNT" = "0" && "$PENDING_COUNT" -gt "0" ]]; then
    nohup "$SCRIPT_DIR/reconcile-sessions.sh" > /dev/null 2>&1 &
  fi
fi

# --- Evaluate auto session-close ---
# Only proceed if session touched vault files
if [[ -z "$TOUCHED_FILES" ]]; then
  exit 0
fi

# Check if any touched files are vault files (they're stored as vault-relative paths)
HAS_VAULT_FILES=false
for f in $TOUCHED_FILES; do
  # Registry stores vault-relative paths — if it's non-empty, it's a vault file
  if [[ -n "$f" ]]; then
    HAS_VAULT_FILES=true
    break
  fi
done

if [[ "$HAS_VAULT_FILES" != "true" ]]; then
  exit 0
fi

# Check for explicit session-close in the last 5 minutes
LOGS_DIR="$VAULT_ROOT/Logs"
EXPLICIT_CLOSE=false
if [[ -d "$LOGS_DIR" ]]; then
  NOW_EPOCH=$(date +%s)
  FIVE_MIN_AGO=$((NOW_EPOCH - 300))
  for log in "$LOGS_DIR"/session-close-*.md; do
    [[ -f "$log" ]] || continue
    # Get file modification time (macOS stat)
    LOG_MTIME=$(stat -f '%m' "$log" 2>/dev/null || echo 0)
    if (( LOG_MTIME >= FIVE_MIN_AGO )); then
      EXPLICIT_CLOSE=true
      break
    fi
  done
fi

if [[ "$EXPLICIT_CLOSE" == "true" ]]; then
  exit 0
fi

# Spawn auto session-close in background (pass files via temp file to handle spaces)
AUTO_CLOSE="$SCRIPT_DIR/session-auto-close.sh"
if [[ -x "$AUTO_CLOSE" ]]; then
  TMPFILE=$(mktemp /tmp/auto-close-files.XXXXXX)
  echo "$TOUCHED_FILES" > "$TMPFILE"
  nohup bash "$AUTO_CLOSE" "$SESSION_ID" "$TMPFILE" > /dev/null 2>&1 &
fi

exit 0
