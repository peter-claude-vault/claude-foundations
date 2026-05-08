# doc-dependencies — Cascade Registry Conventions

`doc-dependencies.json` is a registry that tells `pre-write-guard.sh` which files mirror which canonical sources, so a write to either side surfaces a "review the mirror" prompt before commit. The hook is advisory — it does not block the write — but it catches the case where you edit one half of a duplicated piece of content and forget to update the other.

**Audience:** users adding or auditing entries in `~/.claude/hooks/config/doc-dependencies.json` (foundation skeleton) or `~/.claude/hooks/config/vault-overlay.json` (per-vault overlay).

> **Status (2026-05-08).** This doc is the canonical contract for the skeleton/overlay registry. Schema and skeleton ratified Plan 81 SP01 T-28a (Session 12). Consumer-side overlay-read (`pre-write-guard.sh` + 5 librarian capabilities) and onboarder retarget land in T-28b during the T-20 Phase A 7-day soak (≥2026-05-17). Until T-28b ships, only the skeleton is consumed at runtime; overlay entries are accepted by the schema but unused. Adopters can author overlay entries today; runtime activation lands when T-28b commits.

---

## What this file does

`pre-write-guard.sh` reads `doc-dependencies.json` on every `Edit`, `Write`, or `MultiEdit` tool call against a vault file. If the write target matches an entry's `primary`, `primary_dir`, or one of its `mirrors[].file` paths, the hook injects an advisory message into the tool result — "this write touches a registered dependency, review the mirrors." You can review and update the mirror in the same session OR file a waiver via `cascade_waiver_write` (waivers are documented in the librarian SKILL.md).

The cascade registry is **advisory** — it does not block writes. Its job is to surface the dependency at the moment of edit so you don't ship a write whose mirror has silently rotted.

---

## Skeleton vs overlay (the two-file model)

The cascade registry is split across **two paired files** at `${CLAUDE_HOME}/hooks/config/`:

| File | Source | Purpose |
|---|---|---|
| `doc-dependencies.json` | foundation-repo (shipped by `install.sh`) | **Skeleton.** Generic, vault-agnostic entries that ship to every adopter — currently the `vault-schema-type-consistency` cascade and the `skill` / `plan` / `memory-file` entity rows. |
| `vault-overlay.json` | per-vault (hand-edited / onboarder-generated) | **Additive overlay.** Vault-specific entries that mirror local conventions — engagement directory cascades, hub-spoke vault-architecture mirrors, project-tree directory listings, etc. Ships empty (`{version:2, entries:[], entities:{}}`). |

**Why split.** The skeleton stays portable across adopters; per-vault entries don't pollute the foundation distribution. Same structural shape on both sides — same schema, same merge logic — so an entry authored against the overlay is byte-identical to what would have been an inline addition to the unified file.

### Merge precedence (runtime)

Consumers (`pre-write-guard.sh`, `wikilink-repair.sh`, `rename-history-sync.sh`, `entity-parity.sh`, `waiver-audit.sh`, `frontmatter-enforce.sh`) merge the two files additively at read time:

1. **Read skeleton** → `doc-dependencies.json::entries[]` and `entities{}`.
2. **Read overlay** → `vault-overlay.json::entries[]` and `entities{}`.
3. **Merge entries** by `.id`. **Overlay rows replace skeleton rows of the same id.** Overlay ids absent from the skeleton are appended.
4. **Merge entities** by top-level key. **Overlay keys override skeleton keys of the same name.** Overlay keys absent from the skeleton are added.

Same-id and same-key collisions are explicitly resolved overlay-wins so adopters can locally override a foundation-shipped row (e.g., widen `path_inferred_exceptions` on `vault-schema-type-consistency`) without forking the skeleton.

### Schema

Both files validate against the same structural shape:

- Skeleton: schema authoring deferred (T-28a scope). The skeleton's structural contract is mirrored authoritatively in the overlay schema.
- Overlay: [`schemas/vault-overlay-schema.json`](../schemas/vault-overlay-schema.json) (`$id: https://stem.peter.dev/schemas/vault-overlay/v1.json`, Draft 2020-12).

`version` is locked at `2` on both files; consumers reject mismatched versions to surface schema drift early.

---

## Entry shape

Every entry under `.entries[]` has this shape:

