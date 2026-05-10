---
type: preamble-callouts
parent_skill: onboarder
parent_plan: 81-claude-stem-dogfood-optimization
sub_plan: 02-foundation-framing
flow_step: 1
mode: personalized-output
surfaces_within: block-2-architecture
canonical_source: research/vault-construction/mental-model.md (anti-patterns table)
---

# Preamble anti-patterns (callouts)

Five framings users commonly land on that miss the actual architecture. We surface them inline during Block 2 so they do not stick. Each callout pairs the user-confusion framing with the corrective framing.

These are MENTAL-MODEL-layer anti-patterns. Standards-domain anti-patterns (frontmatter-as-decoration, tags-duplicate-folders) live in T4 §7 and surface during T4-domain pedagogical moments (steps 3 + 6).

---

## A1. "This is just a vault setup tool"

**User confusion.** Conflates the Content pillar with the whole system. Treats the whole system as a more elaborate Obsidian configuration helper.

**Preempt with.** Vault is one of four pillars. Connectors, Processing, Memory work alongside it. The onboarder configures all four. The vault is what you see; it is not what the system is.

**Where it surfaces.** Block 2, after the four-pillar walk. The risk is the user sees "Content = Obsidian vault" and stops listening.

---

## A2. "Do I need to use all of this?"

**User confusion.** Feels overwhelming; wants opt-out from parts of the architecture that look complex.

**Preempt with.** You do not need Orchestration if autonomous work is not your goal yet. The four-pillar architecture is the substrate — opting out of pillars degrades the rest. Opting out of *Orchestration* is a deferral; opting out of a *pillar* is a degradation.

**Where it surfaces.** Block 2, after the directional verbs explanation. The risk is the user collapses "I do not need autonomous work yet" into "I do not need this whole system."

---

## A3. "Why does Claude need a memory layer if I have a vault?"

**User confusion.** Conflates retrieval (Content) with stickiness (Memory). Assumes anything Claude could need is in the vault and Memory is therefore redundant.

**Preempt with.** Vault is what Claude reads on demand. Memory is what Claude knows about you without reading. They serve different purposes — Content is the corpus; Memory is the model of who you are. A system that can read the corpus but does not know your preferences treats every conversation as a cold start.

**Where it surfaces.** Block 2, when the MEMORY pillar is walked. The risk is the user dismisses the claude-mem soft-mandate in Block 4 because they think the vault makes it redundant.

---

## A4. "Is this Obsidian's system or Claude's?"

**User confusion.** Boundary confusion. Sees Obsidian as the visible interface and assumes the system is somehow built around Obsidian rather than Claude.

**Preempt with.** Claude's system, expressed largely through Obsidian as the Content-layer interface. Processing and Memory live in `~/.claude/`. Connectors live in skill scripts. Bigger than Obsidian. Obsidian is the *access surface* for one of four pillars; the system would survive a switch to a different markdown editor (with degradation), and would not survive a switch away from Claude.

**Where it surfaces.** Block 2, after the Content pillar walk. Also relevant in Block 4 where Obsidian is named as the first pre-req — the framing prevents the user from thinking the pre-req is Obsidian's choice rather than the system's.

---

## A5. "What if my work doesn't fit one of the archetypes?"

**User confusion.** Worried about being forced into a wrong shape. Reads "consultant / researcher / developer / manager" as exhaustive categories and panics about edge cases.

**Preempt with.** Archetype is a starting point. The scaffold gets generated from your actual files and answers — archetype just seeds the prompt with the right reference patterns. Multiple archetypes (consultant + researcher; developer + manager) are supported. Personal tracks (Personal Initiatives, BD, MBA prep, side research) layer on top. The archetype does not constrain you; it primes Claude with relevant practitioner research.

**Where it surfaces.** Block 5, when the next 6 steps are previewed. The risk is the user pre-emptively refuses the file drop because they think their work will not classify cleanly.

---

## Surfacing guidance for SP06

These callouts render *inline* within Block 2 — collapsed by default into a "common framings to watch for" affordance, expandable to the full table. The cost of surfacing them all by default is preamble length; the cost of hiding them entirely is the framings persisting silently. The collapsed default + click-to-expand is the compromise.

A5 is the exception — it surfaces in Block 5 (file-drop bridge) rather than Block 2, because that is the moment the archetype framing first becomes operative.

## Source

- Plan 81 SP02 spec.md §Anti-patterns table (L143-153)
- Plan 80 SP02 packet T8 §7
- Canonical: `research/vault-construction/mental-model.md` §Anti-patterns (this file is the preamble-rendered version of that table; mental-model.md is the source-of-truth for the framings themselves)
- T4 anti-patterns (separate, standards-domain): SP03 packet §7
