---
type: reference
description: Librarian archetype-consistency capability contract. Audit-time enforcement of R-41 (frontmatter pillar) field coverage across files declaring an archetype, plus R-51 (tagging pillar) write-time sibling validation.
provides:
  - archetype-consistency-capability
  - r41-audit-contract
  - sp05-hand-off
updated: 2026-05-12
tags: ["#scope/reference"]
---

# Librarian capability — archetype-consistency

**Status:** specified (implementation deferred to a downstream sub-plan)
**Pillar consumers:** R-41 (frontmatter) audit-time; R-51 (tagging) write-time sibling
**Source rules:** `governance/frontmatter-rules.json` R-41 + `governance/tagging-rules.json` R-51

## Purpose

Validate and surface drift in archetype-field-compliance across the vault. The capability walks every file declaring an archetype affiliation (either via the `archetype:` frontmatter field or via a `type:` entry with archetype binding declared in `governance/frontmatter-rules.json#types`), computes the per-archetype required-field intersection from `archetype_conditional_fields[<archetype>]`, and emits findings when any required field is missing or when the file declares an unknown archetype.

The capability is the audit-time counterpart of R-51 archetype-binding DENY in `pre-write-guard.sh` (write-time enforcement of the archetype-enum allowlist). The pair binds the multi-archetype union architectural commitment to both surfaces — write-time prevents unknown archetype values from landing; audit-time surfaces field-coverage drift on archetype-declaring files that already landed.

## Output Contract

**Files written:**
- Findings emitted to stdout (NDJSON; `librarian-finding` schema) and mirrored to `librarian-manifest.json` `drift_findings.archetype_consistency[]` via `manifest_set`. No vault file writes.

**Schema each is gated by:**
- NDJSON output validates against `librarian-finding-schema.json` (the canonical finding shape used by all librarian capabilities).
- Manifest subtree mirror validates against `librarian-manifest-schema.json` `drift_findings.archetype_consistency` (open `additionalProperties: true` object).

**Pre-write validation steps:**
- Read `governance/tagging-rules.json` R-51 `registered_archetypes` + Layer 3 overlay at `archetype_extensions.json` (if present); compute the union archetype-enum set.
- Read `governance/frontmatter-rules.json` `archetype_conditional_fields` + Layer 3 overlay extensions; compute the per-archetype required-field map.
- Validate every input read against its source schema before walking the vault.

**Failure mode:**
- `block and log` on schema-validation failure of source rules / archetype-enum / conditional-field declarations. The capability does not emit silent findings when its own inputs are malformed; it logs the schema-validation failure and aborts the audit run.
- Never `write and hope`.

## Finding categories

| Category | Severity | Trigger | Findings payload |
|---|---|---|---|
| `archetype-field-compliance-drift` | warning | A file declares `archetype: <X>` (or a `type:` with archetype binding to `<X>`) but is missing a field listed in `_archetype_conditional_fields[<X>].required` | `{file_path, archetype, missing_fields[], detected_at, first_seen}` |
| `archetype-not-in-enum` | warning | A file declares `archetype: <X>` where `<X>` is not in the registered archetype enum (foundation + Layer 3 overlay union). **Wave-2 redirect:** T-38 governance-authoring hook will intercept unknown-archetype writes and run the propose-and-confirm registration flow inline; this finding category will downgrade to a backstop emitting only when the hook itself fails or is disabled. | `{file_path, archetype, registered_archetypes[], detected_at, first_seen}` |
| `archetype-field-uses-retired-value` | info | A file carries an archetype-conditional field with a value referencing a retired archetype (per `retired_types` entries with `kind: archetype` in `governance/frontmatter-rules.json`) | `{file_path, field, value, retired_decision_ref, detected_at, first_seen}` |
| `archetype-overlay-orphan` | info | Layer 3 overlay declares an archetype enum value but no file in the vault carries that archetype | `{archetype, overlay_path, detected_at, first_seen}` |

Severity `warning` findings count against the librarian's session-close summary; `info` findings are surfaced but do not block close-out.

## Input sources

The capability reads from (in order):

