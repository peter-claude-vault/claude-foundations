---
name: onboard
description: Verbal-first 5-section onboarding skill. Captures identity, work context, vault, trust, and privacy preferences via /voice (typed-textarea fallback) and produces a populated user-manifest.json + orchestration.json + staged launchd plist in ≤25 minutes. Hands off to /adopt when the user is freshly installing without an existing vault.
disable-model-invocation: false
argument-hint: "[--resume] [--typed-only] [--section {a|b|c|d|e}] [--retention-on] [--dry-run]"
---

# Onboarder

User-facing entry for `/onboard`. Wraps SP01's locked design contract (prompt cards, extraction prompts, fixtures, archetype heuristic, schema bootstrap) in a 5-section UX shell with `/voice` capture, typed-textarea fallback, confidence-gated follow-up, inline-edit summaries, JSONL audit per section, 10 in-flow opt-out surfaces, and an initial-job-setup hook that stages exactly ONE launchd plist. The skill never bootstraps `launchctl` against the user's real host; it stages and hands off to `claude system enable-daemon` (SP08).

## Invocation

| Command | Behavior |
|---------|----------|
| `/onboard` | Full 5-section flow A → B → C → D → E |
| `/onboard --resume` | Reads `user-manifest.system.phases_completed[]` and continues from the first unfinished section |
| `/onboard --typed-only` | Skip `/voice` probe; force typed-textarea path for sections B/C/D |
| `/onboard --section {id}` | Re-record one section without disturbing other sections' fragments |
| `/onboard --retention-on` | Keep transcripts and audio after extraction (default: auto-delete) |
| `/onboard --dry-run` | Walk the flow without writing to live targets; emit unified diffs from the schema bootstrapper |

`SessionStart` triggers `/onboard` automatically when `$CLAUDE_HOME/user-manifest.json` is missing. After Section E completes, the skill hands off to `/adopt` if `vault.is_fresh == true` AND `paths.vault_root` is null or non-existent.

## SP01 Inheritance Contract

This skill is a UX shell over SP01's locked design. The following assets are inherited verbatim and **must not be modified by SP07**:

| Asset | Path (foundation-repo source) | Purpose |
|---|---|---|
| Onboarder design doc (prompt cards live in §3–§7) | `~/Code/claude-stem/onboarding/onboarder-design.md` | Per-section prompt cards (Section A: §3, B: §4, C: §5, D: §6, E: §7) |
| Per-section extraction prompts | `~/Code/claude-stem/onboarding/extraction-prompts/section-{A..E}.md` | LLM extraction templates run against transcripts (A is deterministic stub; B/C/D/E run extraction) |
| 3 archetype fixtures | `~/Code/claude-stem/onboarding/fixtures/{consultant,developer,writer}.json` | Round-trip dogfood / opt-out audit reference shapes |
| Q-ID → schema-field map | `~/Code/claude-stem/onboarding/q-field-map.json` | 17 direct Qs + 6 checkboxes + 3 binary toggles. Iterate this map's keys; never enumerate Q-IDs in code |
| Archetype-inference heuristic | `~/Code/claude-stem/onboarding/archetype-inference.sh` (SP01 T-7a) | Keyword-scored deterministic pass on B+C transcripts; emits archetype label + confidence |
| Schema bootstrap | `~/Code/claude-stem/onboarding/bootstrap-schemas.sh` (SP01 T-10) | Atomic schema writer; per-target validator (ajv preferred, jq fallback); idempotent; block-and-log on validation failure |

The keyword tables for `archetype-inference.sh` are loaded at runtime from `$CLAUDE_HOME/onboarding/archetype-keywords.json` (override via `KEYWORDS_FILE` env var for testing). The `prompt-cards/` directory referenced in older drafts was struck per audit F-01; prompt-card content is anchor-parsed from `onboarder-design.md` §3–§7.

## 5-Section Flow

