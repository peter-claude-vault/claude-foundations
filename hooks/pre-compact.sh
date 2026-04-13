#!/usr/bin/env bash
# pre-compact.sh — write a checkpoint the model can re-read post-compaction.

set -euo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/manifest.sh"

state_dir="$CLAUDE_DIR/hooks/state"
mkdir -p "$state_dir"
checkpoint="$state_dir/checkpoint.md"

{
  echo "# Checkpoint"
  echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if manifest_available; then
    echo "role: $(manifest_get '.identity.role')"
    echo "vault: $(manifest_get '.vault.root')"
  fi
} > "$checkpoint"
exit 0
