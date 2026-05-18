---
altitude: system
scope: Tagging as the user-side query surface — the projection of structural file information into Obsidian's graph view, filter pane, and MOC patterns. The 8-dimension faceted taxonomy, the 25-tag cap on user-facing dimensions, hierarchical `#dimension/value` grammar, per-archetype dimension relabeling, the system-utility dimension exemption (governed by the log-subtype registry rather than the cap), and the write-time hygiene enforcement that keeps the user's working vocabulary navigable. Tags mirror frontmatter fields under the folder-mirrors-tag invariant; the field-side substrate that Claude actually consumes for routing is the subject of `frontmatter-design.md`.
validity_window: 2026-05-12..2026-11-12
source_dependencies:
  - schema: claude-stem/governance/tagging-rules.json (R-37 lockstep peer)
  - governance: claude-stem/governance/_index.json
  - companion: ./frontmatter-design.md
  - companion: ./vault-construction-principles.md
  - companion: ./enforcement-map-design.md
  - companion: ./file-naming-conventions.md
  - companion: ./content-length-limits.md
  - decision: ../../docs/decisions/0004-system-utility-dimension-exemption.md
  - decision: ../../docs/decisions/0005-two-surface-governance-dual-pattern.md
  - external: Hedden — faceted classification (enterprise taxonomy literature)
  - external: Forte — Building a Second Brain (6–8 working-vocabulary cap)
  - external: Dubois — faceted-classification literature (10-max cap)
  - external: Adobe AEM enterprise CMS picklist patterns
  - external: SharePoint enterprise CMS picklist patterns
last_reviewed: 2026-05-12
canonical_url: https://stem.peter.dev/research/vault-construction/tagging-strategy/
url_stability: locked-from-2026-05-12
---

# Tagging strategy — the user-side query surface

## Theme

Tags are the user-side query surface. A human navigating the vault in Obsidian clicks into `#engagement/acme-corp` from the graph and sees every file in that engagement, regardless of where it lives in the folder tree. The filter pane queries by tag; Map-of-Content (MOC) patterns surface tag-scoped indexes; tag-prefixed search returns scoped result sets. None of this is how Claude reads the vault — Claude branches on frontmatter *fields* (`type:`, `engagement:`, `project:`, `status:`, `owner:`, `provides:`), not on tag strings. See [`frontmatter-design.md`](./frontmatter-design.md) §Tags vs fields — who consumes what for the consumer-side dichotomy.

The discipline that keeps the user-side surface useful is the same that keeps any enterprise taxonomy useful: small, strict, stable vocabularies. Uncontrolled tagging produces folksonomy drift within months at scale — synonymous content scatters across variant spellings (`meeting`, `meetings`, `meeting-notes`), case variants (`client-a`, `ClientA`, `client_a`), and abandoned one-offs. The information-architecture literature has documented the failure across every domain it has been studied in (Hedden on faceted classification; enterprise CMS practitioners; personal-knowledge-management work by Forte and Dubois): user-generated tags without governance degrade to noise. The failure is silent — the tag system is present on every file and useful on none.

The architecture refuses the failure by treating tags as **query handles, not descriptive labels.** Every tag is a key that unlocks a user-side set of results in Obsidian; the key set is small (8 dimensions, ≤25 user-facing values), strict (hierarchical `#dimension/value` grammar, write-time DENY for non-conforming), and stable (no new dimension without R-37 lockstep). The write-time pre-write-guard hook validates conformance — but the validation is *hygiene*, not consumption. The hook reads tags to check the array against the registered taxonomy; the validated tags then sit in the file and are not re-read at consumption time except by audit-time hygiene scans. Claude's query/routing happens on the fields. Tag discipline keeps the user-side graph queryable.

This packet is the narrative half of the tagging pillar's dual-surface governance (see [`enforcement-map-design.md`](./enforcement-map-design.md) §Two-surface dual pattern). The machine-readable rule registry lives at `governance/tagging-rules.json`; the user-consumed narrative spoke rendered into adopter vaults at install time is `System Governance - Tagging.md`. R-37 atomic lockstep holds the four coupled surfaces — schema's `_tag_prefixes` declaration, rule registry, narrative spoke, hook — aligned at write-time; the librarian `governance-parity-audit` capability catches drift at audit-time. See [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md) for the design rationale.

## Vision / approach — five structural commitments

