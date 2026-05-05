---
name: seed-projects
description: SP13 T-8 Stage 3 GENERATE-WITH-GATE. Consumes T-7 user-approved import plan (state/approved-import-plan.md; sp13-t6/1) and scaffolds PRD/Context/Updates triads under each project candidate's proposed_path. Single batched gate + atomic-on-approve. Each generated file carries SP12 provenance frontmatter via lib/provenance-frontmatter.sh::pf_emit. /adopt invokes this skill when an approved plan is detected post-onboarding.
disable-model-invocation: true
argument-hint: "--vault-root PATH [--approved-plan PATH] [--templates-dir PATH] [--pf-lib PATH] [--gate-lib PATH] [--audience SELF|TEAM|...] [--accept-on-eof]"
---

# seed-projects

Stage 3 of the SP13 content-seeding pipeline. T-7 user-approved import plan
becomes vault project triads (PRD.md / Context.md / Updates.md) under each
project candidate's `proposed_path`. Single batched gate at end of plan
iteration; atomic-on-approve (all files write or none).

## Personalization tier

This is a **Universal capability** per `docs/personalization-model.md` §1 —
the skill body is identical for every adopter. Personalization comes from
the user's approved import plan (their seeded files clustered + labeled at
Stage 2 INFER), not from per-user code. Output artifacts carry SP12
provenance frontmatter via `lib/provenance-frontmatter.sh::pf_emit`. See
`docs/personalization-model.md` for the full classification framing — this
skill does not re-declare it.

## Invocation

`/seed-projects --vault-root <path>` — the `/adopt` skill auto-invokes
this when an approved import plan is present at `$CLAUDE_HOME/onboarding/
seed-content/state/approved-import-plan.md` (post-install) or the
foundation-repo equivalent (during testing).

Direct invocation:

```sh
./seed.sh \
  --vault-root /Users/me/MyVault \
  --approved-plan onboarding/seed-content/state/approved-import-plan.md
# → /Users/me/MyVault/Engagements/<label>/{PRD.md, Context.md, Updates.md}
# → audit log entries appended at onboarding/auto-author-log.jsonl (SP12 stream)
```

### `seed.sh` flags

| Flag | Default | Meaning |
|---|---|---|
| `--vault-root <path>` | required | Vault root; project folders land under here. Caller (typically `/adopt`) must scaffold the vault root before invoking this skill. |
| `--approved-plan <path>` | `onboarding/seed-content/state/approved-import-plan.md` | T-7 user-approved plan input (`schema_version: sp13-t6/1`); validated before consumption. |
| `--templates-dir <path>` | `templates/` | Foundation-repo templates dir holding `prd-template.md` / `context-template.md` / `updates-template.md`. |
| `--pf-lib <path>` | `lib/provenance-frontmatter.sh` | SP12 T-2 provenance helper; sourced (never forked). |
| `--gate-lib <path>` | `onboarding/lib/three-step-gate.sh` | SP12 T-1 audit-log resolver; sourced for `gate_audit_path`. |
| `--explainer-lib <path>` | `skills/seed-projects/explainer-fragments.sh` | T-9 inline explainer fragments lib; sourced for `emit_full_block`. |
| `--plan-tree <path>` | `~/.claude-plans/71-claude-foundations-engine-v2` | Plan tree root for dev-mode SP12 T-2 + T-11 done-marker checks. Production adopters skip both checks automatically (no plan tree → no-op). |
| `--audience <enum>` | `self` | Audience field for generated frontmatter. |
| `--accept-on-eof` | off | Treat stdin EOF as default `apply` (smoke-test convenience). |

## Architecture decisions (T-8)

### Skill placement — separate skill, NOT `/adopt` extension

Per spec L262 + the build-decision record at `state/T-8-build-decision.md`:
ship as `skills/seed-projects/`, NOT as a `/adopt` extension. `/adopt`
remains the bare-vault scaffolder; `/seed-projects` is the seeded-content
overlay. Two surfaces, one composition point. Users who `/onboard` without
`--seed-content` get the same `/adopt` behavior as before; users who
`/onboard --seed-content` get the scaffold + the project triads on top.

`/adopt` detects the trigger by checking for `approved-import-plan.md`
presence at runtime. The approved-plan file IS the contract — its
existence is proof that `/onboard --seed-content` ran, the user reviewed
the plan, and the T-7 gate accepted. No shadow flag in `user-manifest.json`.

### Single batched gate vs per-triad gate

Per spec L264 + R1 §6 risk #3 UX-quality: ONE batched preview at end of
plan iteration; ONE user `[a/e/s/b]` prompt; atomic-on-approve. For a
5-project plan that's 15 staged files surfaced in a single diff bundle,
NOT 15 individual gate prompts. Per-file gates would force user fatigue
(rubber-stamping or mid-flow abandonment).

