---
title: Provenance Frontmatter Contract
audience: capability authors, contributors
status: shipped
schema: schemas/provenance-frontmatter-schema.json
helpers: lib/provenance-frontmatter.sh
---

# Provenance Frontmatter

Every artifact written by an auto-authoring surface — the seven personalization surfaces produced at onboarding time — MUST carry a YAML frontmatter block at the top of the file declaring how the artifact was produced and whether the user has touched it since. The contract is small (three required fields, two optional lineage fields) and deliberately structural — it lets downstream capabilities decide whether to regenerate, preserve, or merge an artifact without round-tripping the user.

## Why this exists

The differentiator is auto-authored personalized config. The onboarder writes seven artifacts on the user's behalf. After installation, the user edits some of those artifacts. Manifest changes later force a re-run of one or more surfaces.

Without provenance, a re-run cannot answer:

- Did the previous generator already write this file? Or did the user write it manually?
- Has the user edited the file since the last generator run?
- Is it safe to silently overwrite, or must we surface a regen-diff?

Provenance frontmatter answers all three with a single read.

## Required fields

| Field | Type | Purpose |
|---|---|---|
| `generated_by` | string | Surface generator + version (`onboarder@v2.0.0-pre`, e.g. `surface-5-memory-seed`). Identifies which surface owns the file. |
| `generated_from` | string | Source the generator consumed: a Q-ID (`A-CB-7`), a section ID (`section-a`), or a free-form hint (`manual-template`). Lets regen flows detect when the source has changed. |
| `last_user_edit` | ISO-8601 string OR null | Timestamp of the most recent user edit. `null` means the artifact is in its as-generated state. Capabilities MUST preserve user edits when this timestamp is newer than the generator timestamp. |

## Optional lineage fields

Used when one surface upgrades an earlier surface's artifact in place (the bootstrap-then-enrich memory-seed upgrade is the canonical case):

| Field | Type | Purpose |
|---|---|---|
| `superseded_by` | string | The upgrading surface ID. The original `generated_by` stays for lineage; this field tells downstream readers a newer generator has taken over. |
| `original_sha256` | 64-char hex | SHA-256 of the original artifact bytes before the upgrade. Lets an auditor verify the upgrade replaced what it claimed to replace. |

## Worked example

A claude-home `CLAUDE.md` freshly produced by the composed-prose surface:

```yaml
---
generated_by: onboarder@v2.0.0-pre
generated_from: section-a-communication-style
last_user_edit: null
---

# Claude Code — Person Name

## Communication Style

- Firm and specific. No hedging.
...
```

After the user hand-edits the Communication Style section, the writer capability bumps `last_user_edit`:

```yaml
---
generated_by: onboarder@v2.0.0-pre
generated_from: section-a-communication-style
last_user_edit: "2026-05-04T13:22:08Z"
---
```

If a manifest change later triggers a regen of this surface, the regen flow sees `last_user_edit` is newer than the release timestamp and routes through a "review and merge" UX rather than silent rewrite.

## Regen vs preserve decision rule

A regen-capable capability reading an artifact MUST follow this decision tree:

1. No frontmatter present? → Treat as user-authored. NEVER overwrite without explicit user confirmation in the three-step gate preview.
2. Frontmatter present and `last_user_edit: null`? → Safe to silently regenerate (the artifact is still in its as-generated state).
3. Frontmatter present and `last_user_edit: <iso>` newer than the generator timestamp? → Surface a regen-diff in the three-step gate; user chooses apply / edit / skip / abort.
4. Frontmatter present with `superseded_by`? → The artifact is a lineage upgrade. Treat the `superseded_by` value as the authoritative current generator for regen decisions; the original `generated_by` is metadata.

The three-step gate (`onboarding/lib/three-step-gate.sh`) implements points 1 and 3 today; points 2 and 4 are consumer-side rules every surface MUST honor in its generator function.

## Helpers

`lib/provenance-frontmatter.sh` ships two emit helpers and one validator:

| Function | Use |
|---|---|
| `pf_emit <surface-id> <generated-from> [iso-or---null]` | Emit a fresh frontmatter block. Default `last_user_edit: null`. |
| `pf_emit_with_lineage <surface-id> <generated-from> <superseded-by> <original-sha256> [iso]` | Emit a frontmatter block carrying lineage fields for an in-place upgrade. |
| `pf_validate <yaml-file>` | Validate a frontmatter file (fenced or unfenced) against `schemas/provenance-frontmatter-schema.json`. Uses `ajv` when available; falls back to `jq` structural required-keys check. |
| `pf_extract <artifact-path>` | Extract the leading frontmatter block from an artifact file. |

Source the lib at the top of any surface generator script:

```bash
. "${FOUNDATION_REPO}/lib/provenance-frontmatter.sh"

pf_emit "onboarder@v2.0.0-pre" "section-a-communication-style" > "${TMP}/header.yml"
cat "${TMP}/header.yml" "${TMP}/body.md" > "${ARTIFACT}"
```

## Failure mode

`pf_validate` returns non-zero on any required-field violation. A surface generator that emits invalid frontmatter MUST fail loudly rather than shipping the artifact — a missing `generated_by` is a contract violation, not a soft warning.

## Where this is enforced

| Layer | Mechanism |
|---|---|
| Surface generator | Calls `pf_emit` directly; impossible to forget the contract. |
| Three-step gate | Records `sha_before` / `sha_after` per artifact write; the audit trail confirms which surface produced which file. |
| Cross-cutting smoke test | Validates every generated artifact against the schema in a fresh tmpdir run before release. |

## Related

- `onboarding/lib/three-step-gate.sh` — the gate every surface flows artifacts through; consumes provenance for sha-tracking.
- `schemas/provenance-frontmatter-schema.json` — the authoritative Draft-07 schema.
