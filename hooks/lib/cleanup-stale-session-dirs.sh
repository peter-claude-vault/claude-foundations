#!/bin/bash
# cleanup-stale-session-dirs.sh — Plan 84 SP01 T-4 cleanup TTL.
#
# Removes orphan per-session checkpoint directories under
# $STATE_DIR/sessions/<sid>/ once the session is no longer in the registry
# AND the dir's mtime has aged past CHECKPOINT_CLEANUP_TTL_SECS.
#
# Coupled to (consumes, does not modify) Plan 42 session registry:
#   - Active sessions: NEVER deleted, regardless of mtime.
#   - closed-pending-reconciliation: NEVER deleted (reconciler hasn't absorbed yet).
#   - Not in registry + mtime < TTL: preserved as defense-in-depth buffer
#     against transient registry races (Plan 42 STALE_THRESHOLD is 30 min;
#     default TTL of 3600s gives 2x margin).
#   - Not in registry + mtime >= TTL: deleted (rm -rf wholesale).
#
# Reconciler already absorbed audit metadata (close_summary, touched_files,
# structural_changes) into reconcile-log.ndjson before the dir becomes
# eligible. Checkpoint-*.md archives inside the dir are mechanical
# resume-state for in-flight sessions — stale after the session closes.
#
# Honors `HOOKS_STATE_OVERRIDE` + `VAULT_ROOT` for test isolation
# (Plan 84 SP01 T-5a / T-5 convention).
#
# Triggered from session-deregister.sh tail (Plan 84 SP01 T-4) via
# `nohup ... &` after the existing reconciler fire. Lock-guarded so
# concurrent SessionEnd events don't double-sweep.
#
# Exit codes:
#   0 — ran to completion OR lock was busy (another process is cleaning).
#   non-zero — programmer error (jq missing, registry unreadable, etc.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/registry.sh"

STATE_DIR="${HOOKS_STATE_OVERRIDE:-$HOOKS_STATE}"
SESSIONS_DIR="$STATE_DIR/sessions"
CLEANUP_LOCK="$COORD_DIR/cleanup.lock"
TTL_SECS="${CHECKPOINT_CLEANUP_TTL_SECS:-3600}"

# Nothing to do if no per-session dirs exist
if [[ ! -d "$SESSIONS_DIR" ]]; then
  exit 0
fi

# Leader-election re-exec under non-blocking lock. lockf -t 0 returns 75 on
# contention — treat as "someone else is cleaning" and exit 0.
if [[ "${1:-}" != "__locked" ]]; then
  ensure_coord_dir
  rc=0
  lockf -k -t 0 "$CLEANUP_LOCK" "$0" __locked || rc=$?
  if [[ $rc -eq 75 ]]; then
    exit 0
  fi
  exit $rc
fi

# ============================================================================
# Locked section — only one process runs the body below at a time.
# ============================================================================

# Build set of SIDs that must NEVER be deleted (active + pending-reconciliation).
protected_sids=""
if [[ -f "$REGISTRY_FILE" ]]; then
  protected_sids=$(jq -r '
    .sessions | to_entries[]
    | select(.value.status == "active" or .value.status == "closed-pending-reconciliation")
    | .key
  ' "$REGISTRY_FILE" 2>/dev/null || true)
fi

NOW=$(date +%s)
deleted_count=0
preserved_protected=0
preserved_fresh=0
deleted_summary=""

for dir in "$SESSIONS_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  sid=$(basename "$dir")

  # Protected: SID still in registry
  if [[ -n "$protected_sids" ]] && grep -qxF "$sid" <<< "$protected_sids"; then
    preserved_protected=$((preserved_protected + 1))
    continue
  fi

  # Defense-in-depth: mtime buffer against transient registry races.
  # macOS stat -f %m; Linux stat -c %Y. Fall back to 0 (= treat as ancient).
  mtime=$(stat -f %m "$dir" 2>/dev/null || stat -c %Y "$dir" 2>/dev/null || echo 0)
  age=$((NOW - mtime))
  if (( age < TTL_SECS )); then
    preserved_fresh=$((preserved_fresh + 1))
    continue
  fi

  # Orphan + aged out → delete.
  if rm -rf "$dir" 2>/dev/null; then
    deleted_count=$((deleted_count + 1))
    if [[ -z "$deleted_summary" ]]; then
      deleted_summary="${sid:0:8}"
    else
      deleted_summary="$deleted_summary,${sid:0:8}"
    fi
  fi
done

# Silent when nothing happened — stuck-orphan deletions are what we care about.
if (( deleted_count > 0 )); then
  echo "[cleanup] deleted=${deleted_count} sessions=[${deleted_summary}] preserved_protected=${preserved_protected} preserved_fresh=${preserved_fresh}" >&2
fi

exit 0
