---
altitude: system
scope: CLAUDE.md as the session-start context file every Claude Code session reads first. Three CLAUDE.md classes (vault-root, engagement-level, folder-scoped); the file-class contract; the index-vs-instruction split; the line-count discipline; and the loading order that lets per-engagement context override vault-root defaults without re-reading the full system manual.
validity_window: 2026-05-12..2026-11-12
source_dependencies:
  - schema: claude-stem/schemas/vault-schema.json (navigation type entry)
  - companion: ./vault-construction-principles.md
  - companion: ./_index.md-design.md
  - companion: ./frontmatter-design.md
  - decision: ../../docs/decisions/0001-tiered-compliance.md
last_reviewed: 2026-05-12
canonical_url: https://stem.peter.dev/research/vault-construction/claude-md-design/
url_stability: locked-from-2026-05-12
---

# CLAUDE.md design — session-start context the system reads first

## Theme

CLAUDE.md is the file every Claude Code session reads before doing anything else. It's loaded automatically; it sets the operational frame for the session; its content determines whether Claude opens a session oriented to the user's context or oriented to a generic default. The file is small, dense, navigational — it's an index to depth, not the depth itself. A CLAUDE.md that runs 800 lines defeats its purpose: the session loads slowly, the model burns context on metadata, and the depth it should be pointing to gets ignored because it's already loaded. A CLAUDE.md that runs 50 lines is the contract. It says: here's who the user is, here's what's loaded, here's where to look next.

Three classes of CLAUDE.md exist in a healthy vault. Vault-root `CLAUDE.md` orients every session. Engagement-level `Engagements/<X>/CLAUDE.md` orients sessions that branch into a specific engagement's work. Folder-scoped `Engagements/<X>/Projects/<Y>/CLAUDE.md` orients sessions deep inside a project. Each class has a distinct purpose, a distinct content standard, and a distinct loading discipline. Conflating the classes — putting project-level depth in vault-root, putting vault-root context in every project — collapses the discipline. The classes are the design.

## Vision / approach — five structural commitments

### 1. Vault-root CLAUDE.md is the session opener; under 200 lines

Vault-root `CLAUDE.md` is loaded on every session start. It sets the operational frame: who the user is, what engagements are active, where the key files live, what the operational rules are. The content is index-and-summary, not depth — the depth lives in `Vault Architecture.md` (the authoritative system manual) and in the engagement-level files. Vault-root `CLAUDE.md` points at depth; depth opens on demand.

The discipline is a soft line-count ceiling — under 200 lines for the body — because the load cost on every session is real. A 500-line vault-root CLAUDE.md burns context every session, including sessions that never branch into the engagement-scoped work the extra lines tried to anticipate. The fix is structural: keep vault-root CLAUDE.md small and route Claude to engagement-level files when work scopes there.

**What belongs in vault-root CLAUDE.md.** A one-paragraph identity / role / contractual frame for the user. A list of active engagements with one-line summaries (link to engagement CLAUDE.md for depth). A pointer to the system manual (`Vault Architecture.md`). The top 5-10 key files the user touches daily. The session-level operational rules (file-automatically, ask-before-creating, log-scratch-freely, historical-data-frozen). A pointer to the Skills index. The vault structure tree (compact). Behavioral conventions that apply across all engagements.

**What does NOT belong in vault-root CLAUDE.md.** Engagement-specific terminology, people, projects, status. Project-level technical detail. Schema definitions (live in `vault-schema.json`). Tag taxonomies (live in `Vault Architecture - Tagging`). Full file content standards (live in `Vault Architecture - Frontmatter`). The content that doesn't belong gets pulled into vault-root by drift — somebody added it once for visibility; nobody removed it later. The 200-line ceiling is the structural pushback against that drift.

### 2. Engagement-level CLAUDE.md is the navigation guide; loaded on engagement scope

`Engagements/<X>/CLAUDE.md` is loaded when Claude branches into engagement-scoped work. It's not loaded on every session — only when the user asks about engagement X, or when an inbox routing decision lands a file under engagement X, or when a wikilink resolves into engagement X's tree. The file's purpose is engagement-specific orientation: who's on the team, what the engagement's structure looks like, what's active vs archived, where to find what.

The content is a navigation table: every `.md` file in the engagement directory tree appears in the table or in a "Files to Skip" section with explanation. No unlisted files. The table includes line counts (approximate ±20%) so Claude can estimate read cost before loading. The Key People section enumerates everyone in `People/` with name + role + wikilink. The status header matches the engagement's Overview frontmatter `status` field.

**Why navigation, not depth.** Engagement-level CLAUDE.md is read during engagement-scoped sessions, but the actual engagement *work* happens in PRDs, Updates, Context files, meeting notes, and strategic docs. CLAUDE.md is the routing layer — it tells Claude where to look. Depth lives where the work lives. Putting depth in CLAUDE.md means the routing layer gets read every engagement session and the depth gets read again when Claude branches to the work.

