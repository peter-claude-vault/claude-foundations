---
type: reference
description: Librarian backlog-index capability contract. Regenerates the 6-column flat backlog table at `~/.claude-plans/_backlog.md` from `manifest.json` scans across `~/.claude-plans/*/` — sweeps plans in `researching` / `planned` lifecycle states. Idempotent regeneration; preserves operator-edit triage notes via per-row sentinel pattern.
provides:
  - backlog-index-capability
  - plans-tree-backlog-regeneration
updated: 2026-05-18
tags: ["#scope/reference"]
---

# Librarian capability — backlog-index

**Status:** specified (implementation deferred to a downstream sub-plan; contract authored in Plan 81 SP14 T-12.2)
**Pillar consumer:** Plans-tree governance (pillar 8 — `governance/plans-rules.json`)
**Source rules:** `governance/plans-rules.json :: root_files._backlog.md` + `backlog_row` + `slug_rules`
**Source spec:** Plan 81 SP13 alignment Session 2 (Locked decisions Q1.1 / Q1.2 / Q1.3 / Q1.4 + Fork 1; 6-col flat table per A22)

## Purpose

Regenerate the canonical 6-column flat table at `~/.claude-plans/_backlog.md` from `manifest.json` scans across `~/.claude-plans/*/`. The capability sweeps for plans in `researching` / `planned` lifecycle states (per `plans-rules.json :: backlog_row.status_enum`) and emits a unified backlog row per plan. The regeneration is **idempotent** — running the capability twice without intervening manifest edits produces identical `_backlog.md` content. Operator-edit triage notes are preserved across runs via the per-row sentinel pattern (per `feedback_sentinel_pattern_in_practice`): each row carries a stable pointer; full session history lives at the satellite `~/.claude-plans/Logs/backlog-progress/<slug>.md`.

## Output Contract

**Files written:**
- `~/.claude-plans/_backlog.md` — full regeneration of the 6-column flat table. The capability owns this file exclusively (`writers_allowed: ["librarian"]` per `plans-rules.json :: root_files._backlog.md`). Sentinel-bounded table region is regenerated; operator-authored narrative outside the sentinels is preserved verbatim.
- Findings emitted to stdout (NDJSON; `librarian-finding` schema) and mirrored to `librarian-manifest.json` `drift_findings.backlog_index[]` via `manifest_set`. No vault file writes.

**Schema each is gated by:**
- Every `manifest.json` read validates against `schemas/plan-manifest-schema.json` BEFORE row composition.
- `_backlog.md` rendered row shape conforms to the 6-column contract declared in `plans-rules.json :: backlog_row.required_fields` (`project_directory`, `initiative`, `status`, `disposition`, `updated`) + Notes column.
- NDJSON output validates against `librarian-finding-schema.json`.
- Manifest subtree mirror validates against `librarian-manifest-schema.json` `drift_findings.backlog_index` (open `additionalProperties: true` object).

**Pre-write validation steps:**
- Read `governance/plans-rules.json` `root_files._backlog.md` + `backlog_row` (status_enum, disposition_enum, required_fields) + `slug_rules.pattern` (anchored `^[0-9]{2}-[a-z][a-z0-9-]+$`).
- Read every `~/.claude-plans/*/manifest.json`; validate each against `schemas/plan-manifest-schema.json`.
- For each candidate plan: assert `status ∈ {researching, planned}` (the in-backlog statuses per `plans-rules.json :: backlog_row.status_enum`). Plans at other statuses are not eligible for `_backlog.md` representation.
- Assert plan slug conforms to `slug_rules.pattern`; emit `slug-violation` finding for non-conforming slugs.
- Assert each candidate has a `disposition` value within `plans-rules.json :: backlog_row.disposition_enum` (`FIX NOW / ABSORB / STANDALONE / DEFERRED`); emit `backlog-row-missing-disposition` finding if absent or invalid (per A26 + `feedback_backlog_disposition_required`).

**Failure mode:**
- `block and log` on schema-validation failure of source rules (`plans-rules.json`) or any manifest under audit. Non-conforming plans surface as findings; the regeneration STILL emits a `_backlog.md` containing the valid subset — the file is never absent.
- `block and log` on `_backlog.md` write that would produce a non-parseable table; rendered output is validated before atomic-rename.
- `block and log` if the sentinel-marker pair (`<!-- backlog:start -->` / `<!-- backlog:end -->`) cannot be located in the existing `_backlog.md` AND a fresh file cannot be initialized; tempfile deleted, finding emitted.
- Never `write and hope`. Atomic temp+rename for the regeneration; operator narrative outside sentinels preserved across the swap.

