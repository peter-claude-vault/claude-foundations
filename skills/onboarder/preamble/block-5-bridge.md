---
type: preamble-block
block: 5
of: 5
mode: personalized-output
parent_skill: onboarder
parent_plan: 81-claude-stem-dogfood-optimization
sub_plan: 02-foundation-framing
flow_step: 1
hands_off_to: SP06 (file-drop step 2 of T4 §3.6 7-step flow)
---

# Block 5 — Bridge to file drop

You have completed step 1 of the 7-step onboarding flow.

Next: file drop — give us 5-10 reference files we can use to personalize the rest of the flow. Things like meeting notes, project briefs, status updates, anything that shows how you already work. The system reads them, infers your archetype, runs research on practitioners who work the way you do, and pre-fills the questions in step 4 so you confirm rather than answer cold.

You can skip the file drop. The skip path is coherent (we covered the soft-mandate framing in Block 3) — the trade-off is slower, less personalized, but a working system on the other side.

The next 6 steps:

| Step | What happens |
|---|---|
| 2 | File drop (or skip-to-questions) |
| 3 | Background research synthesis — archetype inference + practitioner research + pre-filled answers (2-5 min) |
| 4 | Onboarding Q&A — propose-and-confirm with pre-filled answers |
| 5 | Background re-synthesis — incorporates your refinements |
| 6 | Final vault architecture proposal — propose-and-confirm, N=3 iteration cap |
| 7 | Scaffold execution — your vault gets populated |

Steps 3 and 5 run in the background and may take a few minutes. Steps 2, 4, 6 are interactive. Step 7 is the moment your vault actually gets written.

## Bridge mechanic

Block 5 closes the seam between SP02 (preamble, step 1) and SP06 (file drop, step 2). The handoff is structural — SP06's wizard inherits the user's completed-step-1 state and begins step 2 without re-rendering preamble content.

## Source

- Plan 81 SP02 spec.md §Block 5 (L129-133)
- Plan 80 SP02 packet T8 §5 Block 5
- T4 §3.6 7-step flow contract (the 6-step table above is the binding sequence T4 owns; SP06 implements against it)
- Soft-mandate framing for file-drop skip: T4 §3.6 no-file branch + `ux-primitives.md` §Soft-mandate
