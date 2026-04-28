#!/bin/bash
# Hook: PostToolUse (Edit|Write) — Track vault file writes in session registry.
# Overlap warnings surface via prompt-context.sh on the next UserPromptSubmit.
# (PostToolUse additionalContext non-functional in current Claude Code; the
# registry feeds prompt-context.sh which emits via UserPromptSubmit instead.)
set -euo pipefail

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh"

# Parse stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Extract file path from tool_input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only track vault files (vault_relative returns empty for non-vault paths or
# when VAULT_ROOT is unset, e.g. fresh install with no manifest).
REL_PATH=$(vault_relative "$FILE_PATH")
if [ -z "$REL_PATH" ]; then
  exit 0
fi

# Update registry under lock (adds to touched_files, updates heartbeat).
export MSC_SESSION_ID="$SESSION_ID"
export MSC_FILE_PATH="$REL_PATH"
lockf -k "$REGISTRY_LOCK" "$SCRIPT_DIR/lib/registry-op.sh" update-files > /dev/null

exit 0
