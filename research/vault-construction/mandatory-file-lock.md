---
altitude: system
scope: The universal mandatory file enumeration — what every adopter vault carries at root by foundation mandate, what the foundation explicitly does NOT ship, and what falls into the user-defined territory the foundation refuses to prescribe. Locks the boundary between "foundation-named system folders" and "user-named cluster shapes" so the adopter wizard can scaffold without ambiguity, the governance hooks can validate without contradiction, and the dogfood harness can verify without enumerating drift.
validity_window: 2026-05-13..2026-11-13
source_dependencies:
  - schema: claude-stem/schemas/vault-schema.json (system-folder + system-file type entries)
  - companion: ./vault-construction-principles.md
  - companion: ./claude-md-design.md
  - companion: ./_index.md-design.md
  - companion: ./inbox-flow-architecture.md
  - companion: ./enforcement-map-design.md
  - decision: Plan 81 SP03 Session 16 — 13 LOCKS RATIFIED (2026-05-13; handoff.md §Session 16)
last_reviewed: 2026-05-13
canonical_url: https://stem.peter.dev/research/vault-construction/mandatory-file-lock/
url_stability: locked-from-2026-05-13
---

# Mandatory file lock — what foundation guarantees, what user defines, what is gone

## Theme

Every adopter vault built on this foundation carries an identical small set of system folders and system files at its root. That set is the **lock**: the foundation guarantees the names, the shapes, and the operational semantics; the adopter wizard scaffolds the set during onboarding; the pre-write hooks validate the structure on every write; the librarian audits drift on every cron run. Beyond the lock, the adopter defines everything — cluster names, instance counts, personal-track shapes, archetype overlays — and the foundation refuses to prescribe. The discipline cuts cleanly: **foundation-named system surfaces with mandated semantics; user-named cluster surfaces with mandated SHAPE (not name); user-defined personal tracks with no name or shape mandate.** The boundary is the design.

The lock has a second job: it carries the explicit RETIRED set. Files and folders that earlier drafts of the architecture imagined as mandatory — `README.md` at vault root, a `Templates/` folder shipping archetype seeds into the adopter vault, a `Reference/` folder serving as a Topic-altitude packet location, folder-scoped `CLAUDE.md` at engagement and project levels — are NOT in the mandatory set, and the lock records that explicitly so future contributors do not re-add them by accident. Retirement is as load-bearing as inclusion: a structure built around what a system *does NOT* carry is more defensible than one that only enumerates what it *does*.

The whole lock was ratified at Plan 81 SP03 Session 16 (2026-05-13) across 13 operator-direction locks. This packet is the canonical surface; downstream consumers (T-32 Mandatory-Files narrative spoke + governance/mandatory-files-rules.json + SP04 scaffold install.sh + SP08 dogfood-harness verification fixtures + SP07 connector wizard) bind against it.

## Vision / approach — six structural commitments

### 1. The system set is small, foundation-named, and the adopter cannot move it

Fourteen items make up the mandatory system set at the adopter vault root (5 files + 7 folders + 2 symlinks). The set is small by design: the eager-load cost of vault-root surfaces is real (every session reads them or has them on the navigation hot path), so each entry must earn its place. Each item below is grounded in Session-02b §A.1 (Peter Message 1 + Message 2 universal-kit inventory) + §A.2 infrastructure dig + Session 4 two-surface governance + Session 16 13-lock ratification + Session 18 Option B reshape.

**System files at vault root (5):**

| # | Path | Loaded when | Purpose |
|---|---|---|---|
| 1 | `CLAUDE.md` | every session start | Vault-root operational frame — identity, active engagements, key files, behavioral rules. ONE-CLASS only; no deeper CLAUDE.md scopes (see §3). |
| 2 | `Vault Architecture.md` | on demand | Authoritative system manual; copy of foundation's mental-model doc. SP04 scaffold writes this at step 7. |
| 3 | `System Backlog.md` | librarian-maintained | Vault-root index of Claude-system projects (live since 2026-03-30 in reference deployment; librarian-regenerated). Companion archive lives at `Archive/System Backlog - Archive.md`. |
| 4 | `Tasks.md` | dashboard + librarian + reconciler | THE single task list (table format; Responses + Deliverables sections; sole writer of vault checkboxes). Universal-mandatory per Peter Message 1 + Session-02 applicability matrix (defaulted-on, opt-out). Survivorship: user edits SURVIVE re-pull; OR-merge with connector emissions via `<!-- id:xxx -->` markers. |
| 5 | `enforcement-map.md` (thin pointer ≤2K) | hook + librarian | Vault-level thin pointer indexing the 5 governance narrative spokes + foundation-repo `governance/` JSON registries. Bulk content at spokes, not here. **At vault root** (NOT inside `Vault Architecture/`) per Session 4 two-surface governance decision (handoff §Session 4 L966 verbatim: "Vault root enforcement-map.md: REPURPOSED to thin pointer indexing the spokes + foundation-repo JSONs"). |

