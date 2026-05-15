---
type: reference
description: Folder and file naming conventions the vault parses. Date-prefix patterns, slug grammar, vault-root allowlist, plan slug format, parent_plan inheritance, gitignore patterns.
provides:
  - naming-rules
  - folder-allowlist
  - plan-slug-format
  - date-prefix-patterns
updated: 2026-05-13
max_lines: 250
tags: ["#scope/reference"]
---

> **Summary:** Authoritative reference for the folder and file naming conventions the vault parses. Covers the three date-prefix patterns, the shared slug grammar (folder-name + tag-value parity), the vault-root allowlist, plan slug format with numeric prefix discipline, the parent_plan inheritance rule for sub-task files, and the gitignore patterns at-depth. Hand-authored narrative spoke; R-37 lockstep peer of `governance/naming-rules.json`.
> **Canonical for:** naming-rules, folder-allowlist, plan-slug-format, date-prefix-patterns
> **Last substantive update:** 2026-05-12

# Vault Architecture — Naming

Names are parsed. The system extracts structure from file paths and names — date, archetype, slug, lineage — and the extraction works only when the conventions hold. A meeting note saved as `MeetingNotes 2026-05-12.md` instead of `2026-05-12-meeting-notes.md` still renders in Obsidian and still resolves wikilinks; what it loses is *system legibility* — chronological sort with peers, date-regex matching for librarian walks, roll-up into time-ordered dashboard queries. The file does not break; the system's ability to reason about the file breaks. The conventions here are contracts, not preferences, and they hold because Claude writes filenames on capture (capture-is-cheap commitment); hand-typed names are the documented exception. The long-form research narrative — six structural commitments, anti-pattern catalogue, closed questions — lives at the canonical [`file-naming-conventions.md`](https://stem.peter.dev/research/vault-construction/file-naming-conventions/) packet on the documentation site.

## Date-prefix patterns

Three patterns cover every dated artifact the system writes. Each is paired with at least one parser; the parser is what makes the pattern load-bearing.

| Pattern | Granularity | Used for | Consumers |
|---|---|---|---|
| `YYYY-MM-DD-slug.md` | Daily | Meeting notes, daily logs, digest runs, dated reference entries | Dashboard time-range queries; digest aggregation walker; librarian `meeting-index`; `reconcile-day` skill |
| `YYYYMMDD-HHMMSS-slug.md` | Second | Log files from skills, crons, lifecycle hooks (>1 emission per day) | Log rotation crons; `session-register.sh` SessionStart walker; per-session checkpoint rotation |
| `YYYY-MM-DD-NN-slug.md` | Daily + ordinal | Multi-event days where slug alone cannot disambiguate | Rare; intra-day disambiguation usually handled by descriptive slugs |

ISO-8601 date prefixes give chronological order natively in `ls`, `find`, `grep`, and Obsidian's file tree — lexicographic sort matches time order without a separate index. Date-suffix patterns (`slug-2026-05-12.md`) defeat that property and break every consumer assuming time-ordered listing. Always prefix.

## Slug grammar

The slug portion of every filename and the value portion of every Structural tag follow one grammar. Shared grammar is the load-bearing payoff: a folder at `Engagements/acme-corp/` is the structural artifact, `#engagement/acme-corp` is the tag, `acme-corp` is the slug — one character set, no translation table, no casefolding bugs.

**Rules.**

- **Lowercase only.** `[a-z]` for letters. APFS is case-insensitive but case-preserving; lowercase eliminates the class of bugs where a tag query misses files casefolded differently from the filesystem.
- **Kebab-case.** Hyphen is the word separator. No underscores (reserved for archetype prefixes), no spaces (parse-hostile, wikilink-ambiguous), no camelCase.
- **ASCII alphanumeric + hyphen only.** Character set is `[a-z0-9-]`. No periods inside the slug (the only period is the extension separator), no commas, no parentheses, no Unicode.
- **Conceptual word boundaries on hyphens.** `backlog-hygiene` correct; `bckloghygiene` fails the articulation test.
- **Bounded length.** 60 characters practical; 100 characters hard ceiling.

The grammar is regex-validatable: `^[a-z0-9][a-z0-9-]*[a-z0-9]$`. Pre-write-guard's tag-validation branch enforces the value side of this grammar at write-time via R-32-taxonomy (`governance/tagging-rules.json`); the folder side is enforced by the folder-mirrors-tag invariant captured in [[Vault Architecture - Tagging]].

## Vault-root allowlist (R-04)

The set of valid top-level directories is a fixed enumeration. New top-level paths require the New Structure Checklist (R-10) plus R-37 atomic lockstep; mid-session improvisation produces orphan roots invisible to walkers.

