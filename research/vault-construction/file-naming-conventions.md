---
altitude: system
scope: Folder and file naming conventions the vault parses. Date-prefix patterns, slug grammar, archetype prefixes, vault-root allowlist (R-04), plan slug format (R-27), parent_plan inheritance (R-28), .gitignore patterns (R-20). Naming as parseable contract — the substrate that lets the system extract date, archetype, slug, and lineage from a path without reading the file body.
validity_window: 2026-05-12..2026-11-12
source_dependencies:
  - Plan 81 SP03 spec §Research context packets, §Universal mandatory file enumeration, §`.gitignore` defaults (~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md L97-172)
  - Plan 81 SP03 tasks T-7 (~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/tasks.md L128-142)
  - Live ENFORCEMENT-MAP rows R-04, R-10, R-20, R-27, R-28 (~/.claude-plans/ENFORCEMENT-MAP.md)
  - Live pre-write-guard.sh known-root list (~/.claude/hooks/pre-write-guard.sh L1270 — 15-entry allowlist + 5 single-file exemptions L1277-1281)
  - Live pre-write-guard.sh R-27 plan-status enforcement block (~/.claude/hooks/pre-write-guard.sh L143-284)
  - ~/.claude/CLAUDE.md §Plan Creation Conventions (R-27 + R-28 authoritative source)
  - Live vault evidence — 54 files matching `YYYY-MM-DD-slug.md` across Logs/Meetings/Daily; live checkpoint archives at ~/.claude/hooks/state/checkpoint-YYYYMMDD-HHMMSS.md
  - Companion packet — vault-construction-principles.md §folder-mirrors-tag invariant
  - Companion packet — enforcement-map-design.md §R-XX numbering + §folder-lineage D1 resolution
  - feedback_index_file_convention.md (whitelisted-name exemptions)
  - feedback_repo_is_target_not_live_vault.md (target-state authoring posture)
last_reviewed: 2026-05-12
canonical_url: https://stem.peter.dev/research/vault-construction/file-naming-conventions/
url_stability: locked-from-2026-05-12
---

# File-naming conventions — names the system parses

## Theme

Naming is parseable. The system extracts structure from file paths and names — date, archetype, slug, lineage — and the extraction works only if the conventions hold. Naming drift is silent query drift downstream: a meeting note saved as `MeetingNotes 2026-05-12.md` instead of `2026-05-12-meeting-notes.md` still renders in Obsidian, still resolves wikilinks. What it loses is *system legibility* — chronological sort with peers, date-regex matching for librarian walks, roll-up into time-ordered dashboard queries. The file does not break; the system's ability to reason about the file breaks.

The conventions here are contracts, not preferences. Each is paired with at least one consumer — a hook that parses, a capability that groups, a query that filters, a listing that sorts. The contract holds because Claude writes filenames on capture (commitment 1 of [`vault-construction-principles.md`](./vault-construction-principles.md)); hand-typed names are the documented exception.

## Vision / approach — six structural commitments

1. **Naming is contract, not preference.** Every convention names its consumer; capture-is-cheap means the system emits names.
2. **Date-prefix patterns are time-ordered AND lexically sorted simultaneously.** ISO-8601 (`YYYY-MM-DD` or `YYYYMMDD-HHMMSS`) makes `ls`, `find`, `grep`, and Obsidian's file tree render chronological order natively.
3. **Slug grammar matches tag grammar.** Folder names, file slugs, and tag values share one character set (lowercase ASCII + hyphen). Folder-mirrors-tag invariant requires `Engagements/cdmo-ddx/` ↔ `#engagement/cdmo-ddx`.
4. **Vault-root paths are allowlisted (R-04).** 15 entries enumerated in `pre-write-guard.sh`; new roots require R-10's 7-item checklist + R-37 lockstep.
5. **Plan slugs follow R-27.** Descriptive + numeric prefix in creation order. Shame slugs rejected at `/new-plan`'s creation gate; status header / `manifest.json status` enforced at write-time.
6. **Sub-plan files at depth ≥ 3 carry `parent_plan:` (R-28).** Plan-root files at depth 2 are exempt — they are the parent. Librarian-audit only; conditional escalation if drift recurs.

## Date-prefix patterns

Three patterns cover every dated artifact the system writes; each is consumed by at least one parser.

