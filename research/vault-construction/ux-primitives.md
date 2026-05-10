---
altitude: system
scope: Canonical definitions of the two named UX primitives in Claude Stem onboarding — propose-and-confirm and soft-mandate. Includes engineering contracts, runtime caps, and when-applied tables. Compliance-tier (third primitive) cross-referenced to SP03/T4.
validity_window: 2026-05-10..2026-11-10
source_dependencies:
  - Plan 81 SP02 spec (~/.claude-plans/81-claude-stem-dogfood-optimization/02-foundation-framing/spec.md §The two named UX primitives, L69-89)
  - Plan 80 SP02 source packet T8 (~/Desktop/plan-80-packets/02 - foundation-framing (PACKET).md §4)
  - Plan 80 SP03 source packet T4 (~/Desktop/plan-80-packets/03 - standards (PACKET).md §3.6 N=3 iteration cap; §3.1 compliance tiers)
  - Plan 80 SP05 source packet T5 (~/Desktop/plan-80-packets/05 - auto-routing-enforcement (PACKET).md /ingest three-action sequence)
  - feedback_propose_and_confirm_pattern (memory)
  - feedback_soft_mandate_pattern (memory)
last_reviewed: 2026-05-10
canonical_url: https://stem.peter.dev/research/vault-construction/ux-primitives/
url_stability: locked-from-2026-05-10
---

# UX primitives — propose-and-confirm and soft-mandate

## Theme

Two named UX primitives recur across every Plan 80 sub-plan that touches user interaction. Naming them up front, in onboarder preamble Block 3, pre-loads pattern recognition: when the user encounters the same shape in step 6 architecture review, in `/ingest` routing decisions, in connector setup, they recognize it rather than processing each instance as a fresh interaction. Both primitives also encode engineering discipline — propose-and-confirm forbids cold-start questions when signal exists; soft-mandate forbids hardening into a gate.

A third primitive — *compliance tiers* — is owned by SP03/T4 and surfaces during standards-domain pedagogy. It is referenced here, not defined here.

## Vision / approach

The primitives are not philosophy; they are contracts that consuming sub-plans must implement against. Propose-and-confirm is load-bearing for SP04 (scaffold review), SP05 (`/ingest` three-action sequence), SP06 (file-drop pre-fill), and SP07 (per-tool ideation briefs). Soft-mandate is load-bearing for SP02 pre-reqs, SP06 file-drop step, and SP07 connector recommendations. Naming makes them teachable to the user and auditable in implementation.

## Propose-and-confirm

**Definition.** The system does meaningful work proactively (auto-route, generate scaffold, infer answers) and presents the result for the user to review, tweak, or accept. The user is never asked to provide answers from scratch when the system has enough signal to produce a quality first draft.

**Engineering contract.**

- The system MUST attempt inference when signal exists. Cold-start questioning is rejected when signal is available — it represents a missed propose-and-confirm opportunity.
- Iteration may have a finite runtime cap for safety. Per T4 §3.6 step 6, **N=3 propose-edit-re-propose rounds**; after the third round, the system commits with the user's last accepted state. The cap is a safety valve against infinite loops, not a violation of the pattern.
- Post-cap, the user iterates further post-onboarding via `/route` and manual edits. The cap defers further work; it does not foreclose it.
- Each propose action MUST surface enough rationale for the user to evaluate (not "trust me" black-boxes).

**When applied.**

| Site | Mechanism | Sub-plan |
|---|---|---|
| File-drop step | Adversarial Opus review → pre-filled onboarding answers | SP06 |
| Generative scaffold | Vault structure + rationale (accept / tweak / regenerate, N=3 cap) | SP04 |
| User-initiated file ingestion via `/ingest` | Three-action sequence: Understand → Process → Decompose-and-Route. Frontmatter applied, file split where appropriate, multi-destination map proposed, folder(s) assigned. Review at each action. | SP05 |
| Connector setup wizard | Per-tool ideation briefs / plans (review and sign-off) | SP07 |

**Why named.** Load-bearing across SP04, SP05, SP06, SP07. Naming makes it teachable to the user and auditable in implementation. Auditors can ask: "where in this sub-plan does propose-and-confirm fire? what is its iteration cap? does it surface rationale?"

## Soft-mandate

**Definition.** Strong recommendation backed by research-rationale + frictionless skip path + honest framing of what skipping costs. Never gates on compliance.

**Engineering contract.**

- The skip path MUST be COHERENT — it produces a working system. Degraded ≠ broken.
- The degradation MUST be honestly framed up front, not hidden behind reassurance language.
- No conditional hard-mandate to dry-run on skip. Either it is a hard requirement (then make it a gate) or it is soft-mandated (then the skip path ships coherent output).
- Soft-mandate that hardens into a gate is a violation. SP02's pre-reqs must remain skippable; SP06's file-drop step must support a no-file branch; SP07's connector setup must allow per-tool deferral.

