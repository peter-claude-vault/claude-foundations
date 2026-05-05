---
title: Greenfield Seed Fixture
type: fixture
---

# Greenfield Seed Fixture

A synthetic vault used to test the `/onboard --seed-content <path>` greenfield pipeline end-to-end. Drives intake → IR build → past-section resume → finalize → Section F seven-surface auto-author → four-stage infer-vault orchestrator under stub mode.

> **Note for Phase 5 placement.** The parent directory of this README will move out from under `tests/sp16/fixtures/` to a final path that drops the plan-code prefix. Internal cross-links pointing at `tests/sp16/fixtures/greenfield-seed/` will need a sweep when the rename lands.

<!-- TODO: Peter — confirm final path under tests/ for this fixture -->

## What this fixture exercises

The fixture covers the full greenfield wiring chain, including the steps earlier seed-content tests stop short of:

```
intake.sh → format-detector.sh → ir-builder.sh → orchestrate.sh → bootstrap-schemas.sh → section-f auto-author
```

Earlier seed-content tests stop at the Section F dispatch boundary; this one drives the whole pipeline.

## Layout

- **`vault-content/`** — seven Markdown files split across two clusterable signal groups (alpha, beta) plus one general-norms file. Walked by `intake.sh`; passed to `ir-builder.sh` to produce the IR consumed by `orchestrate.sh`.
- **`extraction-stubs/`** — five `extraction-output-{A..E}.json` templates carrying `{{TEST_VAULT_ROOT}}` placeholders for vault paths. The test runner substitutes the placeholder with the per-run sandbox vault root before copying the stubs into `$INPUTS_DIR/`. Consumed by `bootstrap-schemas.sh` at `run_finalize`.
- **`seed-user-manifest.json`** — minimal pre-finalize manifest with `system.phases_completed: [A,B,C,D,E]` so `onboard.sh --resume` skips the interactive Sections A–E and proceeds directly to `run_finalize` and `run_section_f`. `bootstrap-schemas.sh` overwrites this file at finalize from the extraction stubs.
- **`seed-orchestration.json`** — minimal orchestration skeleton with empty `jobs[]` (the opt-out shape) so `bootstrap-schemas.sh`'s idempotent skeleton-load path is exercised without requiring a launchd plist.

## Constraints

- **Zero forbidden identity tokens.** This fixture and its derived runtime artifacts contain no real-user identity strings. The four-layer grep-audit harness (see [`../grep-audit-fixtures/README.md`](../grep-audit-fixtures/README.md)) verifies the constraint per release.
- **Synthetic identity throughout.** `Alex Rivera`, `Synthetic Holdings Inc.`, projects `Northstar` and `Brightline`, people `Priya Vasquez`, `Jordan Liu`, and `Tomás Kuria`. The same synthetic cast is used by the existing `consultant.json` onboarding fixture — confirmed-synthetic and stable across the suite.
- **Static fixture.** The placeholder substitution at runtime is the only mutation the test runner performs. The fixture itself is read-only on disk.

## Why a directory of synthetic Markdown rather than a pre-baked IR

To exercise the full greenfield wiring chain, including `intake.sh` → `format-detector.sh` → `ir-builder.sh`. A pre-baked IR would short-circuit the part of the pipeline whose job is to build the IR from raw Markdown.

The synthetic-IR helper at `tests/sp16/_lib/section-f-fixture.sh::emit_synthetic_ir()` is reused by other tests for orchestrator-only path-coverage assertions, but the IR consumed by the full pipeline here comes from `ir-builder.sh` walking `vault-content/`.