## Finding categories

| Category | Severity | Trigger | Findings payload |
|---|---|---|---|
| `backlog-row-missing-disposition` | warning | A candidate plan has `status ∈ {researching, planned}` but `disposition` is absent OR not in the canonical enum per `feedback_backlog_disposition_required` + A26. **Stale advisory:** `plans-rules.json :: backlog_row.stale_advisory_days` (14d advisory / 21d escalation) is read by the consumer of this finding (`backlog-hygiene` skill / scheduled cron) — this capability emits the finding once per audit run; the consumer escalates severity by age. | `{plan_slug, current_disposition, stale_for_days, detected_at, first_seen}` |
| `manifest-status-orphan` | warning | A manifest declares a status outside `plans-rules.json :: lifecycle.status_enum` (e.g., legacy / typo); plan excluded from `_backlog.md` until the status is corrected | `{plan_slug, declared_status, valid_statuses[], detected_at, first_seen}` |
| `slug-violation` | warning | Plan directory slug does not conform to `plans-rules.json :: slug_rules.pattern` (`^[0-9]{2}-[a-z][a-z0-9-]+$`) — e.g., missing numeric prefix, shame-slug pattern; plan is still rendered in `_backlog.md` but flagged for hygiene | `{plan_slug, pattern_violation_reason, detected_at, first_seen}` |
| `backlog-regenerated` | info (event) | `_backlog.md` was regenerated; emitted once per audit run | `{plans_rendered_count, plans_skipped_count, sentinel_recreated_bool, detected_at}` |

Severity `warning` findings count against the librarian's session-close summary; `info` event findings are surfaced for operator visibility but do not block close-out.

## Audit cadence

| Mode | Trigger | Output |
|---|---|---|
| **Tier 2 — daily cron** | Launchd plist runs the capability every 24h; aligned with `governance-parity-audit` cadence | Manifest-mirrored findings + stdout NDJSON; `_backlog.md` regenerated |
| **Tier 2 — /librarian full** | Operator runs `/librarian full` at session-close or on-demand | Same outputs as cron |
| **On-demand** | `/librarian backlog-index` invocation | Same outputs |

## Behavior — full regeneration

1. **Read pillar.** Load `governance/plans-rules.json` (`root_files._backlog.md`, `backlog_row`, `slug_rules`, `lifecycle.status_enum`).
2. **Enumerate plans.** Walk `~/.claude-plans/*/` (single-level; exclude hidden dirs + `_research` per Session 2 Q7 lock).
3. **Per-plan filter.** For each candidate:
   - Read `manifest.json`; validate against `schemas/plan-manifest-schema.json`.
   - Skip if `status` not in `{researching, planned}`.
   - Validate slug against `slug_rules.pattern`; emit `slug-violation` if non-conforming but still render the row.
4. **Compose row** (6 columns per A22 / SP13 Session 2 Q1.2):
   - `Project Dir` — literal short path from `manifest.project_directory` (REQUIRED ALWAYS per SP13 Session 2 Q3)
   - `Initiative` — wikilink to plan slug (`[[<slug>]]`) + brief title from `manifest.title`
   - `Status` — current `manifest.status` (`researching` or `planned`)
   - `Disposition` — `manifest.disposition` value (one of `FIX NOW / ABSORB / STANDALONE / DEFERRED`); `MISSING` if absent (emit `backlog-row-missing-disposition` finding)
   - `Updated` — `manifest.updated` ISO date
   - `Notes` — preserved per-row sentinel content from prior `_backlog.md` (per `feedback_sentinel_pattern_in_practice`) — operator-tunable triage line; new rows seed with empty cell
5. **Preserve operator narrative.** Read existing `_backlog.md`; capture any content outside the `<!-- backlog:start -->` / `<!-- backlog:end -->` sentinel pair (preface paragraph, footer notes, cross-references).
6. **Preserve per-row sentinel notes.** Read existing rows; build a `plan_slug → notes_cell` map from the in-table content; carry forward into the regenerated rows.
7. **Render new table.** Sort rows by `Project Dir` ascending then `Updated` descending. Emit table-header + separator + rows under the sentinel-bounded block.
8. **Atomic write.** Compose full file: preserved preface + sentinel-start + header + separator + rows + sentinel-end + preserved footer. Write tempfile; validate parseability; atomic rename.
9. **Emit `backlog-regenerated` event finding** with counts.

