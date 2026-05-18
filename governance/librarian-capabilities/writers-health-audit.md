---
type: reference
description: Librarian writers-health-audit capability contract. Daily sweep of writer-reference files + skill registry + path_routing for drift. Findings to `~/.claude/state/librarian-findings/writers-*.jsonl` (one finding per line). 5 finding classes per Session 5 L-62.
provides:
  - writers-health-audit-capability
  - vault-writers-drift-detection
updated: 2026-05-18
tags: ["#scope/reference"]
---

# Librarian capability — writers-health-audit

**Status:** specified (implementation deferred to a downstream sub-plan; contract authored in Plan 81 SP14 T-12.5)
**Pillar consumer:** Vault Writers governance (pillar 7 — `governance/vault-writers-rules.json` + file-type-contract `governance/file-type-contracts/vault-writer.md.json`)
**Source rules:** `governance/vault-writers-rules.json` + `governance/file-type-contracts/vault-writer.md.json` + adopter `path_routing` (read via `overlay-master.json` / `foundation-master.json` bundles)
**Source spec:** Plan 81 SP13 alignment Session 5 L-62 (5 finding classes — verbatim)

## Purpose

Daily sweep of writer-reference files + skill registry + adopter path_routing surface for drift. Emit findings to a date-stamped JSONL file at `~/.claude/state/librarian-findings/writers-<date>.jsonl` (one finding per line; append-only per run). The capability is the audit-time backstop for the Vault Writers ecosystem: dormant writers, broken destinations, orphan skill references, retired path-routing patterns, and cross-cluster overlap signals all surface through this sweep. It is the cross-cutting auditor; it does NOT regenerate `_index.md` or `_overlap-matrix.md` (those are owned by `writers-index-refresh` T-12.3 and `writers-overlap-refresh` T-12.4 respectively).

## Output Contract

**Files written:**
- `~/.claude/state/librarian-findings/writers-<date>.jsonl` — append-only JSONL findings file. Each line is one finding row conforming to `librarian-finding-schema.json`. Date stamp is the UTC date of the audit run (`YYYY-MM-DD`); multiple runs on the same date append to the same file.
- Findings mirrored to `librarian-manifest.json` `drift_findings.writers_health_audit[]` via `manifest_set`. No vault file writes.

**Schema each is gated by:**
- Every JSONL line validates against `librarian-finding-schema.json`.
- Every writer-reference markdown read validates frontmatter against `governance/file-type-contracts/vault-writer.md.json` BEFORE finding emission (malformed frontmatter surfaces as `writer-frontmatter-malformed` finding via `writers-index-refresh` — this capability does NOT re-emit that class; the two capabilities have disjoint finding namespaces).
- Manifest subtree mirror validates against `librarian-manifest-schema.json` `drift_findings.writers_health_audit` (open `additionalProperties: true` object).

**Pre-write validation steps:**
- Read `governance/file-type-contracts/vault-writer.md.json` (writer-reference contract).
- Read `governance/vault-writers-rules.json` operational config (for cross-references).
- Read `$VAULT_ROOT/Vault Writers/*.md` writer-reference files.
- Read `~/.claude/state/writer-last-run.jsonl` (if present) for `last_success` timestamps per writer (informs `dormant-writer` finding).
- Read foundation-master + overlay-master bundles via `governance/foundation-master.json` + `~/.claude/governance/overlay-master.json` for the resolved `path_routing` map (informs `unresolved-destination` + `orphan-destination-ref` findings).
- Read installed skill registry via filesystem walk of `~/.claude/skills/*/SKILL.md` (informs `orphan-writer-skill-ref` finding).

**Failure mode:**
- `block and log` on schema-validation failure of source contracts. The capability does not emit silent findings when its inputs are malformed.
- `block and log` on JSONL append that would produce a non-parseable line; pre-validate each finding before append.
- Never `write and hope`. Atomic append-only writes (POSIX `>>` against a date-stamped file; per-line flush).

## Finding categories

Per SP13 alignment Session 5 L-62 (verbatim list — 5 classes):

