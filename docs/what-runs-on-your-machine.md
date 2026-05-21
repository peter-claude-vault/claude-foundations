# What runs on your machine

A complete inventory of what claude-stem installs, what runs in-process inside Claude Code, what runs unattended on a schedule, and what calls the network. Each entry includes how to disable it.

## Filesystem footprint

After `./install.sh --apply` and a full `/onboard` + `/adopt`, the system has written to:

| Path | Contents | Size (typical) |
|---|---|---|
| `~/.claude/` (your Claude Code config root) | Hooks, skills, schemas, templates, onboarding scripts, foundation manifest, install logs. | ~5 MB |
| `~/.claude/user-manifest.json` | Your interview answers, structured. | ~10 KB |
| `~/.claude/orchestration.json` | Scheduled-job definitions. | ~2 KB |
| `~/.claude/Library/LaunchAgents.staging/` | Staged but not-yet-active scheduled-job descriptors. | ~5 KB |
| `~/Library/LaunchAgents/com.claude-stem.*.plist` | Active scheduled jobs (only after you run `claude system enable-daemon`). | ~5 KB per job |
| `<vault_root>/` (path you chose during `/onboard`) | Vault skeleton: `Inbox/`, `Logs/`, `.coordination/`, `Plans` symlink, `CLAUDE.md`, `System Backlog.md`. | ~50 KB |
| `~/.claude-plans/` | Plan tracking directory (created if missing). | <1 KB initially |

The installer writes a SHA-256 fingerprint of every shipped file to `~/.claude/governance/foundation-manifest.json`. Uninstall removes only files whose live SHA-256 still matches. Anything you've edited (your `CLAUDE.md`, your `MEMORY.md`, your manifest) survives the uninstall.

## Hooks (in-process inside Claude Code)

Hooks fire only when you have an active Claude Code session. They do not run when Claude Code is closed.

**Default-on:**

| Hook | Event | What it does | How to disable |
|---|---|---|---|
| `pre-write-guard.sh` | PreToolUse[Edit\|Write] | Evaluates ~14 policy rules; can deny a write. Plain-English rule list at [`hooks/RULES.md`](../hooks/RULES.md). | Remove the entry from `~/.claude/settings.json` PreToolUse array. |
| `track-vault-write.sh` | PostToolUse[Edit\|Write] | Updates a multi-session registry. No external effect. | Remove from settings.json. |
| `post-write-verify.sh` | PostToolUse[Edit\|Write] | Validates frontmatter against `vault-schema.json`. Read-only on disk. | Remove from settings.json. |
| `prompt-context.sh` | UserPromptSubmit | Surfaces context-pressure mandates and multi-session overlap warnings. | Remove from settings.json. |
| `session-register.sh` | SessionStart | Writes a JSON record to a multi-session registry. | Remove from settings.json. |
| `cron-health-banner.sh` | SessionStart | Prints a one-line cron-job health summary (skipped if no jobs are active). | Remove from settings.json. |
| `stop-checkpoint-check.sh` | Stop | Blocks `Stop` if context pressure is high and no recent checkpoint exists. | Remove from settings.json. |
| `stop-drift-scan.sh` | Stop | Surfaces touched-file drift advisories. Read-only on disk. | Remove from settings.json. |
| `pre-compact-checkpoint.sh` | PreCompact | Snapshots session state before context compaction. | Remove from settings.json. |
| `session-deregister.sh` | SessionEnd | Removes the session-registry entry. | Remove from settings.json. |
| `worker-statusline.sh` | statusLine | Renders the bottom-of-terminal status line. | Remove from settings.json. |

**Conditional (off by default; opt-in via the manifest):**

