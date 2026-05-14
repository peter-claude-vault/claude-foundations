---
altitude: system
scope: What the Claude Stem vault architecture optimizes for, who it's for, and the structural commitments that produce the outcome. Establishes the four-pillar framing (Frontmatter / Tagging / Naming / Mandatory-Files) at principle level before each pillar is detailed in its own packet. Anchors the other system-altitude packets in a single rationale.
validity_window: 2026-05-12..2026-11-12
source_dependencies:
  - schema: claude-stem/schemas/vault-schema.json
  - governance: claude-stem/governance/_index.json
  - companion: ./frontmatter-design.md
  - companion: ./tagging-strategy.md
  - companion: ./file-naming-conventions.md
  - companion: ./enforcement-map-design.md
  - companion: ./ux-primitives.md
  - companion: ./content-length-limits.md
  - companion: ./_index.md-design.md
  - decision: ../../docs/decisions/0001-tiered-compliance.md
  - decision: ../../docs/decisions/0002-unified-with-per-archetype-entries.md
  - decision: ../../docs/decisions/0003-folder-lineage-as-fields.md
  - decision: ../../docs/decisions/0004-system-utility-dimension-exemption.md
  - decision: ../../docs/decisions/0005-two-surface-governance-dual-pattern.md
last_reviewed: 2026-05-12
canonical_url: https://stem.peter.dev/research/vault-construction/vault-construction-principles/
url_stability: locked-from-2026-05-12
---

# Vault construction principles — what the architecture optimizes for

## Theme

A vault is not a notes app and it is not a wiki. It is the **operational knowledge backbone** that a single human and their AI collaborator both write to, read from, and reason over. It serves two roles simultaneously: it captures and structures the human's day-to-day work, and it stands as shared reference material that any agent, skill, or AI-assisted deliverable can build against — so that whatever the human asks AI to do, present or future, the AI has infinitely better context and produces infinitely better outputs. The vault is, in effect, the user's leverage point for getting maximum value out of AI across any goal: the well-organized substrate that makes every downstream AI workflow start from a stronger position than it otherwise would.

The architecture in this set of packets — frontmatter schema, faceted tagging taxonomy, naming conventions, mandatory-file lock, governance enforcement — is shaped by one operational target: **content lands cheaply, and the system organizes structurally on capture.** Two capture modes feed this:

- **Human capture** — verbal dumps, mid-meeting notes, screenshots, half-formed ideas. The human writes *what*, not *where*. Claude proposes destination, frontmatter, tags, and links; the user confirms (propose-and-confirm).
- **System capture** — connectors pulling data on a schedule from external sources (calendar, mail, chat platforms, meeting transcripts). Connectors emit to a known data store; the system attaches frontmatter, tags, and routing conventions on the way in. The connector layer keeps the reference material fresh without the human having to remember to update it.

Filing, tagging, routing, and lifecycle management are the system's job in both modes. The human's job is to think, decide, and produce. The system's job is to make sure that everything the human captures and everything the connectors emit becomes queryable, reasoning-ready substrate for whatever the human wants their AI to do next.

The reference deployment instantiates this architecture across consulting engagements, personal initiatives, a business-development surface, and a multi-week production validation of the dual-surface governance pattern. The architecture is also replicable: the generative scaffold sub-plan ships an onboarder that infers an adopter's archetype, proposes a personalized structure, and lands a working vault on day one. The same principles apply at both poles, because the operational target — capture cheap (human + system), organize structurally, never lose history, surface high-quality context for any downstream AI workflow — does not change between practitioners.

The architecture refuses three temptations that recurrently kill knowledge systems. First: treating the schema as documentation that ought to be honored rather than as machine-enforced contract. Second: forcing a single archetype on a multi-archetype reality — the consultant who is also a researcher who also writes essays on the side. Third: collapsing the four navigation surfaces — folders, frontmatter, tags, and wiki links — into fewer, sacrificing the query power and the consumer specialization that each surface uniquely provides. Refusing these three is the design. The rest of this packet (and the pillar packets it anchors) is the structural argument for how.

## Vision / approach — seven structural commitments

The principles are not aesthetic; they are commitments that downstream sub-systems build against. The scaffold consumes the structure; the auto-router consumes the enforcement contracts; the onboarder wizard surfaces them as rationale during user installation. The seven commitments below are the ones that all four pillars and all the system-altitude packets honor in common.

### 1. Capture is cheap; Claude organizes

The single most load-bearing operating principle. **Capture happens cheaply in two modes — human and system — and the system organizes structurally on both.**

