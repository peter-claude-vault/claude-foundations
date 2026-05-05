# Claude Stem v2.1.2 — Greenfield Personalization Wiring

**Released:** 2026-05-05
**Tag:** `v2.1.2`
**Predecessor:** `v2.1.0` (2026-05-05)
**Plan:** Plan 71 SP16 (Greenfield Personalization Wiring) — closed 8/8 tasks
across 6 sessions; closes Plan 71 master at `complete`.

---

## Headline

Section F now fires the seven SP12 auto-author surfaces and the four-stage SP13
infer-vault chain end-to-end on `/onboard --seed-content <vault>` adopter
runs.

The 2026-05-05 audit found that v2.1.0 shipped its differentiation surface as
dead code on the greenfield onboarding path. Surfaces and orchestrator scripts
were individually unit-tested (760+ ACs across SP12/SP13/SP15) and reachable
from per-surface tests + `/adopt --retrofit-existing`, but no entry point in
`onboard.sh`, `bootstrap-schemas.sh`, or `install.sh` invoked them on greenfield
runs. A fresh adopter walking the documented `/onboard` flow saw exactly one
record in `auto-author-log.jsonl` (a single SP14 connector entry) where the
architecture promised seven surface records plus a four-stage infer-vault
orchestration log.

v2.1.2 wires it.

---

## What's new

### Greenfield wiring (closes audit P-1, P-2, A1)

- **`run_section_f` in `skills/onboarder/onboard.sh`.** New section, invoked
  AFTER `run_finalize`. Reads the populated user-manifest, dispatches the seven
  SP12 auto-author surfaces in declared order (`surface-{1,2,3,4,5,6,9}-*.sh`),
  then invokes the SP13 orchestrator chain via the new `orchestrate.sh` when
  `SEED_CONTENT_PATH` is set. Per-surface idempotency via
  `$INPUTS_DIR/section-f-state/surface-N.done` markers.

  **Why post-finalize.** Every surface reads from the populated user-manifest,
  but Sections A–E only emit `extraction-output-{A..E}.json` interview stubs
  plus a `system.phases_completed[]` skeleton via `checkpoint.sh`. The
  structured manifest fields surfaces consume (`identity.industry`,
  `paths.vault_root`, `vault.organizational_method`, `vault.tag_prefix_archetype`,
  etc.) only land when `bootstrap-schemas.sh` (invoked by `run_finalize`)
  consumes the five extraction stubs and atomically writes the populated
  manifest. The original SP16 spec placed Section F before `run_finalize`;
  data-flow integrity required the post-finalize ordering. See SP16 Session 2
  defect-correction record for the full reasoning.

- **Three flags** on `/onboard`: `--skip-auto-author` (skip all 7 surfaces),
  `--skip-content-seeding` (skip the orchestrator), and
  `--auto-author-only-surfaces=<csv>` (run a subset by surface number).

- **`skills/infer-vault-structure/orchestrate.sh`.** Deterministic four-stage
  chain wrapping `cluster.sh → propose-taxonomy.sh → import-plan.sh →
  review-gate.sh`. Idempotent re-run via per-stage `state/<stage>.done`
  markers. Halt-resume on review-gate stall: gate writes
  `state/review-pending.flag`, orchestrator exits 64 with a clear message;
  user invokes `--resume` after review and the orchestrator skips completed
  stages. One JSONL record per stage in
  `$CLAUDE_HOME/projects/<slug>/inferred/orchestrate-log.jsonl` carrying
  `{timestamp, stage, exit_code, duration_ms, evidence_path}`.

- **`tests/sp16/greenfield-end-to-end.sh`** + synthetic
  `tests/sp16/fixtures/greenfield-seed/`. Cross-cutting smoke that drives the
  full `intake.sh + ir-builder.sh + 7-surface auto-author + 4-stage orchestrator`
  pipeline against a sandboxed `$HOME` / `$CLAUDE_HOME` under `$TMPDIR`.
  Synthetic seed content (zero Peter-isms; alpha/beta clusterable signals).
  Six acceptance assertions all green: 21 records in `auto-author-log.jsonl`
  (≥7 required), `approved-import-plan.md` present, 3 consultation records
  (tag-prefix surface fired SP15 gate), all 4 orchestrator stages green,
  identity-substituted vault `CLAUDE.md` at sandbox vault root, zero forbidden
  identity tokens across `$CLAUDE_HOME`.

### Adopter-visible cleanup bundle (closes audit S-1, LA-6, S-3, A3)