| Hook fragment | Manifest flag | When it runs | What it does |
|---|---|---|---|
| `auto-commit.json` | `hooks.auto_commit.enabled` | SessionEnd | Auto-commits changes to your `~/.claude/` and/or vault git repos. Off unless you opted in. |
| `memory-consolidation.json` | `hooks.memory_consolidation.enabled` | SessionEnd | Triggers the bundled `claude-mem` plugin to consolidate session memory. |
| `tasks-md-autosync.json` | `hooks.tasks_autosync.enabled` | PostToolUse[Edit\|Write] | Auto-updates plan `tasks.md` files when their state markers change. |
| `multi-session.json` | `hooks.multi_session.enabled` | SessionEnd | Reconciles state when concurrent Claude Code sessions touched the same files. |

**Opt-in advanced (off by default; you wire it manually):**

| Hook | Event | Why you'd add it |
|---|---|---|
| `session-start-canary.sh` | SessionStart | Detects unexpected resurrection of a path you declared dead (e.g. a deprecated plans directory after a rename). Useful only if you have a known dead path to monitor. |

To turn off any default-on hook: edit `~/.claude/settings.json` and remove the entry from the relevant event array. The system never re-adds entries on subsequent installs.

## Skills (only when you invoke them)

Skills are slash commands. They run only when you type the command in Claude Code. None of them run on a schedule unless you've activated their cron variant.

| Skill | Triggered by | Network calls? | Writes outside vault? |
|---|---|---|---|
| `/onboard` | You typing it; or auto on SessionStart when no manifest exists | Optional (LLM extraction; auto-author surfaces). Set `--skip-auto-author` and `--llm-mode stub` for zero network. | `~/.claude/user-manifest.json`, `~/.claude/orchestration.json`, staged plists. |
| `/adopt` | You typing it; or auto on SessionStart when manifest declares fresh-vault | None. | `<vault_root>/...`, plus a one-field update in `user-manifest.json`. |
| `/librarian` | You typing it. | None. | Vault `Logs/` only. |
| `/architect` | You typing it. | Optional WebSearch / WebFetch in dimension 7; gracefully skipped on no network. | One report file per run in `<vault_root>/Logs/`. |
| `/inbox-processor` | You typing it; or via cron when activated. | None. | Routes files within the vault. |
| `/meeting-note-ingestor`, `/meeting-note-ingestor-granola` | Invoked by a connector pipeline. | Granola variant pulls from the Granola MCP server. | Vault meeting-note folders. |
| `/morning-brief` | You typing it. | None directly; reads vault content. | Vault `Logs/` (the brief). |
| `/backlog-{triage,research,hygiene}` | You typing it. | `/backlog-research` may use WebSearch / WebFetch. | Vault `System Backlog.md` and `Logs/backlog-progress/`. |
| `/seed-projects` | Invoked by `/adopt --retrofit-existing`. | None. | New project directories under your vault's projects folder. |
| `/connectors` | You typing it. | OAuth at first use for each MCP server you wire. | `~/.claude/user-manifest.json` (`connectors[]`), `~/.claude/connectors/manifest.json`. |

## Cron jobs (unattended; off by default)

The installer stages launchd plists but does not activate them. You activate one or more by running `claude system enable-daemon` after deciding what should run on a schedule. To list active jobs:

```bash
launchctl list | grep com.claude-stem
```

**Available scheduled jobs:**

| Job | Schedule (default) | What it does | Network |
|---|---|---|---|
| `librarian-cron.sh` | Daily 06:00 weekdays | Runs the librarian's integrity sweep, refreshes the vault manifest. | None. |
| `architect-cron.sh` | Weekly Monday 06:00 | Runs `/architect`, writes a recommendations report. | Optional WebSearch / WebFetch. |
| `digest-run.sh` | Configurable (default daily) | Pulls from configured connectors, processes meeting notes, etc. | Yes, via the connector wizards you've enabled. |
| `chat-scrape.sh` | Configurable | Scrapes connected chat sources (Teams, Google Chat) into the vault. | Yes, browser automation. |
| `calendar-sync.sh` | Every 10 min | Outlook → Google Calendar sync via EventKit (if wired). | Yes. |
| `meeting-processor.sh` | Daily | Processes Granola meetings end-to-end. | Yes, via Granola MCP. |
| `connector-runtime-cron.sh` | Per-connector | Generic runner for any connector pipeline. | Yes, per pipeline. |

