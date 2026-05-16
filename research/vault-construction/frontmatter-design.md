---
altitude: system
scope: Frontmatter as the contract every file exposes to the system. Three compliance tiers (Strict / Standard / Minimal), universal vs archetype-conditional vs packet-only fields, the unified-with-per-archetype-entries extensibility model, the folder-lineage convention, the system-utility dimension exemption, and the R-37 atomic-lockstep protocol that holds the schema and its enforcement layers aligned over time. The schema is target-state-extensible: foundation-repo ships the 21-entry canonical declaration; adopters extend via Layer 3 vault-overlay without changing schema shape.
validity_window: 2026-05-12..2026-11-12
source_dependencies:
  - schema: claude-stem/schemas/vault-schema.json (v2.0.0)
  - companion: ./vault-construction-principles.md
  - companion: ./enforcement-map-design.md
  - companion: ./file-naming-conventions.md
  - companion: ./content-length-limits.md
  - companion: ./tagging-strategy.md
  - decision: ../../docs/decisions/0001-tiered-compliance.md
  - decision: ../../docs/decisions/0002-unified-with-per-archetype-entries.md
  - decision: ../../docs/decisions/0003-folder-lineage-as-fields.md
  - decision: ../../docs/decisions/0004-system-utility-dimension-exemption.md
  - governance: claude-stem/governance/frontmatter-rules.json (R-37 lockstep peer)
last_reviewed: 2026-05-12
canonical_url: https://stem.peter.dev/research/vault-construction/frontmatter-design/
url_stability: locked-from-2026-05-12
---

# Frontmatter design — the contract every file exposes to the system

> **SP13 T-4 (dissolved 2026-05-14):** All `vault-schema.json` references in this packet are historical. The schema was dissolved: type-registry content migrated to `governance/frontmatter-rules.json#types`; enforcement-map references retired SP13 T-4; runtime consumers now read from `governance/foundation-master.json` (bundle-at-load per SP13 T-3). Source-dependency and source-pointer entries at the bottom of this packet are preserved as historical provenance.

## Theme

Frontmatter is the API every file exposes to the system. Every other governance pillar — tagging, naming, mandatory files — assumes that the file's YAML block answers a small set of questions reliably: *what kind of file is this, who owns it, what does it route to, when was it last touched, is it ready to be aged out.* Without that reliability, the rest of the architecture is decoration. Routing fails because the router has nothing to consume. Lifecycle management fails because aging logic has no timestamp. Agent context fails because a file dropped into an LLM context has nothing telling the LLM how to treat it. The principle the packet defends is brutally simple: **the file's frontmatter is its contract, and the contract is enforced at write-time.**

The contract is not aesthetic. It is the substrate that lets a vault scale from a single human's notebook to a multi-archetype, multi-system, multi-year operational database where Claude reads on demand and writes on capture. Three properties make the substrate hold under pressure. First, the schema is *typed* — every file declares its `type:` from a closed enumeration, and the enumeration is what hooks branch on. Second, the schema is *tiered* — Strict for system-emitted files (hard fail at write-time), Standard for user-authored content (soft warn + librarian audit), Minimal for explicit opt-out (no validation, flagged outside system). Third, the schema is *extensible without churn* — one unified declaration with per-archetype entries (the unified-with-per-archetype-entries model); adopters extend via Layer 3 vault-overlay without touching schema shape. The three properties compose: typed enables case-statement enforcement, tiered enables proportional consequences, extensible enables adoption without forking.

The packet is the narrative half of the dual-surface governance pattern (see [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md); `enforcement-map-design.md` retired SP13 T-4). The schema lived at `claude-stem/schemas/vault-schema.json` (dissolved SP13 T-4; content migrated to `claude-stem/governance/frontmatter-rules.json#types`; runtime bundle at `governance/foundation-master.json`). The enforcement rules live at `claude-stem/governance/frontmatter-rules.json`. The user-facing spoke that distills this packet for inline reading is `Vault Architecture - Frontmatter.md`, rendered into the adopter vault from the foundation-repo scaffold at install time — the reference deployment ran the dual-surface pattern through a multi-week production validation before this codification. R-37 atomic lockstep holds the four surfaces aligned at write-time; the librarian `governance-parity-audit` capability catches drift at audit-time. See [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md) for the design rationale.

## Vision / approach — five structural commitments

The commitments below are the load-bearing premises of the schema. Each one is justified by an empirical signal in the reference deployment or a documented incident class that shaped the design. They are not aesthetic preferences; they are the contracts downstream subsystems (scaffold, auto-routing, onboarding wizard) bind against.

### 1. Frontmatter is contract, not decoration

Every file the system writes carries a YAML frontmatter block as its first non-shebang lines. The block is machine-readable, hook-validated at write-time, and consumed by every downstream agent that reads the file. The user does not hand-type the frontmatter — Claude proposes it on capture (propose-and-confirm; see [`vault-construction-principles.md`](./vault-construction-principles.md) commitment 1), templates ship pre-populated under the anti-drift principle, and the scaffold writes it on day one. Files without frontmatter are not "informal" — they are non-conforming. The R-32 Tier 2 DENY rule at `pre-write-guard.sh` blocks Strict-tier writes that lack the required fields.

The principle has a sharp consequence: **frontmatter cannot be optional for the file classes the system reasons over.** A meeting note without `processed:` is invisible to the meeting-processor pipeline. A packet without `last_reviewed:` falls out of the 180-day staleness audit. A people file without `engagement:` cannot be filtered to engagement-scoped views. The schema does not negotiate these fields away — it enumerates them per-type, hooks require them at write-time, and the librarian audits coverage at session-close. The contract is enforced because the alternative — "we'll add it later" — empirically does not return: production-scale untagged-file backlogs accumulate (~500 files observed in a reference deployment) without write-time enforcement.

### 2. Tiered compliance — Strict / Standard / Minimal with proportional consequences

The schema declares three tiers. Each tier names a validation behavior, a default file class, and a consequence:

- **Strict.** System-emitted files: scaffold output, `/ingest`-routed content, scraper aggregation into `Inbox/`. Required fields enforced at write-time via R-32 Tier 2 DENY. The hook refuses the write and returns the missing fields. No partial writes; no soft-warn-but-proceed.
- **Standard.** User-authored vault content. Required fields produce a soft warning at write-time; the file lands. The librarian's `frontmatter-coverage-audit` capability surfaces drift at session-close. Operator triages.
- **Minimal.** Explicit opt-out files — legacy imports, paste-buffer scratch, archives outside lifecycle. No validation. Flagged "outside system" by the librarian. The `tier: minimal` directive lives in the file's own frontmatter or is inferred from a glob exemption in the schema.