- **Client-name scrub in `tests/grep-audit-patterns/literal.txt`** (S-1, A3) —
  reduced from 38 entries to 10. 28 client and engagement names removed
  (Artefact + 4 derivatives, CDMO + DDX, L'Oreal × 5 spelling variants, LUXE,
  Walmart, Ara Partners, six engagement slugs, four `com.*` launchd labels,
  two Peter-resource identifiers). 10 generic identity tokens retained
  (Peter-name variants, GitHub handle, home-directory paths, vault-path
  tokens). Audit-detector functional equivalence preserved
  (`tests/grep-audit-unit-test.sh` 5/5 PASS post-scrub).

- **Engagement-subfolder taxonomy parameterized in
  `skills/librarian/capabilities/frontmatter-enforce.sh`** (LA-6) — finishes
  the SP12 T-9 parameterization started under `vault.projects_root_dirname`.
  Four new env vars (`FM_PEOPLE_DIRNAME`, `FM_PROJECTS_SUBDIRNAME`,
  `FM_STRATEGIC_DIRNAME`, `FM_PLANNING_DIRNAME`) sourced from
  `vault.{people,projects_subdirname,strategic,planning}_dirname` user-manifest
  fields via the existing `umr_get_string` helper. Defaults (`People`,
  `Projects`, `Strategic`, `Planning`) preserve the SP10 install-convention
  for users who never declared the fields. Six previously-hardcoded substring
  assumptions in the `detect_type()` regex patterns now consume the escaped
  manifest values. New 27-AC sweep across academic / generalist / default
  vault structures all PASS; SP12 unit suite 12/12 PASS unchanged.

- **Response-shape allowlist in `onboarding/lib/mcp-registry-probe.sh`** (S-3) —
  records now validated for resolvable `id` / `display_name` / `mcp_server_id`
  before emit; records failing the allowlist drop with per-record reason
  logged to STDERR. The substantive find: jq filter rewritten to descend into
  `.server.{name, ...}` per the canonical 2025-12-11 `server.schema.json`
  shape, with the legacy flat-fields shape still tolerated via `(.server // .)`
  fallback. Live-registry probe now returns 21 valid records with
  title-resolved display names ("inference.sh", "aTars MCP", etc.) where the
  prior code emitted 1 sentinel-substituted `<unknown>` placeholder. SP14
  catalog-discovery suite 30 PASS / 0 FAIL post-edit; cross-cutting smoke
  41 PASS / 0 FAIL.

### Documentation true-up (closes audit P-3, P-4, B1, B2)

- **`skills/onboarder/SKILL.md`** — new "Section F — Greenfield Personalization
  Auto-Authoring" section. Documents post-finalize ordering with the data-flow
  integrity rationale, the seven surfaces classified LLM/deterministic per
  `docs/llm-cost-model.md`, the four-stage chain, the
  consultation-records-in-auto-author-log shape (heterogeneous JSONL
  discriminated by `action`; no separate `consultation-log.jsonl` file), the
  three Section F flags, and per-surface idempotency.

- **`onboarding/ux/section-a.sh:240-242`** — cost-disclosure prose corrected
  from "Five LLM, two deterministic" to "Four LLM, three deterministic" to
  match the bracketed surface inventory below ([LLM]×4 + [deterministic]×3)
  and the canonical `docs/llm-cost-model.md` classification (LLM: 1, 2, 3, 9;
  deterministic: 4, 5, 6).

- **`README.md`** — new "Greenfield personalization (optional)" subsection in
  Quick start documenting `/onboard --seed-content <path>`, the seven dispatched
  surfaces, the four-stage chain, the SP15 consultation prompt on surfaces
  3/4/6, and the three flags.

### Install-shipping fix for `skills/infer-vault-structure/` (latent v2.1.0 carry-forward)

- **`install.sh` 8-named-skills → 9-named-skills.** v2.1.0 shipped the 10-file
  `skills/infer-vault-structure/` tree (the 4 wrapped scripts + the new
  `orchestrate.sh` + 3 Python helpers + `stage-2-5-consultation.sh` + SKILL.md)
  in the source repo but excluded it from `install.sh`'s named-skills
  allowlist. Section F orchestrator invocation in `skills/onboarder/onboard.sh`
  and `skills/adopt/retrofit.sh` both expected the directory at
  `$REPO_ROOT/skills/infer-vault-structure/`; on adopter machines those paths
  resolved to non-existent files and gracefully-skipped or errored. v2.1.2
  adds `infer-vault-structure` to `install.sh`'s enumeration and to
  `generate-foundation-manifest.sh` matching scope. Adopter-side
  `~/.claude/skills/infer-vault-structure/` now ships; the four-stage
  infer-vault chain runs end-to-end on `/onboard --seed-content <vault>`
  adopter runs.

### Foundation-manifest completeness (latent v2.1.0 carry-forward)

