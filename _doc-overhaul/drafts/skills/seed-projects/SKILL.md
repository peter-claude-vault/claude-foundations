---
name: seed-projects
description: >
  Stage 3 of the content-seeding pipeline. Consumes a user-approved import plan and
  scaffolds project triads (PRD.md / Context.md / Updates.md) under each project
  candidate's proposed path, plus inbox-disposition entries for non-project
  candidates. Single batched preview gate; atomic on approve. Each generated file
  carries provenance frontmatter. Invoked by /adopt when an approved plan is detected
  post-onboarding.
disable-model-invocation: true
argument-hint: "--vault-root PATH [--approved-plan PATH] [--templates-dir PATH] [--audience SELF|TEAM|...] [--accept-on-eof]"
---
> **BLOCKED-BY-REDERIVATION** — see `_doc-overhaul/REDERIVATION-REQUIRED.md`


# seed-projects

After the user has approved an import plan (the output of `infer-vault-structure`),
someone has to actually write the files. Writing them naively means dozens of
preview prompts (one per file), which causes user fatigue and rubber-stamping.
Writing them without a preview is unsafe — the user may want to edit a routing
decision or abort entirely. This skill solves both: stage every file under a tmp
directory, render ONE unified diff bundle covering the whole batch, prompt the
user once with `[a/e/s/b]`, and on apply walk the staging tree with atomic
`cp + mv` per file. If apply fails partway through, already-written files
round-trip through the preview as already-existing targets on re-run, so resuming
is safe.

Each generated file carries provenance frontmatter so downstream tools can detect
auto-generated artifacts and avoid double-writing.

## Invocation

`/seed-projects --vault-root <path>` — the `/adopt` skill auto-invokes this when
an approved import plan is present at `$CLAUDE_HOME/onboarding/seed-content/state/approved-import-plan.md`
(post-install) or the foundation-repo equivalent (during testing).

Direct invocation:

```sh
./seed.sh \
  --vault-root /Users/me/MyVault \
  --approved-plan onboarding/seed-content/state/approved-import-plan.md
# → /Users/me/MyVault/Engagements/<label>/{PRD.md, Context.md, Updates.md}
# → /Users/me/MyVault/Inbox/<date>-<slug>.md per non-project candidate
# → audit log entries appended at onboarding/auto-author-log.jsonl
```

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--vault-root <path>` | required | Vault root; project folders land under here. The caller (typically `/adopt`) must scaffold the vault root before invoking this skill. |
| `--approved-plan <path>` | `onboarding/seed-content/state/approved-import-plan.md` | The import plan input; validated before consumption. |
| `--templates-dir <path>` | `templates/` | Foundation-repo templates dir holding `prd-template.md` / `context-template.md` / `updates-template.md`. |
| `--pf-lib <path>` | `lib/provenance-frontmatter.sh` | Provenance helper; sourced (never forked). |
| `--gate-lib <path>` | `onboarding/lib/three-step-gate.sh` | Audit-log resolver; sourced for `gate_audit_path`. |
| `--explainer-lib <path>` | `skills/seed-projects/explainer-fragments.sh` | Inline explainer fragments; sourced for `emit_full_block`. |
| `--inbox-dispo-sh <path>` | `skills/seed-projects/inbox-disposition.sh` | Inbox-disposition wrapper; routes non-project candidates. Absent → `seed.sh` runs project-only (graceful degrade). |
| `--audience <enum>` | `self` | Audience field for generated frontmatter. |
| `--accept-on-eof` | off | Treat stdin EOF as default `apply` (smoke-test convenience). |

## How a run works

1. **Parse the approved plan.** Walk the `## Project candidates` H3 sections plus the `## Doesn't fit any project — disposition` H3 section. Each project candidate carries 8 required fields (`candidate_id`, `label`, `type`, `proposed_path`, `metadata`, `source_items`, `confidence`, `low_confidence`); a missing field exits 2 with structured stderr pointing at the offending H3 line offset. No files are staged on a partial parse.
2. **Stage every file under a single tmp tree.** Project triads land at `$TG_STAGE_DIR/seed-projects/<proposed_path>/{PRD,Context,Updates}.md`. Inbox files (non-project candidates) land at `$TG_STAGE_DIR/seed-projects/Inbox/<date>-<slug>.md`. One unified tree rather than parallel trees lets the explainer scan once and pick up tags + frontmatter from both kinds.
3. **Render the preview.** Unified diff bundle of every staged file vs. its target — full content for new targets, `diff -u` for pre-existing. Above the diff bundle, an explainer block ("Why these tags and frontmatter?") cites `docs/personalization-model.md` rather than restating it.
4. **Prompt once.** `[a/e/s/b]` (apply / edit / skip / batch-abort).
5. **On apply,** walk the staging tree and write each file with atomic `cp + mv`. On a partial failure mid-batch, return rc=3 and audit the specific file that failed. Re-running after fix is safe — already-written files surface in the next preview as pre-existing targets.

The preview header reports both kinds explicitly:

```
Project candidates: 2   Project triads staged: 6
Non-project candidates: 4   Inbox items staged: 8
Total files staged: 14
```

## Batched gate, not per-file

ONE batched preview, ONE user prompt, atomic-on-approve. For a 5-project plan
that's 15 staged files surfaced in a single diff bundle, NOT 15 individual
prompts. Per-file gates would force user fatigue (rubber-stamping or mid-flow
abandonment).

Atomic-on-approve guarantee: each file's `cp .../tmp.$$ + mv` is atomic on the
destination filesystem. The whole batch is NOT wrapped in a filesystem-level
transaction — POSIX provides no portable directory-tree atomicity. A partial
failure mid-batch returns rc=3 and audits the specific file that failed.
Re-running `/seed-projects` after fixing the underlying cause is safe.

