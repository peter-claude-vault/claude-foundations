# Adding a New Vault File Type

> **Summary:** Step-by-step procedure for adding a new canonical file type to the foundation governance layer. Covers the 5-surface R-37 atomic lockstep that must land in one commit. **Canonical for:** canonical §A pillar #6 (`governance/file-type-contracts/`), canonical §C vault-root mandates, canonical §B bundle-at-load, canonical §A meta-rule R-37. **Last substantive update:** 2026-05-15 (SP13 Session 8 E-2 — rewrite from dissolved-schema architecture to canonical 6-pillar shape).

When you add a new canonical file type to your vault — for example, `interview-note` alongside `meeting-note`, `people`, `daily-note` — the change must land in lockstep across **five surfaces** in a single commit. Anything less is documented drift that the governance parity audit will surface.

**Audience:** adopters extending the foundation type system with a new file type.

---

## Why five surfaces, why one commit

The five surfaces are wired together by the foundation governance layer. They are NOT optional: the type does not exist as far as write-time enforcement is concerned unless every surface knows about it. The canonical source of truth at write-time is `governance/foundation-master.json` (the composed bundle per canonical §B); the authoring sources are the individual pillar JSONs that compose into it.

Half-landed lockstep changes are the most expensive failure mode:

| Surface that landed | Surface that didn't | Symptom |
|---|---|---|
| `frontmatter-rules.json#types` only | no `file-type-contracts/<type>.json` | Type is accepted at write-time but body-structure is unenforced — no contract to validate against. |
| `file-type-contracts/<type>.json` only | not in `frontmatter-rules.json#types` | Contract exists but type is not in the R-32 allowlist; writes are denied before the contract is ever checked. |
| Both governance pillars | not in scaffold spoke | Every new adopter vault is seeded without documentation for the type. Governance parity audit fires a gap finding. |
| All three above | not in `_index.json` r37_coupled_surfaces | R-37 lockstep coupling is undeclared; the pre-commit hook cannot verify the commit was atomic. |
| All four above | bundle not rebuilt | Hooks enforce the old bundle state; new type is invisible to write-time enforcement until next bundle rebuild. |

The lockstep target set for every type addition is declared at `governance/_index.json#pillars.file-type-contracts.r37_coupled_surfaces` (per canonical §A meta-rule R-37).

---

## The 5 surfaces (in commit order)

### 1. `governance/file-type-contracts/<type>.json` — body-structure contract

Per canonical §A pillar #6, every recognized vault file type has a body-structure contract under `governance/file-type-contracts/`. The contract declares required frontmatter fields, optional fields, and body-structure constraints (section headings, max line count, sentinel patterns). Pattern: k8s ValidatingAdmissionPolicy `paramKind`.

**New file:** `governance/file-type-contracts/<type-name>.json`

Minimum shape:
```json
{
  "type": "interview-note",
  "frontmatter_required": ["type", "subject", "interviewer", "tags", "updated"],
  "frontmatter_optional": ["transcript_link", "outcome"],
  "body_structure": {
    "required_sections": ["## Summary", "## Key takeaways"],
    "max_line_count": 300
  },
  "consumers": [
    {"hook": "pre-write-guard.sh", "enforcement": "type-allowlist + body-structure"},
    {"hook": "post-write-verify.sh", "enforcement": "required-fields presence"}
  ]
}
```

Model the shape on `governance/file-type-contracts/_index.md.json` (the reference implementation).

### 2. `governance/frontmatter-rules.json#types.<type>` — type registry entry

Per canonical §A pillar #1, `governance/frontmatter-rules.json` is the type registry. The `types` object carries one entry per recognized type, declaring required fields, tier assignment, and archetype conditional fields.

**Edit:** add an entry under `types` in `governance/frontmatter-rules.json`:
```json
"interview-note": {
  "required_fields": ["type", "subject", "interviewer", "tags", "updated"],
  "optional_fields": ["transcript_link", "outcome"],
  "tier": 2,
  "archetype_conditional": {}
}
```

If the new type has path-routing guidance (e.g., it belongs under `Interviews/`), also add a `path_routing.rules[]` entry declaring the `advisory_pattern`.

### 3. `governance/mandatory-files-rules.json#mandates` — vault-root presence mandate (conditional)

**Only needed when the new type is a vault-root mandatory file.** Per canonical §C, vault-root mandatory files are: `CLAUDE.md`, `System Backlog.md`, `System Governance.md`, `_index.md`. For content types like `interview-note`, **skip this surface**.

If your new type IS a vault-root mandatory, add a mandate entry under `mandates` in `governance/mandatory-files-rules.json`.

### 4. `onboarding/scaffold/vault-architecture/System Governance - File-Type-Contracts.md` — spoke entry

