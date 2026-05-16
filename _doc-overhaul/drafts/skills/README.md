# skills/

Slash-command skills installed into `~/.claude/skills/`. Each skill is a directory with a `SKILL.md` (frontmatter + body that Claude Code reads at invocation time) plus any helper scripts the skill spawns.

Every skill in this set reads `~/.claude/user-manifest.json` at runtime to resolve identity, paths, vault layout, and behavioral preferences. None of them carry per-user content.

## Inventory

| Skill | What it does | Trigger |
|---|---|---|
| [`onboarder`](onboarder/SKILL.md) | Five-section verbal-first interview that produces `user-manifest.json`. The entry point for a fresh install. | `/onboard` (and auto on `SessionStart` when no manifest exists) |
| [`adopt`](adopt/SKILL.md) | Scaffolds a fresh Obsidian-compatible vault from the manifest. Optional retrofit mode for existing populated vaults. | `/adopt` |
| [`librarian`](librarian/SKILL.md) | Vault hygiene authority. ~25 capabilities covering placement validation, frontmatter enforcement, cross-reference checks, stale-content detection, log archival, backup, drift sweeps, tag audits. | `/librarian [capability]` |
| [`architect`](architect/SKILL.md) | Strategic vault analyzer. Reads the librarian manifest plus the skills index and writes a dated recommendations report across seven dimensions. Read-only. | `/architect` |
| [`infer-vault-structure`](infer-vault-structure/SKILL.md) | Four-stage cluster → propose → import-plan → review-gate chain. Takes an existing pile of notes and proposes a vault taxonomy. | Invoked by `/onboard --seed-content` and `/adopt --retrofit-existing`. |
| [`seed-projects`](seed-projects/SKILL.md) | Bulk-creates project folders with PRD/Context/Updates triads from an approved import plan. | Invoked by `/adopt --retrofit-existing`. |
| [`inbox-processor`](inbox-processor/SKILL.md) | Routes files dropped into `Inbox/` to the right destination based on type heuristics. | Cron + on-demand. |
| [`meeting-note-ingestor`](meeting-note-ingestor/SKILL.md) | Generic transcript → structured meeting note. | Invoked by connector pipelines. |
| [`meeting-note-ingestor-granola`](meeting-note-ingestor-granola/SKILL.md) | Granola-specific wrapper around the generic ingestor. | Invoked by the Granola connector pipeline. |
| [`morning-brief`](morning-brief/SKILL.md) | Synthesizes a morning briefing from yesterday's meeting notes, calendar, and inbox. | `/morning-brief` |
| [`backlog-triage`](backlog-triage/SKILL.md) | Auto-classifies new items in `System Backlog.md` (NOVEL / DUPLICATE / OVERLAP / DEFERRED). | `/backlog-triage` |
| [`backlog-research`](backlog-research/SKILL.md) | Deep research on a triaged backlog item. Produces an ideation brief at `~/.claude-plans/<slug>/00-ideation-brief.md`. | `/backlog-research <item>` |
| [`backlog-hygiene`](backlog-hygiene/SKILL.md) | Stale-item detection, lifecycle-timeout enforcement, auto-archival of completed items. | `/backlog-hygiene` |

## Adding a skill

1. Create `skills/<name>/SKILL.md` with the canonical Claude Code frontmatter (`name`, `description`, `argument-hint`).
2. Drop helper scripts in the same directory.
3. Read paths and config from `~/.claude/user-manifest.json` via `lib/paths.sh` rather than hardcoding.
4. Add the skill's `<name>/` directory to `install.sh`'s named-skills allowlist and `generate-foundation-manifest.sh`.

If the skill writes to the user filesystem, declare an Output Contract in its `SKILL.md` body — files written, schema types validated against, pre-write validation steps, failure mode. The convention is enforced by `post-write-verify.sh` for vault writes and is good practice for everything else.

## See also

- [`hooks/README.md`](../hooks/README.md) — runtime guards every skill operates under.
- [`docs/personalization-model.md`](../docs/personalization-model.md) — how skill output is classified across universal, combined, and personal tiers.
