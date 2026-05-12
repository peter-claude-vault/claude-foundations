# `spec-context-inject.sh` — sub-plan spec authority injection

A `UserPromptSubmit` hook that injects authoritative sub-plan spec excerpts into model context whenever a prompt references an active sub-plan. Prevents brief-vs-spec drift by construction, not by discipline.

**Origin:** Plan 81 SP01 Session 20 (2026-05-10). See [Failure mode](#failure-mode) below.

## What it does

When a user prompt mentions an active sub-plan — either by path (`.claude-plans/NN-slug/NN-slug`) or by "Plan N SPM" framing — the hook reads the sub-plan's authoritative files and emits them as `additionalContext` ahead of model response:

1. `<sub-plan>/spec.md` — first 80 lines
2. `<sub-plan>/manifest.json` — status, dependencies, acceptance criteria (per-task)
3. `<sub-plan>/00-ideation-brief.md` — first 30 lines
4. `<master-plan>/spec.md` — first 50 lines

Fires once per `(session × sub-plan)` thread; subsequent prompts in the same session for the same sub-plan are silent (sentinel-gated). Total payload capped at 9.5KB with a visible truncation marker on overflow.

## Failure mode

In Plan 81 SP01 Session 20 (2026-05-10), a dispatched session brief said "READ THESE FILES" listing three items (handoff entry, memory, tasks.md). The model executed those reads only — the sub-plan's `spec.md`, master `spec.md`, and `00-ideation-brief.md` were never opened, even though they sat one directory away and had been authored across multiple days to lock down scope, dependencies, and sequencing.

The model then narrated framing that **contradicted the spec text** — claiming "Plan 81 SP02–SP08 must wait for SP01 T-21 soak completion" when the spec said the opposite ("SP02–SP08 only depend on SP01 schema tasks; zero of them depend on T-23"). The drift was caught only via the user's pushback, then resolved by a 4-agent independent investigation that re-read what the model never read.

**Root cause:** in dispatched/scheduled sessions, briefs become the model's entire context window. Authoritative `spec.md` files sit one directory away, untouched. The failure is structural — relying on the brief author to redundantly list every spec file works once, fails on the second author. Memory is a band-aid (`feedback_spec_authority_over_brief.md`); this hook is the structural enforcement layer.

## Detection signals

Two independent signals trigger injection. The hook takes the first match.

**Signal 1 — path-based detection.** Regex match on `\.claude-plans/[0-9]{2,3}-[a-z0-9-]+/[0-9]{2}-[a-z0-9-]+` in the prompt. Used when briefs cite full plan-tree paths.

**Signal 2 — "Plan N SPM" framing.** Extracts `Plan N` + `SPM` from the prompt, then checks the live `.claude-plans/` tree for matching directories. Used when prompts refer to plans by ID without paths. Handles multi-digit SP numbers and leading-zero forms (`SP09` resolved as base-10 via `printf "%02d" $((10#$SP_NUM))` — bash 3.2 octal-parse bug fixed in the live-tree T-1 ship).

## False-positive guards

- **Status guard.** Sub-plans with `manifest.json :: status` of `closed`, `complete`, `superseded`, or `cancelled` are skipped — no injection on historical references.
- **Sentinel gating.** Per `(session_id × plan_slug × sub_plan_slug)` flag at `~/.claude/hooks/state/spec-injected-*.flag`. Second invocation in the same session for the same sub-plan exits silently.
- **Plan-N-only mention.** A prompt with `Plan 81` but no `SP*` framing does not trigger (Signal 2 requires both numbers).
- **Garbage prompts.** Any prompt without a matching path regex or `Plan N SPM` framing is silent.
- **Fail open.** Any error (missing manifest, unreadable spec.md, jq parse failure, etc.) results in silent exit — the hook never blocks the prompt.

## Installation

Shipped at `~/Code/claude-stem/hooks/spec-context-inject.sh`. Installed by `install.sh` Step 2 (hooks glob) to `$CLAUDE_HOME/hooks/spec-context-inject.sh`. Registered in `$CLAUDE_HOME/settings.json` UserPromptSubmit chain via:

- **Template (fresh install):** `templates/settings.json` declares the hook in the UserPromptSubmit chain alongside `prompt-context.sh`.
- **Step 12.5 (re-install / adopter customizations):** idempotent jq merge ensures the hook is registered even when the adopter has a customized UserPromptSubmit chain. Detects existing registration by command-path match; appends to the first bucket's hooks array when absent; no-op when present.

The hook runs **after** `prompt-context.sh` in the chain so context-pressure mandates (R-26) fire first.

## Tests

Foundation-repo test fixtures:

- `tests/spec-context-inject/spec-inject-unit-test.sh` — 23 assertions covering both detection signals, idempotency sentinel, status guards (closed/complete/superseded), garbage prompt silence, Plan-N-only silence, octal-parse fix (SP09), multi-digit SP (SP15), output JSON shape, 9.5KB output cap, missing-manifest fallthrough. Sandboxed via `HOME` override (the hook hardcodes `$HOME/.claude/hooks/state` + `$HOME/.claude-plans`, so HOME override gives equivalent state-isolation to `HOOKS_STATE_OVERRIDE` patterns documented in `feedback_test_isolation_for_hooks_state.md`).
- `tests/installer/install-spec-inject-registration-unit-test.sh` — 10 assertions covering fresh-install registration, re-install idempotency, and pre-existing UserPromptSubmit chain preservation.
- `tests/installer/install-happy-path-unit-test.sh` — extended with 2 assertions (`T1.1a` / `T1.1b`) verifying the hook lands at `$CH/hooks/spec-context-inject.sh` and is executable post-install.

## Audit trail

- Plan 81 SP01 Session 20 incident report: `~/.claude-plans/81-claude-stem-dogfood-optimization/01-manifest-generalization/_session-2026-05-10-r55-drift.md`
- Sub-plan spec: `~/.claude-plans/81-claude-stem-dogfood-optimization/09-spec-authority-injection/spec.md`
- Memory: `feedback_spec_authority_over_brief.md` — band-aid layer; this hook is the structural fix.
