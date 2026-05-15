---
type: reference
description: Step 6 pedagogical moment — tag taxonomy + discipline walkthrough. Inline TL;DR + canonical-URL link + personalized output for the adopter's archetype.
provides:
  - tagging-walkthrough-pedagogy
updated: 2026-05-13
tags: ["#scope/reference"]
---

# Tag taxonomy + discipline walkthrough — step 6 pedagogical moment

## TL;DR (inline)

Tags are the user-side query surface — projection of structural file information into your vault's graph view, filter pane, and Map-of-Content patterns. They are NOT how Claude reasons about files; Claude routes on frontmatter fields. Both surfaces mirror each other under the folder-mirrors-tag invariant: a file under `Engagements/acme-corp/Projects/data-platform/` carries `engagement: acme-corp` + `project: data-platform` as fields AND `#engagement/acme-corp` + `#project/data-platform` as tags. The grammar is `#dimension/value` with lowercase kebab-case slugs. Six user-facing dimensions are capped at 25 total distinct values across them (R-50, working-memory cap from Forte/Dubois research). Two system-utility dimensions (`#log/*`, `#status/*`) are exempt from the cap; they're machine-emitted and governed by the log-subtype registry's near-match DENY discipline (R-05). Adding a new dimension is an R-37 lockstep change touching schema + rule registry + narrative spoke + hook in one commit.

**Anti-pattern callout.** Folksonomy drift — letting users tag freely. One ad-hoc tag invites the next; within months the vocabulary fragments across `meeting` / `meetings` / `meeting-notes`. The pre-write-guard's R-32-taxonomy DENY moves validation from periodic human review to real-time gating. Friction is intentional.

## URL — full canonical reference

→ `https://stem.peter.dev/research/vault-construction/tagging-strategy/`

The canonical packet covers the 8-dimension taxonomy, the five discipline rules with research basis, the system-utility exemption design, the folder-mirrors-tag invariant, per-archetype dimension renaming, and the orphan-detection contract.

## Personalized output (rendered inline during onboarding step 6)

The wizard renders the adopter's archetype-customized tag dimension table inline at this step. The render reads:

- `governance/tagging-rules.json#taxonomy.dimension_prefixes` for the foundation taxonomy (dissolved from schemas/vault-schema.json in SP13 T-4)
- The adopter's selected archetype's structural dimensions — **these are seed defaults; adopters customize via Layer 3 overlay per the archetypes-as-references principle**. Foundation seeds: consultant uses `#engagement/*` + `#project/*`; developer uses `#repo/*` + `#epic/*`; researcher uses `#topic/*` + `#study/*`; manager uses `#program/*` + `#initiative/*`. Adopter overlays may rename, extend, or retire these dimensions freely.
- Adopter Layer-3 overlay if present for custom-dimension extensions

Render format:

```
Your archetype: <archetype>
Your 8 tag dimensions (6 user-facing + 2 system-utility):

  User-facing (subject to 25-cap):
    <structural-1>   e.g., #<engagement-or-equivalent>/acme-corp
    <structural-2>   e.g., #<project-or-equivalent>/data-platform
    #scope/<value>   e.g., #scope/decision, #scope/action-item
    #initiative/<value>
    #artefact-bd/<value>   [optional; remove if not applicable]
    #about-me/<value>      [optional; remove if not applicable]

  System-utility (exempt from cap; canonical-value registry):
    #log/<subtype>   e.g., #log/session-close, #log/digest-run, #log/audit-report
    #status/<value>  e.g., #status/processed, #status/pending, #status/needs-review

25-cap budget: user-facing dimensions can carry a total of ~25 distinct values across them.
The librarian surfaces a consolidation prompt at ≥20 (80% of cap).
```

A single drill-down via `Show registered tags` exposes the full `governance/log-subtype-registry.json` canonical values for the system-utility dimensions, plus the dimension definitions from `governance/tagging-rules.json#taxonomy.dimension_prefixes`.

## Pedagogical rationale

The moment lands at step 6 alongside the frontmatter walkthrough because the two surfaces are coupled. Frontmatter fields are the Claude-side substrate; tags are the user-side surface; the invariant binds them. Surfacing both at the same step lets the adopter form one mental model of "what the system reads" vs "what I navigate by." The 25-cap framing is the load-bearing pedagogy here — adopters either internalize the cap as the design (working-memory constraint, working vocabulary discipline) or rebel against it as arbitrary; the cited research is what changes the frame.