**System folders at vault root (7):**

| # | Path | Loaded when | Purpose |
|---|---|---|---|
| 6 | `Vault Architecture/` | on demand | Container for the 5 narrative spokes: Frontmatter / Tagging / Naming / Mandatory-Files / Enforcement (meta-spoke). |
| 7 | `Inbox/` | dashboard + librarian | **Connector-brief surface** (Session 18 Option B ratification). Foundation mandates the folder, `Inbox/_index.md` (always), and `Inbox/<connector>.md` brief per active connector (conditional-mandatory once a connector activates). The connector's actual DATA lives outside vault at `$CLAUDE_HOME/connector-data/<connector-slug>/` by foundation default (adopter-overridable). |
| 8 | `Archive/` | librarian lifecycle | Long-term cold storage; rolled-over inbox-archive entries; closed engagements. Hosts `Archive/System Backlog - Archive.md` (canonical archived-backlog destination per Peter resolution 2026-05-10; promoted to universal-mandatory + relocated inside `Archive/`). |
| 9 | `Logs/` | system-emitted only | Writable surface for system-emitted logs (session-close, digest-run, backlog-progress, etc.). |
| 10 | `Daily/` | optional / lifecycle | Date-keyed daily notes; activates with daily-note workflow. |
| 11 | `About Me/` | on demand | Adopter profile populated during onboarding (3-5 files describing adopter — career history, LLM interaction preferences, etc.). Universal-mandatory per Peter Message 1 (Session-02b §A.1 row 11). Foundation ships skeleton; adopter populates content at onboarding step 7. |
| 12 | `Meetings/` | on demand + meeting-processor | Universal — people meet regardless of archetype (Peter Message 1; Session-02b §A.1 row 12). Per-meeting notes (`YYYY-MM-DD - <title>.md`) emitted by meeting-processor pipeline from Granola/equivalent transcript sources. |

**System symlinks at vault root (2):**

| # | Symlink | Target | Purpose |
|---|---|---|---|
| 13 | `Plans/` | `~/.claude-plans/` | Plan tree; symlink lets Obsidian + librarian see the plan store. |
| 14 | `Skills/` | `~/.claude/skills/` | Skills index; symlink lets the adopter discover invocable capabilities. |

The set is universal. Every adopter starts with these fourteen entries scaffolded by SP04's install.sh at onboarding. The names are foundation-mandated — the adopter does not rename, relocate, or substitute. R-04 (known-root guard) + R-07 (mirror-review cascade) + R-12 (Personal Initiatives discipline) + R-14 (plan-index regeneration) all key off these exact path names. Renaming `Inbox/` to `Mailbox/`, or `Tasks.md` to `Todo.md`, or `About Me/` to `Profile/` would break every governance hook that references the path.

### 2. User-defined clusters: foundation mandates SHAPE, not NAME