The commitments below are the load-bearing premises of the tagging pillar. Each is grounded in established research (Hedden / Forte / Dubois / Adobe AEM / SharePoint) and in empirical signals from the reference deployment. They are not aesthetic preferences; they are the contracts the user-side query surface binds against.

### 1. Tags are user-side query handles

A tag is a *key* that unlocks a set of results in Obsidian's graph view, filter pane, or a MOC index. A descriptive label is prose attached to a file. The two collapse together in folksonomies — every adjective that comes to mind becomes a tag, the vocabulary explodes, and recall collapses. The discipline holds tags as keys: small in number, strict in grammar, stable across time, optimized for *user* navigation. Claude-side routing is a different problem with a different answer — frontmatter fields are the substrate Claude actually consumes ([`frontmatter-design.md`](./frontmatter-design.md) §Tags vs fields). The two surfaces mirror each other under the folder-mirrors-tag invariant; they don't substitute for each other.

### 2. Faceted classification — multiple independent dimensions

Heterogeneous content cannot be classified by a single hierarchy. Hedden's faceted-classification work names the pattern: multiple independent axes (facets), each carrying a closed list of approved values, combined for cross-cutting queries. The vault's content — meeting notes, decisions, reference docs, action items, brainstorms, log files — spans multiple engagements, projects, scopes, and lifecycle states simultaneously. No single dimension classifies it meaningfully. Eight dimensions (enumerated in §The 8-dimension faceted taxonomy below) each do one job; combined, they produce precise multi-axis filtering for the user without forcing a deeply-nested folder hierarchy.

### 3. The discipline IS the design — small, strict, stable

Personal-knowledge-management practitioners converge on small tag sets: Forte recommends six-to-eight concurrent working tags; Dubois caps actively-tracked dimensions at ten; enterprise CMS practitioners (Adobe AEM, SharePoint) favor controlled picklists over open-ended vocabularies. The 25-cap on user-facing dimensions sits in the same territory — sized so a human can hold the full vocabulary in working memory and pick a tag from the registered set without deliberation. The cap is structural, not aspirational: the pre-write-guard hook enforces conformance at write-time; the librarian audits coverage at audit-time; the system surfaces a consolidation prompt when adopter usage approaches the ceiling rather than silently widening it.

### 4. Hierarchical `#dimension/value` grammar

Every tag is two levels: the hash, the dimension, a slash, the value. The dimension is one of a closed set; the value is a kebab-case slug matching `[a-z0-9-]`. The grammar serves three purposes. Dimension membership is unambiguous (`#scope/decision` and `#status/active` cannot collide). Tags are self-documenting (anyone reading the YAML knows what each tag classifies). Enforcement is trivial (any tag not starting with a registered dimension prefix is non-conforming and the hook DENIES). The value slug follows the same grammar as folder names and file slugs (see [`file-naming-conventions.md`](./file-naming-conventions.md) §Slug grammar) — `[a-z0-9-]`, lowercase, kebab-case — which makes the folder-mirrors-tag invariant load-bearing without translation.

### 5. Folder-mirrors-tag invariant — the tag-side projection of folder lineage

Every Structural dimension (`#engagement/*`, `#project/*`, `#initiative/*`, `#artefact-bd/*`, `#about-me/*`) maps to a corresponding folder root, and every file under that folder carries the matching tag. The invariant exists because Obsidian's graph view renders tags but not folders cleanly — without the tag-side mirror, the user loses graph-view filterability for the entire structural hierarchy. The *field*-level rule (the `engagement:` and `project:` frontmatter fields propagated from folder ancestry) is the Claude-side counterpart; the two surfaces are mandated together at write-time. The field-level enforcement contract lives in [`frontmatter-design.md`](./frontmatter-design.md) §Folder-lineage convention; this packet covers the tag-side discipline.

## The 8-dimension faceted taxonomy

The 8 dimensions are the orthogonal axes the tagging pillar exposes for user-side filtering. Six carry user-facing values (subject to the 25-cap); two are system-utility (machine-emitted; exempt per [ADR-0004](../../docs/decisions/0004-system-utility-dimension-exemption.md)). The reference-deployment instantiation below uses anonymized engagement/project slugs (`acme-corp`, `data-platform`, etc.); adopters instantiate their own values during onboarding.