| Category | Severity | Trigger | Findings payload |
|---|---|---|---|
| `dormant-writer` | warning | A writer-reference has `last_success > 30 days` (per `~/.claude/state/writer-last-run.jsonl`) OR has `status: active` AND `last_run == null` (never observed running) | `{writer_name, writer_kind, status, last_success_iso, days_since_last_success, detected_at, first_seen}` |
| `unresolved-destination` | warning | A writer-reference's `destinations[].path` glob (derived per Session 5 L-69) matches zero existing folders AND no `path_routing` entry declares `auto_create: true` for the pattern (so the reconciler would fail at write-time per Session 4 L-70) | `{writer_name, destination_path_mustache, destination_path_glob, path_routing_resolution, detected_at, first_seen}` |
| `orphan-writer-skill-ref` | warning | A writer-reference's `writer_skill` field points to a skill slug that does not exist in `~/.claude/skills/<slug>/SKILL.md` | `{writer_name, writer_skill_ref, resolved_skill_path_or_null, detected_at, first_seen}` |
| `orphan-destination-ref` | warning | A writer-reference's `destinations[].path` references a `path_routing` pattern that has been retired (no longer present in foundation-master + overlay-master union OR present but flagged retired) | `{writer_name, destination_path_mustache, retired_pattern_id, detected_at, first_seen}` |
| `multi-writer-overlap` | info (cross-reference) | A writer-reference's destinations[] entry appears in a `_overlap-matrix.md` multi-writer cluster (cross-reference finding — same data as `writers-overlap-refresh` cluster output, surfaced here per-writer for health-audit consumers) | `{writer_name, overlap_cluster_glob, peer_writers[], detected_at}` |

Severity `warning` findings count against the librarian's session-close summary; `info` cross-reference findings surface but do not block close-out.

## Audit cadence

| Mode | Trigger | Output |
|---|---|---|
| **Tier 2 — daily cron** | Launchd plist runs the capability every 24h | Append findings to `~/.claude/state/librarian-findings/writers-<date>.jsonl` + manifest mirror |
| **Tier 2 — /librarian full** | Operator runs `/librarian full` at session-close or on-demand | Same outputs as cron |
| **On-demand** | `/librarian writers-health-audit` invocation | Same outputs |

## Behavior — per-writer sweep

1. **Read pillar + contract.** Load `governance/file-type-contracts/vault-writer.md.json` + `governance/vault-writers-rules.json`.
2. **Enumerate writer-references.** Walk `$VAULT_ROOT/Vault Writers/*.md`; exclude `_index.md` + `_overlap-matrix.md` + leading-underscore files.
3. **Read last-run state.** Load `~/.claude/state/writer-last-run.jsonl` (if present); build `writer_name → last_success_iso` map.
4. **Read path-routing resolution.** Load foundation-master + overlay-master bundles; build resolved `path_routing` map (overlay shadows foundation per R-52).
5. **Read skill registry.** Walk `~/.claude/skills/*/SKILL.md`; build slug set.
6. **Per-writer checks** (5 finding classes):
   - **`dormant-writer`** — Compare `last_success_iso` against `now - 30 days`. Emit if older OR if `status: active && last_run == null`.
   - **`unresolved-destination`** — For each `destinations[].path`: derive glob (Mustache `{{<var>}}` → `*`); test against filesystem reality (glob expansion); check `path_routing` for `auto_create: true` declaration. Emit if no folder matches AND no auto-create rule applies.
   - **`orphan-writer-skill-ref`** — Look up `writer_skill` slug in the skill-registry set. Emit if absent.
   - **`orphan-destination-ref`** — For each `destinations[].path`: check if the pattern references a retired `path_routing` entry (per `path_routing` `retired_at` markers or removal from foundation+overlay union). Emit if reference is to a retired pattern.
   - **`multi-writer-overlap`** — Read `Vault Writers/_overlap-matrix.md` (if present); for each cluster the writer participates in, emit one finding row per cluster.
7. **Append findings.** For each emitted finding, append one JSONL line to `~/.claude/state/librarian-findings/writers-<date>.jsonl`. Atomic per-line via `>> file`.
8. **Mirror to manifest.** Update `librarian-manifest.json` `drift_findings.writers_health_audit[]` via `manifest_set` (atomic temp+rename).

## Input sources

The capability reads from (in order):

