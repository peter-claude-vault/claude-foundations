# ADR-0006: Layer-3 Overlay Collision Tiebreaker

**Status:** accepted
**Date:** 2026-05-13
**Supersedes:** prior draft 2026-05-12 (audit-time-only posture; rename-history field) — revised per operator direction for write-time enforcement and simpler shadowing protocol.
**Deciders:** Foundation-repo architecture
**Tags:** governance, extensibility, layer-3-overlay, collision-resolution

## Context

Foundation-repo permits adopter extension via several mechanisms documented in the personalization model:

- `additionalProperties: true` on rule entries in `enforcement-map.schema.json` — adopters add fields per rule without schema-shape changes.
- `_archetype_enum` extension via Layer 3 vault-overlay — adopters declare custom archetypes or rename existing ones to match their org vocabulary.
- `_path_rules.rules[]` extension — adopters add archetype-specific folder-lineage rules without altering existing rules.
- `_archetype_conditional_fields` extension — adopters add fields the foundation does not declare.
- Rule-registry extensions — adopters add Layer-3 rules (`tagging_cap_override.json`, `drift_allowlist.json`, etc.) that supplement foundation rules.

The personalization model is the load-bearing extensibility surface. Foundation archetypes are *references*, not constraints — every adopter ships with a unique folder and filing system, may add folders beyond defaults, and may rename or retire archetypes the foundation declares. The system adapts to the adopter's structure, not the reverse.

But the model has a gap. When adopter Layer-3 overlay and foundation canonical both declare the same rule ID, the same archetype enum value, or the same entry kind in an extensible array, there is no documented resolution rule. The mechanical answer (whatever the runtime hook reads last) is silent — neither the adopter nor the foundation-repo maintainer sees the collision until production surfaces it. Symptoms range from "the new rule didn't fire" to "the foundation rule broke after an overlay edit" to "two rules with the same ID compete unpredictably."

The collision class is not hypothetical. The adoption pattern explicitly invites it:

- An adopter adds a custom archetype and a foundation release later adds an archetype with the same name.
- An adopter adds a Layer-3 rule with adjusted scope and a foundation upgrade redefines the same rule ID with overlapping scope.
- An adopter extends `_path_rules` with a folder-lineage rule and a foundation upgrade adds a structurally similar rule.

The Personalization-seams audit identified this as a HIGH-IMPACT gap because adopter Layer-3 customizations are the load-bearing extensibility surface and silent collisions undermine the entire model.

## Decision

**Adopter Layer-3 SHADOWS foundation canonical.** When adopter Layer-3 overlay and foundation canonical both declare the same rule ID, archetype enum value, or entry kind, the adopter's declaration wins. The foundation declaration is preserved (not deleted) but does not fire; the adopter's overlay is the live entry.

**Two structural commitments make the tiebreaker safe:**

1. **Adopter explicit override.** The Layer-3 overlay carries a required `_override_reason` field on any entry that shadows a foundation declaration. The reason is free-text but mandatory — silent shadowing is rejected. The field exists for human readability: another engineer in the org, or future-adopter, or an upgrade reviewer can see *why* each foundation default was changed.

2. **Foundation upgrade visibility.** A foundation upgrade that touches a shadowed entry produces (a) a merge conflict in the adopter's vault repo at upgrade time and (b) a `foundation-upgrade-touches-shadowed-entry` warning finding from the librarian `governance-parity-audit` capability. The adopter sees the upstream change and consciously decides whether to keep the override or absorb the upgrade.

**Write-time enforcement.** Pre-write-guard DENIES adopter Layer-3 writes that shadow a foundation entry without `_override_reason`. The DENY is immediate, in-your-face, and the system's default — shadowing is an explicit act, not an accident.

**Escape hatch: per-write `--force-override` flag.** An adopter who wants to bypass the DENY for a single write adds `--force-override` to that write. The flag must be added each time; there is no persistent disable. The friction is by design — bypassing governance should require active opt-in per occurrence.

**No rename history field.** Adopter overlay overrides foundation entries by ID; rename is just a special case of shadow. If an adopter renames archetype `engagement` to `account`, their manifest declares `account` and every skill/hook reads from their manifest. The adopter's manifest IS the canonical naming; foundation upgrades that depend on the old name surface as merge conflicts at upgrade time (same channel as any other shadow + upgrade collision). No bridge field is needed.

**Layer-3 collision finding category retired.** Because write-time DENY catches shadowing at the write itself, the librarian `governance-parity-audit` capability does not need a `layer3-collision` finding category at audit time. The audit retains `foundation-upgrade-touches-shadowed-entry` (the upstream-driven surface that cannot be write-time-DENIED, because a foundation release is not an adopter write).

