---
altitude: system
scope: What the Claude Stem vault architecture optimizes for, who it's for, and the structural commitments that produce the outcome. Establishes the four-pillar framing (Frontmatter / Tagging / Naming / Mandatory-Files) at principle level before each pillar is detailed in its own packet. Anchors the other 8 system-altitude packets in a single rationale.
validity_window: 2026-05-12..2026-11-12
source_dependencies:
  - Plan 81 SP03 spec §Theme statement (~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md L19-25)
  - Plan 81 SP03 spec §Multi-archetype handling (same file L223-236)
  - Plan 81 SP03 spec §Anti-patterns to preempt (same file L289-301)
  - Plan 81 SP03 spec §Success criteria — 9-criteria articulation set (same file L303-317)
  - Plan 81 SP03 spec §Universal mandatory file enumeration (same file L152-172)
  - Plan 81 SP03 Session 4 architecture decision (~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/Session-04-architecture-decision.md, Peter-approved 2026-05-11)
  - Plan 81 SP03 D1 + D2 resolutions (~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/handoff.md Session 4 follow-up L1044-1120)
  - Companion packet — enforcement-map design (~/Code/claude-stem/research/vault-construction/enforcement-map-design.md, T-9 close 2026-05-12)
  - Companion packet — UX primitives (~/Code/claude-stem/research/vault-construction/ux-primitives.md)
  - Peter's vault operating philosophy (~/.claude/projects/-Users-petertiktinsky/memory/user_peter_vault.md, last_verified 2026-04-11; verified against live vault structural posture this session)
  - Peter's tagging research treatment (~/Documents/Obsidian Vault/Vault/Logs/foundations-docs/07-the-tagging-taxonomy.md, 137-line treatment with citations to Hedden, Forte, Dubois, Adobe AEM, SharePoint)
  - Peter's live vault structural posture (top-level Engagements/, Personal Initiatives/, Artefact-BD/, About Me/, Logs/, Inbox/)
last_reviewed: 2026-05-12
canonical_url: https://stem.peter.dev/research/vault-construction/vault-construction-principles/
url_stability: locked-from-2026-05-12
---

# Vault construction principles — what the architecture optimizes for

## Theme

A vault is not a notes app and it is not a wiki. It is the operational database that a single human and their AI collaborator both write to, read from, and reason over. The architecture in this set of packets — frontmatter schema, faceted tagging taxonomy, naming conventions, mandatory-file lock, governance enforcement — is shaped by one operational target: **the human captures freely, and the system organizes structurally on capture.** Filing, tagging, routing, and lifecycle management are the system's job. The human's job is to think, decide, and produce.

This is Peter's vault — instantiated, dogfooded, and load-bearing across consulting engagements, personal initiatives, an Artefact business-development surface, and a four-week-old active dual-surface governance proof-of-concept. The architecture is also replicable: SP04 ships a generative scaffold that infers an adopter's archetype, proposes a personalized structure, and lands a working vault on day one. The same principles apply at both poles, because the operational target — capture cheap, organize structurally, never lose history — does not change between practitioners.

The architecture refuses three temptations that recurrently kill knowledge systems. First: treating the schema as documentation that ought to be honored rather than as machine-enforced contract. Second: forcing a single archetype on a multi-archetype reality — the consultant who is also a researcher who also writes essays on the side. Third: collapsing the dual navigation surfaces — folders and tags — into one, sacrificing the query power of the other. Refusing these three is the design. The rest of this packet (and the eight pillar packets it anchors) is the structural argument for how.

## Vision / approach — seven structural commitments

The principles are not aesthetic; they are commitments that downstream sub-plans build against. SP04 (scaffold) consumes the structure; SP05 (auto-routing) consumes the enforcement contracts; SP06 (wizard) surfaces them as rationale during onboarding. The seven commitments below are the ones that all four pillars and all nine system-altitude packets honor in common.

### 1. Capture is cheap; Claude organizes

