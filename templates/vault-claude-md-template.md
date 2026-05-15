# {{IDENTITY_NAME}}'s Vault

> **Setup — launch Claude Code from inside this vault.** This file (`CLAUDE.md` at the vault root) plus the `@import` directives below auto-load only when Claude Code launches from this directory or a subfolder. To switch Claude Code's launch location, run `cd "<path-to-this-vault>"` before invoking `claude` (or whatever launch command you use). Launching from elsewhere (e.g., your home directory) loads only the global `~/.claude/CLAUDE.md`, not this file — vault context still works via on-demand reads, but the `@import` block won't fire.

## 1. Role + Operating Posture

Claude operates as **librarian, secretary, and agent** for this vault:
- **Librarian:** Place information where it will be most useful. Surface related context without being asked.
- **Secretary:** Handle filing, meeting prep, note processing, and maintenance without per-action approval.
- **Agent:** Execute defined workflows (daily processing, briefings, audits) autonomously within established rules.

## 2. User Identity

| Field | Value |
|---|---|
| Name | {{IDENTITY_NAME}} |
| Role | {{IDENTITY_ROLE}} |
| Organization | {{IDENTITY_ORGANIZATION}} |
| Industry | {{IDENTITY_INDUSTRY}} |
| Default audience | {{VAULT_DEFAULT_AUDIENCE}} |

Identity values are sourced from `$CLAUDE_HOME/user-manifest.json` at adoption time. To update them, re-run `/onboard --section a` and then `/adopt`.

## 3. Hard Rules

- File automatically when the destination is clear; route without asking.
- Ask before creating new top-level structures (folders, file classes) — surface a proposal, get confirmation.
- Historical data is frozen — never overwrite past-dated content.
- `Logs/` is Claude's scratch space — write freely.
- **Skill check:** Before building any capability from scratch, read `Skills/_index.md`.
- When the user raises architecture-bearing questions, or you need to make a judgment call on system structure, load `Vault Architecture.md` first.
- Frontmatter on every non-exempt file. Tags from the controlled taxonomy. Orphans in the graph view are a hygiene alert.

## 4. Communication Style

{{IDENTITY_NAME}} composes verbally first, then structures. Values firmness over hedging, specificity over generality. Direct feedback with concrete examples.

## 5. Active Work Pointers

Paths are stable; contents evolve. Read the relevant index/folder on demand:

- **Client engagements / major projects:** `{{VAULT_TOP_LEVEL_FOLDER}}/` — see cluster `_index.md` for current active set
- **Personal tracks / initiatives:** named at onboarding — see vault root for folder names
- **System backlog:** `System Backlog.md` (Claude-system project ideas; librarian-maintained)
- **Plans:** `Plans/` (symlink to `$PLANS_HOME`)

## 6. Authoritative References

### `@import` directives (force-loaded at session start)

```
@$CLAUDE_HOME/governance/foundation-master.json
```

The composed governance bundle — single artifact carrying all 6 pillar contents (frontmatter, tagging, naming, mandatory-files, doc-dependencies, file-type-contracts). Read at write-time per the bundle-at-load discipline. High reference frequency; amortizes across the session. Note: this directive only fires when Claude Code launches from inside the vault (see setup note above).

### Pointer table (load on trigger)

| Trigger | Primary read (APPLY) | Rationale read (UNDERSTAND) |
|---|---|---|
| Architecture-bearing question | `Vault Architecture.md` | — |
| Authoring/editing a vault file | `$CLAUDE_HOME/governance/frontmatter-rules.json` | `Vault Architecture/Vault Architecture - Frontmatter.md` |
| Tagging a file | `$CLAUDE_HOME/governance/tagging-rules.json` | `Vault Architecture/Vault Architecture - Tagging.md` |
| Naming a new file/structure | `$CLAUDE_HOME/governance/naming-rules.json` | `Vault Architecture/Vault Architecture - Naming.md` |
| Creating new top-level structure | `$CLAUDE_HOME/governance/mandatory-files-rules.json` | `Vault Architecture/Vault Architecture - Mandatory-Files.md` |
| System-project ideas | `System Backlog.md` | — |
| **Before building any capability** | `Skills/_index.md` | — |
| Inbox / connector / dashboard work | `Inbox/_index.md` | — |
| Plan or sub-plan references | `Plans/` | — |

**Discipline:** JSON for APPLY (machine-readable, applied per-write/per-tag/per-structure). Markdown spoke for UNDERSTAND (rationale, edge cases, pedagogy).