### `YYYY-MM-DD-slug.md` — daily granularity, human-readable

Meeting notes, daily logs, digest runs, dated reference entries. Hyphen-separated ISO-8601 date; lexicographic sort matches chronological sort.

**Live evidence.** `find ~/Documents/Obsidian\ Vault -name '20[0-9][0-9]-[01][0-9]-[0-3][0-9]-*.md'` returns **54 files** across `Logs/`, `Meetings/`, `Daily/`. Sample: `Logs/2026-04-21-digest-1914.md`, `Logs/2026-04-22-digest-1017.md`, `Logs/2026-05-01-digest-0010.md`. Trailing `-HHMM` is an intra-day disambiguator that becomes part of the slug.

**Consumers.** Dashboard time-range queries; digest aggregation walker; librarian `meeting-index`; `reconcile-day` skill.

### `YYYYMMDD-HHMMSS-slug.md` — second granularity, high-frequency

Log files emitted by skills, crons, and lifecycle hooks. No hyphens inside the timestamp; chosen for compactness and unambiguous lexical sort when multiple files land in the same minute.

**Live evidence.** Checkpoint archives: `~/.claude/hooks/state/checkpoint-20260413-165851.md`, `checkpoint-20260421-204934.md`, `checkpoint-20260423-102832.md`. (Pre-2026-05-11 archives moved to per-session paths per Plan 84 SP01; convention preserved.) Also: cron logs, scraper output, any skill emitting more than one artifact per day.

**Consumers.** Log rotation crons; `session-register.sh` SessionStart walker; per-session checkpoint rotation (Plan 84 SP01).

### `YYYY-MM-DD-NN-slug.md` — multi-event days, ordinal disambiguator

Optional. Used when a slug alone cannot disambiguate multiple same-day artifacts and second-granularity is overkill. `NN` is a 2-digit zero-padded ordinal. Rare in live vault — intra-day disambiguation is usually handled by descriptive slugs.

**Anti-pattern: date-suffix instead of date-prefix.** `slug-2026-05-12.md` defeats lexical-chronological sort. `ls` returns alphabetical-by-slug; every consumer assuming time-ordered listing breaks. Always prefix.

## Slug grammar

The slug portion of every filename and the value portion of every Structural tag follow one grammar. Shared grammar is the load-bearing payoff: `Engagements/cdmo-ddx/` is the folder, `#engagement/cdmo-ddx` is the tag, `cdmo-ddx` is the slug — one character set, no translation table.

**Rules.**

- **Lowercase only.** No `Slug`, no `SLUG`, no `camelCase`. APFS is case-insensitive but case-preserving; lowercase eliminates the class of bugs where a tag query misses files casefolded differently from the filesystem.
- **Kebab-case.** Hyphen is the word separator. No underscores (reserved for archetype prefixes); no spaces (parse-hostile, wikilink-ambiguous); no camelCase.
- **ASCII alphanumeric + hyphen only.** Character set is `[a-z0-9-]`. No periods inside the slug (the only period is the extension separator), no commas, no parentheses, no Unicode.
- **Conceptual word boundaries on hyphens.** `backlog-hygiene` correct; `bckloghygiene` and `backloghygiene` fail the articulation test.
- **Bounded length.** 60 characters practical; 100 characters hard ceiling.

**Tag-value parity.** Same grammar applies to every `#dimension/value` tag. The folder-mirrors-tag invariant (D1 resolution 2026-05-11; [`enforcement-map-design.md`](./enforcement-map-design.md) §Folder-lineage convention) makes parity load-bearing — a file at `Engagements/cdmo-ddx/Projects/gold-layer-qa/` carries `engagement: cdmo-ddx` + `project: gold-layer-qa` as frontmatter fields AND `#engagement/cdmo-ddx` + `#project/gold-layer-qa` as tags. Folder-name and tag-value are the same string.

## Archetype-prefix patterns

Optional class prefixes group files by kind; the system parses them to route, filter, and audit.

