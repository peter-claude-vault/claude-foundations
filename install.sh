#!/usr/bin/env bash
# install.sh — Claude Foundations Onboarding Engine installer.
#
# Installs skills, hooks, and manifest tooling into $HOME/.claude and merges
# the hook set into settings.json. Idempotent — re-running is safe.
#
# Default install:
#   ./install.sh
#
# Isolated test install (does not touch your real ~/.claude):
#   HOME=/tmp/fresh-claude ./install.sh
#   HOME=/tmp/fresh-claude claude
#
# Overriding HOME is the supported isolation mechanism. Claude Code resolves
# its configuration relative to $HOME/.claude, so a HOME override gives you a
# clean-room environment without symlinks or project-local hacks.

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required. Install with 'brew install jq' (macOS) or your package manager." >&2
  exit 2
fi

echo "[foundations] target: $CLAUDE_DIR"
mkdir -p "$CLAUDE_DIR/skills" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/manifest"

# Skills — replace in place so re-runs pick up updated SKILL.md files
rm -rf "$CLAUDE_DIR/skills/onboard-foundation" \
       "$CLAUDE_DIR/skills/onboard-behavioral" \
       "$CLAUDE_DIR/skills/librarian"
cp -R "$SRC_DIR/onboarder/foundation"  "$CLAUDE_DIR/skills/onboard-foundation"
cp -R "$SRC_DIR/onboarder/behavioral"  "$CLAUDE_DIR/skills/onboard-behavioral"
cp -R "$SRC_DIR/skills/librarian"      "$CLAUDE_DIR/skills/librarian"
chmod +x "$CLAUDE_DIR/skills/librarian/scan.sh" 2>/dev/null || true

# Hooks
cp -R "$SRC_DIR/hooks/"* "$CLAUDE_DIR/hooks/"
chmod +x "$CLAUDE_DIR/hooks/"*.sh

# Manifest tooling
cp "$SRC_DIR/manifest/schema.json"          "$CLAUDE_DIR/manifest/schema.json"
cp "$SRC_DIR/manifest/validate-manifest.sh" "$CLAUDE_DIR/manifest/validate-manifest.sh"
chmod +x "$CLAUDE_DIR/manifest/validate-manifest.sh"

# settings.json merge — Claude Code hook schema:
#   - Tool events (PreToolUse, PostToolUse, PreCompact): matcher + hooks[]
#   - Lifecycle events (SessionStart, UserPromptSubmit, Stop): hooks[]
settings="$CLAUDE_DIR/settings.json"
[[ -f "$settings" ]] || echo '{}' > "$settings"

tmp=$(mktemp)
jq --arg d "$CLAUDE_DIR" '
  .hooks = ((.hooks // {}) * {
    PreToolUse: [{
      matcher: "Bash|Edit|Write|MultiEdit|NotebookEdit",
      hooks: [{type: "command", command: ($d + "/hooks/pre-tool-use.sh")}]
    }],
    PostToolUse: [{
      matcher: "Bash|Edit|Write|MultiEdit|NotebookEdit",
      hooks: [{type: "command", command: ($d + "/hooks/post-tool-use.sh")}]
    }],
    SessionStart: [{
      hooks: [{type: "command", command: ($d + "/hooks/session-start.sh")}]
    }],
    UserPromptSubmit: [{
      hooks: [{type: "command", command: ($d + "/hooks/user-prompt-submit.sh")}]
    }],
    PreCompact: [{
      matcher: "auto|manual",
      hooks: [{type: "command", command: ($d + "/hooks/pre-compact.sh")}]
    }],
    Stop: [{
      hooks: [{type: "command", command: ($d + "/hooks/stop.sh")}]
    }]
  })
' "$settings" > "$tmp" && mv "$tmp" "$settings"

cat <<EOF

[foundations] install complete.

Next steps:
  1. Launch Claude Code and run: /onboard-foundation
     (produces $CLAUDE_DIR/user-manifest.json)
  2. Then run: /librarian scan
     (bootstraps from the manifest)

Isolated test install (no touch to your real ~/.claude):
  HOME=/tmp/fresh-claude ./install.sh
  HOME=/tmp/fresh-claude claude
EOF