The single most load-bearing operating principle. The human captures freely — verbal dumps, mid-meeting notes, screenshots, half-formed ideas — and the system routes, files, tags, and lifecycle-manages on the way in. No "where does this go" decisions at capture time. The user writes *what*, not *where*. Claude proposes destination, frontmatter, tags, and links; the user reviews and confirms (propose-and-confirm; see [`ux-primitives.md`](./ux-primitives.md)). The principle is anti-friction by construction — a system that asks the user to file before they capture punishes the capture rate, which is the only failure mode that loses the audit trail.

The principle scales because every pillar reinforces it. Frontmatter is generated, not hand-typed. Tags are inferred from per-archetype synonym dictionaries. Mandatory files are scaffold-emitted on day one. Routing happens in-session via `/ingest` (SP05), not via folder-watching cron jobs. The user authors content; the system authors structure.

### 2. Systems thinking, not ad-hoc tooling

Every behavior the architecture exhibits comes from a generalized primitive, not a per-case patch. When a new failure class appears, the response is to add or strengthen a primitive — a hook, a librarian capability, an enforcement rule — not to write a one-off script. The two-surface governance pattern (Claude-consumed JSON registries + user-consumed narrative spokes; see [`enforcement-map-design.md`](./enforcement-map-design.md)) is the canonical example: a recurring class of governance-rule communication problem has a single structural answer, applied uniformly across all four pillars.

The discipline shows up in the rule numbering convention (R-XX is stable, append-only, citable across history), in the librarian's read-only-by-default audit capabilities (findings surface for human disposition; the system does not silently self-mutate), and in the R-37 atomic-lockstep commit pattern (governance changes touch every coupled surface in one commit, or none). Each pattern is small. Together they compose a system where new behavior lands by extending a primitive, not by accumulating exceptions.

### 3. Historical data is sacred

The vault is an audit trail. Records that captured past state at the time they were written are never overwritten. The librarian rotates, archives, and lifecycle-manages — it does not mutate. Files that move are linked from their old location; files that age out are archived, not deleted. The R-34 self-healing boundary explicitly limits automatic mutation; everything else surfaces findings for the operator to triage.

The principle has a practical edge in AI workflows. LLM-emitted rewrites of historical files lose context that future-Peter or future-Claude will need to reason about past decisions. Append-only history — handoffs, session close-outs, the ENFORCEMENT-MAP ledger, daily logs, meeting notes — is the substrate that makes the vault a reliable memory rather than a rolling snapshot.

### 4. Multi-archetype union over single-archetype forcing

Most practitioners are not one archetype. Peter is a consultant + personal-initiative builder + BD operator + writer. A researcher running a side consultancy is two archetypes plus a personal track. A developer who manages a team is two roles in one vault. The architecture composes the user's vault as the **union** of activated archetypes and personal tracks — folder tree, frontmatter schema, and tag dimensions all built from the union, not from a single primary.

The mechanism: the onboarder infers a primary archetype + 0..N secondaries + 0..N user-declared personal tracks (step 3 of the 7-step flow). Each contributes its archetype-specific frontmatter fields, its synonym-matched structural dimensions, and its folder area. Universal fields and universal dimensions (`type`, `tags`, `updated`, `#scope/*`, `#status/*`, `#log/*`) hold across all. The 25-tag-cap discipline applies across the union, with system-utility dimensions exempt (see [`tagging-strategy.md`](./tagging-strategy.md)). When the union exceeds the cap, the system surfaces a consolidation prompt rather than silently failing or silently widening the cap.

The principle is structural: it preserves user autonomy (the user defines who they are) while enforcing the disciplines that make the system queryable. Peter's live vault — `Engagements/`, `Personal Initiatives/`, `Artefact-BD/`, `About Me/` as four co-equal top-level navigational areas — is the canonical example.

### 5. Folder-mirrors-tag invariant — dual navigation, not redundancy

Folders are hierarchical. Tags are flat and overlap. The architecture commits to maintaining **both**, in parallel, with a structural invariant: every Structural dimension in the tagging taxonomy (`#engagement/*`, `#project/*`, `#initiative/*`, `#about-me/*`, `#artefact-bd/*`) maps to a corresponding folder. The duality is the design, not redundancy.

