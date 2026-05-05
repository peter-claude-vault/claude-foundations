# Adding a New Vault File Type

When you add a new canonical file type to your vault — for example, `interview-note` to live alongside `meeting-note`, `people`, `project`, etc. — the change must land in lockstep across **five surfaces**. Anything less is documented drift: the librarian's drift detector will surface it, and the type will not be enforceable.

**Audience:** users extending the vault schema with a new file type.

---

## Why five surfaces, why one commit

The five surfaces are wired together by the foundation-repo and the librarian capabilities. They are NOT optional: the type does not exist unless every surface knows about it.

Half-landed lockstep changes are the most expensive failure mode. Common drift patterns:

| Surface that landed | Surface that didn't | Symptom |
|---|---|---|
| schema only | not in `detect_type()` | New files fall through to no-type detection; frontmatter-enforce silently passes them. |
| `detect_type()` only | not in schema | Library reports `unknown-schema-type` finding; type cannot be validated. |
| schema + `detect_type()` | not in vault CLAUDE.md | User has no documentation surface; future maintainers add files of the type without knowing the contract. |
| schema + `detect_type()` + CLAUDE.md | not in doc-dependencies | Mirror updates silently rot; index file enumerations drift from reality. |
| All four above | not in placement-validate (when needed) | False-positive findings on routing indexes the user just added. |

The librarian's drift detector surfaces these mismatches on every run, but the audit-then-fix cycle is friction. Lockstep commits avoid the audit loop entirely.

---

## The 5 surfaces (in commit order)

### 1. `vault-schema.json` — the canonical type registry

`~/.claude/schemas/vault-schema.json` declares every type the vault recognizes. Each entry under `.types[]` carries:

```json
{
  "name": "interview-note",
  "required_fields": ["type", "subject", "interviewer", "tags", "updated"],
  "optional_fields": ["transcript_link", "outcome"],
  "path_pattern": "^Interviews/[^/]+\\.md$"
}
```

**Edit:** add a new entry under `.types[]`. The schema is enforced by `frontmatter-enforce.sh` (per-file validation phase) and audited by the librarian drift detector.

### 2. `frontmatter-enforce.sh` — type detection logic

`skills/librarian/capabilities/frontmatter-enforce.sh::detect_type()` maps *paths* to *types* via regex. The new entry's `path_pattern` from vault-schema is the canonical source, but `detect_type()` keeps a parallel hand-tuned table (Python regex literals) for performance — the lookup happens on every file the librarian walks, and a hot-path jq+grep over vault-schema would 5x the audit runtime.

**Edit:** add a `re.match(rf"^...{your-pattern}.*\.md$", rel)` branch returning your type's name. Place it in the existing alphabetical-by-folder order (the matches are mutually exclusive; first-match wins).

### 3. Vault `CLAUDE.md` — "Canonical file types" section

Vault `CLAUDE.md` describes the canonical-file-types contract that `vault-schema.json` enforces. It's the prose-and-rationale companion to the schema's machine-readable `types[]`. The onboarder generates this section from `vault.canonical_file_types[]` in user-manifest, so the lockstep edit is at *manifest level*, not directly in the rendered CLAUDE.md.

**Edit:** add the new type name to `user-manifest.json::vault.canonical_file_types[]`. Re-run `/onboard --section c` to regenerate vault `CLAUDE.md` (the three-step gate previews the diff before any write). OR hand-edit vault `CLAUDE.md` and bump `_provenance.last_user_edit` (see [provenance-frontmatter.md](provenance-frontmatter.md)).

### 4. `doc-dependencies.json` — cascade entry (when relevant)

If the new type lives in a folder whose enumeration is mirrored elsewhere (e.g., a per-engagement `_index.md` lists every interview-note under the engagement), add a cascade entry so `pre-write-guard.sh` surfaces the mirror-review prompt.

**Edit:** add an entry to `~/.claude/hooks/config/doc-dependencies.json::entries[]`. See [doc-dependencies-conventions.md](doc-dependencies-conventions.md) for the entry shape. NOT every new type needs a cascade — only those with a mirrored index.

