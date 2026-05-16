# Documentation Audit — claude-stem

Inventory of every `.md` file in scope. For each: stated purpose, signal-to-noise (S/N) on a 1-5 scale (5 = high signal for an external reader, 1 = lab-notebook noise), and rewrite notes.

**Out of scope** by request: source code logic. **In scope:** every `.md` listed below.

## Top-level docs

| File | Lines | Stated purpose | S/N | Rewrite notes |
|---|---|---|---|---|
| `README.md` | 113 | What claude-stem is, quick-start, architecture-in-one-paragraph | 2 | Buried lede. Status box reads "v2.0.0" but CHANGELOG shows v2.1.2. Heavy internal jargon: "G1-main install-side guard", "I-UNDERSTAND-APRIL-13", "rc1", "SP08", "Plan 38/Plan 71", "v2-engine branch". Architecture paragraph is a wall of nouns. No mermaid. The "What's NOT in v2.0.0" section reads like internal release-cut notes. Needs a complete rewrite that opens with a plain-language pitch (3 sentences), 60-second onboarding path, mermaid arch diagram, and clean cross-links. |
| `CHANGELOG.md` | 140 | Versioned change history | 1 | Reads as plan-tracking notes: Plan 71 SP14/SP16, T-1..T-5, P-1/P-2/A1, S-1/LA-6/S-3/A3, B4/LA-5/B6, audit-finding codes, sub-plan commits. External readers will not parse this. Replace with a clean Keep-a-Changelog format describing user-visible changes per release, no plan codes. |
| `RELEASE_CHECKLIST.md` | 124 | Tag-cut runbook for releases | 3 | Internally useful but lots of plan refs ("SP08 T-7 Lima E2E acceptance", "spec L302/L297-300", "AR-8 hard-dep on T-8", "Plan 71 SP08 spec §release-attestation"). Hazard notes (Sigstore immutability, GITHUB_TOKEN recursion gate) are genuinely useful. Strip plan IDs, keep substance, retitle as a maintainer runbook clearly labelled internal. Could move to `docs/release-runbook.md`. |
| `LICENSE` | n/a | Apache-2.0 license text | 5 | Out of scope (not really doc; license file unmodified). |

## Component-root READMEs

| File | Lines | Stated purpose | S/N | Rewrite notes |
|---|---|---|---|---|
| `installer/README.md` | 3 | Stub: "Foundation-repo distribution-source for SP08 assets. See sub-plan for ownership." | 1 | Useless to external reader. Needs a real intro: what lives here, how install.sh consumes it, contributor-relevance. |
| `onboarding/README.md` | 3 | Stub: "SP07 assets..." | 1 | Same. Onboarding is one of the most important user-facing surfaces — deserves a proper README walking the directory layout (extraction-prompts/, ux/, lib/, archetype-keywords.json, fixtures/, q-field-map.json, archetype-inference.sh, bootstrap-schemas.sh). |
| `orchestrator/README.md` | 3 | Stub: "SP02 assets..." | 1 | Same. Cron architecture is opaque without explanation. README should explain launchd plist rendering, idle-watchdog, cron-wrappers. |
| `plugins/README.md` | 3 | Stub: "SP08 assets..." | 1 | Same. What plugins ship by default? (claude-mem). Why is it bundled? |
| `schemas/README.md` | 42 | Schema inventory + provenance + post-distribution rules | 3 | Substantive content but heavy plan-jargon ("SP01 T-1 (migrated)", "SP09 spec §Source-of-Truth Contract", "1.2.0 fold-in per SP09 T-9 / AR-3", "SP06 13-field contract"). Source-SHA section is internal trivia for an external reader. Keep the schema table, drop sub-plan references, drop SHAs. |
| `skills/README.md` | 3 | Stub: "SP04..SP07 sub-plan assets..." | 1 | Same. Should index every shipped skill with one-line description + link. |
| `templates/README.md` | 84 | settings.json + fragments overview, installer contract, manual install, validation | 4 | Mostly clean but mentions "SP08 installer" repeatedly and references plans implicitly. Light edit to strip "SP08" references; otherwise keep substance. |
| `vault-scaffolding/README.md` | 3 | Stub: "SP08 assets..." | 1 | Same. This is the seed content `/adopt` writes into a fresh vault — should explain what files ship and what they mean. |
| `hooks/README.md` | 79 | Hook taxonomy: 17 default-on + 4 conditional + 1 opt-in | 4 | Clear, tabular, useful. Light edit: remove "SP08", "R-01..R-54", "SP02 spec Constraint" framing. The R-rule numbering belongs in DROPPED-RULES.md, not the entry README. |
| `hooks/DROPPED-RULES.md` | 87 | Why R-rules dropped in foundation rewrite | 2 | Pure internal — references "live (Peter-internal) `pre-write-guard.sh`", "SP02 T-4", individual R-numbers without an R-rule glossary, "spine-remediation Session 16" etc. External reader has no reference frame. Decision needed: rewrite into a clear "what enforcement rules ship and why" doc, OR flag for deletion as historical-only. **Recommend: rewrite as `hooks/RULES.md` describing the 13 active rules generically, with a short "history" footer noting some rules were workflow-specific to the original installation and were dropped.** |

