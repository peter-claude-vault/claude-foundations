# ADR-0006: Layer-3 Overlay Collision Tiebreaker

**Status:** accepted
**Date:** 2026-05-12
**Deciders:** Foundation-repo architecture
**Tags:** governance, extensibility, layer-3-overlay, collision-resolution

## Context

Foundation-repo permits adopter extension via several mechanisms documented in the personalization model:

- `additionalProperties: true` on rule entries in `enforcement-map.schema.json` — adopters add fields per rule without schema-shape changes.
- `_archetype_enum` extension via Layer 3 vault-overlay — adopters declare custom archetypes (researcher, developer, manager extensions, or wholly new archetypes like "curator").
- `_path_rules.rules[]` extension — adopters add archetype-specific folder-lineage rules without altering existing rules.
- `_archetype_conditional_fields` extension — adopters add fields the foundation does not declare (researcher's `study_phase`, developer's `repo`, etc.).
- Rule-registry extensions — adopters add Layer-3 rules (e.g., `tagging_cap_override.json`, `drift_allowlist.json`) that supplement foundation rules.

The personalization model is the load-bearing extensibility surface — every adopter customization runs through it. Without it, the foundation-repo would force adopters to fork rather than overlay, and adoption stalls.

But the model has a gap. When adopter Layer-3 overlay and foundation canonical both declare the same rule ID, the same archetype enum value, or the same entry kind in an extensible array, there is no documented resolution rule. The mechanical answer (whatever the runtime hook reads last) is silent — neither the adopter nor the foundation-repo maintainer sees the collision until production surfaces it. Symptoms range from "the new rule didn't fire" to "the foundation rule broke after an overlay edit" to "two rules with the same ID compete unpredictably."

The collision class is not hypothetical. The adoption pattern explicitly invites it:
- An adopter adds a custom archetype and a foundation release later adds an archetype with the same name.
- An adopter adds a Layer-3 rule for `provides-canonicality` with adjusted scope and a foundation upgrade redefines R-40 with overlapping scope.
- An adopter extends `_path_rules` with a folder-lineage rule and a foundation upgrade adds a structurally similar rule.

The Personalization-seams audit identified this as a HIGH-IMPACT gap because adopter Layer-3 customizations are the load-bearing extensibility surface and silent collisions undermine the entire model.

## Decision

**Adopter Layer-3 SHADOWS foundation canonical.** When adopter Layer-3 overlay and foundation canonical both declare the same rule ID, archetype enum value, or entry kind, the adopter's declaration wins. The foundation declaration is preserved (not deleted) but does not fire; the adopter's overlay is the live entry.

**Three structural commitments make the tiebreaker safe:**

1. **Adopter explicit override.** The Layer-3 overlay carries a required `_override_reason` field on any entry that shadows a foundation declaration. The reason is free-text but mandatory — silent shadowing is rejected. Audit-time tooling reads the field to surface what was overridden and why.

