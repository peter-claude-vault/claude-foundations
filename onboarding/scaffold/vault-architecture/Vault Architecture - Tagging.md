---
type: reference
description: Tagging taxonomy, the 25-tag-cap discipline, folder-mirrors-tag invariant, system-utility dimension exemption, and the orphan-detection contract that keeps the user-side query surface navigable.
provides:
  - tagging-rules
  - 25-tag-cap
  - log-subtype-registry
  - folder-mirrors-tag-invariant
updated: 2026-05-12
max_lines: 250
tags: ["#scope/reference"]
---

> **Summary:** Authoritative reference for the 8-dimension faceted tagging taxonomy, the 25-tag cap on user-facing dimensions (with the system-utility exemption), the hierarchical `#dimension/value` grammar, the folder-mirrors-tag invariant, and the orphan-detection contract. Hand-authored narrative spoke; R-37 lockstep peer of `governance/tagging-rules.json`.
> **Canonical for:** tagging-rules, 25-tag-cap, log-subtype-registry, folder-mirrors-tag-invariant
> **Last substantive update:** 2026-05-12

# Vault Architecture — Tagging

Tags are the user-side query surface — the projection of structural file information into Obsidian's graph view, filter pane, and Map-of-Content (MOC) patterns. They are *not* the Claude-side substrate; Claude routes against frontmatter fields (`type:`, `engagement:`, `project:`, `provides:`, `status:`, `owner:`). The two surfaces mirror each other under the folder-mirrors-tag invariant, but they serve different consumers under different disciplines. The full Claude-side framing lives in [[Vault Architecture - Frontmatter]] §Tags vs fields; the long-form research narrative — research basis, anti-pattern catalogue, multi-archetype overlay, closed questions — is at the canonical [`tagging-strategy.md`](https://stem.peter.dev/research/vault-construction/tagging-strategy/) packet on the documentation site.

## The 8-dimension faceted taxonomy

The vault carries eight tag dimensions. Six are *user-facing* and subject to the 25-tag cap. Two are *system-utility* — machine-emitted by skills and crons; exempt from the cap; governed by the log-subtype registry instead. Adopter-customized names are emitted by the onboarder; the structural slots below are the canonical foundation.

| Dimension | Pattern | Example values | User-facing? |
|---|---|---|---|
| **Engagement** | `#engagement/{slug}` | `#engagement/acme-corp`, `#engagement/globex` | Yes — 25-cap |
| **Project** | `#project/{slug}` | `#project/data-platform`, `#project/customer-360` | Yes — 25-cap |
| **Scope** | `#scope/{slug}` | `#scope/decision`, `#scope/action-item`, `#scope/reference`, `#scope/briefing` | Yes — 25-cap |
| **Initiative** | `#initiative/{slug}` | `#initiative/foundations` | Yes — 25-cap |
| **BD-surface** | `#artefact-bd/{slug}` | `#artefact-bd/partnership-alpha` | Yes — 25-cap |
| **About-Me** | `#about-me/{slug}` | `#about-me/general`, `#about-me/career` | Yes — 25-cap |
| **Status** | `#status/{slug}` | `#status/active`, `#status/pending`, `#status/processed` | No — system-utility (exempt) |
| **Log** | `#log/{log-type}` | `#log/digest-run`, `#log/session-close`, `#log/cron-error`, `#log/meeting` | No — system-utility (exempt) |

The registered prefix list lives at `schemas/vault-schema.json` `_tag_prefixes`; the user-facing vs system-utility classification lives at `_tag_prefixes_meta`. Per-archetype renaming (developer's `#repo/*` in the Engagement slot, researcher's `#topic/*`, etc.) is declared via Layer 3 vault-overlay; the schema shape is unchanged.

## The five discipline rules

The discipline is what keeps the user-side surface useful. Each rule names a research basis, a user-facing rationale, and the enforcement layer that catches violations.

### 1. 25-tag cap on user-facing dimensions (R-50)

The total count of distinct values across the six user-facing dimensions stays under 25. The cap reflects working-memory research (Forte recommends 6–8 concurrent active tags; Dubois caps at 10; enterprise CMS practitioners favor small controlled picklists). Past 25, decision fatigue produces variant-creation rather than canonical-term selection, the vocabulary fragments, and user-side recall collapses.

The librarian `tag-coverage-audit` capability emits an advisory when usage approaches 80% of the cap (≥20 active values), surfaces a consolidation prompt with retire-candidate recommendations, and rejects silent widening. Deliberate Layer 3 override at `tagging_cap_override.json` is supported with rationale + audit-trail entry. The cap is structural, not aspirational.

### 2. Hierarchical `#dimension/value` prefix grammar (R-32-taxonomy)

