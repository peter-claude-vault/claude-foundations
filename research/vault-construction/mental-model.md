---
altitude: system
scope: Canonical three-layer mental model for Claude Stem — experience layer, AI system architecture (4 pillars), autonomous orchestration. Source for Vault Architecture.md copied to user vault root at scaffold execution.
validity_window: 2026-05-10..2026-11-10
source_dependencies:
  - Plan 81 SP02 spec (~/.claude-plans/81-claude-stem-dogfood-optimization/02-foundation-framing/spec.md)
  - Plan 80 master packet (~/Desktop/plan-80-packets/00-master.md §4)
  - Plan 80 SP02 source packet T8 (~/Desktop/plan-80-packets/02 - foundation-framing (PACKET).md §3)
  - Plan 80 SP03 source packet T4 (~/Desktop/plan-80-packets/03 - standards (PACKET).md §3.4 Vault Architecture.md mandate; §3.6 7-step flow)
  - Plan 71 v2.1.2 closed dogfood walkthrough (Finding 1 — product-definition)
  - feedback_propose_and_confirm_pattern, feedback_soft_mandate_pattern (memory)
last_reviewed: 2026-05-10
canonical_url: https://stem.peter.dev/research/vault-construction/mental-model/
url_stability: locked-from-2026-05-10
---

# Mental model — three layers, four pillars, one emergent capability

## Theme

Claude Stem is a personalized AI context system, not a vault tool. Three layers stand in directional relationship: an **Experience layer** (the onboarder) configures an **AI System Architecture** (four pillars: Connectors, Processing, Memory, Content), which in turn enables **Autonomous Orchestration + Multi-Session Coordination**. The mental model is established before any decisions, so adopters reason about pieces inside a coherent frame rather than as a list of disconnected configuration choices.

## Vision / approach

Onboarding teaches the system as a system. After onboarding, experience-layer interactions become rare; the architecture is what persists. Two named UX primitives — *propose-and-confirm* and *soft-mandate* — recur across every sub-plan and are surfaced explicitly so users recognize them as patterns rather than encountering each one as a fresh interaction. (A third primitive, *compliance tiers*, lives in standards-domain pedagogy and is owned by SP03/T4; it is referenced here, not defined.)

Pedagogy progresses concrete-then-technical: the house metaphor lands first as intuition, then the canonical diagram replaces metaphor with technical truth, then the named primitives pre-load pattern recognition for the remainder of the flow.

## The canonical three-layer diagram

```
  ┌──────────────────────────────────────────────────────────┐
  │             THE EXPERIENCE LAYER (the onboarder)         │
  │       Configures your system • Teaches you to use it     │
  └──────────────────────────────────────────────────────────┘
                               │
                               │ builds out
                               ↓
  ┌──────────────────────────────────────────────────────────┐
  │              THE AI SYSTEM ARCHITECTURE                  │
  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────┐   │
  │  │CONNECTORS│→│PROCESSING│→│  MEMORY  │→│  CONTENT   │   │
  │  │  Ingest  │ │ Structure│ │ Remember │ │  Organize  │   │
  │  └──────────┘ └──────────┘ └──────────┘ └────────────┘   │
  └──────────────────────────────────────────────────────────┘
                               │
                               │ enables
                               ↓
  ┌──────────────────────────────────────────────────────────┐
  │         AUTONOMOUS ORCHESTRATION                         │
  │         + MULTI-SESSION COORDINATION                     │
  │            Plans • subagents • parallel work             │
  └──────────────────────────────────────────────────────────┘
```

## The four pillars (architecture)

| Pillar | Verb | One-line | Concrete examples | Why it matters |
|---|---|---|---|---|
| CONNECTORS | Ingest | Pulls structured + unstructured data from your real-world tools | Granola transcripts, Outlook calendar via EventKit, Teams + GChat scrapes, Gmail digests | Without connectors, you manually feed Claude every piece of context. Connectors close that loop. |
| PROCESSING | Structure | Applies rules, frontmatter, tags, and routing decisions to incoming + existing content | PreToolUse hooks (R-32 frontmatter validation, R-47 advisory orphan detection), in-session ingestion routing via the `/ingest` skill (three-action sequence per SP05), the 6 governance pillars (frontmatter / tagging / naming / mandatory-files / doc-dependencies / file-type-contracts) consumed by hooks via the `foundation-master.json` bundle, librarian capabilities | Standards without enforcement drift. Processing is what keeps the system coherent over time without manual maintenance. |
| MEMORY | Remember | Persists user preferences, learned patterns, project context across sessions | Claude's own memory, optimized auto-memory in `~/.claude/projects/.../memory/`, claude-mem cross-session DB | A system that doesn't remember you wastes tokens regathering context every conversation. |
| CONTENT | Organize | Houses your knowledge base in retrievable, navigable form | Obsidian vault, archetype-appropriate folder structure, compliance-tiered frontmatter schemas, faceted 8-dimension tagging taxonomy, CLAUDE.md navigation guides, `_index.md` per folder | Claude is only as good as the context you give it. Content is where personalization lives. |

### Cross-pillar clarifier — data vs. policy

Tags and frontmatter LIVE in Content (they are vault-file metadata). Their enforcement LIVES in Processing (R-32 hooks validate at write-time, R-47 advisories surface drift). The Content/Processing distinction is data vs. policy: Content is what exists; Processing is what guarantees it stays well-formed.

## Orchestration — the emergent capability

| Pillar | Verb | One-line | Concrete examples | Why it matters |
|---|---|---|---|---|
| ORCHESTRATION | Act | Runs autonomous work using everything in the architecture | `/backlog-research` plans, autonomous dispatch via cron, multi-session coordination via R-42, subagent teams, scheduled routines | The endgame. The point of building the architecture is to enable Claude to do work for you when you are not watching. |

