---
type: reference
description: Librarian governance-parity-audit capability contract. Audit-time alignment-mechanism backstop for the dual-surface governance pattern — walks the four pillar JSONs + their narrative spokes + meta-spoke, emits drift findings categorized by pillar.
provides:
  - governance-parity-audit-capability
  - dual-surface-alignment-mechanism
  - layer3-collision-detection
updated: 2026-05-12
tags: ["#scope/reference"]
---

# Librarian capability — governance-parity-audit

**Status:** specified (implementation deferred to a downstream sub-plan)
**Pillar consumer:** the dual-surface governance pattern (cross-pillar; all four pillars + meta)
**Source decision:** [ADR-0005 Two-Surface Governance Dual Pattern](../../docs/decisions/0005-two-surface-governance-dual-pattern.md)

## Purpose

Audit-time alignment-mechanism backstop for the dual-surface governance pattern. Write-time R-37 atomic lockstep prevents partial-surface commits at the gate; this capability detects drift that lands despite the gate (manual filesystem edits, bypass scenarios, cross-foundation-and-overlay collisions). The two enforcement layers compose: R-37 closes the write path, governance-parity-audit closes the audit-time path.

The capability is the load-bearing companion to the dual-surface design. Without an audit-time check, drift between machine-readable governance JSONs and human-readable narrative spokes accumulates silently until adopter confusion surfaces it. The audit makes the drift visible at session-close, weekly cron, or on-demand invocation.

## Output Contract

**Files written:**
- Findings emitted to stdout (NDJSON; `librarian-finding` schema) and mirrored to `librarian-manifest.json` `drift_findings.governance_parity[]` via `manifest_set`. No vault file writes; no governance file writes.

**Schema each is gated by:**
- NDJSON output validates against `librarian-finding-schema.json`.
- Manifest subtree mirror validates against `librarian-manifest-schema.json` `drift_findings.governance_parity`.
- Source-input validation: each pillar JSON validates against `governance/enforcement-map.schema.json` before the audit runs; failure aborts the audit with a `pillar-schema-malformed` log entry.

**Pre-write validation steps:**
- Read all 5 governance JSONs (`_index.json`, `frontmatter-rules.json`, `tagging-rules.json`, `naming-rules.json`, `mandatory-files-rules.json`) + `enforcement-map.schema.json`.
- Read all 5 narrative spokes (`Vault Architecture - Frontmatter.md`, `- Tagging.md`, `- Naming.md`, `- Mandatory-Files.md`, `- Enforcement.md`).
- Validate every input against its source schema before walking the parity comparison.

**Failure mode:**
- `block and log` on schema-validation failure of source inputs (governance JSONs or finding output schema). The capability does not emit silent findings when its own inputs are malformed.
- Never `write and hope`.

## Finding categories

| Category | Severity | Trigger | Findings payload |
|---|---|---|---|
| `rule-id-mismatch` | warning | A rule ID appears in a pillar JSON but is not cross-referenced in the matching narrative spoke (or vice versa) | `{pillar, rule_id, present_in[], missing_from[], detected_at, first_seen}` |
| `field-missing` | warning | A rule entry in pillar JSON declares a field (e.g., `r47_exempt_paths`) that is not documented in the narrative spoke's corresponding section | `{pillar, rule_id, field, json_value, spoke_section, detected_at, first_seen}` |
| `tier-mismatch` | warning | A rule's `tier` declared in pillar JSON differs from the tier label used in the narrative spoke's discussion of that rule | `{pillar, rule_id, json_tier, spoke_tier_reference, detected_at, first_seen}` |
| `source-divergence` | info | A rule entry's `source:` field cites a research-packet path that does not exist or has been renamed | `{pillar, rule_id, json_source_pointer, resolution, detected_at, first_seen}` |
| `layer3-collision` | info | Adopter Layer-3 overlay declares the same rule ID, archetype enum, or extensible-entry kind as foundation canonical (per R-52 / ADR-0006) | `{kind, entity_id, foundation_path, overlay_path, override_reason, detected_at, first_seen}` |
| `foundation-upgrade-touches-shadowed-entry` | warning | A foundation upgrade has touched an entity the adopter overlay shadows; surfaces at `git fetch` cadence | `{kind, entity_id, foundation_diff_summary, overlay_path, detected_at, first_seen}` |
| `meta-rule-coverage-gap` | warning | A meta-rule (cross-cutting in `_index.json cross_cutting_meta_rules[]`) is not referenced in the meta-spoke (Vault Architecture - Enforcement.md) | `{rule_id, meta_spoke_section, detected_at, first_seen}` |
| `pillar-schema-malformed` | warning | A pillar JSON fails `enforcement-map.schema.json` validation at audit-time | `{pillar, schema_validation_error, detected_at, first_seen}` |

Severity `warning` findings count against the librarian's session-close summary; `info` findings surface but do not block close-out. The two `layer3-*` finding categories are the hand-off surface from ADR-0006 / R-52 (the Layer-3 overlay collision tiebreaker).

## Audit cadence

The capability is designed to run at three invocation modes:

| Mode | Trigger | Output |
|---|---|---|
| **Weekly cron** | Launchd plist runs the capability every 7 days; aligned with packet-staleness audit weekly cadence | Manifest-mirrored findings + stdout NDJSON |
| **On-demand** | `/librarian govern` invocation mode; operator runs at session-close, post-foundation-upgrade, or pre-release | Same outputs as weekly; operator chooses the moment |
| **Pre-commit (advisory)** | Optional git pre-commit hook (deferred; lightweight subset only) | Stdout advisory; never blocks the commit |

