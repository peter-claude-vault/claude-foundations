# templates/

Files the installer renders into a user's `~/.claude/` and vault directories at install or adopt time. The templates ship the foundation hook config in two layers:

- **`settings.json`** — the always-on default. Wires the default-on hook entries across eight Claude Code lifecycle events. Default-deny posture: opinionated extras (memory consolidation, auto-commit, multi-session reconciliation, tasks-md autosync) are NOT in this file. Users opt in to those during onboarding.
- **`settings-fragments/`** — opt-in conditional fragments. The installer reads `manifest.behavioral.hook_preferences.<flag>` and deep-merges enabled fragments into the user's `~/.claude/settings.json`.

## Default `settings.json`

| Event | Slot count | Hooks |
|---|---|---|
| PreToolUse[Edit\|Write] | 1 | `pre-write-guard.sh` |
| PostToolUse[Edit\|Write] | 2 | `track-vault-write.sh`, `post-write-verify.sh` |
| UserPromptSubmit | 1 | `prompt-context.sh` (timeout 5s) |
| SessionStart | 2 | `session-register.sh`, `cron-health-banner.sh` (timeout 10s) |
| Stop | 2 | `stop-checkpoint-check.sh` (timeout 3s), `stop-drift-scan.sh` (timeout 10s) |
| PreCompact[auto\|manual] | 1 | `pre-compact-checkpoint.sh` (timeout 5s) |
| SessionEnd | 1 | `session-deregister.sh` |
| statusLine | 1 | `worker-statusline.sh` |

**Timeouts** are in seconds (per Claude Code hooks docs). Hooks without an explicit timeout inherit the default 600s command-hook ceiling — fine for the fast registry / git / python operations they run.

`session-start-canary.sh` is **not** in default `SessionStart`. See [`hooks/README.md`](../hooks/README.md) for the opt-in pattern.

## Conditional fragments

Each fragment file has a self-describing schema:

```json
{
  "_comment": "Why this fragment exists + when to enable",
  "_merge_target": "<dotted-path into settings.json>",
  "_manifest_flag": "<manifest field that gates inclusion>",
  "entries": [ /* hook entries appended to _merge_target.hooks */ ]
}
```

| Fragment | Manifest flag | Merge target |
|---|---|---|
| `memory-consolidation.json` | `hooks.memory_consolidation.enabled` | `SessionEnd[0].hooks` |
| `auto-commit.json` | `hooks.auto_commit.enabled` | `SessionEnd[0].hooks` |
| `tasks-md-autosync.json` | `hooks.tasks_autosync.enabled` | `PostToolUse[Edit\|Write].hooks` |
| `multi-session.json` | `hooks.multi_session.enabled` | `SessionEnd[0].hooks` |

## Installer contract

```
for each fragment in templates/settings-fragments/*.json:
  flag = jq ._manifest_flag fragment
  if jq -e ."$flag" user-manifest.json:
    target  = jq ._merge_target fragment
    entries = jq .entries fragment
    deep-merge entries into user-settings.json at target
```

Fragments are additive. The installer never strips entries from the default `settings.json`. To disable a default-on hook, the user edits their own `~/.claude/settings.json` post-install.

## Manual install (no installer)

Copy `settings.json` to `~/.claude/settings.json`. For each opt-in fragment you want enabled, manually merge its `entries[]` into the matching event's `hooks[]` array.

## Validation

```bash
# Top-level structure
jq -e '.hooks | type == "object"' templates/settings.json

# Every fragment merge-target dotted path resolves
for f in templates/settings-fragments/*.json; do
  jq -e '._merge_target and ._manifest_flag and (.entries | length > 0)' "$f"
done
```
