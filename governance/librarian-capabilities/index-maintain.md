---
type: reference
description: Librarian index-maintain capability contract. Audit-time reconciler for `_index.md` contents-enum tables (Tier 2 sweep) + opt-in semantic-drift validator (Tier 3 --deep). First canonical self-healing capability under the R-34 boundary — mutations bounded to mechanically-derivable values; semantic content flagged for operator review and never auto-overwritten.
provides:
  - index-maintain-capability
  - r44-audit-contract
  - first-self-healing-capability
  - sp05-hand-off
updated: 2026-05-14
tags: ["#scope/reference"]
---

# Librarian capability — index-maintain

**Status:** specified (implementation deferred to SP05 per the SP03-authors-contract / SP05-implements pattern)
**Pillar consumer:** R-44 (mandatory-files) audit-time; Tier 1 sibling at `hooks/post-write-verify.sh`
**Source rules:** `governance/mandatory-files-rules.json` R-44 + `mandates._index_md`

## Purpose

Reconcile every non-exempt folder's `_index.md` against its filesystem reality. The capability is the audit-time companion to the Tier 1 post-write hook that catches writes the hook misses — cron scrapers writing via Bash redirects, direct Obsidian edits, manual file moves, deletes (which never go through the `Edit`/`Write` tool surface). The pair (`post-write-verify.sh` Tier 1 hook + this capability's Tier 2 sweep) closes the full write surface: 80% of writes go through the hook in real time; the remaining 20% surface within one audit cycle.

This is the **first canonical self-healing capability under the R-34 boundary**. The boundary doctrine: mutations bounded to mechanically-derivable values (Lines from `wc -l`, Type from frontmatter `type:`, missing/orphan rows from filesystem reality, `updated:` bump on any mutation); semantic content (descriptions, ordering decisions, exemption-list amendments) is flagged for operator review and never auto-overwritten. Earlier librarian capabilities (`archetype-consistency`, `governance-parity-audit`, `packet-staleness-audit`, `log-subtype-canonical`) are read-only auditors; this capability writes back to `_index.md` files under the bounded mechanical scope.

## Output Contract

**Files written:**
- Vault `_index.md` files — under the R-34 mechanical-drift mutation scope (Tier 2 + Tier 3 auto-correct of Lines, Type, missing/orphan rows, `updated:` bump). Hand-authored content (folder-context paragraph, cross-references, hand-tuned descriptions) preserved via survivorship pattern — automated maintenance touches only content between the sentinel markers (`<!-- contents-enum:start -->` / `<!-- contents-enum:end -->`) and the `updated:` frontmatter field; everything else stays untouched.
- Findings emitted to stdout (NDJSON; `librarian-finding` schema) and mirrored to `librarian-manifest.json` `drift_findings.index_maintain[]` via `manifest_set`.

**Schema each is gated by:**
- Body-structure contract at `governance/file-type-contracts/_index.md.json` validates every write to `_index.md` (sentinel-marker presence; column count + order; row pattern).
- Frontmatter contract at `governance/frontmatter-rules.json#types.index` validates every write to `_index.md` frontmatter (`type: index`; `tags:` non-empty; `parent_folder:` depth-conditional; `updated:` ISO-8601).
- NDJSON output validates against `librarian-finding-schema.json`.
- Manifest subtree mirror validates against `librarian-manifest-schema.json` `drift_findings.index_maintain` (open `additionalProperties: true` object).

**Pre-write validation steps:**
- Read `governance/mandatory-files-rules.json` `mandates._index_md` (matcher + exemption list).
- Read `governance/file-type-contracts/_index.md.json` (body-structure contract + sentinel markers + column shape).
- Read `governance/frontmatter-rules.json#types.index` + `governance/frontmatter-rules.json#archetype_conditional_fields` (frontmatter contract).
- Validate every input read against its source schema (`governance/enforcement-map.schema.json` for the mandatory-files pillar; JSON Schema draft-07 for the body-structure contract).
- Abort the audit run with a `pillar-schema-malformed` log entry if any input fails validation; never `write and hope`.

**Failure mode:**
- `block and log` on schema-validation failure of source rules / mandatory-files-rules.json / file-type-contracts/_index.md.json / frontmatter-rules.json.
- `block and log` on `_index.md` write that would fail post-write `pre-write-guard` validation (the capability never writes content the hook would have rejected at write-time).
- Never `write and hope`.

