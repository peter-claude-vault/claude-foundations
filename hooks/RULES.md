# pre-write-guard rules

The `pre-write-guard.sh` hook fires on every `Edit` and `Write` tool call. It evaluates fourteen rules — thirteen of them numbered R-NN, plus three branches under R-04 — and either allows the write (with optional advisory text) or denies it with a reason. The rules below describe what each one does in plain English, and which manifest field or environment variable, if any, controls or escapes it.

Rules are grouped by behavior:

- **Hard denies** stop the write. Claude sees the deny reason and reports it; the file is not modified.
- **Advisories** allow the write but attach a note Claude reads on the same turn.

## Hard denies

### R-01 — Dead-path block

Blocks any write to a path the manifest declared dead (via `paths.tripwire_paths[]` or the `PLANS_DIR_DEAD` env). Used after a directory rename so stale references surface immediately. The only exception is a `README.md` at the dead root, which is allowed as a placeholder.

### R-04 (size-guard branch) — File-size cap

Denies a write that would push a configured file past its declared size cap. Caps live in the manifest at `schema.size_guards[]` as `{ "path": "...", "limit": <bytes> }`. Used to keep specific files (memory indexes, top-level CLAUDE.md, similar) from drifting unbounded.

### R-23 — Cron-wrapper bash 3.2 compatibility

Denies a write to a cron wrapper (`$CRON_WRAPPERS/*.sh` or `*/cron-wrappers/*.sh`) that introduces bash 4+ syntax (`declare -A`, `${var,,}`, `readarray`, `{a..b..n}`, `&>>`). macOS cron runs these under `/bin/bash` 3.2, where bash-4 syntax fails silently. The rule is the only thing standing between you and a job that runs without errors but produces nothing.

### R-24 — Protected SessionEnd hooks

Denies any `settings.json` write that would remove a hook listed in `manifest.hooks.protected_session_end_hooks[]`. The default protected list keeps load-bearing cleanup hooks from being silently stripped.

Per-hook escape: set `HOOK_GUARD_DISABLE_OK=<hook-name>` in the environment of the session that needs to remove it. A back-compat escape `CLAUDE_MEM_DISABLE_OK=1` is honored for the memory-consolidation hook specifically.

### R-27 — Plan naming + status

Denies a write to a plan-tree file whose top-level directory segment lacks an `NN-` numeric prefix (`12-foo` is fine; `foo` is denied), or whose plan-root document has no status marker — either a `**Status:**` bullet, a YAML `status:` field, or a `manifest.json` with a `status` field. Both are required: the prefix lets the plan-index sort, the status header lets it group.

Escape: set `PLAN_STATUS_OK=1` for one-off scaffolding cases where the rule fights you legitimately.

### R-32 — Vault `type:` allowlist

Denies a vault-file write whose frontmatter declares a `type:` value that isn't in `governance/foundation-master.json` (the composed bundle shipped with every installation). The bundle is the single source of truth for which types are legal at write-time; the authoring source is `governance/frontmatter-rules.json#types`. Adding a new type without first updating the foundation rules is the failure mode this rule catches; see [`docs/adding-a-vault-file-type.md`](../docs/adding-a-vault-file-type.md) for the 5-surface lockstep procedure.

## Advisories

### R-02 — Skill change protocol

When you edit a `~/.claude/skills/*/SKILL.md`, Claude gets a reminder to update related memory files, refresh affected docs, and grep for downstream effects before considering the change shipped.

### R-04 (vault-root branch) — Top-level directory check

Surfaces an advisory when a vault file lands in a top-level directory not in `manifest.vault.root_directories[]`. Doesn't block; lets you know the placement looks unusual. Useful when the vault has a fixed top-level taxonomy and a stray new directory should be a deliberate decision.

### R-04 (folder-placement branch) — `type:` placement match

Surfaces an advisory when a `type:` value's typical placement pattern (declared in `governance/foundation-master.json#frontmatter.path_routing`) doesn't match the actual write path. Example: `type: meeting-note` with a typical placement under `Meetings/` written to `Inbox/raw/`. Allowed, but flagged.

### R-15 — Plan-to-backlog reminder

On every plan-tree write, Claude gets reminded to add or update the corresponding backlog row in `System Backlog.md`. Suppressed when R-28 detects a `parent_plan:` (sub-plans inherit their parent's row).

### R-28 — Parent-plan presence

Detects `parent_plan:` frontmatter on sub-plan files and uses it to suppress R-15. No deny path; this rule's only job is to inform the others.

### R-33 — Folder-placement advisory

When `type:` declares an expected `_placement_pattern` and the file is being written somewhere else, an advisory is surfaced. Looks similar to R-04's folder-placement branch — they both catch placement drift, but R-33 reads the placement contract from the type itself and R-04 reads the vault's allowlist.

### R-40 — Plan-artifact frontmatter

When a canonical plan filename (`spec.md`, `tasks.md`, `handoff.md`, `00-ideation-brief.md`) is missing frontmatter or has a non-canonical `type:` value, an advisory surfaces. These four filenames carry a known `type:` per `plans-schema.json` — drift here breaks the plan-index.

### R-42 — Multi-session overlap

Reads the multi-session registry at `<vault>/Logs/.coordination/session-registry.json`. If the file being written was also touched by a peer Claude Code session in the recent registry window, an advisory surfaces with the peer session ID. The intent is to keep two simultaneous sessions from quietly clobbering each other's edits.

### R-45 — Memory-file frontmatter

Advisory on memory-file writes (under `$CLAUDE_HOME/projects/*/memory/`, but excluding the `MEMORY.md` index itself). Validates that the file carries the four required fields — `name`, `description`, `type` (one of `user` / `feedback` / `project` / `reference`), `last_verified` (ISO 8601) — plus `status` and `superseded_by` when `type: project`. Also flags potential overlap with existing memory-index entries by keyword.

Records a JSONL audit history at `$HOOKS_STATE/memory-schema-advisory-history.jsonl`.

### R-54 — Doc-dependency cascade

When the write touches a file registered in `hooks/config/doc-dependencies.json` as either a primary or a mirror, an advisory surfaces listing the mirrors that need review. Lets you keep documentation cascades in sync without grepping for them by hand. See [`docs/doc-dependencies-conventions.md`](../docs/doc-dependencies-conventions.md).

## Why the R-NN numbers stay

The numbers appear in audit logs (`$HOOKS_STATE/hook-audit.log`) and in the deny / advisory text Claude returns. Renumbering them would break log archaeology and post-incident triage, so they survive the rewrite.

The original (private) hook this distribution descends from carried more rules than the thirteen above — many were specific to one vault's tag taxonomy, engagement structure, or operational conventions and didn't generalize. Those were dropped in the rewrite. If you find yourself wanting one back, you almost certainly want it as a separate hook keyed off your own manifest extension, not as a rule inside this one.

## See also

- [`hooks/README.md`](README.md) — the hook inventory and event wiring.
- [`docs/adding-a-vault-file-type.md`](../docs/adding-a-vault-file-type.md) — what to change in lockstep when extending the vault schema.
- [`docs/doc-dependencies-conventions.md`](../docs/doc-dependencies-conventions.md) — how the cascade declared by R-54 is configured.
