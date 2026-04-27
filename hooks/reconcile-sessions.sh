#!/bin/bash
# reconcile-sessions.sh — Plan 42 Phase 2 reconciler.
#
# Walks session-registry.json, absorbs every `closed-pending-reconciliation`
# entry into an append-only audit log, and flips the `pending_reconciliation`
# flag back to false. Idempotent and lock-guarded; safe to invoke from any
# session at any time.
#
# Scope is intentionally narrow: registry state + audit trail only. Heavier
# reconciliation (git pull/push, `/librarian full --fix`, manifest regen)
# stays under `/librarian session-close` — running it here would be redundant
# when a human closes a session and intrusive when a background cron session
# exits.
#
# Entry points:
#   - session-deregister.sh tail (automatic after every SessionEnd)
#   - /librarian session-close Step 2c (scripted in the session-close chain)
#
# Exit codes:
#   0 — reconciler ran to completion OR lock was busy (another process is
#       reconciling — nothing to do).
#   non-zero — only on programmer error (jq missing, registry unreadable, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh"

# If the registry file doesn't exist, nothing to reconcile.
if [[ ! -f "$REGISTRY_FILE" ]]; then
  exit 0
fi

ensure_coord_dir
RECONCILE_LOG="$COORD_DIR/reconcile-log.ndjson"

# Leader election gate. When sourced as a normal invocation, re-exec self
# under `lockf -t 0`. The re-exec hits the __locked branch with the lock
# held. `lockf -t 0` returns 75 on contention — treat that as "someone else
# is reconciling" and exit 0 cleanly.
if [[ "${1:-}" != "__locked" ]]; then
  rc=0
  lockf -k -t 0 "$RECONCILE_LOCK" "$0" __locked 2>/dev/null || rc=$?
  if [[ $rc -eq 75 ]]; then
    exit 0
  fi
  exit $rc
fi

# ============================================================================
# Locked section — only one process runs the body below at a time.
# ============================================================================

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

reg=$(read_registry)

# Pick out closed-pending-reconciliation session IDs. Use jq's -r output so
# Bash 3.2 `for sid in $pending_sids` loops correctly (no arrays needed).
pending_sids=$(echo "$reg" | jq -r '
  .sessions | to_entries[]
  | select(.value.status == "closed-pending-reconciliation")
  | .key
')

absorbed_count=0
absorbed_summary=""

if [[ -n "$pending_sids" ]]; then
  for sid in $pending_sids; do
    # Serialize the entry as a single-line JSON audit record.
    entry=$(echo "$reg" | jq -c --arg sid "$sid" --arg now "$NOW" '
      {
        reconciled_at: $now,
        session_id: $sid,
        pid: .sessions[$sid].pid,
        started: .sessions[$sid].started,
        last_heartbeat: .sessions[$sid].last_heartbeat,
        close_summary: (.sessions[$sid].close_summary // ""),
        touched_files: (.sessions[$sid].touched_files // []),
        structural_changes: (.sessions[$sid].structural_changes // false)
      }
    ')
    printf '%s\n' "$entry" >> "$RECONCILE_LOG"

    # Drop the entry from the registry.
    reg=$(echo "$reg" | jq --arg sid "$sid" 'del(.sessions[$sid])')

    absorbed_count=$((absorbed_count + 1))
    if [[ -z "$absorbed_summary" ]]; then
      absorbed_summary="${sid:0:8}"
    else
      absorbed_summary="$absorbed_summary,${sid:0:8}"
    fi
  done
fi

# Flip the top-level flag + timestamp regardless — clearing a stale true flag
# is harmless if no entries were absorbed this pass.
reg=$(echo "$reg" | jq --arg now "$NOW" '
  .pending_reconciliation = false
  | .last_reconciled = $now
')

write_registry "$reg"

# Emit a structured line to stderr for the session-deregister caller log.
# Silent when nothing happened — the stuck-entry case is what we care about.
if (( absorbed_count > 0 )); then
  echo "[reconcile] absorbed=${absorbed_count} sessions=[${absorbed_summary}] log=${RECONCILE_LOG}" >&2
fi

exit 0