| Dimension | Pattern | Reference-deployment values (anonymized) | User-side query example | User-facing? |
|---|---|---|---|---|
| **Engagement** | `#engagement/{slug}` | `#engagement/acme-corp`, `#engagement/globex`, `#engagement/initech` | "show me everything in the Acme engagement" | Yes (25-cap) |
| **Project** | `#project/{slug}` | `#project/data-platform`, `#project/customer-360`, `#project/credit-modernization` | "show me every file in the data-platform workstream" | Yes (25-cap) |
| **Scope** | `#scope/{slug}` | `#scope/decision`, `#scope/action-item`, `#scope/braindump`, `#scope/reference`, `#scope/briefing`, `#scope/daily-note`, `#scope/essay`, `#scope/inbox` | "every decision across every engagement"; "every action item this quarter" | Yes (25-cap) |
| **Initiative** | `#initiative/{slug}` | `#initiative/foundations`, `#initiative/personal-site` | "every file in the foundations initiative" | Yes (25-cap; activated when adopter has personal-track work) |
| **BD-surface** | `#artefact-bd/{slug}` | `#artefact-bd/partnership-alpha`, `#artefact-bd/rfp-response-q1` | "every BD artifact for the alpha partnership" | Yes (25-cap; activated when adopter has an internal BD surface) |
| **About-Me** | `#about-me/{slug}` | `#about-me/general`, `#about-me/career`, `#about-me/applications` | "every identity-layer file in the career sub-track" | Yes (25-cap; values are adopter-declared) |
| **Status** | `#status/{slug}` | `#status/active`, `#status/pending`, `#status/processed`, `#status/needs-review`, `#status/complete` | "every file with `#status/pending` across the vault" | No — **system-utility (exempt from 25-cap)** |
| **Log** | `#log/{log-type}` | `#log/digest-run`, `#log/session-close`, `#log/cron-error`, `#log/meeting`, `#log/backlog-hygiene`, `#log/dashboard-sync`, and dozens more canonical operational subtypes | "every cron-error log from the last 30 days" | No — **system-utility (exempt from 25-cap)** |

**Total active vocabulary across user-facing dimensions in the reference deployment:** ~20 distinct values, under the 25-cap with headroom for new engagements / projects / scopes. The system-utility dimensions (`#status/*`, `#log/*`) carry many more values — empirically dozens — governed by the log-subtype registry rather than the working-memory cap (see §System-utility dimension exemption).

**Adopter dimension renaming.** Per-archetype synonym-matching (§Per-archetype dimension relabeling below) lets adopters rename the structural dimensions to their working vocabulary — a developer's `#repo/*` slot occupies the same structural position as a consultant's `#engagement/*`. The schema's `_tag_prefixes` declaration stays the same shape; the *names* are adopter-customized via Layer 3 vault-overlay.

## The five discipline rules

Each rule pairs a research basis with a user-facing rationale and names the enforcement layer. The rules are designed to be teachable — a novice user reads them and can explain why each exists — and machine-enforceable — every rule has a hook, a librarian capability, or both that catches violations.

### Rule 1 — 25-tag cap on user-facing dimensions

The total count of distinct values across user-facing dimensions stays under 25. The cap applies to `#engagement/*`, `#project/*`, `#scope/*`, `#initiative/*`, `#artefact-bd/*`, `#about-me/*`, and any adopter-defined custom dimensions where the user picks the value at capture time. System-utility dimensions are exempt (see §System-utility dimension exemption; [ADR-0004](../../docs/decisions/0004-system-utility-dimension-exemption.md)).

**Research basis.** Forte's working-vocabulary tagging research recommends six-to-eight concurrent active tags; Dubois recommends a hard maximum of ten dimensions per note; enterprise CMS practitioners (Adobe AEM, SharePoint) consistently favor small controlled picklists. The 25-cap sits at the upper practical bound — a human can scan the full list without deliberation and pick a canonical tag rather than create a variant. Past 25, decision fatigue produces variant-creation, the vocabulary fragments, and user-side recall collapses.

**User-facing rationale.** Tags are user-side query handles. A vocabulary of 200 tags requires lookup, introduces decision fatigue, and incentivizes the creation of yet another variant rather than finding the canonical term. A vocabulary under 25 keeps every key meaningful — the user can scan it from memory.

