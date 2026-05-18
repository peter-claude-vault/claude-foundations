---
type: reference
description: Librarian writers-overlap-refresh capability contract. Cross-references all writer-reference files; detects ≥2 writers targeting the same `destinations[].path` (via glob derivation of Mustache templates); regenerates `_overlap-matrix.md` with `writers_allowed: ["librarian"]` parallel to `_index.md` pattern.
provides:
  - writers-overlap-refresh-capability
  - destination-collision-detection
updated: 2026-05-18
tags: ["#scope/reference"]
---

# Librarian capability — writers-overlap-refresh

**Status:** specified (implementation deferred to a downstream sub-plan; contract authored in Plan 81 SP14 T-12.4)
**Pillar consumer:** Vault Writers governance (pillar 7 — `governance/vault-writers-rules.json` + file-type-contract `governance/file-type-contracts/vault-writer.md.json`)
**Source rules:** `governance/file-type-contracts/vault-writer.md.json` (destinations entry shape) + `governance/vault-writers-rules.json :: foundation_variable_namespace`
**Source spec:** Plan 81 SP13 alignment Session 5 L-68 (`librarian writers-overlap-refresh` capability) + L-69 (DUAL pattern language — Mustache for write-time + glob for audit-time)

## Purpose

Cross-reference all writer-reference files in `$VAULT_ROOT/Vault Writers/`, derive a glob form of each `destinations[].path` (each `{{<var>}}` → `*` per Session 5 L-69), cluster destinations by glob equivalence, and detect cases where ≥2 writers share a destination glob. Regenerate `$VAULT_ROOT/Vault Writers/_overlap-matrix.md` — a structured table surfacing every multi-writer destination cluster — so the operator can review reconciliation rules at those destinations (per `governance/vault-writers-rules.json :: processing_defaults` + folder-level `_processing-rules.json` overrides per pillar layering).

The capability is the canonical writer for `Vault Writers/_overlap-matrix.md`. The file declares `writers_allowed: ["librarian"]` in its frontmatter per Session 5 L-68 (parallel to `_index.md` pattern). Hook branch #4 enforcement blocks non-librarian writes to this path.

## Output Contract

**Files written:**
- `$VAULT_ROOT/Vault Writers/_overlap-matrix.md` — regenerated overlap-matrix file (`type: overlap-matrix`; `generated_by: librarian writers-overlap-refresh`; `writers_allowed: ["librarian"]`; `updated: <ISO>`; standard tags). Sentinel-bounded body table is regenerated; operator narrative outside the sentinels is preserved verbatim.
- Findings emitted to stdout (NDJSON; `librarian-finding` schema) and mirrored to `librarian-manifest.json` `drift_findings.writers_overlap_refresh[]` via `manifest_set`. No further vault file writes.

**Schema each is gated by:**
- Every writer-reference markdown read validates frontmatter against `governance/file-type-contracts/vault-writer.md.json` (`destinations[]` entry shape includes `path` + `output_type` + optional `posture` / `processing_rules_ref`).
- `_overlap-matrix.md` written frontmatter validates against `governance/frontmatter-rules.json#types.overlap-matrix` (or fallback `#types.index`-like shape until a dedicated type registers; per SP13 Session 5 the file ships with `type: overlap-matrix` and the frontmatter contract evolves via `/govern register --kind file-type`).
- NDJSON output validates against `librarian-finding-schema.json`.
- Manifest subtree mirror validates against `librarian-manifest-schema.json` `drift_findings.writers_overlap_refresh` (open `additionalProperties: true` object).

**Pre-write validation steps:**
- Read `governance/file-type-contracts/vault-writer.md.json` (writer-reference contract — destinations entry shape).
- Read `governance/vault-writers-rules.json` `foundation_variable_namespace` array (`["date", "title", "slug", "source_id"]` per Session 5 L-69) for the canonical Mustache variable set — adopter-defined variables (e.g., `{{engagement}}`, `{{project}}`) emerge from overlay-master `path_routing` patterns and are treated as opaque tokens during glob derivation.
- Read `$VAULT_ROOT/Vault Writers/*.md` writer-reference files (exclude `_index.md` + `_overlap-matrix.md`).
- For each writer-reference: enumerate `destinations[]` array; for each entry, derive glob form by substituting `{{<any-var>}}` → `*`.
- Cluster destinations by glob equivalence. Singletons (1 writer per glob) are NOT rendered in the matrix; only clusters of ≥2 writers surface.

