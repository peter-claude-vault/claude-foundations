# ADR-0004: System-Utility Dimension Exemption from Tag Cap

**Status:** accepted
**Date:** 2026-05-11
**Deciders:** Foundation-repo architecture (Plan 81 SP03)
**Tags:** tagging, governance, taxonomy

## Context

The faceted tagging taxonomy applies a **25-tag cap** to distinct values across user-facing dimensions — a discipline grounded in cognitive working-memory research (Forte 6-8 working; Dubois 10 max; the 25 ceiling is the practical upper bound at which a human can hold the vocabulary in working memory and an AI can reliably route).

Empirical measurement of the reference vault at design-review time: **46 distinct `#log/*` values** were in active use. The values are canonical operational subtypes — `#log/digest-run`, `#log/session-close`, `#log/cron-error`, `#log/meeting`, etc. — emitted by skills, crons, and capabilities at write-time. They are not noise; they are structurally distinct categories the operator queries.

If the 25-cap were enforced uniformly across all dimensions:

1. Retire useful operational granularity (collapse 46 log subtypes into ~10 buckets, losing query power)
2. Widen the cap to ~50, which defeats its working-memory rationale for the dimensions where it matters
3. Tolerate the inconsistency silently (which produces drift, not discipline)

None of the three is acceptable. The 25-cap was designed for **user-facing** dimensions where a human picks the value during write. System-utility dimensions are different: they're machine-emitted by skills, crons, and capabilities; the operator never picks the value at capture time.

## Decision

- **Exempt system-utility dimensions from the 25-cap.** `#log/*` and `#status/*` are exempt. They are machine-emitted; they never enter the user's working vocabulary.
- **Apply the 25-cap to user-facing dimensions only.** `#engagement/*`, `#project/*`, `#scope/*`, `#initiative/*`, `#artefact-bd/*`, `#about-me/*` (plus adopter-defined custom dimensions where the user picks the value).
- **System-utility dimensions are governed by a different discipline — the log-subtype registry.** Every routine activity uses a STABLE, canonical tag value across runs. The registry enumerates allowed values + the skill/cron that owns each.
- **Hook contract for the log-subtype registry:** writes to `Logs/` with a `#log/*` or `#status/*` tag are validated against the registry. Tag matches a registered value → ALLOW. Near-match (Levenshtein distance ≤2 or substring containment) → DENY with "did you mean #log/<canonical>?" suggestion. Genuinely new → require registration via Hook A pattern.
- **Schema encoding:** `vault-schema.json._tag_prefixes_meta.system_utility_dimensions: ["log", "status"]` + `cap_25_applies_to: "user_facing_dimensions only"`.

## Consequences

**Positive:**
- Operational granularity preserved. Different routine activities can carry distinct, queryable log subtypes without collision.
- The 25-cap remains structurally honest for the dimensions it was designed for (user-facing, working-memory-bounded).
- Drift prevention is structural (registry + hook) rather than aspirational (a soft convention that "Claude should pick consistent log subtypes").
- New log subtypes register explicitly with operator review — no silent vocabulary growth.

**Negative:**
- Two disciplines instead of one. Authors must understand which dimensions get the 25-cap and which get the registry.
- The registry must be maintained — adding a new skill that emits a new log subtype is an R-37-style lockstep change (skill SKILL.md declares `log_subtype:` + registry entry added).
- Adopters who want to use a custom system-utility dimension (e.g., `#health/*` for system health signals) must register their custom dimension as a `system_utility_dimensions` extension via Layer-3 overlay.

**Neutral:**
- Frontmatter `status:` field (the schema's `conditional_required` for some types) is independent of the `#status/*` tag dimension. The field is required by the schema's tier model; the tag is governed by the system-utility exemption. Both surfaces hold; neither is redundant.

## Source decision provenance

- Plan 81 SP03 spec §Tagging spec — System-utility dimension exemption (D2 resolution, 2026-05-11) (`~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md` L88-91)
- Plan 81 SP03 Session 4 follow-up handoff narrative (`~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/handoff.md` L1044-1120 — D2 resolution)
- Empirical measurement: 46 distinct `#log/*` values in reference vault at design-review time
- T-34 log-subtype-registry mechanism specification (in flight at Plan 81 SP03)
- Foundations-doc-7 (Vault/Logs/foundations-docs/07-the-tagging-taxonomy.md) — 137-line research treatment citing Hedden, Forte, Dubois, Adobe AEM, SharePoint

## Related ADRs

- [ADR-0001](./0001-tiered-compliance.md) — frontmatter `status:` field is required by the tier model; this ADR governs the `#status/*` tag dimension separately
- [ADR-0005](./0005-two-surface-governance-dual-pattern.md) — the log-subtype registry is governed across the JSON + narrative surfaces via R-37 lockstep