Every tag is two levels: hash, dimension, slash, value. The dimension is one of the registered prefixes. The value is a kebab-case slug matching `[a-z0-9-]` — lowercase, hyphenated, ASCII-only, no spaces or periods or underscores. The grammar is self-documenting (anyone reading a file's YAML knows what each tag classifies), eliminates the casefolding bug class that scatters near-duplicates, and parallels the slug grammar at `Vault Architecture - Structure` so the folder-mirrors-tag invariant holds without translation tables.

Pre-write-guard DENIES at write-time any tag failing the regex `^#[a-z][a-z0-9-]*/[a-z0-9][a-z0-9-]*$` or starting with an unregistered prefix.

### 3. No new dimension without R-37 atomic lockstep

The set of registered dimensions is closed. New dimensions land via a single coordinated commit touching four artifacts: the schema's `_tag_prefixes` declaration, `governance/tagging-rules.json`, this narrative spoke, and `hooks/pre-write-guard.sh`. The R-37 protocol fires from the hook itself — a write that touches one of the four without the others is DENY-blocked with the missing-surface enumerated.

The blast radius of a dimension addition is large (every consumer reads the prefix list; every adopter learns the taxonomy during onboarding). The change-management cost is the price of preserving the user-side query surface across vocabulary evolution.

### 4. No freeform tags — write-time DENY (R-32-taxonomy)

Any tag that does not start with one of the registered dimension prefixes is non-conforming. The pre-write-guard hook DENIES the write. The tool call fails. An audit record appends to the log.

Standard Obsidian workflow — periodic manual review of the tag pane, hand-consolidation of duplicates — cannot keep pace when an LLM is the primary author writing at volume. The DENY moves validation from periodic human review to real-time automated gating. The author either picks a tag from the registered vocabulary, omits the tag, or runs R-37 lockstep to extend the taxonomy with operator review.

### 5. Tagging failure as signal, not error (R-47)

When content cannot be cleanly tagged with the existing vocabulary, the system surfaces two possibilities: the taxonomy has a gap (a legitimate new category is needed) or the content is a misfit (it doesn't belong where it is being filed). Both are actionable signals. Neither is auto-resolved — the operator triages.

Pre-write-guard emits a Tier 1 advisory `[R-47 TAG PRESENCE]` when a non-exempt vault write has missing or empty `tags:` field. The librarian `tag-coverage-audit` walks the vault at audit time and surfaces longer-running orphans + near-miss patterns (`#scope/decisions` vs `#scope/decision` suggesting one is a typo) as advisory findings.

## System-utility dimension exemption (the log-subtype registry)

`#log/*` and `#status/*` are exempt from the 25-tag cap. They are machine-emitted; they never enter the user's working vocabulary at capture time. A reference deployment carried dozens of distinct `#log/*` values — canonical operational subtypes like `#log/digest-run`, `#log/session-close`, `#log/cron-error`, `#log/meeting`, `#log/backlog-hygiene`. The values are not noise; they are structurally distinct categories the operator queries.

The governing discipline is the **log-subtype registry** (`log-subtype-registry.json`). Every routine activity uses a STABLE, canonical tag value across runs — every `backlog-hygiene` execution tags `#log/backlog-hygiene`, never `#log/backlog-cleanup`, never `#log/backlog-audit`. New subtypes register explicitly via the prompt-and-commit pattern at first emission.

The pre-write-guard tag-validation branch consults the registry on every system-utility write. Match a registered value → ALLOW. Near-match (Levenshtein ≤ 2 or substring containment of an existing canonical value) → DENY with `did you mean #log/<canonical>?`. Genuinely new → require registration. The structural answer to "Claude should pick log subtypes intelligently" is a registry + hook gate; LLM choices are stochastic across runs, and the registry preserves stability.

## Folder-mirrors-tag invariant

Every Structural dimension (`#engagement/*`, `#project/*`, `#initiative/*`, `#artefact-bd/*`, `#about-me/*`) maps to a corresponding folder root, and every file under that folder carries the matching tag. A meeting note at `Engagements/acme-corp/Projects/data-platform/Meetings/2026-05-12-touchbase.md` carries:

```yaml
tags:
  - "#engagement/acme-corp"
  - "#project/data-platform"
  - "#scope/decision"
  - "#status/processed"
  - "#log/meeting"
```

The invariant exists because Obsidian's graph view renders tags but not folders cleanly — without the tag-side mirror, the user loses graph-view filterability for the entire structural hierarchy. The field-level rule (`engagement:` and `project:` frontmatter fields propagated from folder ancestry) is the Claude-side counterpart; the two surfaces are mandated together at write-time. The field-level enforcement contract lives in [[Vault Architecture - Frontmatter]] §Folder-lineage convention.

## Per-archetype dimension renaming

The 8 dimensions are the structural taxonomy; the vocabulary used to describe them is per-archetype. A consultant's `#engagement/*` slot occupies the same structural position as a developer's `#repo/*` or a researcher's `#topic/*`. The schema's `_tag_prefixes` declaration stays the same shape regardless of which archetype the adopter selected during onboarding.

| Structural dimension | Consultant | Developer | Researcher | Manager |
|---|---|---|---|---|
| Top-level client/customer relationship | `#engagement/*` | `#repo/*` | `#topic/*` | `#program/*` |
| Workstream within the relationship | `#project/*` | `#epic/*` | `#study/*` | `#initiative/*` |
| Content modality | `#scope/*` | `#scope/*` | `#scope/*` | `#scope/*` |
| Lifecycle state | `#status/*` | `#status/*` | `#status/*` | `#status/*` |
| System-utility log | `#log/*` | `#log/*` | `#log/*` | `#log/*` |

The top-two dimensions are the load-bearing per-archetype variation. Scope, Status, and Log are universal — every archetype produces decisions, action items, daily notes, and log files at the same modality.

Adding a new archetype requires R-37 lockstep at the schema's `_archetype_enum` + `governance/tagging-rules.json` R-51 binding rule + this spoke + the archetype-conditional field extensions. The pre-write-guard `archetype-binding` branch DENIES writes whose `archetype:` field value is not in the registered enum (or in the Layer 3 vault-overlay `archetype_extensions.json` for adopter-declared custom archetypes).

## Orphan detection and canonical exemptions

Non-exempt files written without tags become orphans in Obsidian graph view — invisible to user-side queries even though the file is legible to Claude via its frontmatter fields. R-47 closes the write-time loop: the pre-write-guard advisory fires the moment a non-exempt file lands without tags.

**Exempt paths.** The R-47 advisory honors a positive-list exempt enumeration — unenumerated paths default to the advisory firing. Current exempt paths (`r47_exempt_paths` in `governance/tagging-rules.json`):

- `Archive/**` — archived content lifecycle is closed; tag-absence is structurally legitimate.
- `Logs/foundations-essays/**`, `Logs/backlog-progress/**` — machine-emitted scratch zones with distinct lifecycle.
- `Tags/**` — Obsidian tag pane metadata, not vault content.
- `_test*` — fixture files for hook regression testing.
- `.claude/**` — Claude Code internal state, not vault content.
- `Logs/ideation-brief-*.md` — symlinks pointing outside-vault to the plan tree; the canonical file lives elsewhere and is governed by a different schema.

Adding a new exempt path requires R-37 atomic lockstep updating R-47 + `pre-write-guard.sh` + this spoke. New top-level folders that need tag-absence tolerance must declare so explicitly; the default behavior is the advisory fires.

## Anti-patterns

| Anti-pattern | What goes wrong | Preempt with |
|---|---|---|
| **Folksonomy drift — "let users tag freely"** | One ad-hoc tag invites the next; within months the vocabulary fragments across `meeting`/`meetings`/`meeting-notes`. User-side recall collapses; the tag system is present on every file and useful on none. | R-32-taxonomy DENY at write-time. The friction is intentional — converts a silent failure into a visible governance signal (R-47). |
| **Tags-as-descriptive-labels** | Tags accumulate as adjectives — `important`, `urgent`, `interesting` — describing the file rather than indexing it. The vocabulary explodes; queries return everything and nothing. | Tags are query handles, not labels. Descriptive metadata belongs in the file body or in dedicated frontmatter fields (`priority:`, `status:`). R-32-taxonomy + R-50 enforce the discipline. |
| **"I'll add tags later"** | Defers; never returns; the user-side graph permanently loses the file's filterability. Production-scale untagged-file backlogs accumulate (~500 files observed in a reference deployment) without write-time enforcement. | The system writes tags on every generated file (capture-is-cheap commitment). R-47 surfaces orphans at write-time. The "later" empirically does not come. |
| **Cap-widening when usage grows** | An adopter activates a new engagement; user-facing tag count approaches 25; the response is "raise the cap to 30." The cap was sized for working-memory; widening defeats its rationale silently. | R-50 consolidation prompt at the 80% audit-time threshold. Adopter is shown active dimensions and asked whether retired engagements / projects / scopes can be archived. Deliberate Layer 3 override is supported with audit trail. |
| **"Claude should pick log subtypes intelligently"** | LLM choices are stochastic across runs; two `backlog-hygiene` runs produce two different tags; the operational subtype space fragments within weeks. | R-05 log-subtype registry + hook gate. Every routine activity uses a STABLE, canonical tag value across runs. Near-match drift DENIED with suggestion. |
| **`#type/*` as a tag dimension** | A user attempts `#type/meeting-note` or `#type/prd` to mirror the frontmatter `type:` field. The tag-side dimension duplicates a field-side classifier without adding query power; the two surfaces drift independently. | File class lives at the field level (`type:`), not as a tag dimension. The historic `#type/*` prefix was retired; `#scope/*` absorbed the content-modality role. Full framing at [[Vault Architecture - Frontmatter]] §Anti-patterns. |

## Where to learn more

- Long-form research narrative — research basis, multi-archetype overlay, closed questions: [`tagging-strategy.md`](https://stem.peter.dev/research/vault-construction/tagging-strategy/)
- Claude-side substrate (the field side of the tag/field dichotomy): [[Vault Architecture - Frontmatter]]
- Machine-readable rule registry: `governance/tagging-rules.json`
- System-utility exemption design rationale: [ADR-0004](https://stem.peter.dev/decisions/0004-system-utility-dimension-exemption/)
- Dual-surface governance pattern: [ADR-0005](https://stem.peter.dev/decisions/0005-two-surface-governance-dual-pattern/)
