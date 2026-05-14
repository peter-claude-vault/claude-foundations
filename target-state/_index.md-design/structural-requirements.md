---
type: reference
parent_folder: target-state/_index.md-design
tags:
  - "#scope/reference"
updated: 2026-05-14
source_packet: ../../research/vault-construction/_index.md-design.md
machine_contract: ./structural-requirements.json
---

# `_index.md` structural requirements

These are the **mandatory** structural elements every `_index.md` carries. The companion [`structural-requirements.json`](./structural-requirements.json) captures the machine-readable contract that the post-write hook (Tier 1 live-sync + auto-bootstrap) and the librarian `index-maintain` capability (Tier 2 audit sweep + Tier 3 deep validation) consume; this markdown narrative is the human-readable rationale + per-section discipline. Optional elements and discipline patterns (cross-references, README distinction) live in [`conventions-and-rationale.md`](./conventions-and-rationale.md). Enforcement mechanism + exemption list + anti-patterns live in [`governance.md`](./governance.md).

## Per-folder `_index.md` structure — locked

Every `_index.md` in the vault follows the same shape. Empirically derived from the reference-deployment corpus.

### Frontmatter (mandatory)

```yaml
---
type: index
parent_folder: Engagements/CDMO DDX          # MANDATORY at depth ≥ 2; OMIT at depth 1
tags:
  - "#engagement/cdmo-ddx"                    # structural-dimension lineage; mirrors folder per folder-lineage convention
updated: 2026-05-14
---
```

Optional: `description:` (one-line scope description); `provides:` (cross-folder grep handle when this index is the canonical source for a domain).

**Field roles:**

| Field | Role |
|---|---|
| `type: index` | Maps to the canonical type enumeration in `schemas/vault-schema.json`; R-32 Tier 2 DENY rejects unknown types |
| `parent_folder:` | Path string relative to vault root, naming the parent folder of this `_index.md`. **Mandatory at depth ≥ 2** (any `_index.md` not directly under vault root). **Omitted at depth 1** (e.g., `Engagements/_index.md`, `Reference/_index.md` — the "parent" is the vault root itself, which is not a folder in the meaningful sense). Gives Claude a programmatic parent-pointer for index-tree traversal without path-parsing. Auto-populated by the bootstrap hook; librarian `index-maintain` audits for path-vs-frontmatter drift. |
| `tags:` | Mandatory because `_index.md` files participate in the folder-mirrors-tag invariant. Tag matches the folder's structural-dimension lineage — `Engagements/<X>/_index.md` carries `#engagement/<X>`; `Reference/_index.md` carries `#scope/reference` |
| `updated:` | ISO date; bumped by every machine-maintenance pass on the file |

**Structural-dimension lineage fields** (`engagement:`, `project:`, etc.) are inherited from the folder-lineage convention in [`frontmatter-design.md`](../../research/vault-construction/frontmatter-design.md). An `_index.md` at `Engagements/CDMO DDX/People/_index.md` carries `engagement: cdmo-ddx` in frontmatter because every file at that path does. Folder-lineage is the content-side lineage convention answering "what engagement does this file belong to"; `parent_folder:` is the navigation-side parent pointer answering "where in the folder tree does this index sit." Different consumers, different jobs, both auto-populated.

### H1 heading (mandatory)

Matches the folder name or close variant. Examples: `Acme Corp`, `Reference — Tier 1`, `Skills Index`, `Data-Platform`. Reinforces the folder-mirrors-tag invariant — the heading reads like a tag value.

### Folder-context paragraph (mandatory)

2–4 sentences describing what lives in the folder, what doesn't, why the folder exists. Pedagogical — both humans and LLMs read this to orient. The paragraph is the **load-bearing** content of the index; without it, the file is regeneratable boilerplate. Example: *"CRM files for all contacts on the engagement. Each file covers role, org, interaction history, and relationship context."*

### Contents enumeration (mandatory, machine-maintained)

Tabular list of child files. Four columns; each earns its keep by mapping to a distinct load-decision input.

#### Why these columns

| Column | Encodes | Why Claude needs it |
|---|---|---|
| **File** | Wikilink to the artifact | Folder navigation — the unambiguous identifier; clickable from any Obsidian reader |
| **Lines** | Line count of the child file | Cost-to-load signal — token-budget approximation before Claude decides to read it |
| **Type** | Frontmatter `type:` value (canonical 26-enum, R-32-enforced) | Structural role identifier — distinguishes the engagement's `overview` from `reference` from `people` without needing separate sectioning |
| **Description** | One-line prose | What reading this file gives you in plain language |

The **`provides:` frontmatter field does NOT surface in this table.** It remains in each file's frontmatter as the cross-folder grep handle (R-39: `grep -r 'provides:.*<concept>'` finds every file declaring canonicality for a concept). Surfacing it per-row in the index duplicated `description:` in practice — same information in two formats — and the hand-authored table cells drifted from source-of-truth frontmatter the moment a file was added or renamed.

**Empirical example — engagement folder `_index.md` contents enumeration:**

```
| File | Lines | Type | Description |
|---|---|---|---|
| [[Acme - Overview.md]] | ~111 | overview | Scope, objectives, team structure |
| [[Acme - Context.md]] | ~67 | context | Current phase, key decisions, navigation cues |
| [[Acme - Updates.md]] | ~145 | updates | Reverse-chronological status log + decisions |
| [[Acme - Reference.md]] | ~141 | reference | Tech stack, vocabulary, meeting calendar |
```

Note the example carries no `CLAUDE.md` row. Per Session 16 lock #1, only the vault-root `CLAUDE.md` exists in the target architecture; engagement-level, folder-scoped, per-cluster, and per-instance `CLAUDE.md` classes are all retired. Engagement-level navigation is delivered by the `_index.md` itself (this file, plus the canonical Overview/Context/Updates trio); see [`claude-md-design.md`](../../research/vault-construction/claude-md-design.md) for the one-class CLAUDE.md mandate.

**Key-file convention surfaced via type, not sectioning.** At engagement folders, the trio `overview` / `context` / `updates` carries primary context — Claude loads these first for any engagement task. At project folders, the trio is `prd` / `context` / `updates`. At about-me folders, `reference` is the dominant type and the `_index.md` itself plus the folder-context paragraph carry the orientation. Adopters learn the convention from the file-type column itself; the canonical type enumeration is small enough (26 values) and stable enough (R-32-enforced) that role-by-type is self-evident without a separate "key files" header.

For light-content folders, a prose "Current Contents" section replaces the table when enumeration would be premature.

## Source pointers

- Machine contract: [`structural-requirements.json`](./structural-requirements.json) — the JSON schema/contract that hooks and librarian capabilities consume to validate `_index.md` files
- Source packet: [`research/vault-construction/_index.md-design.md`](../../research/vault-construction/_index.md-design.md)
- Companion specs in this folder: [`conventions-and-rationale.md`](./conventions-and-rationale.md) (rationale), [`governance.md`](./governance.md) (enforcement)
- Frontmatter contract for the `index` type entry: `schemas/vault-schema.json#types.index` (canonical) + governance JSON registry `governance/frontmatter-rules.json` (runtime)
- Folder-lineage convention: [`frontmatter-design.md`](../../research/vault-construction/frontmatter-design.md) §Folder-lineage convention
