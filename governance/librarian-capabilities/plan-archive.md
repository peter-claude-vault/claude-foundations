---
type: reference
description: Librarian plan-archive capability contract. Promotes plans whose manifest status has transitioned to `closed` into the archived state — appends a row to `~/.claude-plans/_archive.md` (quarterly-grouped retrospective table) and flips `manifest.status` to `archived` atomically. Trigger is event-driven (manifest status transition to `closed`); no calendar gate per `feedback_no_calendar_gates`.
provides:
  - plan-archive-capability
  - plans-tree-lifecycle-promotion
updated: 2026-05-18
tags: ["#scope/reference"]
---

# Librarian capability — plan-archive

**Status:** specified (implementation deferred to a downstream sub-plan; contract authored in Plan 81 SP14 T-12.1)
**Pillar consumer:** Plans-tree governance (pillar 8 — `governance/plans-rules.json`)
**Source rules:** `governance/plans-rules.json :: lifecycle.status_transitions.closed_to_archived` + `root_files._archive.md`
**Source spec:** Plan 81 SP13 alignment Session 2 (Locked decisions Q2.1 / Q2.2 / Q2.3 / Q2.5 / Q2.6 + Fork 2)

## Purpose

Promote `~/.claude-plans/<plan-slug>/` from `status: closed` to `status: archived` and append the canonical retrospective row to `~/.claude-plans/_archive.md`. The capability is the librarian's mechanical companion to the `closed → archived` lifecycle transition declared in `plans-rules.json`. Trigger is **event-driven** (manifest status transition to `closed`) — NOT calendar-gated per `feedback_no_calendar_gates`. The capability sweeps for `status: closed` plans, derives the retrospective row from manifest fields, appends to `_archive.md` under the appropriate `## YYYY-Qn` quarterly section, and atomically flips `manifest.status` to `archived`.

The capability is the second canonical self-healing capability under the R-34 boundary (after `index-maintain`). The boundary doctrine: mutations bounded to mechanically-derivable values (retrospective row composed from manifest fields; status field flipped from `closed` to `archived`); semantic content (outcome_summary text, successor pointer, postmortem path) is read from the manifest and never auto-generated.

## Output Contract

**Files written:**
- `~/.claude-plans/_archive.md` — quarterly-grouped table appended-to. The capability owns this file exclusively (`writers_allowed: ["librarian"]` per `plans-rules.json :: root_files._archive.md`). Full regeneration NOT performed; rows are appended under the appropriate `## YYYY-Qn` heading (creating the heading if absent).
- `~/.claude-plans/<plan-slug>/manifest.json` — single-field atomic flip: `status: closed → status: archived`. Other manifest fields preserved verbatim.
- Findings emitted to stdout (NDJSON; `librarian-finding` schema) and mirrored to `librarian-manifest.json` `drift_findings.plan_archive[]` via `manifest_set`.

**Schema each is gated by:**
- `manifest.json` writes validate against `schemas/plan-manifest-schema.json` BEFORE the atomic temp+rename — including the conditional required-on-close fields (`closed_at`, `outcome_summary`, `shipped_artifacts`, `successor`, `postmortem_path`) per SP13 Session 2 Q3.
- `_archive.md` writes carry no separate body-structure schema (markdown table); row shape is fixed by this capability and validated as a post-write structural check.
- NDJSON output validates against `librarian-finding-schema.json`.
- Manifest subtree mirror validates against `librarian-manifest-schema.json` `drift_findings.plan_archive` (open `additionalProperties: true` object).

**Pre-write validation steps:**
- Read `governance/plans-rules.json` `lifecycle.status_transitions.closed_to_archived` (canonical transition contract) + `root_files._archive.md` (writer enforcement).
- Read every `~/.claude-plans/*/manifest.json`; validate each against `schemas/plan-manifest-schema.json` before considering the plan for archival.
- For each `status: closed` plan: assert presence of the conditional required-on-close fields (`closed_at`, `outcome_summary`, `shipped_artifacts`); if missing, emit `manifest-schema-violation` finding and SKIP the plan (do not auto-fix; do not silently archive incomplete manifests).
- Compute the target `## YYYY-Qn` heading from `closed_at` (quarter inferred from ISO month). If `closed_at` is not a parseable ISO date, emit `manifest-schema-violation` and skip.

