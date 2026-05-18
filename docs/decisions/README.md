# Architecture Decision Records (ADRs)

This directory holds the decision history that shaped Claude Stem's architecture. Format follows the Cognitect/Nygard ADR pattern.

## Purpose

ADRs are the **audit-trail tier** of Claude Stem's three-tier content discipline (per `../../CONTRIBUTING.md` and the `feedback_content_tier_discipline` memory). They carry:

- The decision title and date (machine-parseable)
- The deciders and stakeholders
- The context that produced the decision (the build-tier provenance — internal-process refs, incident classes, plan numbers, etc.)
- The decision itself
- Consequences (positive, negative, neutral)

ADRs are NOT meant for the casual adopter. They exist so that a future-self auditor (human or LLM) can trace "why does this thing work this way" back to the design moment without polluting the consumer-facing surfaces (`research/`, `governance/`, `schemas/`, `System Governance/`).

## ADR format

```markdown
# ADR-NNNN: Title

**Status:** {accepted | superseded | deprecated}
**Date:** YYYY-MM-DD
**Deciders:** {names or roles}
**Tags:** {comma-separated topics}

## Context

What is the problem we're trying to solve? What forces are at play? Include the build-tier provenance here — plan numbers, session refs, incident reports, empirical signals that drove the decision.

## Decision

What did we decide? State it as a concrete commitment, present tense.

## Consequences

What are the positive, negative, and neutral consequences of this decision? What does this enable? What does this foreclose?

## Source decision provenance

Bullets pointing to the original design moments — plan-tree paths, postmortems, session refs. This is the "internal-process audit trail" that ship-tier surfaces don't carry.

## Related ADRs

Optional. Cite by stable filename (e.g., `[ADR-0001](./0001-tiered-compliance.md)`).
```

## Numbering convention

- ADRs are numbered `NNNN-` (zero-padded, 4 digits, allows 9999 ADRs)
- Numbers are **assigned in chronological order of decision** (not by topic, not by sub-plan)
- Numbers are **stable** — once assigned, the ADR keeps its number even if superseded
- Superseded ADRs stay in the directory with `Status: superseded` + a pointer to the replacement ADR

## ADR index

| # | Title | Status | Date | Tags |
|---|---|---|---|---|
| [0001](./0001-tiered-compliance.md) | Tiered Compliance (Strict / Standard / Minimal frontmatter) | accepted | 2026-05-12 | frontmatter, governance |
| [0002](./0002-unified-with-per-archetype-entries.md) | Unified-with-Per-Archetype-Entries Schema Model | accepted | 2026-05-12 | schema, extensibility |
| [0003](./0003-folder-lineage-as-fields.md) | Folder Lineage as Fields, Not Types | accepted | 2026-05-12 | frontmatter, schema, taxonomy |
| [0004](./0004-system-utility-dimension-exemption.md) | System-Utility Dimension Exemption from Tag Cap | accepted | 2026-05-12 | tagging, governance |
| [0005](./0005-two-surface-governance-dual-pattern.md) | Two-Surface Governance Dual Pattern (JSON + narrative spoke) | accepted | 2026-05-12 | governance, architecture |

## Cross-references from ship-tier artifacts

Ship-tier artifacts (research packets, governance JSONs, schemas, narrative spokes) cite ADRs via `source_dependencies:` frontmatter and inline `[ADR-NNNN](../../docs/decisions/NNNN-*.md)` links where rationale is load-bearing.

The build-tier content (plan refs, decision dates, session refs, internal-process names) MUST live in ADRs, not in ship-tier prose. See `../../CONTRIBUTING.md` for the full content-tier discipline.