**Enforcement.** `governance/tagging-rules.json` declares `cap_25_applies_to: user_facing_dimensions`; the librarian `tag-coverage-audit` capability walks the vault and emits an advisory finding when user-facing usage approaches 80% of the cap. Adopters who exceed 25 see a consolidation prompt during onboarding ("you have 32 active engagement values — consolidate to ≤8 to fit the 25-cap, or extend the cap with a documented Layer 3 override"). Silent widening is rejected; deliberate override is supported with audit trail.

### Rule 2 — Hierarchical `#dimension/value` prefix grammar

Every tag is two levels: hash, dimension, slash, value. The dimension is one of the 8 registered prefixes. The value is a kebab-case slug matching `[a-z0-9-]`. No freeform tags. No three-level hierarchies. No spaces, periods, underscores, or Unicode.

**Research basis.** Hedden's faceted-classification literature establishes the hierarchical prefix as the standard pattern for controlled-vocabulary taxonomies — it makes dimension membership unambiguous and enforcement trivial. Adobe AEM and SharePoint enforce the equivalent at the CMS layer. The grammar mirrors the slug grammar in [`file-naming-conventions.md`](./file-naming-conventions.md) §Slug grammar so the folder-mirrors-tag invariant holds without translation tables.

**User-facing rationale.** The format is self-documenting. Anyone reading a file's YAML frontmatter immediately understands what each tag classifies: `#engagement/acme-corp` is the engagement, `#scope/decision` is the content modality, `#status/active` is the lifecycle state. New contributors learn the taxonomy by reading a few real files; no separate documentation lookup is required at capture time. Lowercase + kebab-case + ASCII-only eliminates the class of bugs where casefolding or normalization scatters near-duplicate variants.

**Enforcement.** `governance/tagging-rules.json` declares `tag_pattern_regex: ^#[a-z][a-z0-9-]*/[a-z0-9][a-z0-9-]*$`; pre-write-guard hook Tier 2 DENY at write-time for any tag failing the regex or starting with an unregistered prefix. The hook reconstructs the post-edit state on Edit operations and validates the result. Violations append to an audit log with the file path and specific non-conforming tag.

### Rule 3 — No new dimension without R-37 lockstep

The set of registered dimensions is closed. New dimensions land via R-37 atomic lockstep: one commit updates the schema's `_tag_prefixes` declaration, `governance/tagging-rules.json`, the narrative spoke at `System Governance - Tagging.md`, and the pre-write-guard hook's prefix-validation regex. The R-37 protocol itself is documented in [`enforcement-map-design.md`](./enforcement-map-design.md) §R-37 atomic-lockstep protocol; the tagging-pillar instantiation lives here.

**Research basis.** Enterprise taxonomy-governance literature (Taxonomy Strategies framework; Hedden on faceted-classification evolution) prescribes a formal change-management process for vocabulary expansion: term-request submission, triage, impact analysis, approval. Pure documentation governance fails — schemas-as-prose drift the moment one operator decides "this case is different."

**User-facing rationale.** The 8 dimensions are structural. Adding a ninth changes what every consumer reads, what every hook validates, and what every adopter learns during onboarding. The blast radius is large; the change-management cost is justified. The rule is not "no extension ever" — it is "extension through a single coordinated commit with audit trail," which preserves both the option to evolve and the discipline that keeps the user vocabulary queryable.

**Enforcement.** R-37 fires from `pre-write-guard.sh` itself — a write that touches one of the four coupled artifacts without the others is DENY-blocked with the missing surface enumerated. The librarian `governance-parity-audit` catches drift at audit-time.

### Rule 4 — No freeform tags (write-time DENY)

Any tag that does not start with one of the registered dimension prefixes is, by definition, non-conforming. The pre-write-guard hook DENIES the write. The tool call fails. An audit record appends to the log.

**Research basis.** Enterprise CMS practice (Adobe AEM, SharePoint) constrains tag assignment to picklist selection — users cannot create new tags at the point of content creation. The pattern moves validation from periodic human review to real-time automated gating. Standard Obsidian workflow — periodic manual review of the tag pane, hand-consolidation of duplicates — cannot keep pace when an LLM is the primary author writing at volume.

**User-facing rationale.** Freeform tags are the folksonomy entry point. One ad-hoc tag invites the next, the vocabulary fragments, and the user-side graph degrades within months. The DENY is not a warning — it is a wall. The author either picks a tag from the registered vocabulary, omits the tag (the file is still legible to Claude-side surfaces via its frontmatter fields), or runs the R-37 lockstep to add a new dimension or canonical value with operator review.

