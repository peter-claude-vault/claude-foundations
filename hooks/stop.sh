#!/usr/bin/env bash
# stop.sh — session-end cleanup. Graceful on missing manifest.

set -euo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/manifest.sh"
exit 0
