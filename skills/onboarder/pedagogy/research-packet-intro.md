---
type: reference
description: Step 6 pedagogical moment — research context packet introduction. Inline TL;DR + canonical-URL link + personalized output for the adopter's altitudes.
provides:
  - research-packet-intro-pedagogy
updated: 2026-05-12
tags: ["#scope/reference"]
---

# Research context packet introduction — step 6 pedagogical moment

## TL;DR (inline)

Research context packets are durable design artifacts — narrative explanations of WHY the system is the way it is, paired with structured frontmatter that drives lifecycle audits. Each packet declares an `altitude:` (system / engagement / topic / initiative); a `scope:` (1-3 sentence statement of what the packet covers); a `validity_window:` (ISO-date range during which the packet is authoritative); a `source_dependencies:` array (every claim back-links to evidence); a `last_reviewed:` date that drives the 180-day staleness audit. System-altitude packets live in foundation-repo `research/vault-construction/` and are surfaced at canonical URLs on the documentation site. Engagement / topic / initiative-altitude packets live in your vault with shorter validity windows (90 days for topic; lifecycle-driven for engagement / initiative). The packets are the substrate for Claude's read budget — they answer "where did this design come from" without forcing every adopter to re-derive the rationale.

**Anti-pattern callout.** Treating packets as inert documentation. The `last_reviewed:` field is auto-audited; packets without recent review surface as `packet-staleness-overdue` findings (warning) at 180 days. The validity window is not aspirational; the audit fires on every weekly cron run.

## URL — full canonical reference

→ `https://stem.peter.dev/research/vault-construction/`

The system-altitude packet set covers the construction principles, frontmatter design, tagging strategy, file-naming conventions, content-length limits, enforcement-map design, `_index.md` design, and inbox-flow architecture. Each carries the canonical six-field packet frontmatter and 6-criterion quality bar.

## Personalized output (rendered inline post-scaffold-acceptance)

After the wizard finishes step 6's scaffold acceptance, the adopter sees:

```
Your packet stack (rendered into your vault):

  System-altitude packets — installed at <vault-root>/Reference/foundation-packets/
  (READ-ONLY mirrors of foundation-repo research/vault-construction/*.
   Updated on foundation-repo upgrade via R-37 lockstep.)

  Engagement-altitude packets — author at <vault-root>/Engagements/<X>/Packets/
  (Optional; for engagements with substantial context worth durable framing)
  Required frontmatter: type: packet, altitude: engagement, scope, last_reviewed, tags, updated

  Topic-altitude packets — author at <vault-root>/Reference/topic-packets/<topic>/
  (Cross-engagement reference material that outlives any single engagement)
  Validity window default: 90 days; surfaces staleness at 75 days

  Initiative-altitude packets — author at <vault-root>/Personal Initiatives/<X>/Packets/
  (Project-lifecycle-scoped; closes at plan close)
```

The wizard offers a "Generate first engagement packet" follow-up that uses the adopter's archetype + chosen engagement to render a packet template ready for content authoring. Adopters who don't want engagement packets can skip — the foundation packet stack is the load-bearing reference; engagement / topic / initiative packets are optional adopter extensions.

## Pedagogical rationale

This moment lands AFTER the scaffold-acceptance step rather than alongside the frontmatter + tagging walkthroughs because it introduces a different read-budget model. Frontmatter is "the API every file exposes" (high-frequency); tags are "your query surface" (medium-frequency); packets are "where the design rationale lives" (low-frequency, deep-read). Surfacing the packet stack after the scaffold acceptance gives the adopter a complete mental model: the vault has files (frontmatter contract), navigation tools (tags), and depth references (packets). Without the packet introduction, adopters skim past the `last_reviewed:` discipline and packets rot silently within months. The 180-day cycle is named explicitly so the discipline is not a surprise when the librarian surfaces it.