The discipline at the engagement level is **completeness over compression** — every file in the engagement tree is listed or skipped, with explanation, so a future-Claude reading the navigation guide doesn't accidentally route past an existing file. Compression happens via skip rules (`Files to Skip: <pattern> — <reason>`), not via omission.

### 3. Folder-scoped CLAUDE.md is conditional; required at project level when navigation density justifies

`Engagements/<X>/Projects/<Y>/CLAUDE.md` is optional. It's required when the project has a non-trivial directory tree (e.g., multiple PRDs + Strategic + Planning + dedicated subdirs) and adopter navigation benefits from a project-level index. It's skipped when the project is small enough that the engagement-level CLAUDE.md plus the project's `Project - Context.md` handle navigation adequately.

When present, the folder-scoped CLAUDE.md mirrors the engagement-level shape but at finer granularity: every file in the project tree, line counts, skip rules, key contacts (if distinct from engagement-level), and status. The frontmatter is `type: navigation`, `engagement: <X>`, `project: <Y>`, `updated: <date>`.

The conditional discipline is the structural answer to "do we need a CLAUDE.md everywhere?" The answer is no — folder-scoped CLAUDE.md is a heavy artifact (it duplicates structure already visible in the directory tree) and the value is reading-time orientation, which only pays off when the directory is dense enough to benefit. The librarian's `placement-validate` capability flags engagement-level CLAUDE.md misalignment (R-04 + R-10 + R-37 lockstep); folder-scoped CLAUDE.md is not audited for presence, only for shape when present.

### 4. The index-vs-instruction split: separate what's loaded from what's instructed

CLAUDE.md content splits across two functions: **index** (here's what exists, where to find it) and **instruction** (here's how to operate). The split matters because index content is read-time orientation (Claude loads, learns the layout, navigates) while instruction content is write-time behavior (Claude applies the rule on every write).

Vault-root CLAUDE.md carries both functions. Engagement-level CLAUDE.md is primarily index (the structure is the value). Folder-scoped CLAUDE.md is index-only (instruction lives at the engagement level above).

