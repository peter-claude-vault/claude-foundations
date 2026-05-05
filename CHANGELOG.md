# Changelog

All notable changes to Claude Stem are documented here. Versioning follows the
foundation-manifest `version` field; tag identity matches `vMAJOR.MINOR.PATCH`.

For prior release narratives, see `docs/release-notes-v<version>.md`.

## [v2.1.2] — 2026-05-05

**Plan 71 SP16 — Greenfield Personalization Wiring.** Closes the v2.1.0
architectural-thesis-to-runtime delta surfaced by the 2026-05-05 audit:
v2.1.0 shipped its differentiation surface (seven SP12 auto-author surfaces +
four-stage SP13 infer-vault chain) as dead code on the greenfield onboarding
path. v2.1.2 wires it.

### Wiring delta (closes audit findings P-1, P-2, A1)

- **`run_section_f` in `skills/onboarder/onboard.sh`** (P-1) — new section
  invoked AFTER `run_finalize`. Reads the populated user-manifest, dispatches
  the seven SP12 auto-author surfaces in declared order (1, 2, 3, 4, 5, 6, 9),
  then invokes the four-stage infer-vault orchestrator chain when
  `SEED_CONTENT_PATH` is set. Honors `--skip-auto-author`,
  `--skip-content-seeding`, `--auto-author-only-surfaces=<csv>`. Idempotent on
  re-run via per-surface `state/section-f-state/surface-N.done` markers.
- **`skills/infer-vault-structure/orchestrate.sh`** (P-2) — deterministic
  4-stage chain wrapping `cluster.sh → propose-taxonomy.sh → import-plan.sh →
  review-gate.sh`. Idempotent re-run via per-stage `state/<stage>.done`
  markers. Halt-resume on review-gate stall (writes
  `state/review-pending.flag`, exits 64; `--resume` honors existing markers).
  One JSONL record per stage in `orchestrate-log.jsonl`.
- **`tests/sp16/greenfield-end-to-end.sh`** + synthetic
  `tests/sp16/fixtures/greenfield-seed/` (A1) — drives full
  `intake.sh + ir-builder.sh + 7-surface auto-author + 4-stage orchestrator`
  pipeline against a sandboxed `$HOME` / `$CLAUDE_HOME`. Assertions: ≥7 records
  in `auto-author-log.jsonl`, `approved-import-plan.md` present, ≥1
  consultation record (tag-prefix surface fired), all 4 orchestrator stages
  green, identity-substituted vault `CLAUDE.md` present, zero forbidden
  identity tokens across the sandbox.

### Adopter-visible cleanup bundle (closes audit findings S-1, LA-6, S-3, A3)

- **`tests/grep-audit-patterns/literal.txt` scrubbed** (S-1, A3) — 28
  client / engagement names removed (`LUXE`, `Walmart`, `Ara Partners`,
  `gold-layer-qa`, `b2c-renovate`, `bar-dashboard`, `1p-acquisition`,
  `amazon-creator-directory`, `luxe-creator-analytics`, plus enumerated
  remainder). 10 generic identity tokens retained (Peter-name variants, GitHub
  handle, home-directory paths, vault-path tokens). Audit-detector functional
  equivalence preserved (`tests/grep-audit-unit-test.sh` 5/5 PASS post-scrub).
- **`skills/librarian/capabilities/frontmatter-enforce.sh` parameterized**
  (LA-6) — engagement-subfolder taxonomy now reads from
  `vault.{people,projects_subdirname,strategic,planning}_dirname` user-manifest
  fields via `umr_get_string`. Defaults preserve the SP10 install-convention
  for users who never declared the fields. Closes the SP12 T-9 parameterization
  begun under `vault.projects_root_dirname`. Regression: SP12 unit suite 12/12
  PASS unchanged; new 27-AC sweep across academic / generalist / default vault
  structures all PASS.
- **`onboarding/lib/mcp-registry-probe.sh` response-shape allowlist** (S-3) —
  records now validated for resolvable `id` / `display_name` / `mcp_server_id`
  before emit. Records failing the allowlist drop with per-record reason on
  STDERR. jq filter rewritten to descend into `.server.{name,...}` per the
  canonical 2025-12-11 `server.schema.json` shape; legacy flat-fields shape
  still tolerated via fallback. Live-registry probe now returns 21 valid
  records with proper title-resolved display names (was: 1 sentinel-substituted
  placeholder under the old filter).

### Documentation true-up (closes audit findings P-3, P-4, B1, B2)

