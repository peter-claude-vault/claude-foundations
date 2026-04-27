#!/bin/bash
# Hook: UserPromptSubmit — Inject context pressure warnings + peer awareness.
# Silent (no output) when solo and context is low.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh"

STATE_DIR="$HOME/.claude/hooks/state"
PRESSURE_FILE="$STATE_DIR/context-pressure.json"
CHECKPOINT_FILE="$STATE_DIR/checkpoint.md"

# --- Context pressure enforcement (R-26) ---
# Re-firing mandates with mtime-based clearing condition.
# Clearing window: checkpoint.md mtime must be < 600s (10 min) old.
# The one-shot last_warned flag has been removed — mandates fire every
# UserPromptSubmit until the clearing condition is met.
CLEARING_WINDOW_SEC=600

pressure_context=""
if [[ -f "$PRESSURE_FILE" ]]; then
  pct=$(jq -r '.pct // 0' "$PRESSURE_FILE" 2>/dev/null || echo 0)
  pct_int=${pct%.*}

  # Compute checkpoint freshness (mtime age in seconds; large number if absent)
  if [[ -f "$CHECKPOINT_FILE" ]] && [[ -s "$CHECKPOINT_FILE" ]]; then
    ckpt_mtime=$(stat -f %m "$CHECKPOINT_FILE" 2>/dev/null || stat -c %Y "$CHECKPOINT_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    ckpt_age=$(( now - ckpt_mtime ))
  else
    ckpt_age=999999
  fi
  checkpoint_fresh=false
  if (( ckpt_age < CLEARING_WINDOW_SEC )); then
    checkpoint_fresh=true
  fi

  if (( pct_int >= 48 )); then
    if ! $checkpoint_fresh; then
      # 48% immediate-action mandate — re-fires every prompt until cleared
      pressure_context="CONTEXT PRESSURE ${pct}% — IMMEDIATE ACTION REQUIRED.
Before responding to the user's prompt, invoke /session-checkpoint.
Do not take any other tool action until checkpoint is written to ~/.claude/hooks/state/checkpoint.md.
This is a blocking mandate enforced by the Stop hook (R-26).
Clearing condition: checkpoint.md mtime < 10 min old."
    fi
  elif (( pct_int >= 45 )); then
    if ! $checkpoint_fresh; then
      # 45% at-next-break mandate — re-fires every prompt until cleared
      pressure_context="CONTEXT PRESSURE ${pct}%. At the next natural task boundary (current tool chain complete), invoke /session-checkpoint to write ~/.claude/hooks/state/checkpoint.md with the Session Continuity Block.
Do not begin new multi-step work until checkpoint is written.
Clearing condition: checkpoint.md mtime < 10 min old (R-26)."
    fi
  elif (( pct_int >= 35 )); then
    # 35% silent passive checkpoint — preserves prior behavior as PreCompact feed.
    # Only writes if no fresh checkpoint already exists (don't clobber manual ones).
    if ! $checkpoint_fresh; then
      cat > "$CHECKPOINT_FILE" <<CKPT 2>/dev/null || true
# Auto-checkpoint at ${pct}% context — $(date -Iseconds)
# Passive 35% silent capture — feeds PreCompact hook
CKPT
    fi
  fi
fi

# Parse stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
if [[ -z "$SESSION_ID" ]]; then
  # No session ID but we may still have pressure context
  if [[ -n "$pressure_context" ]]; then
    format_output "UserPromptSubmit" "$pressure_context"
  fi
  exit 0
fi

PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')

# Read registry under lock (2s timeout — skip on contention)
reg=$(lockf -k -t 2 "$REGISTRY_LOCK" cat "$REGISTRY_FILE" 2>/dev/null) || {
  # Registry unavailable — still emit pressure warnings
  if [[ -n "$pressure_context" ]]; then
    format_output "UserPromptSubmit" "$pressure_context"
  fi
  exit 0
}

# Fast path: only our own session → silent
peer_count=$(echo "$reg" | jq --arg sid "$SESSION_ID" \
  '[.sessions | to_entries[] | select(.key != $sid) | select(.value.status == "active" or .value.status == "closing" or .value.status == "closed-pending-reconciliation")] | length')
if (( peer_count == 0 )); then
  # No peers, but may still have pressure context
  if [[ -n "$pressure_context" ]]; then
    format_output "UserPromptSubmit" "$pressure_context"
  fi
  exit 0
fi

# Detect session-close in prompt for enhanced context
is_close=false
if echo "$PROMPT" | grep -qi 'session-close\|/librarian.*close'; then
  is_close=true
fi

context=""

# Pending reconciliation check
pending_info=$(get_pending_info "$reg" "$SESSION_ID")
if [[ -n "$pending_info" ]]; then
  context="$pending_info"
fi

# Peer summary
peer_summary=$(get_peer_summary "$reg" "$SESSION_ID")
if [[ -n "$peer_summary" ]]; then
  if [[ -n "$context" ]]; then
    context="$context

"
  fi
  context="${context}${peer_summary}"
fi

# File overlaps
overlaps=$(get_file_overlaps "$reg" "$SESSION_ID")
if [[ -n "$overlaps" ]]; then
  overlap_list=$(echo "$overlaps" | head -10 | tr '\n' ', ' | sed 's/,$//')
  if [[ -n "$context" ]]; then
    context="$context

"
  fi
  context="${context}Warning: Overlapping files with peer sessions: ${overlap_list}. Re-read before editing."
fi

# Enhanced context for session-close
if $is_close; then
  # Full peer detail for close coordination
  close_detail=$(echo "$reg" | jq -r --arg sid "$SESSION_ID" '
    .sessions | to_entries[] | select(.key != $sid) |
    "- \(.key[0:8])... status=\(.value.status) files=\(.value.touched_files | length) close_summary=\"\(.value.close_summary // "")\""
  ')

  active_count=$(echo "$reg" | jq --arg sid "$SESSION_ID" \
    '[.sessions | to_entries[] | select(.key != $sid) | select(.value.status == "active")] | length')
  pending_count=$(echo "$reg" | jq --arg sid "$SESSION_ID" \
    '[.sessions | to_entries[] | select(.key != $sid) | select(.value.status == "closed-pending-reconciliation")] | length')

  # Recommend close mode
  if (( active_count > 0 )); then
    mode="scoped (other sessions still active)"
  elif (( pending_count > 0 )); then
    mode="reconciler (last active session, pending peers need reconciliation)"
  else
    mode="solo (no coordination needed)"
  fi

  context="${context}

SESSION CLOSE COORDINATION:
Peer sessions:
${close_detail}
Recommended close mode: ${mode}
pending_reconciliation: $(echo "$reg" | jq -r '.pending_reconciliation')"
fi

# Merge pressure context with peer context
if [[ -n "$pressure_context" ]]; then
  if [[ -n "$context" ]]; then
    context="${pressure_context}

${context}"
  else
    context="$pressure_context"
  fi
fi

if [[ -n "$context" ]]; then
  format_output "UserPromptSubmit" "$context"
fi

exit 0