The tier design is not "three flavors of strictness." It is three different *consumers* with three different costs of non-conformance. A Strict-tier non-conforming file is a system bug — the scaffold or the auto-router emitted something the schema rejects. A Standard-tier non-conforming file is human drift — the user typed faster than Claude proposed. A Minimal-tier file is a deliberate carve-out — the user opted out and accepted the consequence. The hook treats them differently because the responses required are different: fix the system (Strict deny), nudge the user (Standard warn), respect the carve-out (Minimal allow).

The tier assignment is per-type, not per-file. The schema's `meeting-note` entry declares `tier: strict` because every meeting note in the reference vault is system-emitted by the meeting-processor pipeline. The `people` entry declares `tier: standard` because people files are user-authored on capture. The `tier: minimal` directive is a file-level opt-out, not a type-level default — there is no canonical type that defaults to Minimal. Adopters customize tier assignments via Layer 3 vault-overlay; the foundation-repo defaults reflect the reference deployment's empirical instantiation.

### 3. Universal vs archetype-conditional vs packet-only — three field classes

The schema partitions fields into three classes. The class determines who applies them and how they extend.

**Universal fields.** Apply to every Strict-tier type. The Strict tier requires `type`, `tags`, `updated`. Conditional on `status` (some types carry an archetype-specific status enum; some don't). These four fields are the minimum machine-readable surface every system file exposes. Standard tier requires the same three (`type`, `tags`, `updated`) without `status`. Minimal requires nothing.

**Archetype-conditional fields.** The schema declares a 14-entry list of fields that *may* appear on any type entry's required or optional list, depending on the type's archetype-relevance. The list:

```
engagement       project          workstream
owner            provides         created
name             attendees        processed
granola_id       target_date      audience
github_repo      parent_folder
```

Per-type entries in the unified schema declare which subset applies. A `meeting-note` requires `attendees`, `processed`; optionally carries `engagement`, `project`, `granola_id`. A `prd` requires `engagement`, `project`, `status`, `owner`; optionally carries `workstream`, `provides`. An `index` requires `parent_folder` at depth ≥ 2 (omitted at depth 1; auto-populated by the new-folder bootstrap hook per [`_index.md-design.md`](./_index.md-design.md) §Maintenance architecture Tier 1). The 14 entries are the foundation-repo seed — adopters extend the list via Layer 3 vault-overlay when their archetype contributes new conditional fields (researcher's `study_phase`, developer's `repo`, manager's `program`).

**Packet-only fields.** Apply only to files with `type: packet`. The foundation ships SYSTEM-altitude packets only — the 9 research context packets at `claude-stem/research/vault-construction/`. The 4-altitude taxonomy (system / engagement / topic / initiative) imagined in earlier drafts is RETIRED from foundation imposition (Session 16 lock #8, 2026-05-13). If an adopter chooses to author their own research packets in their user vault, they MAY use this shape and they MAY assign an altitude label of their choosing — but the foundation does not prescribe non-system altitudes, does not impose a taxonomy on adopter-authored packets, and does not audit non-system altitudes via the staleness capability. Six fields:

```
altitude            validity_window      source_dependencies
last_reviewed       canonical_url        url_stability
```

The packet-only field set is what enables the 180-day staleness audit (`packet-staleness-audit` librarian capability — scope: system-altitude only), the URL-stable contract surfaced on the foundation's GH Pages site, and the source-pointer discipline (every claim back-links to evidence; see quality bar criterion 6 below). Every system-altitude packet authored in this set — including the one you are reading — carries the full six-field block in its frontmatter. Adopter-authored packets (when adopters choose to write them) are governed by adopter-set cadence and need not conform to the system-altitude staleness window.

The three-class partition is what lets the schema scale without churn. Universal fields move via R-37 lockstep (touching universal changes every type entry). Archetype-conditional fields move via Layer 3 overlay (touching no other type). Packet-only fields move within the `packet` type entry. The blast radius of a schema change is bounded by which field class the change touches.

### 4. Unified-with-per-archetype-entries — one schema, one hook, one doc

The schema is one file. The hook is one case statement. The narrative spoke is one document. Per-archetype variation lives *inside* the unified declaration as per-type entries, not as separate schema files or separate hooks. The model has a name: **unified-with-per-archetype-entries.**

The structure: at the top of the schema, declarations that apply across all types (`tiers`, `_archetype_conditional_fields`, `_packet_only_fields`, `_path_rules`, `_tag_prefixes`). Below them, one entry per type (`meeting-note`, `daily-note`, `inbox-archive`, `people`, `prd`, `context`, `reference`, `index`, `weekly-summary`, `daily-archive`, `navigation`, `personal-initiative`, `briefing`, `strategic`, `planning`, `archive`, `historical-brief`, `ideation-brief`, `packet`, `archetype-template`, `log`) declaring its `tier`, `required` field list, `optional` field list. Twenty-one active type entries today; the folder-lineage convention retired `engagement` + `project` from the allowlist (see commitment 5 below; see [ADR-0003](../../docs/decisions/0003-folder-lineage-as-fields.md)).

The unified model is the deliberate alternative to multi-file (e.g., `schemas/meeting-note.json` + `schemas/prd.json` + ...). Multi-file would force schema-walkers to read N files; would distribute tier definitions; would surface as N files for hooks to load. Unified-with-per-archetype-entries reuses one runtime-loaded artifact across all enforcement points. The hook reads the file once, switches on the file's declared `type:`, and validates against the matching entry. The narrative spoke documents the universal sections once and enumerates the per-type entries in a table. The maintenance cost is one schema, one hook branch per type, one table per type — all kept synchronized by R-37 lockstep.

The model is the reference deployment's validated shape. A live `vault-schema.json` ran this structure through multi-week production validation (dissolved SP13 T-4; content migrated to `governance/frontmatter-rules.json#types`; runtime bundle at `governance/foundation-master.json`); the schema-walker hook at `pre-write-guard.sh` now consumes the bundle via bundle-at-load per SP13 T-3; the narrative spoke at `Vault Architecture - Frontmatter.md` documents it. The foundation-repo ports the proof-of-concept and scales it from one pillar's worth of validation to six (the 6-pillar governance architecture per canonical §A).

### 5. Folder-lineage convention (D1) — fields carry what folders cannot

Type information lives at file level only. Folders do not carry frontmatter. The architectural consequence: hierarchical context — *which engagement does this file belong to, which project within that engagement* — cannot be inferred by an LLM from directory ancestry alone. Claude reads a file's frontmatter, not its parent directory. The folder-lineage convention closes the gap by mandating that hierarchical context propagate to file-level fields. See [ADR-0003](../../docs/decisions/0003-folder-lineage-as-fields.md) for the full design rationale.

**The rule.** Any file living at `Engagements/<X>/Projects/<Y>/**` MUST carry both:

- `engagement: <X>` and `project: <Y>` as frontmatter fields (matching the directory ancestor segments)
- `#engagement/<X>` and `#project/<Y>` as tags (matching the field values, per the folder-mirrors-tag invariant)

The folder is the structural artifact; the frontmatter fields and tags are the file-level workaround that propagates lineage to every consumer. The R-32 hook contract validates lineage consistency at write-time: if a file lands under `Engagements/acme-corp/Projects/gold-layer-qa/Meetings/`, the file's frontmatter must carry `engagement: acme-corp` + `project: gold-layer-qa` + matching tags, or the write is denied.

The retirement consequence. `engagement` and `project` were originally TYPE values in an earlier schema version. Empirical measurement at retirement time: zero files carried `type: engagement`; two files carried `type: project`; meanwhile hundreds of files carried the field slots (`engagement:` + `project:`) under the folder tree. The TYPE slots were aspirational, effectively never instantiated — the files that *should* have been engagement-level overview docs were actually `type: navigation` (the CLAUDE.md at `Engagements/<X>/CLAUDE.md`) or `type: context` (the project-overview doc). The retirement codified both as FIELD slots: `engagement` and `project` are how lineage propagates, not what a file IS. The retirement is documented in the schema's `_retired_types` block with `decision_ref`, `reason`, and `replacement` guidance.

**The generic encoding.** The schema's `_path_rules` array carries the rule, parameterized so adopter archetypes extend without schema-shape changes. The foundation-repo ships the consultant default (the `consultant-engagement-project-lineage` rule). Researcher archetype extends with `Topics/<X>/Studies/<Y>/` lineage; developer with `Repos/<X>/Epics/<Y>/`; manager with `Programs/<X>/Initiatives/<Y>/`. Each is one additional entry in the `_path_rules.rules[]` array — no schema-shape change, no hook change beyond consuming the new pattern. The pattern is the structural answer to "how do we encode hierarchical context in a folder-agnostic LLM consumer."

## The 3 compliance tiers in detail

The tier system is the load-bearing enforcement primitive. The schema declares each tier with three fields:

| Tier | validation_behavior | universal_required | conditional_required |
|---|---|---|---|
| **Strict** | `deny` | `[type, tags, updated]` | `[status]` |
| **Standard** | `warn` | `[type, tags, updated]` | `[]` |
| **Minimal** | `allow` | `[]` | `[]` |

`validation_behavior` is what the hook does when required fields are missing. `universal_required` is the minimum field set across the tier. `conditional_required` lists fields that are required only when the type entry declares them (e.g., Strict requires `status` only on types with an archetype-specific status enum — `prd`, `personal-initiative`, `strategic`; not on `meeting-note` or `daily-note`).

### Strict tier — the system contract

Strict is what every system-emitted file conforms to. The hook denies the write if any universal_required field is missing or if any `required` field in the type entry is missing. The deny message enumerates the missing fields and points to the schema. The user sees the deny; the system does not silently write a half-formed file.

**Worked example — a meeting note.** The `meeting-note` type entry declares `tier: strict`, `required: [type, date, meeting_title, attendees, tags, processed, updated]`, `optional: [engagement, project, previous_instance, granola_id, granola_ids, granola_url]`. A meeting-processor pipeline emitting a meeting note at `Engagements/acme-corp/Projects/gold-layer-qa/Meetings/2026-05-12-gold-layer-qa-touchbase.md` must produce frontmatter like:

```yaml
---
type: meeting-note
date: 2026-05-12
meeting_title: Gold Layer QA Touchbase
attendees:
  - Alice Example
  - Sam Walker
engagement: acme-corp
project: gold-layer-qa
processed: true
granola_id: 8f3c2a1e
updated: 2026-05-12
tags:
  - "#engagement/acme-corp"
  - "#project/gold-layer-qa"
  - "#scope/decision"
  - "#log/meeting"
---
```

Missing `attendees:`? Deny. Missing `processed:`? Deny. The deny is immediate — `pre-write-guard.sh` returns a structured error to Claude, which surfaces it as a tool-use error. Claude either fixes the frontmatter and retries, or the write fails permanently. No half-meeting-notes land.

**Worked example — a packet.** This file. `type: packet`, `tier: strict`, `required: [type, altitude, scope, validity_window, source_dependencies, last_reviewed, tags, updated]`, `optional: [canonical_url, url_stability, provides, max_lines, engagement, project]`. The frontmatter at the top of this packet meets all eight required fields. The `canonical_url` and `url_stability` optional fields are present because this packet has been locked for the GH Pages site (per the URL-stable contract). Removing any required field would cause the hook to deny the write.

### Standard tier — user-authored with soft enforcement

Standard is what user-authored content tier conforms to. The hook emits a soft warning if required fields are missing; the file lands; the librarian's `frontmatter-coverage-audit` capability surfaces drift at session-close. The operator triages: fix the frontmatter, or accept the drift, or move the file to a different type.

**Worked example — a PRD.** The `prd` type entry declares `tier: standard`, `required: [title, engagement, project, type, status, owner, updated, tags]`, `optional: [workstream, provides, max_lines]`. A user-authored PRD at `Engagements/acme-corp/Projects/gold-layer-qa/PRD - issue-tracking.md` lands with the frontmatter Claude proposed. If `status:` is missing, the hook warns ("`prd` files should declare `status:`; consider one of `draft|live|closed`") and proceeds. The file lands. The librarian flags the drift at session-close. The operator reviews and either fixes the PRD or accepts the omission.

The Standard tier exists because forcing R-32 Tier 2 DENY on user-authored content empirically punishes capture rate. Production-scale untagged-file backlogs (~500 files observed in a reference deployment) accumulated under capture-friendly modes before write-time enforcement landed; the response was Strict-tier enforcement on system-emitted files where there is no human in the loop, and Standard-tier enforcement on user-authored files where the human is the one writing. The tier choice is structural humility — the system enforces where it owns the write, and warns where the human does.

### Minimal tier — explicit opt-out

Minimal is an explicit declaration that a file is outside the system. The file's frontmatter carries `tier: minimal`, or the file matches a `_minimal_tier_exemptions` glob in the schema. The hook does not validate. The librarian flags the file "outside system" so the operator can find it later (audit-time visibility is preserved even though write-time validation is waived).

The tier exists for legacy imports (a file dragged in from a pre-vault state), paste-buffer scratch (a `notes/scratch.md` that the user uses for thinking-in-public), and archives outside lifecycle (files preserved for legal/regulatory reasons that should not be touched). It is *not* a default — no canonical type declares `tier: minimal`. It is always a per-file opt-out.

**Worked example — legacy import.** A user dragging in `~/old-vault-2024/research-notes.md` from a prior system marks it `tier: minimal` in the frontmatter. The librarian's coverage report surfaces it as "outside system, last touched 2024-08-12, located at `<user-defined-cluster>/legacy/`." The operator either upgrades it to Standard (adds `type:`, `tags:`, `updated:`) or accepts that the file is permanently a museum piece.

## Universal fields

Four fields are universal across the Strict tier: `type`, `tags`, `updated`, and conditionally `status`. The Standard tier drops `status` and keeps the other three. The Minimal tier carries none.

**`type:`** — the canonical enum value declaring the file's class. One of 21 active values in the schema (`meeting-note`, `daily-note`, `inbox-archive`, `log`, `people`, `prd`, `context`, `reference`, `index`, `weekly-summary`, `daily-archive`, `navigation`, `personal-initiative`, `briefing`, `strategic`, `planning`, `archive`, `historical-brief`, `ideation-brief`, `packet`, `archetype-template`). The hook branches on this field via a case statement; every type's `required` and `optional` lists hang off this value. No file is type-less. Files that defy classification are a vocabulary gap — the system surfaces it for review rather than inventing a new type silently.

**`tags:`** — the array of `#dimension/value` tags following the 8-dimension faceted taxonomy. Lowercased, hyphenated, hash-prefixed. The full grammar lives at [`tagging-strategy.md`](./tagging-strategy.md). Universal because every queryable file participates in the tag graph; the orphan-detection librarian capability flags any non-exempt file without a Structural dimension tag.

**`updated:`** — ISO-8601 date the file was last touched. Universal because lifecycle, staleness audits, and recency-weighted queries all consume this field. The post-write-verify hook touches this field automatically when the file is edited; the writer does not have to remember.

**`status:`** — enum value per type entry, where applicable. Strict tier requires `status` *conditionally* — only on types that declare a status enum in their schema entry. `prd` has `status: draft | live | closed`. `personal-initiative` has `status: planned | in-progress | complete | superseded`. `meeting-note` does not have a status enum and does not require it. The conditional encoding is what D2 cleaned up (see commitment below).

## Tags vs fields — who consumes what

The frontmatter block carries both `tags:` (an array of `#dimension/value` strings) and a set of named fields (`type:`, `engagement:`, `project:`, `status:`, `owner:`, `provides:`, etc.). The two surfaces look similar in YAML and adjacent in the file, but they have different consumers and different jobs. Conflating them produces either redundancy (both surfaces carrying the same information with no consumer-side benefit) or gaps (each surface assumed to carry what the other actually does).

**Frontmatter fields are the Claude-side substrate.** Hooks, the librarian, routing skills, and capture pipelines all branch on field values. The pre-write-guard hook's `SCHEMA_KEY` case statement switches on `type:`. The folder-lineage rule consumes `engagement:` + `project:` to validate folder ancestry. Skills read `provides:` to decide what to load. The librarian's coverage audits walk `updated:` for staleness. Field values are how Claude reasons about a file without reading its body — the field IS the API.

**Tags are the user-side surface.** Obsidian's graph view renders tags as nodes; the filter pane queries by tag; Map-of-Content (MOC) patterns surface tag-scoped indexes. A human navigating the vault clicks into `#engagement/acme-corp` from the graph and sees every file in that engagement, regardless of folder hierarchy. The user-side query is the load-bearing consumer for tags.

**The two surfaces mirror, they don't duplicate.** A file under `Engagements/acme-corp/Projects/data-platform/` carries `engagement: acme-corp` + `project: data-platform` as fields AND `#engagement/acme-corp` + `#project/data-platform` as tags. The field gives Claude folder lineage when reading the file out-of-tree (Claude does not climb directory ancestors). The tag gives the user graph-view filterability (Obsidian does not render frontmatter fields as graph nodes). Lose either surface and one consumer goes blind. The folder-mirrors-tag invariant (§Folder-lineage convention above) is the structural commitment that holds both surfaces populated at write-time.

**The write-time hook validates tags but does not query them.** The pre-write-guard hook reads `tags:` to validate the array against the registered taxonomy (prefix grammar, allowlist conformance, near-match detection); the validated tags are then written to the file and the hook does not re-read them at consumption time. This makes tag validation a *hygiene* concern, not a *query* concern. Claude-side query/routing happens on the fields. Tag hygiene is the discipline that keeps the user-side graph queryable; the full discipline lives in [`tagging-strategy.md`](./tagging-strategy.md).

The implication for schema design: the field set and the tag set evolve under separate disciplines. New fields land via R-37 lockstep on the schema + frontmatter rule registry + frontmatter narrative spoke + pre-write-guard SCHEMA_KEY case. New tag dimensions land via R-37 lockstep on the schema's `_tag_prefixes` declaration + tagging rule registry + tagging narrative spoke + pre-write-guard tag-validation branch. The two pillar pipelines are parallel, not the same.

## Archetype-conditional fields

The 13 archetype-conditional fields live at the top of the schema as `_archetype_conditional_fields.fields`. Per-type entries declare which subset applies to their `required` or `optional` list. The list is the consultant-archetype seed generalized for adopter consumption — researchers extend with `study_phase`, developers with `repo`, managers with `program`, all as Layer 3 vault-overlay additions.

| Field | Used on (examples) | Notes |
|---|---|---|
| `engagement` | `prd`, `context`, `people`, `navigation`, `strategic`, `planning` | Folder-lineage FIELD slot; matches folder ancestor segment under `Engagements/`; archetype-specific (`client`, `program`, `topic` in other archetypes) |
| `project` | `prd`, `context`, `meeting-note`, `navigation`, `strategic`, `planning`, `archive`, `packet` (optional) | Folder-lineage FIELD slot; matches folder ancestor segment under `Projects/`; archetype-specific |
| `workstream` | `prd`, `context`, `strategic`, `planning` | Sub-project granularity; optional in all current usages |
| `owner` | `prd`, `context`, `personal-initiative`, `strategic` | The human accountable for the artifact; not the file's frontmatter author |
| `provides` | `reference`, `personal-initiative`, `archetype-template`, `packet` (optional), VA spokes | Declares what concepts/rules this file is the canonical source for; consumed by R-40 provides-canonicality rule |
| `created` | `ideation-brief` | The creation date when distinct from `updated` |
| `name` | `people`, `personal-initiative` | Human-readable name (not a slug); distinct from filename |
| `attendees` | `meeting-note` | Array of names; consumed by people-cross-reference audit |
| `processed` | `meeting-note`, `daily-note`, `inbox-archive` | Boolean; tracks whether the meeting-processor pipeline has emitted the structured artifact |
| `granola_id` / `granola_ids` / `granola_url` | `meeting-note` | Granola transcript reference; consumed by meeting-processor |
| `target_date` | (reserved; not currently on any required list) | Future-dated artifact deadline |
| `audience` | `personal-initiative` | Who the artifact is for; distinct from `owner` |
| `github_repo` | `personal-initiative` | GitHub repo URL for code-bearing initiatives |
| `parent_folder` | `index` (required at depth ≥ 2; omitted at depth 1) | Path string relative to vault root naming the parent folder of an `_index.md`. Gives Claude a programmatic parent-pointer for index-tree traversal without path-parsing. Auto-populated by the new-folder bootstrap hook (see [`_index.md-design.md`](./_index.md-design.md) §Maintenance architecture Tier 1); librarian `index-maintain` audits for path-vs-frontmatter drift. Navigation-side lineage — distinct from the content-side folder-lineage convention which propagates `engagement:`/`project:` from directory ancestry. |

The list is open-ended in the sense that adopters add to it via Layer 3 vault-overlay (`vault-schema.json` deploys to `$CLAUDE_HOME/schemas/vault-schema.json` post-install; adopters extend via the overlay mechanism without touching the foundation-repo canonical). The 14 entries are the seed; archetype-template work introduces archetype-specific extensions per the 4-archetype overlay model (consultant / researcher / developer / manager).

## Packet-only fields

Six fields exist exclusively for `type: packet` entries. The packet type carries the standard universal fields plus all six of these; they enable the staleness audit, the URL stability contract, the source-pointer discipline, and the validity-window framing.

**`altitude:`** — declares the packet's scope band. The foundation ships **system-altitude packets only** — the 9 in this set, all living at `claude-stem/research/vault-construction/`, all carrying `altitude: system`. The 4-altitude taxonomy (system / engagement / topic / initiative) from earlier drafts is RETIRED from foundation imposition (Session 16 lock #8). Adopters who choose to author their own packets in their user vault MAY assign whatever altitude label fits their needs (or none); the foundation neither prescribes nor audits non-system altitude values. The system-altitude cadence is 180-day `last_reviewed`; adopter-authored altitudes carry adopter-defined cadence. The schema's `altitude` field accepts any string value to leave adopter authoring open; the staleness audit scope is hard-bound to `altitude: system` only.

**`scope:`** — free-text declaration of what the packet covers. Bounded paragraph length (1-3 sentences). Surfaces in the `_index.md` entry-point doc, in the `packet-staleness-audit` capability output, and at the top of the rendered GH Pages page. The scope sentence is what tells a future-reader (human or LLM) whether to invest the read budget.

**`validity_window:`** — ISO-date range during which the packet is treated as authoritative. Format: `YYYY-MM-DD..YYYY-MM-DD`. The end date is typically `last_reviewed + 180d` for system packets, `last_reviewed + 90d` for topic packets. Outside the window, the packet surfaces in audits with severity escalating; inside the window, the packet is trusted.

**`source_dependencies:`** — array of pointer strings (filesystem paths, URLs, or `memory:slug` references) to the upstream sources the packet builds against. Critical for the source-pointer discipline (quality bar criterion 6): every claim in the packet body should trace to a `source_dependencies` entry. When an upstream source changes, the dependent packets are flagged for re-review.

**`last_reviewed:`** — ISO date of the last human review. NOT the same as `updated`. `updated:` touches on every edit; `last_reviewed:` only on deliberate review pass. The `packet-staleness-audit` capability walks this field, not `updated`.

**`canonical_url:`** — the GH Pages URL for system-altitude packets shipped from the foundation-repo. Empty / absent for adopter-authored packets (the foundation's GH Pages site indexes system-altitude packets only). URL-stable; restructures of the foundation-repo's research/vault-construction/ tree require a redirect plan.

**`url_stability:`** — a status declaration string (`locked-from-YYYY-MM-DD` or `pending-lock` or `deprecated-since-YYYY-MM-DD`). Surfaces in the URL-stability discipline rule. Once a packet's URL is locked, restructures must add redirects rather than breaking links.

Every system-altitude packet in this set — the one you are reading, plus [`vault-construction-principles.md`](./vault-construction-principles.md), [`content-length-limits.md`](./content-length-limits.md), [`file-naming-conventions.md`](./file-naming-conventions.md), [`_index.md-design.md`](./_index.md-design.md), [`enforcement-map-design.md`](./enforcement-map-design.md), [`claude-md-design.md`](./claude-md-design.md), [`inbox-flow-architecture.md`](./inbox-flow-architecture.md), [`mandatory-file-lock.md`](./mandatory-file-lock.md) — carries the full six-field block. The block is the canonical exemplar for system-altitude foundation packets. Adopter-authored packets at non-system altitudes (if adopters choose to write them) carry whatever subset fits their use case; the foundation does not prescribe.

## Plan-tree-only fields (excluded)

One field is deliberately excluded from the vault schema: `parent_plan:`. It is a plan-tree field that lives in a separate schema and would surface misleading drift signals if included here. Disposition + rationale + future re-visit conditions documented at CQ-F3 below.

## System-utility dimension exemption

The exemption closes an ambiguity that surfaces during schema authoring: do system-utility tag dimensions (`#log/*`, `#status/*`) count against the 25-tag cap?

**The answer.** No. System-utility dimensions are exempt from the 25-tag cap. They are machine-emitted by skills, crons, and capabilities — they never enter the user's working vocabulary. Empirically a reference vault has dozens of distinct `#log/*` values (canonical operational subtypes: `#log/digest-run`, `#log/session-close`, `#log/cron-error`, `#log/meeting`, etc.); enforcing the 25-cap on system-utility dimensions would either retire useful operational granularity or force the cap to widen in a way that defeats its working-memory rationale. See [ADR-0004](../../docs/decisions/0004-system-utility-dimension-exemption.md).

The framing in this packet's terms: **the Strict tier's `conditional_required: [status]` clause does NOT require a tag from the `#status/*` dimension on every Strict file.** It requires a `status:` *field* with an enum value when the type entry declares one. The tag-side equivalent (a `#status/<value>` tag) is governed by the tagging discipline (with system-utility exemption from the 25-cap), not by the frontmatter `status:` field requirement.

The distinction matters because frontmatter and tags are independent surfaces. A `prd` file declares `status: live` as a frontmatter field AND carries `#status/live` as a tag (for graph-view queryability). The Strict tier requires the field. The tagging discipline accepts the tag without counting it against the user-facing 25-cap. Both surfaces hold; neither is redundant.

The system-utility exemption is governed by a different discipline: the **log-subtype registry**. The registry enforces that recurring routine activities use STABLE, canonical tag values across runs (every `backlog-hygiene` run tags `#log/backlog-hygiene`, never a near-synonym). The hook contract consults the registry and DENIES near-match drift with "did you mean #log/<canonical>?" suggestions. The registry is the structural answer to "Claude should assign log subtypes intelligently" — it's a registry + hook gate, not a soft convention. See [`enforcement-map-design.md`](./enforcement-map-design.md) §System-utility dimension exemption for the full enforcement contract.

## The unified extensibility model — one schema, one hook, one doc

The model has a name in the schema itself: `unified-with-per-archetype-entries`. The name describes the load-bearing architectural choice. The schema is one file. The hook is one case statement. The narrative spoke is one document. Per-archetype variation lives *inside* the unified declaration as per-type entries.

### Structurally: what one schema means

The schema declares cross-cutting structures at the top, then enumerates per-type entries below. Cross-cutting:

- `tiers` — the three compliance tiers with `validation_behavior` per tier
- `_archetype_conditional_fields` — the 13-entry field menu
- `_packet_only_fields` — the 6-entry packet field menu
- `_path_rules` — the folder-lineage rules array
- `_tag_prefixes` — the 8-dimension taxonomy
- `_tag_prefixes_meta` — system-utility vs user-facing dimension classification
- `_retired_types` — types removed from the allowlist with `decision_ref`
- `_excluded_fields` — fields deliberately excluded with documented reason
- `_design_notes` — the meta-block (model name, lockstep pair, evolution protocol, source dependencies)

Per-type entries: each carries `tier`, `required`, `optional`, optionally `_description` for context. Twenty-one active type entries today.

The unified file is what `pre-write-guard.sh` loads once via `jq` at the start of a write event. The hook does not re-load per-type; it consumes the relevant entry via a case-statement switch on the file's declared `type:` value.

### Structurally: what one hook means

`pre-write-guard.sh` has a single case statement (called `SCHEMA_KEY`) that switches on `type:` and validates the file's frontmatter against the matching schema entry. The hook does not have N branches for N type-files; it has one branch per type, and the branch consumes the schema's declaration of that type's required/optional fields.

The cost discipline: adding a new type to the schema requires adding one branch to the hook (R-37 lockstep). Removing a type requires removing its branch. The hook's case statement is the runtime mirror of the schema's type-entry list. A change to either without a matching change to the other is the drift that R-37 closes.

`post-write-verify.sh` has a parallel `type_map` dict (per the `doc-dependencies.json` row for `vault-schema-type-consistency`). The pre-write-guard SCHEMA_KEY case statement enumerates the runtime allowlist; the foundation-repo schema declares 21 active type entries, and hook parity at install time is governed by R-37 lockstep (allowlist + post-write-verify type_map + schema move together).

### Structurally: what one document means

The narrative spoke (`Vault Architecture - Frontmatter.md` in adopter scaffolds; ports from the reference vault) documents the universal sections once and enumerates the per-type entries in a table. The doc-side maintenance cost is one table row per type, kept synchronized with the schema's per-type entry via R-37 lockstep.

The narrative spoke is not generated from the schema. The choice was considered and rejected (see [`enforcement-map-design.md`](./enforcement-map-design.md) §Alignment mechanism): narrative spokes carry narrative voice + pedagogy + anti-patterns + citations — content that doesn't round-trip through JSON without lossy transformation. Generated narrative loses pedagogy. R-37 lockstep + librarian `governance-parity-audit` catches drift without flattening the spokes.

### R-37 atomic-lockstep protocol — the alignment mechanism

R-37 is the structural commitment that keeps the four coupled artifacts aligned at write-time. Every schema-touching commit MUST update all four in one commit:

1. **The schema itself** — `vault-schema.json` (foundation-repo canonical at `schemas/vault-schema.json`; adopter install at `$CLAUDE_HOME/schemas/vault-schema.json` or equivalent)
2. **The enforcement rule registry** — `governance/frontmatter-rules.json` (the R-rule peer of the schema)
3. **The narrative spoke** — `Vault Architecture - Frontmatter.md` (rendered from the foundation-repo scaffold)
4. **The hook implementation** — `pre-write-guard.sh` SCHEMA_KEY case statement + `post-write-verify.sh` type_map dict + the CLAUDE.md reference if global

R-37 fires from `pre-write-guard.sh` itself — a write that touches one of the four without the others is DENY-blocked with the missing-surface enumerated. The hook is self-referential by design: it enforces the rule that governs its own updates.

The empirical signal: a reference deployment has run R-37 lockstep on the schema/hook/spoke triple through multi-week production validation. Drift detected to date: 2-3 types of bounded drift between `vault-schema.json` and `Vault Architecture - Frontmatter.md` (the spoke has historical context the schema dropped; the schema has new types the spoke hasn't documented yet). The drift is *visible* — the librarian's `governance-parity-audit` surfaces it weekly — and *bounded* — neither artifact has diverged catastrophically. The pattern works at one pillar's scale; the foundation-repo extends it to four.

The full enforcement model is documented at [`enforcement-map-design.md`](./enforcement-map-design.md) §Two-surface dual pattern, §Alignment mechanism. This packet is the frontmatter-specific instantiation.

## Folder-lineage convention in practice

The convention mandates that any file under `Engagements/<X>/Projects/<Y>/**` carries both:

- `engagement: <X>` and `project: <Y>` as frontmatter fields
- `#engagement/<X>` and `#project/<Y>` as tags

The schema encodes the rule generically via `_path_rules`. The foundation-repo ships the consultant default; adopter archetypes extend the array. Here's the consultant rule:

```json
{
  "id": "consultant-engagement-project-lineage",
  "archetype": "consultant",
  "pattern": "Engagements/{engagement_slug}/Projects/{project_slug}/**",
  "requires_fields": [
    { "field": "engagement", "must_equal_ancestor_segment_at_depth": 1 },
    { "field": "project", "must_equal_ancestor_segment_at_depth": 3 }
  ],
  "requires_tags": [
    { "tag_pattern": "#engagement/{engagement_slug}" },
    { "tag_pattern": "#project/{project_slug}" }
  ],
  "tier": "strict",
  "exemptions": [
    "Files at Engagements/<X>/CLAUDE.md (engagement-level navigation; type=navigation entry handles)",
    "Files at Engagements/<X>/_index.md (folder index; type=index entry handles)",
    "Files at Engagements/<X>/Projects/<Y>/CLAUDE.md (project-level navigation; type=navigation entry handles)",
    "Files at Engagements/<X>/Projects/<Y>/_index.md (project folder index; type=index entry handles)"
  ]
}
```

**Why generic encoding.** The rule is parameterized so adopter archetypes extend without changing the schema's shape. A researcher's `Topics/<X>/Studies/<Y>/` lineage is one additional rule entry in the `_path_rules.rules[]` array, with `archetype: "researcher"`, `pattern: "Topics/{topic_slug}/Studies/{study_slug}/**"`, `requires_fields: [{ "field": "topic", ... }, { "field": "study", ... }]`. The hook consumes the new rule alongside the consultant default; the schema-shape doesn't change.

**Why field-and-tag (not field-only or tag-only).** The two-surface pattern (folder + frontmatter for LLM consumers; tag for graph-view query). Field-only would lose graph-view filterability; tag-only would lose LLM-context propagation. Both surfaces are load-bearing; both are mandated.

**Why folder-level CLAUDE.md and _index.md are exempt.** They are navigation files for the folder itself, not files *about* a project within an engagement. The exemption is enumerated explicitly in the rule's `exemptions` array; the hook honors it via pattern matching.

**Why `engagement` and `project` were retired from TYPE.** Empirical zero-use at TYPE; structural confusion between "what a file IS" and "where a file LIVES." The retirement was the structurally honest answer once the empirical signal was clear. The schema documents the retirement in `_retired_types` with full `decision_ref`, `reason`, and `replacement` guidance — so a future-reader of the schema sees why the slot is empty and where the propagation now happens.

## Worked example — a packet's frontmatter

This packet's own frontmatter at the top of the document is the canonical exemplar. All eight required `packet` fields are present (`type`, `altitude`, `scope`, `validity_window`, `source_dependencies`, `last_reviewed`, `tags`, `updated`); both optional URL fields (`canonical_url`, `url_stability`) are present because the packet has been locked for publishing. The `status:` field is absent because the `packet` type entry does not declare a status enum (packets age out via `last_reviewed` cadence, not status transitions). The tag block is emitted at hook-write-time from the schema's `_tag_prefixes` declaration plus packet-specific dimensions — the field set and the tag set are independent surfaces governed by separate disciplines (see the companion tagging-strategy packet for the tag side). Every system-altitude packet in this set carries this same shape: the frontmatter is the API, and the API is identical across packets.

## Anti-patterns

The frontmatter discipline preempts a recurring set of failure modes. Each is a real pattern the architecture has either survived or designed against.

| Anti-pattern | What goes wrong | Preempt with |
|---|---|---|
| **Frontmatter is decoration** | Treats fields as cosmetic; relies on the file body or filename for routing/lifecycle/agent context | Frontmatter is the API every file exposes. The fields drive R-32 enforcement, R-39 coverage audit, lifecycle staleness, and agent context. Strip the frontmatter and the file is opaque to the system. |
| **Tags duplicate folders — why both?** | Sees folder + tag as redundant; argues for collapsing into one | Folders are hierarchical and answer "where does this file live"; tags are flat and overlap and answer "what is this file about, across hierarchies." Folder-mirrors-tag invariant is the *design* — graph view requires the tag surface; navigation requires the folder surface. Lose either and query power collapses. |
| **I'll add tags / frontmatter later** | Defers; never returns; the audit trail loses the file's lineage forever | The system writes frontmatter for you on every generated file (capture-is-cheap commitment). For manual files, run `/route` and Claude infers + applies. The "later" empirically does not come — production-scale untagged-file backlogs (~500 files observed) accumulate without write-time enforcement. |
| **Custom freeform fields whenever** | A user adds `priority:`, `urgency:`, `client_facing:` ad-hoc; the field set fragments per-file | Frontmatter fields are a closed vocabulary per type. Adding a field requires extending the schema (R-37 lockstep on schema + hook + doc + rule registry). Ad-hoc fields are silent drift — no consumer reads them. Hook does not require deny on unknown fields (Tier 3 advisory only), but the field is invisible to the system. |
| **Strict tier sounds rigid** | Reads the default as imposed; argues for Standard everywhere | Strict tier applies to *system-emitted* files where there is no human in the loop. The system owns the write; the system enforces the contract. Standard tier applies to *user-authored* content where the human is the one writing. Minimal tier is an *explicit opt-out*. The defaults reflect who owns the write, not abstract strictness. |
| **Engagement / project as a TYPE** | A user wants `type: engagement` on the engagement-overview file at `Engagements/<X>/CLAUDE.md` | Type information lives at file level; engagement/project lineage lives at *field* level (the folder-lineage convention). The engagement-overview file is `type: navigation` (it navigates the engagement); the engagement *as a concept* is encoded as `engagement: <slug>` field + `#engagement/<slug>` tag on every file under the engagement's folder tree. The TYPE allowlist retired `engagement` and `project` because the slots were never instantiated. |
| **Generate the narrative spoke from the schema** | A clever automation idea — the spoke is consistent with the schema by construction | The spoke carries voice, examples, anti-patterns, and citations. Generated narrative loses pedagogy. R-37 lockstep + audit catches drift without flattening the spoke. The two-surface dual pattern is the design; collapsing it is the regression. See [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md). |
| **Skip frontmatter on "small" files** | A user-emitted note feels too short for full frontmatter | The Standard tier exists for user-authored content; required fields are still `type`, `tags`, `updated`. A short file is no less queryable than a long one. The librarian's `frontmatter-coverage-audit` flags files without `type:`/`tags:` regardless of body length. If the file is truly outside the system, opt out to Minimal explicitly; do not silently skip. |
| **`updated:` is the last frontmatter edit, not the last content edit** | A user touches the body but forgets to bump `updated:` | The post-write-verify hook touches `updated:` automatically on every edit. The writer does not have to remember. If the hook is bypassed (manual filesystem edit, external editor write), the librarian's freshness audit surfaces the drift. |

## Quality bar self-test (6 criteria)

The 6 criteria are mandatory for every system-altitude packet. Self-test below.

1. **Citation required — every recommendation backed by external literature, internal incident, or documented decision.**
   - PASS. ADRs cited inline ([ADR-0001](../../docs/decisions/0001-tiered-compliance.md) for tier compliance; [ADR-0002](../../docs/decisions/0002-unified-with-per-archetype-entries.md) for the unified model; [ADR-0003](../../docs/decisions/0003-folder-lineage-as-fields.md) for the folder-lineage convention; [ADR-0004](../../docs/decisions/0004-system-utility-dimension-exemption.md) for the system-utility exemption; [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md) for the dual-surface pattern); the schema artifact (`schemas/vault-schema.json`) cited as the canonical declaration; the live PoC cited as multi-week empirical validation; production-scale ~500-untagged-file empirical signal cited; the schema/hook divergence incident class cited as the motivation for R-37 lockstep.

2. **Scope declaration — frontmatter declares altitude, scope, validity window, source dependencies, `last_reviewed`.**
   - PASS. All six packet-only fields present in this packet's frontmatter; both URL fields present and locked.

3. **Articulation test — novice user can articulate the rule + the why after reading.**
   - PASS. Five structural commitments at §Vision/approach enumerate the load-bearing premises with a *why* per commitment. Three-tier table at §The 3 compliance tiers in detail gives the rule + the why per tier. Folder-lineage and system-utility sections explain the empirical signal that drove each resolution. A novice reader exits with: "frontmatter is the API the system reads; three tiers exist for three different write-owners; lineage propagates via field-and-tag because folders don't have frontmatter; the schema is one file with per-type entries so adding a type is a bounded R-37 commit."

4. **Anti-pattern coverage — every rule pairs with the failure mode it prevents.**
   - PASS. 9-row anti-pattern table at §Anti-patterns covers: decoration framing, tag/folder redundancy framing, "later" deferral, custom freeform fields, "Strict is rigid" framing, engagement/project as TYPE, schema-generated spoke, skip-on-small-files, `updated:` discipline. Each pairs with the field/tier/rule it preempts.

5. **Decision-traceability — open questions explicit; closed questions named with disposition.**
   - PASS. §Closed questions enumerates closed dispositions with source decision links; §Open questions enumerates open items with deferral target. Folder-lineage and system-utility resolutions are walked through inline with `decision_ref`, `reason`, and `replacement` framing matching the schema's `_retired_types` block.

6. **Source pointers — every claim back-links to evidence.**
   - PASS. `source_dependencies:` block in frontmatter enumerates schema + companion-packet + ADR pointers; inline references throughout the body cite ADRs by stable filename, schema artifact paths, hook implementation file paths, and companion packet paths. Source-pointer discipline is reflexive: this packet is itself an exemplar of the discipline it documents.

Self-test verdict: 6/6 PASS at first authoring.

## Open questions

- **OQ-F1** (install contract): the foundation-repo schema ships at `schemas/vault-schema.json`; install deploys it to `$CLAUDE_HOME/schemas/vault-schema.json` (or platform-equivalent). The idempotent re-install contract — what happens when an adopter upgrades between releases and has a Layer 3 vault-overlay — is specified at install design time. A folder-lineage R-32 sub-rule (encoded in `_path_rules.rules[]`) needs its canonical rule ID assigned when the hook implementation lands.

- **OQ-F2** (audit-capability design): the exact set of fields the `frontmatter-coverage-audit` librarian capability surfaces as drift findings for the Standard tier. Initial set: `[type-missing, type-not-in-allowlist, required-field-missing, tier-mismatch]`. Extension pending empirical observation of Standard-tier drift patterns post-deploy.

- **OQ-F3** (archetype-template authoring): the exact archetype-conditional field extensions per archetype overlay. Foundation-repo ships the 13-entry consultant-centric list; researcher / developer / manager overlays extend with archetype-specific fields. The extensions land at archetype-template authoring time per Layer 2 overlay shape contract; the shape is locked at the canonical schema, the seed content lands at archetype template build time.

## Closed questions (with disposition)

- **CQ-F1** Should the schema be split per-type into multiple files (e.g., `schemas/meeting-note.json` + `schemas/prd.json` + ...)? → **No — unified-with-per-archetype-entries.** Rationale: hook reads schema once via `jq`; case statement switches on `type:` and consumes the matching entry; one runtime artifact across all enforcement points. Multi-file would force N reads, distribute tier definitions, surface as N artifacts the librarian audit walks. The reference deployment ran the unified shape through multi-week production validation. See [ADR-0002](../../docs/decisions/0002-unified-with-per-archetype-entries.md).

- **CQ-F2** Should `engagement` and `project` be canonical TYPE values? → **No — retired from TYPE allowlist; preserved as FIELD slots.** Rationale: empirical zero-use at TYPE (no file in the reference vault carried `type: engagement` or `type: project`); structural confusion between "what a file IS" and "where a file LIVES." Replacement: lineage propagates via `engagement:` + `project:` frontmatter *fields* on every file under the folder tree, plus matching `#engagement/<slug>` + `#project/<slug>` tags. The folder is the structural artifact; field + tag is the file-level workaround. Documented in schema's `_retired_types` block. See [ADR-0003](../../docs/decisions/0003-folder-lineage-as-fields.md).

- **CQ-F3** Should `parent_plan:` be a universal vault frontmatter field? → **No — plan-tree-only.** Documented in schema's `_excluded_fields.parent_plan` block. Rationale: plan-tree files validate against `plans-schema.json`, not `vault-schema.json`. Including `parent_plan:` in vault schema would surface misleading drift signals — vault files do not have parent plans, they have engagements or projects or topics. Re-visit when planning methodology generalizes for adopters (deferred from v1).

- **CQ-F4** Should the narrative spoke be auto-generated from the schema? → **No — R-37 lockstep + audit.** Rationale: narrative spokes carry narrative voice, examples, anti-patterns, and citations — content that doesn't round-trip through JSON without lossy transformation. Generated narrative loses pedagogy. R-37 atomic lockstep at write-time + librarian `governance-parity-audit` capability at audit-time catches drift without flattening the spokes. Multi-week dual-surface coexistence demonstrated 2-3 types of bounded drift, well within tolerable range. See [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md).

- **CQ-F5** Should the `_archetype_conditional_fields` list be closed at the 13 foundation-repo entries? → **No — closed at foundation-repo seed; extensible via Layer 3 vault-overlay.** Rationale: the 13 entries are the consultant-archetype seed generalized for adopter consumption. Adopters add archetype-specific fields via Layer 3 vault-overlay without touching the foundation-repo canonical schema. Archetype-template work authors the seed extensions per the 4-archetype overlay model. Extensibility is the point of the unified-with-per-archetype-entries model.

## Source pointers

- **Canonical schema artifact (historical)**: `schemas/vault-schema.json` (schema_version 2.0.0; dissolved SP13 T-4; type registry migrated to `governance/frontmatter-rules.json#types`; runtime bundle at `governance/foundation-master.json`)
- **ADRs preserving the design provenance**: [ADR-0001](../../docs/decisions/0001-tiered-compliance.md) (tier compliance), [ADR-0002](../../docs/decisions/0002-unified-with-per-archetype-entries.md) (unified model), [ADR-0003](../../docs/decisions/0003-folder-lineage-as-fields.md) (folder-lineage convention), [ADR-0004](../../docs/decisions/0004-system-utility-dimension-exemption.md) (system-utility exemption), [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md) (dual-surface pattern)
- **Companion packets**: `./vault-construction-principles.md`, `./content-length-limits.md`, `./file-naming-conventions.md`, `./_index.md-design.md` (`enforcement-map-design.md` retired SP13 T-4)
- **Live runtime artifacts (post-install)**: `$CLAUDE_HOME/governance/foundation-master.json` (bundle-at-load; dissolved `$CLAUDE_HOME/schemas/vault-schema.json`); `$CLAUDE_HOME/hooks/pre-write-guard.sh` (bundle consumer + R-04 known-root allowlist); `$CLAUDE_HOME/hooks/post-write-verify.sh` (type_map dict)
- **R-37 lockstep coupled-surface peers**: `governance/frontmatter-rules.json` (rule-level peer of the schema) + `Vault Architecture - Frontmatter.md` (narrative spoke rendered from the scaffold)