## Consequences

**Positive consequences:**

- **Adoption is unblocked.** Adopters customize without fearing foundation upgrades will silently rewrite their overlay choices. The shadowing rule guarantees customization persists across foundation releases unless the adopter actively chooses otherwise.
- **Foundation upgrades remain safe.** A foundation release touching a shadowed entry produces a merge conflict in the adopter's vault repo + a `governance-parity-audit` warning. The adopter consciously decides — absorb upstream, keep override, or fork to a third behavior.
- **Collisions are caught at the moment they're created.** Write-time DENY surfaces the override act when the adopter is writing the overlay, not days later when an audit runs. The adopter sees the system response immediately and provides the required `_override_reason` in the same edit.
- **Escape-hatch friction is per-write.** The `--force-override` flag has to be added each time the adopter wants to bypass the DENY. There is no "I turned it off three weeks ago and forgot" failure mode.
- **No naming-history surface to maintain.** Adopter renames are just shadows under a new name; no parallel `_rename_history` field has to be authored, validated, or cross-checked. The adopter's manifest is the canonical naming surface.

**Negative consequences:**

- **`_override_reason` discipline is human-only.** The field is required but free-text; an adopter can write "TODO" or "because" and the tiebreaker still operates. The discipline is the documentation contract, not a structural gate. The trade-off was deliberate: enumerating reason categories adds adopter write-time friction without providing meaningful machine signal.
- **Foundation maintainers must consider override-friendliness.** Any change to foundation-repo's rule IDs, archetype enums, or entry kinds is a potentially-breaking change for adopters with overlays on those entries. Foundation upgrades should land as additive whenever possible; rename + retain rather than rename + remove.
- **Write-time DENY couples adopter ergonomics to hook reliability.** The pre-write-guard hook must correctly identify shadowing writes. False positives (hook DENIES a non-shadowing write) cost adopter time; false negatives (hook misses a shadowing write) lose the immediate-visibility benefit. The hook's collision-detection logic carries the load that the audit-time capability used to carry.

**Alternatives considered and rejected:**

- **Foundation wins.** Foundation canonical always overrides adopter Layer-3. Rejected: adopters lose customizations on every foundation upgrade, which collapses the value of overlay-based personalization.
- **Newest timestamp wins.** Resolution by `updated:` field on competing entries. Rejected: brittle (clock skew, copy-paste of timestamps, lossy across forks); also unstable when foundation upgrade lands during adopter's active editing.
- **Hard rename required.** Adopters must rename any custom entry that could collide with foundation. Rejected: foundation cannot enumerate every name an adopter might want; rename pressure pushes adopters away from descriptive names.
- **Schema-side enforcement of disjoint namespaces.** Reserve specific ID ranges for foundation (R-01..R-49) vs adopter (R-100+). Rejected: forces adopters to learn an arbitrary numbering convention; does nothing for archetype enums or array entries; does not survive cross-org overlays.
- **Audit-time-only enforcement.** Catch shadowing in the librarian `governance-parity-audit` capability without write-time DENY. Rejected: the collision class is high-impact enough that adopters need immediate friction at the write itself. Audit-time alone defers the signal past the moment the adopter can most easily provide context (the write). The escape-hatch flag preserves adopter agency without sacrificing visibility.
- **Persistent disable in adopter config.** A one-time `governance_enforcement: disabled` setting in adopter config. Rejected: too easy to forget. An adopter who disabled enforcement three weeks ago to land a quick override forgets the system is silent on subsequent writes. Per-write `--force-override` flag preserves the friction.

**SP05 hand-off:** The librarian `governance-parity-audit` capability (specified at the governance-parity-audit capability contract) must include the `foundation-upgrade-touches-shadowed-entry` finding category. The `layer3-collision` finding category is retired (now write-time enforced). The write-time DENY logic is implemented in pre-write-guard.sh; the capability spec for the hook implementation is a sibling Wave-2 task (governance-authoring hook).

## References

- Meta-rule entry: `governance/_index.json` `cross_cutting_meta_rules[]` R-52 (Layer-3 Overlay Collision Tiebreaker)
- Companion ADR: [ADR-0005](./0005-two-surface-governance-dual-pattern.md) — the dual-surface pattern this tiebreaker extends
- Capability contract consumer: librarian `governance-parity-audit` (governance/librarian-capabilities/governance-parity-audit.md) — `foundation-upgrade-touches-shadowed-entry` finding category
- Personalization model: `docs/personalization-model.md` (the extensibility surface this tiebreaker resolves)
