---
type: reference
description: Universal mandatory-file enumeration — the files every vault must carry, the exemption discipline, and the structural enforcement architecture. Session 20 stub scoped to `_index.md` mandate; T-32 expands to the full Session-16-lock universal mandatory-file body.
provides:
  - mandatory-file-rules
  - _index_md-mandate
  - mandatory-file-enforcement
updated: 2026-05-14
max_lines: 250
tags: ["#scope/reference"]
---

> **Summary:** Authoritative reference for the universal mandatory-file lock — which files every vault carries, which folders are exempt, and how the mandate is enforced structurally (not advisorily). Session 20 stub: only the `_index.md` mandate (R-44) is documented; the full vault-root + cluster + instance mandatory-file body lands per the T-32 vault-root rollout. Hand-authored narrative spoke; R-37 lockstep peer of `governance/mandatory-files-rules.json` + `governance/file-type-contracts/_index.md.json` + `hooks/post-write-verify.sh` + `target-state/_index.md-design/`.
> **Canonical for:** mandatory-file-rules, _index_md-mandate, mandatory-file-enforcement
> **Last substantive update:** 2026-05-14

# Vault Architecture — Mandatory-Files

The mandatory-file lock is the structural enforcement layer that determines which files every vault carries. Without the lock, vault contents are user-discretionary and the system loses every guarantee built on "every engagement has an Overview", "every folder has a navigable index", or "the vault root carries CLAUDE.md." With the lock, those guarantees are structural: the post-write hook auto-bootstraps missing files at first-write to a non-exempt path; the librarian audit sweep catches drift between sweeps; adopters never have to remember to author the file. The discipline is enforced at write-time because the alternative — "we'll add the index later" — empirically does not return. The long-form research narrative lives at the canonical [`mandatory-file-lock.md`](https://stem.peter.dev/research/vault-construction/mandatory-file-lock/) packet; the `_index.md`-specific design lives at [`_index.md-design.md`](https://stem.peter.dev/research/vault-construction/_index.md-design/).

## Session 20 scope note

This spoke landed in Session 20 with the `_index.md` mandate (R-44) only. The full universal mandatory-file enumeration (CLAUDE.md vault-root only per canonical §C; `System Backlog.md` vault-root mandate; `Vault Architecture.md` vault-root mandate + `Vault Architecture/` spoke folder; `Inbox/` mandate + `Inbox/_index.md`; `Meetings/` folder; per-folder + per-cluster mandatories; R-07 / R-09 / R-12 / R-14 from the pillar's original assigned rule range) lands incrementally per the vault-root rollout roadmap. T-32 closes when the full body is in.

## The `_index.md` mandate (R-44)

Every non-exempt user-facing folder in the vault MUST carry a sibling `_index.md` at folder root. The mandate is structural — enforced via the three-tier maintenance architecture (live hook + audit sweep + opt-in deep audit), not surfaced as advisory drift. Folder creation is a side effect of file writes in Claude Code (no dedicated folder-create hook surface), so first-write to a new folder IS the bootstrap trigger; the hook auto-creates `_index.md` before reconciling the entry for the write that triggered it.

**Why the file is mandatory.** Folders without `_index.md` appear as leaves in graph view; LLMs reading the folder have no orientation document and must read each child file individually at full token cost; human readers fall back to filename-by-filename scanning. Pre-mandate baseline in the reference deployment showed folder-level navigation breaking past ~10 children and collapsing past ~50.

**Contract.** Frontmatter contract at [`governance/frontmatter-rules.json` `#types.index`](../../../governance/frontmatter-rules.json) — `type: index` + `tags:` (mandatory) + `parent_folder:` (required at `path_depth >= 2`, omitted at depth 1) + `updated:` (ISO-8601 date). Body-structure contract at [`governance/file-type-contracts/_index.md.json`](../../../governance/file-type-contracts/_index.md.json) — H1 matching folder name + folder-context paragraph (2-4 sentences) + contents-enum table (`File | Lines | Type | Description`) wrapped in sentinel markers (`<!-- contents-enum:start -->` / `<!-- contents-enum:end -->`).

**Two-resource pattern.** The `_index.md` mandate follows the k8s `ValidatingAdmissionPolicy` shape: the matcher (the rule that declares THIS file type has a mandate + the file pattern + the exemption list) lives at [`governance/mandatory-files-rules.json` `mandates._index_md`](../../../governance/mandatory-files-rules.json); the parameters (body-structure contract — H1, table columns, sentinel markers, etc.) live at the separately-replaceable `governance/file-type-contracts/_index.md.json`. Hooks load the matcher to decide whether to fire, then load the parameter contract to validate body structure. Adopters override the parameters via Layer-3 overlay at `$CLAUDE_HOME/governance/file-type-contracts/_index.md.adopter.json` with `_override_reason` (R-52).

## Exemption discipline — positive list

A meaningful minority of folders are NOT mandated `_index.md`. The exemption list at [`governance/mandatory-files-rules.json` `mandates._index_md.exemption_paths`](../../../governance/mandatory-files-rules.json) is a positive list — unenumerated folders default to the mandate firing. Adding a new exemption requires R-37 atomic lockstep updating the registry entry + `hooks/post-write-verify.sh` exemption-check + `skills/librarian/capabilities/index-maintain.sh` exemption-check + this spoke.

| Exempt path glob | Category | Why exempt |
|---|---|---|
| `Archive/**` | Cold storage | Append-only history; navigation by name has low signal because contents are date-prefixed |
| `Daily/**` | Date-prefixed sequence | Navigation is date-query / tag-filter, not folder-listing |
| `Inbox/**` | Scraper aggregation | `Inbox/_index.md` is maintained by the dedicated `inbox-index-refresh` capability, not `index-maintain`; per-connector aggregation files are documented inline |
| `Logs/**` | Scratch-space emission | Claude scratch space; emission-driven, not navigation-targeted |
| `Meetings/**` | Date-prefixed sequence | Navigation is date-query / tag-filter, not folder-listing |

Generalized: **a folder is exempt when its contents are date-prefixed sequences, scraper aggregation surfaces, scratch-space emissions, or non-vault infrastructure.** Folders carrying named content files for human and LLM consumption — engagements, projects, people directories, reference, skills, personal initiatives — are mandatory-`_index.md`.

## Three-tier enforcement architecture

`_index.md` files are partially machine-maintained. The contents-enum table drifts the moment a child file is added, removed, or renamed; the `updated:` frontmatter timestamp drifts every time the table changes. Three tiers cover the full write surface — Claude `Edit`/`Write` calls (the 80% case) + cron-script writes + direct-Obsidian edits + manual moves + deletes (the 20% case).

| Tier | Trigger | Scope | Writes |
|---|---|---|---|
| **Tier 1** — live sync via `hooks/post-write-verify.sh` | PostToolUse on every Edit/Write | Single folder of the written file | Auto-bootstrap (if `_index.md` missing AND folder non-exempt); reconcile entry for written file; bump `updated:` |
| **Tier 2** — audit sweep via `skills/librarian/capabilities/index-maintain.sh` | `/librarian full` + scheduled daily cron | Every non-exempt folder in the vault | Add missing rows; remove orphan rows; auto-correct mechanical drift (Lines, Type); bump `updated:` |
| **Tier 3** — `--deep` semantic validation | `/librarian index-maintain --deep` (opt-in) | Same as Tier 2 | Auto-correct mechanical drift; FLAG semantic drift (description-vs-H1 mismatch, ordering incoherence) for operator review — NEVER auto-overwrites hand-tuned content |

**One-line self-exempt loop guard** at the Tier 1 hook entry prevents recursion on the hook's own writes: `[[ "$FILE_PATH" == */_index.md ]] && exit 0`. The guard fires before any work; the hook fires for the index-write that step 5 produces, the guard catches it, exit 0, no loop.

**Self-healing boundary (R-34).** The `index-maintain` capability is the first canonical self-healing capability under the R-34 boundary: mutations bounded to mechanically-derivable values (Lines from `wc -l`, Type from frontmatter `type:`, missing/orphan rows from filesystem reality). Semantic content (descriptions, ordering decisions, exemption-list amendments) is flagged for operator review and never auto-overwritten.

## R-37 lockstep coupled surfaces

This spoke binds five coupled surfaces under R-37 atomic lockstep. Changes touching the `_index.md` mandate or any other mandatory-file entry require touching ALL surfaces in a single commit:

1. `governance/mandatory-files-rules.json` — the rule registry + `mandates` block
2. `governance/file-type-contracts/<file>.json` — the per-file-type body-structure contract (this commit ships `_index.md.json`)
3. `governance/frontmatter-rules.json` — the frontmatter contract per `#types.<type>` entry (dissolved from schemas/vault-schema.json in SP13 T-4; provides `#types.index` with `parent_folder` depth-conditional + `body_structure_contract` pointer)
4. `hooks/post-write-verify.sh` — Tier 1 auto-bootstrap + live-sync + loop guard
5. This spoke — narrative rationale + exemption-list publication

Adopter Layer-3 overlays follow the R-52 collision tiebreaker (adopter shadows foundation with `_override_reason`); foundation upgrades touching shadowed entries surface as `governance-parity-audit` findings.

## Pending T-32 body (not in this spoke yet)

- Vault-root `CLAUDE.md` mandate (one-class per canonical §C; folder-scoped/per-cluster/per-instance/engagement-level all retired)
- `System Backlog.md` vault-root mandate
- `Vault Architecture.md` vault-root mandate + `Vault Architecture/` spoke folder
- `Inbox/` mandate + `Inbox/_index.md` always + `Inbox/<connector>.md` conditional (Session 18 Option B)
- `Meetings/` folder mandate
- Per-folder + per-cluster + per-instance canonical files (Overview / Updates / Context / People)
- R-07 (mirror-review), R-09 (Logs deny-list), R-12 (Personal Initiatives), R-14 (plan-index) rule body

T-32 carries all of the above. The vault-root rollout roadmap packet sequences the work.

## References

- Rule registry: [`governance/mandatory-files-rules.json`](../../../governance/mandatory-files-rules.json)
- `_index.md` body-structure contract: [`governance/file-type-contracts/_index.md.json`](../../../governance/file-type-contracts/_index.md.json)
- Frontmatter contract: [`governance/frontmatter-rules.json` `#types.index`](../../../governance/frontmatter-rules.json)
- Capability contract: [`governance/librarian-capabilities/index-maintain.md`](../../../governance/librarian-capabilities/index-maintain.md)
- Design source (target-state): [`target-state/_index.md-design/`](../../../target-state/_index.md-design/)
- Research narrative: [`research/vault-construction/_index.md-design.md`](../../../research/vault-construction/_index.md-design.md), [`research/vault-construction/mandatory-file-lock.md`](../../../research/vault-construction/mandatory-file-lock.md)
- Sibling spokes: [`Vault Architecture - Frontmatter.md`](./Vault%20Architecture%20-%20Frontmatter.md), [`Vault Architecture - Tagging.md`](./Vault%20Architecture%20-%20Tagging.md), [`Vault Architecture - Naming.md`](./Vault%20Architecture%20-%20Naming.md)
