#!/bin/bash
# Hook: SessionStart — Register this session in the coordination registry.
# Injects peer awareness on startup/resume. Restores checkpoint after compaction.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh"

STATE_DIR="${HOOKS_STATE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/state}"
CHECKPOINT_FILE="$STATE_DIR/checkpoint.md"
MANIFEST_FILE="$VAULT_ROOT/Logs/librarian-manifest.json"

# Parse stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')

if [[ -z "$SESSION_ID" ]]; then
  exit 0
fi

# Clear warning flag on fresh session start
if [[ "$SOURCE" == "startup" ]]; then
  rm -f "$STATE_DIR/last-warning-pct"

  # Morning brief injection — first startup of the day only
  MORNING_BRIEF_FILE="$STATE_DIR/morning-brief.md"
  if [[ -f "$MORNING_BRIEF_FILE" ]]; then
    brief_date=$(head -5 "$MORNING_BRIEF_FILE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)
    today=$(date +%Y-%m-%d)
    yesterday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d 2>/dev/null || true)
    if [[ "$brief_date" == "$today" ]] || [[ "$brief_date" == "$yesterday" ]]; then
      MORNING_BRIEF_SUMMARY=$(head -10 "$MORNING_BRIEF_FILE" | tail -8)
      mv "$MORNING_BRIEF_FILE" "$STATE_DIR/morning-brief-${today}-delivered.md"
    fi
  fi
fi

# Register under lock
export MSC_SESSION_ID="$SESSION_ID"
export MSC_PID="$PPID"
reg=$(lockf -k "$REGISTRY_LOCK" "$SCRIPT_DIR/lib/registry-op.sh" register)

# Build context
context=""

# Morning brief (set during startup block above)
if [[ -n "${MORNING_BRIEF_SUMMARY:-}" ]]; then
  context="Morning brief available. Summary:

${MORNING_BRIEF_SUMMARY}

Full brief: ~/.claude/hooks/state/morning-brief-$(date +%Y-%m-%d)-delivered.md"
fi

# --- Compact: restore checkpoint + manifest state ---
if [[ "$SOURCE" == "compact" ]]; then
  if [[ -f "$CHECKPOINT_FILE" ]] && [[ -s "$CHECKPOINT_FILE" ]]; then
    checkpoint_content=$(cat "$CHECKPOINT_FILE")
    context="POST-COMPACTION CHECKPOINT RESTORE:

${checkpoint_content}"

    # Archive checkpoint (don't delete — useful for debugging)
    ts=$(date +"%Y%m%d-%H%M%S")
    mv "$CHECKPOINT_FILE" "${STATE_DIR}/checkpoint-${ts}.md"
  fi

  # Re-inject librarian manifest state (pending_issues + scan_state only)
  if [[ -f "$MANIFEST_FILE" ]]; then
    manifest_state=$(jq '{pending_issues: .pending_issues, scan_state: .scan_state}' "$MANIFEST_FILE" 2>/dev/null || echo "")
    if [[ -n "$manifest_state" ]] && [[ "$manifest_state" != "{}" ]]; then
      if [[ -n "$context" ]]; then
        context="$context

"
      fi
      context="${context}LIBRARIAN MANIFEST STATE:
${manifest_state}"
    fi
  fi
fi

# Pending reconciliation
pending_info=$(get_pending_info "$reg" "$SESSION_ID")
if [[ -n "$pending_info" ]]; then
  if [[ -n "$context" ]]; then
    context="$context

"
  fi
  context="${context}${pending_info}
Run \`/librarian full --fix\` before starting work."
fi

# Peer summary
peer_summary=$(get_peer_summary "$reg" "$SESSION_ID")
if [[ -n "$peer_summary" ]]; then
  if [[ -n "$context" ]]; then
    context="$context

"
  fi
  context="${context}${peer_summary}
File coordination is active."
fi

# Output only if there's something to say
if [[ -n "$context" ]]; then
  format_output "SessionStart" "$context"
fi

exit 0