| Prefix | Pattern | Used for | Live example |
|---|---|---|---|
| `00-` | `00-ideation-brief.md` | Plan anchor doc — numeric-zero prefix marks it as the brief, distinguishable from `NN-` sub-plans in execution order | `~/.claude-plans/81-claude-stem-dogfood-optimization/00-ideation-brief.md` |
| `_` | `_index.md`, `_session-*.md` | Per-folder index (see [`_index.md-design.md`](./_index.md-design.md)); session ledgers under a plan tree | `~/Documents/Obsidian Vault/Engagements/CDMO DDX/_index.md` |
| `Session-NN-` | `Session-04-architecture-decision.md` | Numbered session artifacts inside a sub-plan; lexical-chronological alongside spec/tasks/handoff | `~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/Session-04-architecture-decision.md` |
| Bare slug | `backlog-progress/<slug>.md` | Backlog-progress satellites (sentinel pattern) — no date prefix because the file is *overwritten* with current-state pointer, not appended | `~/Documents/Obsidian Vault/Logs/backlog-progress/81-claude-stem-dogfood-optimization.md` |
| `Vault Architecture - ` | `Vault Architecture - <Pillar>.md` | Narrative spokes — human-facing, hand-authored, spaces deliberate | `~/Documents/Obsidian Vault/Vault Architecture/Vault Architecture - Frontmatter.md` |

The `_` prefix sorts to the top of directory listings and signals "system-utility infrastructure, treat differently." Note: underscore-prefix alone is not an automatic exemption — a closed set of specific names (`_index.md`, `File-Index.md`, `Logs/ideation-brief-*`, `Logs/build-*`) is whitelisted in librarian and hook gates per `feedback_index_file_convention.md`. New underscore-prefix filenames do NOT inherit exemption by virtue of the prefix.

**Anti-pattern: archetype prefix without the trailing hyphen.** `Session04-...md` defeats the prefix-extracting regex. The hyphen is the boundary; without it, `Session04` is one opaque token.

## Vault-root naming allowlist (R-04)

15 entries, enforced at `~/.claude/hooks/pre-write-guard.sh:1270`. Literal list:

```
About Me        Archive            Artefact-BD        Daily          Dashboard
Engagements     Inbox              Logs               Meetings       Personal Initiatives
Plans           Reference          Skills             Tags           Vault Architecture
```

Single-file vault-root exemptions: `CLAUDE.md`, `Vault Architecture.md`, `Tasks.md`, `System Backlog.md`, `System Backlog - Archive.md`.

**Enforcement.** `pre-write-guard.sh` compares the path's first segment against the literal list and emits a Tier 3 advisory (`[NEW DIRECTORY]`) when unknown. Tier 3 is non-blocking — the write proceeds but the operator is told to move the file or update `Vault Architecture.md`.

**Adding a new root.** R-10's 7-item New Structure Checklist is the gate. Load-bearing items: declare purpose, declare consumer, update `Vault Architecture.md`, add schema entry, add hook entry, add librarian-capability entry, commit R-37 lockstep so all four governance surfaces move together. New roots appear by deliberate R-10 walk, not by drift.

**Anti-pattern: creating a top-level folder mid-session because "there's no obvious home for this file."** Find the existing home (R-04 + R-33 placement advisory) or run the R-10 walk deliberately. Mid-session improvisation produces orphan roots — vault-cleanup Plan 10 closed 22 folders of prior drift.

## Plan slug format (R-27)

Authoritative source: `~/.claude/CLAUDE.md` §Plan Creation Conventions. Hook enforcement: `pre-write-guard.sh:143-284`.

- **Descriptive slug.** Names the actual scope. `vault-system-hardening` (good); `async-wiggling-donut` (shame slug, rejected). Auto-generated adjective-verb-noun slugs from tooling defaults are explicitly forbidden — they leak from creation tools that don't honor R-27 and must be renamed before first commit.
- **Numeric prefix in creation order.** Next-available integer; never backfilled, never reordered. As of 2026-05-12, `~/.claude-plans/` runs through prefix 84.
- **Status header required.** `**Status:**` header bullet, YAML `status:` frontmatter, or `manifest.json` `status` field. Missing status breaks `librarian plan-index` regeneration of `~/.claude-plans/_index.md` grouped by Active/On-Hold/Complete/Superseded/Unknown.
- **Sanctioned creation paths.** `/new-plan <slug>` (ad-hoc) and `/backlog-research <item>` (research-first) render the canonical quartet (`spec.md` + `tasks.md` + `handoff.md` + `00-ideation-brief.md`) + `manifest.json` from templates and assign the next prefix automatically. Hand-creating a plan directory bypasses the creation gate and the shame-slug regex.

