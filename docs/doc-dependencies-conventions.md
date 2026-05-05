# doc-dependencies — Cascade Registry Conventions

`doc-dependencies.json` is a registry that tells `pre-write-guard.sh` which files mirror which canonical sources, so a write to either side surfaces a "review the mirror" prompt before commit. The hook is advisory — it does not block the write — but it catches the case where you edit one half of a duplicated piece of content and forget to update the other.

**Audience:** users adding or auditing entries in `~/.claude/hooks/config/doc-dependencies.json`.

---

## What this file does

`pre-write-guard.sh` reads `doc-dependencies.json` on every `Edit`, `Write`, or `MultiEdit` tool call against a vault file. If the write target matches an entry's `primary`, `primary_dir`, or one of its `mirrors[].file` paths, the hook injects an advisory message into the tool result — "this write touches a registered dependency, review the mirrors." You can review and update the mirror in the same session OR file a waiver via `cascade_waiver_write` (waivers are documented in the librarian SKILL.md).

The cascade registry is **advisory** — it does not block writes. Its job is to surface the dependency at the moment of edit so you don't ship a write whose mirror has silently rotted.

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
| `kind` | yes | One of `satellite-cascade`, `schema-mirror`, `directory-mirror`, `external-mirror`. Free-form — the hook does not branch on this; it's documentation for humans auditing the registry. |
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

---

## What `/onboard` ships

The onboarder generates 3-5 entries based on the structure flags you declared during the interview:

| Always-on | Conditional |
|---|---|
| `system-backlog` (System Backlog.md ↔ Logs/backlog-progress/) | `engagement-list` (gated on `vault.has_structured_projects: true`) |
| `vault-claude-md-canonical-types` (CLAUDE.md ↔ vault-schema.json types[]) | `people-list` (gated on `organizational_method` containing `engagement`) |
| `plan-state` (Plans/ ↔ $PLANS_HOME/_index.md) | |

The generator output carries a top-level `_provenance` field (see [provenance-frontmatter.md](provenance-frontmatter.md)) — `pre-write-guard.sh` reads `.entries[]` only, so the additional sibling key is non-breaking.

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

Editing `doc-dependencies.json` directly is supported — `/onboard` does not clobber user edits on a re-author run because the file-level `_provenance.last_user_edit` field is checked by the regen workflow.

Best practice when hand-editing:

1. Add or modify entries with `jq`:
   ```bash
   jq '.entries += [{id:"my-cascade",kind:"directory-mirror",primary_dir:"Reference/",mirrors:[{file:"CLAUDE.md","section":"Reference"}]}]' \
     ~/.claude/hooks/config/doc-dependencies.json > /tmp/dd.json && mv /tmp/dd.json ~/.claude/hooks/config/doc-dependencies.json
   ```

2. Validate with `jq -e .` after every edit.

3. Bump `_provenance.last_user_edit` to the current ISO timestamp so the regen workflow recognizes the file as user-owned:
   ```bash
   ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   jq --arg ts "$ts" '._provenance.last_user_edit = $ts' \
     ~/.claude/hooks/config/doc-dependencies.json > /tmp/dd.json && \
     mv /tmp/dd.json ~/.claude/hooks/config/doc-dependencies.json
   ```

---

## Related

- [`personalization-model.md`](personalization-model.md) — where doc-dependencies.json sits in the universal/combined/personal taxonomy (Combined tier).
- [`adding-a-vault-file-type.md`](adding-a-vault-file-type.md) — the 5-surface commit pattern when you add a new file type. doc-dependencies updates often happen in that same lockstep.
- [`provenance-frontmatter.md`](provenance-frontmatter.md) — the provenance contract; same shape as the file-level `_provenance` block in this file.
- `skills/librarian/SKILL.md` (waiver-audit capability) — how to file a cascade waiver when you intentionally ship a write without updating the mirror.