Implementation: stage all files into `$TG_STAGE_DIR/seed-projects/`,
render a unified diff bundle (per-file: full content for new targets,
unified `diff -u` for pre-existing targets) to stderr, prompt the user
ONCE, and on apply walk the staging tree with atomic `cp + mv` per file.

Atomic-on-approve guarantee: each file's `cp .../tmp.$$ + mv` is atomic
on the destination filesystem. The whole batch is NOT wrapped in a
filesystem-level transaction (POSIX provides no portable directory-tree
atomicity); a partial failure mid-batch returns rc=3 and audits the
specific file that failed. Re-running `/seed-projects` after fixing the
underlying cause is safe — written files round-trip through the gate
preview as already-existing targets, and the user re-confirms.

### Audit-log shape — REUSE SP12's `auto-author-log.jsonl` stream

Same JSONL shape SP12's gate library writes: `{ts, surface_id, action,
target_path, sha_before, sha_after, note}`. Differentiation comes from
`surface_id="seed-projects"` + `action` enum (`generate / preview /
apply / skip / abort / error`). Adopters reading the audit log get one
chronological view of every auto-authoring event across SP12 + SP13
surfaces — no separate stream, no schema fragmentation.

`seed.sh` resolves the audit log via `gate_audit_path` (public API from
sourced gate library) and writes JSONL records directly using `jq -nc`
to compose the same record shape. We do NOT route through `gate_apply`
(would force per-file prompts); we DO emit byte-identical records
because the audit-log consumer (whatever future tooling reads it) sees
one schema across all surfaces.

### Template placeholder syntax — mustache-style, hand-rolled

Templates use `{{var}}` and dotted-path `{{candidate.metadata.summary}}`.
Substitution is regex-based in stdlib Python — no `jinja2` / `chevron` /
`mustache` dep. Same stdlib-only constraint that T-4/T-5/T-6/T-7 held.

Unresolved tokens render as `_unresolved:<token>_` in the output (visible
to the user; never silently dropped) — surfaces template/data drift
loudly so the regression is caught at the preview gate, not buried in a
rendered file.

### Markdown / YAML parser — minimal, hand-rolled

T-8 walks the approved plan to extract project candidate H3 sections + their
inline `yaml` blocks. The YAML shape is bounded (scalars + lists + nested
dicts of depth ≤ 2; no anchors, aliases, multi-doc, or flow style); a
minimal recursive-descent parser handles it. Same stdlib-only profile
SP13 has held throughout.

Validation: each parsed candidate must carry the 8 required fields per
`schemas/import-plan-schema.json#/definitions/candidate_block`
(`candidate_id`, `label`, `type`, `proposed_path`, `metadata`,
`source_items`, `confidence`, `low_confidence`). Missing field → exit 2
with structured stderr pointing at the offending H3 line offset. No
files are staged on partial parse.

### Provenance frontmatter — pf_emit per file (15 calls per 5-project run)

Each generated file's frontmatter starts with the SP12 contract:
`generated_by: seed-projects@v2.0.0`, `generated_from:
<candidate_id>/<label>`, `last_user_edit: null`. We shell out to
`lib/provenance-frontmatter.sh::pf_emit` once per file — 15 subprocess
calls per 5-project plan. Negligible cost (each emission < 50ms; total
< 1s); we trade subprocess overhead for SP12-contract conformance instead
of re-implementing emission in Python (and risking drift from the schema).

### Carry-forward T-7 reassemble.py helper — DEFER

T-8's parser walks only the project H3 sections; it does NOT reassemble
the full Draft-07 wrapper from the markdown for upstream re-validation.
The schema-version anchor check (already in T-7 + repeated here) is
sufficient at the T-8 input boundary — we trust the user-approved plan
and only validate the project blocks we actively consume.

A full reassemble.py helper for round-trip Draft-07 validation remains
a potential post-SP13 follow-on. T-9 / T-10 will reuse the same H3
walker pattern (T-9: explainer fragments anchored to per-block tags;
T-10: non-project H3s under `## Doesn’t fit any project`); the natural
promotion point for a shared library helper is T-9 close-out.

## Architecture decisions (T-9)

### Reference, do not rewrite — explainer fragments cite the model doc

`docs/personalization-model.md` (SP12 T-11) is the single source of truth
for the universal / combined / personal classification framing. T-9 ships
a sibling lib (`explainer-fragments.sh`) that emits short (1-3 sentence)
per-tag and per-frontmatter-field explainer snippets at the gate_preview
surface; each snippet **cites** the model doc rather than re-stating its
content. If the framing evolves in v2.1, the doc updates and every T-9
explainer automatically points at the latest version — no rewrite churn
across two surfaces.