| Allowlisted root | Purpose |
|---|---|
| `About Me` | Identity layer — career history, interaction preferences, application materials |
| `Archive` | Closed-lifecycle storage — old daily notes, completed tasks, archived logs |
| `Artefact-BD` | Business development surface — NOT a client engagement |
| `Daily` | Daily notes (`{YYYY-MM-DD}.md` + `{YYYY-MM-DD} - Briefing.md`) |
| `Dashboard` | Dashboard architecture and operations docs |
| `Engagements` | Top-level client relationships; folder-lineage anchor for consultant archetype |
| `Inbox` | Operational data surface — skills write here, dashboard reads from it |
| `Logs` | Skill scratch space — processing logs, sync records, session summaries |
| `Meetings` | Structured meeting notes (one file per meeting) |
| `Personal Initiatives` | Adopter's own products; distinct from client work |
| `Plans` | Symlink to the plan-tree root (configured by adopter; typically a sibling directory of the vault) |
| `Reference` | Cross-engagement reference (Tier 1) |
| `Skills` | Skill design specs |
| `Tags` | Obsidian tag pane metadata |
| `Vault Architecture` | Hub-spoke split (Structure, Engagements, People, Frontmatter, Tagging, Naming, Mandatory-Files, etc.) |

A small set of top-level files is exempt from the root-must-be-a-directory rule: `CLAUDE.md`, `Vault Architecture.md`, `Tasks.md`, `System Backlog.md`, `System Backlog - Archive.md`. These are documented allowlist entries; pre-write-guard honors them by name.

Pre-write-guard emits a Tier 3 advisory when a file is written to an unenumerated vault-root path. The advisory never blocks — adopter-customized archetypes legitimately add roots — but the addition should land via the New Structure Checklist so the schema, the hook, the librarian capability, and this spoke move in lockstep.

## New Structure Checklist (R-10)

Adding a new top-level directory requires the 7-item checklist before the first production write. Mid-session improvisation produces orphan roots invisible to walkers and breaks the cross-surface contract this pillar holds.

| # | Step |
|---|---|
| 1 | Declare purpose — what archetype/content the directory holds |
| 2 | Declare consumer — which skill, hook, capability, or query parses this path |
| 3 | Update `Vault Architecture.md` (or the relevant pillar spoke) |
| 4 | Add `governance/frontmatter-rules.json#types` entry + `governance/file-type-contracts/<file>.json` body-structure contract |
| 5 | Extend `pre-write-guard.sh` known-root list (R-04 allowlist update) |
| 6 | Add librarian-capability entry (placement-validation / plan-index / walker) |
| 7 | Commit R-37 atomic lockstep — all four surfaces move in one commit |

The checklist is the documented exception to mid-session improvisation. The pre-write-guard's Tier 3 advisory is the trigger to run the checklist; the R-37 atomic commit is the gate that lands the change.

## Plan slugs (R-27)

Plans live in the plan-tree root (symlinked into the vault at `Plans/`). The slug grammar is stricter than the general slug grammar because plan-tree walkers and librarian `plan-index` regeneration depend on parseable structure.

- **Descriptive kebab-case** matching the actual scope of work (e.g., `vault-system-hardening`, not an auto-generated adjective-verb-noun shame slug like `async-wiggling-donut`). The `/new-plan` skill's creation gate rejects shame slugs.
- **Numeric prefix in creation order.** Every plan gets `NN-` where `NN` is the next integer after the highest existing prefix. Gaps are not backfilled; prefixes are creation-order, not topic-grouped.
- **Sub-plans within a plan folder** use `NN-{slug}/` where `NN` is `01`, `02`, `03`… in **execution order**, not creation order.
- **Status marker required.** Every plan's top-level doc must have either a `**Status:**` header line OR a `manifest.json` with a `status` field. Missing status breaks the `librarian plan-index` capability.

Pre-write-guard's plan-creation block DENIES new plan-root files (depth-2 `spec.md`, `tasks.md`, `00-ideation-brief.md`, `README.md`, `manifest.json`) that lack the numeric prefix or the status marker. Sanctioned creation paths are `/new-plan <slug>` (ad-hoc scaffolding) and `/backlog-research <item>` (research-first creation).

**Whitelist:** two filenames are exempt from the plan-creation block — `ENFORCEMENT-MAP.md` (cross-cutting meta-spoke that can land at plan-root depth without the numeric-prefix discipline) and `_index.md` (index-file convention; same exemption pattern). These names pass the guard at any depth under the plan-tree root.

## Sub-plan files at depth ≥ 3 (R-28)

Sub-task files at depth ≥ 3 under the plan-tree carry `parent_plan: <top-level-slug>` in their YAML frontmatter. The value is the top-level plan slug (no path, no extension). This is the workaround for the same problem the folder-lineage convention solves for the vault: walkers cannot infer plan ancestry from directory hierarchy alone.

