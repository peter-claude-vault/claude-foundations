---
type: index
description: Entry-point index for the system-altitude research packet set. Navigates the nine canonical packets that codify vault construction principles, governance design, and operational disciplines.
provides:
  - vault-construction-research-index
  - packet-set-navigation
updated: 2026-05-12
tags: ["#scope/reference"]
---

# Vault construction — research packet set

This directory carries the system-altitude research packets that codify the foundation's design decisions. Each packet is a durable, citable artifact: the *why* behind a structural choice, paired with structured frontmatter (`altitude`, `validity_window`, `last_reviewed`, `source_dependencies`) that drives the 180-day staleness audit. Together the packets answer "where did this design come from" without forcing every adopter to re-derive the rationale.

The packets are surfaced at canonical URLs on the documentation site (`stem.peter.dev/research/vault-construction/<slug>/`). URLs are locked; restructures require a redirect plan per the URL-stability discipline. Adopters cite by URL; the URL survives the local-path's relocation.

## The nine system-altitude packets

| Slug | Scope (one-line) |
|---|---|
| [`vault-construction-principles`](./vault-construction-principles.md) | The five load-bearing commitments that hold the system together: capture-is-cheap, frontmatter-as-contract, folder-mirrors-tag invariant, multi-archetype union, propose-and-confirm. Read this first. |
| [`frontmatter-design`](./frontmatter-design.md) | Frontmatter as the API every file exposes. Three compliance tiers (Strict / Standard / Minimal); universal vs archetype-conditional vs packet-only field classes; folder-lineage convention; unified-with-per-archetype-entries extensibility model; R-37 atomic-lockstep protocol. |
| [`tagging-strategy`](./tagging-strategy.md) | Tags as the user-side query surface. 8-dimension faceted taxonomy; the five discipline rules (25-cap, prefix grammar, no-new-dimension-without-lockstep, no-freeform, tagging-failure-as-signal); system-utility dimension exemption; per-archetype dimension renaming. |
| [`file-naming-conventions`](./file-naming-conventions.md) | Naming as parseable contract. Three date-prefix patterns; shared slug grammar (folder-name + tag-value parity); vault-root allowlist (R-04); plan slug format (R-27); parent_plan inheritance (R-28); gitignore patterns at-depth (R-20). |
| [`content-length-limits`](./content-length-limits.md) | Per-file-class line-count budgets. The hub-and-spoke split rationale; max_lines frontmatter ceiling; system-utility file class thresholds for Logs/ surfaces. |
| [`claude-md-design`](./claude-md-design.md) | CLAUDE.md as the session-start context file. Three CLAUDE.md classes (vault-root / engagement-level / folder-scoped); the index-vs-instruction split; the loading-order override channel; per-class content standards. |
| [`_index.md-design`](./_index.md-design.md) | Per-folder `_index.md` discovery contract. The navigation companion to CLAUDE.md for non-engagement folders (Skills/, Reference/, Dashboard/). Naming convention, frontmatter, content standards. |
| [`enforcement-map-design`](./enforcement-map-design.md) | The dual-surface governance pattern (Claude-consumed governance JSONs + user-consumed narrative spokes). R-37 atomic-lockstep at write-time; librarian governance-parity-audit at audit-time; system-utility dimension exemption enforcement contract. |
| [`inbox-flow-architecture`](./inbox-flow-architecture.md) | Inbox/ as scraper-output aggregation surface (NOT drop-zone). Auto-routing-on-drop rejection + in-session `/ingest` propose-and-confirm replacement; seven canonical aggregation files; pull-based dashboard read-loop; daily rollover via inbox-archive. |

## Read order

Adopters reading the packet set for the first time:

1. **`vault-construction-principles`** — the five commitments are the substrate every other packet builds on.
2. **`frontmatter-design`** — the contract every file exposes.
3. **`tagging-strategy`** — the user-side query surface and its disciplines.
4. **`file-naming-conventions`** — names the system parses.
5. **`content-length-limits`** — per-file-class budgets.
6. **`claude-md-design`** + **`_index.md-design`** — navigation surface (session-start + per-folder discovery).
7. **`enforcement-map-design`** — the dual-surface governance pattern that holds the rest together.
8. **`inbox-flow-architecture`** — operational data flow architecture (read after the structural packets).

