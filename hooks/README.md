# Generic Hook Set

Every hook resolves its configuration from `user-manifest.json` at runtime. No hardcoded paths.

## Convention

```
CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
MANIFEST="${CLAUDE_MANIFEST:-$CLAUDE_DIR/user-manifest.json}"
```

All hooks source `lib/manifest.sh`, which provides `manifest_available`, `manifest_get '<jq expr>'`, and `manifest_warn`.

## Hooks

| Hook | Trigger | Manifest fields read |
|------|---------|---------------------|
| `pre-tool-use.sh` | Before tool calls | `vault.root`, `vault.protected_paths[]` |
| `post-tool-use.sh` | After tool calls | `vault.root` — enforces frontmatter on vault markdown writes |
| `session-start.sh` | Session start | `identity.role`, `vault.root`, `system.phases_completed` |
| `user-prompt-submit.sh` | Every user prompt | `behavioral.context_pressure_threshold` |
| `pre-compact.sh` | Before compaction | `identity.role`, `vault.root` — writes `$CLAUDE_DIR/hooks/state/checkpoint.md` |
| `stop.sh` | Session end | none — reserved for future cleanup |

## Graceful degradation

If the manifest is missing or malformed, every hook logs a warning to stderr and exits 0. A missing manifest never blocks a session.

## Customization

Override the manifest location with `CLAUDE_MANIFEST=/path/to/manifest.json`. Override the Claude dir with `CLAUDE_HOME=/path/to/dir`. Useful for clean-machine testing and multi-profile setups.