**To deactivate any job:**

```bash
claude system disable-daemon <job-name>
# Or, directly:
launchctl bootout gui/$UID/com.claude-stem.<job-name>
rm ~/Library/LaunchAgents/com.claude-stem.<job-name>.plist
```

**To see what a job is doing:**

```bash
tail -f ~/.claude/logs/<job-name>-$(date +%Y-%m-%d).log
```

Every cron job goes through a wrapper in `orchestrator/cron-wrappers/` that adds: idle-watchdog kill (default 180s of no log output), concurrency lock, cold-wake warm-up probe, dated-log convention. No plist invokes a skill directly.

## External network calls

**Off by default:**
- Anthropic Messages API. Called by `/onboard` extraction (when `--llm-mode live` or `auto` with `ANTHROPIC_API_KEY` set), Section F auto-authoring, `/architect` external-research dimension, `/backlog-research` ideation, the LLM stages of the infer-vault chain.
- Voyage AI embeddings API. Called by the `cluster` stage of the infer-vault chain when `VOYAGE_API_KEY` is set.
- WebSearch / WebFetch. Called by `/architect` dimension 7 and by `/backlog-research`. Both use try/skip — failures don't cascade.
- Connector pulls. Granola, Calendar, Gmail, etc. — only when you've wired them through `/connectors`.

**Always off until you wire them:**
- OAuth for each MCP server. The `/connectors` wizard prompts at first use; you control the auth flow.

**No telemetry.** This system makes no calls to first-party servers belonging to the maintainer. The repo author runs no analytics service.

## Plugins

The installer copies anything under `plugins/` to `~/.claude/plugins/`. Today the repo bundles:

- **`claude-mem`** — cross-session memory consolidation. Off unless `hooks.memory_consolidation.enabled` is true in your manifest. Writes to `~/.claude/projects/<slug>/memory/`.

To disable claude-mem for one session: `export CLAUDE_MEM_DISABLE_OK=1`. To remove it permanently: edit `~/.claude/settings.json` to drop the `memory-consolidation-check.sh` entry from `SessionEnd`.

## A "what's running right now?" command

The system does not yet ship a one-shot inventory command. To check current state by hand:

```bash
# Active scheduled jobs
launchctl list | grep com.claude-stem

# Active hooks (read your settings.json)
jq '.hooks' ~/.claude/settings.json

# Manifest opt-ins (which conditional fragments are enabled)
jq '.hooks' ~/.claude/user-manifest.json

# Most recent install record
ls -lt ~/.claude/logs/install-*.log | head -1

# What the foundation manifest says got installed
jq '.files | length' ~/.claude/governance/foundation-manifest.json
```

A consolidated `claude system status` command is on the maintainer's list but not yet shipped.

## Uninstall

```bash
./uninstall.sh
```

By default, uninstall:

1. Boots out and removes every `com.claude-stem.*` plist from `~/Library/LaunchAgents/`.
2. Walks `~/.claude/governance/foundation-manifest.json` and removes only files whose live SHA-256 still matches the baseline.
3. Preserves: anything you've edited (foundation files with non-matching SHA), your `user-manifest.json`, your install logs, your vault, your plans directory, your memory files, your `~/.claude/projects/`.
4. Leaves a `~/.claude-uninstall-backup-<timestamp>/` directory with the pre-uninstall snapshot.

`--full` removes the user-edited foundation files too. `--purge` additionally clears the install logs. Neither flag touches your vault or your plans.

## See also

- [`docs/installer.md`](installer.md) — full install / uninstall reference.
- [`hooks/README.md`](../hooks/README.md), [`hooks/RULES.md`](../hooks/RULES.md) — hook details.
- [`docs/personalization-model.md`](personalization-model.md) — what's universal vs personal across the auto-author output.
- [`docs/llm-cost-model.md`](llm-cost-model.md) — what calls the LLM, how often, at what cost.
