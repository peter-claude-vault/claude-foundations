---
type: preamble-block
block: 4
of: 5
mode: personalized-output
parent_skill: onboarder
parent_plan: 81-claude-stem-dogfood-optimization
sub_plan: 02-foundation-framing
flow_step: 1
ownership: SP02 (this sub-plan OWNS the gate; SP06 RENDERS per the render contract below)
gate_type: informed-consent
gate_blocks: any disk write under user vault or ~/.claude/
---

# Block 4 — What we ask of you (informed consent)

This onboarder will write directly to your vault and `~/.claude/`. Each major step has a confirmation checkpoint, and we will show you what is about to happen before it does. We strongly recommend three things before we proceed:

- Install **Obsidian** (the content-layer interface)
- Install the **claude-mem plugin** (the memory-layer enabler)
- Set up a **GitHub repo for backups** (your recovery insurance for live writes)

All three significantly improve the system we build for you, and the GitHub repo is your safety net in live-write mode. You can skip these and we will do our best, but you will get a meaningfully degraded experience and reduced safety net.

Press [enter] to begin.

---

## Pre-req detail (linked from setup-directions/)

| Pre-req | Rationale (user-facing) | If skipped |
|---|---|---|
| Obsidian (free) | The content layer of your AI system lives in an Obsidian vault. Native Obsidian gives you the visual interface, plugin ecosystem, and graph view that make the vault navigable for both you and Claude. | Vault still works as plain markdown directory; you lose visual interface, plugin extensibility, graph view. |
| claude-mem plugin | Claude's memory layer extends across sessions when claude-mem is running. Without it, Claude only remembers within-session context. | Memory limited to within-session + your manual `~/.claude/CLAUDE.md` rules; no cross-session learned patterns. |
| GitHub repo for backups | The system writes live to your vault and `~/.claude/` in default mode. Automated backup hooks (existing for `~/.claude`; Plan 79 for vault) push to a remote git repo for rollback insurance. Without a remote destination, every change is local-only and unrecoverable if disk loss or corruption occurs. Setup: GitHub account + auth (gh CLI or SSH key) + at least one private repo for vault backup. | No automated remote backup; recovery limited to local git history; live-default writes carry significantly more risk. |

Full setup directions for each pre-req:
- [`research/vault-construction/setup-directions/obsidian-setup.md`](../../../research/vault-construction/setup-directions/obsidian-setup.md)
- [`research/vault-construction/setup-directions/claude-mem-setup.md`](../../../research/vault-construction/setup-directions/claude-mem-setup.md)
- [`research/vault-construction/setup-directions/github-backup-setup.md`](../../../research/vault-construction/setup-directions/github-backup-setup.md)

---

## Render contract for SP06

SP02 OWNS this gate. SP06 RENDERS it. The contract SP06 must satisfy:

1. **Gate fires before any disk write.** The press-`[enter]`-to-begin gate MUST fire before any write to the user's vault, `~/.claude/`, or any other live target. No file creation, no manifest write, no transcript persistence, no audit-log entry on disk before consent. (Pre-consent in-memory state is allowed; persistence is not.)
2. **All three pre-reqs surfaced verbatim.** The bullet list above renders inline, in full, no URL deferral. The rationale + if-skipped table renders inline as well, OR is collapsed behind an "explain" affordance that the user can expand without leaving the block.
3. **Honest-degradation framing intact.** The phrase "meaningfully degraded experience and reduced safety net" — or substitutively-equivalent honest framing — MUST be present. Reassurance softening ("you'll be fine!") is a violation of the soft-mandate engineering contract per `ux-primitives.md`.
4. **Skip path is coherent.** A user who declines all three pre-reqs MUST be able to complete the rest of the onboarder. The skip path is a soft-mandate, never a gate. (See `ux-primitives.md` §Soft-mandate engineering contract.)
5. **Personalized-output mode** per T4 §3.3 — full inline, no URL deferral.
6. **Single explicit consent gate.** This is the one place where a press-to-proceed action is required for live-default writes. SP06 MUST NOT add additional consent prompts that fragment the gate; subsequent confirmation checkpoints (per-step) are confirmation-of-action, not informed-consent-to-write.

## Render contract negative tests (SP06 spec validation hooks)

SP06 implementation must verify, in its own test suite:

- A simulated user pressing Ctrl-C *before* the gate produces zero disk writes under the user vault and `~/.claude/`.
- The pre-req bullet list renders all three items in the user-facing output.
- The honest-degradation phrase (or its substitutively-equivalent text) is present in the rendered output.
- The skip path (user declines all three pre-reqs but proceeds through the gate) reaches Block 5 and exits the preamble cleanly.

## Source

- Plan 81 SP02 spec.md §Block 4 (L115-127)
- Plan 80 SP02 packet T8 §5 Block 4 (verbatim user-facing text), §6 (pre-req table)
- Master Path D step 4(d) amendment 2026-05-07 (gate ownership locked at SP02; SP06 RENDERS per SP02 spec)
- T4 §3.3 surfacing-modes binding spec (personalized-output mode for this block)
- `ux-primitives.md` §Soft-mandate engineering contract (skip path coherent ≠ broken; honest-degradation framing)
