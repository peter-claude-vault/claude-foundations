---
type: preamble-block
block: 2
of: 5
mode: personalized-output
parent_skill: onboarder
parent_plan: 81-claude-stem-dogfood-optimization
sub_plan: 02-foundation-framing
flow_step: 1
canonical_source: research/vault-construction/mental-model.md
---

# Block 2 — The architecture

Here is what that house actually looks like.

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

Three layers in directional relationship.

**The Experience layer** is the onboarder you are running right now. It configures your system and teaches you to use it. After onboarding, you will rarely interact with this layer — re-onboarding, major reconfigurations. The architecture beneath is what persists.

**The AI System Architecture** is the system. Four pillars:

- **CONNECTORS — Ingest.** Pulls structured and unstructured data from your real-world tools. Granola transcripts, Outlook calendar via EventKit, Teams + GChat scrapes, Gmail digests. Without connectors, you manually feed Claude every piece of context. Connectors close that loop.

- **PROCESSING — Structure.** Applies rules, frontmatter, tags, and routing decisions to incoming and existing content. PreToolUse hooks validate at write-time; the `/ingest` skill runs a three-action sequence (Understand → Process → Decompose-and-Route) for user-initiated routing; ENFORCEMENT-MAP rules and librarian capabilities catch drift. Standards without enforcement drift. Processing is what keeps the system coherent over time without manual maintenance.

- **MEMORY — Remember.** Persists user preferences, learned patterns, project context across sessions. Claude's own memory, optimized auto-memory under `~/.claude/projects/`, claude-mem cross-session DB. A system that does not remember you wastes tokens regathering context every conversation.

- **CONTENT — Organize.** Houses your knowledge base in retrievable, navigable form. Obsidian vault, archetype-appropriate folder structure, compliance-tiered frontmatter, faceted 8-dimension tagging, CLAUDE.md navigation guides, `_index.md` per folder. Claude is only as good as the context you give it. Content is where personalization lives.

A clarifier worth naming up front: tags and frontmatter LIVE in Content (they are vault-file metadata), but their enforcement LIVES in Processing. Data versus policy — Content is what exists; Processing is what guarantees it stays well-formed.

**Autonomous Orchestration + Multi-Session Coordination** is what the architecture enables. Verb: Act. `/backlog-research` plans, autonomous dispatch via cron, multi-session coordination, subagent teams, scheduled routines. Orchestration is not a fifth pillar — it is what the four pillars in concert make possible. Connectors give it data; Processing gives it structure; Memory gives it persistence; Content gives it knowledge. The endgame is Claude doing work for you when you are not watching.

## The directional verbs

Two arrows in the diagram, two relationships:

- **Experience builds out Architecture.** The onboarder is the configurator. Once configured, you do not need to keep configuring.
- **Architecture enables Orchestration.** Orchestration cannot meaningfully function without the four pillars in place. Build the architecture; orchestration becomes possible.

These are not optional sequencing — they are causal. You cannot run autonomous work on a half-built architecture, and you cannot half-configure the architecture and expect it to compose later.

---

## Anti-patterns surfaced inline

Five places where users commonly get the framing wrong. Naming them now so they do not stick:

| If you find yourself thinking… | The clearer framing is |
|---|---|
| "This is just a vault setup tool." | Vault is one of four pillars. Connectors, Processing, Memory work alongside it. The onboarder configures all four. |
| "Do I need to use all of this?" | You do not need Orchestration if autonomous work is not your goal yet. The four-pillar architecture is the substrate — opting out of pillars degrades the rest. |
| "Why does Claude need a memory layer if I have a vault?" | Vault is what Claude reads on demand. Memory is what Claude knows about you without reading. Different purposes. |
| "Is this Obsidian's system or Claude's?" | Claude's system, expressed largely through Obsidian as the Content-layer interface. Processing and Memory live in `~/.claude/`. Connectors live in skill scripts. Bigger than Obsidian. |
| "What if my work doesn't fit one of the archetypes?" | Archetype is a starting point. The scaffold gets generated from your actual files and answers — archetype just seeds the prompt with the right reference patterns. Multiple archetypes + personal tracks are supported. |

---

## Bridge to Block 3

That is the architecture. Next: two patterns you will see again and again across this onboarder, and across the system afterward. We name them now so you recognize them when they appear.

## Source

- Plan 81 SP02 spec.md §Block 2 (L103-107), §Three-layer mental model (L29-67)
- Plan 80 SP02 packet T8 §5 Block 2, §3 (canonical diagram + pillar table)
- Canonical: `research/vault-construction/mental-model.md` (this block renders that doc inline; mental-model.md is source-of-truth)
- Anti-patterns table: `research/vault-construction/mental-model.md` §Anti-patterns; canonical-authored at `skills/onboarder/preamble/anti-patterns.md` (T-9)