```json
{
  "id": "engagement-list",
  "kind": "directory-mirror",
  "primary": "<path-or-relative-to-vault>",
  "primary_dir": "<directory prefix>",
  "mirrors": [
    {"file": "<path>", "section": "<section name or anchor>"}
  ],
  "rationale": "<why this cascade exists>"
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Unique stable identifier. Convention: kebab-case noun phrase describing what's mirrored. |
| `kind` | yes | Common values: `directory-write-constraint`, `directory-membership-cascade`, `hub-spoke-cascade`, `cross-file-type-union`, `directory-mirror`, `satellite-cascade`, `external-mirror`. Free-form — consumers tolerate unknown kinds with advisory warnings; the hook does not branch on this. Convention-only documentation for humans auditing the registry. |
| `primary` | one-of | Single canonical source path (vault-relative for vault paths; `~/...` or `$VAR/...` for paths outside the vault). |
| `primary_dir` | one-of | Directory prefix; matches any write under it. Either `primary` OR `primary_dir` must be set. |
| `mirrors` | yes | Array of `{file, section}` objects. Empty `mirrors[]` means the primary is canonical with no review-target — discouraged but allowed for documentation purposes. |
| `mirrors[].file` | yes | Mirror path. Same path conventions as `primary`. |
| `mirrors[].section` | optional | Markdown section name or anchor scope. Surfaces in the cascade prompt as "review mirrors → \<file\> §\<section\>". `(whole)` is convention for "the whole file." |
| `rationale` | optional | Why this cascade exists. Helps future maintainers decide whether to keep / update / drop the entry as the vault evolves. |

---

## When to add an entry

Add an entry when **a piece of authoritative content is duplicated by design**
in two or more locations. Common cases:

1. **Schema-mirror.** A schema declaration mirrors documentation that describes it. Example: `vault-schema.json::types[]` ↔ vault `CLAUDE.md` "canonical file types" section. Both sides describe the same type taxonomy; editing one without the other creates drift.

2. **Satellite-cascade.** A summary row mirrors per-row history files. Example: System Backlog rows ↔ `Logs/backlog-progress/<slug>.md`. The row carries only the current-state pointer; the satellite is the single source of session history.

3. **Directory-mirror.** A folder's children are enumerated in an index file. Example: each `Engagements/<name>/` directory is enumerated in vault `CLAUDE.md`'s "Directory layout" section and (when present) in `Engagements/_index.md`'s "Engagements" section. Adding a new engagement directory must update both indexes.

4. **External-mirror.** A symlink or pointer references content outside the vault. Example: `Plans/` symlinks to `$PLANS_HOME/`; the vault-side path is read-only navigation, the canonical state lives at `$PLANS_HOME`.

If you find yourself editing the same content in two places without the hook prompting, add an entry. If the prompt fires for a cascade you no longer maintain, drop the entry.

**Where to put the new entry:**

| Entry describes... | Goes in... |
|---|---|
| Vault-local convention (an engagement folder, a vault-architecture hub, a project tree) | `vault-overlay.json` |
| A mirror that exists in any vault that adopts the foundation (skill spec ↔ vault Skill catalog row, plan spec ↔ backlog row) | `doc-dependencies.json` (skeleton — rare; usually a foundation-repo PR) |
| A local override of a skeleton row (e.g., widening `path_inferred_exceptions`) | `vault-overlay.json` with `id` matching the skeleton row |

When in doubt, write to the overlay. The skeleton is foundation-distributed and changing it requires a foundation-repo release.

---

## What `/onboard` ships

The onboarder writes 3-5 entries into **`vault-overlay.json`** (not the skeleton) based on the structure flags you declared during the interview:

| Always-on | Conditional |
|---|---|
| `system-backlog` (System Backlog.md ↔ Logs/backlog-progress/) | `engagement-list` (gated on `vault.has_structured_projects: true`) |
| `vault-claude-md-canonical-types` (CLAUDE.md ↔ vault-schema.json types[]) | `people-list` (gated on `organizational_method` containing `engagement`) |
| `plan-state` (Plans/ ↔ $PLANS_HOME/_index.md) | |

The generator output carries a top-level `_provenance` field (see [provenance-frontmatter.md](provenance-frontmatter.md)) — consumers read `.entries[]` and `.entities{}` only, so the additional sibling key is non-breaking.

---

## How the hook reads the file

`pre-write-guard.sh` extracts the registry path from `${HOOKS_DIR}/config/doc-dependencies.json`. The match logic (jq pipeline, abbreviated):

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

## Editing the registry by hand

Editing either file directly is supported — `/onboard` does not clobber user edits on a re-author run because the file-level `_provenance.last_user_edit` field is checked by the regen workflow.

**For vault-specific entries, write to `vault-overlay.json`.** The skeleton (`doc-dependencies.json`) is foundation-distributed; per-vault edits there get overwritten on the next foundation upgrade unless you maintain a local fork.

Best practice when hand-editing:

1. Add or modify entries with `jq` (overlay example):
   ```bash
   jq '.entries += [{id:"my-cascade",kind:"directory-mirror",primary_dir:"Reference/",mirrors:[{file:"CLAUDE.md","section":"Reference"}]}]' \
     ~/.claude/hooks/config/vault-overlay.json > /tmp/vo.json && mv /tmp/vo.json ~/.claude/hooks/config/vault-overlay.json
   ```

2. Validate with `jq -e .` after every edit. For schema validation:
   ```bash
   jsonschema -i ~/.claude/hooks/config/vault-overlay.json \
     ~/.claude/schemas/vault-overlay-schema.json
   ```

3. Bump `_provenance.last_user_edit` to the current ISO timestamp so the regen workflow recognizes the file as user-owned:
   ```bash
   ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   jq --arg ts "$ts" '._provenance.last_user_edit = $ts' \
     ~/.claude/hooks/config/vault-overlay.json > /tmp/vo.json && \
     mv /tmp/vo.json ~/.claude/hooks/config/vault-overlay.json
   ```

---

## Adopter walkthrough — adding a new vault-local cascade

Scenario: you've started enumerating per-client engagements in `Engagements/_index.md` and you want pre-write-guard to remind you when a write to `Engagements/<name>/` should be reflected in the index.

1. **Identify the cascade shape.** This is a `directory-membership-cascade` (or `directory-mirror`): writes under `Engagements/` should review `Engagements/_index.md`.

2. **Author the entry against the overlay schema.** Append to `~/.claude/hooks/config/vault-overlay.json`:

   ```jsonc
   {
     "id": "engagement-list",
     "kind": "directory-membership-cascade",
     "primary_dir": "Engagements/",
     "primary_scope": "top-level-children",
     "mirrors": [
       {"file": "Engagements/_index.md", "section": "Engagements"}
     ],
     "rule": "if-primary-changes-mirrors-must-be-reviewed",
     "severity": "warn",
     "rationale": "Each engagement folder appears as a row in the catalog index; adding/removing a folder requires updating the index."
   }
   ```

3. **Validate.**
   ```bash
   jq -e . ~/.claude/hooks/config/vault-overlay.json && \
   jsonschema -i ~/.claude/hooks/config/vault-overlay.json \
     ~/.claude/schemas/vault-overlay-schema.json
   ```

4. **Smoke-test.** Touch any file under `Engagements/` and confirm the advisory message lists `engagement-list` with `mirrors → Engagements/_index.md §Engagements`. The hook is advisory; the write proceeds either way.

5. **Iterate.** Tighten `severity` to `deny` (block-not-warn) only after you're confident the cascade is correct — false positives on a `deny` entry cost more than false negatives on a `warn` entry.

### Adding an entity-parity row

Same flow for entities (e.g., a new vault-local entity type that mirrors across multiple files). Append a top-level key to `vault-overlay.json::entities{}`. The merge-by-key semantics mean overlay keys override skeleton keys of the same name — useful when you want to extend a skeleton entity (e.g., add a vault-local mirror to `skill`) without forking the foundation.

### Locally overriding a skeleton entry

If a skeleton entry needs adjusting for your vault — say, widening `path_inferred_exceptions` on `vault-schema-type-consistency` — author an overlay entry with the **same `id`** as the skeleton row. Overlay-wins by id means your override replaces the skeleton row at runtime without a foundation-repo fork.

---

## Known constraints

- **Rename-aware via `rename-history-sync`.** When `librarian` runs at session-close Step 2b, `rename-detect.sh` populates `entries[].rename_history[]` append-only. Hand-editing `rename_history` is discouraged — the rename detector is the canonical writer.
- **Path resolution is consumer-side.** Both files use `${CLAUDE_HOME}`, `${PLANS_ROOT}`, and the `{project_namespace}` placeholder (resolves via `${HOME//\\//-}` or `user-manifest.json::identity.project_namespace`). The placeholders are unresolved on disk; consumers do the substitution at read time.
- **Overlay scope guards.** Overlay entries that reference paths outside the vault (e.g., `${CLAUDE_HOME}/...`) are honored by consumers, but consider whether the cascade belongs in the skeleton instead — foundation-infra cascades shipped with the install benefit every adopter, while vault-only cascades stay in the overlay.
- **`_*` keys are reserved for inline documentation.** Underscore-prefixed string keys (`_comment`, `_note`, `_schema_version`) at the top level and inside `entities{}` are permitted by the schema and ignored by consumers. Use them for inline maintainer notes; do not use them for runtime data.
- **No deletion semantics.** Overlay merge is additive; you cannot mark a skeleton row as "deleted" from the overlay. To suppress a skeleton row, author an overlay row with the same `id` that is structurally a no-op (e.g., empty `mirrors[]`) — the override wins, but the row still exists in the merged registry.

---

## Related

- [`personalization-model.md`](personalization-model.md) — where doc-dependencies.json sits in the universal/combined/personal taxonomy (Combined tier).
- [`adding-a-vault-file-type.md`](adding-a-vault-file-type.md) — the 5-surface commit pattern when you add a new file type. doc-dependencies updates often happen in that same lockstep.
- [`provenance-frontmatter.md`](provenance-frontmatter.md) — the provenance contract; same shape as the file-level `_provenance` block in this file.
- `skills/librarian/SKILL.md` (waiver-audit capability) — how to file a cascade waiver when you intentionally ship a write without updating the mirror.