## docs/ directory

| File | Lines | Stated purpose | S/N | Rewrite notes |
|---|---|---|---|---|
| `docs/adopt.md` | 190 | `/adopt` skill reference: scaffolds fresh vault from manifest | 4 | Substantive; well-structured; only minor plan refs ("SP01 fixture set", "v2.1 retrofit pointer"). Keep the structure, strip sub-plan refs, generalize "Alex Engineer" walkthrough. |
| ~~`docs/april-13-autopsy.md`~~ | 119 | Memorial doc: April 13 install corruption incident | 4 | **SUPERSEDED.** Renamed to `docs/install-corruption-incident.md` (SP13 Session 9 J-13, 2026-05-16). Original deleted; `install-corruption-incident.md` is the canonical version with external-audience framing. |
| `docs/burner-key-runbook.md` | 235 | Disposable test-only API key lifecycle | 3 | Good content (5-phase create → revoke flow) but framed as "SP00 T-11 deliverable" with "first downstream consumers SP03 T-8, SP07 T-5". Strip plan IDs, audience needs to be "anyone running the test harness", not "consumer sub-plans". |
| `docs/connectors-granola-pipeline.md` | 97 | Granola-meetings reference connector pipeline | 3 | Useful but framed as "SP14 T-12 deliverable" with audit cross-refs. Plan refs are easy to strip; the substance (connector pipeline as data, runner architecture, cron-wrapper) is solid. |
| `docs/connectors-schema.md` | 107 | `connectors[]` + `connectors_meta` schemas | 3 | Same — strip plan IDs, retain the schema/runtime/orchestration mapping. |
| `docs/doc-dependencies-conventions.md` | 169 | doc-dependencies.json cascade registry conventions | 4 | Clean adopter-facing doc. Light edit: strip "Plan 71 SP12 T-8 + T-15-G4-docs" from status header. |
| `docs/installer.md` | 155 | `install.sh` adopter-facing reference | 4 | Mostly clean. Strip "SP08" and any plan references. |
| `docs/isolation-contract.md` | 204 | SP00 isolation primitives + Lima/Docker contract | 2 | Heavy plan-tracking framing. "SP00 T-12 deliverable", "supersedes T-9 stub", "downstream sub-plan consumers", "SP00 T-11 deliverable". Substance is the test-harness contract — useful for contributors. Recommend retitling as `docs/test-harness.md` and rewriting for "contributors who want to add tests" audience. |
| `docs/llm-cost-model.md` | 96 | LLM cost estimates for auto-authoring | 4 | Clean. Frontmatter reads `shipped_in: SP12 T-3` — strip and retain. |
| `docs/personalization-model.md` | 178 | Universal/Combined/Personal 3-tier classification | 5 | One of the strongest docs. Clean adopter-facing tone, useful audit story. Light edit only — strip "Plan 71 SP12 Tier-1 surfaces" status framing. |
| `docs/provenance-frontmatter.md` | 147 | Provenance frontmatter contract | 4 | Clean. Strip "Plan 71 SP12 Group B surfaces #1, #2, #3, #4, #5, #6, #9" and similar. |
| `docs/r-37-lockstep-walkthrough.md` | 206 | 5-surface lockstep when adding new vault file types | 3 | Clean structurally; framing leans on "R-37" and "Plan 71 SP12 T-15-G9" as if reader knows the rule taxonomy. Retitle to `docs/adding-a-vault-file-type.md`; introduce the 5-surface concept without depending on R-NN labels. |
| `docs/release-notes-v2.1.0.md` | 112 | Connector wizard release narrative | 2 | Heavy plan-tracking ("Plan 71 SP14", "T-1..T-17", "5 sessions, 9 unit-test suites, 225 sub-checks"). Convert to user-facing changelog entry: what shipped, why it matters, how to use it. |
| `docs/release-notes-v2.1.2.md` | 234 | Greenfield personalization wiring release narrative | 1 | Worst offender. Reads as a postmortem of an audit finding. "Audit finding P-1, P-2, A1, S-1, LA-6, S-3, A3, P-3, P-4, B1, B2", commit shas SP16 T-1..T-5c. Rewrite as a clean 30-line release note for users — "v2.1.2 wires up content seeding for greenfield onboarding; details below." |
| `docs/seed-content-pipeline.md` | 54 | Seed-content pipeline overview | 3 | Marked `status: skeleton`; says "T-14 will expand the doc". Either expand it for v2 (research phase will determine) or delete the skeleton in favor of in-skill docs. |