- **Human capture.** The human writes freely: verbal dumps, mid-meeting notes, screenshots, half-formed ideas. No "where does this go" decisions at capture time. The user writes *what*, not *where*. Claude proposes destination, frontmatter, tags, and links; the user reviews and confirms (propose-and-confirm; see [`ux-primitives.md`](./ux-primitives.md)).
- **System capture.** Connectors pull data on a schedule from external sources — calendar events, mail digests, chat scrolls, meeting transcripts, etc. (see [`inbox-flow-architecture.md`](./inbox-flow-architecture.md) for the connector-brief surface and `$CLAUDE_HOME/connector-data/<slug>/` data-store contract). The system attaches frontmatter, tags, and routing conventions to every emitted artifact at the boundary. The connector layer is how the reference material stays fresh without the human having to remember to update it.

The principle is anti-friction by construction in both modes. A system that asks the user to file before they capture punishes the capture rate, which is the only failure mode that loses the audit trail. A system that requires hand-curation of connector-emitted content punishes the connector cadence, which produces stale reference material that downstream AI workflows cannot rely on.

The principle scales because every pillar reinforces it. Frontmatter is generated by the writer (human-capture skill or connector emission), not hand-typed by the human. Tags are inferred from per-archetype synonym dictionaries combined with the adopter's own vocabulary. Wiki links to canonical destinations (engagement Overview files, plan ideation briefs, related meeting notes, etc.) are proposed at write time and kept intact across renames by the librarian's rename-cascade capability. Mandatory files are scaffold-emitted on day one. Routing happens in-session via the ingest path or at connector-emission time, not via folder-watching cron jobs. The user authors content; the system authors structure.

### 2. Systems thinking, not ad-hoc tooling

Every behavior the architecture exhibits comes from a generalized primitive, not a per-case patch. When a new failure class appears, the response is to add or strengthen a primitive — a hook, a librarian capability, an enforcement rule — not to write a one-off script. The two-surface governance pattern (Claude-consumed JSON registries + user-consumed narrative spokes; see [`enforcement-map-design.md`](./enforcement-map-design.md)) is the canonical example: a recurring class of governance-rule communication problem has a single structural answer, applied uniformly across all four pillars.

The discipline shows up in the rule numbering convention (R-XX is stable, append-only, citable across history), in the librarian's read-only-by-default audit capabilities (findings surface for human disposition; the system does not silently self-mutate), and in the R-37 atomic-lockstep commit pattern (governance changes touch every coupled surface in one commit, or none). Each pattern is small. Together they compose a system where new behavior lands by extending a primitive, not by accumulating exceptions.

### 3. Historical data is sacred

The vault is an audit trail. Records that captured past state at the time they were written are never overwritten. The librarian rotates, archives, and lifecycle-manages — it does not mutate. Files that move are linked from their old location; files that age out are archived, not deleted. The R-34 self-healing boundary explicitly limits automatic mutation; everything else surfaces findings for the operator to triage.

The principle has a practical edge in AI workflows. LLM-emitted rewrites of historical files lose context that future operators (human or LLM) will need to reason about past decisions. Append-only history — handoffs, session close-outs, the enforcement-map ledger, daily logs, meeting notes — is the substrate that makes the vault a reliable memory rather than a rolling snapshot.

### 4. Multi-archetype union over single-archetype forcing

Most practitioners are not one archetype. A consultant may also run personal initiatives, manage a business-development surface, and write publicly on the side — that is four archetypes in one vault. A researcher running a side consultancy is two archetypes plus a personal track. A developer who manages a team is two roles in one vault. The architecture composes the user's vault as the **union** of activated archetypes and personal tracks — folder tree, frontmatter schema, and tag dimensions all built from the union, not from a single primary.

The mechanism: the onboarder infers a primary archetype + 0..N secondaries + 0..N user-declared personal tracks. Each contributes its archetype-specific frontmatter fields, its synonym-matched structural dimensions, and its folder area. Universal fields and universal dimensions (`type`, `tags`, `updated`, `#scope/*`, `#status/*`, `#log/*`) hold across all. The 25-tag-cap discipline applies across the union, with system-utility dimensions exempt (see [`tagging-strategy.md`](./tagging-strategy.md) and [ADR-0004](../../docs/decisions/0004-system-utility-dimension-exemption.md)). When the union exceeds the cap, the system surfaces a consolidation prompt rather than silently failing or silently widening the cap.

The principle is structural: it preserves user autonomy (the user defines who they are) while enforcing the disciplines that make the system queryable. A reference deployment with co-equal top-level navigational areas — Engagements, Personal Initiatives, BD surface, About Me — is the canonical example of the union model holding under real workloads.

