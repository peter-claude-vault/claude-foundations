# Discovery Engine — `/onboard-foundation` Part A

The discovery engine runs before any interview question. It scans the user's environment for signals that pre-populate manifest fields, reducing the interview burden. It is **read-only** — no file is modified, created, or deleted during discovery.

## Environment convention

```
CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
```

All discovery paths resolve relative to `$CLAUDE_DIR` or standard user-home locations. Discovery respects `CLAUDE_HOME` for clean-machine testing.

## Scan targets

| # | Source | Confidence | Populates |
|---|--------|------------|-----------|
| 1 | `$CLAUDE_DIR/` exists | high | `system.existing_setup = true` |
| 2 | `$CLAUDE_DIR/settings.json` → `mcpServers` keys | high | `integrations.active[].channel` (one entry per MCP server) |
| 3 | `$CLAUDE_DIR/settings.json` → `hooks` block | medium | `system.existing_setup = true`; no manifest fields overwritten |
| 4 | `$CLAUDE_DIR/settings.json` → `permissions` | medium | `behavioral.autonomy` hint only (not written in Phase 1; saved in `discovery_context` for Phase 2) |
| 5 | `$CLAUDE_DIR/skills/*/SKILL.md` | high | `system.existing_skills[]` = directory names |
| 6 | `~/Documents/*/.obsidian/` (first match wins, multiple matches flagged as conflict) | high | `vault.root` (candidate), `vault.organizational_method` hint via folder-name heuristics |
| 7 | `~/.gitconfig` → `user.name`, `user.email` | high | `identity.name`, `identity.email` |
| 8 | `$HOME/.zshrc` or `$HOME/.bashrc` — presence of `brew`, `nvm`, `pyenv`, `conda`, `rustup`, `go` | medium | `tools.development_environment[]` |
| 9 | MCP server names matching known calendar/messaging/email providers | medium | `tools.calendar`, `tools.messaging`, `tools.email` — each one presented to the user for confirmation, never auto-saved |

## Confidence levels

- **high** — the evidence is unambiguous (e.g., `.obsidian/` directory exists, `.gitconfig` has `user.email`). The Onboarder marks the field discovery-populated and asks only a confirmation question (`"Is this right?"`).
- **medium** — the evidence is suggestive but not conclusive. The Onboarder asks a normal question but pre-fills the default answer. User can accept with one keystroke or override.
- **low / missing** — no signal. The Onboarder asks the full question.

## Conflict handling

If discovery finds multiple vault candidates, it flags the conflict in `discovery_context.conflicts[]` and lets the user choose during Block 3. It does NOT pick one silently.

If `~/.gitconfig` has multiple identities (e.g., work and personal includes), discovery picks the global one and notes the alternatives.

## discovery_context shape (internal, never persisted)

```json
{
  "claude_dir": "/Users/example/.claude",
  "existing_setup": true,
  "existing_skills": ["librarian", "digest-run"],
  "vault_candidates": [
    { "path": "/Users/example/Documents/Vault", "file_count": 342, "organizational_hint": "custom" }
  ],
  "git_identity": { "name": "Example User", "email": "example@example.com" },
  "mcp_servers": ["google_calendar", "gmail", "slack"],
  "dev_env": ["homebrew", "node", "python"],
  "conflicts": [],
  "confidence": {
    "identity.name": "high",
    "vault.root": "high",
    "tools.calendar": "medium"
  }
}
```

## What discovery does NOT do

- Never reads file contents inside an Obsidian vault. It only checks for `.obsidian/` and counts files.
- Never reads chat logs, emails, calendars, or any authenticated service data.
- Never makes network calls. Discovery is local-only.
- Never writes anything. The only persistent artifact is the final manifest written by Part C.
- Never calls `grep`/`find` on `$HOME` without scoping — scans are bounded to known locations to avoid accidental reads of sensitive directories.