## Input sources

The capability reads from (in order):

1. **`governance/plans-rules.json`** — `root_files._backlog.md` + `backlog_row` + `slug_rules` + `lifecycle.status_enum`.
2. **`schemas/plan-manifest-schema.json`** — schema gate for every manifest read.
3. **`~/.claude-plans/*/manifest.json`** — candidate plan manifests.
4. **`~/.claude-plans/_backlog.md`** — current file (for operator narrative + per-row notes preservation).

## Self-healing boundary declaration (R-34)

This capability operates under the R-34 mechanical-mutation boundary:

- **In bounds (auto-corrected):** Table region inside sentinel markers — rows added / removed / re-sorted; cells populated from manifest fields; `MISSING` placeholder for absent `disposition`.
- **Out of bounds (flagged, never overwritten):** Operator narrative outside sentinel markers; per-row `Notes` cell content (preserved across regeneration via per-row sentinel matching by `plan_slug`); manifest content (capability is read-only against manifest); disposition values (operator-authored; never inferred).

The boundary is enforced by code structure — regeneration touches only content between the `<!-- backlog:start -->` / `<!-- backlog:end -->` markers; everything else passes through unchanged.

## Cooperation with adjacent capabilities

| Capability | Cooperation pattern |
|---|---|
| `plan-archive` (T-12.1) | Owns `~/.claude-plans/_archive.md` exclusively; `backlog-index` does NOT touch `_archive.md`. Plans transitioning `closed → archived` exit the backlog by virtue of `status` filter (step 3); their backlog row drops on next regeneration. |
| `index-maintain` | Owns vault-side `_index.md` reconciliation; `librarian plan-index` (separate capability outside this contract) owns `~/.claude-plans/_index.md`. `backlog-index` is orthogonal — different file, different status filter. |
| `governance-parity-audit` | Surfaces drift between `plans-rules.json` declarations and on-disk state; the disposition_enum + status_enum are audited there. |
| `backlog-hygiene` (skill, not capability) | Consumer of `backlog-row-missing-disposition` findings — escalates severity by `stale_for_days` against `plans-rules.json :: backlog_row.stale_advisory_days` thresholds (14d / 21d). |

## R-37 lockstep coupled surfaces

This contract is an R-37 lockstep peer with:

- `governance/plans-rules.json` `root_files._backlog.md` (writer enforcement registry)
- `governance/plans-rules.json` `backlog_row` (column shape + enums) + `slug_rules` (pattern) + `lifecycle.status_enum`
- `schemas/plan-manifest-schema.json` (manifest schema gate; `disposition` field declaration)
- `governance/_index.json` pillar 8 registry (plans-rules)

Changes to any of the above require R-37 atomic lockstep including this contract spec.

## Implementation hand-off

The capability is specified at this contract; a downstream implementation sub-plan delivers the runtime at `~/.claude/skills/librarian/capabilities/backlog-index.sh`. Implementation requirements:

- **Atomic writes** — `_backlog.md` regeneration via atomic temp+rename.
- **Survivorship** — preserve operator narrative outside sentinel markers; preserve per-row `Notes` cell across regeneration (keyed by `plan_slug`).
- **Read-only** to plan content (`manifest.json` only; never `spec.md` / `tasks.md` / `handoff.md`).
- **bash 3.2 compatible** — per CONTRIBUTING.md §The bash 3.2 compatibility constraint.
- **Output Contract** — implementation MUST carry an Output Contract section per CONTRIBUTING.md §The Output Contract rule.
- **Idempotent** — running the capability twice without intervening manifest edits produces identical `_backlog.md` content (same row set, same cell content, same sort order).

## References

- Plans-rules pillar: `governance/plans-rules.json`
- Plan manifest schema: `schemas/plan-manifest-schema.json`
- Source decisions: Plan 81 SP13 alignment Session 2 Locked decisions (Q1.1 / Q1.2 / Q1.3 / Q1.4 + Fork 1 + A22 6-col flat table)
- Sentinel pattern: `feedback_sentinel_pattern_in_practice` (memory)
- Disposition requirement: `feedback_backlog_disposition_required` (memory)
- Sibling capabilities: `governance/librarian-capabilities/plan-archive.md`, `index-maintain.md`, `governance-parity-audit.md`
- Librarian-finding schema: `schemas/librarian-finding-schema.json`
- Librarian-manifest schema: `schemas/librarian-manifest-schema.json` (`drift_findings.backlog_index` subtree)