1. **`governance/frontmatter-rules.json`** — `archetype_conditional_fields` (per-archetype required + optional field map); `archetype_enum` (foundation archetype enum); `retired_types` (for retired-archetype detection); R-41 `archetype_conditional_fields_source` + `exemptions` (paths that opt out of the audit).
2. **`governance/tagging-rules.json`** — R-51 `registered_archetypes` (foundation enum mirror) + `custom_archetype_overlay_path`.
3. **Layer 3 overlay-master (adopter)** — `overlay-master.frontmatter.archetype_extensions` per canonical §H (declared at `governance/_index.json#path_routing` if present; otherwise sibling to foundation pillars post-install).
5. **Vault walk** — every file under the configured vault root, filtered by R-41 exemptions (`tier: minimal`, `Archive/**`, files without `archetype:` field or archetype-binding type).

## Exemptions

The audit honors R-41 exemptions declared in `governance/frontmatter-rules.json`:

- Files declaring `tier: minimal` — opt-out from validation.
- Files under `Archive/**` — closed-lifecycle; archetype-completeness is preserved as historical record.
- Files without any archetype declaration — pre-archetype-era content remains in Standard tier without binding.

Exemption paths are read from R-41's `exemptions` field at audit time; do not hardcode the list in the capability implementation.

## Layer-3 collision handling

Per ADR-0006 (Layer-3 Overlay Collision Tiebreaker) + R-52 meta-rule: when adopter Layer-3 overlay and foundation canonical both declare the same archetype enum value, the adopter's declaration wins. Collision detection itself is **write-time-enforced in `pre-write-guard.sh`** (per R-52); this capability does not perform collision detection at audit-time. The capability's responsibility is field-coverage validation given the resolved (adopter-shadowed) archetype set. Required behavior:

- Read the adopter overlay first; foundation second.
- For shadowed archetype enums: use the adopter's `_archetype_conditional_fields[<X>]` declaration directly (adopter wins). Foundation's declaration for the same `<X>` is preserved-but-shadowed and does not enter the audit's field-coverage computation.
- Adopter renames are special-case shadows under a new name (per R-52 revision; no `_rename_history` field). The audit reads from the adopter's current declarations; foundation upgrades that touch shadowed entries surface via the `governance-parity-audit` `foundation-upgrade-touches-shadowed-entry` finding category, not via this capability.

## Implementation hand-off

The capability is specified at this contract; a downstream implementation sub-plan delivers the runtime at `~/.claude/skills/librarian/capabilities/archetype-consistency.sh` (or equivalent shell binary). Implementation requirements:

- **Atomic writes** — manifest updates via `manifest_set` (atomic temp+rename); no partial-state visibility.
- **Survivorship** — preserve `first_seen` on matched rows across runs; new rows append with the next sequence number; resolved rows drop on observing run.
- **Read-only** to vault files — the capability never edits vault content; findings inform the operator, who triages.
- **bash 3.2 compatible** — per CONTRIBUTING.md §The bash 3.2 compatibility constraint (no associative arrays, no `${var,,}` lowercasing, no `readarray`, etc.).
- **Output Contract** — the implementation MUST carry an Output Contract section in its SKILL.md or in-script header (files written, schema gated by, validation steps, failure mode) per CONTRIBUTING.md §The Output Contract rule.

## R-37 lockstep coupled surfaces

This contract is an R-37 lockstep peer with:

- `governance/frontmatter-rules.json` R-41 (the rule entry this capability audits)
- `governance/tagging-rules.json` R-51 (the write-time sibling enforcing archetype-enum at write)
- `governance/frontmatter-rules.json` `archetype_conditional_fields` + `archetype_enum` (the canonical declarations; SP13 T-4 absorbed from dissolved schemas/vault-schema.json)
- `onboarding/scaffold/vault-architecture/Vault Architecture - Frontmatter.md` §Archetype Extension Protocol (narrative spoke)
- `onboarding/scaffold/vault-architecture/Vault Architecture - Tagging.md` §Per-archetype dimension renaming (narrative spoke)

Changes to any of the above require R-37 atomic lockstep including this contract spec. New archetype additions, new conditional-field additions, and tier-compliance changes all touch this capability's behavior.

## References

- R-41 rule entry: `governance/frontmatter-rules.json`
- R-51 rule entry: `governance/tagging-rules.json`
- ADR-0006 (Layer-3 overlay collision tiebreaker): `docs/decisions/0006-layer3-overlay-collision-tiebreaker.md`
- Personalization model: `docs/personalization-model.md`
- Multi-archetype union research narrative: `research/vault-construction/vault-construction-principles.md` commitment 4
- Librarian-finding schema: `schemas/librarian-finding-schema.json` (foundation-repo canonical)
- Librarian-manifest schema: `schemas/librarian-manifest-schema.json` (`drift_findings.archetype_consistency` subtree)