2. **Rename history preserved.** When an adopter renames a foundation entry (e.g., archetype `consultant` → `practitioner`), the Layer-3 overlay carries a `_rename_history` field with the original foundation identifier. The renaming is one-directional (adopter cannot un-rename a foundation entry's identity), but the history makes the chain traceable.

3. **Collision audited at session-close.** The librarian `governance-parity-audit` capability emits a `layer3-collision` finding for every shadowing relationship. The finding is `informational` (not blocking) — adopter overrides are legitimate; the audit surfaces them for visibility, not refusal. A foundation upgrade that touches a shadowed entry surfaces as a `foundation-upgrade-touches-shadowed-entry` finding with severity `warning` so the adopter sees the upstream change and can decide whether to keep the override or absorb the upgrade.

**No write-time block.** The tiebreaker is audit-time enforcement only. Pre-write-guard does NOT DENY adopter Layer-3 writes that collide with foundation. The reasoning is structural: write-time DENY would force adopters to either rename or refuse foundation upgrades, and both choices undermine adoption. Audit-time visibility plus version-control merge-conflict surfacing (a foundation upgrade touching a shadowed entry produces a merge conflict in the adopter's vault repo) gives the adopter a deliberate review point without a hard block.

## Consequences

**Positive consequences:**

- **Adoption is unblocked.** Adopters customize without fearing foundation upgrades will silently rewrite their overlay choices. The shadowing rule guarantees customization persists across foundation releases unless the adopter actively chooses otherwise.
- **Foundation upgrades remain safe.** A foundation release touching a shadowed entry produces a merge conflict in the adopter's vault repo + a `governance-parity-audit` warning, both pointing the adopter at the change. The adopter consciously decides — absorb upstream, keep override, or fork to a third behavior.
- **Audit trail is complete.** Every shadowing relationship carries `_override_reason` and (when applicable) `_rename_history`. A future-reader walking the adopter's overlay sees what was customized, why, and what the foundation declared at customization time.
- **Identity stability survives renames.** Foundation upgrades that depend on stable identifiers (cross-referencing a rule by ID, looking up an archetype by enum value) continue to work because the foundation identifier is preserved in `_rename_history` even when the adopter's display name diverges.

**Negative consequences:**

- **Adopter responsibility grows.** The adopter must run `governance-parity-audit` at meaningful cadence (session-close, pre-release, post-foundation-upgrade) to see collision findings. The audit surfaces drift but does not act on it; if the adopter ignores the findings, drift accumulates silently within the adopter's overlay.
- **`_override_reason` discipline is human-only.** The field is required but free-text; an adopter can write "TODO" or "because" and the tiebreaker still operates. The discipline is the documentation contract, not a structural gate.
- **Foundation maintainers must consider override-friendliness.** Any change to foundation-repo's rule IDs, archetype enums, or entry kinds is a potentially-breaking change for adopters with overlays on those entries. Foundation upgrades should land as additive whenever possible; rename + retain rather than rename + remove.

**Alternatives considered and rejected:**

- **Foundation wins.** Foundation canonical always overrides adopter Layer-3. Rejected: adopters lose customizations on every foundation upgrade, which collapses the value of overlay-based personalization.
- **Newest timestamp wins.** Resolution by `updated:` field on competing entries. Rejected: brittle (clock skew, copy-paste of timestamps, lossy across forks); also unstable when foundation upgrade lands during adopter's active editing.
- **Hard rename required.** Adopters must rename any custom entry that could collide with foundation. Rejected: foundation cannot enumerate every name an adopter might want; rename pressure pushes adopters away from descriptive names.
- **Schema-side enforcement of disjoint namespaces.** Reserve specific ID ranges for foundation (R-01..R-49) vs adopter (R-100+). Rejected: forces adopters to learn an arbitrary numbering convention; does nothing for archetype enums or array entries; does not survive cross-org overlays.

**Why audit-time only and not write-time:** A write-time DENY would treat shadowing as an error. Shadowing is not an error — it is the documented extension pattern. The structural answer is: shadowing is *visible* at audit-time and *navigable* via version-control merge-conflict surfacing on foundation upgrades. The adopter sees collisions when they matter (at session-close + at upgrade time) without write-time friction during normal customization.

**SP05 hand-off:** The librarian `governance-parity-audit` capability (specified at T-33) must include the `layer3-collision` finding category and the `foundation-upgrade-touches-shadowed-entry` finding category. The capability reads the foundation `governance/_index.json` + the adopter's overlay files, computes the shadowing set, and emits the findings. No write-time hook implementation is required (audit-time enforcement only per this decision).

## References

- Meta-rule entry: `governance/_index.json` `cross_cutting_meta_rules[]` R-52 (Layer-3 Overlay Collision Tiebreaker)
- Companion ADR: [ADR-0005](./0005-two-surface-governance-dual-pattern.md) — the dual-surface pattern this tiebreaker extends
- Capability contract consumer: librarian `governance-parity-audit` (specified at the governance-parity-audit capability contract; collision-detection finding category is the load-bearing consumer of this decision)
- Personalization model: `docs/personalization-model.md` (the extensibility surface this tiebreaker resolves)