## Finding categories

| Category | Severity | Trigger | Findings payload |
|---|---|---|---|
| `bootstrap-auto-created` | info (event) | Tier 2 sweep found a non-exempt folder lacking `_index.md` and created one (because no prior write triggered the Tier 1 hook bootstrap) | `{folder_path, frontmatter_inferred, exemption_check_result, detected_at}` |
| `index-row-drift-mechanical` | info (event) | Auto-corrected a Lines value, Type value, missing row, or orphan row | `{index_path, drift_type, before, after, child_file, detected_at}` |
| `index-row-drift-semantic` | warning | Tier 3 --deep found description-vs-H1 mismatch or ordering incoherence on a hand-tuned row | `{index_path, drift_type, row_wikilink, suggested_correction, detected_at, first_seen}` |
| `index-stale-frontmatter` | warning | `_index.md` frontmatter fails `#types.index` contract (missing `parent_folder` at depth >= 2; missing `tags:`; invalid `updated:` format) | `{index_path, missing_or_invalid_fields[], detected_at, first_seen}` |
| `index-orphan-folder` | warning | `_index.md` carries `parent_folder:` that doesn't resolve to an existing vault path | `{index_path, declared_parent_folder, resolved_parent_folder_exists, detected_at, first_seen}` |
| `index-exemption-conflict` | warning | `_index.md` exists at a path on the exemption list (e.g., hand-created `Logs/_index.md`) | `{index_path, matched_exemption_glob, recommended_action, detected_at, first_seen}` |
| `mandate-violation` | warning | Non-exempt folder lacks `_index.md` AND the bootstrap auto-create failed (write error, permission, etc.) | `{folder_path, bootstrap_error, detected_at, first_seen}` |

Severity `warning` findings count against the librarian's session-close summary; `info` event findings are surfaced for operator visibility but do not block close-out. The `bootstrap-auto-created` event finding lets the operator review what the hook auto-created; the operator can then fill the placeholder folder-context paragraph and tune the seeded tags.

## Audit cadence

| Mode | Trigger | Output |
|---|---|---|
| **Tier 2 — daily cron** | Launchd plist runs the capability every 24h; aligned with `archetype-consistency` + `governance-parity-audit` cadence | Manifest-mirrored findings + stdout NDJSON; mechanical auto-corrections written back |
| **Tier 2 — /librarian full** | Operator runs `/librarian full` at session-close or on-demand | Same outputs as cron |
| **Tier 3 — /librarian index-maintain --deep** | Operator opt-in for semantic drift validation | Same as Tier 2 + `index-row-drift-semantic` findings; no auto-overwrite of hand-tuned content |

Tier 1 (live sync via `post-write-verify.sh`) is the always-on substrate. Tier 2 is the always-on audit. Tier 3 is opt-in.

## Behavior — Tier 2 per folder

1. Read `mandates._index_md.exemption_paths` from `governance/mandatory-files-rules.json`. Skip folders matching any exempt glob.
2. Enumerate child `.md` files (exclude `_index.md` itself; exclude gitignored paths via `git check-ignore`).
3. Locate sibling `_index.md`:
   - **Missing** → auto-bootstrap (emit `bootstrap-auto-created` event): create with frontmatter stub (`type: index`; `parent_folder:` derived from path if depth >= 2; `tags:` inferred from structural-dimension lineage e.g., `Engagements/<X>/<...>/` → `#engagement/<X>`; `updated:` today); write H1 from folder name; emit placeholder folder-context paragraph; emit empty contents-enum table wrapped in sentinel markers.
   - **Exists** → parse contents-enum table by sentinel markers.
4. Reconcile rows:
   - **File with no row** → append row with (filename wikilink, line count via `wc -l`, type from frontmatter, description from `description:` frontmatter OR H1 OR first paragraph fallback). Emit `index-row-drift-mechanical`.
   - **Row with no file** → remove row (orphan from delete/rename). Emit `index-row-drift-mechanical`.
   - **Line-count drift** → update Lines cell. Emit `index-row-drift-mechanical`.
   - **Type drift** → update Type cell. Emit `index-row-drift-mechanical`.
5. Validate frontmatter against `#types.index` contract; emit `index-stale-frontmatter` for non-compliant entries.
6. Validate `parent_folder:` resolves to existing path (if declared); emit `index-orphan-folder` for unresolved entries.
7. Bump `_index.md` frontmatter `updated:` to today if any change in steps 4-6.