### Fire-point — gate_preview, not gate_apply

The explainer block fires inside `print_batched_preview`, immediately
after the run-summary header and BEFORE the per-file diff bundle. The
flow is:

1. Run header (approved plan, vault root, candidates, files staged)
2. **`emit_full_block` → "Why these tags + frontmatter?" section**
3. Per-file diff bundle (one `diff -u` per staged file vs target)
4. "what happens next" UX block
5. `[a/e/s/b]` prompt

Per spec L297: the user reads BEFORE confirming. Firing after `apply`
would explain the artifact post-hoc — too late to inform the apply
decision.

### API shape — three public functions, prefix-bucket dedup

`explainer-fragments.sh` exports three functions:

| Function | Input | Output |
|---|---|---|
| `emit_tag_explainer <tag>` | one tag (e.g., `#engagement/alpha`) | 1-3 sentences explaining what the tag does + a `docs/personalization-model.md` §-reference |
| `emit_field_explainer <field>` | one frontmatter field (`type` / `tags` / `generated_by` / ...) | 1-3 sentences (or silent skip for unknown fields) |
| `emit_full_block [stage_root]` | optional stage tree path | Composes the full "Why these tags + frontmatter?" section: scans the stage tree for tags + fields actually present, dedupes tags by prefix bucket, dispatches to per-tag and per-field emitters |

Tag dispatch is prefix-aware: `#project`, `#project/alpha`, `#project/beta`
all bucket to the `#project` explainer (one entry per prefix bucket per
preview). Same for `#engagement/*`, `#scope/*`, etc. Unknown tags get a
generic "carried through from your import plan" fallback that still
points to the model doc. Unknown frontmatter fields silent-skip (avoid
polluting the explainer with fields we have no documented opinion on).

### Coverage — anchored to actual generated content

When `stage_root` is supplied (the seed.sh call site passes
`$TG_STAGE_DIR/seed-projects`), `emit_full_block` scans every `.md` file
under it for frontmatter tags and field names; the explainer surfaces
ONLY what's actually present in this run's staging tree. Per spec L291
("anchored to actual generated files"). When `stage_root` is omitted,
`emit_full_block` falls back to the union of all known tags + fields —
useful for unit-testing the lib in isolation without a staging tree.

### SP12 T-11 done-marker pre-flight

`seed.sh` checks `~/.claude-plans/71-claude-foundations-engine-v2/12-auto-authored-personalization/state/T-11.done`
before sourcing the explainer lib. Dev-mode only (production adopters
have no plan tree → check is no-op). Mirrors the SP12 T-2 done-marker
check from T-8: each cross-sub-plan dependency surfaces its own
hard-block at the seed.sh entry boundary.

## Output schema (`schema_version: sp13-t8/1`)

T-8's surface produces a manifest JSON during staging (consumed by
`seed.sh` to drive the apply step). On-disk files (PRD/Context/Updates
triads) are markdown — no schema_version on the markdown bodies, but each
carries SP12 provenance frontmatter (`schemas/provenance-frontmatter-
schema.json`) at the top of the YAML frontmatter.

Manifest shape (transient; not written to disk past the staging tmpdir):

```json
{
  "schema_version": "sp13-t8/1",
  "surface_id": "seed-projects",
  "approved_plan_input": "/path/to/approved-import-plan.md",
  "vault_root": "/path/to/vault",
  "stage_root": "/tmp/seed-projects-stage.XXXXXX/seed-projects",
  "templates_dir": "/path/to/templates",
  "generated_at": "2026-05-04T14:05:00Z",
  "candidates_count": 5,
  "writes": [
    {
      "staging": "/tmp/.../Engagements/alpha/PRD.md",
      "target": "/path/to/vault/Engagements/alpha/PRD.md",
      "candidate_id": "p0001",
      "label": "alpha",
      "kind": "PRD"
    }
  ]
}
```

## Output Contract (R-43)

- **Files written:**
  - `<vault-root>/<candidate.proposed_path>/{PRD,Context,Updates}.md` per
    project candidate (only on user `apply`).
  - Audit log entries appended to SP12's `onboarding/auto-author-log.jsonl`
    stream (or `$AUTO_AUTHOR_LOG` override) — one record per gate event
    (generate / preview / apply / skip / abort / error). Apply emits one
    record per file (so a 5-project run lands 15 `apply` records plus the
    `generate` + `preview` pair); skip / abort emit one record total.
  - All paths are caller-controlled (vault root must exist before
    invocation; staging dir defaults to `mktemp -d` under `$TMPDIR` and
    can be overridden via `TG_STAGE_DIR`). No live `~/.claude/` writes.