1. **`governance/file-type-contracts/vault-writer.md.json`** — writer-reference contract (frontmatter shape + destinations entry shape).
2. **`governance/vault-writers-rules.json`** — operational config + `foundation_variable_namespace`.
3. **`$VAULT_ROOT/Vault Writers/*.md`** — writer-reference files (current state).
4. **`~/.claude/state/writer-last-run.jsonl`** — last-success state per writer (if present).
5. **`governance/foundation-master.json` + `~/.claude/governance/overlay-master.json`** — bundled `path_routing` map resolution.
6. **`~/.claude/skills/*/SKILL.md`** — skill registry filesystem walk.
7. **`$VAULT_ROOT/Vault Writers/_overlap-matrix.md`** — pre-existing cluster signals (for `multi-writer-overlap` cross-reference).

## Self-healing boundary declaration (R-34)

This capability operates STRICTLY in **read-only audit mode** under R-34 — it is the audit-time backstop, not a self-healing writer:

- **In bounds:** Findings emission to `~/.claude/state/librarian-findings/writers-<date>.jsonl` (state-tier; not vault content) + manifest mirror to `librarian-manifest.json`.
- **Out of bounds:** Any write to vault content. The capability never edits writer-reference files, `_index.md`, `_overlap-matrix.md`, or any other vault path. Drift surfaces as findings the operator triages.

The boundary is enforced by code structure — the capability has no write-to-vault code path.

## Cooperation with adjacent capabilities

| Capability | Cooperation pattern |
|---|---|
| `writers-index-refresh` (T-12.3) | Disjoint finding namespaces — `writers-index-refresh` emits `writer-frontmatter-malformed` / `writer-missing-required-field` / `writer-kind-violation` (schema validation findings); `writers-health-audit` emits the 5 L-62 classes (operational drift findings). No overlap. |
| `writers-overlap-refresh` (T-12.4) | `multi-writer-overlap` finding cross-references `_overlap-matrix.md` content (the dual-surface pattern — overlap-refresh writes the matrix; health-audit emits per-writer signals into the findings JSONL). |
| `governance-parity-audit` | Sibling audit at the governance-vs-spoke parity layer. `writers-health-audit` is the vault-writers-specific operational audit; `governance-parity-audit` covers cross-pillar JSON-vs-spoke drift. |
| `index-maintain` / `plan-archive` / `backlog-index` | Sibling librarian capabilities; share the `~/.claude/state/librarian-findings/` write target (each capability writes its own date-stamped file). |

## R-37 lockstep coupled surfaces

This contract is an R-37 lockstep peer with:

- `governance/file-type-contracts/vault-writer.md.json` (writer-reference contract — drift signal source)
- `governance/vault-writers-rules.json` (operational config)
- `governance/_index.json` pillar 7 registry (vault-writers)

Changes to any of the above require R-37 atomic lockstep including this contract spec.

## Implementation hand-off

The capability is specified at this contract; a downstream implementation sub-plan delivers the runtime at `~/.claude/skills/librarian/capabilities/writers-health-audit.sh`. Implementation requirements:

- **Append-only writes** — JSONL lines appended via `>>`; per-line flush; no rewrite of historical lines.
- **Read-only** to vault content — never edits any file under `$VAULT_ROOT`.
- **bash 3.2 compatible** — per CONTRIBUTING.md §The bash 3.2 compatibility constraint (no associative arrays, no `${var,,}`, no `mapfile`).
- **Output Contract** — implementation MUST carry an Output Contract section per CONTRIBUTING.md §The Output Contract rule.
- **Idempotent for `first_seen`** — finding rows preserve `first_seen` across runs (matched by `{category, writer_name, [secondary key]}` tuple); only `detected_at` updates each run.
- **Date stamping** — UTC date is canonical; runs spanning midnight UTC may span two files (acceptable).

## References

- File-type-contract: `governance/file-type-contracts/vault-writer.md.json`
- Vault-writers pillar: `governance/vault-writers-rules.json`
- Source decisions: Plan 81 SP13 alignment Session 5 L-62 (verbatim 5-class list)
- Sibling capabilities: `writers-index-refresh.md`, `writers-overlap-refresh.md`, `governance-parity-audit.md`
- Librarian-finding schema: `schemas/librarian-finding-schema.json`
- Librarian-manifest schema: `schemas/librarian-manifest-schema.json` (`drift_findings.writers_health_audit` subtree)