### docs/ C5 status update (SP13 Session 9, 2026-05-16)

The following C5 docs-section findings from the SP13 purity sweep were applied directly (not via `_doc-overhaul/drafts/`):

| Finding | File | Status |
|---|---|---|
| C5-C4 | `docs/vault-claude-md-template.md` | **CREATED** — new docs page per §C/§D/§E/§F/§G |
| C5-H1 | `docs/personalization-model.md` | **APPLIED** — Universal-tier table references `frontmatter-rules.json#types` + `tagging-rules.json#taxonomy` |
| C5-H2 | `docs/installer.md` | **APPLIED** — Step 13.6 table: dropped `vault-overlay.json`, added `governance/foundation-master.json` |
| C5-H3 | `docs/decisions/0005-two-surface-governance-dual-pattern.md` | **APPLIED** — addendum: Enforcement.md meta-spoke retired; enforcement-map.schema.json retired |
| C5-M1 | `docs/decisions/0003-folder-lineage-as-fields.md` | **APPLIED** — addendum: user-vocab abstractification per §H |
| C5-M2 | `docs/decisions/0004-system-utility-dimension-exemption.md` | **APPLIED** — addendum: about-me + artefact-bd retired |
| C5-M3 | `docs/decisions/0006-layer3-overlay-collision-tiebreaker.md` | **APPLIED** — addendum: overlay shape revised to 6-pillar parallel |
| C5-M4 | `docs/glossary.md` | **APPLIED** — Engagement + Engagements-based entries abstracted to archetype-agnostic |
| C5-M5 | `docs/adopt.md` | **APPLIED** — outputs rewritten to §C 3 mandatories + §D 6-spoke; canonical-file-types.json dropped |
| C5-M6 | `docs/seed-content-pipeline.md` | **APPLIED** — Stage 3 example labels abstracted from Engagements/References to Projects/Resources |
| C5-L1 | `docs/decisions/0001-tiered-compliance.md` | **APPLIED** — addendum: vault-schema dissolved → frontmatter-rules.json + foundation-master bundle |
| C5-L2 | `docs/decisions/0002-unified-with-per-archetype-entries.md` | **APPLIED** — addendum: vault-schema dissolved; _tag_prefixes → tagging-rules |
| C5-L3 | `docs/april-13-autopsy.md` | **DELETED** — `install-corruption-incident.md` already existed as canonical version |

Remaining C5 items: C5-C2 (`docs/r-37-lockstep-walkthrough.md` delete) requires OD-5b operator decision.

## Skills (`skills/*/SKILL.md`)

Each SKILL.md has YAML frontmatter (consumed by Claude Code) + body content. Frontmatter must remain in the canonical Claude Code skill shape; bodies need cleanup.

