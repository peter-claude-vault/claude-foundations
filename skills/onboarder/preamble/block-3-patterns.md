---
type: preamble-block
block: 3
of: 5
mode: personalized-output
parent_skill: onboarder
parent_plan: 81-claude-stem-dogfood-optimization
sub_plan: 02-foundation-framing
flow_step: 1
canonical_source: research/vault-construction/ux-primitives.md
---

# Block 3 — The patterns you will see

Two interaction patterns appear over and over across this onboarder, and across the system you keep using afterward. We name them now so they are recognizable when they appear.

## Propose-and-confirm

The system does meaningful work proactively — auto-routes a file, generates a vault structure, infers an answer — and presents the result for you to review, tweak, or accept. You are never asked to provide answers from scratch when the system has enough signal to produce a quality first draft.

You will see this pattern in:

- **The file-drop step** (next), where Claude reviews the files you provide and pre-fills onboarding answers — you confirm or edit, you do not type from scratch.
- **The architecture proposal** later in the flow, where Claude presents a full vault structure with rationale — you accept, tweak, or regenerate. There is a safety cap: after three rounds of edit-and-re-propose, the system commits with your last accepted state and you keep iterating after onboarding via `/route` and manual edits. The cap exists so the loop cannot run forever.
- **The `/ingest` skill** any time you drop a new file into the system after onboarding — Claude proposes frontmatter, splits the file if useful, and routes to a destination folder, all reviewable per action.

## Soft-mandate

Strong recommendation, frictionless skip path, honest framing of what you give up by skipping. Never gates on compliance.

You will see this pattern in:

- **The pre-reqs in the next block** — Obsidian, the claude-mem plugin, a GitHub backup repo. Strongly recommended; you can skip; the skip path produces a working system but is honestly degraded in personalization quality and safety net.
- **The file-drop step** — heavily encouraged so Claude can pre-fill answers from your real work, but skip-to-questions is a real path that produces a coherent (slower, less personalized) onboarding.
- **The connector setup** later — recommended after you name the tools you use; you can defer per-tool without breaking anything.

The engineering contract: any skip path is COHERENT. Degraded does not mean broken. If a recommendation would force a broken or incomplete system on skip, it should be a hard requirement, not a soft mandate.

## A third pattern, surfaced later

A third pattern — *compliance tiers* — appears in standards-domain decisions later in the flow (around the schema and tagging conversations). We mention it now only so you are not surprised when it lands. Three tiers (Strict / Standard / Minimal) describe how strictly different file types are validated; the canonical definition surfaces when the standards step runs.

---

## Bridge to Block 4

You will see propose-and-confirm and soft-mandate everywhere. The next block is the first soft-mandate — three things we recommend you set up before this onboarder writes anything to your disk.

## Source

- Plan 81 SP02 spec.md §Block 3 (L109-113), §The two named UX primitives (L69-89)
- Plan 80 SP02 packet T8 §5 Block 3, §4
- Canonical: `research/vault-construction/ux-primitives.md` (this block renders pointer-summaries; ux-primitives.md is source-of-truth)
- Compliance-tier cross-reference: SP03 packet T4 §3.1 (third primitive, owned by standards domain)
- N=3 iteration cap: SP03 packet T4 §3.6 step 6