### 5. Four-surface architecture — folders, frontmatter, tags, wiki links

Files in the vault are reachable via four surfaces simultaneously, each serving a different consumer (or consumer mix) and each carrying a distinct utility profile. The architecture commits to maintaining all four in parallel rather than collapsing any of them into another.

| Surface | Primary consumer | Primary utility |
|---|---|---|
| **Folder hierarchy** | Both human + LLM | "Where does this file live in the structural hierarchy?" — filesystem navigation; human directory traversal; LLM path-derived lineage as a secondary signal |
| **Frontmatter** | Claude (machine-readable YAML API) | "What is this file, what does the system do with it?" — drives routing, lifecycle, agent-readable context |
| **Tags** | User (Obsidian graph view, search, query) | "What is this file about, across hierarchies?" — facet-based query handle for category traversal |
| **Wiki links** | Both human + LLM | "What does this file connect to?" — explicit, directed cross-references the user clicks to traverse and Claude follows to scope context |

**Folder hierarchy** is the structural artifact closest to a single visible truth about how the work is organized. Humans navigate vaults via the file tree; LLMs can derive partial lineage from paths (though the architecture does not rely on path inference — frontmatter carries lineage explicitly; see below). The folder hierarchy is what everyone sees first and how everyone orients.

**Frontmatter** is primarily for Claude. The YAML block at the top of every file declares the file's type, status, lifecycle stage, lineage (which engagement / project / cluster it belongs to), tags, last-updated timestamp, and any archetype-conditional metadata. The hook layer reads frontmatter to enforce write-time invariants; the librarian reads it to audit drift; agents read it to construct context before consuming the body. The reason frontmatter is contract-not-decoration: an agent reading a file should never have to infer the file's type, scope, or status from the body, because body-inference is lossy and stochastic. Frontmatter is the explicit declaration that makes the body legible to any downstream AI workflow.

**Tags** are primarily for the user. Obsidian's graph view renders the tag dimension; the user filters by tag to query across hierarchies ("show me every `#scope/decision`"; "show me everything tagged `#project/<slug>` regardless of where it lives in the folder tree"). Tags are the user-side navigation surface — the human uses them to traverse the vault **by category**, not by location. They are not load-bearing for Claude's routing or lifecycle decisions; those run off frontmatter. Tags exist because humans navigate by concept differently than agents reason about lineage, and the human's category-query surface needs first-class support.

**Wiki links** are for both consumers. They are the explicit, directed cross-reference surface — a file declares "this content connects to `[[other-file]]`" and that link is clickable by the user in Obsidian AND followable by Claude when reasoning about the file's context. The vault-root `CLAUDE.md` is itself built on wiki links: active engagements, key files, and policy references all appear as `[[wikilinks]]` that Claude resolves to scope into the right context at session start. Skills emit wiki links to connect meeting notes to engagement Overview files, plan ideation briefs to their parent plans, action items to their source meetings, etc. The librarian protects wiki-link integrity through dedicated capabilities (`wikilink-repair`, `xref-check`, `rename-cascade`, `rename-detect`, `rename-history-sync`) — when a file moves, every wiki link pointing to it updates atomically; when a wiki link points to a missing target, the audit surfaces a repair finding.

**Tags vs wiki links — the distinction matters.** Tags **categorize** (faceted classification — "what bucket does this belong to"); wiki links **connect** (explicit reference — "what does this specifically point to"). A meeting note may carry `#scope/decision` (tag, for "show me all decisions") AND `[[Engagements/<X>/<X> - Overview.md]]` (wiki link, for "follow back to the engagement context"). Both surfaces are populated; both serve queries the other cannot answer.

**The invariant that holds the four surfaces together.** Every file's tag set mirrors its folder location, every file's frontmatter declares its lineage as explicit fields, and every wiki link's target survives across moves (via librarian rename-cascade). A meeting note living at `Engagements/<X>/Projects/<Y>/Meetings/2026-05-13.md` carries:
- Folder lineage: `Engagements/<X>/Projects/<Y>/`
- Frontmatter fields: `engagement: <X>`, `project: <Y>`
- Tags: `#engagement/<X>`, `#project/<Y>`
- Wiki links: `[[Engagements/<X>/<X> - Overview.md]]`, `[[Engagements/<X>/Projects/<Y>/<Y> - Updates.md]]`

