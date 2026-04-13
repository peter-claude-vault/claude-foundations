#!/usr/bin/env bash
# pre-tool-use.sh — block writes to protected paths resolved from the manifest.
# Reads JSON tool-call payload on stdin; exits 0 to allow, 2 to block.

set -euo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/manifest.sh"

if ! manifest_available; then
  manifest_warn "manifest not found at $MANIFEST — skipping pre-tool-use enforcement"
  exit 0
fi

payload="$(cat)"
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty')
target=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.path // empty')

# Only enforce for write-capable tools
case "$tool" in
  Write|Edit|NotebookEdit|MultiEdit) ;;
  *) exit 0 ;;
esac

[[ -z "$target" ]] && exit 0

vault_root=$(manifest_get '.vault.root')
protected=$(manifest_get '.vault.protected_paths[]?')

# Manifest itself is always protected
if [[ "$target" == "$MANIFEST" ]]; then
  echo "blocked: $MANIFEST is owned by the Librarian; do not edit directly" >&2
  exit 2
fi

if [[ -n "$vault_root" ]]; then
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    full="$vault_root/${p#/}"
    if [[ "$target" == "$full"* ]]; then
      echo "blocked: $target is inside protected path $full" >&2
      exit 2
    fi
  done <<< "$protected"
fi

exit 0