| # | Section | Mode | Time | Schema fields seeded | Opt-out surfaces |
|---|---------|------|------|----------------------|------------------|
| A | Welcome & Discovery Review | Confirm pre-fills (no recording) | ~2 min | `identity.name/email`, `system.timezone`, `paths.vault_root`, `vault.root`, `tools.*` | #1 (discovery) |
| B | Who You Are & What You Do | `/voice` 3–5 min OR typed | ~5 min | `identity.role/organization/industry/seniority`, `projects.active[]`, `people[]`, `behavioral.cadence_default`, `vault.default_audience` | #2 (org), #3 (people), #4 (tool integrations) |
| C | Your Knowledge System | `/voice` 2–4 min OR typed | ~4 min | `vault.organizational_method`, `vault.has_structured_projects`, `vault.is_fresh`, `vault.canonical_file_types[]`, `system.opt_outs[]` | #5 (vault), #6 (sensitive content) |
| D | Trust, Privacy & Automation | `/voice` 2–3 min OR typed | ~3 min | `behavioral.autonomy`, `orchestration.jobs[0]`, `architect.prior_seed`, `behavioral.hook_preferences.notification_style` | #7 (hook enforcement), #8 (R-26 threshold), #9 (initial-job), #10 (tripwires) |
| E | Final Checkboxes | 3 binary toggles (no recording) | ~1 min | `behavioral.hook_preferences.{auto_commit,memory_consolidation,multi_session}_enabled` | (deterministic — no opt-outs) |

## Per-Section Pipeline (B/C/D)

For each transcript-mode section, in this order:

