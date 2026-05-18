# Vault CLAUDE.md Template

The vault `CLAUDE.md` is the root instruction file Claude Code loads when working inside your vault. It is one of the three mandatory vault-root files the foundation ships and governs.

**Source:** `templates/vault-claude-md-template.md` in the repo. After install: `$CLAUDE_HOME/templates/vault-claude-md-template.md`. `/adopt` resolves the runtime path first, falls back to repo-relative for development.

**Audience:** developers extending the template or understanding how it is rendered and used.

---

## What the template produces

`/adopt` renders this template with identity substitution and writes the result to `<vault_root>/CLAUDE.md`. The rendered file instructs Claude Code on:

- Who owns the vault and how to interact with them
- Which governance bundle to load at session start
- Where to route files and when to ask before creating structure
- Which vault-root files are mandatory and where to find architecture documentation

---

## Substitution tokens

Seven tokens are replaced from `$CLAUDE_HOME/user-manifest.json` at render time:

| Token | Source field | Default fallback |
|---|---|---|
| `{{IDENTITY_NAME}}` | `identity.name` | `_not provided_` |
| `{{IDENTITY_ROLE}}` | `identity.role` | `_not provided_` |
| `{{IDENTITY_ORGANIZATION}}` | `identity.organization` | `_not provided_` |
| `{{IDENTITY_INDUSTRY}}` | `identity.industry` | `_not provided_` |
| `{{VAULT_ORGANIZATIONAL_METHOD}}` | `vault.organizational_method` | `_not provided_` |
| `{{VAULT_TOP_LEVEL_FOLDER}}` | `vault.top_level_folder` | `_not provided_` |
| `{{VAULT_DEFAULT_AUDIENCE}}` | `vault.default_audience` | `_not provided_` |

Post-write validation greps for `{{[A-Z_]+}}`; any remaining placeholder triggers exit 50 (halts and logs rather than shipping a broken file).

---

## Template structure and canonical design

### Governance bundle load

The template's `@import` directive loads `@$CLAUDE_HOME/governance/foundation-master.json` at session start. This is the composed 6-pillar governance bundle (frontmatter rules, tagging rules, naming rules, mandatory-files rules, doc-dependencies, file-type contracts). The bundle-at-load discipline means Claude reads it once per session, not per write.

**Not** `@$CLAUDE_HOME/schemas/vault-schema.json` — that schema is dissolved in the canonical architecture. The bundle replaces all direct schema reads at write time.

### Mandatory vault-root files (§C)

The template references the three files that must be present at every vault root:

| File | Role |
|---|---|
| `CLAUDE.md` | This file — vault instruction root; loaded at session start |
| `System Backlog.md` | System-project idea tracker; librarian-maintained |
| `System Governance.md` | Governance overview hub; load when architecture questions arise |

The template's pointer table includes a trigger row for `System Governance.md` so Claude knows to load it on architecture-bearing questions.

### 6-spoke governance surface (§D)

`System Governance/` contains six narrative markdown spokes, one per governance pillar:

1. `System Governance - Frontmatter.md`
2. `System Governance - Tagging.md`
3. `System Governance - Naming.md`
4. `System Governance - Mandatory-Files.md`
5. `System Governance - Doc-Dependencies.md`
6. `System Governance - File-Type-Contracts.md`

These are user-facing prose documentation — not Claude's source of truth (that is the JSON bundle). Users read the spokes for understanding; Claude reads the JSON for enforcement.

### In-folder `_index.md` auto-bootstrap (§E)

The template does not declare `_index.md` files for individual folders — they are auto-bootstrapped by `post-write-verify.sh` at first write to any non-exempt folder that lacks one. The template describes the convention ("Orphans in the graph view are a hygiene alert") and points at `System Governance.md` for the full mandate.

**Exempt folders** (no `_index.md` required): `Archive/`, `Daily/`, `Inbox/`, `Logs/`, `Meetings/`. These are foundation-shipped folders with date-prefixed or aggregation-only contents.

### Foundation-scaffolded system folders (§F)

The template's directory layout section enumerates the system folders seeded at `/adopt` time:

- `Archive/`, `Logs/`, `Inbox/`, `Daily/`, `Meetings/` — foundation-shipped folders
- `Plans/` — symlink to `$PLANS_HOME` (plan-state lives outside the vault)
- `Skills/` — symlink to `$CLAUDE_HOME/skills/` (read-only navigation surface)

### Retired items — NOT referenced in the template (§G)

The following surfaces were present in earlier vault designs and are explicitly absent from the canonical template:

| Retired item | Why removed |
|---|---|
| `Tasks.md` at vault root | Users define their own task-tracking workflow; foundation imposes no shape |
| `About Me/` folder | Not a foundation-mandated structure |
| `enforcement-map.md` at vault root | Superseded by JSON governance pillars + hooks |
| Per-folder `CLAUDE.md` files | One vault-root `CLAUDE.md` only; nested instruction files are not a foundation pattern |
| `vault-schema.json` validation reference | Dissolved; governance reads from `foundation-master.json` bundle |

---

## Rendering

Two production paths render this template:

| Path | When |
|---|---|
| `skills/adopt/adopt.sh` (lines 371–376) | `/adopt` first run and `--refresh` re-runs |
| `onboarding/auto-author/surface-3-vault-claude-md.sh` (lines 577–583) | Section A re-record during onboarding (`/onboard --section a`) |

Both paths use identical 7-token substitution logic. The rendered result is written atomically (tmpfile + rename) and post-write validated.

---

## See also

- [`adopt.md`](adopt.md) — full `/adopt` skill reference; how the template is consumed
- [`personalization-model.md`](personalization-model.md) — the three-tier model this template lives in (Combined tier)
- [`adding-a-vault-file-type.md`](adding-a-vault-file-type.md) — the 5-surface commit pattern when governance changes require template updates
