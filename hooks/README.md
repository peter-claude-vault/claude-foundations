# Foundation hooks — overview + install map

This directory ships the generic Claude Code hook set: 17 default-on hooks
covering write-time enforcement (R-01..R-54), session lifecycle, multi-session
coordination, and post-write validation. One additional hook is available as
opt-in.

## Install

The SP08 distribution installer reads `templates/settings.json` and merges it
into the user's `~/.claude/settings.json`, then drops the hook scripts at
`$CLAUDE_HOME/hooks/` and the lib helpers at `$CLAUDE_HOME/hooks/lib/`. Hooks
read manifest fields from `$CLAUDE_HOME/user-manifest.json` with hardcoded
fallbacks — every hook exits 0 on missing manifest (graceful-degrade per
SP02 spec Constraint).

## Default-on hooks (17)

Wired into `templates/settings.json`. Always installed.

| Event | Hook | Purpose |
|---|---|---|
| PreToolUse[Edit\|Write] | `pre-write-guard.sh` | 13-rule R-enforcement (R-01..R-54 generic core) |
| PostToolUse[Edit\|Write] | `track-vault-write.sh` | Multi-session registry update on vault writes |
| PostToolUse[Edit\|Write] | `post-write-verify.sh` | Frontmatter schema validation + R-38/R-39 advisory |
| UserPromptSubmit | `prompt-context.sh` | Context-pressure mandate + multi-session overlap surfacing |
| SessionStart | `session-register.sh` | Multi-session coordination registry entry |
| SessionStart | `cron-health-banner.sh` | 24h-cached cron-health summary |
| Stop | `stop-checkpoint-check.sh` | Block stop on stale checkpoint at high context-pressure |
| Stop | `stop-drift-scan.sh` | Touched-file drift advisory at session end |
| PreCompact[auto\|manual] | `pre-compact-checkpoint.sh` | Pre-compact session-state snapshot |
| SessionEnd | `session-deregister.sh` | Multi-session coordination cleanup |
| statusLine | `worker-statusline.sh` | Statusline rendering |

Plus 6 supporting scripts: `auto-commit-surfaces.sh`, `memory-consolidation-check.sh`,
`memory-consolidation-run.sh`, `reconcile-sessions.sh`, `session-auto-close.sh`,
`tasks-md-autosync.sh`. These are wired conditionally — see below.

## Conditional hooks (4 fragments)

The SP08 installer reads `manifest.behavioral.hook_preferences` and merges
fragment files from `templates/settings-fragments/` based on opt-in flags:

| Fragment | Manifest flag | When to enable |
|---|---|---|
| `memory-consolidation.json` | `hooks.memory_consolidation.enabled` | Installing claude-mem; SessionEnd consolidation desired |
| `auto-commit.json` | `hooks.auto_commit.enabled` | `$CLAUDE_HOME` and/or vault are git repos with auto-commit policy |
| `tasks-md-autosync.json` | `hooks.tasks_autosync.enabled` | Plan workflow with `tasks.md` task-status markers |
| `multi-session.json` | `hooks.multi_session.enabled` | Concurrent Claude Code sessions on the same vault expected |

Default posture: all four conditionals are **off** unless the user opts in
during onboarding. Foundation install ships strictest-by-default.

## Opt-in advanced (1)

`session-start-canary.sh` is **not** wired into the default `templates/settings.json`.
It detects unexpected resurrection of a tripwire path (e.g., a deprecated plans
directory). It is a migration-scar pattern — useful for users tracking a
specific filesystem move, never useful on a greenfield install. Add to the
SessionStart array manually if you have a tripwire path to monitor; declare it
via `manifest.paths.tripwire_paths[]` (foundation hook reads this; absent
manifest entry = no-op).

## State + config

- `hooks/state/` — runtime state (`hook-audit.log`, `tripwire.log`, etc.). Created lazily by hooks; ships empty.
- `hooks/config/` — hand-editable allowlists:
  - `doc-dependencies.json` — R-54 doc-dependency cascade entries
  - `drift-allowlist.json` — librarian provides:-overlap exemptions
  - `cron-log-architecture-exceptions.json` — R-22 wrapper-owned-logging exceptions

All three ship empty (`[]`); users add entries as their installation evolves.

## See also

- `lib/paths.sh` — manifest-driven path resolution (single source of truth)
- `DROPPED-RULES.md` — rationale for R-rules dropped in the live→foundation rewrite
- `templates/settings.json` — default hook wiring (consumed by SP08 installer)
- `templates/settings-fragments/` — opt-in conditional fragments