**Enforcement scope.** Hook matches `~/.claude-plans/*.md` (flat root), `~/.claude-plans/*/spec.md`, `~/.claude-plans/*/00-ideation-brief.md`, `~/.claude-plans/*/README.md`, `~/.claude-plans/*/manifest.json`. Sub-plan files (depth ≥ 2) inherit from parent per R-28.

## Sub-plan `parent_plan:` inheritance (R-28)

Authoritative source: `~/.claude/CLAUDE.md` §Plan Creation Conventions item 5. Drift surface: librarian `plan-parent-resolve` capability.

**Convention.** Files at depth ≥ 3 under `~/.claude-plans/` MUST carry `parent_plan: <top-level-slug>` in YAML frontmatter. Value is the top-level plan slug (no path, no extension). Examples:

- `~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/_session-2026-05-12-research-execution.md` → `parent_plan: 81-claude-stem-dogfood-optimization`
- `~/.claude-plans/57-spine-remediation/24-parent-plan-inheritance-and-master-initiative-migration/spec.md` → `parent_plan: 57-spine-remediation`

**Exemptions.** Plan-root files at depth 2 (`spec.md`, `tasks.md`, `handoff.md`, `00-ideation-brief.md`, `README.md`, `manifest.json`) — they *are* the parent. `handoff.md` at any depth (append-only). Files under `tests/` and `_orchestrator/`.

**Enforcement posture.** Librarian-audit only, not pre-write-guard. Mirrors Session 23's shame-slug precedent — formalize the convention, surface drift, escalate to write-time block only if drift recurs. Convention was in informal use in 62 spine-remediation session files before Session 24 formalized it; formalization of organic practice, not retrofit.

## `.gitignore` patterns (R-20)

Naming-adjacent rule: gitignore patterns matching directory names *at any depth* must use the `**/` prefix. `Tags/` alone matches only vault-root `Tags/`; `**/Tags/` matches anywhere in the tree.

**Provenance.** Spine-remediation Session 08 learned the rule in-session — 113 files leaked in the initial commit before catch.

**Foundation-repo defaults (D3 resolution, 2026-05-11).** Ships `.DS_Store`, `Tags/` (Make.md plugin artifacts), adopter-disposable patterns. SP04 install.sh extends the adopter's vault `.gitignore` at install time. Both adopter and foundation layers carry their own `.gitignore`; Peter's live vault keeps `Tags/` locally but never ships them.

**Enforcement.** Documentary only per ENFORCEMENT-MAP §Single-layer rules. Narrow and well-known post-Session 08; custom linter is disproportionate. Promote to pre-commit hook if drift recurs.

## Whitelisted-name exemptions

Per `feedback_index_file_convention.md`, the following filenames are legitimate infrastructure and bypass the standard archetype taxonomy:

- `_index.md` — per-folder index (see [`_index.md-design.md`](./_index.md-design.md))
- `File-Index.md` — engineering + project file index
- `Logs/ideation-brief-*.md` — pre-2026-04-13 symlink artifacts (read-only history; not relocated or deleted)
- `Logs/build-*` — legacy build-log naming

Closed set. New filenames are NOT auto-whitelisted; additions go through R-37 lockstep.

## Anti-patterns

| Anti-pattern | What goes wrong | Preempt with |
|---|---|---|
| **Camelcase or PascalCase filenames** | Tag-grammar mismatch — folder name and tag value diverge in casing. APFS case-insensitivity masks the bug locally; queries on case-sensitive systems silently miss files. Folder-mirrors-tag invariant collapses. | Lowercase + kebab-case grammar; system writes filenames on capture; templates ship pre-cased. |
| **Date-suffix instead of date-prefix** | `slug-2026-05-12.md` defeats lexical-chronological sort. Every consumer assuming time-ordering on directory listing breaks. | Always prefix with ISO-8601. Skills emit the prefix; templates include it; reviewers check it. |
| **Shame slugs** (auto-generated adjective-verb-noun) | `async-wiggling-donut` tells the operator nothing about scope. Plan-index, backlog routing, search-by-name all degrade. | `/new-plan` rejects shame-slug regex at the creation gate. R-27 names the failure pattern explicitly. |
| **Spaces in system-emitted filenames** | Shell-quoting hostile downstream — every cron, scraper, skill consumer must double-quote paths. Wikilink behavior becomes ambiguous. | Spaces forbidden in system-emitted filenames. Human-titled narrative documents (`Vault Architecture.md`) are documented exception; spaces appear there deliberately. |