- **`skills/onboarder/SKILL.md`** — new "Section F — Greenfield Personalization
  Auto-Authoring" section documenting post-finalize ordering, the seven
  surfaces, the four-stage chain, the consultation-records-in-auto-author-log
  shape (heterogeneous JSONL discriminated by `action`; no separate
  `consultation-log.jsonl` file), the three flags, and per-surface idempotency.
- **`onboarding/ux/section-a.sh:240-242`** — cost-disclosure prose corrected
  from "Five LLM, two deterministic" to "Four LLM, three deterministic" to
  match the bracketed surface inventory and `docs/llm-cost-model.md`
  classification (LLM: 1, 2, 3, 9; deterministic: 4, 5, 6).
- **`README.md`** — new "Greenfield personalization (optional)" subsection in
  Quick start documenting `/onboard --seed-content <path>`, the seven
  dispatched surfaces, the four-stage chain, the SP15 consultation prompt on
  surfaces 3/4/6, and the three flags.

### Install-shipping fix for `skills/infer-vault-structure/` (latent v2.1.0 carry-forward)

- **`install.sh` and `generate-foundation-manifest.sh` 8-named-skills →
  9-named-skills.** v2.1.0 shipped `skills/infer-vault-structure/` (10 files:
  4-stage chain + orchestrate.sh + 3 Python helpers + stage-2-5-consultation
  + SKILL.md) in the source repo but excluded the directory from install.sh's
  named-skills allowlist. `skills/onboarder/onboard.sh` Section F orchestrator
  invocation and `skills/adopt/retrofit.sh` both depend on this directory at
  `$REPO_ROOT/skills/infer-vault-structure/`. On adopter installs at v2.1.0
  and v2.1.1, those code paths gracefully-skipped or errored; the four-stage
  infer-vault chain was structurally unreachable adopter-side.

  v2.1.2 adds `infer-vault-structure` to install.sh's enumeration (becomes 9
  named skills) and to the foundation-manifest generator's matching scope.
  Adopter-side `~/.claude/skills/infer-vault-structure/` now ships, and the
  Section F orchestrator chain runs end-to-end on `/onboard --seed-content
  <vault>` adopter runs as the v2.1.2 release notes describe.

### Foundation-manifest completeness fix (latent v2.1.0 carry-forward)

- **`foundation-manifest.json` regenerated against v2.1.2 tree.** v2.1.0's
  manifest was timestamped 2026-05-03 but the v2.1.0 tag landed 2026-05-05;
  files added between (SP14 connector wizard runtime, SP15 consultation gate
  library, SP08 retrofit harness, SP13 seed-content/format-parsers tree, etc.)
  were absent from the v2.1.0 manifest. v2.1.2 regen captures those plus the
  SP16 T-1..T-5 deltas plus the `infer-vault-structure` install-shipping fix
  above. Net: 197 → 257 tracked files; tracked SHAs now match the v2.1.2
  working tree.

### Out of scope (deferred to v2.2)

- B4 / LA-5 onboarder Q-coverage of 24+ schema fields — UX expansion charter.
- B6 SP03/SP04/SP05/SP06 label hygiene.
- C1–C4 v2.x charter rows.
- Reopening SP12 (precluded by GA Sigstore attestation).
- Modifications to SP12 surface scripts or SP13 infer-vault scripts
  (composition-not-fork constraint).
- Live `~/.claude/` writes (R-55 zero-touch maintained through v2.1.2).

### Audit reference

`~/.claude-plans/71-claude-foundations-engine-v2/_audit-2026-05-05/00-synthesis.md`
+ `03-personalization-design-integrity.md` + `04-librarian-architect-personalization.md` +
`05-security-audit.md`. Sub-plan: `16-greenfield-personalization-wiring/`.
SP16 commits: `36b0d7f` (T-1) → `6d6a1d2` (T-2) → `8173556` (T-3) →
`19b7351` (T-4) → `3f725ee` (T-5a) → `05cdbe0` (T-5b) → `c48ad75` (T-5c).

---

## [v2.1.0] — 2026-05-05

Plan 71 SP14 — Connector Wizard. See `docs/release-notes-v2.1.0.md` for full
narrative.

## [v2.0.0] — 2026-05-03

Plan 71 ships the personalization engine. Supersedes Plan 38 after the
2026-04-13 incident. See `docs/release-notes-v2.0.0.md` (where present) and
`RELEASE_CHECKLIST.md` for tag-cut procedure.
