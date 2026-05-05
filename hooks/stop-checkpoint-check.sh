#!/bin/bash
# Hook: Stop — Enforce checkpoint writing before session exit at high context.
# Exit 2 = force continuation. Exit 0 = allow stop.
set -euo pipefail

STATE_DIR="${HOOKS_STATE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/state}"
PRESSURE_FILE="$STATE_DIR/context-pressure.json"
CHECKPOINT_FILE="$STATE_DIR/checkpoint.md"
CLEARING_WINDOW_SEC=600

# Read context percentage
pct=0
if [[ -f "$PRESSURE_FILE" ]]; then
  pct=$(jq -r '.pct // 0' "$PRESSURE_FILE" 2>/dev/null || echo 0)
fi
pct_int=${pct%.*}

# Safety valve: >90% always allows stop (context too full to continue productively)
if (( pct_int > 90 )); then
  exit 0
fi

# Below 48%: allow (no R-26 enforcement band)
if (( pct_int < 48 )); then
  exit 0
fi

# Compute checkpoint freshness
ckpt_exists=false
ckpt_age=999999
if [[ -f "$CHECKPOINT_FILE" ]] && [[ -s "$CHECKPOINT_FILE" ]]; then
  ckpt_exists=true
  ckpt_mtime=$(stat -f %m "$CHECKPOINT_FILE" 2>/dev/null || stat -c %Y "$CHECKPOINT_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  ckpt_age=$(( now - ckpt_mtime ))
fi

# 48-80% band: R-26 mtime-freshness gate. Checkpoint must be < 10 min old.
if (( pct_int < 80 )); then
  if $ckpt_exists && (( ckpt_age < CLEARING_WINDOW_SEC )); then
    exit 0
  fi
  echo "Context at ${pct}%. Cannot stop — checkpoint stale (mtime age ${ckpt_age}s, limit ${CLEARING_WINDOW_SEC}s)." >&2
  echo "Invoke /session-checkpoint first to refresh $CHECKPOINT_FILE. After checkpoint is written, stop will be allowed. (R-26 48-80% band)" >&2
  exit 2
fi

# 80-90% band: checkpoint must at minimum exist (pre-existing rule, preserved)
if $ckpt_exists; then
  exit 0
fi

echo "Context at ${pct}%. You must save a checkpoint before stopping. Invoke /session-checkpoint to write $CHECKPOINT_FILE. (R-26 80-90% band)" >&2
exit 2