| File | Lines | Stated purpose | S/N | Rewrite notes |
|---|---|---|---|---|
| `skills/onboarder/SKILL.md` | 274 | `/onboard` 5-section interview + Section F auto-authoring | 3 | Substantive, well-structured. Heavy refs to "SP01 inheritance contract", "SP07 audit F-01", "SP12 surfaces", "SP15 consultation gate", "SP16 wired this section in". Strip every "SPNN" mention, retain the table-driven flow description. |
| `skills/adopt/SKILL.md` | 296 | `/adopt` vault scaffold | 3 | Same — strip plan IDs, retain the actual contract (manifest fields → vault output). |
| `skills/architect/SKILL.md` | 470 | `/architect` strategic vault analyzer | 4 | Long but clean. Content references {VAULT_ROOT}/{CLAUDE_HOME} placeholders correctly. Light edit. |
| `skills/librarian/SKILL.md` | 2615 | `/librarian` capability suite (~25 capabilities) | 3 | Massive. Description frontmatter is literally just "Librarian" — useless for model invocation routing. Body reads like internal capability spec — references "Plan 67 SP04 trinity-lag", "Plan 63 T-4 extracted shell", "Plan 59 T-1", many R-rule cross-refs, "Module 16-C, spine-remediation Session 16", "T-9a" inline. Very high signal at the capability level (each capability has clear input/output). **Strategic decision:** Don't try to rewrite the full 2615 lines word-for-word. Instead: (1) rewrite description, (2) rewrite the intro/overview, (3) per-capability headers cleaned of plan IDs, (4) leave fine-grained capability detail substantively intact. Mark for plan-IDs-only sweep. |
| `skills/backlog-hygiene/SKILL.md` | 258 | Stale-item detection + auto-archive | 3 | Strip plan refs ("Plan 67 SP04", "R-29/30/31 wired into backlog-hygiene 2026-04-17", "Phase 4 (docs) at P5 lockstep"). Keep substance. |
| `skills/backlog-research/SKILL.md` | 227 | Research a backlog item before planning | 3 | Same. |
| `skills/backlog-triage/SKILL.md` | 150 | Auto-classify new backlog items | 3 | Same. |
| `skills/inbox-processor/SKILL.md` | 280 | Inbox routing | 3 | Same. |
| `skills/infer-vault-structure/SKILL.md` | 415 | 4-stage cluster→propose→import→review chain | 3 | Heavy SP13 refs throughout. Strong substance — this is the differentiator skill. Strip plan IDs; intro needs to make case for why an adopter would care. |
| `skills/meeting-note-ingestor/SKILL.md` | 191 | Generic meeting → vault notes | 3 | Strip plan refs. Reads cleanly. |
| `skills/meeting-note-ingestor-granola/SKILL.md` | 144 | Granola-specific connector | 3 | Same. |
| `skills/morning-brief/SKILL.md` | 203 | Morning briefing skill | 3 | Same. |
| `skills/seed-projects/SKILL.md` | 475 | Bulk-seed engagements/projects | 3 | Same. |
| `onboarding/SKILL.md` | 151 | bootstrap-schemas (per-section extraction → 4 schemas) | 3 | This is a "skill" by SKILL.md convention but is really an internal engine of the onboarder. Frontmatter `parent_plan` + `sub_plan` + `task` fields are pure plan-tracking. The rest is solid output-contract reference. Strip plan-tracking frontmatter, retain output contract. |

## Templates

| File | Lines | Stated purpose | S/N | Rewrite notes |
|---|---|---|---|---|
| `templates/claude-home-claude-md-template.md` | n/a | Generic `~/.claude/CLAUDE.md` template (rendered by `/onboard` SP12 surface 1) | n/a | Need to read. Likely contains placeholder substitution markers — purpose is the rendered output, not the template itself. Light edit at most. |
| `templates/context-template.md` | n/a | Project Context.md template | n/a | Same. |
| `templates/prd-template.md` | n/a | Project PRD.md template | n/a | Same. |
| `templates/updates-template.md` | n/a | Project Updates.md template | n/a | Same. |
| `templates/vault-claude-md-template.md` | n/a | Vault `CLAUDE.md` template (rendered by `/adopt`) | n/a | Same. |

These five templates ARE the deliverable surface for users — content needs to read well to *adopters*, not to claude-stem developers.

## Onboarding subtree

| File | Lines | Stated purpose | S/N | Rewrite notes |
|---|---|---|---|---|
| `onboarding/onboarder-design.md` | n/a | Per-section prompt cards (anchor-parsed by onboarder UX) | n/a | Need to read. This is internal source material for the onboarder; light edit at most. |
| `onboarding/initial-job-setup-flow.md` | n/a | Section D initial-job staging flow | n/a | Same. |
| `onboarding/extraction-prompts/section-{A..E}.md` | n/a (5 files) | LLM extraction templates per section | n/a | Internal source material; only rewrite if content references plan IDs in user-visible places. |

## Test fixtures

| File | Lines | Stated purpose | S/N | Rewrite notes |
|---|---|---|---|---|
| `tests/foundation/README.md` | n/a | Foundation test harness intro | n/a | Need to read. Likely heavy plan-tracking; rewrite for contributors. |
| `tests/foundation/architect-fixtures/README.md` | n/a | Architect test fixtures | n/a | Probably 1-3 lines stub; rewrite or delete. |
| `tests/foundation/fixtures/vault-minimal/CLAUDE.md` | n/a | Minimal vault CLAUDE.md fixture | n/a | Fixture content; out of scope (acts as test data). |
| `tests/foundation/fixtures/vault-minimal/Vault Architecture.md` | n/a | Minimal Vault Architecture fixture | n/a | Fixture content; out of scope. |
| `tests/grep-audit-fixtures/README.md` | n/a | Grep-audit test fixture intro | n/a | Need to read. |
| `tests/sp16/fixtures/greenfield-seed/README.md` | n/a | Greenfield seed fixture | n/a | Need to read. |
| `tests/sp16/fixtures/greenfield-seed/vault-content/*.md` (7 files) | n/a | Synthetic vault content for greenfield E2E | n/a | Fixture content. Out of scope; might rename to remove "sp16" but leave content alone. |