The payoff is query power. Hierarchical navigation answers "where does this file live"; tag-based navigation answers "what is this file about, across hierarchies." A meeting note for a `#scope/decision` on `#project/gold-layer-qa` under `#engagement/cdmo-ddx` is reachable from `Engagements/cdmo-ddx/Projects/gold-layer-qa/Meetings/` AND from any tag-filtered query (`#scope/decision` alone, or `#engagement/cdmo-ddx` + `#scope/decision`, etc.). Obsidian's graph view renders the tag dimension; the file tree renders the folder dimension. Lose either and the query power collapses.

The invariant is not free. It requires that frontmatter and tags propagate folder lineage (the D1 resolution, 2026-05-11; see [`enforcement-map-design.md`](./enforcement-map-design.md) §Folder-lineage convention): any file living at `Engagements/<X>/Projects/<Y>/` must carry `engagement: <X>` + `project: <Y>` as frontmatter fields AND `#engagement/<X>` + `#project/<Y>` as tags. The folder is the structural artifact; frontmatter fields + tags are the file-level workaround that propagates lineage to LLM consumers (which read frontmatter, not directory ancestry). R-32 hook enforcement holds the invariant at write-time.

### 6. Two-surface governance dual pattern

The governance layer ships across two surfaces with separate consumers but synchronized content: Claude-consumed JSON registries (loaded by hooks at runtime; deterministic; terse) and user-consumed narrative spokes (Peter's voice, pedagogy, examples, anti-patterns). R-37 atomic lockstep keeps them aligned at write-time; the librarian `governance-parity-audit` capability catches drift at audit-time. The decision is documented end-to-end in [`enforcement-map-design.md`](./enforcement-map-design.md) and load-bearing for the entire SP03 work.

The principles-altitude statement: **rules must be both teachable and enforced, and those requirements pull in opposite directions if collapsed onto a single artifact.** Narrative is bad at machine consumption (a 90K markdown table is a 23-28K-token read cost per hook lookup; see [`enforcement-map-design.md`](./enforcement-map-design.md) §Why this architecture, Lane J empirical measurement); JSON is bad at pedagogy (no voice, no examples, no anti-pattern callouts). The two-surface pattern refuses the collapse. Bounded drift is tolerated; visibility is guaranteed. Peter's live vault has run the pattern for four weeks on one pillar (frontmatter); Plan 81 SP03 scales it from one pillar to four.

### 7. Mandatory-file lock — the universal minimum

Every adopter's vault, day one, has a fixed set of mandatory files: a vault-root `CLAUDE.md`, a `Vault Architecture.md` mental-model doc, a `README.md`, a thin pointer `enforcement-map.md`, and an `Inbox/` directory of scraper aggregation files. Plus per-folder mandates: a folder-scoped `CLAUDE.md` and an `_index.md` index. Plus conditional files that ship when an adopter activates the relevant subsystem (`Logs/<subsystem>/`, `Templates/<archetype>/`, `Reference/<topic>/`). The full enumeration is locked at `mandatory-file-lock.md` (T-13) and structurally rendered via the `Vault Architecture - Mandatory-Files.md` narrative spoke (T-32).

The lock is the architectural floor. Below it, the system cannot guarantee its own invariants: `_index.md` enables folder-scoped navigation; folder-scoped `CLAUDE.md` enables in-context agent guidance; the Inbox/ surface enables scraper aggregation. Adopters can add files freely above the floor; they cannot remove the floor and expect the system to function. The minimum is small (eight items at vault root, two per folder) precisely because the architecture is opinionated about what is structural and what is preference.

## The four pillars

The four pillars are the orthogonal axes the governance system enforces, each detailed in its own packet. At the principles altitude, the pillars exist as principle-level commitments before they descend into specifics.

### Frontmatter — the API every file exposes to the system

Every vault file carries machine-readable YAML frontmatter that drives routing, lifecycle, and agent context. The schema is unified-with-per-archetype-entries: one canonical declaration of universal fields (`type`, `tags`, `updated`, `status` where applicable) plus per-archetype extension entries that name the conditional fields (`engagement`, `project`, `workstream`, `owner`, `provides`, etc.). Three compliance tiers — Strict (system files; hard fail at write-time via R-32 Tier 2 DENY), Standard (user-authored; soft warning; librarian flags drift), Minimal (explicit opt-out; flagged "outside system"). The full schema lives at `frontmatter-design.md` (T-4); the canonical JSON at `~/Code/claude-stem/schemas/vault-schema.json` (T-1).

The principle: frontmatter is contract, not decoration. The system reads it before doing anything else with a file. The fields define the file's behavior — what it routes to, how it ages, what an agent reading it should treat as authoritative.

### Tagging — faceted taxonomy with discipline

Eight-dimension faceted classification (per Peter's instantiation: Engagement, Project, Scope, Status, Initiative, Artefact-BD, About-Me, Log), with five rules: 25-tag cap on user-facing dimensions (system-utility dimensions exempt via the log-subtype registry per D2 resolution); hierarchical `#dimension/value` format; no new dimension without R-37 lockstep; no freeform tags (pre-write hook DENIES non-conforming); tagging failure surfaces as a governance signal. Per-archetype synonym-matching re-labels structural dimensions in the adopter's vocabulary (consultant's `engagement` vs developer's `repo`). The full treatment lives at [`tagging-strategy.md`](./tagging-strategy.md) (T-2), surfacing Peter's existing 137-line research treatment at `Vault/Logs/foundations-docs/07-the-tagging-taxonomy.md` with literature citations (Hedden, Forte, Dubois, Adobe AEM, SharePoint).

The principle: tags are query handles, not descriptive labels. Free-form tags become folksonomy drift. The discipline is the design.

### Naming — folder and file conventions the system parses

Folder names match tag values (folder-mirrors-tag invariant); file names follow date-prefix patterns (`YYYY-MM-DD-slug.md` for meeting notes; `YYYYMMDD-HHMMSS-slug.md` for log files); plan slugs follow R-27 (descriptive + numeric prefix in creation order); vault-root paths obey R-04 (known-root allowlist). The full pattern catalog lives at `file-naming-conventions.md` (T-7); enforced via `naming-rules.json` (T-26) and surfaced in `Vault Architecture - Naming.md` (T-31).

The principle: naming is parseable. The system extracts structure from file paths and names — date, archetype, slug, lineage — and the extraction works only if the conventions hold. Naming drift is silent query drift downstream.

### Mandatory files — the structural floor

Enumerated above as commitment 7. The full inventory plus per-file rationale lives at `mandatory-file-lock.md` (T-13).

The principle: a minimum exists below which the system cannot function. The minimum is small, enumerated, and locked.

## The articulation test — novice mental-model checkpoint

After reading this packet and the eight pillar packets — and being onboarded via the 7-step flow — a novice user should be able to articulate nine things about their own vault, in plain language, without consulting the documentation. The articulation set is the dogfood test target for SP08 and the working definition of "the onboarder succeeded":

1. **What frontmatter is for** — it drives routing, lifecycle, and agent context; the fields are the API every file exposes to the system.
2. **The folder-mirrors-tag principle** — folders and tags are dual navigation surfaces; losing either collapses query power.
3. **The cap-and-prefix discipline** — 25 distinct tag values across user-facing dimensions; `#dimension/value` hierarchical format; system-utility dimensions exempt.
4. **Research context packets** — mid-density bundles at four altitudes (System / Engagement / Topic / Initiative) that orient agents before consuming vault budget.
5. **Compliance tiers** — Strict (system files) / Standard (user-authored) / Minimal (opt-out); default Strict, opt-down preserved.
6. **The mandatory file lock** — what's at vault root, what's per folder, what's conditional, and why each item is there.
7. **Multi-archetype + personal tracks** — the system composes the union of activated archetypes plus user-declared tracks; the user doesn't pick one.
8. **Propose-and-confirm in this domain** — Claude infers structure and writes the first draft; the user reviews, tweaks, and signs off.
9. **The 7-step onboarder flow** — research-then-Q&A-then-architecture-then-scaffold; soft-mandates with coherent skip paths; iteration capped at N=3 on the architecture review step.

If a novice can articulate these nine things after onboarding, the architecture has been internalized at a level sufficient to use the system without ongoing handholding. If they cannot, the onboarder has failed and the pedagogy needs revision. The articulation set is a structural property, not a rhetorical one — SP08's dogfood harness measures against it explicitly.

## Anti-patterns the architecture preempts

Four anti-patterns recur in knowledge-system designs, and the architecture preempts each structurally. Lower-altitude anti-patterns (tier-rigidity confusion, "tags are just labels," "I'll add tags later," "research is for engineers") surface in the pillar packets and the onboarder pedagogy moments.

### "Architecture is documentation; rules are honored on a best-effort basis"

The temptation: write the schema as prose in CLAUDE.md and trust the operator (human or LLM) to honor it. The failure mode: schemas-as-prose drift the moment one operator decides "this case is different." A year in, the vault contains 1,200 files conforming to seven different evolutions of the schema, none documented, none recoverable without a hand audit.

The preempt: every rule has a structural enforcement layer — a hook, a librarian capability, a JSON Schema, a cron audit. Prose surfaces the rule for pedagogy; the layer enforces it at runtime. R-37 atomic lockstep ensures the prose and the enforcement layer stay aligned through governance changes. Pure documentation governance is rejected as a load-bearing strategy. (`feedback_structural_over_bandaid` — when a failure class recurs, build the enforcement layer; memory is band-aid where a hook would work.)

### "Folders OR tags, pick one"

The temptation: pick one navigation surface and treat the other as redundant. The failure mode: lose graph-view query power if you pick folders only; lose hierarchical context if you pick tags only. Both surfaces answer different questions; collapsing them sacrifices a dimension of query.

The preempt: the folder-mirrors-tag invariant. Every Structural-dimension tag has a corresponding folder; every folder hierarchy propagates as frontmatter fields + matching tags. Both surfaces stay populated; both queries stay answerable. R-32 hook enforcement holds the lineage propagation at write-time.

### "Pick a primary archetype; everything else is secondary clutter"

The temptation: force the onboarder to declare a primary archetype and treat secondary archetypes / personal tracks as exceptions. The failure mode: most practitioners are multi-archetype, and forcing a primary makes secondary content second-class. The consultant who also writes a Substack ends up with the Substack work fitting awkwardly into a consulting-first vault — folder placement is unclear, frontmatter is inconsistent, search across the two domains breaks.

The preempt: the union model. Onboarder infers primary + 0..N secondaries + 0..N user-declared tracks. Folder tree, frontmatter schema, and tag dimensions are all composed from the union. Universal fields hold across all. The 25-tag cap holds across the union, with consolidation prompts when exceeded — not silent failure, not silent cap-widening.

### "Frontmatter is decoration; the real content is the body"

The temptation: treat the YAML block at the top of a file as optional metadata, occasionally filled in for "important" files. The failure mode: a vault where frontmatter coverage is partial cannot route, lifecycle-manage, or surface context. Agents reading a file with missing frontmatter cannot determine its type, scope, or status — they fall back to inferring from filename or content, which is lossy and stochastic.

The preempt: frontmatter is contract. The schema is enforced at write-time (R-32 Tier 2 DENY for Strict tier; soft warning for Standard). Templates ship pre-populated. The system writes frontmatter on every generated file. The user never hand-types YAML; the user never has to remember the schema. The principle: if frontmatter is something the human has to remember to write, frontmatter coverage will be zero.

## Open questions

- **OQ-P1** (deferred to consuming sub-plans): multi-archetype overlap policy when archetypes share semantically near dimensions (consultant's `engagement` ≈ developer's `repo`; researcher's `topic` ≈ manager's `initiative`). Synonym-matching handles single-archetype re-labeling cleanly; multi-archetype overlap composition is SP04 design. Likely surfaces in T-14 (multi-archetype union spec) and SP04's archetype-composition logic.
- **OQ-P2** (deferred to SP08): the 9-criteria articulation test needs a measurement protocol — how does the dogfood harness verify each criterion is met by an onboarded user without surveying them at length? SP08 owns the operationalization; this packet locks the criteria and the rationale.

## Closed questions (with disposition)

- **CQ-P1** Should the vault architecture be **discovered** (let the adopter's existing structure dictate the shape) or **designed** (impose a canonical structure)? → **Designed, with adopter inputs.** The structure is canonical at the principle level (four pillars, folder-mirrors-tag, multi-archetype union, two-surface governance); the *instantiation* is personalized via synonym-matching, archetype composition, and personal-track declaration. Pure discovery produces folksonomy drift; pure imposition fails the autonomy test. Decided at SP03 spec authoring 2026-05-07.
- **CQ-P2** Should the onboarder force a single primary archetype? → **No — union model.** Decided at SP03 spec authoring 2026-05-07 (§Multi-archetype handling). Rationale: most practitioners are multi-archetype; forcing primacy makes the system less useful for the majority. The 25-tag cap holds across the union; consolidation prompts surface when exceeded.
- **CQ-P3** Is structural enforcement separable from pedagogy — can governance ship as JSON only, with narrative-mode left for later? → **No — two-surface dual pattern is load-bearing.** Decided Session 4 (2026-05-11; see [`enforcement-map-design.md`](./enforcement-map-design.md) §Why this architecture). Rationale: rules must be both teachable and enforced; collapsing onto a single surface produces a document that is bad at both jobs at once.
- **CQ-P4** Should historical files (handoffs, logs, daily notes, plan close-outs) be normalized to current schema retroactively when the schema evolves? → **No — append-only.** Decided as Peter's standing vault posture (R-34 self-healing boundary; `feedback_no_remembered_followups`). Rationale: historical records captured past state at the time they were written; retroactive normalization loses the audit trail. Forward changes from this point; old files stay as-is.
- **CQ-P5** Are `engagement` and `project` archetypes (TYPE values) or navigation slots (FIELD values)? → **Navigation slots, encoded as fields.** Decided 2026-05-11 (D1 resolution; audit captured in `~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/handoff.md` Session 4 follow-up L1044-1120). Empirical disposition: zero files at TYPE; 237 + 125 files at FIELD slots in Peter's vault. Folders carry the structural hierarchy; frontmatter fields + tags propagate lineage to LLM consumers.

## Source pointers

- Plan 81 SP03 spec §Theme statement: `~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md` L19-25
- Plan 81 SP03 spec §Multi-archetype handling: same file L223-236
- Plan 81 SP03 spec §Anti-patterns to preempt: same file L289-301
- Plan 81 SP03 spec §Success criteria (9-criteria articulation set): same file L303-317
- Plan 81 SP03 spec §Universal mandatory file enumeration: same file L152-172
- Plan 81 SP03 spec §Governance Architecture — Two-Surface Dual Pattern: same file L174-222
- Plan 81 SP03 Session 4 architecture decision (two-surface dual pattern, Peter-approved 2026-05-11): `~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/Session-04-architecture-decision.md`
- Plan 81 SP03 D1 + D2 resolutions (folder-lineage convention; system-utility exemption): `~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/handoff.md` Session 4 follow-up L1044-1120
- Peter's vault operating philosophy: `~/.claude/projects/-Users-petertiktinsky/memory/user_peter_vault.md` (auto-memory; structural posture verified against live vault this session)
- Peter's tagging research treatment (137 lines; citations to Hedden, Forte, Dubois, Adobe AEM, SharePoint): `~/Documents/Obsidian Vault/Vault/Logs/foundations-docs/07-the-tagging-taxonomy.md`
- Companion packet — enforcement-map design (two-surface pattern detail; R-XX numbering; hook gate categories; librarian audit pattern): `~/Code/claude-stem/research/vault-construction/enforcement-map-design.md` (T-9 close 2026-05-12)
- Companion packet — UX primitives (propose-and-confirm; soft-mandate; N=3 iteration cap): `~/Code/claude-stem/research/vault-construction/ux-primitives.md`
- Live ENFORCEMENT-MAP ledger (R-XX rule history; append-only): `~/.claude-plans/ENFORCEMENT-MAP.md`
- Live narrative-spoke PoC (the user-consumed surface this architecture scales from 1 pillar to 4): `~/Documents/Obsidian Vault/Vault Architecture/Vault Architecture - Frontmatter.md`
- Live Claude-consumed governance PoC (the JSON-registry side of the same surface pair): `~/.claude/hooks/vault-schema.json`
- Plan 81 SP03 tasks T-1..T-34 (full inventory of the work this packet anchors): `~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/tasks.md`