**The structural commitment:** instruction content lives at the layer that owns the behavior. Tag rules live in `Vault Architecture - Tagging.md` (the tagging pillar's narrative spoke). Frontmatter rules live in `Vault Architecture - Frontmatter.md`. The Naming pillar's discipline lives in `Vault Architecture - Naming.md`. CLAUDE.md references those spokes by wikilink and gives the one-line operational summary — `tags from the taxonomy; no invented tags` — but the full discipline lives at the spoke. This keeps CLAUDE.md scannable AND keeps instruction content owned by one canonical surface (the spoke), not duplicated across CLAUDE.md plus the spoke.

The anti-pattern is duplicating instruction content: a tagging rule restated in vault-root CLAUDE.md plus engagement CLAUDE.md plus the Tagging spoke. Three copies drift independently. The discipline is: one canonical statement at the spoke; CLAUDE.md carries the wikilink + a one-line gloss.

### 5. Loading order: vault-root → engagement-level → folder-scoped; each overrides previous

Claude Code loads CLAUDE.md files in directory ancestry order: vault-root first, then any intermediate ancestor with a CLAUDE.md, then the most-specific scoped file. The loading order is the structural channel for context layering — engagement-specific rules override vault-root defaults; project-specific overrides override engagement-level.

The discipline: each layer ADDS or OVERRIDES, never DUPLICATES. Engagement-level CLAUDE.md should not restate vault-root content; it adds engagement-specific orientation. Folder-scoped CLAUDE.md should not restate engagement-level content; it adds project-specific orientation. The override semantics are implicit — the deeper layer's instruction wins for the scoped work — and the duplication anti-pattern (each layer restating the same rule for safety) collapses the override channel.

The loading order is also the read-budget primer. Vault-root CLAUDE.md is ~150-200 lines (under 200 ceiling). Engagement-level CLAUDE.md adds ~80-150 lines depending on engagement size. Folder-scoped CLAUDE.md (when present) adds ~50-100 lines. Total context at the deepest scope: ~280-450 lines of CLAUDE.md across three files. Substantially more than the vault-root alone, but the engagement + folder layers only load when work scopes there.

## Vault-root CLAUDE.md content standard

The reference structure (in order):

1. **Identity / role** — one paragraph. Who the user is, role title, current contractual frame, time horizon.
2. **Engagements** — bulleted list with one-line status. Each line includes engagement status (ACTIVE / COMPLETE / PLANNING) + capacity estimate + link to engagement CLAUDE.md.
3. **Business development** (if applicable) — separate from client engagements; one paragraph + link to BD CLAUDE.md.
4. **Personal initiatives** — adopter's own products distinct from client work; one line per initiative with link.
5. **About-me** (if applicable) — identity-layer files (career history, interaction preferences, application materials) with links.
6. **Key files** — top 5-10 daily-touched files with one-line purpose each.
7. **Claude's role** — operational frame (librarian / secretary / agent) one paragraph.
8. **Vault structure** — compact tree (~25-40 lines).
9. **Processing rules** (summary) — 3-5 lines pointing to `Vault Architecture.md` for full detail.
10. **Task rules** (summary) — 3-5 lines pointing to the Task system docs.
11. **Behavioral rules** — operational defaults (file-automatically, ask-before-creating, log-scratch-freely, historical-frozen, etc.).
12. **Vault schema enforcement** — one paragraph + pointer to `schemas/vault-schema.json` + the R-32 enforcement reference.
13. **New Structure Checklist** — the 7-item walk for new vault-root directories.
14. **Pre-write checklist** (librarian) — 3-5 lines pointing to the librarian Intake Contract.
15. **Tagging taxonomy** — bulleted dimension list with current values (compact; full discipline at the Tagging spoke).
16. **People** — top contacts with wikilinks (engagement-level depth lives in engagement CLAUDE.md).
17. **Communication style** — one paragraph + pointer to `About Me/LLM Interaction Preferences.md`.
18. **Dashboard** — one-line pointer to dashboard docs.
19. **Vault conventions** — bulleted (Obsidian-native, frontmatter, daily-note shape, etc.).
20. **Terminology** — engagement / project / task definitions if archetype-customized.

Target line count: 150-200 lines body content. Sections that grow beyond ~10 lines should be moved to a Vault Architecture spoke + replaced with a wikilink + one-line gloss in CLAUDE.md.

## Engagement-level CLAUDE.md content standard

The reference structure:

1. **Frontmatter** — `type: navigation`, `engagement: <slug>`, `updated: <date>`.
2. **Title + one-paragraph engagement summary** — what the engagement delivers, client, role.
3. **Status** — single-line status (matches engagement Overview frontmatter status field).
4. **File Navigation table** — every `.md` file in the engagement directory tree, with approximate line counts.
5. **Files to Skip section** — patterns + explanation for files that exist but aren't worth routine loading.
6. **Key People** — every file under `People/` with name + role + wikilink.
7. **Workstreams / Projects** — bulleted list with status + link to project CLAUDE.md (if present) or PRD.
8. **Current Phase** — one paragraph; what the engagement is currently doing.
9. **Recent Activity** — last 3-5 substantive events with dated entries.
10. **Engagement-specific conventions** — vocabulary, abbreviations, or rules that apply within this engagement (none if no archetype customization needed).

Target line count: 80-150 lines. Larger engagements with deep project trees may justify 200 lines; beyond that, split into per-project CLAUDE.md files at the folder-scoped level.

## Folder-scoped CLAUDE.md content standard (when present)

The reference structure:

1. **Frontmatter** — `type: navigation`, `engagement: <slug>`, `project: <slug>`, `updated: <date>`.
2. **Title + one-line project summary**.
3. **Status** — matches PRD frontmatter status.
4. **File Navigation table** — project-scoped files with line counts.
5. **Key contacts** — only if distinct from engagement-level Key People.
6. **Active work** — what's in flight in this project right now.

Target line count: 50-100 lines. Beyond 100, the navigation justification is questionable — either the project is small enough that `{Project} - Context.md` handles routing, or the project is big enough that subdividing into sub-projects is appropriate.

## Anti-patterns

| Anti-pattern | What goes wrong | Preempt with |
|---|---|---|
| **Vault-root CLAUDE.md as the system manual** | Vault-root grows past 500 lines as people add depth; session-start load cost balloons; the actual system manual (`Vault Architecture.md`) gets ignored. | 200-line ceiling on vault-root CLAUDE.md. Depth moves to `Vault Architecture.md` and to per-pillar spokes. CLAUDE.md is index. |
| **Folder-scoped CLAUDE.md everywhere** | Every project gets a CLAUDE.md whether the directory needs it or not. Maintenance burden balloons; navigation files drift out of sync with directory contents. | Folder-scoped CLAUDE.md is conditional. Only when navigation density justifies. The librarian audits engagement-level CLAUDE.md placement; folder-scoped is optional. |
| **Duplicated instruction content** | A tagging rule restated in vault-root CLAUDE.md + engagement CLAUDE.md + the Tagging spoke. Three copies drift. | One canonical statement at the spoke. CLAUDE.md carries wikilink + one-line gloss. The override channel between layers handles legitimate engagement-specific divergence. |
| **Missing files in the engagement-level Navigation table** | A file lives in the engagement directory tree but doesn't appear in CLAUDE.md's File Navigation table OR in the Files to Skip section. Claude routing past existing files. | Engagement CLAUDE.md completeness is the discipline. Every `.md` file in the tree is listed or skipped with explanation. The librarian audits this post-write. |
| **Engagement CLAUDE.md as depth document** | Engagement CLAUDE.md grows past 300 lines as people add project depth, decision history, status logs. The navigation function collapses; the file becomes another long-form document. | Engagement CLAUDE.md is navigation. Status/decision/log content lives in `Engagement - Updates.md` and `Engagement - Overview.md`. CLAUDE.md links to depth, not the depth itself. |
| **Stale People sections** | A person leaves the engagement but their CLAUDE.md row stays; Claude routes to obsolete CRM data. | Engagement People section mirrors People/ folder. Librarian flags missing or extra entries at session-close. The People file is canonical; CLAUDE.md mirrors. |
| **No status header on engagement CLAUDE.md** | Status drifts between Overview frontmatter and CLAUDE.md text. | Status header on every engagement CLAUDE.md; mirrors Overview frontmatter `status:` field. Librarian audits parity. |
| **Vault-root structure tree out of date** | New top-level directory landed; vault-root CLAUDE.md tree stays stale. | R-10 New Structure Checklist requires updating the structure tree on every new root. R-37 lockstep enforces at write-time. |

## Quality bar self-test (6 criteria)

1. **Citation required.** PASS. Companion packets cited inline (`vault-construction-principles.md`, `_index.md-design.md`, `frontmatter-design.md`). Schema artifact cited (`schemas/vault-schema.json navigation type`). ADR-0001 cited for tiered compliance.

2. **Scope declaration.** PASS. All six packet-only fields present in frontmatter; `validity_window` 2026-05-12..2026-11-12; `canonical_url` locked.

3. **Articulation test.** PASS. Five structural commitments enumerate the load-bearing premises with a *why* per commitment. Per-class content-standard sections give the concrete reference structure. Novice reader exits with: "vault-root CLAUDE.md is the small session opener; engagement-level is the navigation guide; folder-scoped is optional; loading order is ancestor-to-leaf; each layer adds or overrides without duplicating."

4. **Anti-pattern coverage.** PASS. 8-row anti-pattern table covers: vault-root-as-system-manual, folder-scoped-everywhere, duplicated-instruction, navigation-completeness, engagement-as-depth, stale-People-sections, missing-status-header, stale-structure-tree.

5. **Decision-traceability.** PASS. Loading-order commitment paired with the override channel rationale. Conditional folder-scoped CLAUDE.md called out explicitly. Line-count discipline named at each class with target ranges.

6. **Source pointers.** PASS. `source_dependencies:` frontmatter enumerates schema + 3 companion packets + 1 ADR. Inline references cite ADR-0001 + companion packets by stable filename.

Self-test verdict: 6/6 PASS at first authoring.

## Open questions

- **OQ-CM1** Auto-generation of engagement-level CLAUDE.md from directory contents — defer to librarian-capability design; placement-validate currently audits but does not generate.
- **OQ-CM2** Cross-archetype CLAUDE.md content patterns — researcher / developer / manager archetypes have different daily-touched-files distributions; the foundation-repo seed reflects consultant archetype. Adopter customization happens at install time via the onboarding wizard.

## Closed questions (with disposition)

- **CQ-CM1** Should CLAUDE.md ship with auto-generated content? → **No — hand-authored.** Rationale: CLAUDE.md content includes engagement-specific judgments (which files are daily-touched, which people are key, which conventions matter) that the auto-generator cannot infer. Templates seed the structure; humans author the content.
- **CQ-CM2** Should the line-count discipline be enforced at write-time? → **No — soft ceiling audited by the librarian.** Rationale: 200-line vault-root CLAUDE.md is a *target*, not a structural requirement. Larger files surface as `claude-md-bloat` findings at the audit; operator triages.
- **CQ-CM3** Should engagement-level CLAUDE.md be required? → **Yes when the engagement has its own folder; no for archived or zero-content engagements.** R-04 + the librarian `placement-validate` capability audits required-presence per the foundation rule.

## Source pointers

- Companion packets: `./vault-construction-principles.md` (capture-is-cheap commitment), `./_index.md-design.md` (sibling navigation surface for non-engagement folders), `./frontmatter-design.md` (`navigation` type entry frontmatter shape)
- Schema artifact: `schemas/vault-schema.json navigation` type entry
- Design rationale: [ADR-0001](../../docs/decisions/0001-tiered-compliance.md) (tiered compliance — applies to CLAUDE.md as `Strict` tier when system-emitted, `Standard` when adopter-authored)
- Runtime: Claude Code's CLAUDE.md auto-loading semantics (directory-ancestry order)
