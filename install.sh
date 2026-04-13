#!/usr/bin/env bash
# install.sh — Claude Foundations Onboarding Engine installer.
# Copies skills, hooks, and manifest tooling into $CLAUDE_HOME (default ~/.claude)
# and wires the hook set into settings.json via a jq-merged update.

set -euo pipefail

CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required. Install with 'brew install jq' (macOS) or your package manager." >&2
  exit 2
fi

echo "[foundations] target: $CLAUDE_DIR"
mkdir -p "$CLAUDE_DIR/skills" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/manifest"

# Skills
cp -R "$SRC_DIR/onboarder/foundation" "$CLAUDE_DIR/skills/onboard-foundation"
cp -R "$SRC_DIR/skills/librarian"     "$CLAUDE_DIR/skills/librarian"

# Hooks
cp -R "$SRC_DIR/hooks/"* "$CLAUDE_DIR/hooks/"
chmod +x "$CLAUDE_DIR/hooks/"*.sh

# Manifest tooling
cp "$SRC_DIR/manifest/schema.json"         "$CLAUDE_DIR/manifest/schema.json"
cp "$SRC_DIR/manifest/validate-manifest.sh" "$CLAUDE_DIR/manifest/validate-manifest.sh"
chmod +x "$CLAUDE_DIR/manifest/validate-manifest.sh"

# settings.json merge
settings="$CLAUDE_DIR/settings.json"
[[ -f "$settings" ]] || echo '{}' > "$settings"

tmp=$(mktemp)
jq --arg d "$CLAUDE_DIR" '
  .hooks = ((.hooks // {}) * {
    PreToolUse:       [{type:"command", command: ($d + "/hooks/pre-tool-use.sh")}],
    PostToolUse:      [{type:"command", command: ($d + "/hooks/post-tool-use.sh")}],
    SessionStart:     [{type:"command", command: ($d + "/hooks/session-start.sh")}],
    UserPromptSubmit: [{type:"command", command: ($d + "/hooks/user-prompt-submit.sh")}],
    PreCompact:       [{type:"command", command: ($d + "/hooks/pre-compact.sh")}],
    Stop:             [{type:"command", command: ($d + "/hooks/stop.sh")}]
  })
' "$settings" > "$tmp" && mv "$tmp" "$settings"

cat <<EOF

[foundations] install complete.

Next steps:
  1. Run /onboard-foundation to create your first user-manifest.json
  2. Then run /librarian scan to bootstrap your vault

Customize with CLAUDE_HOME=<path> to install into a non-default location.
EOF
