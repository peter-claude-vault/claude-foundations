---
title: SP16 T-3 Greenfield Seed Fixture
type: fixture
parent_plan: 71-claude-foundations-engine-v2
---

# SP16 T-3 Greenfield Seed Fixture

Hermetic synthetic content for `tests/greenfield-pipeline/greenfield-end-to-end.sh`. Drives the full `/onboard --seed-content <path>` greenfield pipeline (Stage-1 INGEST → IR-build → resume past Sections A–E → Finalize bootstrap-schemas → Section F seven-surface auto-author + four-stage infer-vault orchestrator) under stub mode.

## Layout

- `vault-content/` — 7 markdown files split across two clusterable signal groups (alpha/beta) plus one general-norms file. Walked by `intake.sh`; passed to `ir-builder.sh` to produce the IR consumed by `orchestrate.sh`.
- `extraction-stubs/` — 5 `extraction-output-{A..E}.json` templates carrying `{{TEST_VAULT_ROOT}}` placeholders for vault paths. The test runner substitutes the placeholder with the per-run sandbox vault root before copying the stubs into `$INPUTS_DIR/`. Consumed by `bootstrap-schemas.sh` at `run_finalize`.
- `seed-user-manifest.json` — minimal pre-finalize manifest with `system.phases_completed: [A,B,C,D,E]` so `onboard.sh --resume` skips the interactive Sections A–E and proceeds directly to `run_finalize` + `run_section_f`. Bootstrap-schemas overwrites this file at finalize from the extraction stubs.
- `seed-orchestration.json` — minimal orchestration skeleton with an empty `jobs[]` (D-2 opt-out shape) so bootstrap-schemas's idempotent skeleton-load path is exercised without requiring a launchd plist.

## Constraints

- Zero forbidden identity tokens. Per `feedback_universal_vault_safety` and the SP16 T-3 AC#2 blocklist (enumerated in `tasks.md` §T-3), this fixture and its derived runtime artifacts contain no real-user identity strings.
- Synthetic identity. `Alex Rivera`, `Synthetic Holdings Inc.`, projects `Northstar` / `Brightline`, people `Priya Vasquez` / `Jordan Liu` / `Tomás Kuria` (also used by the existing `consultant.json` onboarding fixture — confirmed-synthetic).
- Static fixture. The placeholder substitution at runtime is the only mutation the test runner performs. The fixture itself is read-only on disk.

## Why a directory of synthetic markdown rather than a pre-baked IR

To exercise the FULL greenfield wiring chain, including `intake.sh` → `format-detector.sh` → `ir-builder.sh`. SP16 T-2's existing tests stop at the Section F dispatch boundary; T-3 is the first test to drive the seed-content pipeline end-to-end.

## Reuse

`tests/greenfield-pipeline/_lib/section-f-fixture.sh::emit_synthetic_ir()` is reused by other SP16 tests for orchestrator-only path-coverage assertions, but the IR consumed by the full pipeline here comes from `ir-builder.sh` walking `vault-content/`.
