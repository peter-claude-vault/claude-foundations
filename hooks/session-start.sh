#!/usr/bin/env bash
# session-start.sh — emit manifest-derived context at session start.

set -euo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/manifest.sh"

if ! manifest_available; then
  manifest_warn "no manifest — running without personalization"
  exit 0
fi

role=$(manifest_get '.identity.role')
vault=$(manifest_get '.vault.root')
phases=$(manifest_get '.system.phases_completed | join(",")')

cat <<EOF
[foundations] manifest loaded
  role:    ${role:-unset}
  vault:   ${vault:-none}
  phases:  ${phases:-none}
EOF
exit 0
