#!/usr/bin/env bash
# user-prompt-submit.sh — surface behavioral context pressure reminders.

set -euo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/manifest.sh"

manifest_available || exit 0

threshold=$(manifest_get '.behavioral.context_pressure_threshold')
[[ -z "$threshold" || "$threshold" == "null" ]] && exit 0

exit 0