Orchestration is not a fifth pillar; it is what the four-pillar architecture enables. Connectors give it data; Processing gives it structure; Memory gives it persistence; Content gives it knowledge. Without all four, autonomous work has nothing reliable to act on.

## Directional relationships

- **Experience → Architecture (builds out).** The onboarder is the configurator. After onboarding, experience-layer interactions become rare (re-onboarding, major reconfiguration). The architecture is what persists.
- **Architecture → Orchestration (enables).** Orchestration cannot meaningfully function without the four pillars in place. It is the system in motion, not a separate add-on.

## The two named UX primitives (canonical pointer)

- **Propose-and-confirm.** The system does meaningful work proactively (auto-route, generate scaffold, infer answers) and presents the result for review, tweak, or accept. Iteration may have a finite runtime cap (T4 §3.6 step 6 specifies N=3 as a safety valve, not a violation of the pattern).
- **Soft-mandate.** Strong recommendation backed by research-rationale + frictionless skip path + honest framing of what skipping costs. Never gates on compliance. The skip path is COHERENT (it produces a working system) but may legitimately be DEGRADED in personalization quality vs. the primary path; the degradation is honestly framed up front.

Canonical definitions, when-applied tables, engineering contracts, and examples live in [`ux-primitives.md`](./ux-primitives.md). A third standards-domain primitive — *compliance tiers* — is owned by SP03/T4 and surfaced during standards-domain pedagogy; it is not defined here.

## Anti-patterns (mental-model layer)

These are recognition cues for confusion that recurs at the framing layer. Standards-domain anti-patterns (frontmatter-as-decoration, tags-duplicate-folders) live in T4 §7 and surface during T4-domain pedagogical moments.

| Anti-pattern | User confusion | Preempt with |
|---|---|---|
| "This is just a vault setup tool" | Conflates the Content pillar with the whole system | Vault is one of four pillars. Connectors, Processing, Memory work alongside it. The onboarder configures all four. |
| "Do I need to use all of this?" | Feels overwhelming; wants opt-out | You do not need Orchestration if autonomous work is not your goal yet. The four-pillar architecture is the substrate — opting out of pillars degrades the rest. |
| "Why does Claude need a memory layer if I have a vault?" | Conflates retrieval with stickiness | Vault is what Claude reads on demand. Memory is what Claude knows about you without reading. Different purposes. |
| "Is this Obsidian's system or Claude's?" | Boundary confusion | Claude's system, expressed largely through Obsidian as the Content-layer interface. Processing and Memory live in `~/.claude/`. Connectors live in skill scripts. Bigger than Obsidian. |
| "What if my work doesn't fit one of the archetypes?" | Worried about being forced into a wrong shape | Archetype is a starting point. The scaffold gets generated from your actual files and answers — archetype just seeds the prompt with the right reference patterns. Multiple archetypes + personal tracks are supported. |

## Articulation success criteria

After completing the preamble (step 1 of the 7-step onboarder flow per T4 §3.6), a novice user should be able to articulate, in their own words:

1. **Three layers** — experience configures, architecture is the system, orchestration is what emerges.
2. **Four pillars** — each pillar named, with at least one example.
3. **The "emerges" relationship** — orchestration depends on the four-pillar architecture; not a separate add-on.
4. **The two patterns** — what propose-and-confirm means; what soft-mandate means; recognize them when they appear.
5. **The consent contract** — the system writes live to disk with checkpoints; the GitHub backup repo is recovery insurance.
6. **The 7-step flow exists** — preamble is step 1, file-drop is step 2, scaffold execution is step 7.

These criteria are the dogfood test target for SP08's harness — a simulated novice user runs the preamble, and an evaluator scores articulation against the six criteria.

## Open questions

- **OQ-1 (resolved at SP02 T-10)** — Minimal harness scope set to smoke-test only (5 blocks render in sequence, consent gate fires, bridge clean). SP08 owns the full-harness scope.
- **OQ-2 (resolved at SP02 T-1)** — Canonical doc location confirmed at `foundation-repo/research/vault-construction/mental-model.md` per T4 §3.4 strong suggestion.
- **OQ-3 (deferred to SP06)** — Pedagogy interaction style (interactive click-through vs. one long read-through) — wizard restructure decides.
- **OQ-4 (resolved at SP02 T-3)** — House metaphor wording finalized in `skills/onboarder/preamble/block-1-house-metaphor.md`.

## Source pointers

- **Spec text** — Plan 81 SP02 spec.md §Three-layer mental model (L29-67), §Four pillars (L54-67), §UX primitives (L69-89), §Mental-model success criteria (L155-166).
- **Source packet** — Plan 80 SP02 packet T8 §3 (canonical mental model), §4 (UX primitives), §8 (articulation success criteria).
- **Master packet** — Plan 80 master §4.1-§4.12 cross-cutting principles; §4.1-§4.4 specifically anchor the three-layer model + four pillars + two UX primitives + compliance-tier referent.
- **T4 binding contracts** — SP03 packet §3.3 (research context packet schema, 6-criteria quality bar), §3.4 (Vault Architecture.md mandate at vault root), §3.6 (7-step onboarder flow contract).
- **Predecessor evidence** — Plan 71 v2.1.2 dogfood walkthrough Finding 1 (product-definition) and Finding 4 (system-completeness) are the two findings this mental-model document directly addresses.
- **Sibling docs** — [`ux-primitives.md`](./ux-primitives.md) for canonical primitive definitions; [`setup-directions/`](./setup-directions/) for soft-mandated pre-req setup.
