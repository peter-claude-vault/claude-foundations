#!/usr/bin/env bash
# hooks/lib/manifest.sh — shared manifest resolution + lookup helpers.
# Source this from every hook. Every function is tolerant of missing/malformed
# manifests: on failure it prints a warning to stderr and returns empty.

CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
MANIFEST="${CLAUDE_MANIFEST:-$CLAUDE_DIR/user-manifest.json}"

manifest_available() {
  [[ -f "$MANIFEST" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e . "$MANIFEST" >/dev/null 2>&1 || return 1
  return 0
}

manifest_get() {
  # $1 = jq expression, defaults to "empty" on failure
  manifest_available || { echo ""; return 0; }
  jq -r "$1 // empty" "$MANIFEST" 2>/dev/null || echo ""
}

manifest_warn() {
  printf '[foundations hook] %s\n' "$*" >&2
}