**Enforcement.** Tier 2 DENY in `pre-write-guard.sh` on the tag-validation branch. The hook reads `governance/tagging-rules.json` at runtime, extracts the registered prefixes and per-dimension allowlists, and validates each tag in the file's frontmatter. The DENY message enumerates the non-conforming tags and points to the rule registry.

### Rule 5 — Tagging failure as signal, not error

When content cannot be cleanly tagged with the existing vocabulary, the system surfaces two possibilities: the taxonomy has a gap (a legitimate new category is needed) or the content is a misfit (it doesn't belong where it is being filed). Both are actionable signals. Neither is auto-resolved.

**Research basis.** Enterprise taxonomy-governance literature prescribes the same loop under "change management": the vocabulary evolves through deliberate decisions, not silent accumulation. Auto-generating tags or silently accepting non-conforming ones has been explicitly rejected across the practitioner consensus — auto-generated tags reflect the LLM's salience model, not the user's information architecture.

**User-facing rationale.** A tag the operator wants to add but cannot is a piece of governance information. Either the work has expanded into a new category (the taxonomy needs an extension) or the file is filed wrongly (the operator should re-route it). The rule reframes "tagging failure" from an error to suppress into a signal to act on.

**Enforcement.** The DENY message from Rule 4 surfaces the failure directly. The librarian `tag-coverage-audit` capability surfaces longer-running gaps: tags with zero files attached (candidates for removal), near-miss patterns (`#scope/decisions` vs `#scope/decision` suggesting one is a typo), and unrecognized tags that slipped through. The audit emits advisory findings; the operator triages.

## System-utility dimension exemption

Two dimensions are exempt from the 25-cap: `#log/*` and `#status/*`. They are machine-emitted by skills, crons, and capabilities — they never enter the user's working vocabulary at capture time. The exemption is structurally honest, not a special case.

**Why the exemption.** A reference deployment carried dozens of distinct `#log/*` values — canonical operational subtypes like `#log/digest-run`, `#log/session-close`, `#log/cron-error`, `#log/meeting`, `#log/backlog-hygiene`. The values are not noise; they are structurally distinct categories the operator queries (graph view filtered by `#log/digest-run` returns every digest-run artifact). Enforcing the 25-cap on machine-emitted dimensions would either retire useful operational granularity (collapse 40+ subtypes into ~10 buckets), force the cap to widen and defeat its working-memory rationale on the dimensions where it matters, or tolerate inconsistency silently. None is acceptable. The 25-cap was designed for user-facing dimensions where a human picks the value during write. System-utility dimensions are different — they need a different discipline.

**The governing discipline — log-subtype registry.** Every routine activity uses a STABLE, canonical tag value across runs: every `backlog-hygiene` execution tags `#log/backlog-hygiene` — never `#log/backlog-cleanup`, never `#log/backlog-audit`. The registry enumerates allowed values and the skill or cron that owns each. New subtypes register explicitly via the registration hook pattern (the adopter is prompted on first emission; the registration commits to Layer 3 vault-overlay with the owning skill declared). The discipline is structural — a registry + hook gate — not aspirational ("Claude should pick consistent log subtypes intelligently"). LLM choices are stochastic across runs; the registry preserves stability.

**Hook contract.** Writes to `Logs/` with a `#log/*` or `#status/*` tag are validated against the registry. Tag matches a registered value → ALLOW. Near-match (Levenshtein ≤2 or substring containment) → DENY with `did you mean #log/<canonical>?` suggestion. Genuinely new → require registration via the prompt-and-commit pattern. See [`enforcement-map-design.md`](./enforcement-map-design.md) §System-utility dimension exemption for the three-layer enforcement contract (registry primitive + skill-side declaration + hook gate).

**Field vs tag distinction.** The frontmatter `status:` *field* and the `#status/*` *tag* are independent surfaces governed by separate disciplines. The Strict tier requires the `status:` field on type entries that declare a status enum (`prd`, `personal-initiative`, etc.) — that's a field-level requirement, consumed by Claude. The `#status/*` tag mirrors the field value for user-side graph queryability — that's the tag-level mirror, exempt from the 25-cap. The full field-side framing lives in [`frontmatter-design.md`](./frontmatter-design.md) §System-utility dimension exemption; this packet covers the tag-side discipline.

## Per-archetype dimension relabeling

The 8 dimensions are the structural taxonomy. The vocabulary used to *describe* those dimensions is per-archetype. A consultant's `#engagement/*` slot occupies the same structural position as a developer's `#repo/*` or a researcher's `#topic/*`; the schema's `_tag_prefixes` declaration stays the same shape regardless of which vocabulary the adopter chose during onboarding. The multi-archetype union model itself (foundation: adopters compose archetype overlays + personal tracks; the user is the union, not the primary) lives in [`vault-construction-principles.md`](./vault-construction-principles.md) commitment 4; this section is the tag-side instantiation.

| Structural dimension | Consultant default | Developer | Researcher | Manager |
|---|---|---|---|---|
| Top-level client/customer relationship | `#engagement/*` | `#repo/*` | `#topic/*` | `#program/*` |
| Workstream within the relationship | `#project/*` | `#epic/*` | `#study/*` | `#initiative/*` |
| Content modality | `#scope/*` | `#scope/*` | `#scope/*` | `#scope/*` |
| Personal-track | `#initiative/*` | `#initiative/*` | `#initiative/*` | `#initiative/*` |
| BD/outbound surface (conditional) | `#artefact-bd/*` | n/a (not typical) | `#grant/*` (NIH applications, etc.) | n/a (typically) |
| Identity layer | `#about-me/*` | `#about-me/*` | `#about-me/*` | `#about-me/*` |
| Lifecycle state | `#status/*` | `#status/*` | `#status/*` | `#status/*` |
| System-utility log | `#log/*` | `#log/*` | `#log/*` | `#log/*` |

The first two rows are the load-bearing per-archetype variation. The Scope, Status, and Log dimensions are universal — every archetype produces decisions, action items, daily notes, and log files at the same modality. The Identity and Initiative dimensions are universal in shape; their values are archetype-specific.

**Synonym-matching at onboarding.** The onboarder infers the adopter's primary archetype (and 0..N secondaries) from a file-drop sample, proposes the renamed dimensions, and lets the adopter override at confirmation. The proposed names are inspiration depth (N=3 candidates per slot), not a cap — adopter language inferred from the file-drop wins ("major projects" not "engagements," "build" not "repo"). The schema's `_tag_prefixes` array stays the same shape; the dimension *names* are adopter-customized via Layer 3 vault-overlay.

### Worked example — consultant default → developer overlay

A consultant onboarding sees the default 8-dimension taxonomy with `#engagement/acme-corp` and `#project/data-platform` as the top-two Structural dimensions. The vault layout is `Engagements/Acme Corp/Projects/Data Platform/`. A meeting note at `Engagements/Acme Corp/Projects/Data Platform/Meetings/2026-05-12-touchbase.md` carries:

```yaml
tags:
  - "#engagement/acme-corp"
  - "#project/data-platform"
  - "#scope/decision"
  - "#status/processed"
  - "#log/meeting"
```

A developer onboarding activates the developer overlay: the structural top-two slots are renamed to `#repo/*` and `#epic/*`. The vault layout becomes `Repos/payments-service/Epics/checkout-redesign/`. The equivalent developer-archetype artifact (a design-doc or planning-session note) carries:

```yaml
tags:
  - "#repo/payments-service"
  - "#epic/checkout-redesign"
  - "#scope/decision"
  - "#status/processed"
  - "#log/meeting"
```

Both files conform to the same 8-dimension taxonomy at the structural level. The Scope, Status, and Log dimensions are unchanged; the top-two dimensions are relabeled. The folder-mirrors-tag invariant holds in both cases. Cross-archetype queries (every `#scope/decision` across the vault; every `#log/meeting` over the last 90 days) work identically because the universal dimensions hold their grammar across archetypes.

The R-37 lockstep coupled-surface for the developer overlay is the developer's narrative spoke (`System Governance - Tagging.md` rendered with developer vocabulary), the developer's `governance/tagging-rules.json` overlay entries, the hook's prefix regex extended to include `#repo/*` and `#epic/*`, and the schema's `_tag_prefixes.adopter_extensions` array entry. One commit; four artifacts; audit-time `governance-parity-audit` catches drift.

## Anti-patterns

The tagging discipline preempts a recurring set of failure modes. Anti-patterns shared with the frontmatter pillar (`#type/*` as a tag dimension; tags-duplicate-folders framing) cross-reference [`frontmatter-design.md`](./frontmatter-design.md) §Anti-patterns to avoid duplication.

| Anti-pattern | What goes wrong | Preempt with |
|---|---|---|
| **Folksonomy drift — "let users tag freely"** | One ad-hoc tag invites the next; within months the vocabulary fragments across `meeting`/`meetings`/`meeting-notes`, `client-a`/`ClientA`/`client_a`. User-side recall collapses; the tag system is present on every file and useful on none. | Closed-vocabulary picklist enforced at write-time (Rule 4 DENY). The friction is intentional — it converts a silent failure into a visible governance signal (Rule 5). |
| **Tags-as-descriptive-labels** | Tags accumulate as adjectives — `important`, `urgent`, `follow-up`, `interesting` — describing the file rather than indexing it. The vocabulary explodes; queries return everything and nothing because every file is "important." | Tags are query handles, not labels. Descriptive metadata belongs in the file body or in dedicated frontmatter fields (`priority:`, `status:`), not in the tag namespace. The closed dimension list and 25-cap (Rules 1–2) enforce the discipline. |
| **"I'll add tags later"** | Defers; never returns; the user-side graph permanently loses the file's filterability. Production-scale untagged-file backlogs (~500 files observed in a reference deployment) accumulate without write-time enforcement. | The system writes tags on every generated file (capture-is-cheap commitment). For manual files, the route skill infers + applies. The "later" empirically does not come. |
| **Freeform tags ad-hoc** | A user adds `#priority`, `#urgent`, `#client-facing` outside the registered dimensions; the field set fragments per-file; no user-side query consumes them; no consumer reads them. | Rule 4 DENY at the hook layer. Adopter either picks from the vocabulary, omits the tag, or runs R-37 lockstep to add a new dimension. |
| **New dimension without R-37 lockstep** | A clever insight at capture time produces a new prefix (`#priority/*`) without coordinated updates to the schema, rule registry, narrative spoke, and hook. The dimension exists in some surfaces and not others. | Rule 3. R-37 fires from the hook itself; a write that touches one of the four coupled artifacts without the others is DENY-blocked. |
| **"Claude should pick log subtypes intelligently"** | The temptation to let the LLM choose `#log/*` values at write-time. LLM choices are stochastic across runs; two `backlog-hygiene` runs produce two different tags; the operational subtype space fragments within weeks. | The log-subtype registry + hook gate. Every routine activity uses a STABLE, canonical tag value across runs. Near-match drift caught DENY; new subtypes register explicitly with operator review. |
| **Cap-widening when usage grows** | The adopter activates a new engagement; user-facing tag count approaches 25; the response is "raise the cap to 30." The cap was sized for working-memory; widening defeats its rationale silently. | Consolidation prompt at the audit-time threshold. The adopter is shown the active dimensions and asked whether any retired engagements / projects / scopes can be archived. Deliberate Layer 3 override is supported with audit trail; silent widening is rejected. |

**Cross-referenced anti-patterns (covered in [`frontmatter-design.md`](./frontmatter-design.md) §Anti-patterns; not duplicated here):**
- **`#type/*` collapsed into the `type:` frontmatter field** — file class lives at the field level, not as a tag dimension; the historic `#type/*` dimension was retired.
- **"Tags duplicate folders — why both?"** — folder + tag + field is a three-surface design honoring three different consumers; collapsing surfaces collapses query power.

## Open questions

- **OQ-T1** — exact JSON shape for encoding per-dimension allowlists (where applicable) in `governance/tagging-rules.json`. Closed-value dimensions like `#status/*` (reference-deployment values: `active | pending | processed | needs-review | complete`) carry explicit enumerations; open-value dimensions like `#engagement/*` carry only a prefix regex and rely on R-37 lockstep + onboarding flow for value registration. The schema constraint is locked at `governance/enforcement-map.schema.json`; the field shape resolves at hook-implementation time.

- **OQ-T2** — composition mechanism for multi-archetype overlays where dimension names overlap (a consultant who is also a researcher activates both `#engagement/*` and `#topic/*`). Single-archetype renaming is straightforward; two-archetype composition needs a mechanism that doesn't collide. Composition logic lands in the scaffold sub-plan's archetype-composition module; this packet locks the structural contract.

## Closed questions (with disposition)

- **CQ-T1** Should the dimension count be fixed at 4 (engagement / project / type / status)? → **No — expanded to 8 to fit the multi-archetype union and personal-tracks reality.** Rationale: the original 4-dimension vocabulary worked for a pure consultancy archetype; once personal initiatives, an internal BD surface, and an identity layer were activated, additional dimensions (`#initiative/*`, `#artefact-bd/*`, `#about-me/*`) emerged as load-bearing. The `#type/*` dimension was retired in favor of the frontmatter `type:` field (see [`frontmatter-design.md`](./frontmatter-design.md) anti-pattern table); the `#scope/*` dimension absorbed the content-modality role.

- **CQ-T2** Should the 25-tag cap apply uniformly across all dimensions? → **No — exempt system-utility dimensions (`#log/*`, `#status/*`).** Rationale: system-utility dimensions are machine-emitted; they never enter the user's working vocabulary. Governance moves to the log-subtype registry. See [ADR-0004](../../docs/decisions/0004-system-utility-dimension-exemption.md).

- **CQ-T3** Should the LLM pick `#log/*` values intelligently at write-time? → **No — log-subtype registry.** Rationale: LLM choices are stochastic across runs; the operational subtype space fragments within weeks. The registry preserves stability — every routine activity uses a canonical value across runs.

- **CQ-T4** Should tags be the primary query substrate for Claude-side routing? → **No — frontmatter fields are the Claude-side substrate; tags are the user-side mirror.** Empirically the live runtime hooks and skills route on frontmatter fields (`type:`, `engagement:`, `project:`, `provides:`, `status:`); no skill in the canonical surface queries vault content by `#tag` pattern. Tags exist for user-side graph view, filter pane, and MOC patterns. The two-surface design is honored by the folder-mirrors-tag invariant. See [`frontmatter-design.md`](./frontmatter-design.md) §Tags vs fields — who consumes what.

## Source pointers

- **Canonical rule registry**: `governance/tagging-rules.json` (R-37 lockstep peer of the schema's `_tag_prefixes` declaration; consumed by `pre-write-guard.sh` tag-validation branch)
- **R-37 lockstep coupled-surface peers**: `schemas/vault-schema.json` (`_tag_prefixes` + `_tag_prefixes_meta` declarations); `governance/tagging-rules.json`; `System Governance - Tagging.md` (narrative spoke rendered from the foundation-repo scaffold); `hooks/pre-write-guard.sh` (tag-validation branch + prefix-regex case)
- **Companion narrative packets**: [`frontmatter-design.md`](./frontmatter-design.md) (§Tags vs fields — who consumes what; §Folder-lineage convention; §System-utility dimension exemption — the field-side framing of the dichotomy this packet covers from the tag side), [`vault-construction-principles.md`](./vault-construction-principles.md) (commitment 4 multi-archetype union; commitment 5 folder-mirrors-tag invariant), [`enforcement-map-design.md`](./enforcement-map-design.md) (§R-37 atomic-lockstep protocol; §System-utility dimension exemption three-layer contract; §Folder-lineage convention R-32 hook contract), [`file-naming-conventions.md`](./file-naming-conventions.md) (§Slug grammar parity for folder-mirrors-tag invariant), [`content-length-limits.md`](./content-length-limits.md) (system-utility file class thresholds for `Logs/` surfaces)
- **Architecture decision records**: [ADR-0004](../../docs/decisions/0004-system-utility-dimension-exemption.md) (system-utility dimension exemption from 25-cap), [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md) (dual-surface governance architecture)
- **Live runtime artifacts (adopter-deployment paths, parameterized via install.sh)**: `hooks/pre-write-guard.sh` (Tier 2 DENY tag-validation branch; consumes `tagging-rules.json` at runtime); `hooks/post-write-verify.sh` (orphan-tag advisory); `skills/librarian/capabilities/tag-coverage-audit.sh` (audit-time coverage hygiene)
- **External research lineage**: Hedden — faceted classification (enterprise taxonomy literature, the canonical reference for multi-dimension classification systems); Forte — *Building a Second Brain* (working-vocabulary tagging-cap of 6–8 concurrent active tags); Dubois — faceted-classification literature (10-max cap per note); Adobe AEM and SharePoint — enterprise CMS picklist patterns (constrained tag assignment at write-time, the industry-converged model for controlled vocabularies under LLM-volume write loads)