- **Schema types:**
  - `sp13-t6/1` validated on input (literal frontmatter line
    `schema_version: sp13-t6/1`); mismatch → exit 2.
  - SP12 provenance schema (`schemas/provenance-frontmatter-schema.json`)
    governs the upper-half of every generated file's frontmatter.
  - SP12 audit-log shape (JSONL: `{ts, surface_id, action, target_path,
    sha_before, sha_after, note}`) governs every audit record T-8 emits.
- **Pre-write validation:** `bash -n` clean on `seed.sh`; Python
  `ast.parse` clean on `seed.py`. SP12 T-2 done-marker presence check
  (dev-mode only; provenance frontmatter contract). SP12 T-11 done-marker
  presence check (dev-mode only; `docs/personalization-model.md` for the
  T-9 explainer to cite). Approved-plan path exists + carries `sp13-t6/1`.
  Templates exist at `templates/{prd,context,updates}-template.md`.
  `pf_emit` callable via sourced `lib/provenance-frontmatter.sh`.
  `gate_audit_path` callable via sourced `lib/three-step-gate.sh`.
  `emit_full_block` callable via sourced `explainer-fragments.sh`.
  After staging, every staged file is a non-empty regular file before
  the user prompt fires (parser failure short-circuits the run; no
  preview ever surfaces a half-staged tree).
- **Failure mode:** Block and log.
  - Pre-flight failures → exit 2 with structured stderr (no audit
    record; no staging dir mutated).
  - Staging failure (seed.py rc != 0) → exit 2; manifest absent → no
    preview, no prompt, no apply.
  - User abort → exit 1; audit `abort`; no vault writes.
  - User skip → exit 0; audit `skip`; no vault writes.
  - Apply-time copy / rename failure → exit 3; audit `error` for the
    specific file that failed; partial state possible (some files
    written, the failed one + subsequent are not). Re-running after fix
    is safe — already-written files surface in the next preview as
    pre-existing targets, and the user re-confirms.

## Dependencies

- **T-7 approved import plan** (`onboarding/seed-content/state/approved-import-plan.md`) — required input (`schema_version: sp13-t6/1`).
- **SP12 `lib/provenance-frontmatter.sh`** — required (sourced; never forked). T-2 done-marker checked in dev-mode.
- **SP12 `onboarding/lib/three-step-gate.sh`** — required for `gate_audit_path` resolver.
- **SP12 `docs/personalization-model.md`** — required as a doc citation target for the T-9 inline explainer. T-11 done-marker checked in dev-mode.
- **`skills/seed-projects/explainer-fragments.sh`** (T-9) — required (sourced) for the gate_preview "Why these tags + frontmatter?" block.
- **`templates/{prd,context,updates}-template.md`** — required (rendered with `{{var}}` substitution).
- **`python3`** on PATH (stdlib only — no pip installs).
- **`jq`** — used in `seed.sh` for manifest queries + audit-log JSONL emission.
- **`shasum` or `sha256sum`** — used for sha-before / sha-after in audit records (matches SP12 contract).
- **Editor** — read from `${EDITOR:-vi}` for the edit action; falls back through `vi → nano → vim`.

## Downstream consumers

| Task | Consumes | Notes |
|---|---|---|
| **T-9** explainer-fragments.sh | This skill's `print_batched_preview` UX layer | SHIPPED 2026-05-04. `seed.sh` sources `explainer-fragments.sh` and calls `emit_full_block` at the top of `print_batched_preview` (BEFORE the per-file diff bundle). Each per-tag and per-frontmatter-field snippet cites `docs/personalization-model.md` rather than re-stating the universal / combined / personal classification framing. |
| **T-10** inbox-disposition.sh | `## Doesn’t fit any project` H3 sections from same approved plan | Reuses the H3 walker pattern T-8 introduced. Routes non-project candidates to vault `Inbox/` with `disposition: <type>` + tag (`#unclassified` / `#reference` / `#meeting`). |
| **T-13** retrofit.sh | Templates + provenance contract | Retrofit reuses T-8's PRD/Context/Updates renderer with `mode: retrofit` (skip-creating-new-projects-when-existing-detected; merge-into-existing-instead). |

## R-55 isolation

T-8 produces no `~/.claude/` writes. Output targets land under the
caller-supplied `--vault-root` (production: a user vault path; testing:
a `$TMPDIR/sp13-t8-test-XXXXXX` tmpdir). The hermetic test
(`tests/sp13-seed-projects-test.sh`) provisions everything under
`$TMPDIR/sp13-t8-test-XXXXXX` per `feedback_test_isolation_for_hooks_state`;
sets `AUTO_AUTHOR_LOG` + `TG_STAGE_DIR` into the tmpdir; G1 should never
fire on a T-8 invocation.
