# plugins/

Bundled Claude Code plugins. The installer copies anything under this directory into `~/.claude/plugins/` at install time.

## What's bundled

| Plugin | Purpose |
|---|---|
| `claude-mem/` | Cross-session memory hooks. The `SessionEnd` hook consolidates conversation history into structured memory under `~/.claude/projects/<slug>/memory/`. Optional but recommended. |

## Installation

Plugins ship to `~/.claude/plugins/` along with the rest of the foundation. They're hands-off after install — Claude Code discovers them via the standard plugin loader.

If the foundation install runs against a `~/.claude/` that already has a plugin tree, the installer is conservative: existing plugin files are preserved. The bundled plugin is treated as a default for fresh installs, not as a forced upgrade.

## Disabling a bundled plugin

Set `CLAUDE_MEM_DISABLE_OK=1` in your environment to suppress the claude-mem `SessionEnd` hook for the current session. The hook itself is also under the protected-`SessionEnd` list `pre-write-guard.sh` reads from your manifest, so removing it from `settings.json` requires the per-hook escape `HOOK_GUARD_DISABLE_OK=memory-consolidation-check.sh`. The protection exists because losing memory-consolidation silently means losing state — make removal an explicit decision.