## Behavior — Tier 3 --deep additional checks

Same as Tier 2 plus:

- Compare row's Description against referenced file's H1 OR `description:` frontmatter; emit `index-row-drift-semantic` on mismatch (NO auto-overwrite — descriptions can be hand-tuned for context).
- Check ordering coherence: key-role types (`overview`, `context`, `updates`, `prd`, `navigation`) listed before supporting types (`reference`, `people`); emit `index-row-drift-semantic` on incoherence (NO auto-reorder — operator may have intentional ordering).

## Input sources

The capability reads from (in order):

1. **`governance/mandatory-files-rules.json`** — `mandates._index_md` (matcher + exemption list).
2. **`governance/file-type-contracts/_index.md.json`** — body-structure contract (sentinel markers, columns, ordering, fallback rules).
3. **`governance/frontmatter-rules.json`** — `#types.index` (frontmatter contract) + `#archetype_conditional_fields` (depth-conditional parent_folder semantics; dissolved from schemas/vault-schema.json in SP13 T-4).
4. **`governance/enforcement-map.schema.json`** — schema validation gate for the mandatory-files pillar JSON.
5. **Adopter Layer-3 overlays** — `$CLAUDE_HOME/governance/file-type-contracts/_index.md.adopter.json` (if present); shadows foundation per R-52 with `_override_reason`.
6. **Vault walk** — every folder under the configured vault root, filtered by `mandates._index_md.exemption_paths`.

## Exemptions

Folders matching `mandates._index_md.exemption_paths` glob (positive list): `Templates/**`, `Archive/**`, `Daily/**`, `Meetings/**`, `Inbox/**` (handled by `inbox-index-refresh` capability), `Logs/**`, `Tags/**`, `_orchestrator/**`, `tests/**`, `tests/fixtures/**`. Exemption-list amendments require R-37 atomic lockstep updating the registry + post-write hook + this capability + Mandatory-Files spoke.

## Self-healing boundary declaration (R-34)

This capability is the first canonical self-healing capability in the librarian set. The R-34 boundary doctrine:

- **In bounds (auto-corrected):** Lines value (from `wc -l`), Type value (from frontmatter `type:`), missing rows (filesystem reality), orphan rows (file no longer exists), `updated:` bump on any mutation, auto-bootstrap of missing non-exempt `_index.md` files.
- **Out of bounds (flagged, never overwritten):** Descriptions (hand-tunable), ordering decisions (intentional sorting), exemption-list membership decisions (operator triage), folder-context paragraph content.

The boundary is enforced by code structure — the auto-correct branch writes only Lines / Type / row-add / row-remove / `updated:`; the semantic-drift branch emits NDJSON findings and never writes vault content. The two branches are not interchangeable.

## Cooperation with adjacent capabilities

| Capability | Cooperation pattern |
|---|---|
| `placement-validate.sh` | Whitelists `_index.md` against the file-naming convention (leading underscore + lowercase); passes through valid placement; flags `_index.md` at out-of-scope locations. This capability assumes `_index.md` is whitelisted at every non-exempt depth. |
| `rename-cascade.sh` | Handles rename-driven row updates in contents-enum tables; cooperates with Tier 1 hook on Edit/Write but catches Bash-driven moves the hook misses. This capability reconciles after the rename lands. |
| `xref-check.sh` | Validates wikilink integrity (relevant when an `_index.md` references files renamed/moved). This capability defers wikilink-repair to `wikilink-repair.sh`. |
| `wikilink-repair.sh` | Auto-fixes broken wikilinks in `_index.md` tables; runs before this capability in the librarian sequence so wikilinks are valid when row reconciliation runs. |
| `inbox-index-refresh.sh` | Owns `Inbox/_index.md` exclusively (active-connection enumeration + destination-overlap shape, NOT the standard four-column shape). This capability skips `Inbox/**` per the exemption list. |
| `frontmatter-enforce.sh` | Validates frontmatter schema conformance at audit time across the vault. This capability emits `index-stale-frontmatter` findings for `_index.md`-specific frontmatter drift; the broader audit covers other types. |

## Layer-3 collision handling