**Honest-degradation example (T4's no-file branch, canonical).** Per T4 §3.6: "Step 3 has no research input. Degraded path: minimal cold-start Q&A in step 4 (no pre-fill); Claude does practitioner-archetype research only after answers land. Slower, less personalized, coherent. Honest soft-mandate."

**When applied.**

| Site | Mechanism | Sub-plan |
|---|---|---|
| Pre-reqs (Obsidian, claude-mem, GitHub backup repo) | Recommended in preamble Block 4 with rationale + degradation framing | SP02 (gate OWNED), SP06 (RENDERS) |
| File-drop step | Heavily encouraged with rationale; skip-to-questions is the no-file variant (slower, less personalized, coherent) | SP06 |
| Connector setup | Recommended after tool naming; user can defer per-tool | SP07 |

**Why named.** Preserves user autonomy while honestly informing trade-offs. Forces engineering discipline — the skip path must be coherent. The degradation must be honest. Without naming, soft-mandates drift into either gates (loss of autonomy) or unframed recommendations (skip is a footgun).

## Compliance tiers (SP03/T4-owned, cross-reference)

A third standards-domain primitive — compliance tiers — surfaces during T4-domain pedagogical moments (steps 3 + 6 of the onboarder flow). Three tiers per T4 §3.1:

- **Strict** — system files (scaffold-emitted, `/ingest`-routed, scraper-aggregated). Hard fail at write-time (R-32 Tier 2 DENY).
- **Standard** — user-authored vault content. Soft warning; librarian flags drift.
- **Minimal** — explicit opt-out files. No validation; flagged "outside system."

Compliance tiers are not redefined here; the canonical source is SP03 packet §3.1. T8's preamble Block 3 mentions compliance tiers as a forthcoming primitive ("a third pattern, compliance tiers, appears in standards-domain decisions later") so users recognize the pattern when it lands; the definition lives in the standards domain.

## Surfacing modes (T4 §3.3 binding spec)

Both primitives, when surfaced inside the onboarder, render in **personalized-output mode** per T4 §3.3:
- Inline, in full, no URL deferral.

The sibling **static-research mode** (inline TL;DR ≤200 words + URL link to public GH Pages docs site) appears in T4-domain pedagogical moments (steps 3 + 6). UX primitives surface in personalized-output because they describe what is about to happen to *this user's* system, not background reference material.

## Anti-patterns (UX-primitive-layer)

| Anti-pattern | What goes wrong | Preempt with |
|---|---|---|
| Cold-start questioning when signal exists | Asks user to provide answer that pre-fill would have produced | Audit: where could inference have run? Treat the missed inference as the bug, not the question. |
| Silent commit past the iteration cap | User loses sense of agency; commit feels arbitrary | Surface the cap explicitly at iteration N+1: "We've made three rounds of changes — committing now and you can iterate further via `/route`." |
| Soft-mandate that gates on skip | "You can skip but then we cannot proceed" — that is a hard mandate | Either make the gate explicit, or ship a coherent skip path. The middle position is dishonest. |
| Skip path that is broken, not merely degraded | User skips, system silently emits incomplete output | Engineering review: does the skip path produce a working system? If not, it is a hard requirement disguised as a soft one. |
| Reassurance-language degradation | "You can skip and everything will work fine!" when in fact key personalization is lost | Frame the cost honestly. T4's "minimal cold-start Q&A; slower, less personalized, coherent" is the model. |

## Open questions

- None at primitive-definition layer. Implementation-layer open questions (specific iteration UI, rationale-surfacing detail) belong in consuming sub-plans (SP04, SP05, SP06, SP07).

## Source pointers

- **Spec text** — Plan 81 SP02 spec.md §The two named UX primitives (L69-89), §Surfacing modes (L91-93).
- **Source packet** — Plan 80 SP02 packet T8 §4 (Propose-and-confirm + Soft-mandate canonical definitions).
- **N=3 iteration cap** — Plan 80 SP03 packet T4 §3.6 step 6 ("Iteration cap on step 6. N=3 propose-edit-re-propose rounds before forcing commit").
- **Honest-degradation example** — Plan 80 SP03 packet T4 §3.6 no-file branch.
- **Compliance tiers (cross-ref)** — Plan 80 SP03 packet T4 §3.1.
- **Surfacing modes** — Plan 80 SP03 packet T4 §3.3 (two-mode binding spec for SP06).
- **/ingest three-action sequence** — Plan 80 SP05 packet T5 (in-session ingestion model; superseded the original "auto-routing on Inbox drops" framing at SP05 alignment 2026-05-06).
- **Sibling docs** — [`mental-model.md`](./mental-model.md) for the three-layer architecture context that primitives surface within.
