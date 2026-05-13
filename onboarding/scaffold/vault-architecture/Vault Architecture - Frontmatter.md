---
type: reference
description: Frontmatter standards, the three compliance tiers, the folder-lineage convention, the archetype extension protocol, and the pre-write validation contract that holds the vault schema enforceable at write-time.
provides:
  - frontmatter-rules
  - pre-write-validation
  - folder-lineage-convention
  - archetype-extension-protocol
updated: 2026-05-12
max_lines: 250
tags: ["#scope/reference"]
---

> **Summary:** Authoritative reference for the YAML frontmatter contract every vault file exposes to the system. Covers the three compliance tiers (Strict / Standard / Minimal), the universal-vs-archetype-conditional-vs-packet-only field classes, the folder-lineage convention, the archetype extension protocol, and the pre-write validation flow. Hand-authored narrative spoke; R-37 lockstep peer of `governance/frontmatter-rules.json` and `schemas/vault-schema.json`.
> **Canonical for:** frontmatter-rules, pre-write-validation, folder-lineage-convention, archetype-extension-protocol
> **Last substantive update:** 2026-05-12

# Vault Architecture — Frontmatter

Frontmatter is the API every file exposes to the system. Hooks, the librarian, routing skills, and capture pipelines all branch on field values; without a reliable contract at the top of each file, every downstream consumer is guessing. The discipline is enforced at write-time because the alternative — "we'll add frontmatter later" — empirically does not return. Tags are the user-side query surface (Obsidian graph view, filter pane, MOC patterns) and live in [[Vault Architecture - Tagging]]; frontmatter fields are the Claude-side substrate documented here. The two surfaces mirror each other under the folder-mirrors-tag invariant. The long-form research narrative — five structural commitments, anti-pattern catalogue, closed questions — lives at the canonical [`frontmatter-design.md`](https://stem.peter.dev/research/vault-construction/frontmatter-design/) packet on the documentation site.

## The three compliance tiers

The tier system is the load-bearing enforcement primitive. Each tier names a validation behavior and a default file class; the consequence is proportional to who owns the write.

| Tier | Validation behavior | Universal required | Default file class |
|---|---|---|---|
| **Strict** | `deny` (R-32 Tier 2) | `type`, `tags`, `updated` (+ `status` when type declares a status enum) | System-emitted files (scaffold output, `/ingest`-routed content, scraper aggregation into `Inbox/`) |
| **Standard** | `warn` (Tier 1 advisory) | `type`, `tags`, `updated` | User-authored vault content |
| **Minimal** | `allow` (no validation) | None | Explicit opt-out — legacy imports, paste-buffer scratch, archives outside lifecycle |

Tier assignment is per-type, not per-file. The schema's `meeting-note` entry declares `tier: strict` because every meeting note is system-emitted. The `people` entry declares `tier: standard` because people files are user-authored. The `tier: minimal` directive is always a per-file opt-out — no canonical type defaults to Minimal. Adopters customize tier assignments via Layer 3 vault-overlay; the foundation-repo defaults reflect a multi-week production validation in the reference deployment.

## Required fields by file type

The canonical declaration lives at `schemas/vault-schema.json`. The table below is the at-a-glance summary; the schema is the source of truth and changes via R-37 atomic lockstep.

| File type | Tier | Required fields | Notes |
|---|---|---|---|
| Meeting notes | Strict | `type: meeting-note`, `date`, `meeting_title`, `attendees`, `tags`, `processed`, `updated` | Optional: `engagement`, `project`, `previous_instance`, `granola_id`, `granola_url` |
| Daily notes | Strict | `type: daily-note`, `date`, `day`, `processed`, `tags`, `updated` | |
| Inbox archive | Strict | `type: inbox-archive`, `date`, `day`, `sources`, `created`, `tags`, `updated` | |
| Log files | Strict | `type: log`, `log-type`, `date`, `timestamp`, `tags`, `updated` | `log-type` is the canonical operational subtype; the `#log/<log-type>` tag is derived |
| People | Standard | `type: people`, `name`, `org`, `role`, `engagement`, `tags`, `updated` | Optional: `email`, `projects` |
| PRD | Standard | `type: prd`, `title`, `engagement`, `project`, `status`, `owner`, `tags`, `updated` | Optional: `workstream`, `provides`, `max_lines` |
| Project context | Standard | `type: context`, `engagement`, `project`, `owner`, `status`, `provides`, `tags`, `updated` | |
| Reference | Standard | `type: reference`, `provides`, `tags`, `updated` | `provides` declares the canonical scope |
| Index files | Strict | `type: index`, `tags`, `updated` | Per-folder `_index.md` discovery files |
| Navigation | Strict | `type: navigation`, `tags`, `updated` | Engagement/project CLAUDE.md files |
| Strategic | Standard | `type: strategic`, `engagement`, `status`, `tags`, `updated` | `status: active \| graduated \| archived` |
| Planning | Standard | `type: planning`, `engagement`, `tags`, `updated` | |
| Personal initiative | Standard | `type: personal-initiative`, `name`, `status`, `owner`, `tags`, `updated` | Optional: `github_repo`, `audience`, `provides` |
| Briefing | Strict | `type: briefing`, `generated`, `date`, `tags`, `updated` | AI-generated daily briefings |
| Archive (general) | Standard | `type: archive`, `source-path`, `archived-date`, `tags`, `updated` | |
| Historical brief | Standard | `type: historical-brief`, `marked-historical-by`, `tags`, `updated` | Superseded ideation briefs retained for historical reference |
| Ideation brief | Standard | `type: ideation-brief`, `title`, `created`, `tags`, `updated` | Vault-side type; canonical content lives at the plan tree |
| Packet | Strict | `type: packet`, `altitude`, `scope`, `validity_window`, `source_dependencies`, `last_reviewed`, `tags`, `updated` | Optional: `canonical_url`, `url_stability`, `provides`, `max_lines` |
| Archetype template | Strict | `type: archetype-template`, `archetype`, `template_for`, `tags`, `updated` | |

## Three field classes

The schema partitions every frontmatter field into one of three classes. The class determines who applies the field and how it extends.

**Universal fields** apply to every Strict-tier type: `type`, `tags`, `updated`, and conditionally `status` (only on types that declare a status enum — `prd`, `personal-initiative`, `strategic`). Standard tier drops `status`; Minimal carries none.

**Archetype-conditional fields** are a 13-entry list at `schemas/vault-schema.json _archetype_conditional_fields`: `engagement`, `project`, `workstream`, `owner`, `provides`, `created`, `name`, `attendees`, `processed`, `granola_id`, `target_date`, `audience`, `github_repo`. Per-type entries declare which subset applies. Adopters extend this list via Layer 3 vault-overlay when their archetype contributes new conditional fields (researcher's `study_phase`, developer's `repo`, manager's `program`).

**Packet-only fields** apply exclusively to `type: packet` entries: `altitude`, `validity_window`, `source_dependencies`, `last_reviewed`, `canonical_url`, `url_stability`. These six fields enable the 180-day staleness audit, the URL-stable contract for the documentation site, and the source-pointer discipline (every claim in a packet back-links to evidence).

The three-class partition is what bounds the blast radius of a schema change. Universal-field changes move via R-37 lockstep touching every type entry. Archetype-conditional changes move via Layer 3 overlay touching no other type. Packet-only changes stay within the `packet` type entry.

## Folder-lineage convention

Type information lives at file level only. Folders do not carry frontmatter, so hierarchical context — *which engagement does this file belong to, which project within that engagement* — cannot be inferred by an LLM from directory ancestry alone. The folder-lineage convention closes the gap by mandating that lineage propagate to file-level frontmatter fields and matching tags.

**The rule.** Any file living at `Engagements/<X>/Projects/<Y>/**` MUST carry both:

- `engagement: <X>` and `project: <Y>` as frontmatter fields (matching the directory ancestor segments)
- `#engagement/<X>` and `#project/<Y>` as tags (matching the field values per the folder-mirrors-tag invariant)

The folder is the structural artifact; the frontmatter fields and tags are the file-level workaround that propagates lineage to every consumer. The R-32 hook contract validates lineage consistency at write-time: a file landing under `Engagements/acme-corp/Projects/data-platform/Meetings/` whose frontmatter lacks `engagement: acme-corp` + `project: data-platform` + matching tags is DENIED.

**The generic encoding.** The schema's `_path_rules` array carries the rule, parameterized so adopter archetypes extend without schema-shape changes. The foundation-repo ships the consultant default; researcher / developer / manager archetypes add one entry each (`Topics/<X>/Studies/<Y>/`, `Repos/<X>/Epics/<Y>/`, `Programs/<X>/Initiatives/<Y>/`). The hook consumes the new pattern; the schema-shape is unchanged.

**Retired types.** `engagement` and `project` were originally TYPE values in an earlier schema version. Empirical measurement showed zero files at `type: engagement` and two at `type: project`, while hundreds carried the field slots under the folder tree. The TYPE slots were aspirational, effectively never instantiated — engagement-level overview docs were actually `type: navigation` (the CLAUDE.md) or `type: context` (the project-overview doc). The retirement codified both as FIELD slots, documented in `schemas/vault-schema.json _retired_types` with `decision_ref` pointing to ADR-0003.

## Archetype Extension Protocol

The foundation-repo ships four archetypes — consultant, researcher, developer, manager — declared at `schemas/vault-schema.json _archetype_enum` and bound to the per-archetype field set at `_archetype_conditional_fields`. Adopters extend the enum via Layer 3 vault-overlay when their work pattern does not match any default archetype.

**Adding a custom archetype.** The adopter writes a Layer 3 overlay at `archetype_extensions.json` (sibling to `vault-schema.json` post-install) declaring the new archetype's enum value, the per-archetype conditional field set, and the path-lineage rule. Pre-write-guard's archetype-binding branch (R-51, governance/tagging-rules.json) reads the union of the foundation enum + the overlay enum at validation time; the librarian archetype-consistency audit (R-41, this pillar) reads the union of `_archetype_conditional_fields` + the overlay's per-archetype declarations.

**R-37 lockstep for archetype changes.** Adding an archetype to the foundation requires touching: (1) `schemas/vault-schema.json _archetype_enum` + `_archetype_conditional_fields` + `_path_rules`, (2) `governance/tagging-rules.json` R-51 `registered_archetypes`, (3) `governance/frontmatter-rules.json` R-41 (this pillar — references the schema enum), (4) `Vault Architecture - Tagging.md` §Per-archetype dimension renaming, (5) this spoke's required-fields table, (6) `pre-write-guard.sh` archetype validation branch. All six surfaces move in one commit.

**Worked example — adding a "curator" archetype.** The adopter's archetype is a museum curator: top-level `Collections/<X>/` instead of `Engagements/`, sub-level `Exhibits/<Y>/` instead of `Projects/`. The overlay declares `archetype: curator`, conditional fields `[collection, exhibit, accession_id, deaccessioned_date, owner, updated, tags]`, path rule `Collections/{collection_slug}/Exhibits/{exhibit_slug}/**` with `requires_fields: [collection, exhibit]` + `requires_tags: [#collection/{slug}, #exhibit/{slug}]`. Pre-write-guard validates against the union enum; the librarian audit verifies field-set completeness on every curator-archetype file.

**The sibling pair (R-41 + R-51).** R-41 in this pillar is the audit-time field-coverage check; R-51 in `governance/tagging-rules.json` is the write-time DENY on unknown archetype values. The pair binds the multi-archetype union architectural commitment to both surfaces — write-time enforcement on the tag side, audit-time coverage on the field side.

## Pre-write validation flow

Before any vault write, pre-write-guard runs the following checks in order. Failure at Tier 2 DENIES the write; failure at Tier 1 surfaces an advisory and proceeds.

**Placement (Tier 1 advisory).** Is the file in a known root (`naming-rules.json` R-04 allowlist)? Does the file's `type:` match the canonical folder pattern per `_path_rules` (R-33)? Are the folder-lineage fields populated to match the directory ancestor segments?

**Frontmatter (Tier 2 DENY).** Does the YAML frontmatter declare a `type:` value in the schema's allowlist (R-32 type DENY)? Are the per-type universal required fields and `required` field list all present? Is `updated:` populated? Is `status:` present when the type declares a status enum?

**Tag validation (Tier 2 DENY + Tier 1 advisory).** Do all `tags:` entries match the hierarchical `#dimension/value` grammar (R-32-taxonomy, `governance/tagging-rules.json`)? Do system-utility tags (`#log/*`, `#status/*`) match the log-subtype-registry's canonical values (R-05)? Is the file's `tags:` array non-empty when the path is not exempted (R-47)?

**Cross-reference (Tier 1 advisory).** Do `owner:`/`attendees:`/`projects:` wikilinks resolve to existing files? Do tag values match folder ancestor segments per the folder-mirrors-tag invariant?

**Post-write coverage (Tier 1 advisory).** Does the file declare `provides:` when over 200 lines (R-39)? Does the file declare `audience: human` when the content is human-only? Are optional fields omitted (not set to empty string) when not applicable?

The librarian frontmatter-coverage-audit walks the vault at audit time and surfaces R-39, R-40 (provides-canonicality drift), and R-41 (archetype-field-compliance drift) as findings the operator triages at session-close.

## Anti-patterns

| Anti-pattern | What goes wrong | Preempt with |
|---|---|---|
| **Frontmatter is decoration** | Treats fields as cosmetic; relies on the file body or filename for routing, lifecycle, and agent context. | Frontmatter is the API every file exposes. The fields drive R-32 enforcement, R-39 coverage audit, lifecycle staleness, and agent context. Strip the frontmatter and the file is opaque to the system. |
| **"I'll add frontmatter later"** | Defers; never returns; the audit trail loses the file's lineage forever. Production-scale untagged-file backlogs accumulate (~500 files observed in a reference deployment) without write-time enforcement. | The system writes frontmatter on every generated file (capture-is-cheap commitment). For manual files, run the routing skill and Claude infers + applies. R-32 Tier 2 DENY closes the loop on Strict-tier writes. |
| **Custom freeform fields whenever** | A user adds `priority:`, `urgency:`, `client_facing:` ad-hoc; the field set fragments per-file; no consumer reads the new fields. | Frontmatter fields are a closed vocabulary per type. Adding a field requires R-37 atomic lockstep (schema + this rule registry + spoke + hook). Ad-hoc fields are silent drift — invisible to the system. |
| **Strict tier sounds rigid** | Reads the default as imposed; argues for Standard everywhere. | Strict tier applies to system-emitted files where there is no human in the loop. The system owns the write; the system enforces the contract. Standard tier applies to user-authored content. Minimal tier is an explicit opt-out. The defaults reflect who owns the write, not abstract strictness. |
| **Engagement / project as a TYPE** | A user wants `type: engagement` on the engagement-overview file at `Engagements/<X>/CLAUDE.md`. | Type lives at file level; engagement/project lineage lives at field level (the folder-lineage convention). The engagement-overview file is `type: navigation`; lineage is propagated as `engagement: <slug>` field + `#engagement/<slug>` tag on every file under the folder tree. |
| **Skip frontmatter on "small" files** | A user-emitted note feels too short for full frontmatter. | The Standard tier exists for user-authored content; required fields are still `type`, `tags`, `updated`. A short file is no less queryable than a long one. If the file is truly outside the system, opt out to Minimal explicitly; do not silently skip. |
| **`updated:` is the last frontmatter edit, not the last content edit** | A user touches the body but forgets to bump `updated:`. | The post-write-verify hook touches `updated:` automatically on every edit. The writer does not have to remember. Manual filesystem edits that bypass the hook surface as freshness drift in the librarian audit. |

## Drift posture vs the schema

The dual-surface governance pattern accepts bounded drift between the canonical schema and this narrative spoke as the cost of preserving narrative voice, examples, and pedagogy. The librarian `governance-parity-audit` capability walks both surfaces at audit time and reports drift findings (typically 2-3 categories: types the schema has retired but the spoke still documents; required-field changes one surface has and the other does not; new fields the schema added that the spoke has not yet covered). R-37 atomic lockstep is the structural commitment that bounds the drift; the audit is the regression check.

## Where to learn more

- Long-form research narrative — five structural commitments, anti-pattern catalogue, closed questions: [`frontmatter-design.md`](https://stem.peter.dev/research/vault-construction/frontmatter-design/)
- Tag-side counterpart of the field/tag dichotomy: [[Vault Architecture - Tagging]]
- Machine-readable rule registry: `governance/frontmatter-rules.json`
- Canonical schema: `schemas/vault-schema.json`
- Tiered-compliance design rationale: [ADR-0001](https://stem.peter.dev/decisions/0001-tiered-compliance/)
- Folder-lineage convention rationale: [ADR-0003](https://stem.peter.dev/decisions/0003-folder-lineage-as-fields/)
- Dual-surface governance pattern: [ADR-0005](https://stem.peter.dev/decisions/0005-two-surface-governance-dual-pattern/)