- **`foundation-manifest.json` regenerated against the v2.1.2 working tree.**
  The v2.1.0 manifest was timestamped 2026-05-03 but the v2.1.0 tag landed
  2026-05-05 — files added in between (SP14 connector wizard runtime, SP15
  consultation-gate library, SP08 retrofit harness, SP13
  seed-content/format-parsers tree, etc.) were absent from the v2.1.0
  manifest. v2.1.2 regen captures those plus the SP16 T-1..T-5 deltas plus
  the `infer-vault-structure` install-shipping fix above. Net tracked-file
  count: 197 → 257. SHAs now match the v2.1.2 working tree.

---

## Composition-not-fork

Across SP16, the seven SP12 auto-author surface scripts, the four SP13
infer-vault scripts, and the SP15 `consultation-gate.sh` were touched zero
times. Section F shells out to the surfaces as-is; `orchestrate.sh` wraps the
four infer-vault scripts as-is. T-5b touches a librarian capability and T-5c
touches an onboarding lib helper — both predate the SP12 GA-attestation scope
and were always within the legitimate edit boundary.

R-55 zero-touch maintained throughout: zero `~/.claude/` writes from SP16
work. Foundation-repo + plan-tree only.

---

## Adopter-side notes

- **Existing adopter installs.** v2.1.0 → v2.1.2 is a same-`MAJOR.MINOR`
  patch. Re-run `install.sh` to land the new `skills/onboarder/onboard.sh`
  (with `run_section_f`) and `skills/infer-vault-structure/orchestrate.sh`.
  No schema bump; `user-manifest.json` carries forward.
- **First-time greenfield run.** `/onboard --seed-content <vault>` now
  dispatches the seven surfaces and (when seed content is supplied) the
  four-stage infer-vault chain. Stub-mode tests cover the wiring; live LLM
  invocation requires `ANTHROPIC_API_KEY` set in the adopter environment.
- **Section F is opt-out, not opt-in.** Default greenfield behavior fires the
  seven surfaces; `--skip-auto-author` opts out. Default content-seeding
  behavior is gated by `SEED_CONTENT_PATH` being set;
  `--skip-content-seeding` opts out when it is.

---

## What's NOT in v2.1.2

- **B4 / LA-5 onboarder Q-coverage of 24+ schema fields.** UX expansion charter
  for v2.2 — not a wiring fix.
- **B6 SP03/SP04/SP05/SP06 label hygiene.** v2.2 hygiene session.
- **C1–C4 v2.x charter rows.** Tracked in master Plan 71 manifest charter
  queue.
- **SP12 surface modifications.** Precluded by SP12 GA Sigstore attestation.
- **`bootstrap-schemas.sh` `--force` semantics on resume runs.** Carry-forward
  finding from SP16 Session 3 — track for v2.2 hygiene if a structural fix is
  warranted (`run_finalize` consults `BOOTSTRAP_FORCE_ON_RESUME=1` env, OR
  `bootstrap-schemas.sh::seed_memories()` preserves
  `system.phases_completed` when the live file is present).
- **Wider client-name leak class.** Post T-5a, `tests/sp14/cross-cutting-smoke-test.sh:267`
  and `onboarding/tests/sp13-meeting-note-ingestor-test.sh:238` still carry
  string occurrences of `LUXE` and `Walmart` in their assertion bodies. Out of
  T-5a scope; track for v2.2 hygiene.

---

## Audit reference

- `~/.claude-plans/71-claude-foundations-engine-v2/_audit-2026-05-05/00-synthesis.md`
- `_audit-2026-05-05/03-personalization-design-integrity.md`
- `_audit-2026-05-05/04-librarian-architect-personalization.md`
- `_audit-2026-05-05/05-security-audit.md`

Sub-plan: `~/.claude-plans/71-claude-foundations-engine-v2/16-greenfield-personalization-wiring/`.

SP16 commit sequence on `main`:
- `36b0d7f` — SP16 T-1: ship orchestrate.sh + 4 hermetic tests (4/4 PASS)
- `6d6a1d2` — SP16 T-2: ship run_section_f + 5 hermetic tests (5/5 PASS); correct spec L48 ordering
- `8173556` — SP16 T-3: ship greenfield-end-to-end.sh + synthetic seed fixture (6/6 PASS)
- `19b7351` — SP16 T-4: doc true-up
- `3f725ee` — SP16 T-5a: scrub literal.txt
- `05cdbe0` — SP16 T-5b: parameterize engagement-subfolder taxonomy in frontmatter-enforce (27/27 PASS)
- `c48ad75` — SP16 T-5c: response-shape allowlist + canonical-shape jq filter in mcp-registry-probe (17/17 PASS)
- `<v2.1.2 release-prep commit>` — version bump + CHANGELOG + release notes + spec true-up rider

Plan 71 master closes at v2.1.2.