Beyond the system set, the adopter activates clusters that match their work archetype mix. Cluster names are **user-defined**; foundation cannot mandate paths it does not pre-know. One adopter calls their cluster `Engagements/` (consultant archetype); another calls it `Clients/` (also consultant, different vocabulary); another `Major Projects/` (project-manager archetype using natural English); another `Studies/` (researcher archetype). The wizard infers terminology from the adopter's file-drop + Q&A answers, proposes cluster names in the adopter's language (via the synonym dictionary's N=3 inspiration seed, not as a propose-cap), and confirms before scaffold.

The **cluster shape** is mandated. Every user-named cluster carries:
- A cluster-level `_index.md` enumerating active instances + activity-state markers (mandatory per §4).
- Per-instance folders (e.g., `Engagements/<X>/`, `Studies/<topic>/`) — count and names user-defined; SP04 scaffold writes them during onboarding step 7 for each named instance.
- A 3-file-per-bucket triad inside each instance: `<Instance> - Overview.md` (or the user's natural-language equivalent slot for the archetype-overlay-driven canonical file), `<Instance> - Updates.md`, `<Instance> - Context.md`. Optionally `People/` subfolder when the instance has multiple stakeholders.
- An instance-level `_index.md` (mandatory per §4).

Personal tracks (Personal Initiatives, BD, Side Research, MBA Prep, etc.) live alongside work clusters at the vault root. The adopter declares them during onboarding Q4 ("personal tracks not covered by archetype clusters"); SP04 scaffolds the same 3-file-per-bucket triad shape per declared track. Personal tracks have no foundation name mandate — the adopter names them however they want.

The boundary cuts cleanly: **system set = foundation-named (cannot rename); user clusters = user-named with foundation-mandated SHAPE; personal tracks = user-named and user-shaped.** Governance hooks (§5) enforce the SHAPE invariants on user-named clusters via pattern matching against the user's declared cluster names (loaded from the adopter's onboarding-time Layer-3 overlay).

### 3. CLAUDE.md is ONE class — vault-root only

Earlier drafts of the architecture imagined three classes of `CLAUDE.md`: vault-root (every session), engagement-level (per-engagement-scope sessions), folder-scoped (deep project scope). That three-class model is **retired**. Folder-scoped, per-cluster, per-instance, and engagement-level `CLAUDE.md` classes are all out. The mandate is ONE class: the vault-root `CLAUDE.md`.

Why retired: the cumulative eager-load cost of multi-class `CLAUDE.md` (in the reference deployment, ~38K from 7+ files before correction) sat past Anthropic's documented ">5K tokens is almost always too many" warning for session-start auto-loaded surfaces. Vault-root-only collapses the load to ~10–15K and preserves engagement context via on-demand reads of the canonical instance files (`<Instance> - Overview.md` / `<Instance> - Updates.md` / `<Instance> - Context.md`) plus the instance-level `_index.md`. The session-start budget is the constraint; deeper-scope context arrives when work scopes there.

The replacement read surfaces for what folder-scoped `CLAUDE.md` would have carried: cluster-level `_index.md` (active-instance enumeration); instance-level `_index.md` (per-instance file enumeration); the 3-file-per-bucket triad inside each instance. Claude reads these on demand when scoping work into the cluster/instance. The `claude-md-design.md` companion packet codifies the one-class structure and content standard for the vault-root file itself.

### 4. `_index.md` is mandatory at user-facing folders + `Inbox/`; out-of-scope elsewhere

Folder-navigation scaffolding (`_index.md`) carries different obligations at different scopes. Foundation-scaffold mandate (locked Session 16):

| Folder | `_index.md` mandate | Why |
|---|---|---|
| User-defined cluster folders (`<cluster>/`) | Mandatory | Active-instance enumeration; archetype-overlay status markers. Critical for both adopter wayfinding and Claude routing. |
| User-defined cluster instance folders (`<cluster>/<instance>/`) | Mandatory | Per-instance file enumeration + line counts + skip rules. Replaces what folder-scoped `CLAUDE.md` used to carry. |
| `Inbox/` | Mandatory | Active-connection enumeration: which connectors are configured, when each last ran. Important for both adopter (operational visibility) and Claude (routing inputs). |
| `Vault Architecture/` | Mandatory | Navigation across the 5 narrative spokes. |
| `About Me/` | Mandatory | Navigation across adopter-profile files (career history, LLM preferences, etc.); Claude scopes here on demand for user-context questions. |
| `Meetings/` | Mandatory | Enumeration / chronological navigation of per-meeting notes; both adopter and meeting-processor pipeline consume. |
| `Logs/` | OUT OF SCOPE | Claude's own writing space; high-churn. An index would re-stale every cron run. No navigation value. |
| `Tags/` | OUT OF SCOPE | Make.md plugin artifact; `.gitignored` per SP03 D3; not foundation-canonical; does not ship to adopters at all. |
| `Archive/` | OUT OF SCOPE | Cold storage; no ongoing maintenance value. |
| `Daily/` | OUT OF SCOPE | Date-keyed convention; an index would re-churn daily. |

R-32 / R-47 governance hooks treat missing `_index.md` at mandated locations as drift; the librarian's placement-audit surfaces findings on the next cron run. At out-of-scope locations, the librarian does NOT flag missing-index — the absence is correct.

### 5. Governance applies AUTOMATICALLY to all net-new user-created artifacts

The foundation does NOT prescribe content shape inside user-defined clusters or personal tracks. But the foundation DOES enforce governance discipline on every user-created artifact regardless of where it lives:

- **Frontmatter validation** — every net-new file gets schema-conformant frontmatter via `pre-write-guard.sh` R-32 (Tier 2 DENY for strict-tier types; Tier 1 warning for standard-tier; Tier 0 no-op for minimal-tier).
- **Controlled-vocabulary tagging** — every net-new file gets tags matching the 8-dimension faceted taxonomy (or the adopter's Layer-3 overlay if they have customized). Free-form tags denied.
- **Pre-write rules** — `pre-write-guard.sh` enforces R-04 (known-root), R-10 (new-structure checklist), R-27 (plan slug discipline), R-28 (parent_plan on sub-task files), R-32 (frontmatter), R-47 (orphan tag advisory), etc.
- **Librarian-manifest inclusion** — every net-new file is indexed by the librarian-manifest.json regenerator (machine-emitted full vault inventory; refreshed on demand and at cron cadence).
- **Governance-authoring hook (T-38)** — when the adopter creates a NEW folder, NEW file type, unknown archetype, lifecycle-close, or unknown log-subtype, the T-38 hook fires a propose-and-confirm flow to register governance rules into the adopter's Layer-3 overlay. Subsequent writes of that kind are frictionless. T-38 is the structural surface delivering "governance applies automatically" without forcing the adopter to hand-author rule entries.

The cumulative effect: the adopter can create any net-new folders, files, subfolders, or content shapes they want without risk of system-integrity drift. Governance catches up automatically at the moment of creation; the wizard surfaces propose-and-confirm at that boundary; the rule registration is permanent and overlay-scoped to the adopter.

### 6. The retired set: what foundation explicitly does NOT ship

A structure is more defensible when it enumerates what is NOT in scope alongside what is. The retired set:

| Retired item | Why retired | Operator direction |
|---|---|---|
| `README.md` at vault root | Not in Session-02b §A.5 Peter Message 2 universal-kit list; was a draft proposal that did not survive the authoritative inventory | Session 16 lock #6 |
| `Templates/` folder in adopter vault | Foundation-repo `~/Code/claude-stem/templates/` is Claude-onboarding REFERENCE only (consumed by SP04 scaffold to write adopter files; not shipped as adopter artifact). No `Vault Architecture - Templates.md` spoke either. | Session 16 lock #5 (3× operator direction) |
| `Reference/` folder | Retired entirely — not as system folder, not as user-defined cluster, not as Topic-altitude packet location, not as anything. The 4-altitude packets taxonomy that proposed `Reference/<topic>/` as Topic-altitude location is also retired (see §7). | Session 16 lock #4 (3× operator direction) |
| Folder-scoped `CLAUDE.md` at any depth below vault root | One-class CLAUDE.md mandate (see §3) | Session 16 lock #1 |
| Per-instance `CLAUDE.md` (e.g., `<cluster>/<instance>/CLAUDE.md`) | Same as folder-scoped — engagement context is READ surfaces (Overview/Updates/Context/People + `_index.md`), not eager-loaded CLAUDE.md | Session 16 lock #1 + lock #7 |
| Engagement-as-Skill conversion | Engagement folders stay folders; Claude reads instance-level canonical files on demand. NOT invocable capabilities. Skills are "given engagement X, RUN capability Y" (e.g., `gold-layer-qa`). Engagements themselves are context storage. | Session 16 lock #7 |
| Hardcoded N-aggregation-file `Inbox/` lock | Inbox shape is connector-driven (per `inbox-flow-architecture.md`); SP07 connector wizard defines what gets emitted | Session 16 lock #3 |
| 4-altitude packets taxonomy foundation-imposed | Foundation ships system-altitude packets only. Adopters may create engagement/topic/initiative-altitude packets in their own vault if they choose; the foundation neither prescribes the shape nor imposes the taxonomy. | Session 16 lock #8 |

Each retirement carries an operator-direction citation. The audit hooks (T-38 + governance-parity-audit) catch any future regression by rejecting writes that re-introduce a retired class.

## Canonical content

### The 14-item system set, file-by-file

**`CLAUDE.md`** (system-file).
Vault-root operational frame loaded every session. ~150–200 lines body (8–15K bytes per `content-length-limits.md` system-file class). Carries identity, active engagements with one-line summaries, top 5–10 key files, behavioral conventions, schema-enforcement pointer, tagging-taxonomy compact reference, pointer to `Vault Architecture.md` for depth. Authored by SP04 install.sh from the `vault-claude-md-template.md` reference. Length discipline enforced by R-37 lockstep on edits + librarian `claude-md-bloat` finding above 25K bytes.

**`Vault Architecture.md`** (system-file).
Authoritative system manual. Copy of foundation-repo `research/vault-construction/mental-model.md` (the T8 deliverable). SP04 step 7 writes this at scaffold time. The adopter does not author it — it is canonical foundation content, refreshed only via R-37 lockstep when the foundation's mental-model packet revises.

**`System Backlog.md`** (system-file).
Vault-root index of Claude-system projects (research questions, infrastructure improvements, planned-not-yet-scoped work). Lifecycle: `new → triaged → briefed → researched → planned → executed → archived` (per Plan 81 SP03 Phase 2 sentinel schema). Librarian-maintained via `backlog-hygiene` capability; `backlog-research` skill drives item promotion through the lifecycle. Active in the reference deployment since 2026-03-30. Companion archive lives inside `Archive/` at `Archive/System Backlog - Archive.md`.

**`Tasks.md`** (system-file).
THE single task list at vault root (table format; Responses + Deliverables sections). Universal-mandatory per Peter Message 1 + Session-02 applicability matrix (defaulted-on, opt-out). The sole writer of vault checkboxes — Inbox checkbox state is read for sync but `Tasks.md` state wins (per reference-deployment dashboard-sync OR-merge survivorship pattern). User edits SURVIVE re-pull from connectors; the `<!-- id:xxx refs:yyy -->` marker convention links Task cells back to source emission for dedup. Cross-archetype scope: consultants track engagement deliverables; developers track higher-level deliverables (OR-merging with GitHub Issues / Linear / Jira via dashboard sync); managers track at deliverable-level (cadence-stack files like `Status/`, `Reviews/` carry finer-grained tracking). Content varies; the slot is universal.

**`enforcement-map.md`** (system-file; thin pointer ≤2K bytes).
Vault-level pointer indexing the 5 narrative spokes at `Vault Architecture/` + the foundation-repo `governance/` JSON registries. NOT the bulk-content surface; just the pointer table. The earlier ENFORCEMENT-MAP.md monolith (90K with 4,247-char rows) is retired per the two-surface governance architecture (`enforcement-map-design.md` companion packet); bulk content lives at the pillar spokes + JSON registries.

**`Vault Architecture/`** (system-folder).
Container for the 5 narrative spokes — `Vault Architecture - Frontmatter.md`, `- Tagging.md`, `- Naming.md`, `- Mandatory-Files.md`, `- Enforcement.md` (thin meta-spoke). Each spoke 4–8K bytes; the meta-spoke 3–5K. Reference deployment ports 3 spokes verbatim from live (Frontmatter, Tagging, Naming); SP03 T-32 authors the remaining 2.

**`Inbox/`** (system-folder).
Connector-brief surface for human-readable per-connector companion docs (Session 18 Option B ratification, 2026-05-13). Carries: (a) `_index.md` (always mandatory) — active-connection enumeration + cross-connector destination-overlap matrix; (b) `<connector>.md` brief per active connector (conditional-mandatory once a connector activates) — SP07 wizard authors at activation from the foundation template at `templates/connector-brief-template.md`; structure is `Strict`-tier per `vault-schema.json connector-brief` type entry. The connector's actual DATA (JSON aggregates, SQLite databases, binary blobs) lives outside vault at `$CLAUDE_HOME/connector-data/<connector-slug>/` by foundation default (adopter-overridable per-connector via Layer-3 overlay). SP05 auto-routing reads the data store, not the brief markdown; the brief is documentation. See `inbox-flow-architecture.md` companion packet for the full bi-surface architecture + processing-rules contract + destination-overlap mechanics.

**`Archive/`** (system-folder).
Long-term cold storage. Houses rolled-over inbox-archive entries (`Archive/Inbox/{YYYY-MM-DD}.md`), closed engagements after archival, retired plan trees. Librarian-managed; no adopter direct-edit expected after items land.

**`Logs/`** (system-folder).
System-emitted logs only — `session-close-*.md`, `digest-run-*.md`, `backlog-progress/<slug>.md`, etc. Writable surface; cron-driven write cadence. NO `_index.md` here (out-of-scope per §4). Adopter does not hand-author Logs/ content; the cron infrastructure writes.

**`Plans/`** (system-symlink → `~/.claude-plans/`).
Symlink lets Obsidian, librarian, and graph view see the plan store. The plan store itself lives at `~/.claude-plans/` (out of `.claude/` since 2026-04-13 per `feedback_plans_dir_location`). The symlink is the adopter-vault visibility path.

**`Skills/`** (system-symlink → `~/.claude/skills/`).
Skills index symlink. Lets the adopter discover invocable capabilities from inside the vault.

**`Daily/`** (system-folder; optional).
Date-keyed daily notes folder. Activates if the adopter uses a daily-note workflow (`{YYYY-MM-DD}.md` per day). Out-of-scope for `_index.md`.

**`About Me/`** (system-folder).
Adopter profile populated during onboarding (Session-02b §A.1 row 11). Foundation ships skeleton; SP04 wizard authors 3-5 files at onboarding step 7 from Q&A output. Reference-deployment content shape: `Career History & Development.md`, `LLM Interaction Preferences.md`, `Job & Interview Prep/` subfolder (when applicable), etc. — adopter chooses what to surface. The folder serves as Claude's source-of-truth for who the adopter is when reasoning about preferences, expertise, communication style, and historical context. Per-folder `_index.md` mandate applies (the navigation surface for adopter-authored profile files).

**`Meetings/`** (system-folder).
Per-meeting note destination — universal because people meet regardless of archetype (Session-02b §A.1 row 12). Meeting-processor pipeline writes per-meeting notes here from Granola or equivalent transcript sources at `Meetings/YYYY-MM-DD - <title>.md`. File names follow the date-prefix naming convention. Cross-references: each meeting note carries wiki links to its engagement Overview (when scoped to one) and to any action items it produced. Per-folder `_index.md` mandate applies.

### The user-defined territory

Beyond the system set, the adopter activates clusters (work archetypes) + personal tracks. Two-axis territory:

| Axis | Foundation role | Adopter role |
|---|---|---|
| Cluster NAMES | Proposed via synonym dictionary (N=3 inspiration seed) + inferred from file-drop/Q&A | Confirms or modifies; user language wins (per `feedback_synonym_seed_is_inspiration_not_cap`) |
| Cluster SHAPE | Mandated: `_index.md` at cluster + instance; 3-file-per-bucket triad per instance; optional `People/` subfolder | Cannot reshape (governance enforces) |
| Cluster INSTANCE COUNTS | No mandate | Free-form; scaffold writes named instances at onboarding step 7; `/ingest` handles post-onboarding additions |
| Personal track NAMES | No mandate | Free-form (e.g., `Personal Initiatives/`, `BD/`, `Side Research/`, `MBA Prep/`) |
| Personal track SHAPE | Same as clusters (3-file-per-bucket per instance, `_index.md` at each level) | Cannot reshape |
| Per-file content discipline | Mandated frontmatter + tags + governance hooks | Authors content; governance auto-applies |

The reference deployment exhibits a canonical multi-archetype + multi-track instantiation: `Engagements/` (consultant cluster) + `Personal Initiatives/` + `Artefact-BD/` (personal tracks) — three user-defined cluster/track roots alongside the fourteen system items (`About Me/` is in the system set per row 11 above, not a personal track).

### The conditional set

Items that materialize only when the adopter activates the relevant workflow:

- `Logs/<subsystem>/` — when adopter has running scrapers / cron jobs (e.g., `Logs/digest-run/`, `Logs/backlog-progress/`, `Logs/session-close/`). System-emitted; subdir name follows the writer skill's convention.
- `Archive/Inbox/{YYYY-MM-DD}.md` — daily inbox-rollover entries; activate when `inbox-archive` rollover runs.
- `People/` subfolder inside cluster instances — when the instance has multiple stakeholders; SP04 scaffold or `/ingest` writes when first People file is created.

## Anti-patterns

The lock preempts six recurring drift classes:

| Anti-pattern | Drift signature | Preempt with |
|---|---|---|
| Re-introducing folder-scoped `CLAUDE.md` | Multiple `CLAUDE.md` files appearing in cluster + instance folders during dogfood; cumulative session-start load creeps past 25K | One-class lock (§3); R-32 governance hook rejects `CLAUDE.md` writes outside vault root |
| Hardcoding Inbox file list | New connector adds aggregation file but the foundation tries to require it for all adopters | Connector-driven shape (§1 row 6 + companion `inbox-flow-architecture.md`); foundation mandates `Inbox/` + `Inbox/_index.md` (always) + `Inbox/<connector>.md` brief per active connector (conditional-mandatory) |
| Markdown-as-data-layer in `Inbox/` | Connector skill writes a topic-based data dump into `Inbox/<connector>.md`; markdown drifts from documentation to degraded mirror; dashboard moves to separate data store; markdown goes stale | Session 18 Option B ratification — connector DATA lives at `$CLAUDE_HOME/connector-data/<slug>/`; `Inbox/<connector>.md` is `Strict`-tier documentation brief authored from `templates/connector-brief-template.md`; R-32 rejects non-brief content shapes |
| Adding archetype templates to adopter vault | Foundation-repo `templates/` content appearing as adopter artifacts (e.g., `Templates/consultant/`) | Lock #5 retirement of `Templates/`; SP04 scaffold consumes templates at onboarding time but does NOT copy them |
| Treating engagement folder as Skill | "Convert `Engagements/<X>/` to an invocable skill with SKILL.md" appears in design discussions | Lock #7: engagements are CONTEXT storage; Skills are invocable capabilities; do not conflate the primitives |
| Imposing the 4-altitude packets taxonomy on adopter vault | Adopter wizard proposes `Engagements/<X>/<altitude-packet>.md` patterns or `Reference/<topic>/<altitude>.md` paths | Lock #8 retirement; foundation ships system-altitude only; non-system altitudes are adopter-defined if they exist at all |

The two-surface governance architecture catches anti-pattern occurrences via `governance-parity-audit` (compares foundation `governance/mandatory-files-rules.json` to the live adopter Layer-3 overlay) and via R-32 write-time DENY for explicit retired-class writes.

## Quality bar self-test (6 criteria)

1. **Citation required** — operator direction Session 16 (2026-05-13) cited verbatim across §3, §4, §6, anti-patterns; Anthropic ">5K tokens" warning cited in §3; reference-deployment empirical state (~38K pre-correction) cited in §3; Session-02b §A.5 Peter Message 2 cited as authoritative inventory in §6.
2. **Scope declaration** — frontmatter declares `altitude`, `scope`, `validity_window`, `source_dependencies`, `last_reviewed`, `canonical_url`, `url_stability`. ✓
3. **Articulation test** — novice user can articulate after reading: (a) what the system set is (14 items at root — 5 files + 7 folders + 2 symlinks); (b) the SYSTEM-vs-USER cluster boundary; (c) one-class CLAUDE.md mandate; (d) `_index.md` mandate scope; (e) governance-auto-apply guarantee; (f) the retired set and why. ✓
4. **Anti-pattern coverage** — 5 anti-patterns enumerated with drift signature + preempt mechanism. ✓
5. **Decision-traceability** — closed locks (1, 3, 4, 5, 6, 7, 8 from Session 16) attributed verbatim; open carry-forwards (T-32 spoke authoring; SP04 install.sh implementation; SP08 verification fixtures) explicit at §Source pointers below.
6. **Source pointers** — every claim back-linked: companion packets cited inline; sibling deliverables (T-32 / T-38 / governance JSON registry) referenced; operator-direction sessions cited.

## Open questions

| ID | Question | Disposition |
|---|---|---|
| **OQ-MF-1** | `System Backlog.md` shape — table-with-sentinel-pattern (Phase 2 schema; current reference deployment) vs single-row-per-item simpler shape — is the sentinel pattern part of the foundation mandate or an adopter customization? | Defer to T-32 spoke authoring; document the sentinel pattern in `Vault Architecture - Mandatory-Files.md` and let adopters opt-down via Layer-3 overlay if they want simpler. |
| **OQ-MF-2** | `Plans/` + `Skills/` symlinks: SP04 install.sh creates these post-scaffold; should the symlink target paths be configurable for adopters who deploy `claude-stem` to non-standard install roots? | Lean yes; SP04 install.sh accepts `--claude-home` flag; symlink targets follow. |
| **OQ-MF-3** | `Daily/` activation: gated by adopter Q-flow answer, or always-scaffolded-with-explanation? | Always-scaffold; the folder is cheap; the discipline (date-keyed convention) is documented at `Vault Architecture - Naming.md`. |
| **OQ-MF-4** | Re-naming `Inbox/` — some adopters request `Mailbox/` or `Capture/`. Allow rename via Layer-3 overlay or hard-mandate? | Hard-mandate. Every governance hook + scraper config keys off `Inbox/` by exact path. Rename would cascade to 20+ surfaces. Document the rationale in `Vault Architecture - Mandatory-Files.md`. |

## Closed questions (with disposition)

| Question | Disposition |
|---|---|
| Three-class CLAUDE.md model (vault-root + engagement-level + folder-scoped) | RETIRED Session 16 lock #1 (one-class only) |
| Hardcoded 7-aggregation-file Inbox lock | RETIRED Session 16 lock #3 (connector-driven) |
| `README.md` at vault root | RETIRED Session 16 lock #6 |
| `Templates/` folder in adopter vault | RETIRED Session 16 lock #5 |
| `Reference/` folder anywhere | RETIRED Session 16 lock #4 |
| 4-altitude packets taxonomy foundation-imposed | RETIRED Session 16 lock #8 |
| Engagement folder as Skill | RETIRED Session 16 lock #7 |
| Per-archetype synonym dictionary as propose-cap (vs inspiration seed) | RESOLVED — N=3 is INSPIRATION depth; user terminology wins (memory `feedback_synonym_seed_is_inspiration_not_cap`) |

## Source pointers

**Companion packets** (canonical content at `claude-stem/research/vault-construction/`):
- [`vault-construction-principles.md`](./vault-construction-principles.md) — overarching rationale and principles
- [`claude-md-design.md`](./claude-md-design.md) — one-class CLAUDE.md mandate detail
- [`_index.md-design.md`](./_index.md-design.md) — `_index.md` shape and mandate scope detail
- [`inbox-flow-architecture.md`](./inbox-flow-architecture.md) — `Inbox/` connector-driven shape detail
- [`frontmatter-design.md`](./frontmatter-design.md) — schema underpinning system-file mandates
- [`enforcement-map-design.md`](./enforcement-map-design.md) — governance hook architecture
- [`file-naming-conventions.md`](./file-naming-conventions.md) — naming discipline across mandated files
- [`content-length-limits.md`](./content-length-limits.md) — byte caps per file class

**Downstream consumers** (bind against this packet):
- `~/Code/claude-stem/governance/mandatory-files-rules.json` (T-27) — machine-readable rule registry
- `~/Code/claude-stem/onboarding/scaffold/vault-architecture/Vault Architecture - Mandatory-Files.md` (T-32) — narrative spoke
- `~/Code/claude-stem/onboarding/scaffold/install.sh` (SP04) — scaffold-time write logic
- `~/Code/claude-stem/onboarding/scaffold/vault-architecture/Vault Architecture - Enforcement.md` (T-32) — thin meta-spoke
- SP05 auto-routing rules — read mandatory paths to validate destinations
- SP07 connector wizard — emits to `Inbox/` per connector configuration
- SP08 dogfood-harness verification fixtures — assert mandatory set present + retired set absent

**Decision-authority sessions**:
- Plan 81 SP03 Session 16 (2026-05-13) — 13 LOCKS RATIFIED (handoff.md §Session 16); load-bearing for §3, §4, §5, §6, anti-patterns
- Plan 81 SP03 Session-02b §A.5 Peter Message 2 — authoritative universal-kit inventory; load-bearing for §1
- Plan 81 SP03 Session 4 (2026-05-11) — two-surface governance architecture decision; load-bearing for §4 + governance hook references
- Plan 81 SP01 (2026-05-11 closure) — manifest-generalization mechanism that lets `live_mutation_scope` declare adopter-vault writes; load-bearing for SP04 install.sh design

**Memory cross-references** (live `~/.claude/projects/-Users-petertiktinsky/memory/`):
- `feedback_claude_md_two_class_model` — one-class CLAUDE.md mandate
- `feedback_user_defines_clusters` — system-folder + cluster-name + governance-applies-automatically + altitude-packets retirement
- `feedback_inbox_connector_driven` — Inbox shape contract
- `feedback_engagement_is_context_not_skill` — engagement folder semantics
- `feedback_index_file_convention` — `_index.md` mandate scope
- `feedback_synonym_seed_is_inspiration_not_cap` — wizard proposal depth
- `feedback_no_live_edits_during_foundation_repo_build` — separation discipline during SP03–SP08 build