1. Render the prompt card (anchor-parse from `onboarder-design.md` §{3..7})
2. Probe the harness for `/voice` availability (per audit F-07: probe the harness API directly, NOT `which /voice` — slash-commands are not on PATH). On unavailability OR `--typed-only`, swap step 3 for typed-textarea
3. Capture: `/voice` records until user stops; returns transcript text + audio path. Write transcript to `$CLAUDE_HOME/onboarding/transcripts/section-{id}.txt`
4. Invoke SP01's per-section extraction prompt against `{transcript, schema slice via q-field-map, discovery context from Section A}`. Receive: populated fragment + `confidence_map` + `source_spans` + `missing_required[]` + `conflicts[]` + `follow_up`
5. Apply confidence gate: ≥0.85 silent populate, 0.5–0.85 yellow-confirm in summary, <0.5 ONE surgical text follow-up. Re-extract with the follow-up answer appended; never re-record for one field, never re-interview the section
6. Render inline-edit summary (`render-summary.sh`); user can accept, edit fields, re-record the entire section, or trigger an opt-out
7. Apply opt-out routing (surfaces #2–#10 are reachable from within their owning section's summary screen); each opt-out writes its own manifest record without aborting the section
8. Append per-section JSONL audit entry: `{section_id, run_id, ts, opt_outs[], confidence_map, source_spans, corrections[], follow_ups[], manifest_paths_written[]}`
9. Merge fragment into the populated manifest via `bootstrap-schemas.sh` (atomic tmp+rename, per-target validation, idempotent)
10. After Section C completes, run `archetype-inference.sh` against B+C transcripts; write the archetype label to `architect.prior_seed` and append archetype-seeded canonical file types to `vault.canonical_file_types[]` (deduplicated)
11. If retention checkbox (Section E E-1 family) is OFF (default), delete transcript + audio; if ON, retain at `$CLAUDE_HOME/onboarding/transcripts/`

Section A is a deterministic confirmation screen — no transcript, no extraction, no confidence gates. Section E is three deterministic binary toggles (all default OFF).

## Top-Level Runner

`skills/onboarder/onboard.sh` chains the deterministic glue end-to-end (sections A and E, `render-summary.sh` invocations after sections B/C/D Pass 2, `bootstrap-schemas.sh` finalize). Sections B/C/D are inherently two-pass with an LLM extraction in the middle: Pass 1 records the transcript and compiles the prompt card; Pass 2 consumes the LLM-produced extraction stub via `EXTRACTION_OUTPUT_OVERRIDE`. The runner yields between passes via a structured `# HANDOFF: extract-section-X` emit and exits rc=5; the LLM driving `/onboard` (or a harness in test mode) does the extraction and re-invokes with `--resume --section X --extraction-stub PATH`. Hermetic test fixtures bypass the LLM via `--test-fixture-dir DIR` (used by SP07 T-11 Alex dogfood and SP08 T-7 Lima E2E).

Both the runner-driven and the LLM-driven invocation paths read the same handoff signals: section-{b,c,d}.sh emit `# HANDOFF: render-summary --section X` after Pass 2; the runner emits `# HANDOFF: extract-section-X` between passes. There is one canonical chain documented in `## Per-Section Pipeline (B/C/D)` below; the runner is its mechanical execution.

## Confidence Gates

Applied per extracted field per section:

| Confidence | Behavior |
|---|---|
| ≥ 0.85 | Populate silently; field appears confirmed in summary |
| 0.5 – 0.85 | Populate; flag yellow in summary ("is this right?"); user accepts, edits, or clears |
| < 0.5 | Surface as `missing_required`; trigger ONE surgical text follow-up; re-extract once |
| < 0.5 on REQUIRED field post-follow-up | **Block section exit** (Output Contract block-and-log); summary highlights the field yellow; user types correction inline before exit |

A required field is any field whose absence would fail SP01 schema validation against `user-manifest-schema.json`. The per-section minimum-viable lists in `onboarder-design.md` §3–§7 are the authoritative required-field set.

Conflict path: if extraction returns `conflicts[]` (transcript contradicts discovery context), summary asks one clarifying question. Override path: user-corrected fields write a `corrections[]` entry to the section's JSONL for future dogfood tuning.

## Opt-out Surfaces (10)

Each surface is reachable in-flow from within its owning section's summary screen and writes a deterministic manifest record without aborting the section:

| # | Surface | Section | Manifest record |
|---|---------|---------|-----------------|
| 1 | Discovery (skip filesystem pre-fill) | A | Empty discovery context + `system.opt_outs[]` appends `discovery_skipped` |
| 2 | Organization field | B | `identity.organization: null` |
| 3 | People capture | B | `people: []` (librarian people-audit skips downstream) |
| 4 | Tool integrations | B | Per-tool `null` flags individual integration blocks |
| 5 | Vault | C | `vault: null` (downstream vault writes go stub-mode until a vault is created) |
| 6 | Sensitive-content acknowledgement | C | `system.opt_outs[]` appends `sensitive_isolation` (or user-provided note in `vault.notes`) |
| 7 | Hook Output Contract enforcement | D | Advisory-mode install for R-43 family hooks |
| 8 | Session-checkpoint R-26 threshold | D | Raise to 55% OR set `CHECKPOINT_DISABLE_OK=1` in `behavioral.hook_preferences` |
| 9 | Initial-job-setup | D | `orchestration.jobs: []` — no plist written, no staging file |
| 10 | Observability tripwires | D | Cron trilayer not installed; user can re-enable later via `/setup-job` |

**Full-opt-out terminal state** (all 10 elected): produces a valid minimal `user-manifest.json` + valid empty `orchestration.json` + zero launchd jobs staged. T-8's `validate-full-opt-out.sh` audits this boundary.

## Initial-Job-Setup Integration (Section D)

After Section D's schema fragment commits and IF opt-out #9 was NOT elected, `initial-job-setup.sh` runs:

1. Read `orchestration.jobs[0].id` from Section D output (`librarian` | `architect`; default applied per `q-field-map.json`)
2. Apply per-job defaults (schedule, log_path, idle_watchdog_sec, budget_usd, model, skip_weekends) per the `defaults_applied` table in `q-field-map.json`
3. The 8-question customization sub-flow (per `~/Code/claude-stem/onboarding/initial-job-setup-flow.md`, SP03 T-12 contract) surfaces these defaults as user-facing overrides; no new Q-IDs are introduced
4. Show dry-run preview: pretty-printed launchd plist + human-readable schedule
5. On user confirmation, invoke `$CLAUDE_HOME/installer/render-launchd.sh <job>` (foundation-repo source: `~/Code/claude-stem/installer/render-launchd.sh`)
6. **Write the rendered plist to `$CLAUDE_HOME/Library/LaunchAgents.staging/com.claude-stem.<Label>.plist`** — staging directory only. The `Label` is derived from the rendered plist via `plutil -extract Label raw` (e.g. `com.claude-stem.librarian-scan.plist`). This filename form is locked per CFF-S55-3
7. Append `$CLAUDE_HOME/onboarding/audit/initial-job-setup.jsonl` entry
8. Emit terminal prompt: "Onboarding complete. Run `claude system enable-daemon` to activate the staged launchd job."

**This skill MUST NOT call `launchctl bootstrap`** against the user's real host. The bootstrap step is owned by SP08's `claude system enable-daemon`, which runs G1–G10 installer-tree validation guards before moving the staged plist to `~/Library/LaunchAgents/` and invoking `launchctl bootstrap gui/$UID`. Test/dogfood variants (Lima E2E + macOS-host smoke) wrap `launchctl` calls in SP00 T-9's sandbox-exec profile inside SP00 T-1's Lima VM (SP00 invariant I2: no test fires a real launchd job on the user's host).

## Resume & Mid-Section Quit

Resume is keyed off `user-manifest.system.phases_completed[]`, an ordered array of section IDs the skill writes after each section's `bootstrap-schemas.sh` merge succeeds.

| Trigger | Behavior |
|---|---|
| `/onboard --resume` | Read `phases_completed[]`; jump to first missing section in order A → B → C → D → E |
| `SessionStart` with `$CLAUDE_HOME/user-manifest.json` missing | Auto-invoke `/onboard` (no `--resume`); write `phases_completed: []` on first section commit |
| `SessionStart` with `phases_completed[]` non-empty AND not all 5 entries present | Surface a one-shot resume prompt: "You stopped onboarding mid-flow. Resume from Section {next}? (yes / start over / skip)" — implemented by SP07 T-10 in the SessionStart hook; this skill exposes the contract |
| Mid-section quit | Per-section checkpoint: partial transcript saved at `$CLAUDE_HOME/onboarding/transcripts/section-{id}.txt`; extraction NOT yet run; `phases_completed[]` is NOT updated for the unfinished section. Re-record offered on resume |

Re-record path (`/onboard --section {id}`): discards the named section's current fragment and JSONL audit entry, removes its `phases_completed[]` membership if present, runs the section pipeline fresh. Other sections' fragments and `phases_completed[]` entries are untouched.

## Output Contract

Per CLAUDE.md skill-creation rules: every vault-writing skill declares files written, schema type, pre-write validation steps, and failure mode.

### Files written

| Path | Schema type | Cardinality | Lifecycle |
|---|---|---|---|
| `$CLAUDE_HOME/user-manifest.json` | Populated instance of `~/Code/claude-stem/schemas/user-manifest-schema.json` (v1.2.0; runtime path `$CLAUDE_HOME/schemas/user-manifest-schema.json`) | Single | Pre-existing skeleton at install (SP08 T-1 `cp -n` from `~/Code/claude-stem/templates/user-manifest-skeleton.json`); SP07 populates via merge-into-existing semantics |
| `$CLAUDE_HOME/orchestration.json` | Populated instance of `~/Code/claude-stem/schemas/orchestration-schema.json` | Single | Pre-existing skeleton at install; SP07 populates `jobs[]` from Section D |
| `$CLAUDE_HOME/Library/LaunchAgents.staging/com.claude-stem.<Label>.plist` | launchd plist (XML; `plutil -lint`-validated) | Per scheduled job | Staging only — **never** moved to `~/Library/LaunchAgents/` by this skill. `<Label>` derived via `plutil -extract Label raw`. Form locked per CFF-S55-3 |
| `$CLAUDE_HOME/onboarding/audit/section-{a,b,c,d,e}.jsonl` | JSONL audit (per-line: `section_id`, `run_id`, `ts`, `opt_outs[]`, `confidence_map`, `source_spans`, `corrections[]`, `follow_ups[]`, `manifest_paths_written[]`) | One file per section | Append-only |
| `$CLAUDE_HOME/onboarding/audit/initial-job-setup.jsonl` | JSONL audit | One file | Append-only; emitted by `initial-job-setup.sh` after staged plist write |
| `$CLAUDE_HOME/onboarding/transcripts/section-{a..e}.txt` | Raw text | One per recorded section | Auto-deleted after extraction unless retention checkbox set |
| `$CLAUDE_HOME/onboarding/bootstrap-log.jsonl` | JSONL audit (per-field: `ts`, `run_id`, `q_id`, `section_id`, `path`, `value`, `confidence`, `source_span`; per-run terminator: `{ts, run_id, status: BOOTSTRAP_COMPLETED|BOOTSTRAP_FAILED}`) | Single | Append-only; emitted by `bootstrap-schemas.sh` |

JSONL audit entries strip user-provided strings from any diagnostic field (per spec §Risk Assessment row "Reference leak via audit JSONL content"). The renderer emits structural metadata only.

### Pre-write validation

For every manifest write, in order:

1. **Q-ID legality** — proposed write paths must resolve via `q-field-map.json` keys (or `_research_c_aliases` table). Unknown Q-ID blocks the write
2. **Schema validation** — `bootstrap-schemas.sh` validates the populated instance against its declared schema (`user-manifest-schema.json` for `U.*`, `orchestration-schema.json` for `O.*`). Validator: `ajv` when on PATH; `jq`-structural fallback otherwise
3. **Confidence-gate clearance** — required fields must be ≥0.5 OR have an inline-typed correction; otherwise section exit blocked
4. **Idempotency** — if a target file exists and bytes match the would-write payload, skip rename and audit-log a `skip-identical` record. Bytes-differ without `--force` writes a `<target>.new` sidecar + emits a unified diff to stderr; exits 1
5. **Atomicity** — all writes go through `tmp + rename` via `bootstrap-schemas.sh`; no partial state visible to live readers
6. **Reference-leak floor** — JSONL audit entries strip user strings; only structural metadata is recorded in audit fields

### Failure mode

**block-and-log** — never "write and hope". On any validation, parse, or IO failure:

1. Roll back all `*.tmp` files in the current run (atomic semantics — live targets remain untouched)
2. Append a `{ts, run_id, status: BOOTSTRAP_FAILED, failed_validation_class, remediation_hint}` terminator to `bootstrap-log.jsonl`
3. Exit non-zero with a structured diagnostic pointing the user at the failure-class file
4. The section's JSONL audit entry records the failure but does NOT add the section to `phases_completed[]` — `--resume` will retry the section cleanly

The user sees the diagnostic path in the run summary and chooses whether to address the failure manually or re-invoke `/onboard --resume`.

## Discovery Probe Sources (Bucket C — read-only)

Section A pre-fills are sourced from the user's live host; the skill reads but never writes:

| Probe | Source | Q-ID feed |
|---|---|---|
| `discovery.name` | `git config --global user.name` | A-1 |
| `discovery.email` | `git config --global user.email` | A-2 |
| `discovery.timezone` | `readlink /etc/localtime \| sed 's\|.*/zoneinfo/\|\|'` (privilege-free; launchd-context-safe; IANA Continent/City form per CFF-S56-5) | A-3 |
| `discovery.vault_root` | Filesystem scan: `~/Documents/*Vault*`, `~/Vault`, `~/Obsidian` | A-4 |
| `discovery.tools.*` | Connected MCP enumeration in `~/.claude/settings.json` (calendar / messaging / email / transcription / tasks providers); `which code cursor zed nvim` for dev_env | A-CB1..A-CB6 |
| `discovery.platform` | `uname -s` → `O.platform` constant (`darwin-launchd`) | (not user-asked) |

If any probe returns null, the corresponding Section A field is left empty and the user types it inline. Section A's opt-out (#1) skips the entire pre-fill block; user provides every value manually.

## Hard Rules

1. **SP01 inheritance is read-only.** This skill calls SP01's prompt cards, extraction prompts, fixtures, archetype heuristic, and schema bootstrap. It does NOT modify them. Mismatches surface as integration failures that SP01 owns fixing.
2. **Q-ID namespace is locked.** Iterate `q-field-map.json` keys; never enumerate Q-IDs in code. Adding a Q-ID requires reopening SP01 T-8 + design-doc §10.
3. **No `launchctl bootstrap` against the user's real host.** Production install writes plist to `$CLAUDE_HOME/Library/LaunchAgents.staging/` only; bootstrap is owned by SP08's `claude system enable-daemon`. Test/dogfood `launchctl` runs under SP00 T-9 sandbox-exec inside SP00 T-1 Lima.
4. **One UX, two input modes.** Verbal and typed paths share the same prompt card, the same extraction prompt, the same confidence gates, and the same summary screen. Per-section toggle is honored mid-flow.
5. **One surgical follow-up per low-confidence required field.** Never re-interview a section. Never re-record for one field. After one follow-up, summary inline-edit is the escape hatch; block-and-log if still <0.5.
6. **Per-section checkpoint after `bootstrap-schemas.sh` merge.** `phases_completed[]` updates only after a successful merge — partial state is unrecoverable but not corrupting.
7. **Transcripts auto-delete by default.** Retention is opt-in via Section E's E-1-family checkbox; default OFF.
8. **Initial-job-setup writes EXACTLY ONE plist.** Default librarian daily 06:00 weekdays; alternate architect weekly Monday 06:00. Never both in Phase 1. Opt-out #9 produces zero plists.
9. **Output Contract is non-negotiable.** Block-and-log failure mode applies to every manifest write. The `corrections[]` JSONL trail is the future-tuning audit surface; never strip it.
10. **`/adopt` delegation is conditional.** Hand off after Section E only when `vault.is_fresh == true` AND `paths.vault_root` is null or non-existent on the live filesystem. If the user has an existing vault, `/adopt` is not invoked.

## Related Skills

| Skill | When | Owns |
|---|---|---|
| `/adopt` | After Section E if `vault.is_fresh == true` AND `paths.vault_root` empty | Fresh-vault scaffolding (vault directory tree, seed CLAUDE.md, initial Vault Architecture.md) |
| `/librarian` | Default initial job (Section D D-2) when user picks `librarian` | Daily vault scan, manifest refresh, drift findings, capability-registry updates |
| `/architect` | Alt initial job (Section D D-2) when user picks `architect`; also runs first-time after onboarding completes IF `architect.prior_seed` contains an archetype label | Strategic 7-dimension vault analysis; reads `architect.prior_seed[]` for first-run seeding |
| `claude system enable-daemon` (SP08) | After onboarding completes; user-invoked | G1–G10 installer-tree validation; moves staged plist to `~/Library/LaunchAgents/`; runs `launchctl bootstrap gui/$UID` |

## Cross-Plan References

- **SP01** — schemas, prompt cards (in `onboarder-design.md` §3–§7), extraction prompts, fixtures, `archetype-inference.sh`, `bootstrap-schemas.sh`, `q-field-map.json` (all inherited verbatim)
- **SP02** — SessionStart hook adds an onboarding-resume branch (SP07 T-10 modifies `session-start.sh`; depends on SP02 T-9 close)
- **SP03** — `installer/render-launchd.sh` (rendering template), `initial-job-setup-flow.md` (8-question customization sub-flow contract)
- **SP04** — librarian is the default initial job; `/librarian classify` consumes the populated manifest
- **SP05** — architect first-run reads `architect.prior_seed[]` directly from `$CLAUDE_HOME/user-manifest.json` (per audit F-10)
- **SP08** — `cp -R foundation-repo/skills/onboarder/ → $CLAUDE_HOME/skills/onboarder/` at install time (per audit F-04); `claude system enable-daemon` owns post-install `launchctl bootstrap`