The folder is the structural artifact; the frontmatter fields propagate lineage to Claude; the tags propagate the same lineage to the user's graph view; the wiki links create explicit traversal paths that both human and Claude follow to expand context. R-32 hook enforcement holds the frontmatter + tag invariants at write-time; the librarian's rename-cascade + xref-check capabilities hold the wiki-link invariants over time (see [`enforcement-map-design.md`](./enforcement-map-design.md) §Folder-lineage convention and [ADR-0003](../../docs/decisions/0003-folder-lineage-as-fields.md)).

Collapsing any of the four surfaces breaks a query. Folder-only navigation loses graph-view filtering across hierarchies AND loses explicit cross-references. Tag-only navigation loses the structural hierarchy AND directed traversal. Frontmatter-only files are illegible to humans. A vault without wiki links forces both human and Claude to re-derive every cross-reference from path or content inference — lossy and slow at human speed, lossy and stochastic at agent speed. The four surfaces hold because each one does what the others cannot.

### 6. Two-surface governance dual pattern

The governance layer ships across two surfaces with separate consumers but synchronized content: Claude-consumed JSON registries (loaded by hooks at runtime; deterministic; terse) and user-consumed narrative spokes (voice, pedagogy, examples, anti-patterns). R-37 atomic lockstep keeps them aligned at write-time; the librarian `governance-parity-audit` capability catches drift at audit-time. The decision is documented end-to-end in [`enforcement-map-design.md`](./enforcement-map-design.md) and [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md), and is load-bearing for the entire governance layer.

The principles-altitude statement: **rules must be both teachable and enforced, and those requirements pull in opposite directions if collapsed onto a single artifact.** Narrative is bad at machine consumption (a single ~90K markdown ledger imposes a 23–28K-token read cost per hook lookup with section-of-interest ratio under 10%; see [`enforcement-map-design.md`](./enforcement-map-design.md) §Why this architecture); JSON is bad at pedagogy (no voice, no examples, no anti-pattern callouts). The two-surface pattern refuses the collapse. Bounded drift is tolerated; visibility is guaranteed. The reference deployment ran the pattern at single-pillar scale (frontmatter) through multi-week production validation; the architecture generalizes it from one pillar to four.

### 7. Mandatory-file lock — the universal minimum

Every adopter's vault, day one, carries a 14-item system set at root, scaffolded by the onboarder's install pass: 5 files + 7 folders + 2 symlinks. The set is grounded in Session-02b §A.1 (Peter Message 1 + Message 2 universal-kit inventory) + §A.2 infrastructure dig + Session 4 two-surface governance + Session 16 13-lock ratification + Session 18 Option B reshape. Beyond the system set, the adopter activates user-defined clusters (foundation mandates the SHAPE; user defines the NAME) and personal tracks (user-named, user-shaped).

**System files at vault root (5):**

| File | Purpose |
|---|---|
| `CLAUDE.md` | Vault-root operational frame loaded at every session start. ONE-CLASS only (no deeper CLAUDE.md scopes) |
| `Vault Architecture.md` | Authoritative system manual — copy of the foundation's mental-model doc |
| `System Backlog.md` | Vault-root index of Claude-system projects; librarian-maintained. Companion archive at `Archive/System Backlog - Archive.md` |
| `Tasks.md` | THE single task list (table format; Responses + Deliverables sections); sole writer of vault checkboxes; OR-merge survivorship with connector emissions (user edits win) |
| `enforcement-map.md` | Thin pointer (≤2K) indexing the 5 narrative spokes + foundation `governance/` JSON registries. **At vault root**, NOT inside `Vault Architecture/` (per Session 4 two-surface governance decision) |

**System folders at vault root (7):**

| Folder | Purpose |
|---|---|
| `Vault Architecture/` | Container for the 5 narrative spokes: Frontmatter / Tagging / Naming / Mandatory-Files / Enforcement (thin meta-spoke) |
| `Inbox/` | Connector-brief surface — per-connector briefs + active-connection `_index.md`; connector DATA lives outside vault at `$CLAUDE_HOME/connector-data/<slug>/` by default (see [`inbox-flow-architecture.md`](./inbox-flow-architecture.md)) |
| `Archive/` | Cold storage for closed engagements + retired plan trees; hosts `Archive/System Backlog - Archive.md` |
| `Logs/` | System-emitted logs only (session-close, digest-run, backlog-progress, etc.) |
| `Daily/` | Date-keyed daily notes (optional / lifecycle-driven) |
| `About Me/` | Adopter profile populated during onboarding — 3-5 files (career history, LLM interaction preferences, etc.); Claude's source-of-truth for who the adopter is |
| `Meetings/` | Per-meeting notes from meeting-processor pipeline (`YYYY-MM-DD - <title>.md`); universal — people meet regardless of archetype |