The set is internally cross-referenced; each packet's `source_dependencies:` lists its upstream peers.

## Companion artifacts

The packets are the *narrative* half of the dual-surface design pattern. The *machine-readable* half lives at:

- **`governance/_index.json`** — pillar registry + cross-cutting meta-rules (R-37, R-35, R-34, R-52).
- **`governance/frontmatter-rules.json`** — frontmatter pillar rule registry (R-32, R-33, R-37, R-39, R-40, R-41).
- **`governance/tagging-rules.json`** — tagging pillar rule registry (R-05, R-32-taxonomy, R-47, R-50, R-51).
- **`governance/naming-rules.json`** — naming pillar rule registry (R-04, R-10, R-20, R-27, R-28).
- **`governance/mandatory-files-rules.json`** — mandatory-files pillar rule registry (R-07, R-09, R-12, R-14).
- **`governance/log-subtype-registry.json`** — canonical `#log/*` and `#status/*` subtype enumeration.
- **`governance/librarian-capabilities/`** — audit-time capability contracts (archetype-consistency, packet-staleness-audit, governance-parity-audit, log-subtype-canonical).
- **`schemas/vault-schema.json`** — canonical frontmatter schema (21 active type entries; 3 tiers; folder-lineage `_path_rules`).
- **`docs/decisions/`** — Architecture Decision Records preserving the design provenance:
  - [ADR-0001](../../docs/decisions/0001-tiered-compliance.md) — tiered compliance
  - [ADR-0002](../../docs/decisions/0002-unified-with-per-archetype-entries.md) — unified-with-per-archetype-entries
  - [ADR-0003](../../docs/decisions/0003-folder-lineage-as-fields.md) — folder-lineage convention
  - [ADR-0004](../../docs/decisions/0004-system-utility-dimension-exemption.md) — system-utility dimension exemption
  - [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md) — dual-surface governance pattern
  - [ADR-0006](../../docs/decisions/0006-layer3-overlay-collision-tiebreaker.md) — Layer-3 overlay collision tiebreaker

R-37 atomic-lockstep holds the four artifact families aligned at write-time (schemas + governance JSONs + narrative packets + ADRs); the librarian `governance-parity-audit` capability catches drift at audit-time.

## Adopter customization

The packets describe the foundation-repo's canonical shape. Adopter installations extend via Layer 3 vault-overlay without forking the canonical artifacts:

- New archetype enum values → `archetype_extensions.json`
- New per-archetype conditional fields → same file
- New folder-lineage rules → `_path_rules` overlay entries
- New tag dimensions → require R-37 atomic lockstep (governance + spoke + hook + schema; not a pure overlay extension)
- Cap-overrides and exemptions → declared at adopter-side overlay files (`tagging_cap_override.json`, `r47_exempt_paths` overlay, etc.)

The Layer-3 overlay collision tiebreaker ([ADR-0006](../../docs/decisions/0006-layer3-overlay-collision-tiebreaker.md) → R-52 meta-rule) governs what happens when adopter overlay and foundation canonical declare the same identifier: adopter wins, foundation preserved-but-shadowed, audit-time surfaces the collision.

## Quality bar

Every packet meets the same 6-criteria self-test at first authoring + at every `last_reviewed` cycle:

1. **Citation required** — every recommendation backed by external literature, internal incident, or documented decision.
2. **Scope declaration** — frontmatter declares altitude, scope, validity window, source_dependencies, last_reviewed.
3. **Articulation test** — novice user can articulate the rule + the why after reading.
4. **Anti-pattern coverage** — every rule pairs with the failure mode it prevents.
5. **Decision-traceability** — open questions explicit; closed questions named with disposition.
6. **Source pointers** — every claim back-links to evidence.

The librarian `packet-staleness-audit` capability surfaces packets approaching the 180-day `last_reviewed` mark; the maintainer re-reviews and refreshes the validity window or marks the packet for retirement.

## URL stability

Every packet's `canonical_url` is locked from the date in its `url_stability:` field. Restructures (renames, relocations, splits) require a redirect plan landing in the same R-37 lockstep commit as the structural change. Adopters citing by URL get stable references over time; the underlying filesystem layout can evolve.
