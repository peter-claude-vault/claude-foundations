# vault-scaffolding/

Seed files `/adopt` writes into a fresh vault. The directory mirrors the layout `/adopt` produces, so contents here are exactly what an adopter sees on day one.

## What's seeded

| File | What it is |
|---|---|
| `System Backlog.md` | Top-level index for system-project tracking. Empty on install with `## Active` and `## Archived` H2 sections. The `/backlog-triage` and `/backlog-research` skills add and update rows here. |
| `System Backlog - Archive.md` | Companion archive file. `/backlog-hygiene` writes resolved items here (preserves them rather than deleting). |
| `Logs/backlog-progress/_template.md` | Per-item progress log template. When `/backlog-triage` promotes a row, it creates `Logs/backlog-progress/<slug>.md` from this template. |

## What `/adopt` does in addition to seeding these files

- Creates `Inbox/`, `Logs/`, `Logs/backlog-progress/`, `.coordination/` directories.
- Renders `CLAUDE.md` from [`templates/vault-claude-md-template.md`](../templates/) with identity tokens substituted from your manifest.
- Symlinks `Plans/` to `$PLANS_HOME` (default `~/.claude-plans/`).
- Drops a skeleton `.coordination/canonical-file-types.json`.

## Editing seed content

Files in this directory are templates. They ship with empty content and minimal frontmatter. If you want a different starting state — different H2 sections, different default tags, a pre-filled archive index — edit the file here and your next `/adopt` run picks it up.

`/adopt` is idempotent. Re-running it on an already-scaffolded vault leaves your edits in place — the seed files are written only when the target file does not already exist.

## See also

- [`docs/adopt.md`](../docs/adopt.md) — full `/adopt` reference, including the manifest-field → vault-output mapping.
- [`skills/adopt/SKILL.md`](../skills/adopt/SKILL.md) — skill output contract.