**System symlinks at vault root (2):**

| Symlink | Target | Purpose |
|---|---|---|
| `Plans/` | `~/.claude-plans/` | Plan tree visibility from inside the vault |
| `Skills/` | `~/.claude/skills/` | Skills index visibility from inside the vault |

**Per-folder navigation mandate.** Every user-facing folder carries an `_index.md` for active-instance / per-file enumeration and navigation. The index files navigate via wiki links — both the user (in Obsidian) and Claude (when scoping into the folder) follow them to the right destination. In-scope: `Inbox/` (active-connection enumeration), `Vault Architecture/`, `About Me/`, `Meetings/`, and every user-defined cluster + cluster-instance folder. Out-of-scope: `Logs/`, `Tags/`, `Archive/`, `Daily/` (high-churn or no-navigation-value).

**The retired set (explicit "not shipped"):** `README.md` at vault root, `Templates/` as adopter artifact, `Reference/` folder entirely, folder-scoped `CLAUDE.md` at any depth — all retired per Session 16 locks #1 / #4 / #5 / #6.

**Beyond the system set.** User-defined clusters (e.g., `Engagements/`, `Studies/`, `Clients/`, `Major Projects/` — named per the adopter's archetype and vocabulary) and personal tracks (e.g., `Personal Initiatives/`, `BD/`, `MBA Prep/` — named freely). Foundation mandates **cluster SHAPE** — `_index.md` at cluster + instance levels; 3-file-per-bucket triad per instance (Overview / Updates / Context); optional `People/` subfolder when stakeholders multiply. Foundation does NOT mandate cluster names.

The full enumeration is locked at [`mandatory-file-lock.md`](./mandatory-file-lock.md); the user-facing rendering ships at `Vault Architecture - Mandatory-Files.md` (with the thin meta-spoke `Vault Architecture - Enforcement.md`).

The lock is the architectural floor. Below it, the system cannot guarantee its own invariants. Above it, adopters add files freely; they cannot remove the floor and expect the system to function. Governance discipline (frontmatter + tagging + pre-write hooks + librarian-manifest inclusion) auto-applies to every net-new user-created artifact regardless of where it lives (Session 16 lock #10).

## The four pillars

The four pillars are the orthogonal axes the governance system enforces, each detailed in its own packet. At the principles altitude, the pillars exist as principle-level commitments before they descend into specifics.

### Frontmatter — the API every file exposes to the system

Every vault file carries machine-readable YAML frontmatter that drives routing, lifecycle, and agent context. The schema is unified-with-per-archetype-entries: one canonical declaration of universal fields (`type`, `tags`, `updated`, `status` where applicable) plus per-archetype extension entries that name the conditional fields (`engagement`, `project`, `workstream`, `owner`, `provides`, etc.). Three compliance tiers — Strict (system files; hard fail at write-time via R-32 Tier 2 DENY), Standard (user-authored; soft warning; librarian flags drift), Minimal (explicit opt-out; flagged "outside system"). The full schema lives at [`frontmatter-design.md`](./frontmatter-design.md); the canonical JSON at `schemas/vault-schema.json`. See [ADR-0001](../../docs/decisions/0001-tiered-compliance.md) and [ADR-0002](../../docs/decisions/0002-unified-with-per-archetype-entries.md).

The principle: frontmatter is contract, not decoration. The system reads it before doing anything else with a file. The fields define the file's behavior — what it routes to, how it ages, what an agent reading it should treat as authoritative.

### Tagging — faceted taxonomy with discipline

The onboarding flow is pre-loaded with a **reference tagging structure** — a baseline set of faceted dimensions, prefix grammar, and discipline rules grounded in established taxonomy research (Hedden, Forte, Dubois, Adobe AEM, SharePoint). The wizard combines this reference structure with two inputs from the adopter — the adopter's file drop (which surfaces their existing vocabulary) and their answers during onboarding (which surface their archetype, their work, and the language they use to describe both) — to produce a **per-adopter baseline tag set**: dimensions named in the adopter's vocabulary, populated with starting values that match how the adopter actually talks about their work. The discipline rules apply uniformly across every adopter instantiation regardless of how the wizard names the dimensions for that adopter:

- **Cap.** The total distinct tag values across user-facing dimensions stays bounded (25 working-vocabulary values is the foundation default, calibrated against working-memory literature). System-utility dimensions (`#log/*`, `#status/*`) are exempt because they are machine-emitted and never enter the user's working vocabulary. When the cap is approached during onboarding or later expansion, the wizard prompts for consolidation rather than silently widening the cap.
- **Format.** Tags follow a hierarchical `<dimension>/<value>` prefix grammar — the dimension declares the facet; the value declares the instance within that facet. The grammar mirrors the folder structure (see commitment 5 and the naming pillar below — the same dimension name appears in the folder name, in the frontmatter field name, and in the tag prefix).
- **Closed grammar.** No freeform tags. Every tag matches the prefix grammar; the pre-write hook rejects non-conforming writes. Adding a new dimension requires an explicit R-37 atomic-lockstep schema change, not a casual edit.
- **Tagging failure as signal.** Content that cannot be cleanly tagged surfaces a governance question — either the vocabulary needs extension (rare; R-37 commit) or the content needs re-shaping (typical; routing prompt). The system never invents a freeform tag to escape the bind.

The full treatment — including the cognitive-load research underlying the cap, the per-archetype synonym matching mechanics, and worked examples of the discipline rules in practice — lives at [`tagging-strategy.md`](./tagging-strategy.md).

The principle: tags are the user-side **category-query** handle (see commitment 5 — four-surface architecture). They answer "what bucket does this belong to," not "what does this connect to" — that's the wiki-link surface's job. Free-form tags become folksonomy drift. The discipline is the design.

### Naming — folder and file conventions the system parses

Three things stay parseable across the vault:
- **Folder names match dimension prefixes.** The cluster folder name corresponds to one tag-dimension prefix (e.g., `Engagements/` corresponds to the `#engagement/*` dimension; the adopter's chosen cluster name maps to one dimension). The per-instance subfolder name is the tag *value*.
- **File names follow date-prefix patterns.** `YYYY-MM-DD-slug.md` for meeting notes; `YYYYMMDD-HHMMSS-slug.md` for log files; slug grammar matches frontmatter and tag values where applicable.
- **Plan slugs** follow a descriptive-slug + numeric-prefix-in-creation-order convention; vault-root paths obey a known-root allowlist (R-04).

**The connection between tagging and naming is structural.** The `<dimension>/<value>` tag format mirrors the `<dimension-folder>/<value-folder>/` directory structure. A file at `Engagements/acme-corp/Projects/gold-layer-qa/Meetings/2026-05-13-touchbase.md` carries three matching surfaces:

| Surface | Lineage encoding |
|---|---|
| Folder path | `Engagements/acme-corp/Projects/gold-layer-qa/` |
| Frontmatter fields | `engagement: acme-corp`, `project: gold-layer-qa` |
| Tags | `#engagement/acme-corp`, `#project/gold-layer-qa` |

The dimension name appears in the folder (`Engagements/`), in the frontmatter field name (`engagement:`), and in the tag prefix (`#engagement/`). The instance name appears in the folder (`acme-corp/`), in the frontmatter field value (`acme-corp`), and in the tag value (`acme-corp`). One declaration of lineage, materialized across three surfaces — the three-surface architecture from commitment 5 in operation. Naming is the discipline that keeps the surfaces aligned.

**Naming is also what keeps wiki links intact.** Every wiki link in the vault targets a file by path. When a file moves or is renamed, every wiki link pointing to it has to update or the link breaks. The librarian's `rename-cascade` capability handles this automatically — on a rename, every wiki link to the old path is rewritten to the new path in one atomic pass. The `xref-check` and `wikilink-repair` capabilities audit broken cross-references on a cron cadence. The naming conventions are what give those capabilities deterministic targets to walk: parseable paths in, parseable paths out. Free-form or inconsistent naming would force fuzzy-match repair (lossy and stochastic); the convention discipline keeps the repair surface deterministic.

The full pattern catalog lives at [`file-naming-conventions.md`](./file-naming-conventions.md); enforced via `governance/naming-rules.json` and surfaced in `Vault Architecture - Naming.md`.

The principle: naming is parseable. The system extracts structure from file paths and names — date, archetype, slug, lineage — and the extraction works only if the conventions hold. Naming drift is silent query drift downstream AND silent wiki-link rot.

### Mandatory files — the structural floor

Enumerated above as commitment 7. The full inventory plus per-file rationale lives at the mandatory-file-lock packet.

The principle: a minimum exists below which the system cannot function. The minimum is small, enumerated, and locked.

## The articulation test — novice mental-model checkpoint

After reading this packet and the pillar packets — and being onboarded via the canonical onboarder flow — a novice user should be able to articulate nine things about their own vault, in plain language, without consulting the documentation. The articulation set is the dogfood test target and the working definition of "the onboarder succeeded":

1. **What frontmatter is for** — it drives routing, lifecycle, and agent context; the fields are the API every file exposes to the system.
2. **The four-surface architecture** — folders (filesystem structure, both human + LLM), frontmatter (Claude's machine-readable API), tags (user-side category-query handle via graph view), and wiki links (explicit cross-references both human + LLM follow to traverse and scope context) each serve a different consumer or consumer mix; collapsing any one breaks a query dimension.
3. **The cap-and-prefix discipline** — 25 distinct tag values across user-facing dimensions; `#dimension/value` hierarchical format; system-utility dimensions exempt.
4. **Research context packets** — mid-density bundles at system altitude (the 9 foundation-shipped packets at `claude-stem/research/vault-construction/`, surfaced via the foundation's GH Pages site) that orient agents before consuming vault budget. Adopters who choose to author their own packets in their user vault may do so at adopter-defined altitudes; the foundation imposes no taxonomy beyond system (Session 16 lock #8).
5. **Compliance tiers** — Strict (system files) / Standard (user-authored) / Minimal (opt-out); default Strict, opt-down preserved.
6. **The mandatory file lock** — what's at vault root, what's per folder, what's conditional, and why each item is there.
7. **Multi-archetype + personal tracks** — the system composes the union of activated archetypes plus user-declared tracks; the user doesn't pick one.
8. **Propose-and-confirm in this domain** — Claude infers structure and writes the first draft; the user reviews, tweaks, and signs off.
9. **The 7-step onboarder flow** — research-then-Q&A-then-architecture-then-scaffold; soft-mandates with coherent skip paths; iteration capped at a small bound on the architecture review step.

If a novice can articulate these nine things after onboarding, the architecture has been internalized at a level sufficient to use the system without ongoing handholding. If they cannot, the onboarder has failed and the pedagogy needs revision. The articulation set is a structural property, not a rhetorical one — the dogfood harness measures against it explicitly.

## Anti-patterns the architecture preempts

Four anti-patterns recur in knowledge-system designs, and the architecture preempts each structurally. Lower-altitude anti-patterns (tier-rigidity confusion, "tags are just labels," "I'll add tags later," "research is for engineers") surface in the pillar packets and the onboarder pedagogy moments.

### "Architecture is documentation; rules are honored on a best-effort basis"

The temptation: write the schema as prose in CLAUDE.md and trust the operator (human or LLM) to honor it. The failure mode: schemas-as-prose drift the moment one operator decides "this case is different." A year in, the vault contains thousands of files conforming to several undocumented evolutions of the schema, none recoverable without a hand audit.

The preempt: every rule has a structural enforcement layer — a hook, a librarian capability, a JSON Schema, a cron audit. Prose surfaces the rule for pedagogy; the layer enforces it at runtime. R-37 atomic lockstep ensures the prose and the enforcement layer stay aligned through governance changes. Pure documentation governance is rejected as a load-bearing strategy.

### "Folders OR tags OR frontmatter OR wiki links — pick one"

The temptation: pick a single navigation surface and treat the others as redundant. The failure mode varies by which surface is dropped — drop folders and humans lose orientation; drop frontmatter and Claude has no machine-readable contract; drop tags and the user loses cross-hierarchy category filtering; drop wiki links and both human and Claude lose the explicit cross-reference paths that scope context. Each surface answers a different question for a different consumer (or consumer mix); collapsing any one sacrifices a query dimension.

The preempt: the four-surface architecture. Every Structural-dimension tag has a corresponding folder; every folder hierarchy propagates as frontmatter fields + matching tags; wiki links create explicit cross-reference paths to canonical destinations; lineage and connection are materialized identically across all four surfaces. R-32 hook enforcement holds the frontmatter + tag invariants at write-time; the librarian's `rename-cascade` + `xref-check` + `wikilink-repair` capabilities hold the wiki-link integrity over time; the `governance-parity-audit` capability catches drift at audit-time.

### "Pick a primary archetype; everything else is secondary clutter"

The temptation: force the onboarder to declare a primary archetype and treat secondary archetypes / personal tracks as exceptions. The failure mode: most practitioners are multi-archetype, and forcing a primary makes secondary content second-class. The consultant who also writes a Substack ends up with the Substack work fitting awkwardly into a consulting-first vault — folder placement is unclear, frontmatter is inconsistent, search across the two domains breaks.

The preempt: the union model. Onboarder infers primary + 0..N secondaries + 0..N user-declared tracks. Folder tree, frontmatter schema, and tag dimensions are all composed from the union. Universal fields hold across all. The 25-tag cap holds across the union, with consolidation prompts when exceeded — not silent failure, not silent cap-widening.

### "Frontmatter is decoration; the real content is the body"

The temptation: treat the YAML block at the top of a file as optional metadata, occasionally filled in for "important" files. The failure mode: a vault where frontmatter coverage is partial cannot route, lifecycle-manage, or surface context. Agents reading a file with missing frontmatter cannot determine its type, scope, or status — they fall back to inferring from filename or content, which is lossy and stochastic.

The preempt: frontmatter is contract. The schema is enforced at write-time (R-32 Tier 2 DENY for Strict tier; soft warning for Standard). Templates ship pre-populated. The system writes frontmatter on every generated file. The user never hand-types YAML; the user never has to remember the schema. The principle: if frontmatter is something the human has to remember to write, frontmatter coverage will be zero.

## Open questions

- **OQ-P1** — multi-archetype overlap policy when archetypes share semantically near dimensions (consultant's `engagement` ≈ developer's `repo`; researcher's `topic` ≈ manager's `initiative`). Synonym-matching handles single-archetype re-labeling cleanly; multi-archetype overlap composition is design work in the consuming scaffold sub-plan. Likely surfaces in multi-archetype union spec and archetype-composition logic.
- **OQ-P2** — the 9-criteria articulation test needs a measurement protocol — how does the dogfood harness verify each criterion is met by an onboarded user without surveying them at length? The dogfood sub-plan owns the operationalization; this packet locks the criteria and the rationale.

## Closed questions (with disposition)

- **CQ-P1** Should the vault architecture be **discovered** (let the adopter's existing structure dictate the shape) or **designed** (impose a canonical structure)? → **Designed, with adopter inputs.** The structure is canonical at the principle level (four pillars, folder-mirrors-tag, multi-archetype union, two-surface governance); the *instantiation* is personalized via synonym-matching, archetype composition, and personal-track declaration. Pure discovery produces folksonomy drift; pure imposition fails the autonomy test.
- **CQ-P2** Should the onboarder force a single primary archetype? → **No — union model.** Rationale: most practitioners are multi-archetype; forcing primacy makes the system less useful for the majority. The 25-tag cap holds across the union; consolidation prompts surface when exceeded.
- **CQ-P3** Is structural enforcement separable from pedagogy — can governance ship as JSON only, with narrative-mode left for later? → **No — two-surface dual pattern is load-bearing.** Rationale: rules must be both teachable and enforced; collapsing onto a single surface produces a document that is bad at both jobs at once. See [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md).
- **CQ-P4** Should historical files (handoffs, logs, daily notes, plan close-outs) be normalized to current schema retroactively when the schema evolves? → **No — append-only.** Rationale: historical records captured past state at the time they were written; retroactive normalization loses the audit trail. Forward changes from this point; old files stay as-is. The R-34 self-healing boundary explicitly limits automatic mutation.
- **CQ-P5** Are `engagement` and `project` archetypes (TYPE values) or navigation slots (FIELD values)? → **Navigation slots, encoded as fields.** Empirical disposition in the reference deployment: zero files held those values at TYPE while hundreds held them at FIELD slots. Folders carry the structural hierarchy; frontmatter fields + tags propagate lineage to LLM consumers. See [ADR-0003](../../docs/decisions/0003-folder-lineage-as-fields.md).

## Source pointers

- Pillar packets (the four-pillar detail this packet anchors): [`frontmatter-design.md`](./frontmatter-design.md), [`tagging-strategy.md`](./tagging-strategy.md), [`file-naming-conventions.md`](./file-naming-conventions.md), and the mandatory-file-lock packet
- Companion narrative packets: [`enforcement-map-design.md`](./enforcement-map-design.md), [`ux-primitives.md`](./ux-primitives.md), [`content-length-limits.md`](./content-length-limits.md), [`_index.md-design.md`](./_index.md-design.md)
- Schema: `schemas/vault-schema.json`
- Governance JSON registries: `governance/_index.json`, `governance/frontmatter-rules.json`, `governance/tagging-rules.json`, `governance/naming-rules.json`, `governance/mandatory-files-rules.json`
- Architecture decision records: [ADR-0001](../../docs/decisions/0001-tiered-compliance.md), [ADR-0002](../../docs/decisions/0002-unified-with-per-archetype-entries.md), [ADR-0003](../../docs/decisions/0003-folder-lineage-as-fields.md), [ADR-0004](../../docs/decisions/0004-system-utility-dimension-exemption.md), [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md)
- Tagging-research lineage (established literature): Hedden (faceted classification); Forte (working-vocabulary cognitive limits); Dubois (10-tag maximum); Adobe AEM and SharePoint (enterprise CMS picklist patterns)