## Inbox files — body and tagging

Inbox files use one tag per file, exact-mapped from the candidate type: `type: reference` → `#reference`, `type: meeting` → `#meeting`, `type: unclassified` → `#unclassified`. There is no heuristic over the body content — the user already made the disposition decision at the import-plan review.

The body inlines the source file's text when readable. Pragmatic fallbacks:

- Source file missing, binary, larger than `SOURCE_INLINE_BYTE_CAP` (256 KB), or non-UTF-8 → the body becomes a structured placeholder that names the path and reason. Downstream consumers (the inbox-processor) can still classify from the `source_path` and `source_hash` frontmatter fields.
- Frontmatter `source_inlined: true|false` surfaces which path was taken so downstream consumers can distinguish.

## Output Contract

**Files written (only on user `apply`):**
- `<vault-root>/<candidate.proposed_path>/{PRD,Context,Updates}.md` per project candidate.
- `<vault-root>/Inbox/<date>-<slug>.md` per non-project candidate's source items.
- Audit-log records appended to `onboarding/auto-author-log.jsonl`. One `generate` + one `preview` + N `apply` records (where N = project triads + Inbox items). User `skip` or `abort` emits one record total covering both kinds.

All paths are caller-controlled (vault root must exist before invocation; staging dir defaults to `mktemp -d` under `$TMPDIR` and can be overridden via `TG_STAGE_DIR`). No live `~/.claude/` writes.

**Frontmatter on every generated file** starts with the provenance contract:

```yaml
generated_by: seed-projects@v2.0.0
generated_from: <candidate_id>/<label>
last_user_edit: null
```

Plus per-kind fields:
- Project triads carry `audience` and template-driven fields.
- Inbox files carry `source_path`, `source_hash`, `source_inlined`, and a single tag matching the disposition (`#reference` / `#meeting` / `#unclassified`).

**Schema:**
- The approved plan input must declare a recognized schema version on its frontmatter; mismatch exits 2.
- Provenance schema (`schemas/provenance-frontmatter-schema.json`) governs the upper-half of every generated file's frontmatter.
- Audit-log shape (JSONL: `{ts, surface_id, action, target_path, sha_before, sha_after, note}`).

**Pre-write validation:**
- `bash -n` clean on `seed.sh`; Python `ast.parse` clean on `seed.py`.
- The approved plan exists and carries the expected schema version.
- Templates exist at `templates/{prd,context,updates}-template.md`.
- `pf_emit` callable via the sourced provenance helper; `gate_audit_path` callable via the sourced gate library; `emit_full_block` callable via the sourced explainer library.
- After staging, every staged file is a non-empty regular file before the user prompt fires. A parser failure short-circuits the run; the preview never surfaces a half-staged tree.

**Failure mode:** the skill aborts on validation failure rather than writing partial state.
- Pre-flight failures → exit 2 with structured stderr; no audit record; no staging dir mutated.
- Staging failure → exit 2; manifest absent → no preview, no prompt, no apply.
- User `abort` → exit 1; audit `abort`; no vault writes.
- User `skip` → exit 0; audit `skip`; no vault writes.
- Apply-time copy/rename failure → exit 3; audit `error` for the specific file that failed; partial state possible (some files written, the failed one + subsequent are not). Re-running after fix is safe.

## Template placeholders

Templates use `{{var}}` and dotted-path `{{candidate.metadata.summary}}`. Substitution is regex-based in stdlib Python — no `jinja2`, `chevron`, or `mustache` dependency.

Unresolved tokens render as `_unresolved:<token>_` in the output (visible to the user; never silently dropped). This surfaces template/data drift loudly so the regression is caught at the preview gate, not buried in a rendered file.

## Reproducibility

`SEED_PROJECTS_GENERATED_AT=<ISO-8601>` env var pins the generation timestamp end-to-end for tests.

## Audit log

Same JSONL shape used elsewhere in the auto-authoring pipeline: `{ts, surface_id, action, target_path, sha_before, sha_after, note}`. Differentiation comes from `surface_id="seed-projects"` plus the `action` enum (`generate / preview / apply / skip / abort / error`). Adopters reading the audit log get one chronological view of every auto-authoring event across all surfaces — no separate stream, no schema fragmentation.

## Dependencies

- The approved import plan from `infer-vault-structure/review-gate.sh`.
- `lib/provenance-frontmatter.sh` (sourced).
- `lib/three-step-gate.sh` (sourced for `gate_audit_path`; the batched gate is hand-rolled, so files don't get per-file prompts).
- `templates/{prd,context,updates}-template.md`.
- Co-located `explainer-fragments.sh` — emits the "Why these tags and frontmatter?" snippets at preview time.
- Co-located `inbox-disposition.{sh,py}` — routes non-project candidates to vault `Inbox/`.
- Co-located `h3_walker.py` — shared bounded-YAML + section-walker library used by both `seed.py` and `inbox-disposition.py`.
- `python3` (stdlib only — no pip installs).
- `jq`.
- `shasum` or `sha256sum` for SHA-before / SHA-after in audit records.
- `${EDITOR:-vi}` for the `edit` action; falls back through `vi` → `nano` → `vim`.

## Downstream consumers

| Consumer | Notes |
|---|---|
| `/adopt` | Auto-invokes this skill when an approved import plan is detected post-onboarding (greenfield seed) or post-retrofit (existing-vault path). |
| `/adopt --retrofit-existing` | Uses the same renderer with retrofit-mode behavior — skip already-scaffolded folders, merge into existing rather than create-new. |
| The inbox-processor | Picks up Inbox files written by this skill on its next tick and classifies them like any other Inbox drop. The `generated_by` and `source_inlined` frontmatter fields let it skip unnecessary re-classification. |