**Failure mode:**
- `block and log` on schema-validation failure of source rules (`plans-rules.json`) or any manifest under audit. The capability does not perform partial archival when its inputs are malformed; the offending plan is skipped + logged.
- `block and log` on `_archive.md` write that would produce a non-parseable table; the capability validates the rendered row before atomic-rename.
- `block and log` on `manifest.json` post-flip validation failure; tempfile deleted, manifest unchanged, finding emitted.
- Never `write and hope`. Atomic temp+rename for every write; row append is a read-modify-write under sentinel-marker discipline (see Behavior §3).

## Finding categories

| Category | Severity | Trigger | Findings payload |
|---|---|---|---|
| `archive-eligible-plan` | info (event) | A `status: closed` plan was successfully archived this run | `{plan_slug, closed_at, archived_at, archive_row_quarter, detected_at}` |
| `archive-row-malformed` | warning | Composing the retrospective row from manifest produced an invalid row (e.g., embedded pipe character not escaped; ISO date not parseable) | `{plan_slug, malformed_field, manifest_value, detected_at, first_seen}` |
| `manifest-schema-violation` | warning | A `status: closed` plan's manifest fails `schemas/plan-manifest-schema.json` validation OR is missing required-on-close fields; plan skipped this run | `{plan_slug, validation_error_or_missing_fields, detected_at, first_seen}` |

Severity `warning` findings count against the librarian's session-close summary; `info` event findings are surfaced for operator visibility but do not block close-out.

## Audit cadence

| Mode | Trigger | Output |
|---|---|---|
| **Tier 2 — daily cron** | Launchd plist runs the capability every 24h; aligned with `governance-parity-audit` cadence | Manifest-mirrored findings + stdout NDJSON; mechanical archival performed under R-34 |
| **Tier 2 — /librarian full** | Operator runs `/librarian full` at session-close or on-demand | Same outputs as cron |
| **On-demand** | `/librarian plan-archive [--plan-slug <slug>]` invocation | Same outputs; `--plan-slug` scopes to a single plan |

## Behavior — per-plan

1. **Read manifest.** Load `~/.claude-plans/<plan-slug>/manifest.json`. Validate against `schemas/plan-manifest-schema.json`. On failure: emit `manifest-schema-violation`; skip plan.
2. **Status gate.** Skip unless `status == "closed"`. (`researching` / `planned` / `in-progress` / `on-hold` / `superseded` / `archived` all skipped.)
3. **Required-on-close field check.** Assert presence of `closed_at`, `outcome_summary`, `shipped_artifacts`. If any missing: emit `manifest-schema-violation`; skip plan.
4. **Compose retrospective row.** Fields from manifest:
   - `slug` from directory name
   - `closed_at` from `manifest.closed_at` (ISO date)
   - `archived_at` from current UTC date
   - `outcome` from `manifest.outcome_summary` (1-line; escape pipe characters)
   - `shipped_artifacts` joined with `<br>` from `manifest.shipped_artifacts[]`
   - `postmortem_link` from `manifest.postmortem_path` (or `—` if null)
   - `successor_link` from `manifest.successor` (or `—` if null)
   - For superseded-class plans: read `manifest.superseded_by` and surface in `outcome` cell prefix
5. **Validate composed row.** Check pipe-escape integrity; check ISO date parseability. On failure: emit `archive-row-malformed`; skip plan; manifest unchanged.
6. **Resolve target quarterly section.** Compute `## YYYY-Qn` from `closed_at` month. If section absent in `_archive.md`, prepare to create.
7. **Atomic _archive.md update.** Read current `_archive.md`; insert row under target `## YYYY-Qn` section (creating heading + table-header if absent; preserving operator-edits outside the table region via sentinel-marker pattern per `feedback_sentinel_pattern_in_practice`); write tempfile; validate parseability; atomic rename.
8. **Atomic manifest status flip.** Read manifest (re-read for fresh content); flip `status: closed → status: archived`; preserve all other fields verbatim; write tempfile; validate against `plan-manifest-schema.json`; atomic rename.
9. **Emit `archive-eligible-plan` event finding** on success.

## Input sources

The capability reads from (in order):