## Comparison method

For each pillar (frontmatter / tagging / naming / mandatory-files / meta):

1. **Rule-ID set comparison.** Read pillar JSON `rules[].id`; read narrative spoke body for all `R-NN` references. Emit `rule-id-mismatch` for any ID present in one but not the other.
2. **Field-coverage check.** For each rule in pillar JSON, check whether the narrative spoke covers the rule's structural fields (`rule_text` summary, `failure_mode` reference, `enforcement_layer` enumeration). Emit `field-missing` for gaps.
3. **Tier-label consistency.** Cross-check `tier:` declarations in pillar JSON against the tier framing in the narrative spoke. Emit `tier-mismatch` when the spoke describes a rule at a different tier than the JSON declares.
4. **Source-pointer resolution.** Resolve `rules[].source:` pointers to filesystem paths. Emit `source-divergence` for unresolvable paths.
5. **Layer-3 collision walk.** For each adopter overlay file (declared in `_index.json _path_rules` or sibling-discoverable), compute the union of overlay + foundation identifiers; emit `layer3-collision` for every overlap; consult git-diff context (when available) for `foundation-upgrade-touches-shadowed-entry` finding emission.
6. **Meta-rule coverage.** Read `_index.json cross_cutting_meta_rules[]`; verify each meta-rule is referenced in the meta-spoke. Emit `meta-rule-coverage-gap` for missed references.

The comparison is intentionally conservative: drift surfaces as findings the operator triages, not as auto-fixes. Auto-fix would conflict with the dual-surface design — narrative spokes carry voice + examples + anti-patterns that cannot be auto-generated from JSON, and JSON carries structured fields that should not be inferred from prose.

## Input sources

The capability reads from (in order):

1. **`governance/_index.json`** — pillar registry + `cross_cutting_meta_rules[]` + `_path_rules` for overlay discovery.
2. **`governance/{frontmatter,tagging,naming,mandatory-files}-rules.json`** — the four pillar registries.
3. **`governance/enforcement-map.schema.json`** — schema validation gate for each pillar JSON.
4. **`onboarding/scaffold/vault-architecture/Vault Architecture - {Frontmatter,Tagging,Naming,Mandatory-Files,Enforcement}.md`** — the five narrative spokes.
5. **Adopter overlay roots** — `archetype_extensions.json`, `tagging_cap_override.json`, `packet_staleness_thresholds.json`, and any other Layer-3 overlay files declared in `_index.json _path_rules`.
6. **Foundation diff context** (when `--upgrade` flag set) — `git diff foundation/<previous-tag>..foundation/<current-tag> -- governance/`.

## Companion: archetype-consistency capability

The `archetype-consistency` capability (specified at `governance/librarian-capabilities/archetype-consistency.md`) focuses on per-file archetype-field coverage; this `governance-parity-audit` capability focuses on cross-surface drift between governance JSONs and narrative spokes. The two are companion audits with distinct scopes — both run weekly via the cron template.

Layer-3 collision finding categories (`layer3-collision` + `foundation-upgrade-touches-shadowed-entry`) are emitted by governance-parity-audit, not archetype-consistency, per ADR-0006's design hand-off.

## R-37 lockstep coupled surfaces

This capability sits OUTSIDE the per-pillar R-37 lockstep — it is the audit-time backstop FOR the R-37 lockstep, not a peer of it. Changes to any of the four pillar JSONs, the five narrative spokes, or `_index.json` should trigger this capability's next run to detect drift introduced by the change.

The capability itself is coupled with:

- `governance/enforcement-map.schema.json` — schema-validation gate for source inputs.
- `librarian-finding-schema.json` — output schema for findings.
- `librarian-manifest-schema.json` — `drift_findings.governance_parity` subtree.
- ADR-0006 (Layer-3 overlay collision tiebreaker) — design hand-off for the two `layer3-*` finding categories.

## Implementation hand-off

The capability is specified at this contract; a downstream implementation sub-plan delivers the runtime at `~/.claude/skills/librarian/capabilities/governance-parity-audit.sh`. Implementation requirements:

- **Atomic writes** — manifest updates via `manifest_set`.
- **Survivorship** — preserve `first_seen` on matched rows across runs; new rows append; resolved rows drop.
- **Read-only** to all governance + spoke files.
- **bash 3.2 compatible** — per CONTRIBUTING.md §The bash 3.2 compatibility constraint.
- **Output Contract** — implementation MUST carry an Output Contract section per CONTRIBUTING.md §The Output Contract rule.
- **Idempotent** — running the audit twice without intervening edits produces the same finding set (same IDs, same payloads modulo `detected_at` timestamps).
- **Foundation-diff handling** — when `--upgrade` flag is set, the implementation must handle absent / shallow git history gracefully (return advisory only when diff context is available).

## References

- Design rationale: ADR-0005 (two-surface governance dual pattern)
- Collision design: ADR-0006 (Layer-3 overlay collision tiebreaker) → R-52 in `_index.json`
- Source narrative: `research/vault-construction/enforcement-map-design.md`
- Sibling capability: `governance/librarian-capabilities/archetype-consistency.md`
- Schema validation: `governance/enforcement-map.schema.json`
- Output schemas: `schemas/librarian-finding-schema.json`, `schemas/librarian-manifest-schema.json`
