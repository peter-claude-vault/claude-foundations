# {{IDENTITY_NAME}}'s Vault

This vault is the operational database for {{IDENTITY_NAME}}'s work — meeting notes,
project context, briefings, daily logs, ideation briefs, references. Claude reads
and writes here under the conventions documented below.

## Identity context

| Field | Value |
|---|---|
| Name | {{IDENTITY_NAME}} |
| Role | {{IDENTITY_ROLE}} |
| Organization | {{IDENTITY_ORGANIZATION}} |
| Industry | {{IDENTITY_INDUSTRY}} |
| Default audience | {{VAULT_DEFAULT_AUDIENCE}} |

Identity values are sourced from `$CLAUDE_HOME/user-manifest.json` at adoption
time. To update them, re-run `/onboard --section a` (Section A re-record) and
re-run `/adopt` — the latter is idempotent and will refresh substituted fields
without re-creating directory scaffolding.

## Vault conventions

- **Organizational method:** {{VAULT_ORGANIZATIONAL_METHOD}}
- **Top-level folder:** `{{VAULT_TOP_LEVEL_FOLDER}}/` (engagement-based vaults)
  or flat layout (project-based vaults)
- **Canonical file types:** populated by `/adopt` (skeleton at adoption time;
  Phase 2 in v2.1 populates richer set from archetype heuristic). Authoritative
  list lives at `$CLAUDE_HOME/user-manifest.json` `vault.canonical_file_types[]`
  and at `<vault_root>/.coordination/canonical-file-types.json`. Both are kept
  in sync by future hooks.
- **Frontmatter contract:** every non-exempt vault file carries `tags:`. Orphans
  in graph view are a hygiene alert. Validate frontmatter against
  `$CLAUDE_HOME/schemas/vault-schema.json` before any vault write.
- **Plans symlink:** `Plans/` symlinks to `$PLANS_HOME` (typically
  `$HOME/.claude-plans/`). Plan-state lives outside the vault to escape Claude
  Code's sensitive-file gate; the symlink is read-only navigation surface.

## Directory layout (post-adoption skeleton)

| Path | Purpose | Lifecycle |
|---|---|---|
| `Inbox/` | Capture surface — emails, transcripts, dashboard data | Daily reconcile |
| `Logs/` | Build logs, ideation briefs, session notes | Append-only |
| `Logs/backlog-progress/` | Per-backlog-item satellite logs (R-29/R-30/R-31) | Sentinel-driven |
| `.coordination/` | Multi-session shared state, hook artifacts, manifests | Hook-managed |
| `Plans/` | Symlink to `$PLANS_HOME` (plan-state, manifests, handoffs) | External |
| `System Backlog.md` | Vault-root index of system-project ideas | librarian-maintained |

Directory expansion happens organically — `/adopt` ships the minimum viable
skeleton; subsequent capture and processing populate engagement folders,
project folders, and people files as needed.

## Working with Claude

Claude reads this CLAUDE.md on session start. Vault-specific conventions
(naming, tags, frontmatter, engagement structure) belong here, not in
`~/.claude/CLAUDE.md`. Keep the global file lean — communication and workflow
rules only — and document vault structure here.

For multi-engagement vaults: nested `<engagement>/CLAUDE.md` files act as
navigation guides scoped to that engagement; they describe the engagement's
specific conventions, key files, and active workstreams.

## What `/adopt` did

This file was seeded by `/adopt` at adoption time. Identity fields above were
substituted from `$CLAUDE_HOME/user-manifest.json` — no placeholder tokens
should remain. If you see `{{...}}` markers below this paragraph, the
substitution failed; re-run `/adopt` (idempotent) to refresh.

## What's next

- **System backlog.** Open `System Backlog.md` and start capturing system-project
  ideas. The librarian + architect will work the backlog over time.
- **First engagement.** Create `{{VAULT_TOP_LEVEL_FOLDER}}/<engagement-name>/`
  with its own CLAUDE.md, or work in a flat layout if you prefer.
- **Hook posture.** Section E of `/onboard` decided your hook posture
  (auto-commit, memory-consolidation, multi-session). Adjust at any time via
  `~/.claude/settings.json` opt-in fragments.
- **Plans surface.** `Plans/` is a symlink to your plan-state directory. Use
  `/new-plan <slug>` to scaffold a plan or `/backlog-research <item>` for
  research-first creation.
