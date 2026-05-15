---
type: reference
description: Step 6 pedagogical moment — frontmatter walkthrough. Inline TL;DR + canonical-URL link + personalized output for the adopter's vault.
provides:
  - frontmatter-walkthrough-pedagogy
updated: 2026-05-13
tags: ["#scope/reference"]
---

# Frontmatter walkthrough — step 6 pedagogical moment

## TL;DR (inline)

Every vault file exposes a YAML frontmatter block as its first lines. That block is the API the system reads — hooks, the librarian, capture pipelines, and routing skills all branch on field values. Three compliance tiers govern the contract: **Strict** (system-emitted files like meeting notes; required fields enforced at write-time via R-32 DENY), **Standard** (user-authored content; required fields produce a soft warning that the librarian surfaces at session-close), **Minimal** (explicit opt-out for legacy imports). Three universal fields apply to every Strict-tier file: `type:` (one of the canonical types), `tags:` (the hierarchical `#dimension/value` array), `updated:` (auto-touched on every edit). Per-type fields layer on top — meeting notes carry `attendees:` + `processed:`; PRDs carry `engagement:` + `project:` + `owner:` + `status:`; packets carry `altitude:` + `validity_window:` + `last_reviewed:`. The contract is enforced at write-time because the alternative — "we'll add frontmatter later" — empirically does not return.

**Anti-pattern callout.** Treating frontmatter as decoration. Stripping the frontmatter and the file becomes opaque to the system: routing fails, lifecycle staleness can't fire, agent context is gone. The fields are the API, not metadata.

## URL — full canonical reference

→ `https://stem.peter.dev/research/vault-construction/frontmatter-design/`

The canonical packet covers the five structural commitments, the unified-with-per-archetype-entries extensibility model, the folder-lineage convention, the system-utility dimension exemption, and the R-37 atomic-lockstep protocol that holds the schema + rule registry + narrative spoke + hook aligned.

## Personalized output (rendered inline during onboarding step 6)

The wizard renders the adopter's archetype-customized frontmatter table inline at this step. The render reads:

- `governance/foundation-master.json#frontmatter.types` for the type allowlist + per-type required/optional field maps (dissolved from schemas/vault-schema.json in SP13 T-4)
- `governance/frontmatter-rules.json#archetype_conditional_fields` for the per-archetype field set
- Adopter Layer-3 overlay-master (if present) for adopter-customized field declarations

Render format:

```
Your adopter archetype: <archetype>
Your required-fields table (top 6 types you'll write most):

  meeting-note    type, date, meeting_title, attendees, tags, processed, updated
  daily-note      type, date, day, processed, tags, updated
  people          type, name, org, role, <archetype-lineage-field>, tags, updated
  prd             type, title, <archetype-lineage-field>, <archetype-project-field>, status, owner, tags, updated
  context         type, <archetype-lineage-field>, <archetype-project-field>, owner, status, provides, tags, updated
  reference       type, provides, tags, updated

Where <archetype-lineage-field> is "<engagement|topic|repo|program>"
and <archetype-project-field> is "<project|study|epic|initiative>"
per your selected archetype.
```

The full table (all 21 type entries) is one keystroke away via `Show full schema`. The wizard surfaces the 6 most-used types inline so the adopter can recognize the shape without scanning a 21-row table; the rest is a single drill-down.

## Pedagogical rationale

The moment lands at step 6 because steps 1-5 establish the archetype + folder structure + initial files; step 6 is where the adopter first sees the contract that will gate every future write. Surfacing it BEFORE step 7's first scaffold-write is structural — the adopter needs to recognize the frontmatter pattern before encountering the R-32 DENY message on their first non-conforming write.

The TL;DR runs ≤200 words so the inline read cost is bounded. The canonical-URL link provides the depth path for adopters who want the full rationale; the personalized-output render makes the contract concrete by binding it to the adopter's chosen archetype rather than the generic foundation example.