## Open questions

- **OQ-N1** (deferred to SP04 design): archetype-template naming for adopter scaffolds. Narrative-spoke filenames (`Vault Architecture - <Pillar>.md`) use spaces and title case as human-facing reading material. SP04 must decide whether adopter-side spokes follow verbatim or adopt a parseable alternative. Likely answer: verbatim (the spoke pattern is deliberate); flag for SP04 reviewer.
- **OQ-N2** (deferred to T-26 `naming-rules.json` authoring): exact JSON shape for encoding R-04 known-root entries, R-27 plan-slug regex, R-28 parent_plan resolver — pillar-JSON schema constraints (`enforcement-map.schema.json`) lock the field set at T-1 close.

## Closed questions (with disposition)

- **CQ-N1** Should date-prefix granularity be uniform across all artifacts? → **No — two patterns coexist.** `YYYY-MM-DD-slug.md` for human-readable daily artifacts; `YYYYMMDD-HHMMSS-slug.md` for high-frequency system emission. Rationale: daily granularity sufficient for human-authored content; second granularity required where multiple emissions per minute are common. Both preserve lexical-chronological sort. Decided organically through live use; documented here.
- **CQ-N2** Should plan slugs be allowed without numeric prefixes during initial draft? → **No — prefix at creation.** Decided spine-remediation Session 22 (R-27 landing 2026-04-14). Missing prefix breaks plan-index; missing status breaks plan-index status grouping. Both gate at write-time. Sanctioned creation paths emit prefix automatically; no "draft" mode exempts it.
- **CQ-N3** Should sub-plan files (depth ≥ 3) repeat the parent's numeric prefix in their filename? → **No — `parent_plan:` frontmatter inheritance.** Decided spine-remediation Session 24 Phase 1 (R-28 landing 2026-04-14). Repeating the prefix in the filename adds noise without disambiguation; the frontmatter field is the structural answer. Librarian walks frontmatter, not filenames, to resolve plan ancestry.
- **CQ-N4** Should the foundation-repo target-state preserve the narrative-spoke filename pattern (`Vault Architecture - <Pillar>.md` with spaces and title case)? → **Yes — verbatim port.** Decided Plan 81 SP03 spec authoring (§Universal mandatory file enumeration, D4 resolution 2026-05-11). The spoke pattern is deliberate human-facing reading material; spaces are documented exceptions. Per `feedback_repo_is_target_not_live_vault.md`, target-state authoring tracks the canonical convention, not live drift.

## Source pointers

- **Plan 81 SP03 spec** — Research context packets / Universal mandatory file enumeration / `.gitignore` defaults: `~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md` L97-172
- **Plan 81 SP03 tasks** — T-7 definition: same plan / `tasks.md` L128-142
- **ENFORCEMENT-MAP rows** — R-04 L28; R-10 L34; R-15 L39 (plans backlog + sub-plan exemption); R-20 L44; R-27 L52; R-28 L51: `~/.claude-plans/ENFORCEMENT-MAP.md`
- **Live pre-write-guard.sh** — R-04 known-root list literal: `~/.claude/hooks/pre-write-guard.sh:1270` (15-entry allowlist + 5 single-file exemptions L1277-1281); R-27 plan-status enforcement: same file L143-284
- **CLAUDE.md** — R-27 + R-28 + sanctioned creation paths: `~/.claude/CLAUDE.md` §Plan Creation Conventions
- **Live vault evidence — date-prefix counts** — `YYYY-MM-DD-slug.md` pattern: 54 files (Logs/ + Meetings/ + Daily/). Checkpoint archives: `~/.claude/hooks/state/checkpoint-*.md` series
- **Live vault evidence — vault-root structure** — 15 directories matching R-04 allowlist exactly: `ls -d ~/Documents/Obsidian\ Vault/*/` (verified 2026-05-12)
- **Companion packets** — `~/Code/claude-stem/research/vault-construction/{vault-construction-principles,enforcement-map-design,_index.md-design}.md`
- **Memory** — `feedback_index_file_convention.md` (whitelisted-name exemptions); `feedback_repo_is_target_not_live_vault.md` (target-state authoring)