## Vault scaffolding (seed files /adopt writes)

| File | Lines | Stated purpose | S/N | Rewrite notes |
|---|---|---|---|---|
| `vault-scaffolding/Logs/backlog-progress/_template.md` | n/a | Backlog progress log template | n/a | User-visible after /adopt. Needs to read well to a user who has never seen the backlog system before. |
| `vault-scaffolding/System Backlog - Archive.md` | n/a | Empty index seed | n/a | Likely a stub with frontmatter only. |
| `vault-scaffolding/System Backlog.md` | n/a | Empty index seed | n/a | Same. |

## Pattern observations across the corpus

Recurring noise classes the rewrite must strip:

1. **Plan IDs and sub-plan IDs.** Every doc references "Plan 71", "SP01"-"SP16", "T-1"-"T-17", "P-1/P-2/A1", "AR-3", "S-1/LA-6", "B6". These mean nothing to an external reader. Replace with prose ("the onboarding pipeline", "the connector wizard work").
2. **R-rule numbering.** R-01..R-54 references are scattered everywhere. The rules themselves are real, but the numbering is internal. Replace with what-the-rule-does prose; keep R-NN as parenthetical anchors only when something else references the number.
3. **Audit-finding codes.** "P-1, P-2, A1, S-3, LA-6, B4". Pure internal artifacts.
4. **Build-session callouts.** "Session 11 of spine-remediation", "spine-remediation Module 16-C", "S22 source", "Sub-plan 01 T-2".
5. **Sigstore and release-machinery jargon** without explanation. "Rekor", "OIDC", "Fulcio cert", "actions/attest-build-provenance@v2" — fine for the release runbook but doesn't belong in the README.
6. **April-13/Plan-38/Plan-71 succession framing** as if external readers are expected to know the lineage. Plan numbers should disappear; the substantive lessons (sentinel-gated install, isolation harness) survive.
7. **"v2-engine branch" / "rc1 ships fixture-staged" / "30-day GA observation window"** — these are project-management artifacts, not user-facing facts.
8. **Stub READMEs.** Six 3-line "Foundation-repo distribution-source for SPNN assets. See sub-plan for ownership." stubs. They actively harm the docs because a curious reader hitting `installer/README.md` learns nothing.
9. **"Status:" header pattern that conflates document status with software status.** Most files declare `**Status:** active — SPNN T-N deliverable`. Either drop the header (default = current) or replace with a software-version field.
10. **Mismatch between README "Status: v2.0.0" and CHANGELOG showing v2.1.2.** This is a documentation-rot bug, not just style. Will be fixed in the rewrite.

## Files flagged for possible deletion (Phase 6 surfacing)

These need a Peter call rather than unilateral removal:

- `hooks/DROPPED-RULES.md` — pure internal; delete OR rewrite as `hooks/RULES.md`.
- `docs/april-13-autopsy.md` — keep as a memorial/runbook lesson, OR move to `docs/incidents/april-13.md`. Recommend keeping but rewriting the intro.
- `docs/r-37-lockstep-walkthrough.md` — retitle as `docs/adding-a-vault-file-type.md`; the R-37 framing is internal.
- `docs/release-notes-v2.1.0.md` and `v2.1.2.md` — replace with concise per-version entries inside `CHANGELOG.md`. Or keep separate but rewrite drastically.
- `docs/isolation-contract.md` — rename to `docs/test-harness.md`; reframe for contributors.
- `RELEASE_CHECKLIST.md` — move to `docs/release-runbook.md`; clearly mark as maintainer-only.
- `docs/seed-content-pipeline.md` — skeleton-only; either expand (research will determine) or fold into the infer-vault-structure SKILL.md.

## Net-new docs likely needed

- `docs/architecture.md` — high-level architecture diagram + component overview. README will link.
- `docs/concepts.md` — key terms (manifest, foundation, vault, skill, hook, archetype) defined for newcomers. Could be a short glossary inside the README instead.
- `CONTRIBUTING.md` — does not exist; needed for skeptical-engineer audience.

## Audit complete; advancing to research phase
