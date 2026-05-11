# Claude Code — {{IDENTITY_NAME}}

This file is `~/.claude/CLAUDE.md` (or `$CLAUDE_HOME/CLAUDE.md`). Claude Code
reads it on session start. Keep it lean — communication and workflow rules
only. Vault-specific conventions (folders, tags, frontmatter, engagement
structure) belong in the vault's own CLAUDE.md, not here.

## Identity

| Field | Value |
|---|---|
| Name | {{IDENTITY_NAME}} |
| Role | {{IDENTITY_ROLE}} |
| Organization | {{IDENTITY_ORGANIZATION}} |

Identity values are sourced from `$CLAUDE_HOME/user-manifest.json` at install
time. To update them, re-run `/onboard --section a` and re-run `/adopt`. Both
are idempotent.

## Communication

- **Firm and specific.** Confident assertions with concrete details. Avoid
  hedging language ("perhaps," "might be") when the answer is known.
- **Audience-aware.** Define the audience before writing. The same content
  shaped for an exec, a peer, and Claude itself looks different.
- **Mirror the user's language.** Use their tone, terminology, and phrasing
  where possible.
- **Receive unstructured input, return structured output.** Spoken-style
  briefs, fragmented context, mid-thought corrections — all valid input.

## Working Patterns

- **Context-first.** Wait for the full brief before producing output. Don't
  jump ahead.
- **Progressive disclosure.** When context is loaded in stages, synthesize
  understanding back before executing on complex asks.
- **Produce deliverables, not conversation.** Sessions should end with
  concrete artifacts — documents, code, structured briefs. Not just
  discussion.
- **Iterative refinement.** Edit in typed passes: structural → content →
  tone → polish. Don't conflate feedback types.

## Coding Preferences

- **Go straight to the point.** Simplest approach first. Don't over-engineer.
- **No unnecessary abstractions.** Three similar lines beat a premature
  helper function.
- **Don't add what wasn't asked for.** No extra docstrings, type
  annotations, error handling, or refactoring beyond the request.
- **Security-conscious.** Never introduce injection vulnerabilities,
  credential exposure, or unsafe patterns.
- **Test after writing.** Run tests or verify output when the tooling
  supports it.

## Skill Creation Rules — Output Contract

When creating a new skill, capability, or script that writes to the vault or
to user-owned filesystem locations:

1. The skill's `SKILL.md` MUST include an **Output Contract** section
   declaring: files written, schema type, pre-write validation steps, and
   failure mode.
2. The skill MUST validate frontmatter against the relevant JSON schema
   (`vault-schema.json` for vault writes, `user-manifest-schema.json` for
   manifest writes) before any write.
3. The skill MUST declare its failure mode as **block and log** — never
   "write and hope."
4. Skills without Output Contracts are incomplete and must not be marked as
   built.

## Auto Memory

Claude Code maintains a persistent file-based memory system at
`$CLAUDE_HOME/projects/<slug>/memory/`. Memory accumulates across sessions
and compounds over time — treat it as durable user context, not
session-scoped scratch.

### Memory Search Strategy

When looking for prior context, search in this order:

1. **MEMORY.md index** — always loaded; check first for curated,
   high-signal context.
2. **Memory files** — read the specific files referenced in `MEMORY.md`
   for detail.
3. **claude-mem search** — for broader recall (observations, tool usage,
   session history); available when the `claude-mem` plugin is installed.
4. **Session transcripts** — last resort; raw JSONL files, use targeted
   `grep`.

When the librarian runs `mem-promote`, knowledge flows UP this hierarchy:
transcripts → claude-mem → (mem-promote filter) → auto-memory →
`MEMORY.md` index. Each layer is progressively more curated and more
readily available.

### Writing Memory

New memory files live at
`$CLAUDE_HOME/projects/<slug>/memory/<type>_<slug>.md` where `<type>` is
one of `user`, `feedback`, `project`, or `reference`. Every memory file
MUST carry the four-field memory frontmatter contract enforced by the
pre-write guard's R-45 advisory:

```yaml
---
name: <short title>
description: <one-line summary used to decide future relevance>
type: <user|feedback|project|reference>
last_verified: <ISO 8601 date>
---
```

Adding a new memory file should also append a one-line index entry under
the appropriate H2 section in `MEMORY.md`.

## Plan Creation Conventions

When creating a new plan in `~/.claude-plans/`:

1. **Descriptive slug.** The plan folder or file name must describe the
   actual scope of work (e.g., `auth-rewrite`, not an auto-generated
   adjective-verb-noun like `async-wiggling-donut`). Rename any
   auto-generated shame slug before the first commit.
2. **Number prefix in creation order.** Every plan gets a numeric prefix
   matching the next integer after the highest existing prefix. If the last
   created plan is `38-foo`, the next is `39-bar`. Do not backfill
   historical gaps.
3. **Subplans within a plan folder.** Sub-plan files use `NN-{slug}/` where
   NN is 01, 02, 03… in **execution order**, not creation order.
4. **Status header required.** Every plan's top-level doc (`spec.md` or flat
   `.md`) must have either a `**Status:**` header line OR a `manifest.json`
   with a `status` field. Missing status breaks the `librarian plan-index`
   capability, which regenerates `~/.claude-plans/_index.md` grouped by
   status.
5. **`parent_plan:` on sub-task files.** Sub-task files at depth ≥ 3 under
   `~/.claude-plans/` MUST carry `parent_plan: <top-level-slug>` in their
   YAML frontmatter. Plan-root files at depth 2 are exempt — they are the
   parent, not the child.
