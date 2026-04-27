#!/bin/bash
# Multi-session coordination — locked registry operations.
# Called via: lockf -k "$REGISTRY_LOCK" ~/.claude/hooks/lib/registry-op.sh <operation>
# Data passed via MSC_* environment variables.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/registry.sh"

op="${1:-}"

case "$op" in
  register)
    # Env: MSC_SESSION_ID, MSC_PID
    ensure_coord_dir
    reg=$(read_registry)
    reg=$(echo "$reg" | clean_stale)
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    reg=$(echo "$reg" | jq \
      --arg sid "$MSC_SESSION_ID" \
      --argjson pid "${MSC_PID}" \
      --arg now "$now" \
      '.sessions[$sid] = {
        "pid": $pid,
        "started": $now,
        "last_heartbeat": $now,
        "status": "active",
        "touched_files": [],
        "structural_changes": false,
        "manifest_read_at": "",
        "close_summary": ""
      }')

    write_registry "$reg"
    echo "$reg"
    ;;

  update-files)
    # Env: MSC_SESSION_ID, MSC_FILE_PATH
    reg=$(read_registry)
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    reg=$(echo "$reg" | jq \
      --arg sid "$MSC_SESSION_ID" \
      --arg file "$MSC_FILE_PATH" \
      --arg now "$now" \
      --argjson cap "$TOUCHED_FILES_CAP" \
      'if .sessions[$sid] then
        .sessions[$sid].last_heartbeat = $now |
        .sessions[$sid].touched_files = (
          (.sessions[$sid].touched_files + [$file]) | unique |
          if length > $cap then .[-$cap:] else . end
        )
      else . end')

    write_registry "$reg"
    echo "$reg"
    ;;

  deregister)
    # Env: MSC_SESSION_ID
    reg=$(read_registry)
    reg=$(echo "$reg" | clean_stale)

    own_status=$(echo "$reg" | jq -r --arg sid "$MSC_SESSION_ID" '.sessions[$sid].status // "absent"')
    if [[ "$own_status" == "absent" ]]; then
      # Still write back cleaned registry (stale entries may have been removed)
      write_registry "$reg"
      exit 0
    fi

    active_peers=$(echo "$reg" | jq --arg sid "$MSC_SESSION_ID" \
      '[.sessions | to_entries[] | select(.key != $sid) | select(.value.status == "active")] | length')
    pending_peers=$(echo "$reg" | jq --arg sid "$MSC_SESSION_ID" \
      '[.sessions | to_entries[] | select(.key != $sid) | select(.value.status == "closed-pending-reconciliation")] | length')
    own_files=$(echo "$reg" | jq --arg sid "$MSC_SESSION_ID" \
      '(.sessions[$sid].touched_files // []) | length')

    if (( active_peers > 0 )); then
      # Others still active — mark pending
      reg=$(echo "$reg" | jq --arg sid "$MSC_SESSION_ID" \
        '.sessions[$sid].status = "closed-pending-reconciliation"')
    elif (( pending_peers > 0 && own_files > 0 )); then
      # All others pending, we did work — flag reconciliation
      reg=$(echo "$reg" | jq --arg sid "$MSC_SESSION_ID" \
        '.sessions[$sid].status = "closed-pending-reconciliation" | .pending_reconciliation = true')
    else
      # Solo or no work — clean remove
      reg=$(echo "$reg" | jq --arg sid "$MSC_SESSION_ID" 'del(.sessions[$sid])')
      remaining=$(echo "$reg" | jq '.sessions | length')
      if (( remaining == 0 )); then
        reg=$(echo "$reg" | jq '.pending_reconciliation = false')
      fi
    fi

    write_registry "$reg"
    ;;

  read)
    read_registry
    ;;

  *)
    echo "Unknown operation: $op" >&2
    exit 1
    ;;
esac