**Failure mode:**
- `block and log` on schema-validation failure of source contracts (writer-reference contract; vault-writers-rules.json). Partial regeneration is not performed when inputs are malformed.
- `block and log` on `_overlap-matrix.md` write that would fail post-write frontmatter validation.
- `block and log` if the sentinel-marker pair (`<!-- overlap-matrix:start -->` / `<!-- overlap-matrix:end -->`) cannot be located in the existing `_overlap-matrix.md` AND a fresh file cannot be initialized.
- Never `write and hope`. Atomic temp+rename for the regeneration; operator narrative outside sentinels preserved across the swap.

## Finding categories

| Category | Severity | Trigger | Findings payload |
|---|---|---|---|
| `multi-writer-overlap-detected` | info (event) | A destination glob is shared by ≥2 writers; emitted once per detected cluster per run | `{destination_glob, writer_count, writer_names[], processing_rules_resolution_pointer, detected_at}` |
| `destination-collision-unresolved` | warning | A multi-writer cluster targets a destination where folder-level `_processing-rules.json` is absent AND universal pillar 7 `processing_defaults` would be applied (no folder-level override declared); surfaces as drift candidate for operator triage — the cluster may need an explicit reconciliation rule | `{destination_glob, writer_names[], applicable_pillar_defaults, detected_at, first_seen}` |
| `overlap-matrix-regenerated` | info (event) | `_overlap-matrix.md` was regenerated; emitted once per audit run | `{clusters_rendered_count, total_writers_scanned, sentinel_recreated_bool, detected_at}` |

Severity `warning` findings count against the librarian's session-close summary; `info` event findings are surfaced for operator visibility but do not block close-out.

## Audit cadence

| Mode | Trigger | Output |
|---|---|---|
| **Tier 2 — daily cron** | Launchd plist runs the capability every 24h; aligned with `writers-index-refresh` + `writers-health-audit` | Manifest-mirrored findings + stdout NDJSON; `_overlap-matrix.md` regenerated |
| **Tier 2 — /librarian full** | Operator runs `/librarian full` at session-close or on-demand | Same outputs as cron |
| **On-demand** | `/librarian writers-overlap-refresh` invocation | Same outputs |

## Behavior — full regeneration

1. **Read contracts.** Load `governance/file-type-contracts/vault-writer.md.json` (destinations entry shape) + `governance/vault-writers-rules.json` (`foundation_variable_namespace`).
2. **Enumerate writer-references.** Walk `$VAULT_ROOT/Vault Writers/*.md`; exclude `_index.md`, `_overlap-matrix.md`, and any leading-underscore files.
3. **Per-writer destination enumeration.** For each writer-reference: parse `destinations[]` array; for each entry, extract `path` (Mustache form).
4. **Glob derivation.** For each Mustache `path`, substitute `{{<any-identifier>}}` → `*` (single substitution per variable occurrence; preserves `/` path separators). The result is the destination's glob equivalent for overlap-matching purposes — no second field stored on the writer-reference per L-69.
5. **Cluster by glob.** Build a `destination_glob → [writer_name]` map. Clusters with `len(writers) >= 2` are matrix candidates.
6. **Compose matrix rows.** Per cluster:
   - `Destination glob` — derived glob form
   - `Writers` — comma-separated list of `writer_name` values
   - `Output type(s)` — unique set of `output_type` values across cluster members
   - `Posture(s)` — unique set of `posture` values (`direct` / `staged`); `mixed` if both
   - `Processing rules resolution` — derived from `processing_rules_ref` on cluster members + folder-level `_processing-rules.json` resolution (walk-up lookup); `pillar-default` when no folder-level contract resolved
7. **Preserve operator narrative.** Read existing `_overlap-matrix.md`; capture content outside the `<!-- overlap-matrix:start -->` / `<!-- overlap-matrix:end -->` sentinel pair.
8. **Render new file.** Compose:
   - Frontmatter (`type: overlap-matrix`, `parent_folder: "Vault Writers"`, `generated_by: librarian writers-overlap-refresh`, `writers_allowed: ["librarian"]`, `tags`, `updated: <today>`)
   - H1 (`# Vault Writers — Overlap Matrix`)
   - Preserved folder-context paragraph (or default scaffolding if absent)
   - `## Clusters` H2
   - Sentinel-start marker
   - Markdown table with column headers + separator + rows (sorted by `Destination glob` ascending)
   - Sentinel-end marker (or "No multi-writer overlaps detected." sentinel-inner message when cluster set is empty)