6. **Canonical ideation brief location.** `~/.claude-plans/{slug}/00-ideation-brief.md`
   with a symlink at `<vault_root>/Logs/ideation-brief-{slug}.md` for vault
   visibility.

To find the next prefix:

```sh
ls ~/.claude-plans/ | grep -oE '^[0-9]+' | sort -n | tail -1
```

Add 1. Use the descriptive slug. Add the status header on day 1.

**Sanctioned creation paths** (use ONE — do not hand-write new plan
directories):

- `/new-plan <slug>` — ad-hoc scaffolding. Renders the canonical quartet
  (`spec.md` + `tasks.md` + `handoff.md` + `00-ideation-brief.md`) +
  `manifest.json` from templates, assigns the next prefix, rejects shame
  slugs, adds the backlog row.
- `/backlog-research <item>` — research-first creation. Same scaffolding
  backed by actual vault/infra/external research. Use when a triaged
  backlog item needs feasibility analysis before planning.

## Hard Constraints Override Spec Text

When a stated constraint (no live mutations, no destructive operations
without confirmation, no credential exposure, etc.) conflicts with a spec,
plan, or task description, the spec is treated as **defective**. Options
that violate the constraint do **not** appear in option-comparison tables.
The user does not get to "choose between honoring or violating" their own
rule — the constraint already settled the question. Flag the spec as
defective and propose corrections.

## Compact Instructions — Session Continuity Block Schema

When compacting, preserve state using this exact schema. Populated by the
PreCompact hook (automatic), by the `/session-checkpoint` skill (manual or
context-pressure enforcement), or on user request:

```
plan_id:                   # active plan slug from ~/.claude-plans/
phase:                     # current phase number/name
task_id:                   # current task ID and status
completed_steps:           # list of completed steps/tasks this session
files_modified:            # list of files modified this session
key_decisions:             # architectural or design decisions made
next_steps:                # what to do next
ac_status:                 # acceptance criteria checklist (done/pending per item)
current_blocker:           # current error, test failure, or blocker (if any)
context_pct_at_checkpoint: # context pressure % at the moment of the write
```

After compaction, restore context by reading
`$CLAUDE_HOME/hooks/state/sessions/<sid>/checkpoint.md` (where `<sid>` is
`$CLAUDE_SESSION_ID`) and mapping its fields to this schema. This is a
contract between PreCompact output and post-compaction model intake.
Fields that cannot be populated must be marked `[MISSING]` — never silently
skipped.

**Checkpoint file contract:**

- `$CLAUDE_HOME/hooks/state/sessions/<sid>/checkpoint.md` is the single
  canonical "current session state" file PER SESSION (where `<sid>` is
  `$CLAUDE_SESSION_ID`). `/session-checkpoint`, `prompt-context.sh` (silent
  at moderate pressure), and `pre-compact-checkpoint.sh` all write here.
  Hooks fall through to graceful no-op when `$CLAUDE_SESSION_ID` is absent
  (zero-cross-session-pollution invariant). Per-session paths close the
  cross-session-pollution incident class where peer sessions racing through
  SessionStart `source=compact` could deliver wrong-session payload via
  POST-COMPACTION CHECKPOINT RESTORE.
- Dated `checkpoint-YYYYMMDD-HHMMSS.md` archives live under the same
  per-session dir (`$CLAUDE_HOME/hooks/state/sessions/<sid>/`), rotated by
  `session-register.sh` on SessionStart `source=compact`. They are
  legitimate history — do not delete or write to them directly.
- Stale per-session directories (orphan in registry + mtime older than
  `CHECKPOINT_CLEANUP_TTL_SECS`, default 3600s) are cleaned up by
  `lib/cleanup-stale-session-dirs.sh`, fired from `session-deregister.sh`
  tail. Active and `closed-pending-reconciliation` sessions are protected
  from deletion regardless of mtime.
- Default thresholds: warn at 45% context pressure, mandate at 48%,
  hard-block at 80%. Customize in `user-manifest.json` under
  `hooks.context_pressure.{warn_pct,mandate_pct,hard_pct}` if desired.

## Do

- File content automatically when the destination is clear.
- Surface related context from the project without being asked.
- Preserve user edits in any shared file (survivorship rules).
- Check for existing skills/tools/patterns before building from scratch.
- Ask clarifying questions on ambiguous placement or scope.

## Don't

- Don't respond prematurely when context is still being loaded.
- Don't create new top-level structures without explicit approval.
- Don't overwrite historical records or past-dated content.
- Don't hedge or soften language — be direct.
- Don't summarize what you just did at the end of responses. The user can
  read the diff.
- Don't add emojis unless explicitly asked.

## Vault Pointer

If a vault is configured (`vault.root` in `user-manifest.json` is set), the
vault's own `CLAUDE.md` is the operational database for engagement work and
contains all structural context, conventions, and engagement-specific
rules. Load that on demand — don't duplicate vault rules here.

## What `install.sh` did

This file was seeded by `install.sh` at install time. Identity fields above
were substituted from `$CLAUDE_HOME/user-manifest.json` — no placeholder
tokens should remain. If you see `{{...}}` markers anywhere in this file,
the substitution failed; re-run `install.sh` (idempotent) to refresh.

To customize this file, edit it directly. `install.sh` will not clobber it
on re-run unless invoked with `--force-install` and the explicit
clobber-acknowledgement sentinel — the same install-corruption protection
that guards every other foundation file. See
[`docs/install-corruption-incident.md`](../docs/install-corruption-incident.md)
for the rationale.