### 5. `placement-validate.sh` — exemption table (when relevant)

`skills/librarian/capabilities/placement-validate.sh` keeps a whitelist of files that don't fit the per-type frontmatter contract (e.g., `_index.md`, `File-Index.md`, `CLAUDE.md`, `README.md`). If your new type carries an exemption (it's a routing index, not enumerated content), add it to the whitelist.

**Edit:** add the path-pattern or filename to the appropriate whitelist section in `placement-validate.sh`. Most new types do NOT need this — default-enforced behavior is what you want for content files.

---

## Worked example: adding `interview-note`

You decide to add `interview-note` for transcripts of stakeholder interviews under `Interviews/<topic>/<date>.md`.

**Step 1 — vault-schema.json:**

```bash
jq '.types += [{
  name: "interview-note",
  required_fields: ["type", "subject", "interviewer", "tags", "updated"],
  optional_fields: ["transcript_link", "outcome"],
  path_pattern: "^Interviews/[^/]+/[^/]+\\.md$"
}]' ~/.claude/schemas/vault-schema.json > /tmp/vs.json && \
  mv /tmp/vs.json ~/.claude/schemas/vault-schema.json
```

**Step 2 — frontmatter-enforce.sh `detect_type()`:**

Add (after the "people" branch, before "prd"):

```python
if re.match(rf"^Interviews/[^/]+/[^/]+\.md$", rel):
    return "interview-note"
```

(Use `{PD}` instead of a hardcoded literal if your folder name is parameterized via `vault.projects_root_dirname`. Plain `Interviews` is fine when the folder is universal across users.)

Also extend the `REQUIRED` table:

```python
REQUIRED = {
    ...
    "interview-note": ["type", "subject", "interviewer", "tags", "updated"],
}
```

**Step 3 — vault CLAUDE.md (via manifest):**

```bash
jq '.vault.canonical_file_types += ["interview-note"] | .vault.canonical_file_types |= unique' \
  ~/.claude/user-manifest.json > /tmp/um.json && \
  mv /tmp/um.json ~/.claude/user-manifest.json
# Then re-run /onboard --section c to regenerate vault CLAUDE.md (or hand-edit).
```

**Step 4 — doc-dependencies.json (only if you maintain an `_index.md` listing interviews):**

```bash
jq '.entries += [{
  id: "interview-list",
  kind: "directory-mirror",
  primary_dir: "Interviews/",
  mirrors: [{file: "Interviews/_index.md", section: "(whole)"}]
}]' ~/.claude/hooks/config/doc-dependencies.json > /tmp/dd.json && \
  mv /tmp/dd.json ~/.claude/hooks/config/doc-dependencies.json
```

**Step 5 — placement-validate.sh:** typically no edit needed for content types. Skip unless `interview-note` files should be exempt from per-type frontmatter (which they should not — they have a strict required-field set per Step 1).

---

## Quick checklist

When adding a new vault file type:

- [ ] **vault-schema.json** — new entry under `.types[]` with required + optional fields + path_pattern
- [ ] **frontmatter-enforce.sh** — new `detect_type()` branch + `REQUIRED[type]` entry
- [ ] **vault CLAUDE.md** — type listed under "Canonical file types" (via manifest regen OR hand-edit)
- [ ] **doc-dependencies.json** — cascade entry if the new type's folder is enumerated in an index file
- [ ] **placement-validate.sh** — whitelist entry only if the new type is itself a routing index (rare)

Land all five in one commit. Re-run `/architect` (any mode) afterwards to confirm the drift detector reports zero new findings.

---

## Related

- [personalization-model.md](personalization-model.md) — universal/combined/personal classification of every file mentioned above.
- [doc-dependencies-conventions.md](doc-dependencies-conventions.md) — cascade entry shape (Step 4).
- [provenance-frontmatter.md](provenance-frontmatter.md) — provenance contract for hand-edits (Step 3 fallback path).
- `skills/librarian/SKILL.md` — the drift detector capability; what surfaces post-commit if any of the five didn't land.