9. **Atomic write.** Write tempfile; validate parseability + frontmatter; atomic rename.
10. **Emit per-cluster `multi-writer-overlap-detected` events** + cluster-level `destination-collision-unresolved` warnings where applicable + run-level `overlap-matrix-regenerated` event.

## Input sources

The capability reads from (in order):

1. **`governance/file-type-contracts/vault-writer.md.json`** — writer-reference contract; destinations entry shape.
2. **`governance/vault-writers-rules.json`** — `foundation_variable_namespace` (canonical Mustache variables) + `processing_defaults` (universal floor for processing rules).
3. **`$VAULT_ROOT/Vault Writers/*.md`** — writer-reference files (current state).
4. **Folder-level `_processing-rules.json` files** — discovered via walk-up from each destination glob to detect override declarations (input to the `processing_rules_resolution` column).
5. **`$VAULT_ROOT/Vault Writers/_overlap-matrix.md`** — current file (for operator narrative preservation).

## Self-healing boundary declaration (R-34)

This capability operates under the R-34 mechanical-mutation boundary:

- **In bounds (auto-corrected):** Table region inside sentinel markers — rows added / removed / re-sorted; cells populated from writer-reference frontmatter via mechanical glob derivation; frontmatter `updated:` bumped.
- **Out of bounds (flagged, never overwritten):** Folder-context paragraph + adjacent operator narrative outside sentinels; writer-reference frontmatter (capability is read-only against writer-references); folder-level `_processing-rules.json` content (capability reads only); `_index.md` (separate capability writes that file).

The boundary is enforced by code structure — regeneration touches only content inside sentinel markers + the librarian-managed frontmatter fields (`generated_by`, `updated`).

## Cooperation with adjacent capabilities

| Capability | Cooperation pattern |
|---|---|
| `writers-index-refresh` (T-12.3) | Owns `$VAULT_ROOT/Vault Writers/_index.md` exclusively. `_index.md` pointer-links to `_overlap-matrix.md` via `## See also` (NOT embed) per L-68. The two capabilities share writer-reference reads but write disjoint files. |
| `writers-health-audit` (T-12.5) | Emits `multi-writer-overlap` finding class that cross-references `_overlap-matrix.md` (per L-62). Operator can pivot from a health-audit finding to the matrix file for full destination cluster context. |
| `index-maintain` | Skips `Vault Writers/_overlap-matrix.md` (parallel exemption to `_index.md` — librarian-owned indices live outside `index-maintain`'s reconciliation scope). |
| Hook branch #4 | Enforces `writers_allowed: ["librarian"]` write posture on `Vault Writers/_overlap-matrix.md` — `writers-overlap-refresh` writes through the librarian's authenticated path. |

## R-37 lockstep coupled surfaces

This contract is an R-37 lockstep peer with:

- `governance/file-type-contracts/vault-writer.md.json` (writer-reference contract — destinations entry shape source)
- `governance/vault-writers-rules.json` (`foundation_variable_namespace` + `processing_defaults`)
- `governance/_index.json` pillar 7 registry (vault-writers)

Changes to any of the above require R-37 atomic lockstep including this contract spec.

## Implementation hand-off

The capability is specified at this contract; a downstream implementation sub-plan delivers the runtime at `~/.claude/skills/librarian/capabilities/writers-overlap-refresh.sh`. Implementation requirements:

- **Atomic writes** — `_overlap-matrix.md` regeneration via atomic temp+rename.
- **Survivorship** — preserve operator narrative outside sentinel markers across runs.
- **Read-only** to writer-reference files + `_processing-rules.json` files.
- **bash 3.2 compatible** — per CONTRIBUTING.md §The bash 3.2 compatibility constraint.
- **Output Contract** — implementation MUST carry an Output Contract section per CONTRIBUTING.md §The Output Contract rule.
- **Idempotent** — running the capability twice without intervening writer-reference edits produces identical `_overlap-matrix.md` content.
- **Glob derivation determinism** — same Mustache input MUST yield same glob output (no random tie-breaking; deterministic ordering by `Destination glob` ASC).

## References

- File-type-contract: `governance/file-type-contracts/vault-writer.md.json`
- Vault-writers pillar: `governance/vault-writers-rules.json`
- Source decisions: Plan 81 SP13 alignment Session 5 L-68 (capability) + L-69 (DUAL pattern language)
- Sibling capabilities: `writers-index-refresh.md`, `writers-health-audit.md`, `index-maintain.md`
- Librarian-finding schema: `schemas/librarian-finding-schema.json`
- Librarian-manifest schema: `schemas/librarian-manifest-schema.json` (`drift_findings.writers_overlap_refresh` subtree)