1. **`governance/plans-rules.json`** — `lifecycle.status_transitions.closed_to_archived` (trigger contract) + `root_files._archive.md` (writer enforcement).
2. **`schemas/plan-manifest-schema.json`** — schema validation gate for every manifest read.
3. **`~/.claude-plans/*/manifest.json`** — manifest scan for `status: closed` candidates.
4. **`~/.claude-plans/_archive.md`** — current archive file (parsed for existing rows + quarterly sections).

## Self-healing boundary declaration (R-34)

This capability operates under the R-34 mechanical-mutation boundary:

- **In bounds (auto-corrected):** `manifest.status` flip from `closed` to `archived`; `_archive.md` row append (composed strictly from manifest fields); quarterly heading creation when target section absent.
- **Out of bounds (flagged, never overwritten):** `outcome_summary` content (operator-authored 1-liner; never paraphrased or expanded); `successor` pointer (operator-declared); `postmortem_path` content; ANY existing `_archive.md` row (immutable historical record); operator-curated narrative outside the row table.

The boundary is enforced by code structure — the atomic-flip branch writes only the `status` field; the row-append branch writes only the canonical retrospective row composed from validated manifest fields.

## Cooperation with adjacent capabilities

| Capability | Cooperation pattern |
|---|---|
| `backlog-index` (T-12.2) | Owns `~/.claude-plans/_backlog.md` exclusively; `plan-archive` does NOT touch backlog rows (a closed-and-archived plan's backlog row lifecycle is managed by `backlog-index` per `plans-rules.json` lifecycle contract). |
| `index-maintain` | Owns `_index.md` reconciliation; `plan-archive` does NOT regenerate `~/.claude-plans/_index.md` (regeneration is `librarian plan-index` responsibility per `plans-rules.json :: root_files._index.md`). |
| `governance-parity-audit` | Surfaces drift between `plans-rules.json` declarations and on-disk state; `plan-archive` is one of the audited surfaces (the canonical writer for `_archive.md` per the pillar). |

## R-37 lockstep coupled surfaces

This contract is an R-37 lockstep peer with:

- `governance/plans-rules.json` `lifecycle.status_transitions.closed_to_archived` (the rule entry this capability implements)
- `governance/plans-rules.json` `root_files._archive.md` (writer enforcement registry)
- `schemas/plan-manifest-schema.json` (manifest schema gate; conditional required-on-close fields)
- `governance/_index.json` pillar 8 registry (plans-rules)

Changes to any of the above require R-37 atomic lockstep including this contract spec.

## Implementation hand-off

The capability is specified at this contract; a downstream implementation sub-plan delivers the runtime at `~/.claude/skills/librarian/capabilities/plan-archive.sh`. Implementation requirements:

- **Atomic writes** — `_archive.md` and `manifest.json` updates via atomic temp+rename; no partial-state visibility.
- **Survivorship** — preserve every existing row in `_archive.md` across runs; preserve operator-authored narrative outside the row table region via sentinel-marker pattern.
- **Read-only** to plan content outside `manifest.json` — the capability never edits `spec.md` / `tasks.md` / `handoff.md` / `00-ideation-brief.md`.
- **bash 3.2 compatible** — per CONTRIBUTING.md §The bash 3.2 compatibility constraint (no associative arrays, no `${var,,}`, no `mapfile`).
- **Output Contract** — implementation MUST carry an Output Contract section in its SKILL.md or in-script header per CONTRIBUTING.md §The Output Contract rule.
- **Idempotent** — running the capability twice without intervening manifest edits produces the same archived-plan set + no duplicate rows in `_archive.md` (the row-append branch is keyed by `plan_slug + closed_at` and skips on existing match).

## References

- Plans-rules pillar: `governance/plans-rules.json`
- Plan manifest schema: `schemas/plan-manifest-schema.json`
- Source decisions: Plan 81 SP13 alignment Session 2 Locked decisions (Q2.1 / Q2.2 / Q2.3 / Q2.5 / Q2.6 + Fork 2)
- Sibling capabilities: `governance/librarian-capabilities/backlog-index.md`, `index-maintain.md`, `governance-parity-audit.md`
- Librarian-finding schema: `schemas/librarian-finding-schema.json`
- Librarian-manifest schema: `schemas/librarian-manifest-schema.json` (`drift_findings.plan_archive` subtree)
