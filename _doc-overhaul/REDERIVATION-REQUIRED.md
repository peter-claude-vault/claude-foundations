# REDERIVATION-REQUIRED — _doc-overhaul/drafts/docs/*

**Status:** BLOCKED — do not merge `_doc-overhaul/drafts/docs/` content into production docs until re-derivation is complete.

**Created:** 2026-05-16 (SP13 Session 9 J-16)

---

## The problem

`_doc-overhaul/drafts/docs/` contains documentation drafted against the OLD governance architecture, which referenced `vault-schema.json` as the central schema for vault frontmatter, types, and tag prefixes. As of SP13 Session 5–9, `vault-schema.json` is **dissolved** and its concerns are distributed across the canonical 6-pillar governance set:

| Old reference | Canonical successor |
|---|---|
| `vault-schema.json#types[]` | `governance/frontmatter-rules.json#types` |
| `vault-schema.json._tag_prefixes` | `governance/tagging-rules.json#taxonomy.dimension_prefixes` |
| `vault-schema.json` (runtime read) | `governance/foundation-master.json` (composed bundle) |

**Remaining `vault-schema.json` references in `_doc-overhaul/drafts/`:** ~39 occurrences across 17 files (as of 2026-05-16). The `_doc-overhaul/drafts/skills/librarian/SKILL.md` has already been migrated (J-15). The remaining hits are concentrated in `docs/adding-a-vault-file-type.md` (8 refs), `onboarding/SKILL.md` (5 refs), `schemas/README.md` (4 refs), and scattered across other draft files.

---

## Why mechanical migration is insufficient

The `_doc-overhaul/drafts/docs/` files were authored in context of the OLD architecture where:
- One flat `vault-schema.json` contained all types + tags + path rules
- Types were added by appending a key
- The schema was "one of three sanctioned schemas" validated at install time

The NEW architecture (per `foundation-governance-target-state.md`) is structurally different:
- Type registry lives in `frontmatter-rules.json` (pillar 1)
- Tag taxonomy lives in `tagging-rules.json` (pillar 2)
- Both are composed into `foundation-master.json` (the bundle) at release time
- Adopters extend via `overlay-master.json` (6-pillar parallel), not by editing schema files
- The sanctioned-schema-drift-detect capability checks `foundation-master.json`, not `vault-schema.json`

Simply replacing string occurrences would produce technically-correct text but architecturally incoherent documentation (e.g., "adding a vault file type" walkthrough would need to reflect the R-37 lockstep across frontmatter-rules.json + tagging-rules.json + foundation-master.json rebuild + overlay-master shape update — a fundamentally different 5-surface flow).

---

## Required action

Each file in `_doc-overhaul/drafts/docs/` that references `vault-schema.json` must be **re-authored from first principles** against `foundation-governance-target-state.md` rather than mechanically migrated. The re-derivation source is:

**`~/.claude-plans/81-claude-stem-dogfood-optimization/13-post-onboarding-governance-architecture/context-packets/foundation-governance-target-state.md`** — canonical reference for §A (6-pillar set), §B (bundle), §C (mandatory files), §D (6-spoke), §E (_index.md), §F (system folders), §G (retired items), §H (overlay-master).

---

## Files requiring re-derivation

| File | vault-schema refs | Notes |
|---|---|---|
| `drafts/docs/adding-a-vault-file-type.md` | 8 | Full re-derivation — the 5-surface commit pattern has changed substantially |
| `drafts/onboarding/SKILL.md` | 5 | Re-derive onboarder SKILL.md against current onboarding architecture |
| `drafts/schemas/README.md` | 4 | Re-derive schema README against 6-pillar set; drop vault-schema.json from schema table |
| `drafts/onboarding/onboarder-design.md` | 3 | Re-derive onboarder design doc |
| `drafts/onboarding/README.md` | 2 | Re-derive README |
| `drafts/hooks/RULES.md` | 2 | Re-derive RULES.md against current R-rule set (post-vault-schema dissolution) |
| `drafts/docs/personalization-model.md` | 2 | Light re-derive; the production version has been patched (J-2) |
| `drafts/docs/doc-dependencies-conventions.md` | 2 | Light re-derive |
| `drafts/skills/inbox-processor/SKILL.md` | 2 | Re-derive inbox-processor SKILL.md |
| `drafts/skills/backlog-hygiene/SKILL.md` | 2 | Re-derive |
| `drafts/skills/backlog-research/SKILL.md` | 1 | Light re-derive |
| `drafts/skills/backlog-triage/SKILL.md` | 1 | Light re-derive |
| `drafts/skills/architect/SKILL.md` | 1 | Light re-derive |
| `drafts/docs/what-runs-on-your-machine.md` | 1 | Light re-derive |
| `drafts/templates/vault-claude-md-template.md` | 1 | Re-derive; production template already patched |
| `drafts/templates/claude-home-claude-md-template.md` | 1 | Re-derive |
| `drafts/tests/foundation/architect-fixtures/README.md` | 1 | Light re-derive |

**Note:** `drafts/skills/librarian/SKILL.md` has already been migrated (SP13 Session 9 J-15, 2026-05-16).

---

## Next steps

1. Schedule a dedicated re-derivation session for `_doc-overhaul/drafts/docs/` content.
2. Start with `adding-a-vault-file-type.md` (8 refs, most architecturally load-bearing).
3. For each file: read `foundation-governance-target-state.md` first, then re-author from scratch — do not patch from the old draft.
4. Production docs that have already been directly patched (personalization-model.md, installer.md, adopt.md, glossary.md, vault-claude-md-template.md) can serve as reference for tone and structure.
5. Remove this file when all 17 draft files have been re-derived and reviewed.
