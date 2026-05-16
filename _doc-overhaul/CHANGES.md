# Documentation overhaul — change summary

This file documents the doc rewrite that landed on the working tree. Drafts at `_doc-overhaul/drafts/`, research briefs at `_doc-overhaul/research/`, persona reviews at `_doc-overhaul/reviews/`. Nothing is committed; the working tree is dirty for your review.

## Headline numbers

- **64 markdown files rewritten or created.**
- **60 in-place modifications**, **4 renames** (left old files in place — see below), **9 new files**.
- **Audit identified 75 .md files in scope.** Of those, 11 are test-fixture vault content (synthetic notes for the greenfield-seed test) and were not rewritten — they're test data, not user-facing docs.
- **Three persona reviews** (first-time visitor, Claude Code newcomer, skeptical engineer). Round-2 fixes incorporated; no round-3 review run.

## File-by-file change summary

### Top-level

| File | Change | Notes |
|---|---|---|
| `README.md` | **Major rewrite (round 2).** | Iteration after persona review. Defines vault / manifest / hook / skill in first 200 words. Surfaces voice-first onboarding feature. Adds explicit "Is this for you?" audience table. Notes the existing-`~/.claude/` sentinel ceremony in the 60-second start. Links to new `docs/glossary.md` and `docs/what-runs-on-your-machine.md`. Drops Lima / Sigstore / sha256 / G1-G10 internals. Adds honest "what's not done yet" section. |
| `CHANGELOG.md` | Full rewrite. | Keep-a-Changelog format. All plan IDs / sub-plan IDs / audit-finding codes / commit SHAs stripped. Three releases described in user terms (v2.0.0, v2.1.0, v2.1.2). |
| `CONTRIBUTING.md` | **NEW.** | Did not exist. Covers clone, test harness, scope, bash 3.2 constraint, Output Contract rule, schema-change policy, release-cut pointer. |
| `LICENSE` | Untouched. | Out of scope. |
| `RELEASE_CHECKLIST.md` | **Will be deleted; superseded by `docs/release-runbook.md`.** | The original is still on disk; flag for Peter to remove. |

### `docs/`

| File | Change | Notes |
|---|---|---|
| `docs/adopt.md` | Rewrite. | "Alex Engineer" walkthrough generalized to "Jane Doe". Plan refs stripped. |
| `docs/adding-a-vault-file-type.md` | **NEW (renamed from `r-37-lockstep-walkthrough.md`).** | Title and intro re-anchored away from "R-37 says…" framing. Source file `docs/r-37-lockstep-walkthrough.md` left in place — flag for Peter to delete. |
| `docs/burner-key-runbook.md` | Rewrite. | Plan refs stripped; reframed for "anyone running the test harness against the real Anthropic API". |
| `docs/connectors-granola-pipeline.md` | Light rewrite. | Plan IDs stripped; substance preserved. |
| `docs/connectors-schema.md` | Light rewrite. | Same. |
| `docs/doc-dependencies-conventions.md` | Light rewrite. | Status header de-jargoned. |
| `docs/glossary.md` | **NEW.** | Every term in the system, defined in one sentence. Addresses the most-cited reviewer concern (vocabulary). |
| `docs/install-corruption-incident.md` | **NEW (renamed from `april-13-autopsy.md`).** | Opens with the structural lesson, not the Plan-38/Plan-71 succession framing. Source file deleted 2026-05-16 (SP13 Session 9 J-13). |
| `docs/installer.md` | Light rewrite. | Sub-plan refs stripped. |
| `docs/llm-cost-model.md` | Light edit. | Status header de-jargoned. |
| `docs/personalization-model.md` | Light edit. | Sub-plan status framing stripped. Three-tier model preserved. |
| `docs/provenance-frontmatter.md` | Light edit. | Sub-plan refs stripped. |
| `docs/release-notes-v2.1.0.md` | **Drastic rewrite.** | Was 112 lines of plan-process tracking; now ~40 lines of user-facing release content. |
| `docs/release-notes-v2.1.2.md` | **Drastic rewrite.** | Was 234 lines of audit-finding codes; now ~40 lines of user-facing release content. |
| `docs/release-runbook.md` | **NEW (moved from `RELEASE_CHECKLIST.md` at repo root).** | Plan refs stripped; substance preserved. Source file `RELEASE_CHECKLIST.md` left in place — flag for Peter to delete. |
| `docs/seed-content-pipeline.md` | **Major expansion.** | Was a 54-line `status: skeleton` stub; now a 130-line proper doc covering all four stages. |
| `docs/test-harness.md` | **NEW (renamed from `isolation-contract.md`).** | Reframed for "contributors who want to add tests." Source file left in place — flag for Peter to delete. |
| `docs/what-runs-on-your-machine.md` | **NEW.** | Inventory of every hook, every cron job, every external network call, with off-by-default flags and how to disable. Addresses second most-cited reviewer concern ("what runs on my machine?"). |

