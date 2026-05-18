# doc-dependencies — Cascade Registry Conventions

> **Summary:** The `doc-dependencies` governance pillar tells `pre-write-guard.sh` which files mirror which canonical sources, so a write to either side surfaces a "review the mirror" prompt. Adopters extend the registry via the `overlay-master.json#doc_dependencies` slot. **Canonical for:** canonical §A pillar #5 (`governance/doc-dependencies.json`), canonical §H overlay-master shape (`overlay-master.json#doc_dependencies`). **Last substantive update:** 2026-05-15 (SP13 Session 8 E-2 — rewrite to canonical 6-pillar + overlay-master shape).

`governance/doc-dependencies.json` is a first-class governance pillar (canonical §A pillar #5). It tells `pre-write-guard.sh` which files mirror which canonical sources, so a write to either side surfaces a "review the mirror" prompt before the session continues. The hook is advisory — it does not block the write — but it catches the case where you edit one half of a duplicated piece of content and forget to update the other.

**Audience:** users adding or auditing cascade registry entries, or extending the registry via overlay-master.

---

## What this file does

`pre-write-guard.sh` reads the cascade registry on every `Edit`, `Write`, or `MultiEdit` tool call against a vault file. If the write target matches an entry's `primary`, `primary_dir`, or one of its `mirrors[].file` paths, the hook injects an advisory message — "this write touches a registered dependency, review the mirrors." You can review and update the mirror in the same session OR file a waiver via `cascade_waiver_write` (waivers are documented in the librarian SKILL.md).

The cascade registry is **advisory** — it never blocks writes. Its job is to surface the dependency at the moment of edit so you don't ship a write whose mirror has silently rotted.

---

## Foundation pillar + overlay-master extension

The cascade registry is structured per canonical §A + §H:

| Layer | Location | Purpose |
|---|---|---|
| Foundation pillar | `governance/doc-dependencies.json` | Foundation-shipped entries: vault-root mandatory file hub-spoke cascades, skill-to-backlog cascades, plan-state cascades. Generic across all adopters. Composed into `governance/foundation-master.json`. |
| Overlay-master extension | `overlay-master.json#doc_dependencies` | Adopter-added cascade entries. Per canonical §H, overlay-master is a perfect parallel of foundation-master — the `doc_dependencies` slot holds adopter entries in the same `entries[]` shape. Populated via `/govern register --kind doc-dep` or hand-edit. |

**Why separate.** The foundation pillar stays portable across adopters. Per-vault cascade entries — folder directory mirrors, hub-spoke documentation pairs, project-tree indexes — belong in the overlay-master extension, not in the foundation pillar. The foundation pillar is authored in the foundation-repo and requires a PR + bundle rebuild to change; the overlay extension lives in the adopter's vault.

Per canonical §B, `pre-write-guard.sh` reads from `governance/foundation-master.json` (the composed bundle loaded once per write session). Overlay-master extension is loaded alongside and merged additively at read time by id: overlay entries with a matching `id` replace foundation entries; overlay entries with new ids are appended.

---

## Entry shape

Every entry under `entries[]` has this shape:

```json
{
  "id": "va-hub-spoke",
  "kind": "hub-spoke-cascade",
  "primary": "System Governance.md",
  "mirrors": [
    {"file": "System Governance - Frontmatter.md", "section": "(whole)"},
    {"file": "System Governance - Tagging.md", "section": "(whole)"},
    {"file": "System Governance - Naming.md", "section": "(whole)"},
    {"file": "System Governance - Mandatory-Files.md", "section": "(whole)"},
    {"file": "System Governance - Doc-Dependencies.md", "section": "(whole)"},
    {"file": "System Governance - File-Type-Contracts.md", "section": "(whole)"}
  ],
  "rationale": "System Governance.md is the hub; the 6 pillar spokes are its mirrors per canonical §D."
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Unique stable identifier. Convention: kebab-case noun phrase describing what's mirrored. |
| `kind` | yes | Common values: `directory-write-constraint`, `directory-membership-cascade`, `hub-spoke-cascade`, `cross-file-type-union`, `directory-mirror`, `satellite-cascade`, `external-mirror`. Free-form — consumers tolerate unknown kinds with advisory warnings. Convention-only for humans auditing the registry. |
| `primary` | one-of | Single canonical source path (vault-relative for vault paths; `~/...` or `$VAR/...` for paths outside the vault). |
| `primary_dir` | one-of | Directory prefix; matches any write under it. Either `primary` OR `primary_dir` must be set. |
| `mirrors` | yes | Array of `{file, section}` objects. Empty `mirrors[]` is discouraged but allowed for documentation purposes. |
| `mirrors[].file` | yes | Mirror path. Same path conventions as `primary`. |
| `mirrors[].section` | optional | Markdown section name or anchor scope. Surfaces in the cascade prompt as "review mirrors → \<file\> §\<section\>". `(whole)` is convention for "the whole file." |
| `rationale` | optional | Why this cascade exists. Helps future maintainers decide whether to keep, update, or drop the entry. |

---

## When to add an entry

Add an entry when **a piece of authoritative content is duplicated by design** in two or more locations. Common cases:

1. **Hub-spoke cascade.** A hub document mirrors content to spoke documents. Example: `System Governance.md` ↔ 6 pillar narrative spokes. Editing the hub without updating a spoke creates drift.

2. **File-type-contracts mirror.** A file-type contract mirrors documentation that describes it. Example: `governance/file-type-contracts/CLAUDE.md.json` ↔ `System Governance - File-Type-Contracts.md` spoke entry for `CLAUDE.md`. Both describe the same body-structure contract.

3. **Satellite-cascade.** A summary row mirrors per-row history files. Example: System Backlog rows ↔ `Logs/backlog-progress/<slug>.md`. The row carries the current-state pointer; the satellite is the single source of session history.

4. **Directory-mirror.** A folder's children are enumerated in an index file. Example: a top-level cluster directory is enumerated in vault `CLAUDE.md`'s directory layout section. Adding a new entry to the cluster must update the index.

5. **External-mirror.** A symlink or pointer references content outside the vault. Example: `Plans/` symlinks to `$PLANS_HOME/`; the vault-side path is read-only navigation, the canonical state lives at `$PLANS_HOME`.

If you find yourself editing the same content in two places without the hook prompting, add an entry. If the prompt fires for a cascade you no longer maintain, drop the entry.

**Where to put the new entry:**

| Entry describes... | Goes in... |
|---|---|
| A mirror that exists in any vault adopting the foundation (skill spec ↔ backlog row; plan spec ↔ backlog row) | `governance/doc-dependencies.json` (foundation pillar — requires foundation-repo PR) |
| Vault-local convention (a folder mirror, a hub-spoke pair, a project tree) | `overlay-master.json#doc_dependencies.entries[]` |
| A local override of a foundation row (e.g., widening path_inferred_exceptions) | `overlay-master.json#doc_dependencies.entries[]` with `id` matching the foundation row |

When in doubt, write to the overlay-master extension. The foundation pillar is foundation-distributed and changing it requires a foundation-repo release.

---

## How the hook reads the file

`pre-write-guard.sh` loads `governance/foundation-master.json` (the composed bundle) once per write session (per canonical §B bundle-at-load). The cascade registry is available at `bundle.doc_dependencies.entries[]`. The overlay-master extension is loaded alongside and merged additively at read time.

The match logic (jq pipeline, abbreviated):
```jq
.entries[]?
| select(
    ($rel != "") and (
      (($e.primary // "") == $rel) or
      ((($e.mirrors // []) | map(.file) | index($rel)) != null) or
      ((($e.primary_dir // "") != "") and ($rel | startswith($e.primary_dir)))
    )
  )
```

Three trigger paths: exact-match on `primary`, exact-match on any `mirrors[].file`, prefix-match on `primary_dir`. The matched entry's `id`, `kind`, and `mirrors[]` are surfaced in the advisory message.

---

## Extending the registry via overlay-master

To add a vault-local cascade, write to `overlay-master.json#doc_dependencies.entries[]`. The `/govern register --kind doc-dep` skill writes this slot for you; hand-editing is also supported.

**Example — consultant archetype, engagement directory mirror:**

If you maintain engagement folders under a cluster and enumerate them in an index file, add a cascade so pre-write-guard reminds you when a folder is added or removed. This entry belongs in overlay-master — it references a user-named cluster that is a consultant-archetype extension, not a foundation-shipped surface (per canonical §H):

```json
{
  "id": "engagement-list",
  "kind": "directory-membership-cascade",
  "primary_dir": "Engagements/",
  "primary_scope": "top-level-children",
  "mirrors": [
    {"file": "Engagements/_index.md", "section": "Engagements"}
  ],
  "rationale": "Each engagement folder appears as a row in the catalog index."
}
```

Smoke-test: touch any file under `Engagements/` and confirm the advisory message lists `engagement-list` with `mirrors → Engagements/_index.md §Engagements`.

---

## Upstream→downstream propagation (SP14 scope)

Per canonical §A pillar #5 (session-1 follow-on amendment), `doc-dependencies.json` also governs **upstream→downstream write-time propagation**: when a change to an upstream document should trigger a write to a downstream document, not just a review prompt. This is the "PROMPT-FOR-DOC-DEPS" stage in the governance-mutation pipeline. Entry shape for propagation entries is a superset of the cascade shape above; full spec deferred to SP14.

---

## Known constraints

- **Path resolution is consumer-side.** Both the foundation pillar and overlay entries use `${CLAUDE_HOME}`, `${PLANS_ROOT}`, and path placeholders. Consumers resolve these at read time.
- **Overlay merge is additive.** You cannot "delete" a foundation entry from the overlay. To suppress a foundation row, author an overlay entry with the same `id` and empty `mirrors[]` — overlay-wins semantics mean your entry replaces the foundation row at runtime.
- **`_*` keys are reserved for inline documentation.** Underscore-prefixed string keys (`_comment`, `_note`) at the top level are permitted by the schema and ignored by consumers.
- **Schema validation.** `schemas/doc-dependencies-schema.json` validates the foundation pillar shape. `install.sh` runs jsonschema validation at install time when the `python3 jsonschema` module is reachable.

---

## Related

- [`adding-a-vault-file-type.md`](adding-a-vault-file-type.md) — 5-surface lockstep when adding a new file type; Surface 3 (doc-dependencies cascade) applies when the new type's folder is enumerated in an index file.
- [`provenance-frontmatter.md`](provenance-frontmatter.md) — provenance contract for auto-authored overlay files.
- `governance/doc-dependencies.json` — the foundation pillar (canonical authoring source).
- `governance/foundation-master.json` — the composed bundle; `doc_dependencies` slot is available to hooks at write-time.
- `schemas/doc-dependencies-schema.json` — JSON Schema for entry validation.
- `skills/librarian/SKILL.md` (waiver-audit capability) — how to file a cascade waiver when you intentionally ship a write without updating the mirror.
