---
altitude: system
scope: CLAUDE.md as the session-start context file every Claude Code session reads first. The ONE-CLASS mandate (vault-root only; folder-scoped + per-cluster + per-instance + engagement-level RETIRED Session 16 lock #1 2026-05-13); the index-vs-instruction split; the length discipline tied to content-length-limits.md; the cumulative eager-load cost evidence that drove retirement of the multi-class model; and the replacement read surfaces (cluster + instance `_index.md`; canonical instance files; System Governance spokes) that carry what folder-scoped CLAUDE.md classes used to carry.
validity_window: 2026-05-13..2026-11-13
source_dependencies:
  - schema: claude-stem/schemas/vault-schema.json (navigation type entry)
  - companion: ./vault-construction-principles.md
  - companion: ./_index.md-design.md
  - companion: ./mandatory-file-lock.md
  - companion: ./frontmatter-design.md
  - companion: ./content-length-limits.md
  - decision: Plan 81 SP03 Session 16 lock #1 (2026-05-13; handoff.md §Session 16)
  - decision: ../../docs/decisions/0001-tiered-compliance.md
last_reviewed: 2026-05-13
canonical_url: https://stem.peter.dev/research/vault-construction/claude-md-design/
url_stability: locked-from-2026-05-12
---

# CLAUDE.md design — session-start context the system reads first

## Theme

CLAUDE.md is the file every Claude Code session reads before doing anything else. It is loaded automatically by the platform on session start; it sets the operational frame for the session; its content determines whether Claude opens oriented to the adopter's context or oriented to a generic default. There is **exactly one CLAUDE.md class**: the vault-root file. Folder-scoped, per-cluster, per-instance, and engagement-level CLAUDE.md classes — proposed by earlier drafts of the architecture and the reference deployment's pre-correction state — are all **retired**. The one-class mandate is the structural answer to a cumulative eager-load cost problem that multi-class designs cannot solve without violating the small-and-dense discipline a session-start file requires.

The reference deployment ran a three-class model (vault-root + engagement-level + folder-scoped) through several months of practice and accumulated ~38K of eager-loaded CLAUDE.md content across 7+ files — past the documented ">5K tokens is almost always too many" Anthropic guidance for session-start auto-loaded surfaces. The retirement (Plan 81 SP03 Session 16 lock #1, 2026-05-13) collapsed that load to ~10–15K from a single file. The depth that used to live in engagement-level and folder-scoped CLAUDE.md files now lives where work actually happens: at cluster + instance `_index.md` for navigation, at the 3-file-per-bucket triad (Overview / Updates / Context) for engagement content, and at the System Governance narrative spokes for governance discipline. Each of those surfaces loads on demand when work scopes there. The session-start budget stays bounded; engagement depth stays available.

This packet codifies the one-class structure, the content standard for the vault-root CLAUDE.md file, the length discipline, the replacement-surface mapping, and the anti-patterns that the retirement was designed to preempt.

## Vision / approach — five structural commitments

### 1. Vault-root CLAUDE.md is the ONLY CLAUDE.md class

The mandate is ONE class. Vault-root `CLAUDE.md` is mandatory; everything else is retired:

| CLAUDE.md class | Status | Replacement read surface |
|---|---|---|
| Vault-root `CLAUDE.md` | **MANDATORY — the only class** | n/a (it IS the surface) |
| Folder-scoped CLAUDE.md (any folder below vault root) | RETIRED Session 16 lock #1 | Cluster + instance `_index.md`; canonical instance files |
| Per-cluster `CLAUDE.md` (e.g., `Engagements/CLAUDE.md`) | RETIRED Session 16 lock #1 | Cluster-level `_index.md` (active-instance enumeration) |
| Per-instance `CLAUDE.md` (e.g., `Engagements/<X>/CLAUDE.md`) | RETIRED Session 16 lock #1 | Instance-level `_index.md` (per-instance file enumeration); 3-file triad (Overview / Updates / Context); optional `People/` |
| Engagement-level CLAUDE.md (navigation-guide framing) | RETIRED Session 16 lock #1 | Same as per-instance row above |

Operator direction at Session 16, verbatim: *"We're not doing folder scope."* The retirement is unconditional and not gated on future evidence; the load-bearing rationale (§2) plus the operational practicality of the replacement surfaces (§4) is the case for closure.

The session-load semantics under one-class: Claude Code reads `<vault>/CLAUDE.md` automatically; deeper-scope reads happen on demand when Claude scopes work into a cluster/instance. The deeper read targets (`_index.md`, Overview/Updates/Context) are referenced by name in vault-root CLAUDE.md but not auto-loaded; they materialize when needed.

### 2. Length discipline: 60–90 line target / 6–9K bytes / 15K hard cap

The body of vault-root CLAUDE.md targets **60–90 lines** by line count and **6–9K bytes** by file size, with a **15K-byte hard cap (150 lines)** triggering a librarian `claude-md-bloat` finding. Length is canonical at the companion packet `content-length-limits.md`; this packet propagates the threshold and explains why.

**Why the ceiling.** Vault-root CLAUDE.md loads on every session start — every single one. Multiple convergent sources establish the ceiling:
- **Anthropic developer guidance**: ">5K tokens is almost always too many" for auto-loaded session-start surfaces.
- **HumanLayer best-practices** (humanlayer.dev/blog/writing-a-good-claude-md): target <60 lines; failure mode cited — heavy CLAUDE.md triggers Claude's "context may or may not be relevant" deprioritization heuristic, causing Claude to **ignore** CLAUDE.md content.
- **Bijit Ghosh instruction-slot research** (Medium May 2026): ~150-200 reliable instructions per session, ~50 already consumed by Claude Code's system prompt = **~100-150 usable**. Heavy CLAUDE.md exhausts the budget; adherence degrades.
- **2026 community convergence** (AGENTS.md, Cursor `.cursor/rules/*.mdc`, GitHub Copilot path-scoped instructions): small root file + path-scoped / topic-scoped satellites is the universal pattern.

A 500-line vault-root CLAUDE.md burns context every session AND degrades adherence even on the content that is loaded. The structural fix is to keep vault-root CLAUDE.md small AND route Claude to the on-demand surfaces (`_index.md` + canonical instance files + System Governance spokes + governance JSON registries) when work scopes deeper.

**Length-vs-byte discipline.** When the byte threshold and the line target diverge for a specific deployment (e.g., a vault with long bulleted lines), **the byte threshold wins** — it's the operational measurement that matters at session-load time. The 200-line target is the lines-equivalent at typical line width; bytes is the authoritative ceiling.

**Reference-deployment empirical state pre-correction.** ~38K bytes of CLAUDE.md content was eager-loaded across 7+ files (vault-root + engagement-level + per-instance + folder-scoped). That state was a structural failure of the multi-class model: each individual file passed its own length target while the cumulative eager-load cost violated the Anthropic guidance. The one-class collapse is the structural fix.

**Enforcement.** R-32 + R-37 governance hooks watch the vault-root file size at write-time; the librarian's `claude-md-bloat` finding surfaces at the next cron run if the cap is exceeded; placement-validate rejects writes of `CLAUDE.md` at any path below vault root.

### 3. Index, not depth — CLAUDE.md points at depth; depth lives elsewhere

Vault-root CLAUDE.md is the **index**, not the **depth**. It carries:

- Identity / role / contractual frame (one paragraph)
- Active engagements + personal tracks (bulleted, one-line summaries pointing at canonical instance files for depth)
- Top 5–10 key files (one-line purpose each)
- Session-level operational rules (file-automatically, ask-before-creating, log-scratch-freely, historical-data-frozen, etc.)
- Vault structure tree (compact ~25–40 lines)
- Pointers (wikilinks + one-line gloss) to: `System Governance.md`, the 5 governance spokes, the schemas, the Skills index, the Plans index
- Tagging taxonomy enumeration (compact: dimension list + current canonical values only)
- Behavioral conventions
- Communication style (one paragraph + optional pointer to an adopter-profile preferences file if the adopter maintains one)

It does **NOT** carry:

- Engagement-specific terminology, people, projects, status (lives at the cluster's instance-level Overview/Updates/Context + `_index.md`)
- Project-level technical detail (same)
- Schema definitions (live in `governance/frontmatter-rules.json` + the Frontmatter spoke; `schemas/vault-schema.json` dissolved SP13 T-4)
- Full tag taxonomy discipline (lives at the Tagging spoke; CLAUDE.md carries enumeration only)
- File-class content standards in full (live at the Frontmatter spoke; CLAUDE.md may carry an operational quick-reference subsection)
- Pre-write rule details (live at governance JSON registries; `System Governance - Enforcement.md` retired SP13 T-4)
- Plan-specific narrative or session-close summaries (live in plan-tree)

The discipline is **stateable as one rule**: every paragraph in vault-root CLAUDE.md is either operational session-start orientation or a pointer to depth elsewhere. Anything that doesn't fit one of those two roles is a candidate for relocation to a System Governance spoke, a canonical instance file, or a Reference plan-tree dossier.

### 4. The replacement read surfaces — where engagement context lives now

Under the retired three-class model, engagement-scoped sessions loaded:
- Vault-root CLAUDE.md (~150 lines)
- Engagement-level `Engagements/<X>/CLAUDE.md` (~80–150 lines)
- Folder-scoped `Engagements/<X>/Projects/<Y>/CLAUDE.md` (~50–100 lines when present)

Total: ~280–450 lines across three files at the deepest scope. Across multiple engagements + instances, the cumulative eager-load cost was the observed ~38K problem.

Under the one-class model, engagement-scoped sessions load only vault-root CLAUDE.md eagerly. When work scopes into a cluster/instance, Claude reads on demand:

| Old surface (retired) | New on-demand read surface |
|---|---|
| Engagement-level `Engagements/<X>/CLAUDE.md` (navigation guide; line counts; skip rules; status header) | Cluster-level `_index.md` (active instances + status markers) + instance-level `_index.md` (per-instance file enumeration with line counts + skip rules) |
| Engagement-level CLAUDE.md "key people" section | Instance-level `People/` subfolder (one file per stakeholder when applicable) + `People/_index.md` for the enumeration |
| Engagement-level CLAUDE.md status header | Instance Overview frontmatter `status:` field + cluster `_index.md` rollup |
| Folder-scoped (per-project) CLAUDE.md content table | Instance-level `_index.md` is the navigation surface; finer-grained navigation comes from the directory itself + `_index.md` patterns documented in `_index.md-design.md` |
| Folder-scoped CLAUDE.md "context handoff" content | Instance `<Instance> - Context.md` (one of the 3-file-per-bucket triad) |

The instance-level `_index.md` is the load-bearing replacement for what folder-scoped CLAUDE.md used to carry. It enumerates every `.md` file in the instance subtree with line counts (approximate ±20%) and skip rules where applicable. This **replaces** the navigation function previously served by folder-scoped CLAUDE.md without adding eager-load cost — `_index.md` is on-demand-read like any other vault file.

The `_index.md-design.md` companion packet codifies the full `_index.md` content shape, mandate scope (mandatory at user-facing folders + `Inbox/`; out-of-scope at `Logs/`, `Tags/`, `Archive/`, `Daily/`), and authoring discipline.

### 5. The index-vs-instruction split — separate what's loaded from what's instructed

CLAUDE.md content splits across two functions: **index** (here's what exists, where to find it) and **instruction** (here's how to operate). The split matters because index content is read-time orientation (Claude loads, learns the layout, navigates) while instruction content is write-time behavior (Claude applies the rule on every write).

Under the one-class model, vault-root CLAUDE.md carries **both functions**, but most instruction content is **delegated by reference** to the System Governance narrative spokes:

| Function | Where it lives |
|---|---|
| Index (vault structure, active engagements, key files, schemas/skills pointers) | Vault-root CLAUDE.md (in-line, compact) |
| Behavioral conventions (file-automatically, ask-before-creating, etc.) | Vault-root CLAUDE.md (in-line, one-line each) |
| Tag taxonomy enumeration | Vault-root CLAUDE.md (compact list; current values only) |
| Tag taxonomy discipline (25-cap rationale, prefix-grammar, anti-patterns) | `System Governance - Tagging.md` spoke |
| Frontmatter schema enumeration | Vault-root CLAUDE.md (one-line pointer to `governance/frontmatter-rules.json`; `schemas/vault-schema.json` dissolved SP13 T-4) |
| Frontmatter rules (per-type required + optional fields, R-32 contract) | `System Governance - Frontmatter.md` spoke |
| Naming conventions (compact summary) | Vault-root CLAUDE.md (one-line pointer) |
| Naming conventions (full discipline) | `System Governance - Naming.md` spoke |
| Mandatory-file enumeration (compact reference) | Vault-root CLAUDE.md (compact list) |
| Mandatory-file lock (full rationale + retired set) | `System Governance - Mandatory-Files.md` spoke |
| R-37 lockstep, promotion framework, structural enforcement | `governance/_index.json` (coupling declarations); `System Governance - Enforcement.md` retired SP13 T-4 |

The structural commitment: **instruction content lives at the spoke that owns the discipline**. Tag rules live at the Tagging spoke. Frontmatter rules at the Frontmatter spoke. Naming conventions at the Naming spoke. Vault-root CLAUDE.md references those spokes by wikilink + a one-line operational summary ("tags from the taxonomy; no invented tags"; "frontmatter per the schema; R-32 denies non-conforming writes"); the full discipline lives at the spoke. This keeps CLAUDE.md scannable AND keeps each instruction content surface owned by exactly one canonical location, not duplicated across CLAUDE.md plus the spoke.

The anti-pattern (which the index-vs-instruction split preempts): duplicating instruction content across multiple surfaces. A tagging rule restated in vault-root CLAUDE.md plus a Tagging spoke plus an engagement-level CLAUDE.md (under the retired three-class model) is three copies that drift independently. The discipline is: **one canonical statement at the spoke; CLAUDE.md carries the wikilink + a one-line gloss**.

## Vault-root CLAUDE.md content standard — 6-section framework

The reference structure is **6 sections, in order**, targeting **60–90 lines / 6-9K bytes** of body content. Hard cap 150 lines / 15K bytes — well under the community ~120-line ceiling (HumanLayer, Bijit Ghosh, AGENTS.md convergence). The framework follows the **JSON-for-APPLY, markdown-for-UNDERSTAND** discipline: vault-root CLAUDE.md inlines only what Claude needs for first-action behavior; everything else is delegated via `@import` directives (always-loaded) or pointers (load-on-trigger).

The 6-section framework was ratified Plan 81 SP03 Session 17 (2026-05-13). It supersedes an earlier 21-section enumerated content standard that pre-dated the post-Session-4 governance architecture (System Governance spokes + governance JSON registries). Under the post-Session-4 architecture, content classes the 21-section standard inlined (file content standards, tag taxonomy values, processing rules, vault structure tree depth, etc.) all live at canonical surfaces elsewhere — inlining them in CLAUDE.md duplicates content + creates a maintenance tax + triggers instruction-slot exhaustion (Bijit Ghosh research: ~150-200 reliable slots, ~50 already consumed by Claude Code's system prompt). The 6-section framework reverses that and pushes load to the spokes + JSON registries via pointers and one `@import` directive.

### 1. Role + Operating Posture (~3-5 lines)

One paragraph declaring Claude's role in THIS vault. Examples: "Claude operates as librarian, secretary, and agent" (consultant archetype); "Claude is the research-pipeline owner" (researcher archetype); "Claude is the strategic-document collaborator" (manager archetype). Maintenance: never changes once locked at onboarding.

### 2. User Identity (~3-5 lines)

One paragraph: name, role, contractual frame, time horizon. SP04 install.sh substitutes from the adopter's onboarding `user-manifest.json` at scaffold time. Maintenance: changes only at contract transitions (quarterly+ frequency).

### 3. Hard Rules / Behavioral Conventions (~5-10 bullets)

The non-negotiables that govern Claude's behavior across every session in this vault. Each rule is one line. Reference examples:
- File automatically when destination is clear
- Ask before creating new top-level structures
- Historical data is frozen — never overwrite past-dated content
- `Logs/` is Claude's scratch space — write freely
- Skill check: before building any capability from scratch, read `Skills/_index.md`
- When the user raises architecture-bearing questions or you need to make a judgment call on system structure, load `System Governance.md` first

Per Bijit Ghosh's instruction-slot research: aim for <10 hard rules. Each rule must change Claude's behavior — if it does not, delete it.

### 4. Communication Style (~3-5 lines)

One paragraph: tone, structure expectations, feedback style. Followed by an optional pointer to a more detailed preferences file if the adopter maintains one (adopter-profile folder per overlay-master; foundation does not ship `About Me/` per canonical §G). Maintenance: rare.

### 5. Active Work Pointers (~5-10 lines)

NOT enumerated. Pointers only, with the path stable even as contents churn. Examples:
- Active client engagements: `<cluster-folder>/` — see cluster `_index.md` for current list
- Personal tracks: `<tracks-folder>/`
- System backlog: `System Backlog.md`

Maintenance: path-stable; only changes when the adopter renames a cluster (rare; R-37 lockstep applies).

### 6. Authoritative References (~15-25 lines)

The eager-load + on-demand reference set. Two sub-blocks:

**A. `@import` directives (force-loaded at session start)**

```
@$CLAUDE_HOME/governance/foundation-master.json
```

ONE file. The composed governance bundle — R-32 type allowlist + R-47 tag taxonomy + 6 pillar registries composed at foundation-repo release time; hooks read exclusively from this bundle per bundle-at-load architecture (SP13 T-3). Small enough to amortize across the session. SP04 install.sh substitutes `$CLAUDE_HOME` to the adopter's install root (typically `~/.claude/`). Claude Code's `@import` primitive supports absolute paths and `~/` expansion per docs at code.claude.com/docs/en/memory. (Formerly `@schemas/vault-schema.json`; dissolved SP13 T-4; content migrated to governance pillars; bundle at `governance/foundation-master.json`.)

The eager-load discipline: ONLY include surfaces that are session-start critical AND small enough to amortize across the session. The 4 governance JSON registries (frontmatter-rules, tagging-rules, naming-rules, mandatory-files-rules) FAIL this test — they're per-write / per-tag / per-rare-structure-decision, not session-start critical. They're pointer-only.

**B. Pointer table (load on trigger)**

| Trigger | Primary read (APPLY) | Rationale read (UNDERSTAND) |
|---|---|---|
| Architecture-bearing question (what is the system; why this way) | `System Governance.md` | — (the manual IS the rationale) |
| Authoring/editing a vault file (frontmatter conformance) | `$CLAUDE_HOME/governance/frontmatter-rules.json` | `System Governance/System Governance - Frontmatter.md` |
| Tagging a file | `$CLAUDE_HOME/governance/tagging-rules.json` | `System Governance/System Governance - Tagging.md` |
| Naming a new file or structure | `$CLAUDE_HOME/governance/naming-rules.json` | `System Governance/System Governance - Naming.md` |
| Creating new top-level structure | `$CLAUDE_HOME/governance/mandatory-files-rules.json` | `System Governance/System Governance - Mandatory-Files.md` |
| Governance hook / R-37 / promotion question | `governance/_index.json` | `System Governance - Enforcement.md` retired SP13 T-4; governance JSONs are now authoritative |
| System-project ideas; librarian/architect work | `System Backlog.md` | — |
| **Mandatory** before building any capability | `Skills/_index.md` | — |
| Inbox / connector / dashboard work | `Inbox/_index.md` | — |
| Plan or sub-plan references | `Plans/` (symlink to plan tree) | — |

The discipline encoded in this table: **JSON for APPLY (machine-readable, applied per-write/per-tag/per-structure), markdown spoke for UNDERSTAND (rationale, edge cases, pedagogy)**. Claude reads PRIMARY when applying a rule mechanically; reads RATIONALE when the user asks "why" or when judgment is required in edge cases the JSON doesn't cover.

### Length budget summary

| Section | Target | Maintenance frequency |
|---|---|---|
| 1 Role + Operating Posture | 3-5 lines | Never |
| 2 User Identity | 3-5 lines | Contract-transition |
| 3 Hard Rules | 5-10 bullets | Quarterly+ |
| 4 Communication Style | 3-5 lines | Rare |
| 5 Active Work Pointers | 5-10 lines | Path-stable; rename-driven only |
| 6 Authoritative References | 15-25 lines | R-37 lockstep when foundation governance evolves |
| **Total body** | **34-60 lines** | — |

Plus frontmatter + headers + blank lines: **total file 60-90 lines, 6-9K bytes**. Hard cap 150 lines / 15K bytes triggers librarian `claude-md-bloat` finding.

The framework collapses by ~5x from the pre-correction reference-deployment state (~38K cumulative multi-class CLAUDE.md) and by ~3x from the Session 17 reference vault-root state (286 lines / ~25K). The collapse is enabled by:
- System Governance spokes carrying governance discipline content (post-Session-4 two-surface architecture)
- Governance JSON registries carrying machine-readable rules (per-pillar JSONs)
- `_index.md` at cluster + instance levels carrying navigation (per `_index.md-design.md`)
- The `@import` primitive force-loading `governance/foundation-master.json` without inlining its content (formerly `@schemas/vault-schema.json`; dissolved SP13 T-4)
- Hard rules limited to first-action behavior (per Ghosh ~100-150 usable instruction-slot budget)

### Authoring

SP04 install.sh writes the vault-root CLAUDE.md at scaffold step 11.5 (per install.sh L565) by seeding `~/Code/claude-stem/templates/vault-claude-md-template.md` with identity substitution from the adopter's onboarding `user-manifest.json`. Foundation-repo template needs to match the 6-section framework — SP03 T-44 (scaffolded Session 17) authors the template update with R-37 lockstep coupling to this packet. The template is foundation-repo Claude-onboarding reference (Session 16 lock #5); consumed at scaffold-time, not shipped as an adopter artifact.

## What used to be in folder-scoped CLAUDE.md and where it lives now

Under the three-class model, engagement-level `Engagements/<X>/CLAUDE.md` and folder-scoped `Engagements/<X>/Projects/<Y>/CLAUDE.md` carried specific content classes. Their content maps to on-demand read surfaces in the one-class model:

**Was in engagement-level CLAUDE.md → now lives at:**

- Navigation table of every `.md` file in the engagement directory tree, with line counts + skip rules → **instance-level `_index.md`** (per-instance file enumeration). Skip rules become `- skip: <pattern> — <reason>` lines.
- Engagement status header + capacity estimate → **instance Overview frontmatter `status:` field** + cluster-level `_index.md` rollup row.
- Key People section enumerating People/ contacts → **`People/_index.md`** inside the instance + the People file frontmatter.
- Engagement vocabulary + terminology → **instance `<Instance> - Context.md`** (one of the 3-file-per-bucket triad).
- Active vs archived enumeration → **cluster-level `_index.md`** (active-instance markers; archived instances move to `Archive/`).

**Was in folder-scoped (project-level) CLAUDE.md → now lives at:**

- Project file table → **project-level `_index.md`** (the folder is itself the project; `_index.md` mandate applies per `_index.md-design.md`).
- Project-specific terminology / context → **`<Project> - Context.md`** (project-level file).
- Project status → **`<Project> - Overview.md` frontmatter `status:` field**.
- Project-specific stakeholders distinct from engagement-level → **project-local `People/` subfolder** when applicable.

The replacement pattern composes: cluster → instance → (optional) project subdirectory, each with its own `_index.md` + 3-file-per-bucket triad. The structure carries the same orientation function as the retired CLAUDE.md classes did, with two important differences:

1. **On-demand load.** `_index.md` and instance files load when Claude scopes work there, not at session start. Cumulative eager-load cost stays at ~10–15K (vault-root only) regardless of how many engagements the adopter activates.
2. **One-class consistency.** Every adopter has exactly one CLAUDE.md file. Future contributors cannot accidentally re-add engagement-level or folder-scoped CLAUDE.md instances without tripping the placement-validate audit.

## Anti-patterns

The one-class mandate and the index-vs-instruction split together preempt six recurring drift classes:

| Anti-pattern | Drift signature | Preempt with |
|---|---|---|
| Re-introducing folder-scoped `CLAUDE.md` (anywhere below vault root) | New `CLAUDE.md` files appearing in `<cluster>/<instance>/` or `<cluster>/<instance>/Projects/<Y>/` during dogfood | One-class lock; R-32 governance hook rejects `CLAUDE.md` writes outside `<vault-root>/CLAUDE.md` |
| Vault-root CLAUDE.md inlining engagement-specific depth | A section like "ACME engagement details" appearing in vault-root with multi-paragraph content because "we used to have an engagement-level CLAUDE.md and now we don't" | Replace with one-line link to `Engagements/ACME/ACME - Overview.md`; the depth lives at the canonical instance file |
| Instance-level `_index.md` authored as a mini-CLAUDE.md with operational rules | Per-instance `_index.md` grows operational instruction content ("when working on this engagement, always …") | `_index.md` is navigation only per `_index.md-design.md`; behavioral rules live at vault-root CLAUDE.md; engagement-specific behavior lives at instance `<Instance> - Context.md` |
| Vault-root CLAUDE.md grows past 15K bytes / 150 lines | New session-start auto-load cost; sections that should be at the spokes get inlined "for visibility"; instruction-slot exhaustion (Ghosh research) degrades adherence on remaining rules | Length cap enforced by librarian `claude-md-bloat` finding; 6-section framework discipline tells you what to move; companion `content-length-limits.md` codifies the threshold |
| 21-section enumerated content standard (engagement list, key files, processing rules, file content standards, tag taxonomy values, vault structure tree all inlined) | Maintenance tax accumulates daily/weekly (engagements churn, tasks change, taxonomies evolve); CLAUDE.md becomes a lie Claude reads; deprioritization heuristic kicks in | 6-section framework (Role / User / Hard Rules / Communication Style / Active Work Pointers / Authoritative References); JSON-for-APPLY + markdown-for-UNDERSTAND discipline pushes content to the spokes + JSON registries; pointers replace enumerations |
| Instruction content duplicated across CLAUDE.md and the spokes | Tag rules at CLAUDE.md + Tagging spoke; frontmatter rules at CLAUDE.md + Frontmatter spoke; each drifts independently | Spoke is canonical; CLAUDE.md carries wikilink + one-line gloss; governance-parity-audit catches drift |
| Per-archetype CLAUDE.md (consultant CLAUDE.md vs researcher CLAUDE.md) | Adopter wizard proposes archetype-specific CLAUDE.md variants | Vault-root CLAUDE.md is universal; archetype variation lives in the cluster + instance + canonical-instance-file shapes per Session 16 lock #9; the wizard customizes content within the vault-root file, not the file count |

## Quality bar self-test (6 criteria)

1. **Citation required** — operator direction Session 16 lock #1 (2026-05-13) cited verbatim at §1; Anthropic ">5K tokens" guidance cited at §2; reference-deployment empirical state (~38K pre-correction) cited at §2; install.sh L565 + step 11.5 cited at §Vault-root CLAUDE.md content standard for scaffold-time authoring; `content-length-limits.md` canonical-source citation for length threshold.
2. **Scope declaration** — frontmatter declares `altitude`, `scope`, `validity_window`, `source_dependencies`, `last_reviewed`, `canonical_url`, `url_stability`. ✓
3. **Articulation test** — novice user can articulate after reading: (a) there is exactly one CLAUDE.md, at vault root; (b) length stays at 60-90 line target, 15K / 150-line hard cap; (c) CLAUDE.md is index, not depth — it points at the System Governance spokes, governance JSON registries, and canonical instance files for detail; (d) what used to live at engagement-level CLAUDE.md now lives at instance `_index.md` + Overview/Updates/Context; (e) the 6-section framework structure (Role / User Identity / Hard Rules / Communication Style / Active Work Pointers / Authoritative References); (f) the JSON-for-APPLY, markdown-for-UNDERSTAND discipline at §6 Authoritative References; (g) `@import governance/foundation-master.json` is the ONLY eager-load directive, with all other surfaces being pointer-only (`schemas/vault-schema.json` dissolved SP13 T-4). ✓
4. **Anti-pattern coverage** — 6 anti-patterns enumerated with drift signature + preempt mechanism. ✓
5. **Decision-traceability** — three-class retirement attributed (Session 16 lock #1); replacement read surfaces enumerated against the retired classes; open questions explicit at §Open questions; closed questions named with disposition at §Closed questions.
6. **Source pointers** — every claim back-linked: companion packets cited inline; downstream consumers + memory references enumerated at §Source pointers.

## Open questions

| ID | Question | Disposition |
|---|---|---|
| **OQ-CMD-1** | Replacement-surface adequacy: does the cluster `_index.md` + instance `_index.md` + 3-file triad fully replace the orientation function that engagement-level CLAUDE.md served, or are there gap classes (e.g., engagement-specific operational rules) that need a new surface? | Defer to SP08 dogfood-harness empirical validation. If gaps surface, the candidate response is a new section in `<Instance> - Context.md` (operational rules per instance) — NOT a re-introduction of engagement-level CLAUDE.md. |
| **OQ-CMD-2** | Length-cap tightening: should the 15K hard cap drop further (e.g., HumanLayer 60-line target)? Reference deployment empirical validation forthcoming via SP08 dogfood. | Defer to SP08; the 15K cap is the Session 17 framework default; per-adopter Layer-3 overlay can tighten without foundation change. |
| **OQ-CMD-3** | Identity-substitution boundary: when SP04 install.sh seeds vault-root CLAUDE.md from `templates/claude-home-claude-md-template.md`, which sections accept onboarding-time substitution (identity, engagements, key files) vs which are foundation-locked (behavioral rules, schema enforcement reference)? | Defer to SP04 spec; T-22 sibling-integration verification confirms the substitution map. |
| **OQ-CMD-4** | Multi-vault adopters: an adopter running two Obsidian vaults (e.g., work + personal) wants different CLAUDE.md per vault — is that the same one-class mandate applied per vault, or a fork? | Same mandate per vault. The mandate is per-vault-root, not per-adopter-globally. Two vaults = two vault-root CLAUDE.md files, each carrying its own one-class. |

## Closed questions (with disposition)

| Question | Disposition |
|---|---|
| Three-class CLAUDE.md model (vault-root + engagement-level + folder-scoped) | **RETIRED Session 16 lock #1 (2026-05-13)**. Operator direction verbatim: "We're not doing folder scope." |
| Engagement-level CLAUDE.md as engagement-scope navigation guide | **RETIRED Session 16 lock #1**. Replacement: instance-level `_index.md` + 3-file-per-bucket triad. |
| Folder-scoped CLAUDE.md at project level when navigation density justifies | **RETIRED Session 16 lock #1**. Replacement: project-level `_index.md` (per `_index.md-design.md` mandate scope). |
| Loading-order semantics (vault-root → engagement-level → folder-scoped; each overrides previous) | **MOOT under one-class mandate**. Only vault-root loads at session start; deeper-scope reads are on demand. |
| Per-cluster `CLAUDE.md` (e.g., `Engagements/CLAUDE.md`) | **RETIRED Session 16 lock #1**. Cluster-level `_index.md` carries active-instance enumeration. |
| Per-instance `CLAUDE.md` (e.g., `Engagements/<X>/CLAUDE.md`) | **RETIRED Session 16 lock #1**. Per-instance navigation surface is instance-level `_index.md`. |
| Engagement-as-Skill conversion (audit-agent + main-thread hallucination Session 16) | **RETIRED Session 16 lock #7**. Engagements are CONTEXT storage (read on demand); Skills are invocable capabilities. The conflation was a category error. |
| 21-section enumerated vault-root CLAUDE.md content standard | **RETIRED Session 17 (2026-05-13)**. Structurally inconsistent with post-Session-4 governance architecture; triggered instruction-slot exhaustion + deprioritization heuristic. Replaced by 6-section framework (Role / User Identity / Hard Rules / Communication Style / Active Work Pointers / Authoritative References) with JSON-for-APPLY + markdown-for-UNDERSTAND discipline at §6 Authoritative References. |
| Eager-load System Governance.md via `@import` at session start | **RESOLVED Session 17 as pointer-only**. System Governance.md is medium-size (15-25K) prose with grep-friendly sections; eager-loading the full file to consult ~2K of relevant content is wasteful. Hard Rule #6 directs Claude to load when architecture-bearing questions surface. |
| Eager-load governance JSON registries (frontmatter-rules.json, tagging-rules.json, naming-rules.json, mandatory-files-rules.json) | **RESOLVED Session 17 as pointer-only**. Each registry is per-pillar-application, not session-start critical. Hooks (`pre-write-guard.sh`) enforce structurally regardless of Claude pre-load. Pointer + on-demand read at the moment of authoring/tagging/structure-creation. |

## Source pointers

**Companion packets** (canonical content at `claude-stem/research/vault-construction/`):
- [`vault-construction-principles.md`](./vault-construction-principles.md) — overarching rationale + four-pillar framing
- [`mandatory-file-lock.md`](./mandatory-file-lock.md) — vault-root system set including CLAUDE.md; retired-set rationale; replacement surfaces
- [`_index.md-design.md`](./_index.md-design.md) — `_index.md` content shape + mandate scope (mandatory user-facing + Inbox; out-of-scope Logs/Tags/Archive/Daily); load-bearing for §4 replacement surfaces
- [`frontmatter-design.md`](./frontmatter-design.md) — schema underpinning the vault-root CLAUDE.md frontmatter + governance hook contracts
- [`content-length-limits.md`](./content-length-limits.md) — canonical 8–15K target / 25K hard cap source; `claude-md-bloat` finding threshold
- [`enforcement-map-design.md`](./enforcement-map-design.md) — R-32 / R-37 governance hooks that enforce the one-class write-time discipline

**Downstream consumers** (bind against this packet):
- `~/Code/claude-stem/templates/vault-claude-md-template.md` — onboarding reference template SP04 consumes at scaffold step 11.5
- `~/Code/claude-stem/install.sh` step 11.5 — vault-root CLAUDE.md seed with identity substitution
- `~/Code/claude-stem/onboarding/scaffold/vault-architecture/System Governance - Mandatory-Files.md` (T-32) — narrative spoke surfaces the one-class mandate as discipline
- `~/Code/claude-stem/onboarding/scaffold/vault-architecture/System Governance - Enforcement.md` (T-32) — thin meta-spoke for R-32 / R-37 lockstep (retired SP13 T-4; enforcement context now in governance JSON registries + `governance/_index.json` coupling declarations)
- SP04 wizard — surfaces the one-class mandate as part of onboarder pedagogy moment (per SP06 pedagogy spec)
- SP08 dogfood-harness — verifies no `CLAUDE.md` files exist below vault root (placement-validate assertion)

**Decision-authority sessions**:
- Plan 81 SP03 Session 16 (2026-05-13) — 13 LOCKS RATIFIED; lock #1 is load-bearing for §1 + §Closed questions
- Plan 81 SP03 Session 4 (2026-05-11) — two-surface governance architecture; load-bearing for §5 index-vs-instruction split between CLAUDE.md and spokes
- Reference deployment empirical state pre-correction (~38K cumulative CLAUDE.md load) — load-bearing for §2 length-discipline rationale

**Memory cross-references** (live `~/.claude/projects/-Users-petertiktinsky/memory/`):
- `feedback_claude_md_two_class_model` — one-class CLAUDE.md mandate (file slug retained for cross-link history; content is one-class)
- `feedback_engagement_is_context_not_skill` — engagement folders as CONTEXT not Skills; preempts the closed-question category-error
- `feedback_index_file_convention` — `_index.md` mandate scope; load-bearing for §4 replacement surfaces
- `feedback_user_defines_clusters` — system folders vs user-named cluster shapes; vault-root CLAUDE.md addresses both
- `feedback_no_live_edits_during_foundation_repo_build` — separation discipline during SP03–SP08 build