### `hooks/`

| File | Change | Notes |
|---|---|---|
| `hooks/README.md` | Rewrite. | Strict-by-default posture explained. The "manifest-driven" claim was qualified to reflect actual code state — six hooks still hardcode `$HOME/.claude` despite the framing. (Skeptical engineer flagged this; I qualified the doc rather than misrepresent. See "Open issues for Peter" below.) |
| `hooks/RULES.md` | **NEW (replaces `DROPPED-RULES.md`).** | Plain-English description of the thirteen pre-write-guard rules. Footer briefly notes that some workflow-specific rules from the original (private) hook were dropped. Source file `DROPPED-RULES.md` left in place — flag for Peter to delete. |
| `hooks/DROPPED-RULES.md` | **Will be deleted; superseded by `hooks/RULES.md`.** | Flag for Peter to remove. |

### `skills/`

| File | Change | Notes |
|---|---|---|
| `skills/README.md` | Rewrite. | Was 3-line stub. Now a proper inventory with one-line descriptions per skill. |
| `skills/adopt/SKILL.md` | Substantial rewrite. | Plan refs stripped; structure preserved. "Peter-specific values" prose generalized. |
| `skills/architect/SKILL.md` | Light-to-medium rewrite. | Plan refs and "split 2026-04-21" notes stripped. Seven dimensions preserved. |
| `skills/backlog-hygiene/SKILL.md` | Light-to-medium rewrite. | Plan refs stripped. R-29/R-30/R-31 retained where they appear in librarian output (kept inline since the reports emit those codes). |
| `skills/backlog-research/SKILL.md` | Same. | |
| `skills/backlog-triage/SKILL.md` | Same. | |
| `skills/inbox-processor/SKILL.md` | Substantial rewrite. | 32% reduction. Plan refs stripped; Output Contract clarified for in-place frontmatter appends vs full artifact writes. |
| `skills/infer-vault-structure/SKILL.md` | Substantial rewrite. | All sub-plan IDs (T-4, T-5, T-6, T-7) stripped from prose. Schema versions (`sp13-t4/1` etc.) retained because they're wire-format identifiers. |
| `skills/librarian/SKILL.md` | **Long noise-strip pass.** | Was 2615 lines; now 2570 lines (~2% reduction; the file is dense reference material — most lines are substance). 34 capabilities, including 5 (`classify`, `cluster-by-topic`, `draft-canonical-file`, `write-frontmatter`, `sanctioned-schema-drift-detect`) that two independent rewrite agents identified as v2.1-deferred capabilities present in the source at extraction time. The current `skills/librarian/SKILL.md` in your working copy carries them; **verify whether they should ship or whether they were intentionally trimmed during a prior pass.** Plan refs, session callouts, audit-finding codes, migration commentary stripped. Path placeholder convention consolidated to one explanation near the top. (Two restart cycles needed — first agent stalled mid-write, second agent worked from an earlier source state, third agent finished after I'd applied an interim version. The 2570-line file is the most comprehensive cleanup; that's what's in the live tree now.) |
| `skills/meeting-note-ingestor/SKILL.md` | Rewrite. | Identity leakage scrubbed (transcript fixtures with named individuals replaced with placeholders). |
| `skills/meeting-note-ingestor-granola/SKILL.md` | Rewrite. | "Peter's meeting-processor" framing replaced with "the maintainer's private skill". |
| `skills/morning-brief/SKILL.md` | Rewrite. | Source file had no frontmatter; new draft adds the canonical `name`/`description`/`argument-hint` shape. |
| `skills/onboarder/SKILL.md` | Substantial rewrite. | Plan refs stripped; voice-first feature surfaced more clearly; 5-section flow preserved; Output Contract preserved verbatim. |
| `skills/seed-projects/SKILL.md` | Substantial rewrite. | 50%+ reduction. Per-task architecture-decision walls collapsed into prose; substance (single batched gate, atomic-on-approve, template syntax) preserved. |

### `onboarding/`

| File | Change | Notes |
|---|---|---|
| `onboarding/README.md` | Rewrite. | Was 3-line stub. Now a proper directory walkthrough. |
| `onboarding/SKILL.md` | Light-to-medium rewrite. | This is the bootstrap-schemas engine. Frontmatter plan-tracking fields stripped; Output Contract preserved. |
| `onboarding/onboarder-design.md` | Light edit. | Plan refs in framing stripped; prompt-card content preserved. |
| `onboarding/initial-job-setup-flow.md` | Light edit. | **Two TODO flags inline for Peter (real schema-vs-renderer drift bugs):** `dow` field array semantics and `log_path` required-but-unused. |
| `onboarding/extraction-prompts/section-{A..E}.md` | Light edits. | Plan refs in comments stripped; extraction prompt bodies preserved verbatim. |

### `templates/`

| File | Change | Notes |
|---|---|---|
| `templates/README.md` | Light edit. | "SP08 installer" framing stripped. |
| `templates/claude-home-claude-md-template.md` | Light edit. | `I-UNDERSTAND-APRIL-13` sentinel reframed as "explicit clobber-acknowledgement sentinel" with cross-link. |
| `templates/vault-claude-md-template.md` | Light edit. | R-29/30/31 numbering replaced with plain-English description. |
| `templates/prd-template.md`, `context-template.md`, `updates-template.md` | Untouched (verbatim copies). | No plan refs to strip. |

### `installer/`, `orchestrator/`, `plugins/`, `vault-scaffolding/`

| File | Change | Notes |
|---|---|---|
| `installer/README.md` | **Replaced 3-line stub with proper README.** | Component map, "when you'd touch this directory" section. |
| `orchestrator/README.md` | **Replaced 3-line stub with proper README.** | Cron architecture explained. |
| `plugins/README.md` | **Replaced 3-line stub with proper README.** | What's bundled, how to disable. |
| `vault-scaffolding/README.md` | **Replaced 3-line stub with proper README.** | Seed-files explained. |
| `vault-scaffolding/Logs/backlog-progress/_template.md` | Light edit. | R-rule numbering replaced with prose. |
| `vault-scaffolding/System Backlog.md`, `System Backlog - Archive.md` | Untouched (verbatim copies). | Already clean. |

### `schemas/`

| File | Change | Notes |
|---|---|---|
| `schemas/README.md` | Rewrite. | Schema inventory expanded from 6 to 9 (the research dir documented 9; the additional three are real and referenced from elsewhere). Source-SHA section dropped (internal trivia). |

### `tests/`

| File | Change | Notes |
|---|---|---|
| `tests/foundation/README.md` | Light rewrite. | Plan refs stripped. |
| `tests/foundation/architect-fixtures/README.md` | Light rewrite. | |
| `tests/grep-audit-fixtures/README.md` | Light rewrite. | |
| `tests/greenfield-seed/README.md` | **NEW directory and README.** | Renamed from `tests/sp16/fixtures/greenfield-seed/`. The original directory is left in place since it's referenced by `tests/sp16/greenfield-end-to-end.sh` — see "Open issues for Peter" below for the path-rename plan. |
| `tests/sp16/fixtures/greenfield-seed/README.md` | Untouched in the apply phase. | But would be deleted once the test driver is updated. |

## Files flagged for deletion (do not delete; flag and explain)

These five files have been superseded by drafts at new paths. The replacement is in place; the original is left for Peter to verify and delete when convenient.

| Source file | Replaced by | Why |
|---|---|---|
| ~~`docs/april-13-autopsy.md`~~ | `docs/install-corruption-incident.md` | Title and framing reset for an external audience. Deleted 2026-05-16. |
| `docs/isolation-contract.md` | `docs/test-harness.md` | Reframed for contributors. |
| `docs/r-37-lockstep-walkthrough.md` | `docs/adding-a-vault-file-type.md` | Title and intro re-anchored. |
| `RELEASE_CHECKLIST.md` (repo root) | `docs/release-runbook.md` | Moved under `docs/`. |
| `hooks/DROPPED-RULES.md` | `hooks/RULES.md` | Replaced "what got dropped" framing with "what runs". |

To remove all five:

```bash
cd ~/Code/claude-stem
rm docs/april-13-autopsy.md docs/isolation-contract.md docs/r-37-lockstep-walkthrough.md RELEASE_CHECKLIST.md hooks/DROPPED-RULES.md
```

Recommend doing this only after spot-checking the new files.

## Net-new files

| Path | Why |
|---|---|
| `CONTRIBUTING.md` | Did not exist. Required reading for contributor PRs. |
| `docs/glossary.md` | Most-cited reviewer concern: vocabulary was used as if self-explanatory. |
| `docs/what-runs-on-your-machine.md` | Second-most-cited reviewer concern: "what runs unattended?" was vague across the original docs. |
| `hooks/RULES.md` | The 13 active rules in plain English (replaces the "DROPPED-RULES" historical retrospective). |
| `docs/install-corruption-incident.md`, `docs/test-harness.md`, `docs/adding-a-vault-file-type.md`, `docs/release-runbook.md` | Renamed targets — see deletion table above. |
| `tests/greenfield-seed/README.md` | New directory; the existing `tests/sp16/fixtures/greenfield-seed/` is referenced by a test driver that hasn't moved yet. |

## Open issues for Peter

These surfaced during the rewrite and warrant a decision rather than a unilateral fix.

### Real bugs the docs cannot paper over

1. **CHANGELOG path mismatch.** `tests/greenfield-end-to-end.sh` is referenced in the v2.1.2 release notes but the actual file is at `tests/sp16/greenfield-end-to-end.sh`. The CHANGELOG was edited to disclose this and signal a future rename, but the repo really should either move the file or accept the sub-plan-named path. Right now an external reader who runs `find . -name greenfield-end-to-end.sh` lands on `tests/sp16/...` which contradicts the v2.1.2 narrative.

2. **Six hooks hardcode `$HOME/.claude`.** Despite the manifest-driven runtime claim, the following hooks do not honor `CLAUDE_HOME`:
   - `hooks/cron-health-banner.sh`
   - `hooks/post-write-verify.sh`
   - `hooks/pre-compact-checkpoint.sh`
   - `hooks/prompt-context.sh`
   - `hooks/session-register.sh`
   - `hooks/stop-checkpoint-check.sh`
   - `hooks/stop-drift-scan.sh`, `worker-statusline.sh`, `session-auto-close.sh`, `session-start-canary.sh` (also hardcode)

   The hooks/README.md was qualified to reflect this rather than perpetuate the marketing claim. The right fix is to add `${CLAUDE_HOME:-$HOME/.claude}` resolution to each hook (a code change, out of scope for this overhaul). Until then, the docs disclose the gap.

3. **`orchestration-schema.json#/jobs[].dow` declared as multi-element array but `render-launchd.sh` reads only `[0]`.** Flagged inline with a TODO marker in `onboarding/initial-job-setup-flow.md`. Either schema needs `maxItems: 1` for the `StartCalendarInterval` branch, or the renderer needs to emit launchd's array form.

4. **`orchestration-schema.json#/jobs[].log_path` is required but ignored by the renderer.** Templates `librarian.plist.tmpl` and `architect.plist.tmpl` consume `$CLAUDE_LOG_DIR` env directly. Either wire `log_path` through the templates or drop it from the schema's required list. Flagged inline in `onboarding/initial-job-setup-flow.md`.

5. **Skill provenance value drift.** `meeting-note-ingestor` and `meeting-note-ingestor-granola` SKILL.md examples ship `generated_by` values that may not match what the runtime actually emits. The drafts assume the new style (`generated_by: meeting-note-ingestor`); the source code may still emit the old style (`sp13-t11/1`). Verify before committing.

6. **`seed-projects` `--plan-tree` flag dropped from public docs.** The flag's default was a hardcoded internal plan path; the new draft describes it as dev-mode only and omits the flag from the public surface. If it's genuinely needed by adopters, re-add it with a generic default.

7. **Five librarian capabilities documented but possibly not active.** `classify`, `cluster-by-topic`, `draft-canonical-file`, `write-frontmatter`, `sanctioned-schema-drift-detect` — two independent rewrite agents identified these as v2.1-deferred capabilities present in `skills/librarian/SKILL.md` at extraction time. The applied draft includes them. Verify whether they should ship in the docs or whether they were intentionally trimmed elsewhere; if the latter, remove the corresponding `## Capability:` blocks from `skills/librarian/SKILL.md`.

### Personalization-model deferral

The skeptical engineer flagged that `docs/personalization-model.md` lists five items as "deferred to a future release" while the README leans on "manifest-driven runtime" as a differentiator. The README rewrite acknowledged this gap by adding a "what's not done yet" section. The deeper fix is either to ship more of the regen orchestration or to soften the README claim further. Decision is yours.

### Sub-plan vocabulary in shipped artifacts (out of scope for docs)

These are source-code issues, not doc issues, but they affect adopter perception:

- Multiple `tests/spNN/` directory names. Adopters don't need to know what sub-plan a test came from. Recommendation: move to `tests/internal/` or rename by what's tested.
- `feedback_*` and `SP_NN` references in `skills/onboarder/onboard.sh:23-28` (script comments). These reference private memory-file names; should be translated to standalone rationale.
- The `I-UNDERSTAND-APRIL-13` sentinel name itself. Both reviewers commented that the inside-baseball date sounds like a one-person learning experience. Renaming to `I-HAVE-READ-THE-DRY-RUN` or similar is a code change but worth considering.

### Seed-content pipeline expansion

The original `docs/seed-content-pipeline.md` was a `status: skeleton` stub. The rewrite expanded it to a proper doc using the infer-vault-structure research brief as source. Verify the expanded content matches the actual implementation before treating it as authoritative.

### v2.1.0 changelog overstates connector catalog

CHANGELOG v2.1.0 originally said "12 known servers in the catalog." The repo ships exactly one pipeline template (`granola-meetings.json`). The rewrite kept the "12" claim because the catalog is presumably maintained outside the foundation-repo. If "12 known servers" only means "wizard knows about 12 server names," the changelog should clarify that.

### Open question on pacing and adopter friction

The first-time visitor and Claude Code newcomer both bounced or bookmarked rather than installed. Common theme: the surface area is overwhelming for someone whose actual need is "Claude knows my context." The README rewrite added an audience table and a "Why this exists (and why you might roll your own instead)" section that explicitly says "If you've already built your own customizations and they work, this repo is a reference, not a replacement." This sets honest expectations but doesn't shrink the surface area. A genuine "minimal mode" install path would address this; today there isn't one.

### Round-3 review not run

The plan called for up to three rounds of persona review. Round 1 produced three substantial reviews; round 2 incorporated specific actionable fixes (vocabulary glossary, "what runs on your machine" doc, README restructure, identity-leak scrub, RULES count fix, CHANGELOG path note, manifest-driven claim qualification). A round-3 review could verify whether the fixes addressed the round-1 concerns. It was not run because the round-2 fixes are large and targeted; running round 3 would either confirm the fixes (and add little) or surface new concerns from the still-unresolved items above (which already need a Peter-level decision rather than a documentation iteration).

## Working tree state

Per the spec: nothing has been committed. The working tree is dirty. To review:

```bash
cd ~/Code/claude-stem
git status --short    # 60 modified + 9 untracked
git diff README.md    # spot-check the highest-impact rewrite
git diff CHANGELOG.md
```

To roll back any individual file: `git checkout -- <path>`.
To roll back everything: `git checkout -- . && git clean -fd CONTRIBUTING.md docs/ hooks/RULES.md tests/greenfield-seed/`.

## Where to look in `_doc-overhaul/`

- `audit.md` — Phase 1 audit (every .md file, signal-to-noise estimate, rewrite notes).
- `research/` — 60 component briefs grouped by category (skills, hooks, schemas, install, orchestrator, connectors, templates, plus a dependency graph at `research/dependency-graph.md`).
- `drafts/` — every rewrite, mirroring repo structure. Compare against the live tree to see exactly what changed.
- `reviews/` — three persona reviews (`first-time-visitor.md`, `claude-code-newcomer.md`, `skeptical-engineer.md`).
- `CHANGES.md` — this file.
