# ADR-0001: Tiered Compliance (Strict / Standard / Minimal frontmatter)

**Status:** accepted
**Date:** 2026-05-12
**Deciders:** Foundation-repo architecture (Plan 81 SP03)
**Tags:** frontmatter, governance, validation

## Context

The vault schema needs to apply at write-time across a wide range of file classes — system-emitted artifacts (scaffold output, scraper aggregations, meeting-processor pipeline output) AND user-authored content (PRDs, context docs, people files, ad-hoc references) AND explicit opt-outs (legacy imports, paste-buffer scratch, archives outside lifecycle). One uniform enforcement policy fails in three different ways for these three consumers:

- A hard DENY on user-authored content punishes capture rate. Pre-cleanup, the reference vault accumulated ~500 untagged files in `Logs/` before any write-time enforcement landed — the failure mode of "we'll add tags later."
- A soft-warn-only on system-emitted content invites silent bugs. The scaffold or auto-router can emit half-formed files that pass validation and break downstream consumers.
- A blanket allow on legacy imports loses the audit visibility — files outside the system never surface for review.

Three different consumers, three different costs of non-conformance, three different responses required.

## Decision

The frontmatter schema declares **three compliance tiers**, applied per-type:

| Tier | validation_behavior | Default file class |
|---|---|---|
| Strict | DENY at write-time (Tier 2 hook gate) | System-emitted files: scaffold output, `/ingest`-routed content, scraper aggregations |
| Standard | Soft warn at write-time + librarian session-close audit | User-authored vault content |
| Minimal | No validation, flagged "outside system" by librarian | Explicit per-file opt-out via `tier: minimal` directive |

Tier assignment is per-type in the schema (not per-file). Adopters customize tier assignments via Layer-3 vault-overlay; foundation-repo defaults reflect a consultant-archetype reference instantiation.

## Consequences

**Positive:**
- Capture-rate preserved for user-authored content (Standard's soft warn doesn't block writes).
- System-emitted bugs caught at write-time (Strict's DENY prevents half-formed files).
- Opt-out is explicit and auditable (Minimal files are visible to the librarian, just exempt from validation).
- Tier choice maps to **who owns the write** (system vs user vs explicit-opt-out) — a structurally honest framing.

**Negative:**
- Three tiers is more complexity than one. New authors must learn the tier model.
- Per-type tier assignments require schema updates (R-37 lockstep) when a new type lands.
- Adopters who want to override tier assignments must operate via Layer-3 vault-overlay rather than editing the foundation-repo schema directly.

**Neutral:**
- The tier system is the load-bearing primitive other rules ride on (R-32 Tier 2 DENY, R-39 frontmatter-coverage audit, R-47 advisory orphan detection). Removing it would require redesigning enforcement from scratch.

## Source decision provenance

- Plan 81 SP03 spec §Frontmatter schema — 3 compliance tiers (`~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md` L27-46)
- Plan 71 SP09 postmortem (R-32 incident class — schema/hook divergence root cause; the original incident that motivated tier separation as structural primitive): `~/.claude-plans/71-claude-foundations-engine-v2/09-live-mutation-remediation/POSTMORTEM-2026-04-28-live-mutation-creep.md`
- Live reference deployment validation: tier model has run on the reference vault for multiple weeks before foundation-repo port
- T-1 schema authoring (Plan 81 SP03 Session 7) where tier definitions ratified as the schema's load-bearing primitive

## Related ADRs

- [ADR-0002](./0002-unified-with-per-archetype-entries.md) — extends this tier model to per-archetype type entries
- [ADR-0005](./0005-two-surface-governance-dual-pattern.md) — tier definitions are mirrored across the JSON + narrative surfaces via R-37 lockstep

---

## SP13 Post-Onboarding Governance Architecture — Amendment (2026-05-16)

**Governance source of truth migrated from `vault-schema.json` to `foundation-master.json` bundle.** This ADR describes a tier system whose tier assignments live in the schema. Per the SP13 canonical governance architecture:

- `vault-schema.json` is **dissolved**. Type registry and tier assignments now live in `governance/frontmatter-rules.json#types[]`.
- Hooks read tier and type information exclusively from `governance/foundation-master.json` (the composed bundle shipped at install time), not from `vault-schema.json` directly.
- The three-tier model (Strict / Standard / Minimal) is unchanged. Per-type tier assignments are now declared in `frontmatter-rules.json` and composed into the bundle via `tools/build-foundation-master.sh` at foundation-repo release time.
- Adopters customize tier assignments via `overlay-master.json` (the Layer-3 overlay parallel), not by editing the foundation-repo schema.

See `foundation-governance-target-state.md` §A (6-pillar governance set) and §B (foundation-master bundle) for the canonical reference.
