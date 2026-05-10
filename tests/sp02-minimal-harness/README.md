# SP02 minimal harness

Resolves SP02 OQ-1 (how minimal is "minimal"). Smoke-only. Hands off to SP08 for the full dogfood-harness scope.

## Run

```sh
bash ./preamble-smoke.sh
```

Exit 0 = green. Exit 1 = at least one assertion failed; failures print to stderr.

## What it validates

| AC | What it checks |
|----|----------------|
| AC1 | Smoke runs and returns a clean exit code. |
| AC2 | All 5 preamble blocks exist at canonical paths, declare `block: N of: 5 / flow_step: 1 / mode: personalized-output` in frontmatter, render in the fixture-declared sequence. Block 1 has the verbatim house-metaphor opening; Block 2 names all 4 pillars + both directional verbs; Block 3 names both UX primitives + cross-refs compliance tiers. |
| AC3 | Block 4 lists all 3 pre-reqs verbatim, carries the honest-degradation phrase, declares the render contract for SP06 (gate fires before disk write; skip path coherent), declares SP02 ownership / SP06 rendering, binds personalized-output mode. |
| AC4 | Block 5 declares step-1-completed, names the next 6 steps of the T4 §3.6 7-step flow, frontmatter declares `hands_off_to: SP06`. |
| AC5 | Smoke harness self-declares smoke scope and SP08 hand-off. |

Plus presence checks for T-1 (`mental-model.md`), T-2 (`ux-primitives.md`), T-8 (3 setup-direction docs), T-9 (`anti-patterns.md`).

## What it intentionally does NOT validate

- **Renderer behavior.** SP06 owns the wizard that consumes these blocks. Until SP06 lands, "render" means "file exists with the right shape." This harness validates the content; SP06's own test suite must validate runtime rendering.
- **Runtime gate enforcement.** The Block 4 render contract says "no disk write before consent." Proving that property at runtime requires SP06's wizard implementation. SP06 must ship the negative tests declared in `skills/onboarder/preamble/block-4-consent.md` §Render contract negative tests.
- **Articulation scoring.** The 6-criteria articulation set in `mental-model.md` §Articulation success criteria is the SP08 dogfood-harness target. Simulated novice user runs preamble → evaluator scores articulation. Out of scope here.

## Hand-off to SP08

When SP08 lands the full dogfood harness, this smoke remains as a fast-feedback structural test. The full harness extends with: live-VM execution, simulated-user invocation, evaluator scoring against articulation criteria, and end-to-end run validation under both file-drop and no-file paths.

## Source pointers

- Spec: `~/.claude-plans/81-claude-stem-dogfood-optimization/02-foundation-framing/spec.md`
- Tasks: `~/.claude-plans/81-claude-stem-dogfood-optimization/02-foundation-framing/tasks.md` T-10
- Source packet: `~/Desktop/plan-80-packets/02 - foundation-framing (PACKET).md` §9 (scope: minimal harness)