Per canonical §D, the `System Governance/` folder carries 6 narrative spokes — one per governance pillar. The File-Type-Contracts spoke is the user-facing description of all recognized file-type contracts. It is seeded into every new adopter vault by the onboarding wizard.

**Edit:** add an entry to the spoke doc describing the new type's body-structure contract: its purpose, required fields, and contract JSON path.

### 5. `governance/_index.json#pillars.file-type-contracts.r37_coupled_surfaces` — lockstep coupling declaration

Per canonical §A meta-rule R-37, every pillar declares its `r37_coupled_surfaces` — the exact set of surfaces that must land atomically when the pillar changes.

**Edit:** append the new contract file path to `pillars.file-type-contracts.r37_coupled_surfaces[]` in `governance/_index.json`.

---

## Bundle rebuild (required after every pillar edit)

After all five surface edits land in git, rebuild the bundle:

```bash
cd ~/Code/claude-stem
bash tools/build-foundation-master.sh
```

Per canonical §B, `governance/foundation-master.json` is composed at foundation-repo release time and shipped as an immutable artifact to adopter `~/.claude/governance/foundation-master.json`. Adopters never build the bundle — `install.sh` ships the composed artifact. The rebuild here is the foundation-repo authoring step.

Include the rebuilt `governance/foundation-master.json` in the same commit as the pillar edits.

---

## Worked example: adding `interview-note`

You decide to add `interview-note` for stakeholder interview transcripts under `Interviews/<date>-<topic>.md`.

**Surface 1 — new file `governance/file-type-contracts/interview-note.json`:**
```json
{
  "type": "interview-note",
  "frontmatter_required": ["type", "subject", "interviewer", "tags", "updated"],
  "frontmatter_optional": ["transcript_link", "outcome"],
  "body_structure": {
    "required_sections": ["## Summary", "## Key takeaways"],
    "max_line_count": 300
  },
  "consumers": [
    {"hook": "pre-write-guard.sh", "enforcement": "type-allowlist + body-structure"},
    {"hook": "post-write-verify.sh", "enforcement": "required-fields presence"}
  ]
}
```

**Surface 2 — `governance/frontmatter-rules.json#types.interview-note`:**
```json
"interview-note": {
  "required_fields": ["type", "subject", "interviewer", "tags", "updated"],
  "optional_fields": ["transcript_link", "outcome"],
  "tier": 2,
  "archetype_conditional": {}
}
```
Also add to `path_routing.rules[]`:
```json
{"type": "interview-note", "advisory_pattern": "^Interviews/[^/]+\\.md$"}
```

**Surface 3 — `governance/mandatory-files-rules.json`:** skip. `interview-note` is not a vault-root mandatory per canonical §C.

**Surface 4 — `System Governance - File-Type-Contracts.md`:**
Add a row to the file-type contracts table:
```markdown
| `interview-note` | `governance/file-type-contracts/interview-note.json` | Transcripts of stakeholder interviews. Required: subject, interviewer, tags, updated. |
```

**Surface 5 — `governance/_index.json#pillars.file-type-contracts.r37_coupled_surfaces`:**
Append `"governance/file-type-contracts/interview-note.json"` to the array.

**Bundle rebuild:**
```bash
bash tools/build-foundation-master.sh
```
Verify `governance/foundation-master.json#file_type_contracts.interview-note` is present in the rebuilt bundle.

---

## Quick checklist

Land all five in one commit:

- [ ] **`governance/file-type-contracts/<type>.json`** — new body-structure contract (required sections, max line count, frontmatter fields)
- [ ] **`governance/frontmatter-rules.json#types.<type>`** — type registry entry + optional path_routing.rules[] entry
- [ ] **`governance/mandatory-files-rules.json#mandates`** — presence mandate (vault-root mandatory only; skip for content types)
- [ ] **`onboarding/scaffold/vault-architecture/System Governance - File-Type-Contracts.md`** — spoke narrative entry
- [ ] **`governance/_index.json#pillars.file-type-contracts.r37_coupled_surfaces`** — lockstep coupling declaration
- [ ] **Bundle rebuild** — run `tools/build-foundation-master.sh`; include rebuilt `governance/foundation-master.json` in commit

After commit: re-run `/architect` (governance-parity-audit mode) to confirm zero new gap findings for the new type.

---

## Related

- [doc-dependencies-conventions.md](doc-dependencies-conventions.md) — cascade entries when the new type's folder is enumerated in an index file.
- [provenance-frontmatter.md](provenance-frontmatter.md) — provenance contract for auto-authored files.
- `governance/file-type-contracts/_index.md.json` — reference implementation of an existing file-type contract.
- `governance/_index.json` — pillar registry with R-37 coupled-surfaces declarations.
- `tools/build-foundation-master.sh` — bundle composition script.