| Required (depth ≥ 3) | Exempt |
|---|---|
| Sub-plan session files | Plan-root files at depth 2 (`spec.md`, `tasks.md`, `00-ideation-brief.md`, `README.md`, `manifest.json`) — they ARE the parent |
| Nested sub-task files | `handoff.md` at any depth (append-only session record) |
| Plan-state files inside an existing plan directory | Files under `tests/` (synthetic fixtures, not plan state) |
| | Files under `_orchestrator/` (orchestrator runtime, not plan state) |

R-28 is a Tier 1 advisory — librarian-audit only; drift surfaces as findings, not write-time block. Escalation to pre-write-guard is contingent on drift recurring despite sanctioned creation paths.

## Gitignore patterns at-depth (R-20)

Gitignore patterns matching directory names at any depth must use the `**/` prefix. Bare-name patterns match only at repo root; `**/<name>/` matches anywhere in the tree.

| Pattern shape | Matches |
|---|---|
| `Tags/` | Only repo-root `Tags/` directory |
| `**/Tags/` | Every `Tags/` directory at any depth |
| `.env` | Only repo-root `.env` file |
| `**/.obsidian/workspace*.json` | Workspace files at any depth |

The default `.gitignore` for foundation-repo + adopter vaults ships with the following entries:

| Pattern | Anchor | Purpose |
|---|---|---|
| `.DS_Store` | repo-root only | macOS Finder metadata; usually scattered shallow enough that bare name suffices |
| `**/Tags/` | at-any-depth | Obsidian tag pane metadata directories |
| `.env` | repo-root only | Repo-root environment file |
| `.env.local` | repo-root only | Per-machine environment override |
| `node_modules/` | repo-root only | Node dependency tree (typically only at repo root) |
| `**/.obsidian/workspace*.json` | at-any-depth | Obsidian workspace state files at any nested vault depth |

Bare-name patterns survive only for repo-root-only artifacts. Anything that can land at depth requires the `**/` anchor.

## Anti-patterns

| Anti-pattern | What goes wrong | Preempt with |
|---|---|---|
| **Date-suffix instead of date-prefix** | `slug-2026-05-12.md` defeats lexical-chronological sort; every consumer assuming time-ordered listing breaks. | Always date-prefix. The three patterns at §Date-prefix patterns cover every dated artifact. |
| **camelCase or spaces in slugs** | APFS preserves case; query targeting `acme-corp/` misses `Acme-Corp/`. Spaces require wikilink quoting and break URL routing. | Lowercase kebab-case enforced by R-32-taxonomy on tags; folder names follow the same grammar via the folder-mirrors-tag invariant. |
| **Creating a top-level folder mid-session** | "There's no obvious home for this file" → ad-hoc top-level folder → walker invisibility → librarian flags weeks later. | Find the existing home (R-04 allowlist + R-33 placement advisory). New roots require R-10's 7-item checklist + R-37 lockstep, not mid-session improvisation. |
| **Shame slugs from auto-generators** | `async-wiggling-donut`, `gold-fashioned-hammer` — produces unsearchable plan trees and degraded `plan-index` output. | `/new-plan` and `/backlog-research` reject shame slugs at the creation gate. Rename auto-generated slugs before the first commit. |
| **Backfilling plan prefixes** | "A prefix was skipped earlier; let me renumber the gap" — breaks every cross-reference to existing plans. | Numeric prefixes are creation-order; gaps are permanent. Skip the number, do not backfill. |
| **Bare-name gitignore at-depth** | `Tags/` matches only repo root; deeper `Tags/` instances are committed silently. | Use `**/<name>/` for at-depth patterns. The default `.gitignore` ships with `**/`-anchored entries; copy that shape for new patterns. |
| **Type-prefix in filenames** | `prd-data-platform.md` duplicates `type: prd` from frontmatter; the prefix is parser-hostile and breaks the slug-grammar parity with tag values. | File class lives in `type:` frontmatter. Filenames follow the slug grammar; type information is read from YAML. |

## Where to learn more

- Long-form research narrative — six structural commitments, anti-pattern catalogue, closed questions: [`file-naming-conventions.md`](https://stem.peter.dev/research/vault-construction/file-naming-conventions/)
- Folder-lineage convention rationale: [ADR-0003](https://stem.peter.dev/decisions/0003-folder-lineage-as-fields/)
- Tag-value grammar (same grammar as slugs): [[Vault Architecture - Tagging]]
- Folder-level type and frontmatter contract: [[Vault Architecture - Frontmatter]]
- Machine-readable rule registry: `governance/naming-rules.json`
- Dual-surface governance pattern: [ADR-0005](https://stem.peter.dev/decisions/0005-two-surface-governance-dual-pattern/)
