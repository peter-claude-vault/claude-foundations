#!/usr/bin/env bash
# post-tool-use.sh — verify vault writes carry required frontmatter.
# Block-and-log on contract violation (exit 2). Reads tool-call JSON on stdin.

set -euo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/manifest.sh"

if ! manifest_available; then
  exit 0
fi

payload="$(cat)"
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty')
target=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')

case "$tool" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

vault_root=$(manifest_get '.vault.root')
[[ -z "$vault_root" || -z "$target" ]] && exit 0
[[ "$target" == "$vault_root"* ]] || exit 0
[[ "$target" == *.md ]] || exit 0
[[ -f "$target" ]] || exit 0

# Require YAML frontmatter on any vault markdown write
if ! head -1 "$target" | grep -q '^---$'; then
  echo "contract violation: $target is missing YAML frontmatter" >&2
  exit 2
fi

exit 0