Per ADR-0006 / R-52 (Layer-3 Overlay Collision Tiebreaker): when an adopter Layer-3 overlay at `$CLAUDE_HOME/governance/file-type-contracts/_index.md.adopter.json` shadows the foundation body-structure contract, the adopter's declaration wins. Collision detection itself is **write-time-enforced in `pre-write-guard.sh`** (per R-52); this capability does not perform collision detection at audit-time. The capability's responsibility is contract-compliance validation given the resolved (adopter-shadowed) contract. Required behavior:

- Read adopter overlay first; foundation second.
- For shadowed body-structure fields: use the adopter's declaration directly.
- Foundation upgrades touching shadowed entries surface via `governance-parity-audit` `foundation-upgrade-touches-shadowed-entry` finding category, not via this capability.

## R-37 lockstep coupled surfaces

This contract is an R-37 lockstep peer with:

- `governance/mandatory-files-rules.json` R-44 + `mandates._index_md` (matcher + exemption list)
- `governance/file-type-contracts/_index.md.json` (body-structure contract)
- `governance/frontmatter-rules.json#types.index` + `governance/frontmatter-rules.json#archetype_conditional_fields` (frontmatter contract)
- `onboarding/scaffold/vault-architecture/Vault Architecture - Mandatory-Files.md` (narrative spoke)
- `hooks/post-write-verify.sh` (Tier 1 sibling — auto-bootstrap + live-sync + loop guard)
- `target-state/_index.md-design/` (design source — conventions-and-rationale.md + structural-requirements.md + structural-requirements.json + governance.md)

Changes to any of the above require R-37 atomic lockstep including this contract spec. New exemption-list entries, body-structure-contract changes, and frontmatter-contract changes all touch this capability's behavior.

## Implementation hand-off

The capability is specified at this contract; SP05 delivers the runtime at `skills/librarian/capabilities/index-maintain.sh` per the SP03-authors-contract / SP05-implements pattern (matches `governance-parity-audit` + `archetype-consistency` precedent). Implementation requirements:

- **Atomic writes** — `_index.md` updates via atomic temp+rename; manifest updates via `manifest_set`; no partial-state visibility.
- **Survivorship** — preserve content outside sentinel markers across runs; preserve hand-tuned descriptions and ordering across Tier 2 mechanical sweeps; preserve `first_seen` on matched finding rows.
- **Bounded mutation scope** — only auto-correct Lines / Type / row-add / row-remove / `updated:` / auto-bootstrap; flag everything else.
- **bash 3.2 compatible** — per CONTRIBUTING.md §The bash 3.2 compatibility constraint (no associative arrays, no `${var,,}` lowercasing, no `readarray`, etc.).
- **Output Contract** — implementation MUST carry an Output Contract section in its SKILL.md or in-script header per CONTRIBUTING.md §The Output Contract rule.
- **Loop guard pattern** — the capability's own writes go through `post-write-verify.sh`, which carries the self-exempt loop guard for `_index.md`. Verify the guard fires in test fixtures before shipping.
- **Idempotent** — running the capability twice without intervening filesystem changes produces the same finding set (same IDs, same payloads modulo `detected_at` timestamps).

## References

- R-44 rule entry: `governance/mandatory-files-rules.json` `rules[0]` + `mandates._index_md`
- Body-structure contract: `governance/file-type-contracts/_index.md.json`
- Frontmatter contract: `governance/frontmatter-rules.json#types.index`
- Narrative spoke: `onboarding/scaffold/vault-architecture/Vault Architecture - Mandatory-Files.md`
- Tier 1 sibling: `hooks/post-write-verify.sh` (auto-bootstrap + live-sync + loop guard)
- Sibling capabilities: `governance/librarian-capabilities/archetype-consistency.md`, `governance-parity-audit.md`, `packet-staleness-audit.md`, `log-subtype-canonical.md`
- Design source: `target-state/_index.md-design/` (conventions-and-rationale.md + structural-requirements.md + structural-requirements.json + governance.md)
- Research narrative: `research/vault-construction/_index.md-design.md`, `mandatory-file-lock.md`
- ADR-0006 (Layer-3 overlay collision tiebreaker): `docs/decisions/0006-layer3-overlay-collision-tiebreaker.md`
- Librarian-finding schema: `schemas/librarian-finding-schema.json` (foundation-repo canonical)
- Librarian-manifest schema: `schemas/librarian-manifest-schema.json` (`drift_findings.index_maintain` subtree)
