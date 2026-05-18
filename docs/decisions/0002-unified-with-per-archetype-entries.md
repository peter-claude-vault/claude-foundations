# ADR-0002: Unified-with-Per-Archetype-Entries Schema Model

**Status:** accepted
**Date:** 2026-05-12
**Deciders:** Foundation-repo architecture (Plan 81 SP03)
**Tags:** schema, extensibility, frontmatter

## Context

The frontmatter schema must support multiple archetypes (consultant, researcher, developer, manager, plus adopter-defined customs) without forking. Two viable encodings surfaced during design:

1. **Multi-file per-type:** One JSON file per type (`schemas/meeting-note.json`, `schemas/prd.json`, etc.). Schema-walkers read N files. Hooks load N artifacts. Adding a type means adding a file.
2. **Unified-with-per-archetype-entries:** One schema file with cross-cutting blocks at the top (tiers, archetype-conditional fields, packet-only fields, path rules, tag prefixes) plus one per-type entry below declaring its `tier`, `required` field list, `optional` field list.

Choice (1) distributes complexity and makes adding a type cheap but makes runtime expensive (N reads) and makes per-archetype variation N×M files. Choice (2) keeps runtime cheap (one read, case-statement switch) and lets per-archetype variation live as additional per-type entries inside the unified declaration.

The reference deployment ran choice (2) on a single hand-authored schema for multiple weeks before foundation-repo port — empirical validation that the unified shape holds under real evolution.

## Decision

Use the **unified-with-per-archetype-entries** model:

- One schema file at `claude-stem/schemas/vault-schema.json`
- Cross-cutting structures declared at the top (`tiers`, `_archetype_conditional_fields`, `_packet_only_fields`, `_path_rules`, `_tag_prefixes`)
- One entry per type below, declaring `tier`, `required`, `optional`
- Hooks load the schema once, switch on `type:` via case statement, validate against the matching entry
- Adding a new type is one entry + one hook branch + one narrative-spoke table row (all under R-37 atomic lockstep)
- Adopters extend via Layer-3 vault-overlay (additional per-type entries, additional `_path_rules` entries) without touching foundation-repo canonical

## Consequences

**Positive:**
- One runtime artifact across all enforcement points (low load cost; one place to inspect).
- Adding a type is a bounded R-37 commit (schema entry + hook branch + spoke row).
- Adopter extensibility lives inside the same shape — no overlay-file forking, no shadow schemas.
- Tier definitions live once at the top; per-type entries reference the tier names by enum value.
- The narrative spoke (`System Governance - Frontmatter.md`) documents the universal sections once + enumerates per-type entries in a table — one-to-one with the schema.

**Negative:**
- The schema file grows as types accumulate. The reference deployment hit ~13K / 474 lines at 21 active types; ship-tier discipline holds the file readable but it's monolithic.
- Refactoring a tier definition (e.g., adding a new universal field) touches every per-type entry by implication, even though the entry definitions don't change. Test discipline (parse schema + assert tier conformance) is mandatory.
- The case statement in the hook must stay in sync with the schema's per-type entries (R-37 lockstep enforces this).

**Neutral:**
- The model permits any per-type extensibility — adopters can add archetype-specific types (researcher's `study-phase`, developer's `repo-deliverable`) without schema-shape changes.
- The narrative spoke is hand-authored, not generated. See [ADR-0005](./0005-two-surface-governance-dual-pattern.md) for the dual-surface rationale.

## Source decision provenance

- Plan 81 SP03 spec §Frontmatter schema — Extensibility model (`~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md` L45)
- T-1 canonical schema authoring (Plan 81 SP03 Session 7, 2026-05-12) where the unified shape was ratified after considering multi-file alternative
- Live reference deployment: `~/.claude/hooks/vault-schema.json` ran the unified shape for ~4 weeks pre-foundation-repo port; the shape held under multiple type additions (`briefing`, `strategic`, `planning`, `archive`, `historical-brief`, `packet`, `archetype-template`) without refactor

## Related ADRs

- [ADR-0001](./0001-tiered-compliance.md) — tier model the per-type entries reference
- [ADR-0003](./0003-folder-lineage-as-fields.md) — explains why `engagement` and `project` are FIELD slots, not TYPE entries
- [ADR-0005](./0005-two-surface-governance-dual-pattern.md) — narrative spoke is hand-authored, not generated from this schema

---

## SP13 Post-Onboarding Governance Architecture — Amendment (2026-05-16)

**`vault-schema.json` dissolved; unified model migrated to `frontmatter-rules.json`.** The "unified-with-per-archetype-entries" shape ratified here is preserved, but the artifact has changed:

- `schemas/vault-schema.json` is **dissolved**. The unified type-registry content (cross-cutting blocks + per-type entries) now lives in `governance/frontmatter-rules.json`.
- `_tag_prefixes` block moves to `governance/tagging-rules.json#taxonomy.dimension_prefixes`.
- `_path_rules` block is retained in `governance/frontmatter-rules.json#path_routing`.
- The hook's case-statement switch remains one-read, one-artifact — but the artifact is now `governance/foundation-master.json` (the composed bundle) read at session start, not `vault-schema.json` read per-write.

The one-schema/unified-shape architectural choice is unchanged. The **physical artifact** is now the composed bundle; the **logical shape** remains per-type entries in the frontmatter pillar.

See `foundation-governance-target-state.md` §A (pillar 1 — frontmatter-rules.json) and §B (foundation-master bundle) for the canonical reference.
