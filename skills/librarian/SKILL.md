---
name: librarian
description: Librarian
---

# Librarian

Vault integrity, cross-domain sync, and backup. Single authority on "is the vault correct?" Validates placement, frontmatter, cross-references, stale content, log archival, backend↔vault sync, and git backup. Serves as session-close orchestrator and intake validation API via the vault manifest.

## Invocation

`/librarian [capability|mode] [flags]`

| Command | Runs | Default Scope |
|---------|------|---------------|
| `/librarian` (no args) | All integrity capabilities in sequence | `--recent` (7 days) |
| `/librarian full` | All integrity capabilities, full vault | `--full` |
| `/librarian frontmatter-enforce` | Frontmatter enforcer only | `--recent` |
| `/librarian xref-check` | Cross-reference checker only | `--recent` |
| `/librarian log-archive` | Log archiver only | 7-day threshold |
| `/librarian stale-detect` | Stale content detector only | `--full` |
| `/librarian placement-validate` | Placement validator only | vault root + engagements |
| `/librarian sync-check` | Cross-domain consistency only | full |
| `/librarian backup` | Git backup only | all tracked dirs |
| `/librarian --fix` | All integrity capabilities with auto-fix | `--recent` |
| `/librarian --dry-run` | All integrity capabilities, report only | `--recent` |
| `/librarian session-close` | Context + scoped integrity + sync + backup + log | touched files |
| `/librarian session-close --deep` | Same, expanded dependency scope | touched + graph |
| `/librarian memory-hygiene` | Memory file lifecycle maintenance | all memory files |
| `/librarian memory-hygiene --fix` | Same, with auto-apply for safe consolidations | all memory files |
| `/librarian transcript-mine` | Mine session transcripts for implicit knowledge | transcripts since last mine |
| `/librarian transcript-mine --apply` | Same, with auto-write for high-confidence proposals | transcripts since last mine |
| `/librarian architect-triage` | Surface untracked architect recommendations | all architect logs |
| `/librarian mem-promote` | Promote high-signal claude-mem observations to auto-memory | observations since last promote |
| `/librarian cron-log-architecture` | launchd plist vs wrapper dated-log mismatch linter (R-22) | all `com.*.plist` |
| `/librarian handoff-disposition-check` | Grep touched handoffs for unresolved-language without disposition (R-25) | touched `*handoff.md` |
| `/librarian mem-promote --apply` | Same, with auto-write for high-confidence promotions | observations since last promote |
| `/librarian drift-sweep` | Scan vault for frontmatter drift against `vault-schema.json` | full vault (excl. `.claude/projects/*`, `_test*`) |
| `/librarian people-audit` | Audit `*/People/*.md` conformance (frontmatter + `## Context` H2) | all engagements (auto-exempts `status: complete\|archived\|historical\|closed`) |
| `/librarian waiver-audit` | Audit `cascade-waivers.json` abuse + `hook-audit.log` override fires (R-46) | all waivers + all logged fires |
| `/librarian wikilink-repair` | Detect broken `[[wikilinks]]` + propose doc-dependency-registry-seeded repairs (dry-run default; `--apply` to rewrite) | full vault (excl. `Archive/`, `Logs/foundations-essays/`, `Logs/backlog-progress/`) |
| `/librarian stale-detect` | Extracted shell (Plan 63 T-4). 8 staleness rules across file types + R-16 plan-stale-status detection + Plan 67 SP04 trinity-lag | full vault + plan roots |
| `/librarian placement-validate` | Extracted shell (Plan 63 T-5). Vault-root allowlist + project-folder rules + Index File Convention + Logs/ dated pattern | full vault |
| `/librarian tag-coverage-audit` | Vault-wide tag coverage + taxonomy compliance audit (Plan 59 T-1); flags `missing_tags_field`, `empty_tags_field`, `unrecognized_tag_prefix`, `historical_type_residual` | full vault (excl. `Archive/`, `Tags/`, `.claude/projects/`, `.claude/skills/`, `$PLANS_DIR/`) |
| `/librarian rename-detect` | Scan last 24h of `git log --diff-filter=R` across vault + plans; emit NDJSON rename records (Plan 67 SP02 T-1) | vault + plans git repos |
| `/librarian rename-cascade` | Consume rename-detect NDJSON on stdin; rewrite inbound `[[wikilinks]]` + (optional) frontmatter path refs + `parent_plan:` slug; dry-run default (Plan 67 SP02 T-2) | vault + plans |
| `/librarian rename-history-sync` | Maintain `rename_history[]` on `doc-dependencies.json`: `migrate` to backfill empty arrays, `append` to ingest rename-detect stdin (Plan 67 SP02 T-3) | `doc-dependencies.json` |
| `/librarian trinity-drift-detect` | Detect spec.md / manifest.json / tasks.md / per-task T-N status disagreement at plan-root + sub-plan-root (Plan 67 SP04 T-1) | `$PLANS_DIR/**` depth 2 + 3 |

**Note:** `/librarian` and `/librarian full` run the 5 integrity capabilities (frontmatter-enforce, xref-check, log-archive, stale-detect, placement-validate). They do NOT run sync-check, backup, or session-close — those are invoked explicitly. `drift-sweep` + `people-audit` + `waiver-audit` + `tag-coverage-audit` + `trinity-drift-detect` + `skill-parity` are wired into the **Monday-only** `/librarian full` cron block in `librarian-cron.sh` (non-blocking, supplemental to write-time hooks). `rename-detect | rename-history-sync | rename-cascade` runs as Step 2b of `session-close` (dry-run-cascade only; `--apply` is human-initiated).

**Vault root:** `~/Documents/Obsidian Vault/`
**Architecture source of truth:** `~/Documents/Obsidian Vault/Vault Architecture.md`

---

## Capability: frontmatter-enforce

**Runtime:** `~/.claude/skills/librarian/capabilities/frontmatter-enforce.sh` (extracted from pseudocode 2026-04-21 via Plan 63 Sub-plan 01 T-2; sources `lib/findings.sh` + `lib/manifest.sh`).

**Purpose:** Validate and optionally fix frontmatter on vault files against the specs in Vault Architecture.md. Two phases: per-file validation (required fields, empty optionals, tag taxonomy) + four vault-wide drift audits (provides-canonicality, size monitoring, hub-spoke recommendation, schema-type-hook-coverage-gap).

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/frontmatter-enforce.sh [--scope <path>|--recent|--full] [--check|--fix] [--dry-run] [--logs-only]
```

| Flag | Effect |
|------|--------|
| `--scope <path>` | Narrow scope to a single file or directory. Drift audits skipped under `--scope`. |
| `--recent` | Files modified in last 7 days (default when no scope flag). |
| `--full` | Entire vault walk. |
| `--check` | Report only (default). |
| `--fix` | Auto-apply auto-fix class: add missing `updated` (today's date), infer `tags` from path heuristics, remove empty-string optional fields. Survivorship: never modify fields with existing non-empty values. |
| `--dry-run` | Summary counts only; no emissions, no fixes. |
| `--logs-only` | Restrict scope to `$VAULT_LOGS/**/*.md`. Runs only deliverable-detection check (Module 16-C, spine-remediation Session 16) — emits `logs-deliverable-detected` findings. All other scopes and drift audits skipped. |

**Per-file validation output (stdout or `$FINDINGS_OUTPUT`):**
- `frontmatter-missing-required` — required field absent
- `frontmatter-empty-optional` — optional field set to empty string (`""`, `''`, `null`)
- `frontmatter-tag-violation` — tag not in R-32 allowlist, or `tags:` is a string instead of a list

**File type detection (alias collapse applied):** path-pattern rules yield one of 20 schema keys or 5 aliases. Aliases resolve as `skill-spec → reference`, `overview → engagement`, `updates → engagement`, `file-index → index`, `tier-2 → reference`. Required-field matrix mirrors `~/.claude/schemas/vault-schema.json`; tag prefix allowlist mirrors `_tag_prefixes` (currently `engagement/`, `project/`, `scope/`, `status/`, `initiative/`, `artefact-bd/`).

**Scope exemptions:** `.git/`, `.obsidian/`, `.claude/`, `.claude/projects/`, `_test*`, `Logs/ideation-brief-*.md`, `Engagements/*/CLAUDE.md` (navigation, no frontmatter required).

**Drift audits (always run on `--full` / `--recent`; skipped on `--scope` and `--logs-only`):**

**File type detection** uses path patterns first (e.g. `Meetings/*.md → meeting-note`, `Engagements/*/People/*.md → people`, `Engagements/*/Projects/*/* - PRD.md → prd`), with frontmatter `type:` overriding when explicitly set. Full path→type map is embedded in the runtime; see runtime source for the 20-row table. Required-field matrix mirrors `~/.claude/schemas/vault-schema.json`.

**Drift audit finding shapes (read-only; never auto-fixed):**

1. `provides-canonicality-drift` — any capability in `provides:` claimed by 2+ canonical-scope files (vault root depth-1 + `Vault Architecture/**` + `Skills/**`); severity `blocking` if any owner is at vault root OR inside `Vault Architecture/`, else `warning`. Allowlist source of truth: `~/.claude/hooks/drift-allowlist.json` (`provides_overlap[].capability`); mirrored into `librarian-manifest.json` on every run. Peter edits the hooks file directly — never hand-edit the manifest. Engagement reference docs, meeting notes, project docs, and daily notes are excluded (`provides:` is project-scoped vocabulary there).

2. `size-warning-soft` / `size-warning-strong` / `size-guard-violation` — actual lines vs `frontmatter.max_lines`; vault-root files get 400-line default. Thresholds: 70% info, 85% warning, 100% blocking. Finding fields: `file`, `declared_max`, `declared_source` (`frontmatter` | `default_root`), `actual_lines`, `pct_of_max`, `delta`, optional `recommendation`.

3. **Hub-spoke recommendation engine** — attached to size findings with severity ≥ warning AND file in canonical scope. Finds largest non-structural H2/H3 section (excluding `frontmatter`, `version history`, `summary`, `behavioral rules`). If < 30 lines: manual-review message. Otherwise proposes a spoke file at `{parent}/{basename}/{basename} - {slug}.md` with either "Convert to hub-spoke" (no existing spokes) or "Add new spoke" wording.

4. `schema-type-hook-coverage-gap` — for each `vault-schema.json` schema key, verifies both `pre-write-guard.sh` SCHEMA_KEY case statement AND `post-write-verify.sh` type_map carry the type. Exceptions at `doc-dependencies.json` `vault-schema-type-consistency.path_inferred_exceptions[]`. Fields: `schema_key`, `missing_in` (one or both hook filenames), `remediation`.

**Persistent IDs (reconciled every run):**
- `DC-NNN` — provides canonicality drift (matched by `capability`)
- `SM-NNN` — size monitoring (matched by `file`)
- `ST-NNN` — schema-type hook coverage gap (matched by `schema_key`)

Matched rows retain `first_seen`. New rows append with next sequence number. Resolved rows drop out on the observing run. Written atomically via `manifest_set` to `drift_findings.{provides_canonicality|size_monitoring|schema_type_coverage}` arrays.

**Env overrides (testing):** `FM_VAULT_SCHEMA`, `FM_PRE_WRITE_GUARD_OVERRIDE`, `FM_POST_WRITE_VERIFY_OVERRIDE`, `FM_DRIFT_ALLOWLIST_FILE_OVERRIDE`, `FM_DOC_DEPENDENCIES_OVERRIDE`, `MANIFEST_PATH`, `FINDINGS_OUTPUT`.

**Extraction baselines & tests:** pre-extraction `drift_findings` snapshot at `~/.claude-plans/63-librarian-capability-extraction/01-tier-1-high-stakes/baselines/frontmatter-enforce-pre-manifest.json`; synthetic test harness at `tests/frontmatter-enforce.sh` (16/16 pass 2026-04-21). Deviations from the legacy model-interpreted output are documented pseudocode-bug corrections per Plan 63 T-1 precedent.

---

## Capability: xref-check

**Runtime:** `~/.claude/skills/librarian/capabilities/xref-check.sh` (extracted from pseudocode 2026-04-21 via Plan 63 Sub-plan 02 T-3; sources `lib/findings.sh` + `lib/manifest.sh`).

**Purpose:** Detect broken wikilinks, orphaned files, and stale People cross-references. Writes `xref_graph` manifest subtree.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/xref-check.sh [--full|--recent|--scope <path>] [--include-logs]
```

| Flag | Effect |
|------|--------|
| `--recent` | Files modified in last 7 days (default). |
| `--full` | Entire vault. |
| `--scope <path>` | Single file or directory subtree. |
| `--include-logs` | Include `Logs/` in orphan detection (default: excluded). |

**Wikilink regex:** `\[\[([^\]|]+)(\|[^\]]+)?\]\]`. Supports `[[Target]]` + `[[Target|Display]]` + `[[path/Target]]` + `[[Target#anchor]]`.

**Resolution:** target basename (stem, lowercase) looked up in vault-wide index; first-match wins.

**Finding classes:**

| Finding | Level | Meaning |
|---|---|---|
| `xref-broken-link` | error | Target `.md` not found anywhere in vault. |
| `xref-people-one-way` | warn | File in `*/People/*.md` references another People file without reciprocal back-ref. |
| `xref-orphan` | info | File has zero inbound links. Excluded by default: `CLAUDE.md`, `_index.md`, `File-Index.md`, `Vault Architecture.md`, `Tasks.md`, `Archive/**`, `Logs/**`. |

**Manifest write:** `xref_graph` subtree via `manifest_set` (entire replacement — resolved-row drop-out pattern per T-2 precedent). Fields: `last_scan`, `total_files`, `scoped_files`, `broken`, `people_oneway`, `orphan`.

**Env overrides (testing):** `VAULT_ROOT_OVERRIDE`, `XREF_SCOPE`, `MANIFEST_PATH`, `FINDINGS_OUTPUT`.

**Exit codes:** `0` success, `2` unknown flag, `3` vault root not found.

**Output Format:**

```
## Cross-References ({N} issues)

- Files scanned: {scoped} / {total} total
- Broken wikilinks: {count}
- People one-way refs: {count}
- Orphans (info): {count}
```

**Tests:** `~/.claude-plans/63-librarian-capability-extraction/02-tier-2-mid-tier/tests/xref-check.sh` — 14/14 pass (happy path cross-link, broken wikilink, alias-style resolution, orphan detection, orphan exclusions for CLAUDE.md/_index.md/Logs, unknown-flag exit 2, manifest subtree persistence, `--scope` single-file).

**Pseudocode-bug correction (extraction time):** SKILL.md legacy pseudocode invoked multiple `echo $RESULT | python3 -c` + `echo $RESULT | python3 - <<PY` subshells. The heredoc-script + stdin-pipe combination silently empties stdin under some bash/python3 combos (python consumes the heredoc AS stdin, ignoring the pipe). Replaced with a single argv-based Python pass returning a multi-line summary + JSON blob. Caught by test Scenario 7 (manifest subtree wrote empty-string `"xref_graph": ""` on first run).

---

## Capability: drift-sweep

**Purpose:** Weekly full-vault frontmatter drift scan against `vault-schema.json`. Supplemental to write-time hooks (pre-write-guard R-32 + post-write-verify) — drift-sweep catches files that escaped write-time checks (cascade waivers, pre-allowlist writes, files touched outside the hook path).

**Scope:** all `.md` files under vault root, excluding `.claude/projects/*` (auto-memory) and `_test*` (scratch).

**Flags:**
- `--dry-run` — default. Emits structured ndjson findings without modifying files.
- `--live` — cron mode; same behavior as dry-run (no auto-fix), but suppresses progress stderr.
- `--batch-size N` — progress emit every N files (default 50). Resets stream-json 180s idle watchdog.
- `--output <path>` — write findings ndjson to file (cron mode passes `$CAP_LOG`).

**Implementation:** `~/.claude/skills/librarian/capabilities/drift-sweep.sh`. Bash 3.2 clean (R-23). Emits `unregistered_type` and `missing_required` findings.

**Cron wiring:** Monday-only block in `~/.claude/orchestrator/cron-wrappers/librarian-cron.sh`. Non-blocking (`ANY_FAIL` is not flipped on drift-sweep failure). Timing (spine-remediation-followup Phase 4 P4-T04): 884 files / 35.4s / 17 progress emits / worst-case idle 1.9s — ~95× headroom under the 180s stream-json watchdog.

**Finding classes:**
- `unregistered_type` — `type:` value not in the 24-value R-32 allowlist
- `missing_required` — required fields (per vault-schema.json) missing

Findings are weekly-review material, not write-time advisories. Human resolution path: add type to schema + hooks + CLAUDE.md (R-37 lockstep) OR correct the file.

---

## Capability: people-audit

**Purpose:** Weekly audit of `*/People/*.md` frontmatter + `## Context` H2 section conformance. Moved here from `post-write-verify.sh` because C's research measured a 28% false-positive rate at write-time (disqualifying host). Periodic audit tolerates the noise and still surfaces actionable findings.

**Scope:** all `*/People/*.md` under vault root.

**Exemptions:** Engagements whose Overview/_index/CLAUDE.md carries `status: complete|archived|historical|closed` are skipped. Auto-discovered — no hardcoded engagement list. (Tiffany + Walmart Digital Partnership are currently auto-exempted per their Overview `status: complete`.)

**Checks:**
1. Required `people` fields: `name`, `org`, `role`, `engagement`, `updated`, `tags` (per `vault-schema.json`).
2. `^## Context` H2 present in first 2KB of body.

**Flags:**
- `--batch-size N` — progress emit every N files (default 50).
- `--output <path>` — write findings ndjson to file.

**Implementation:** `~/.claude/skills/librarian/capabilities/people-audit.sh`. Bash 3.2 clean. Runtime 0.6s on 30 files (P4-T03 smoke test).

**Cron wiring:** Monday-only block in `librarian-cron.sh`, alongside `drift-sweep`. Zero write-time noise — standalone shell, never hook-invoked.

**Finding class:** `people_non_conforming` with `file` + `issues` (pipe-joined `missing_required:<fields>` and/or `missing_context_section`).

---

## Capability: waiver-audit

**Purpose:** Audit two bypass surfaces for abuse, ad-hoc use, and cluster-to-rule candidates: (a) `~/.claude/hooks/state/cascade-waivers.json` (R-07 waivers) and (b) `~/Desktop/artefact-daily-logs/hook-audit.log` override fires (R-24 `CLAUDE_MEM_DISABLE_OK`, R-27 `PLAN_STATUS_OK`). Observational — emits findings, never blocks. Enforces R-46 (ENFORCEMENT-MAP).

**Scope:** all waivers in the canonical + 4 historical drift shapes; all override fires in the hook-audit log.

**Flags:**
- `--scope {all|waivers|overrides}` — narrow audit surface (default `all`)
- `--report <path>` — write markdown summary report
- `--dry-run` — summary counts to stdout only (no emission)

**Classification buckets (waivers):**
- `legitimate` — reason matches standing legit markers (R-37 lockstep, mechanical backfill, additive-only, SCHEMA_KEY, type: log, etc.)
- `ad-hoc` — reason lacks legit markers OR entry_id not in `~/.claude/hooks/doc-dependencies.json` registry
- `abuse` — empty reason, <30 char reason without legit marker, OR identical reason repeated across ≥3 sessions for the same entry_id
- `stale` / `unclassifiable` — reserved for future TTL + edge-case taxonomy (neither fires in v1)

**Abuse signatures (overrides):**
- `override-rate-warning` — ≥3 override fires on the same calendar date (day is proxy for session since hook-audit.log has no session id)

**Implementation:** `~/.claude/skills/librarian/capabilities/waiver-audit.sh`. Bash 3.2 clean. Read-only against `cascade-waivers.json` (the canonical writer is `~/.claude/hooks/lib/cascade-waiver.sh`, shipped 2026-04-20 Phase-0 Fix 1). Baseline preservation: the capability refuses to write to any `cascade-waiver-audit-*.md` path (Plan 65 T-1 baseline at `Logs/cascade-waiver-audit-2026-04-20.md` is immutable Sub-plan 05 evidence).

**Env overrides (testing):** `CASCADE_WAIVER_PATH`, `HOOK_AUDIT_LOG`, `DOC_DEP_FILE`, `FINDINGS_OUTPUT`.

**Cron wiring:** Monday-only block in `librarian-cron.sh`, alongside `drift-sweep` and `people-audit`. Zero write-time noise.

**Finding classes:** `waiver-abuse`, `waiver-ad-hoc`, `waiver-registry-rule-candidate`, `override-fire`, `override-rate-warning`.

**Landed:** Plan 64 Sub-plan 02 T-1 (2026-04-20). 17/17 synthetic tests pass (`~/.claude-plans/64-enforcement-gap-systematic-audit/02-bypass-audit-capability/tests/synthetic-waiver-audit.sh`).

**Enforcement layer for:** ENFORCEMENT-MAP R-46, R-48, R-49, R-50 (Plan 64 Sub-plan 02 added R-46; follow-up rules landed alongside waiver-audit).

---

## Capability: tag-coverage-audit

**Runtime:** `~/.claude/skills/librarian/capabilities/tag-coverage-audit.sh` (Plan 59 T-1, 2026-04-19; sources `~/.claude/hooks/lib/paths.sh` + `lib/plan-path.sh` + `lib/findings.sh` + `lib/frontmatter.sh`).

**Purpose:** Vault-wide tag coverage + taxonomy compliance audit. Measures presence of `tags:` frontmatter field, classifies tags against the canonical allowlist (`vault-schema.json` `_tag_prefixes`), and flags residual `#type/*` references remaining after the 2026-04-17 R-37 lockstep `type:` elimination.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/tag-coverage-audit.sh [--scope <section>] [--batch-size N] [--output <file>] [--verbose]
```

| Flag | Effect |
|------|--------|
| `--scope <section>` | Override vault-subtree root. Default: full vault walk. |
| `--batch-size N` | Progress emit every N files (default 100). |
| `--output <file>` | Write NDJSON findings to file instead of stdout. |
| `--verbose` | Emit per-file diagnostic lines during walk. |

**Scope:** VAULT-ONLY v1 (Plan 59 vault-only scope per Peter 2026-04-19). `$PLANS_DIR` + `Plans/` symlinks exempted (plans-folder tag dimensions are a Q3 follow-up).

**Exempt surfaces (do NOT flag):**
- `Archive/**`, `Tags/**`, `_test*`
- `Logs/ideation-brief-*.md` (symlinks to `~/.claude-plans/`)
- `.claude/projects/**` (auto-memory; separate schema domain)
- `.claude/skills/**` (mirrored skill specs; separate schema domain — added 2026-04-22)
- Root navigation: `CLAUDE.md`, `Vault Architecture.md` (untagged-navigation convention, added 2026-04-21)
- Plan-root files + any depth ≥2 under `$PLANS_DIR`
- `Logs/foundations-essays/**` and `Logs/backlog-progress/**` are **no longer exempt** (2026-04-21 exhaustive backfill; `#log/{log-type}` mirrors frontmatter `log-type:`)

**Canonical tag-prefix allowlist (L83 in runtime):** `engagement/`, `project/`, `scope/`, `status/`, `initiative/`, `artefact-bd/`, `about-me/`, `log/`. Runtime uses the post-elimination canonical list so residual `#type/*` is correctly flagged as `historical_type_residual` even while `vault-schema.json._tag_prefixes` still carries stale `type` pending T-2 lockstep removal. Note: Agent C patched `frontmatter-enforce.sh` L255 TAG_PREFIXES on 2026-04-22 to add `about-me/` + `log/` — keep these two lists mirrored.

**Finding classes:**
- `missing_tags_field` — no `tags:` field at all
- `empty_tags_field` — `tags: []`
- `unrecognized_tag_prefix` — tag prefix not in canonical allowlist
- `historical_type_residual` — special case for residual `#type/*` (emitted in addition to `unrecognized_tag_prefix`, for T-5 migration tracker consumption)

**Lifecycle events (via `emit_event`):** `tag_coverage_audit_start`, `progress` every `BATCH_SIZE` files, `tag_coverage_audit_end` carrying `files_scanned`, `findings`, `missing_tags_count`, `empty_tags_count`, `unrecognized_tag_count`, `historical_type_residual_count`.

**Env overrides (testing):** `VAULT_ROOT`, `PLANS_DIR`, `FINDINGS_OUTPUT`.

**Cron wiring:** Monday-only block in `librarian-cron.sh`, alongside `drift-sweep`, `people-audit`, `waiver-audit`, `trinity-drift-detect`. Read-only; no write-time integration.

---

## Capability: wikilink-repair

**Runtime:** `~/.claude/skills/librarian/capabilities/wikilink-repair.sh` (Plan 59 T-3, 2026-04-20 — parallel session with T-5; sources `lib/findings.sh` + Plan 61 `lib/plan-path.sh`).

**Purpose:** Detect broken `[[wikilinks]]` across the vault and propose repairs seeded from the `doc-dependencies.json` registry. **No heuristic / fuzzy match** — a broken target with no registry seed is logged as `broken-wikilink` for manual triage.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/wikilink-repair.sh [--apply] [--scope <path>] [--report <path>]
```

| Flag | Effect |
|------|--------|
| (default) | Dry-run; emit findings to stdout / `FINDINGS_OUTPUT`. |
| `--apply` | Rewrite repairable wikilinks (explicit opt-in per batch). |
| `--scope <path>` | Limit walk to a vault subtree. |
| `--report <path>` | Write markdown summary report. |
| `--dry-run` | Accepted for CLI-contract symmetry (no-op default). |

**Repair-seed policy:**
- Propose a repair ONLY when the broken wikilink's target basename exactly matches the basename of a `primary` or `mirrors[]` entry in `~/.claude/hooks/doc-dependencies.json`. The registry is rename-aware (see `rename-history-sync` for how entries are updated).
- Multiple candidates: logged with `ambiguous` flag; no auto-repair.

**Scope exclusions:** `Archive/`, `Logs/foundations-essays/`, `Logs/backlog-progress/`.

**Finding classes:** `broken-wikilink`, `wikilink-repair-proposed`, `wikilink-ambiguous`, `wikilink-repair-applied` (only under `--apply`).

**Env overrides (testing):** `VAULT_ROOT`, `DOC_DEP_FILE`, `FINDINGS_OUTPUT`.

**Exit codes:** `0` success, `2` unknown flag. Defensive — never fails on missing files or parse errors; emits warning findings instead.

---

## Capability: rename-detect

**Runtime:** `~/.claude/skills/librarian/capabilities/rename-detect.sh` (Plan 67 Sub-plan 02 T-1, 2026-04-22; sources `lib/findings.sh`, optionally `lib/manifest.sh` under `--register`).

**Purpose:** Detect file renames by scanning `git log --diff-filter=R --name-status -M90` across the vault + plans repos over a time window (default last 24h). Emits one NDJSON record per rename. **Upstream signal** for `rename-cascade` — pipe-composable.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/rename-detect.sh [--since <iso8601>] [--root <path>] [--register] [--min-similarity <int>]
```

| Flag | Effect |
|------|--------|
| `--since <spec>` | Override default `"24 hours ago"` (any git-parsable spec). |
| `--root <path>` | Override configured roots (repeatable). |
| `--register` | Also append findings via `manifest.sh` into `drift_findings.rename_detected`. |
| `--min-similarity <int>` | Filter by git R-score (default `0` = all). |

**Output NDJSON shape:**

```json
{"root":"...","old_path":"...","new_path":"...","commit_sha":"...","committed_at":"<ISO8601>","similarity":95}
```

**Default roots:** `$VAULT_ROOT`, `$PLANS_DIR` (git repos only; non-git roots silently skipped). Override via `RENAME_DETECT_ROOTS` env (colon-separated).

**Pipe composition:** `rename-detect.sh | rename-cascade.sh` (dry-run cascade) or `rename-detect.sh | rename-history-sync.sh append` (registry update).

**Env overrides (testing):** `RENAME_DETECT_ROOTS`, `FINDINGS_OUTPUT`.

**Exit codes:** `0` on success or empty-window (no-op is not a failure), `2` unknown flag.

**Session-close integration:** Step 2b (Plan 67 SP02 T-4). See session-close chain below.

---

## Capability: rename-cascade

**Runtime:** `~/.claude/skills/librarian/capabilities/rename-cascade.sh` (Plan 67 Sub-plan 02 T-2, 2026-04-22). Consumes `rename-detect` NDJSON on stdin; rewrites inbound references. Stdin capture pattern avoids the `python3 heredoc` stdin-swallow bug (`feedback_python_heredoc_argv.md`).

**Purpose:** Apply the rename cascade — update inbound `[[wikilinks]]`, optionally frontmatter path refs (`spec_path`, `handoff_path`, `ideation_brief_path`, `tasks_path`), and `parent_plan:` slugs when a plan directory is renamed.

**Invocation:**

```
rename-detect.sh | rename-cascade.sh                          # dry-run
rename-detect.sh | rename-cascade.sh --apply                  # writes changes
rename-detect.sh | rename-cascade.sh --include-frontmatter    # include path-valued frontmatter + parent_plan
```

| Flag | Effect |
|------|--------|
| (default) | Dry-run; propose replacements. |
| `--apply` | Rewrite files. |
| `--include-frontmatter` | Also scan `.md` frontmatter for path-valued keys + `parent_plan:` slug rewrites (scope-guarded to `$PLANS_DIR`). |
| `--scope <path>` | Override scan root (repeatable). |
| `--dry-run` | Accepted for CLI-contract symmetry. |

**Behavior per stdin NDJSON record:**
1. **Wikilink mode (always):** scan vault + plans for inbound `[[<old_basename>]]`, `[[<old_basename>|alias]]`, `[[<old_basename>#heading]]` (with or without `.md` suffix). Propose replacement to `new_basename`.
2. **Frontmatter mode (`--include-frontmatter`):** scan `.md` frontmatter for path-valued keys equal to `old_path`. Propose path update.
3. **`parent_plan:` slug mode (inside `--include-frontmatter`):** when a plan directory is renamed (e.g. `67-old/` → `67-new/`), derive the slug pair (strip leading `NN-` prefix) and rewrite child-file `parent_plan: <old-slug>` values to `parent_plan: <new-slug>`. Scope-guard: only acts when the renamed path is under `$PLANS_DIR`.

**Env overrides (testing):** `RENAME_CASCADE_SCOPES` (colon-separated; default `$VAULT_ROOT:$PLANS_DIR`), `FINDINGS_OUTPUT`.

**Exit codes:** `0` success, `2` unknown flag. Empty stdin is a valid no-op.

**Session-close integration:** Step 2b runs `rename-detect | rename-cascade` in dry-run only — `--apply` is human-initiated.

---

## Capability: rename-history-sync

**Runtime:** `~/.claude/skills/librarian/capabilities/rename-history-sync.sh` (Plan 67 Sub-plan 02 T-3, 2026-04-22).

**Purpose:** Maintain the `rename_history[]` field on `~/.claude/hooks/doc-dependencies.json`. Two idempotent sub-commands.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/rename-history-sync.sh migrate
bash ~/.claude/skills/librarian/capabilities/rename-history-sync.sh append < <rename-detect-ndjson>
```

| Sub-command | Effect |
|-------------|--------|
| `migrate` | Add empty `rename_history: []` to any entry missing it. Idempotent. |
| `append` | Read `rename-detect` NDJSON from stdin; append each matching `{from, to, at, commit}` row to the entry whose `primary` or `mirrors[].file` basename matches the `old_path`. |

**Env overrides (testing):** `DOC_DEP_FILE` (default `~/.claude/hooks/doc-dependencies.json`).

**Exit codes:** `0` success, `2` missing registry file.

**Session-close integration:** Step 2b runs `rename-detect | tee (rename-history-sync append) | rename-cascade`. Downstream consumer: `wikilink-repair` uses the rename-aware registry as its sole repair source.

---

## Capability: trinity-drift-detect

**Runtime:** `~/.claude/skills/librarian/capabilities/trinity-drift-detect.sh` (Plan 67 Sub-plan 04 T-1, 2026-04-22; sources `~/.claude/hooks/lib/paths.sh` + `lib/findings.sh`). Addresses the drift class caught by the 2026-04-21 validation audit: sub-plan spec/manifest declared `status: complete`, but tasks.md ledger lagged with `not-started`/`in-progress` per-task statuses, masking incomplete work as complete.

**Purpose:** Detect disagreement between `spec.md` / `manifest.json` / `tasks.md` / per-task T-N statuses across plan-root and sub-plan-root directories.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/trinity-drift-detect.sh [--scope <path>] [--dry-run]
```

| Flag | Effect |
|------|--------|
| (default) | Full walk of `$PLANS_DIR`; emit findings to `$FINDINGS_OUTPUT` or stdout. |
| `--scope <path>` | Limit walk root. |
| `--dry-run` | Summary counts only; no emission. |

**Walk scope:**
- Depth 2: `~/.claude-plans/<plan>/{spec.md,manifest.json,tasks.md}`
- Depth 3: `~/.claude-plans/<plan>/<subplan>/{spec.md,manifest.json,tasks.md}`

For every directory containing BOTH `spec.md` and `manifest.json`, compare `spec` `status:`, `manifest` `.status`, `tasks.md` frontmatter `status:`, and per-task `**Status:**` values (T-1, T-2, ...).

**Emission rules (NDJSON via `emit_finding`):**
- `spec-manifest-divergence` — `spec.status != manifest.status`
- `trinity-task-ledger-lag` — `manifest.status=complete` AND any `T-N.status != done`
- `header-trinity-divergence` — `spec.status=complete` AND `tasks.status=planned`
- `parse-failure` — emitted as fallback on malformed files; walk continues

**Tolerated non-drift (no emission):**
- All-in-progress (mid-execution valid state)
- manifest / spec / tasks all agree (aligned)
- `manifest.complete` but no `tasks.md` present (flat plan)

**Finding payload:**

```json
{"finding":"trinity-status-drift","file":"<plan-rel>","drift_class":"<class>",
 "spec_status":"...","manifest_status":"...","tasks_status":"...",
 "task_ledger":[{"id":"T-1","status":"not-started"}, ...],
 "detected_at":"<ISO8601>"}
```

**Env overrides (testing):** `PLANS_DIR`, `FINDINGS_OUTPUT`.

**Exit codes:** `0` success, `2` unknown flag or scope not a directory.

**Session-close integration:** Step 2d. Also fires in the Monday-only `/librarian full` cron block alongside `drift-sweep`, `people-audit`, `waiver-audit`, `tag-coverage-audit`.

**Complementary to:** `stale-detect` Check #8 (same drift class surfaces there as `trinity-lag` category, plan-root scope only); `trinity-drift-detect` adds the broader divergence classes + sub-plan-root walk.

---

## Capability: log-archive

**Runtime:** `~/.claude/skills/librarian/capabilities/log-archive.sh` (extracted from pseudocode 2026-04-21 via Plan 63 Sub-plan 02 T-1; sources `~/.claude/hooks/lib/paths.sh` + `lib/findings.sh` + `lib/dates.sh` — `lib/dates.sh` co-shipped in the same commit). Note: `paths.sh` lives under `~/.claude/hooks/lib/`, not `librarian/lib/`; librarian's own `lib/plan-path.sh` is a separate helper for plan-root detection.

**Purpose:** Archive old top-level Logs/ files to `Archive/Logs/{YYYY}-W{WW}/` per retention thresholds. Never deletes — only `mv`.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/log-archive.sh [--dry-run | --execute]
```

| Flag | Effect |
|------|--------|
| `--dry-run` | Preview only (default when run as part of `/librarian`). |
| `--execute` | Move eligible files. |

**Thresholds:**
- Dashboard-sync logs (filename contains `dashboard-sync`): older than **3 days**
- General logs: older than **7 days**

**Scope rules (scope-hardening vs legacy pseudocode):**
- Top-level `*.md` in Logs/ only. Subdirectories (`backlog-progress/`, `foundations-essays/`, etc.) preserved.
- Symlinks skipped (`ideation-brief-*.md` symlinks point to `~/.claude-plans/` canonical files — must not be moved).
- Files without a `YYYY-MM-DD` in their filename stay in place (non-dated content in Logs/ is a placement-validate concern, not a log-archive concern).

**Env overrides (testing):** `LOG_ARCHIVE_SOURCE` (default `$VAULT_LOGS`), `LOG_ARCHIVE_TARGET` (default `$VAULT_ROOT/Archive/Logs`).

**Exit codes:** `0` success, `2` unknown flag, `3` source dir missing.

**Output Format:**

```
## Logs (X archived, Y remaining) [dry-run if applicable]

- Moved {N} files to Archive/Logs/
- Created folders:
  - Archive/Logs/{YYYY}-W{WW}/
- Files archived:
  - {filename} → Archive/Logs/{YYYY}-W{WW}/
- Remaining in Logs/: {N} files (within retention window)
```

**Tests:** `~/.claude-plans/63-librarian-capability-extraction/02-tier-2-mid-tier/tests/log-archive.sh` — 19/19 pass 2026-04-21 (happy path, threshold boundaries, symlink skip, non-dated preservation, dry-run no-op + lib/dates.sh direct smoke tests).

---

## Capability: stale-detect

**Runtime:** `~/.claude/skills/librarian/capabilities/stale-detect.sh` (extracted from pseudocode 2026-04-20 via Plan 63 Sub-plan 01 T-4; sources `lib/manifest.sh` + `lib/plan-path.sh` + `lib/findings.sh`). Plan 67 Sub-plan 04 T-2 (2026-04-22) added **Check #8** (trinity-lag) without disturbing the 7-rule pseudocode contract.

**Purpose:** Identify files that may need attention based on age or missing processing.

### Staleness Rules

| File Type | Stale Condition |
|-----------|----------------|
| Daily notes | `processed: false` and older than 2 days |
| People files | `<!-- TODO: enrich context -->` marker present |
| People files | No Timeline entry in last 30 days (active engagement only) |
| Project files | `updated` older than 14 days (active projects only) |
| Meeting notes | `processed: false` |
| Logs | Older than 7 days and still in `Logs/` |
| Plan files (`$PLANS_DIR/**`) | Case-insensitive match on `status:\s*(complete\|completed\|implemented\|done)` in YAML frontmatter OR `\*\*Status:\*\*\s*(Complete\|COMPLETE\|Completed\|Implemented\|Done)` header bullet (corpus uses all five forms; Session 17 stale-detect run verified), AND no evidence of verification. Verification evidence is any one of: (a) `last_verified: <ISO date>` in YAML frontmatter within 14 days, (b) `**Last Verified:** <ISO date>` header bullet within 14 days (header-bullet style matches the `**Status:**` style plans already use), (c) sibling `handoff.md` with a non-empty acceptance-criteria section. Enforcement layer for R-16 (Session 05 / spine-remediation Session 16; regex + header-bullet support added in Session 17 Module A2). |
| Plan trinity (`$PLANS_DIR/**`) | **Check #8 (Plan 67 SP04 T-2, 2026-04-22).** `manifest.json.status == "complete"` AND any per-task `**Status:**` value in sibling `tasks.md` lags (`not-started`, `in-progress`, `blocked`, `pending`, `planned`). Emits category `trinity-lag` with the lagging T-N list. Complementary to `trinity-drift-detect` (which surfaces the same class as a standalone finding + broader spec/manifest/tasks divergence classes). |

### Process

1. Scan all files in scope
2. Parse frontmatter for `updated`, `processed`, `status` fields
3. For People files, also scan body for TODO markers and Timeline dates
4. Apply staleness rules per file type
5. Skip completed engagements, archived files, and non-content files
6. For plan files under `$PLANS_DIR`: **scope is plan-root files ONLY** — the same set enforced by R-27 pre-write-guard (flat root `*.md`, `*/spec.md`, `*/00-ideation-brief.md`, `*/README.md`, `*/manifest.json`). **Sub-task files at depth ≥ 2** (e.g. `32-autonomous-project-orchestration/32a-*.md`, `34-digest-synthesis-intelligence/tasks.md`, `*/phase*.md`, `*/test-results.md`) and orchestrator artifacts (`*/_orchestrator/**`) are **explicitly excluded** — they inherit status from the parent plan rather than carrying independent completion markers. Scope rewritten in spine-remediation Session 22 to eliminate the sub-task false-positive class (10 findings filed Session 21). Case-insensitive check for ANY of these completion markers — frontmatter `status:\s*(complete|completed|implemented|done)`, OR header bullet matching `\*\*Status:\*\*\s*(Complete|COMPLETE|Completed|Implemented|Done)`. If a completion marker exists, check for any one of these verification evidence forms:
   - `last_verified: <ISO date>` in YAML frontmatter within 14 days, OR
   - `**Last Verified:** <ISO date>` header bullet within 14 days (mirrors the `**Status:**` header-bullet style most legacy plans use — Session 17 discovered plans don't have YAML frontmatter, only markdown header blocks), OR
   - A sibling `handoff.md` file with non-empty acceptance-criteria evidence section.

   If no verification evidence exists, emit stale-detect finding `stale-status-no-evidence` with plan slug and resolution hint ("add `last_verified:` frontmatter OR `**Last Verified:**` header bullet with today's ISO date, OR attach sibling `handoff.md` with acceptance-criteria section"). Category: `stale-status`. This is the enforcement layer for ENFORCEMENT-MAP R-16 (plans marked complete without evidence). Regex + header-bullet support added by Session 17 Module A2; scope tightened to plan-root only in Session 22.

### Output Format

```
## Stale Content (X items)

| File | Reason | Category |
|------|--------|----------|
| {path} | `updated` 21 days old (active project) | stale |
| {path} | No Timeline entry since 2026-02-15 | stale |
| {path} | Contains <!-- TODO: enrich context --> | todo |
| {path} | Log file, 12 days old | archive-candidate |
| {plan-slug} | completion marker (frontmatter `status: complete\|completed\|implemented\|done` or `**Status:**` header bullet) without `last_verified` frontmatter, `**Last Verified:**` header bullet, or linked `handoff.md` | stale-status |
```

---

## Capability: placement-validate

**Purpose:** Check that every file is in the correct location per the routing rules.

**Flags:**
- `--scope {path}` — check specific directory
- `--full` — entire vault (default)

### Rules

1. **Vault root** may only contain: `CLAUDE.md`, `Vault Architecture.md`, `Tasks.md`
2. **Project folders** should only contain files matching `{Project} - *.md` plus `_index.md` and `File-Index.md` (navigation/reference scaffolding — see Index File Convention below)
3. **People files** must be in `Engagements/*/People/` folders
4. **Meeting notes** must be in `Meetings/`
5. **Engagement root** should only contain the 4 standard files + CLAUDE.md + `_index.md` + `File-Index.md` + `.DS_Store`. (See Vault Architecture.md for `File-Index.md` — auto-maintained by digest-run as the fallback link-routing destination when project is ambiguous.)
6. **Reference/ (Tier 1)** should not contain engagement-specific files
7. **Logs/** is for dated operational logs only. Allowed patterns: dated logs matching `{log-type}-{date}-*.md` (e.g., `digest-*`, `session-auto-close-*`, `librarian-cron-error-*`), `build-*.md` build session records, and `ideation-brief-*.md` (vault-visibility symlinks or pending-retrofit files — canonical location is `~/.claude-plans/{slug}/00-ideation-brief.md`, see `project_backlog_cron_brief_paths.md` memory). No other content files in `Logs/`, `Archive/`, `.obsidian/`, `.git/`, `.claude/`.

### Index File Convention

`_index.md` is a folder-navigation artifact used at engagement roots, project roots, and People/ subfolders to improve Claude Code's filesystem traversal efficiency. It is always allowed and should not be flagged.

`File-Index.md` is a scaffolding file that houses external resource links (SharePoint, Google Drive, Excel) and file paths. It exists at project roots (`Engagements/*/Projects/*/File-Index.md`) for workstream-scoped links and at engagement roots (`Engagements/*/File-Index.md`) as the fallback destination for digest-run Phase 2.5 when links can't be clearly routed to a project. See `~/.claude/skills/digest-run/SKILL.md` Phase 2.5 and Vault Architecture.md.

`ideation-brief-*.md` in `Logs/` is load-bearing infrastructure for the autonomous orchestration workflow — see `project_backlog_cron_brief_paths.md` and `project_autonomous_orchestration.md`. Never relocate, delete, or enforce log-frontmatter schema on these files. Canonical location is `~/.claude-plans/{slug}/00-ideation-brief.md`; the `Logs/` path is a symlink (or a pending-retrofit regular file awaiting T-8 in `vault-workflow-restructure`). Frontmatter-enforce must skip files matching `Logs/ideation-brief-*.md`.

### Process

1. Scan each directory per rules above
2. Flag any file that violates its directory's rules
3. Suggest correct location based on Routing Decision Tree

### Output Format

```
## Placement (X issues)

| File | Issue | Suggested Location | Classification |
|------|-------|--------------------|---------------|
| {path} | File at vault root | {suggested} | auto-fix |
| {path} | Non-project file in project folder | {suggested} | manual |
```

---

## Capability: sync-check

**Runtime:** `~/.claude/skills/librarian/capabilities/sync-check.sh` (extracted from pseudocode 2026-04-21 via Plan 63 Sub-plan 01 T-3; sources `lib/findings.sh` + `lib/manifest.sh`).

**Purpose:** Cross-domain consistency between backend (`~/.claude/`) and vault (`~/Documents/Obsidian Vault/`). Deterministic checklist of known relationships — not agent-based discovery.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/sync-check.sh [--scope <group|check-name>] [--check|--fix] [--dry-run]
```

| Flag | Effect |
|------|--------|
| `--scope <group>` | One of `backend`, `vault`, `cross`, or `all` (default). |
| `--scope <check-name>` | Single-check filter (`skill-runtime`, `skills-index`, `memory-paths`, `root-claude-md`, `vault-claude-md`, `vault-architecture`, `engagement-status`). |
| `--check` | Report only (default). |
| `--fix` | Auto-apply auto-fix class: copy backend SKILL.md → vault mirror for hash-mismatches; rewrite `status:` in engagement CLAUDE.md to match Overview. |
| `--dry-run` | Summary counts only. |

**The seven checks (grouped):**

**backend group (1–4):**
1. **skill-runtime** — hash compare `~/.claude/skills/{X}/SKILL.md` vs vault copy at `.claude/skills/{X}.md`. Auto-fix: copy backend → vault.
2. **skills-index** — every backend skill has a row in `Skills/_index.md`; every index row points to a spec. Manual (new skill → needs design spec).
3. **memory-paths** — memory files' filesystem path references resolve. Auto-fix: flag stale references.
4. **root-claude-md** — referenced absolute paths in `~/.claude/CLAUDE.md` resolve. Auto-fix or manual.

**vault group (5–6):**
5. **vault-claude-md** — engagement list matches `Engagements/*/` dirs. Missing: folder exists but not documented; stale: documented but folder missing. Manual.
6. **vault-architecture** — directory tree in VA.md matches filesystem. Manual.

**cross group (7):**
7. **engagement-status** — status in vault CLAUDE.md marker + engagement `CLAUDE.md` + engagement `* - Overview.md` frontmatter all agree. **Overview is source of truth.** Auto-fix: rewrite CLAUDE.md `status:` to match Overview.

**Persistent IDs:** `S-NNN`. Matched across runs by `(check, subject)`; `first_seen` preserved; resolved rows drop out. Persisted at `drift_findings.sync_check[]` via `manifest_set`.

**Env overrides (testing):** `SC_BACKEND_ROOT`, `SC_MEMORY_ROOT`, `SC_ROOT_CLAUDE_MD`, `SC_VAULT_CLAUDE_MD`, `SC_VAULT_ARCH_MD`, `SC_SKILLS_INDEX`, `MANIFEST_PATH`, `FINDINGS_OUTPUT`.

**Tests:** `~/.claude-plans/63-librarian-capability-extraction/01-tier-1-high-stakes/tests/sync-check.sh` — 12/12 pass 2026-04-21 (--scope backend/vault/cross + persistent S-NNN IDs across runs).

---

## Capability: backup

**Runtime:** `~/.claude/skills/librarian/capabilities/backup.sh` (extracted from pseudocode 2026-04-21 via Plan 63 Sub-plan 02 T-2).

**Purpose:** Git add/commit/push across tracked directories. Mechanical close-the-loop. Graceful degradation on push failure (logged, never retried, exit 0).

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/backup.sh [--dry-run] [--scope <dir>] [--message <msg>]
```

| Flag | Effect |
|------|--------|
| `--dry-run` | Preview changes + proposed message; no writes. |
| `--scope <dir>` | Restrict to one directory; overrides default set + `BACKUP_TARGETS`. |
| `--message <msg>` | Override the auto-generated `librarian: {N} files` commit message. |

**Default targets (skipped if not a git repo):** `$VAULT_ROOT`, `~/artefact-dashboard`, `$CLAUDE_HOME` (`~/.claude/`), `$PLANS_DIR` (`~/.claude-plans/`). Override via `BACKUP_TARGETS` env (colon-separated) for testing.

**Vault filter:** `.obsidian/workspace.json` is reset from stage before commit (high-noise churn file).

**Exit codes:** `0` always (best-effort; push failures reported but non-fatal), `2` unknown flag.

**Output Format:**

```
## Backup [(dry-run)]

- {dir}: {N} files committed, pushed
- {dir}: {N} files committed, push failed (reported, not retried)
- {dir}: no changes
- {dir}: not a git repo, skipped
```

**Tests:** `~/.claude-plans/63-librarian-capability-extraction/02-tier-2-mid-tier/tests/backup.sh` — 13/13 pass (clean tree, dirty tree dry-run, dirty tree live commit, push failure graceful, unknown-flag exit 2, `--message` override, `--scope` precedence, non-git skip).


---

## Capability: plan-index

**Runtime:** `~/.claude/skills/librarian/capabilities/plan-index.sh` (extracted from pseudocode 2026-04-20 via Plan 63 Sub-plan 01 T-1; co-ships with `lib/manifest.sh`).

**Purpose:** Regenerate `~/.claude-plans/_index.md` as a status-grouped navigation index. Runs during `librarian full`. Read-only walk of `~/.claude-plans/` + one atomic file write.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/plan-index.sh [--dry-run] [--parent <slug>]
```

| Flag | Effect |
|------|--------|
| `--dry-run` | Produce the target content + report counts; write nothing. |
| `--parent <slug>` | Restrict output to plans whose `parent_plan:` frontmatter chain includes `<slug>`. Shares the walker with `plan-parent-resolve` (Session 24 Phase 1). |

**Status vocabulary** (normalized by `normalize_status()` in the script):

- Active ← `planned`, `briefed`, `draft`, `in-progress`, `in_progress`, `review`, `researching`, `ready`, `active`, `approved`, `approved-*`, `partial` *(deprecated — see below)*
- Complete ← `complete`, `completed`, `done`
- On-Hold ← `on-hold`, `deferred`, `paused`
- Superseded ← `superseded`, `replaced`, `obsolete`, `absorbed`, `absorbed-by-*`
- Unknown ← anything else (slug surfaced in the `unknown_slugs` JSON field for audit).

Whitespace in raw status values is collapsed to hyphens (`"On Hold"` ↔ `on-hold`); trailing commentary after ` — ` or ` - ` is stripped.

**`partial` is deprecated.** The legacy model-interpreter invented a non-canonical `Partial` group for Plans 42 and 54 (which carry `status: partial`). Shell extraction (2026-04-20) maps `partial` to Active to preserve read behavior, but the word should be retired from plan manifests — its semantics are ambiguous (partial-complete vs partial-start vs partially-deferred). Migrate Plans 42 and 54 to `status: in-progress` at next touch; remove `partial` from the Active mapping set once both are migrated.

**Guardrails:**

- Aborts with `exit 4` if the walk finds 0 plan roots (prevents wiping `_index.md` on a misread).
- Aborts with `exit 3` if the group-count sum assertion fails.
- Atomic write via temp-file + `os.replace`; never deletes plans.
- Master-initiative whitelist (Session 22-I, TEMPORARY): `57-spine-remediation`, `58-vault-workflow-restructure` skip the prefix-conformance audit.
- Orchestrator-artifact exclusion: directories whose `manifest.json.spec_path` points outside the directory are skipped (the canonical plan is the file the spec_path references).

**Output format:** writes the composed markdown to `_index.md` (or stderr on `--dry-run`) and emits structured JSON findings + a summary object on stdout:

```json
{"plan_index_run": {"total": N, "active": a, "on_hold": h, "complete": c, "superseded": s, "unknown": u, "unknown_slugs": [...], "dry_run": bool, "parent_filter": null|str}}
```

**Target `_index.md` shape:**

```markdown
# Plan Index

_Auto-generated by `librarian plan-index`. Do not hand-edit — changes will be overwritten on the next `librarian full` run._

**Total plans:** {N}
**Last regenerated:** {YYYY-MM-DD HH:MM}

## Active ({count})
- [{slug}](./{slug}/) — {title}
...
## On-Hold ({count})
...
## Complete ({count})
...
## Superseded ({count})
...
## Unknown ({count})
_Plans missing a detectable status. Fix by adding a `**Status:**` header or `manifest.json`._
- ...
```

Sub-initiatives with internal session structure (e.g. `57-spine-remediation/`) appear once in the index under the master plan's status; internal session directories are not flattened.

**Extraction baselines & tests:** `~/.claude-plans/63-librarian-capability-extraction/01-tier-1-high-stakes/baselines/` holds pre/post `_index.md` + dual-run stdout. Deviations from the legacy model-interpreted output are documented pseudocode-bug corrections (adding `partial` to the Active vocabulary; collapsing whitespace in status-line heads; dotfile filtering at the walker).

---

## Capability: plan-parent-resolve

**Runtime:** `~/.claude/skills/librarian/capabilities/plan-parent-resolve.sh` (extracted from pseudocode 2026-04-21 via Plan 63 Sub-plan 02 T-7; sources `lib/findings.sh` + `lib/frontmatter.sh`). Enforcement layer for ENFORCEMENT-MAP R-28 (spine-remediation Session 24 Phase 1, 2026-04-14).

**Purpose:** Walk the `parent_plan:` frontmatter chain for sub-task files under `$PLANS_DIR`, resolving inherited state and detecting drift. Read-only — emits findings only; never writes.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/plan-parent-resolve.sh [--file <path>] [--parent <slug>] [--dry-run]
```

| Flag | Effect |
|------|--------|
| (no args) | Full corpus walk; emit findings + summary. |
| `--file <path>` | Single-file mode: prints resolution tag (`ok:<chain>`, `inferred:<slug>`, `broken:<slug>`, `cycle:<chain>`, `too-deep:<n>`, or `unresolvable`) to stdout. |
| `--parent <slug>` | List files whose chain includes `<slug>`. One path per line on stdout. |
| `--dry-run` | No-op — resolver is already read-only; accepted for chain-cleanliness. |

**Scope:** sub-task files at depth ≥ 3 under `$PLANS_DIR`. Exclusions (applied at scope time, not post-hoc): depth < 3 plan-root files (spec/tasks/handoff/00-ideation-brief/README/manifest), `handoff.md` at any depth, files under `tests/` and `_orchestrator/`.

**The convention:** `parent_plan:` value is the SLUG of the parent plan (no numeric prefix, no path, no extension). Per CLAUDE.md rule #5 the resolver accepts three lookup forms: direct match (`<slug>/`), flat-file plan (`<slug>.md`), and `NN-<slug>/` (prefix form).

**Findings emitted:**

| Finding | Level | Meaning |
|---|---|---|
| `parent-plan-inferred` | info | Missing field; parent derived from path top segment. |
| `parent-plan-unresolvable` | warn | Missing field; path yields no matching plan. |
| `parent-plan-broken-pointer` | warn | Chain reached a slug that resolves under none of the three lookup forms. |
| `parent-plan-cycle` | error | Visited set hit (includes self-parent). |
| `parent-plan-chain-too-deep` | error | Depth exceeded 6. |
| `parent-plan-path-drift` | warn | Explicit field disagrees with path top segment. |

None block writes or session close. R-28 is drift-surface enforcement only.

**Env overrides (testing):** `PLANS_DIR_OVERRIDE`, `FINDINGS_OUTPUT`.

**Exit codes:** `0` success, `2` unknown flag, `3` PLANS_DIR or `--file` target not found.

**Cycle-detection design:** visited-set walk with hard depth cap of 6. Self-parent caught on hop 1. Floyd's tortoise-hare is overkill for bounded single-parent trees.

**Output Format (corpus mode):**

```
## plan-parent-resolve ({N} files scanned)

- Explicit parent_plan: {count}
- Path-inferred: {count}
- Unresolvable: {count}
- Broken pointers: {count}
- Cycles detected: {count}
- Chain too deep: {count}
```

**Tests:** `~/.claude-plans/63-librarian-capability-extraction/02-tier-2-mid-tier/tests/plan-parent-resolve.sh` — 15/15 pass (covers all 6 Session 24 cases + 5 wrapper-CLI cases + scope exclusion for `handoff.md` and `tests/`). Complementary Session 24 harness still lives at `~/.claude-plans/57-spine-remediation/24-parent-plan-inheritance-and-master-initiative-migration/tests/test-parent-resolver.sh`.

**Pseudocode-bug correction (extraction time):** the Session 24 inline resolver only recognized `<slug>/` and `<slug>.md` forms. Live corpus (2026-04-20) has 63 files carrying `parent_plan: <slug-without-prefix>` pointing at `NN-<slug>/` dirs — the convention documented in CLAUDE.md rule #5. The capability accepts all three forms. Pre-fix live signal: 63 spurious broken pointers. Post-fix: 0 broken, 9 real self-cycle findings in `56-spine-remediation-finalization/` surface as legitimate drift.


---

## Capability: cron-log-architecture

**Runtime:** `~/.claude/skills/librarian/capabilities/cron-log-architecture.sh` (extracted from pseudocode 2026-04-21 via Plan 63 Sub-plan 02 T-4; sources `lib/findings.sh`). Enforcement layer for ENFORCEMENT-MAP R-22 (spine-remediation Session 19 Module 19-A).

**Purpose:** Detect plists whose `StandardOutPath`/`StandardErrorPath` competes with a wrapper's dated-`LOG_FILE=$(date …)` pattern. Report-only — resolution requires a human `launchctl unload/load`.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/cron-log-architecture.sh [--scope all|plist|allowlist] [--allowlist-path <path>]
```

| Flag | Effect |
|------|--------|
| `--scope all` | plist walk + allowlist downgrade (default). |
| `--scope plist` | Walk only; ignore allowlist. |
| `--scope allowlist` | Print the allowlist file's contents and exit. |
| `--allowlist-path <path>` | Override the exceptions JSON path. |

**Scope:** `$PLIST_DIR/com.*.plist` (default `~/Library/LaunchAgents`) correlated against wrappers under `$CRON_WRAPPERS_RES` (default `~/.claude/orchestrator/cron-wrappers`). Plists whose Program is not a script under `$CRON_WRAPPERS_RES` are silently skipped (not spine-remediation-managed).

**Allowlist:** `$CRON_LOG_EXCEPTIONS` (default `$HOOKS_DIR/cron-log-architecture-exceptions.json`). Schema `{ "<label>": "<reason>", ... }`. Allowlisted labels are emitted at `level=info` with `allowlisted_reason` field; non-allowlisted are `level=error`.

**Finding shape:**

```json
{ "finding": "cron-log-architecture-mismatch", "file": "<label>",
  "plist": "<path>", "wrapper": "<path>",
  "StdOut": "<path|(unset)>", "StdErr": "<path|(unset)>",
  "level": "error|info", "allowlisted_reason": "<optional>" }
```

**Env overrides (testing):** `PLIST_DIR_OVERRIDE`, `CRON_WRAPPERS_OVERRIDE`, `CRON_LOG_EXCEPTIONS`, `FINDINGS_OUTPUT`. Override vars use `_OVERRIDE` suffix because `paths.sh` unconditionally exports `PLIST_DIR` / `CRON_WRAPPERS` — pseudocode-bug correction (T-4 extraction).

**Exit codes:** `0` always when PlistBuddy present (report-only capability), `2` unknown flag. Non-macOS (no PlistBuddy): exit 0 with advisory message.

**Output Format:**

```
## Cron Log Architecture ({M} mismatches, {A} allowlisted, {C} compliant)

- <label> — StdOut=<path> StdErr=<path> wrapper=<path>
- <label> (ALLOWLISTED — <reason>)
```

**Tests:** `~/.claude-plans/63-librarian-capability-extraction/02-tier-2-mid-tier/tests/cron-log-architecture.sh` — 12/12 pass (compliant, mismatch blocking, allowlisted info downgrade, wrapper without dated pattern, plist outside CRON_WRAPPERS, unknown-flag, `--scope allowlist`).

**Where it fires:** `/librarian cron-log-architecture` (ad-hoc), `/librarian full` (every full scan), `librarian session-close` Step 2 (when Touched Files include plists or wrappers).

**Session 19 baseline preserved:** 9 plists + 9 dated wrappers. Session 19 Module 19-A fixed `com.digest-run.plist`; 8 remaining deferred to cron-log-architecture-exceptions.json or case-by-case resolution.

---

## Capability: handoff-disposition-check

**Runtime:** `~/.claude/skills/librarian/capabilities/handoff-disposition-check.sh` (extracted from pseudocode 2026-04-21 via Plan 63 Sub-plan 02 T-5; sources `lib/findings.sh`). Enforcement layer for ENFORCEMENT-MAP R-25. Codifies `feedback_no_remembered_followups.md`.

**Purpose:** Block session-close when touched `*handoff.md` files contain unresolved follow-up language without a disposition tag within a 2-line window.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/handoff-disposition-check.sh --files <file> [--files <file> ...]
echo "<path>" | ~/.claude/skills/librarian/capabilities/handoff-disposition-check.sh
```

| Flag | Effect |
|------|--------|
| `--files <path>` | Repeatable. Scope to one or more handoff.md files. |
| (stdin) | Newline-separated file paths. Overrides to `--files` if pipe attached and no `--files` given. |

**Scope:** only files whose basename matches `*handoff.md`. Non-matching files in the scope are silently skipped.

**Unresolved-language regex (case-insensitive, word-boundary guarded):** `(^|[^a-zA-Z])(should|later|eventually|TODO|worth watching|flagged|follow[- ]?up)([^a-zA-Z]|$)`

**Disposition regex (case-insensitive):** `(FIX NOW|ABSORB|STANDALONE|deferred[- ]to:)`

**Window:** hit line + 2 following lines.

**Finding shape:**

```json
{ "finding": "handoff-disposition-missing", "file": "<handoff_path>",
  "line": "<N>", "phrase": "<matched word>",
  "matched": "<trimmed line content>", "level": "error" }
```

**Exit codes:** `0` if no missing dispositions, `1` if ≥ 1 missing (session-close blocks), `2` unknown flag.

**Env overrides (testing):** `FINDINGS_OUTPUT`.

**Output Format:**

```
## Handoff Dispositions ({N} missing)

- {file}:{line} — "{phrase}" needs one of FIX NOW / ABSORB / STANDALONE / deferred-to:
```

**Where it fires:** `librarian session-close` Step 2 Scoped Integrity Check (alongside `plan-index-touch-regen`, `doc-dependency-cascade-audit`). NOT in `/librarian full` — handoffs are session-scoped.

**Tests:** `~/.claude-plans/63-librarian-capability-extraction/02-tier-2-mid-tier/tests/handoff-disposition-check.sh` — 13/13 pass (compliant, missing disposition, out-of-window, `laterally` word-boundary, `todos.txt` word-boundary, unknown-flag, multi-`--files`, stdin scope, non-handoff skip).

**Regex tuning:** deliberately tight — literal words only, word-boundary-guarded. False positives (e.g. `laterally`, `todos.txt`) verified negative in tests. Tighten if Session 21+ surfaces new false-positive classes; never relax dispositions.

---

## Capability: skill-parity

**Runtime:** `~/.claude/skills/librarian/capabilities/skill-parity.sh` (Plan 12 skill-optimizer scope evolution, 2026-04-21; sources `lib/findings.sh`). Absorbs the mechanical (bash-checkable) subset of the original skill-optimizer Axis 1 config audit. Bash-vs-LLM boundary: LLM-interpreted checks (effort calibration, argument-hint extraction, description rewrite, disable-model-invocation heuristics) remain in `/skill-optimizer --skill {name}`.

**Scope:** `~/.claude/skills/*/SKILL.md` — not vault content.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/skill-parity.sh [--check|--fix] [--scope <dir>] [--dry-run]
```

| Flag | Effect |
|------|--------|
| `--check` (default) | Emit findings, no writes |
| `--fix` | Auto-add missing `name:` from directory basename. Never modifies existing fields or rewrites descriptions. |
| `--scope <dir>` | Narrow to a single skill directory or SKILL.md file |
| `--dry-run` | Summary counts only, no JSON finding emission |

**Checks:**

| Finding | Condition | Auto-fixable |
|---------|-----------|--------------|
| `skill-parity-missing-frontmatter` | File does not start with `---` YAML block | No (structural) |
| `skill-parity-missing-name` | No `name:` field in frontmatter | Yes (`--fix` adds from dir basename) |
| `skill-parity-name-mismatch` | `name:` value ≠ directory basename | No (requires human judgment — could indicate rename in progress) |
| `skill-parity-missing-description` | No `description:` field | No (requires LLM drafting) |
| `skill-parity-description-length` | Description empty or >1024 chars | No (requires LLM rewrite) |

**Exit codes:** `0` on clean run (findings routed via emit), `2` on unknown flag.

**Env overrides (testing):** `FINDINGS_OUTPUT`, `SKILL_PARITY_SKILLS_ROOT_OVERRIDE`.

**Where it fires:** surfaces in `/librarian full` supplemental block. Richer skill analysis (intent alignment, external benchmarking, LLM-judged frontmatter proposals) is the scope of the standalone `/skill-optimizer --skill {name}` skill.

**Tests:** `~/.claude-plans/12-skill-optimizer/tests/skill-parity.sh` — 16/16 pass (happy path, missing frontmatter, missing name, name mismatch, missing description, description length, `--fix` add-name, `--fix` idempotent, `--fix` leaves existing name, `--scope`, `--dry-run`, unknown flag).

---

## Capability: entity-parity

**Runtime:** `~/.claude/skills/librarian/capabilities/entity-parity.sh` (Plan 68; V1 shipped 2026-04-21 for skill entity; V2 extended 2026-04-21 to `plan` + `memory-file`). Cross-surface parity driven by the `entities` section of `~/.claude/hooks/doc-dependencies.json`. V3 (deferred) adds event-time advisory via pre-write-guard; V4 (deferred) adds `--apply` + session-close Step 2d gate.

**Scope (V2):** three entity types — `skill`, `plan`, `memory-file`. Each entity declares a canonical path template (with `{placeholder}`), a `canonical_field`, an `instance_enumerator` (glob), and N mirrors. Mirror paths may be vault-root-relative, home-relative (`~/...`), or include a `#row[{key}]` suffix indicating a row-within-file selector.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/entity-parity.sh [--check] [--scope <dir>] [--entity-type <type>] [--dry-run]
```

| Flag | Effect |
|------|--------|
| `--check` (default) | Emit findings; reconcile + persist to `drift_findings.entity_parity` |
| `--scope <dir>` | Narrow enumeration to one canonical instance directory |
| `--entity-type <type>` | `skill` \| `plan` \| `memory-file`; other types skipped |
| `--dry-run` | Summary counts only, no JSON emission, no manifest write |

**Registry schema:**

| Field | Level | Values | Meaning |
|-------|-------|--------|---------|
| `row_kind` | mirror | `wikilink-row` (default), `backlog-row`, `memory-index-line` | Selector dialect for `#row[{key}]` mirrors |
| `match_kind` | mirror | `frontmatter` (default), `json-field` | Canonical/mirror field parser |
| `optional` | mirror | `true`, `false` (default) | Silent when mirror file absent |
| `presence_only` | mirror | `true`, `false` (default) | Skip content-match; row presence = pass |
| `strict` | mirror | `true`, `false` (default) | Enforce content-match; content-mismatch emits finding |
| `exclude_basenames` | entity | list | Filter out basenames from enumerator (e.g. `MEMORY.md`) |

**Finding classes:**

| Finding | Severity | Condition |
|---------|----------|-----------|
| `entity-parity-canonical-missing-{field}` | warn | Canonical lacks the declared `canonical_field` |
| `entity-parity-mirror-missing` | warn | Strict non-optional mirror file absent |
| `entity-parity-mirror-absent-{field}` | info | Strict mirror present but field absent |
| `entity-parity-{field}-mismatch` | warn | Exact-match fails on canonical_field |
| `entity-parity-index-row-missing` | warn | `#row[]` mirror has no matching row |
| `entity-parity-registry-parse-failed` | warn | Registry unreadable or entities block empty |

**Persistent IDs:** `EP-NNN` with `first_seen` / `last_seen`. Match key: `(entity_type, instance_id, invariant_id, mirror_path)`. Reconciliation pattern ported from `frontmatter-enforce.sh:700-739`.

**Exit codes:** `0` on clean run, `2` on unknown flag.

**Env overrides (testing):** `ENTITY_PARITY_DOC_DEPS_OVERRIDE`, `ENTITY_PARITY_SKILLS_ROOT_OVERRIDE`, `ENTITY_PARITY_PLANS_ROOT_OVERRIDE`, `ENTITY_PARITY_MEMORY_ROOT_OVERRIDE`, `ENTITY_PARITY_VAULT_ROOT_OVERRIDE`, `MANIFEST_PATH`, `FINDINGS_OUTPUT`.

**Where it fires:** Monday cron block in `librarian-cron.sh` (wired alongside `drift-sweep`, `people-audit`, `waiver-audit`, `skill-parity` — non-blocking). Manual invocation remains available.

**Tests:**
- V1: `~/.claude-plans/68-entity-parity-enforcement/01-v1-bare-bones/tests/entity-parity.sh` — 26/26 pass.
- V2: `~/.claude-plans/68-entity-parity-enforcement/02-v2-coverage/tests/entity-parity.sh` — 27/27 pass (backlog-row three pointer forms, memory-index-line, `optional` mirror silent-when-absent, `match_kind: json-field`, `exclude_basenames`, `--entity-type` filter, persistent ID stability across V2 findings).

**Baseline (real inventory, 2026-04-21 V2 dry-run):** 170 instances scanned; 40 findings; all legitimate drift, zero detector bugs.
- skill: 29 (V1 unchanged) — 3 canonical-missing-description, 7 mirror-missing, 9 mirror-absent-description (info), 3 description-mismatch, 7 index-row-missing
- plan: 10 — all `index-row-missing` (plans lacking System Backlog rows; consistent with R-15 principle)
- memory-file: 1 — `index-row-missing` (memory file absent from MEMORY.md)

---

## Unified Report Format

When running all capabilities (default or `full`):

```
Librarian Report — YYYY-MM-DD HH:MM
==================================

## Placement (X issues)
[placement-validate output]

## Frontmatter (X issues)
[frontmatter-enforce output]

## Cross-References (X issues)
[xref-check output]

## Stale Content (X items)
[stale-detect output]

## Logs (X archived, Y remaining)
[log-archive output]

## Plan Index (X plans, Y unknown)
[plan-index output]

## Cron Health (X issues)
[cron-health findings: blocking rows for each *cron-error*.md newer than 24h by filename epoch]
[tripwire findings: blocking rows for each TRIPWIRE line in ~/.claude/hooks/state/tripwire.log newer than 24h]

## Cron Log Architecture (X mismatches)
[cron-log-architecture-mismatch findings: blocking rows for plists whose StandardOutPath conflicts with wrapper dated-log pattern — R-22]

## Handoff Dispositions (X missing)
[handoff-disposition-missing findings: blocking rows for unresolved-language hits in touched handoff.md without FIX NOW / ABSORB / STANDALONE / deferred-to tag — R-25]

## Summary
- Auto-fixed: N
- Manual review needed: N
- Info: N
```

---

## Invocation Mode: session-close

End-of-session reconciliation — a deterministic chain of extracted librarian capabilities. Not a new capability. Replaces the standalone `/session-close` skill.

**Invocation:** `/librarian session-close [--deep]`

**Orchestrator:** `~/.claude/skills/librarian/capabilities/session-close.sh` (Plan 63 Sub-plan 04, 2026-04-21). Deterministic shell; chains extracted capability shells; advisory-only (always exits 0).

### Flags

| Flag | Purpose |
|------|---------|
| `--scope solo\|scoped\|reconciler` | Override auto-detected scope (see table below). Default auto-detects from the session registry + `UserPromptSubmit` signals. |
| `--dry-run` | Report the capability plan; skip invocation. |
| `--touched-files <csv>` | Explicit touched-file list (bypasses registry lookup). |
| `--test-mode` | Stub capability invocations for test harnesses; writes to `$SESSION_CLOSE_LOG_DIR` if set. |

### Close-Mode contract

| Close Mode | Condition | Behavior |
|------------|-----------|----------|
| **solo** | No other active or pending sessions | Standard session-close. Reconciliation sweep is a no-op. |
| **scoped** | Other sessions still active | Own touched files only. `session-deregister.sh` marks self `closed-pending-reconciliation`. **Reconciliation sweep + backup DEFER** to a later reconciler pass (R-42). |
| **reconciler** | Last active session with pending peers | Merge peers' touched files. Run reconciliation sweep to clear pending entries. Full manifest regeneration. |

Default if no registry: **solo**.

### Capability chain (executed in order)

1. **Scoped integrity** (Step 2): `frontmatter-enforce --check` → `xref-check` → `placement-validate` → `stale-detect` → `cron-log-architecture` → `handoff-disposition-check` → `plan-index` → `plan-parent-resolve`.
2. **Rename cascade** (Step 2b, Plan 67 SP02 T-4, 2026-04-22): `rename-detect` over last-24h git log across VAULT + PLANS → `rename-history-sync append` onto `doc-dependencies.json` → `rename-cascade` (dry-run only; `--apply` is human-initiated). Empty 24h window is a valid no-op. Logged as `rename-cascade-pipeline` + per-subcommand status in the aggregated log.
3. **Reconciliation sweep** (Step 2c): `~/.claude/hooks/reconcile-sessions.sh`. **Skipped in `scoped` mode** (R-42 defers to reconciler). Idempotent and lock-guarded; safe to fire in `solo` and `reconciler`.
4. **Trinity drift detect** (Step 2d, Plan 67 SP04 T-1, 2026-04-22): `trinity-drift-detect` full walk of `$PLANS_DIR` depth 2 + 3. Surfaces `spec-manifest-divergence`, `trinity-task-ledger-lag`, `header-trinity-divergence`. Advisory; does not block close.
5. **Sync check** (Step 3): `sync-check --fix` (full scope).
6. **Architect triage** (Step 4c): `architect-triage` — reads `Logs/architect-*.md`, deduplicates against backlog + manifest.
7. **Backup** (Step 5): `backup` capability. **Skipped in `scoped` mode** to avoid partial-state commits during overlapping sessions.
8. **Aggregated log** (Step 6): single write to `~/Documents/Obsidian Vault/Logs/session-close-YYYYMMDD-HHMMSS.md`. Capability-by-capability status recorded. Idempotent: second invocation within 60s short-circuits without double-writing.

### Capability error handling

Individual capability failures are logged as `error` entries in the capability chain section of the aggregated log and counted in `errors-total`. They do not halt orchestration. Session-close is **advisory** — always exits 0. Gating semantics remain on the individual capabilities' own contracts (e.g., blocking findings emitted to the unified report + manifest sections).

### Output

Single aggregated log at `Logs/session-close-YYYYMMDD-HHMMSS.md`:

```yaml
---
type: log
log-type: session-close
mode: shell-orchestrator
scope: solo|scoped|reconciler
date: YYYY-MM-DD
timestamp: ISO
findings-total: N
errors-total: N
tags: [log/session-close]
---
```

Body sections: `## Capability Chain` (per-capability status), `## Summary` (totals), `## Error Findings` (when `errors-total > 0`).

Individual capabilities MAY write their own sub-logs + findings per their SKILL.md contracts (e.g., drift findings into `drift_findings` manifest section, cascade findings into the `cascade_findings:` block, architect triage into the backlog). The orchestrator does not duplicate those payloads — it only records orchestration status.

### Cross-references

- Individual capability contracts: see `## Capability: <name>` sections in this SKILL.md.
- R-42 scope contract: `~/.claude-plans/57-spine-remediation/` and `ENFORCEMENT-MAP.md`.
- R-41 plan-index staleness tripwire: `plan-index` capability section.
- Aggregated report schema: `~/.claude/schemas/vault-schema.json` (type: log, log-type: session-close).

---

## Bulk Fix Pre-Flight

When `--fix` is invoked and the scope exceeds **10 files**, a mandatory pre-flight validation runs before any changes are applied:

### Process

1. **Dry-run first pass:** Execute all applicable capabilities in `--check` mode. Collect the full list of proposed changes.
2. **Cross-check:** Do any proposed changes conflict with each other? (e.g., two capabilities both want to modify the same field on the same file with different values)
3. **Dependency check:** For each target file, check if any file that links TO it (inbound edges from `xref_graph`) is also being modified. Flag cascading risk.
4. **Summary to Peter:** Present a grouped summary before executing:

```
## Pre-Flight Summary ({N} files affected)

### By Capability
- frontmatter-enforce: {N} fixes
- xref-check: {N} fixes
- placement-validate: {N} moves

### Cross-Check
- {N} conflicts detected (details below)
- {N} cascading dependency risks

### Conflicts
| File | Capability A | Capability B | Issue |
|------|-------------|-------------|-------|

Proceed with all? Or specify capabilities/files to include/exclude.
```

5. **Wait for approval.** Apply only approved changes. Log excluded items.

**When scope ≤ 10 files:** Pre-flight is skipped. `--fix` applies directly (standard behavior).

**Exception:** Session-close auto-fix mode skips pre-flight for its own touched files (these were just modified by the session, low risk). Pre-flight still applies if session-close is in **reconciler** mode (merging multiple sessions' changes).

---

## Capability: memory-hygiene

**Runtime:** `~/.claude/skills/librarian/capabilities/memory-hygiene.sh` (shipped Plan 63 Sub-plan 03 T-2, 2026-04-20 — pattern exemplar for the Tier 3 shell-prefilter + Claude-synthesis hybrid).

**Purpose:** Lifecycle maintenance for the Claude memory system. Shell prefilter handles 5 deterministic drift classes as direct findings; emits NDJSON candidates for 3 judgment classes that Claude synthesizes here at runtime.

**Invocation contract:**

| Flag / env | Purpose | Default |
|------------|---------|---------|
| `--scope <path>` | Override memory directory | — |
| `--dry-run` | Summary counts only, no emission | off |
| `--help` | Usage | — |
| `MEMORY_DIR` | Memory files root | `$HOME/.claude/projects/-Users-petertiktinsky/memory/` |
| `MEMORY_INDEX_PATH` | MEMORY.md path | `$MEMORY_DIR/MEMORY.md` |
| `FINDINGS_OUTPUT` | Finding output sink (file, else stdout) | stdout |
| `STALENESS_THRESHOLD_DAYS` | Staleness cutoff | 30 |
| `MANIFEST_PATH` | librarian-manifest.json target | `$VAULT_LOGS/librarian-manifest.json` |

**Flag map (SKILL.md legacy → runtime):**
- `/librarian memory-hygiene` → runs the prefilter, emits findings + NDJSON candidates; Claude synthesizes candidate proposals at the invocation site.
- `/librarian memory-hygiene --fix` → after synthesis proposals are accepted, apply approved mutations (add to MEMORY.md, remove dead refs, refresh `last_verified`). Fix mode is a synthesis-time action, not a shell flag.

### Deterministic classes (shell direct-fires findings)

| # | Check | Emitted as | Evidence carried |
|---|-------|-----------|------------------|
| #1 | Staleness | `{"finding": "staleness", ...}` | last_verified + days + threshold |
| #4 | Orphan | `{"finding": "orphan", ...}` | file on disk not in MEMORY.md |
| #5 | Index accuracy | `{"finding": "index", ...}` | MEMORY.md entry → missing target |
| #7 | Temporal hygiene | `{"finding": "temporal", ...}` | frontmatter date field empty / malformed |
| #8 | Budget monitor | `{"finding": "budget", ...}` | MEMORY.md line count vs 200-line cap (green/yellow/red) |

### Judgment classes (shell emits NDJSON; Claude synthesizes)

| # | Check | NDJSON `check` value | Claude's job |
|---|-------|---------------------|--------------|
| #2 | Status verification | `status-verification` | Confirm a `project_*` memory marked complete/closed is actually settled; refresh `last_verified` or propose archive |
| #3 | Overlap | `overlap` | Adjudicate slug/name-similar memory pairs — merge, keep-both (with `related:` cross-link), or delete-superseded |
| #6 | Conflict | `conflict` | Same-name memory pairs — compare content, identify contradictions, propose which to keep |

### NDJSON schema

Every judgment candidate carries:

```json
{
  "capability": "memory-hygiene",
  "check": "status-verification|overlap|conflict",
  "candidate_id": "<SHA256(capability|check|subject)[:16]>",
  "subject": "<file-path or file_a|file_b pair>",
  "evidence": { ... see prefilter-contract.md §1 ... },
  "score": 0.0-1.0,
  "notes": "<one-line hint>"
}
```

Full schema + per-capability evidence payloads live at
`~/.claude-plans/63-librarian-capability-extraction/03-tier-3-hybrid/prefilter-contract.md §1`.

### Model synthesis prompt (LIVE — this IS what Claude executes)

When `/librarian memory-hygiene` emits NDJSON candidates, Claude reads each line and produces proposals using the following judgment rubric:

**For `#2 status-verification` candidates:**
1. Read the `content_excerpt` — does it explicitly state the project/plan/engagement is complete, closed, or superseded?
2. If explicit: CONFIRM closure. Refresh `last_verified` to today. Optionally archive.
3. If ambiguous: escalate to Peter with the excerpt + `last_verified` age for a manual call.
4. If the excerpt contradicts the `status: complete` frontmatter: flag as conflict.

**For `#3 overlap` candidates:**
1. Read the `file_a` + `file_b` names, descriptions, and excerpts in the evidence payload.
2. Decide: MERGE (same subject, redundant); KEEP-BOTH (intentionally distinct — add `related:` frontmatter cross-link); SUPERSEDE (one explicitly marked superseded in its own body — delete it, keep the survivor).
3. Specifically flag 2-file sentinel-pattern pairs with high slug similarity (≥0.7) and one file explicitly marked SUPERSEDED — these are high-confidence merge targets that pseudocode's "3+ group" threshold misses.

**For `#6 conflict` candidates:**
1. Same-name memory pairs. Read both content excerpts.
2. If contradictory statements on the same subject (different roles, statuses, timestamps): pick the canonical (usually the un-suffixed slug) and merge/delete.
3. If non-contradictory (same subject, complementary details): propose MERGE with description consolidation.
4. Never accept two live memories with the same frontmatter `name:` — either merge or rename.

**Batch optimization:** When prefilter emits many `status-verification` candidates with similar shape (`status: completed` + stale `last_verified` + quiet bodies), propose a single BULK REFRESH action covering all of them rather than per-file proposals.

**Dotfile filter:** If `subject` ends in `.md` but starts with `.`, REJECT the finding — dotfiles are infrastructure, not memories. This is a known pseudocode-bug correction pending prefilter v2.

### Output format (runtime)

After synthesis, Claude renders proposals in the following markdown to Peter:

```
## Memory Hygiene ({N} files checked)

### Deterministic Findings
| Class | File | Action | Auto-fix? |
|-------|------|--------|----------|

### Merge / Supersede Proposals (from overlap + conflict synthesis)
| File(s) | Action | Why |
|---------|--------|-----|

### Status Verification Proposals
| File | Current status | last_verified age | Proposed action |
|------|---------------|------------------|-----------------|

### Budget
- MEMORY.md: {line_count}/200 lines ({pct}%), status={green|yellow|red}

### Pipeline Health
| Layer | Last Run | Status | Entries |
|-------|----------|--------|---------|
| Auto-memory | (always current) | {budget status from Check #8} | {N} files, {line_count}/200 index |
| Consolidation runner | {last_consolidation from .consolidation-state.json} | {sessions_since} sessions ago | — |
| Transcript mine | {last_transcript_mine} | {age since last run, or "never"} | — |
| mem-promote | {last_mem_promote} | {age since last run, or "never"} | — |
| claude-mem | (continuous) | {total observation count via search} | — |

### Pipeline Recommendations
- {any pipeline-level recommendations, e.g., "transcript-mine hasn't run in 7 days — consider /librarian transcript-mine"}
- {e.g., "mem-promote has never run — consider /librarian mem-promote --since 2026-04-01"}
```

### Consolidation Logic (ADD/UPDATE/DELETE/NOOP) — preserved for consumer callers

When a new memory is being created (by any skill or by the auto-memory system), memory-hygiene logic applies:

| Situation | Action |
|-----------|--------|
| No similar existing memory | **ADD** — create new file, add to index |
| Similar memory exists, new info adds detail | **UPDATE** — merge into existing file, update `last_verified` |
| Similar memory exists, new info contradicts | **UPDATE** — replace conflicting content, add `superseded_by` to old if creating replacement |
| Existing memory covers this exactly | **NOOP** — update `last_verified` on existing, skip creation |
| Existing memory is outdated/irrelevant | **DELETE** — remove file, remove from index, note in log |

### Tests + two-gate acceptance status

- Tests: `~/.claude-plans/63-librarian-capability-extraction/03-tier-3-hybrid/tests/memory-hygiene.sh` — 19 assertions across 5 scenarios (deterministic direct-fire, NDJSON shape, empty-state, Gate A adversarial recall, --dry-run summary).
- Gate A (adversarial prefilter recall): **5/5 seeded anomalies surfaced** (verified 2026-04-20 T-2).
- Gate B (proposal acceptance delta): pending Peter's judge-pack pass at `baselines/judge-pack/memory-hygiene.md`.


---

## Capability: transcript-mine

**Runtime:** `~/.claude/skills/librarian/capabilities/transcript-mine.sh` (Plan 63 Sub-plan 03 T-3, 2026-04-20; sources `lib/findings.sh` + `lib/manifest.sh` + `lib/dates.sh`). Hybrid shell-prefilter + Claude-synthesis. **Phase 1 + Phase 2 are deterministic shell** — they discover transcripts and emit NDJSON signal candidates. **Phase 3 + Phase 4 are Claude synthesis at runtime** using the prompt below against the NDJSON stream.

**Purpose:** Mine meeting transcripts for implicit knowledge — decisions, preferences, action-items, tool-mentions, corrections — that was never explicitly saved as a memory. Proposes new memory entries for review.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/transcript-mine.sh [--scope <path>] [--dry-run] [--help]
```

| Flag | Effect |
|------|--------|
| `--scope <path>` | Override `TRANSCRIPT_DIR` (test-mode / alt-corpus) |
| `--dry-run` | Summary counts only — no NDJSON emission |
| `--help` | Usage + env overrides |

**Env overrides (testing):** `TRANSCRIPT_DIR` (default `$HOME/Documents/Obsidian Vault/Meetings/`), `TRANSCRIPT_GLOB` (default `*.md`), `FINDINGS_OUTPUT` (default stdout).

**NDJSON schema:** per `~/.claude-plans/63-librarian-capability-extraction/03-tier-3-hybrid/prefilter-contract.md §1`. Each line:

```json
{
  "capability": "transcript-mine",
  "check": "decision|preference|action-item|tool-mention|correction",
  "candidate_id": "<SHA256(capability|check|subject)[:16]>",
  "subject": "<filename>:L<line>",
  "evidence": {
    "transcript_path": "<filename>",
    "meeting_date": "YYYY-MM-DD",
    "passage": "<matched line + 2-line context>",
    "line_number": <int>,
    "signal_category": "<check>",
    "keyword_hit": "<matched regex token>"
  },
  "score": <float>,
  "notes": "<one-line hint>"
}
```

**Signal category keyword table (Phase 2 deterministic):**

| Category | Keyword regex (word-boundary, case-insensitive) |
|----------|------------------------------------------------|
| `decision` | decided, approved, going with, the plan is, let's go, `**Decision:**`, Peter's position |
| `preference` | prefer(s\|red\|ring), from now on, I like, dislike(s\|d), avoid, always, never |
| `action-item` | will do, will (follow up\|send\|share\|draft\|review), follow-up, deadline, owner, by `<date>` |
| `tool-mention` | Claude, skill, script, cron, hook, librarian, memory |
| `correction` | actually, correction, rephrase, take (that\|it) back, instead |

Scores: baseline 0.6 per hit; `**Decision:**` leader bumps to 0.9; action-item hits inside markdown tables bump to 0.75. Frontmatter stripped before scanning (so `tags:` values do not fire).

### Phase 3: Deduplication Against Existing Memories

1. For each extracted signal, compare against existing memory file names and descriptions
2. If the signal clearly maps to an existing memory: skip (already captured)
3. If the signal is novel: promote to a proposed memory entry

### Phase 4: Proposal Generation

For each novel signal, generate a proposed memory entry:

```yaml
---
name: {inferred title}
description: {one-line description}
type: {inferred type}
last_verified: {today}
source_transcript: {transcript filename}
source_line: {line number}
confidence: high|medium|low
---

{proposed content}

**Why:** {extracted context for why this matters}
**How to apply:** {when/where this should guide behavior}
```

**Confidence levels:**
- **High:** Direct statement from Peter ("don't do X", "always use Y")
- **Medium:** Implied from correction or decision context
- **Low:** Inferred from pattern across multiple sessions

In `--propose` mode: output all proposals as a report for Peter's review.
In `--apply` mode: write high-confidence proposals directly (with memory pre-write guard validation from Plan 20), present medium/low for approval.

### Output Format

```
## Transcript Mining ({N} transcripts scanned, {date_range})

### Proposed Memories
| # | Type | Name | Confidence | Source | Action |
|---|------|------|-----------|--------|--------|
| 1 | feedback | {title} | high | {session-id}.jsonl:L{N} | write |
| 2 | project | {title} | medium | {session-id}.jsonl:L{N} | propose |

### Details
#### Proposal 1: {title}
**Source:** "{extracted quote}" — {transcript}:L{N}
**Proposed memory:**
{full proposed content}

### Skipped (already captured)
- "{signal}" → matches existing: {memory_file.md}
```

### Integration with Consolidation Pipeline

- The background consolidation runner does NOT run transcript-mine (requires Claude's judgment for proposal generation — not suitable for shell automation).
- Transcript-mine runs only via explicit `/librarian transcript-mine` invocation.
- The consolidation state tracker records `last_transcript_mine` timestamp so transcript-mine knows where to start scanning.
- After a successful run, update `.consolidation-state.json` with `last_transcript_mine` set to current ISO timestamp.

### Tests + two-gate acceptance status

- Tests: `~/.claude-plans/63-librarian-capability-extraction/03-tier-3-hybrid/tests/transcript-mine.sh` — 17 assertions across 6 scenarios (NDJSON schema, no-match, malformed skip, Gate A adversarial, --dry-run, frontmatter strip).
- Gate A (adversarial prefilter recall): **0 candidates from 20L DQ Sheet placeholder** (verified 2026-04-20 T-3). PASS — near-zero condition satisfied.
- Gate B (proposal acceptance delta): pending Peter's judge-pack pass at `baselines/judge-pack/transcript-mine.md`.

---

## Capability: architect-triage

**Runtime:** `~/.claude/skills/librarian/capabilities/architect-triage.sh` (extracted from pseudocode 2026-04-21 via Plan 63 Sub-plan 02 T-6; sources `lib/findings.sh` + `lib/manifest.sh` + `lib/dates.sh`).

**Purpose:** Surface untracked architect `[R-NNN]` recommendations as System Backlog candidates. Dedupe against Backlog row text + prior manifest state. Manifest I/O heavy — persists `architect_recommendations` subtree via `manifest_set`.

**Invocation:**

```
bash ~/.claude/skills/librarian/capabilities/architect-triage.sh [--check|--apply]
```

| Flag | Effect |
|------|--------|
| `--check` | Report untracked recommendations + update manifest. No Backlog write. Default. |
| `--apply` | Currently blocks with `exit 4`. Main-session flag; Backlog writes are Peter-authorized. |
| `--dry-run` | Alias for `--check`. |

**Extraction regex:** `^\*\*\[R-(\d+)\]\s+([^*]+?)\*\*\s*(?:\`\[([A-Za-z\-]+)\]\`)?` — matches `**[R-NNN] Title** ` + optional `\`[cat]\`` bucket tag. **Category:** and **Confidence:** lines scanned in the next 2KB of body for metadata.

**Dedupe:**
- Backlog regex scan: `R-\d+` in `$SYSTEM_BACKLOG_PATH` → files marked as `backlog_matches` (status `in_backlog_untracked` if manifest has no entry).
- Manifest `architect_recommendations.recommendations[]` — matched IDs drop to `manifest_matches` with their prior status preserved (`tracked|deferred|completed|rejected`).
- Duplicates across logs: newest log wins; a rec ID is only triaged once.

**Finding shape:**

```json
{ "finding": "architect-recommendation-untracked", "file": "<source_log>",
  "id": "R-NNN", "title": "<title>", "category": "<category>", "level": "info" }
```

**Manifest subtree (via `manifest_set`, entire replacement — resolved-row drop-out pattern):**

```json
{
  "architect_recommendations": {
    "last_scan": "<iso>",
    "last_scanned_log": "<filename>",
    "logs_scanned": N,
    "recommendations": [
      {"id": "R-001", "title": "...", "source_log": "...",
       "category": "quick-win", "status": "tracked|deferred|completed|rejected|in_backlog_untracked|untracked",
       "backlog_entry": true|false, "last_checked": "YYYY-MM-DD"}
    ]
  }
}
```

**Env overrides (testing):** `ARCHITECT_LOGS_GLOB`, `SYSTEM_BACKLOG_PATH`, `MANIFEST_PATH`, `FINDINGS_OUTPUT`.

**Exit codes:** `0` success, `2` unknown flag, `4` `--apply` blocked (extraction does not author Backlog writes).

**Output Format:**

```
## Architect Triage ({N} logs scanned, {M} recommendations found)

- Untracked (surface for Backlog): {count}
- Already in Backlog (tracked via row): {count}
- Tracked in manifest (prior triage): {count}

### Untracked Recommendations
| ID | Title | Category | Source Log |
|---|---|---|---|
| R-NNN | {title} | {category} | {source_log} |
```

**Session-close integration (Step 4c):** gates on last_scanned_log vs newest log mtime — only fires if a new log exists. Runs after Step 4b (System Backlog Update).

**Tests:** `~/.claude-plans/63-librarian-capability-extraction/02-tier-2-mid-tier/tests/architect-triage.sh` — 14/14 pass (new untracked, Backlog dedupe, manifest completed dropout, duplicate-across-logs dedupe, unknown-flag exit 2, `--apply` blocked exit 4, manifest subtree persistence, prior-status preservation).

---

## Capability: mem-promote

**Runtime:** `~/.claude/skills/librarian/capabilities/mem-promote.sh` (shipped Plan 63 Sub-plan 03 T-4, 2026-04-20 — Tier 3 hybrid: shell prefilter + Claude synthesis).

**Purpose:** Query claude-mem's observation database for high-value patterns and propose promotions to the auto-memory system. Bridges the gap between claude-mem's wide-net automatic capture and auto-memory's curated, always-available context.

**Invocation contract:**

| Flag / env | Purpose | Default |
|------------|---------|---------|
| `--session <path>` | Session JSONL to query (repeatable) | — |
| `--session-glob '<pattern>'` | Glob pattern for sessions | — |
| `--dry-run` | Summary counts only, no emission | off |
| `--help` | Usage | — |
| `MEM_SESSION_PATH` | Colon-separated session JSONL paths (test mode) | — |
| `MEMORY_DIR` | Memory files root | `$HOME/.claude/projects/-Users-petertiktinsky/memory/` |
| `CLAUDE_MEM_DB` | claude-mem SQLite DB | `$HOME/.claude-mem/claude-mem.db` |
| `FINDINGS_OUTPUT` | Finding output sink (file, else stdout) | stdout |
| `MEM_PROMOTE_CLUSTER_THRESHOLD` | Jaccard threshold for within-session cluster consolidation | 0.5 |

**Flag map (legacy → runtime):**
- Legacy `--since YYYY-MM-DD` is replaced by explicit `--session` selection; sessions are the operational scoping unit post-extraction.
- Legacy `--propose` is the default shell behavior (NDJSON candidates surface; synthesis decides apply vs defer).
- Legacy `--apply` is a synthesis-time decision, not a shell flag.

### What the shell prefilter does (Phase 1 + Phase 2)

- **Phase 1:** For each `--session <path>`, look up the `memory_session_id` in the claude-mem SQLite DB via `sdk_sessions.content_session_id`, then pull observations (`id`, `type`, `title`, `subtitle`, `facts`, `narrative`, `created_at`) ordered by id.
- **Phase 2:** Consolidate within-session near-duplicates via Jaccard(tokens) ≥ 0.5 union-find clustering. Dedup each cluster against existing `memory/*.md` files (Jaccard of title+description tokens; ≥0.6 = duplicate, ≥0.35 = variant, else novel). When ≥2 sessions are scanned, also emit `pair-overlap` findings for cross-session subject echoes (Jaccard ≥0.3, ≥2 shared tokens).

### NDJSON schema

Every promotion-candidate carries:

```json
{
  "capability": "mem-promote",
  "check": "promotion-candidate",
  "candidate_id": "<SHA256(capability|check|subject)[:16]>",
  "subject": "<inferred subject title>",
  "evidence": {
    "session_id": "<JSONL session UUID>",
    "session_end": "<ISO timestamp>",
    "sessions": [{"session_id","session_end"}, ...],
    "observations": ["<obs passage>", ...],
    "observations_meta": [{"id","type","title","created_at","session_id"}, ...],
    "cluster_size": <int>,
    "existing_memory_matches": [{"file","subject_hash","match_score"}],
    "dedup_decision": "novel|variant|duplicate",
    "pair_confirmed": true|false
  },
  "score": 0.0-1.0,
  "notes": "<one-line hint>"
}
```

Pair-overlap findings (when >1 session scanned) carry:

```json
{
  "capability": "mem-promote",
  "check": "pair-overlap",
  "candidate_id": "<SHA256>",
  "subject": "<subject_a>|<subject_b>",
  "evidence": {
    "session_a": "...",
    "session_b": "...",
    "subject_a": "...",
    "subject_b": "...",
    "shared_tokens": ["..."],
    "jaccard": 0.0-1.0,
    "drift_class": "pair-overlap"
  },
  "score": 0.4-0.8,
  "notes": "cross-session subject echo — claude should evaluate merge vs keep-separate"
}
```

Full schema + per-capability evidence payloads live at `~/.claude-plans/63-librarian-capability-extraction/03-tier-3-hybrid/prefilter-contract.md §1`.

### Phase 3: Promotion Proposal Generation (LIVE — this IS what Claude executes)

For each NDJSON candidate, synthesize a proposed memory entry:

```yaml
---
name: {inferred title}
description: {one-line description}
type: {inferred type}
last_verified: {today}
source: claude-mem
source_observation_id: {claude-mem observation ID}
confidence: high|medium|low
---

{proposed content}
```

**Confidence levels:**
- **High:** Observation captures a direct user correction, explicit decision, or stated rule
- **Medium:** Observation captures a pattern or discovery with clear future relevance
- **Low:** Observation captures context that might be useful but is situational

**Synthesis rubric (per candidate):**

1. For `promotion-candidate` with `dedup_decision: novel` — produce an **ADD proposal**. Confidence from type: `decision`/`bugfix` → high, `feature`/`change` → medium, `discovery` → low.
2. For `promotion-candidate` with `dedup_decision: variant` — produce an **UPDATE proposal** targeting the matched memory file. Merge new detail into the existing body; refresh `last_verified`.
3. For `promotion-candidate` with `dedup_decision: duplicate` — **SKIP**, but surface to Peter if `match_score < 0.8` (for confirmation).
4. For `pair-overlap` findings — **COLLAPSE**: both subjects refer to the same underlying work. Emit ONE consolidated proposal, not two. The higher-jaccard cross-session pair is the strongest collapse signal.
5. For clusters of ≥3 promotion-candidates sharing a topic cluster (session-work on the same plan/feature/domain) — propose a **bulk UPDATE** to the matching project/feature memory, not per-observation proposals. Saves churn; preserves signal.

**Batch optimization:** When 5+ observations from the same session describe per-plan/per-handoff status updates (handoff appends, manifest flips, System Backlog rows), SKIP them en masse — they're routine discipline captured in per-plan handoff records, not promotable signal.

**Session-bookkeeping filter:** Reject candidates whose subject matches `Located|Reviewed|Audit Completed|Checkpoint written|Execution-order-\d{4}-\d{2}-\d{2}` — these are session-discovery/meta-review observations, not knowledge.

### Phase 4: Cross-Reference Annotation (LIVE — Claude applies)

When a promotion is applied (memory file created or updated), add a source reference in the memory file body:

```
> Source: claude-mem observation #{id}, {date}
```

Create an audit trail from curated memory back to the raw observation that generated it.

### Output Format (runtime)

```
## mem-promote ({N} observations scanned across {S} sessions, {date_range})

### Source Stats
- claude-mem observations queried: {N}
- Within-session clusters consolidated: {C}
- Pair-overlap findings: {P}
- Already captured (variant/duplicate skipped): {K}
- Novel signals found: {M}
- Proposed promotions (ADD): {A}
- Proposed updates (UPDATE): {U}

### Promotions
| # | Type | Action | Name | Confidence | Source Observation |
|---|------|--------|------|-----------|-------------------|
| 1 | feedback | ADD | {title} | high | obs #{id} |
| 2 | project | UPDATE → {existing_file.md} | {title} | medium | obs #{id} |

### Details
#### Promotion 1: {title}
**Source observation:** #{id} ({date})
**Original context:** "{extracted content}"
**Proposed memory:**
{full proposed content}
```

### Integration with Consolidation Pipeline

- The background consolidation runner does NOT run mem-promote (requires Claude's judgment for proposal quality — not suitable for shell automation).
- mem-promote runs via explicit `/librarian mem-promote --session <path>` invocation, or as part of session-close (Step 2.5) when the 48-hour gate is met, or from a session-end hook passing the current session JSONL.
- After a successful run, update `.consolidation-state.json` with `last_mem_promote` set to current ISO timestamp.

### Tests + two-gate acceptance status

- Tests: `~/.claude-plans/63-librarian-capability-extraction/03-tier-3-hybrid/tests/mem-promote.sh` — 19 assertions across 7 scenarios (novel candidate emission, duplicate/variant detection, nonexistent-session handling, Gate A adversarial pair, --dry-run summary, within-session cluster consolidation, unknown-flag exit 2).
- Gate A (adversarial pair-overlap): **4 pair-aware findings emit** (shared-token jaccard 0.30-0.40 across the 8b4eccad + 83468272 pair — cascade-waiver ×2, partial-status, Plan 64 SP02). Gate A PASS per prefilter-contract.md (disjunctive "collapse OR pair-aware finding").
- Gate B (proposal acceptance delta): pending Peter's judge-pack pass at `baselines/judge-pack/mem-promote.md`.

---

## Memory Search Strategy

When looking for prior context, search in this order:

1. **MEMORY.md index** (always loaded — check first for curated, high-signal context)
2. **Memory files** (read specific files referenced in MEMORY.md for detail)
3. **claude-mem:mem-search** (for broader recall — observations, tool usage, session history)
4. **Session transcripts** (last resort — raw JSONL files, use targeted grep)

When the librarian runs mem-promote, knowledge flows UP this hierarchy:
transcripts → claude-mem → (mem-promote filter) → auto-memory → MEMORY.md index

Each layer is progressively more curated and more available.

---

## Shared Helpers (`~/.claude/skills/librarian/lib/`)

Five shared shell libraries, sourced by capability scripts to keep invariants in one place (Plan 61 seed, extended by Plans 63/64/67). Contract: every capability that emits findings, reads/writes the manifest, handles dates, parses frontmatter, or resolves plan paths sources the relevant helper instead of inlining logic.

| Helper | Purpose | Key exports | Primary consumers |
|--------|---------|-------------|-------------------|
| `lib/findings.sh` | Canonical finding + lifecycle-event emitter. Routes to `$FINDINGS_OUTPUT` or stdout. | `emit_finding`, `emit_event` | all capabilities |
| `lib/manifest.sh` | Atomic `manifest_set` / `manifest_get` JSON subtree I/O against `librarian-manifest.json`. Python3 worker — callers pay the subshell cost on demand (avoid importing in hot paths). | `manifest_set`, `manifest_get` | frontmatter-enforce, xref-check, sync-check, plan-index, architect-triage, rename-detect (`--register`) |
| `lib/dates.sh` | ISO-8601 date math + week-of-year conversions. Bash 3.2 clean. | `date_iso`, `days_since`, `yyyy_ww_from_iso` | log-archive, session-close, transcript-mine, architect-triage |
| `lib/frontmatter.sh` | Single-file YAML-frontmatter parser (bash 3.2 compatible; no `declare -A`). Returns key-value pairs. | `frontmatter_load`, `frontmatter_get` | plan-parent-resolve, tag-coverage-audit |
| `lib/plan-path.sh` | Plan-root detection under `$PLANS_DIR`. Disambiguates depth-2 plan-root files from depth-≥3 sub-task files. | `is_plan_root_file`, `plan_root_for` | stale-detect, tag-coverage-audit, plan-parent-resolve |

**Note:** `lib/plan-path.sh` is librarian-local. The paths helper `lib/paths.sh` lives under `~/.claude/hooks/lib/paths.sh` (vault/plans/logs env exports) — librarian capabilities source it via absolute path, not via `librarian/lib/`. Do not conflate the two.

---

## Hard Rules

1. **Survivorship.** Never modify fields that already have values. Never overwrite Peter's edits.
2. **No deletions.** Librarian moves files (log-archive) and adds fields (frontmatter-enforce --fix). It never deletes files or removes field values.
3. **Report before acting.** Default mode is always `--check` / `--dry-run`. Auto-fix requires explicit `--fix` flag.
4. **Skip non-content files.** Ignore `.json`, `.DS_Store`, `.obsidian/`, `.git/`, `.claude/`, image files. Also skip `librarian-manifest.json` — it is infrastructure, not content.
5. **Vault Architecture.md is source of truth.** All rules derive from it. If a file violates a rule not in VA.md, it's not a violation.

---

## Intake Contract

Any skill that writes to the vault should read `librarian-manifest.json` before writing and validate against it. This replaces discovery-by-scanning for pre-write validation.

### Protocol

Before writing a vault file, the writing skill reads `~/Documents/Obsidian Vault/Logs/librarian-manifest.json` and validates:

| # | Check | Manifest Path | On Failure |
|---|-------|--------------|------------|
| 1 | **Engagement exists** | `engagements[slug]` — present and check status | Stop, ask Peter. Do not create new engagement structure without approval. |
| 2 | **Project exists** | `engagements[slug].projects[project_slug]` — present and not complete | Stop, ask Peter. |
| 3 | **People file exists** | `engagements[slug].people[]` — path exists | Create it (allowed). Log the creation. |
| 4 | **Tags valid** | `tags.taxonomy` — all tags being written are in the taxonomy | Use closest match or omit. Flag in output. |
| 5 | **Routing destination valid** | `inventory.by_type` + `engagements` structure — target directory exists | Stop, ask Peter. |
| 6 | **No duplication** | `inventory.by_type[*][].path` — no existing file with same name | Stop, ask Peter. |

### Staleness Handling

If `manifest.generated` is >24 hours old, the writing skill should log a warning but proceed. The manifest is advisory, not blocking.

If the manifest is missing entirely, the skill falls back to the old behavioral approach: direct filesystem scanning and the pre-write checklist in Vault Architecture.md.

### Who Reads the Manifest

- **digest-run** — Before writing Inbox/ files: validates engagement list and tag taxonomy for task routing
- **meeting-processor** — Before writing meeting notes: validates engagement/project/people state for tag assignment and attendee wikilink validation
- **process-notes, reconcile-day, briefing** — Covered by vault CLAUDE.md pre-write checklist referencing the manifest
- **Any new skill that writes to the vault** — Must follow this contract

---

## Infrastructure: Vault Manifest

Librarian maintains a persistent state file at `~/Documents/Obsidian Vault/Logs/librarian-manifest.json`. The manifest is a structured snapshot of the vault's current state — file inventory, engagement/project structure, tag usage, cross-reference graph, scan history, and pending issues.

**Purpose:** Skip full vault rediscovery on every run. Diff against current filesystem (glob + mtime comparison) instead of scanning every file. Other skills read the manifest to validate their writes before committing them.

### Schema (v1)

```json
{
  "generated": "ISO-8601 timestamp",
  "generator": "librarian",
  "version": 1,

  "inventory": {
    "by_type": {
      "engagement": [
        { "path": "relative/to/vault", "mtime": "ISO", "frontmatter_status": "ok|issues", "issues": [] }
      ],
      "project": [],
      "people": [],
      "meeting": [],
      "daily": [],
      "briefing": [],
      "inbox": [],
      "strategic": [],
      "planning": [],
      "reference": [],
      "log": [],
      "skill_spec": [],
      "other": []
    },
    "total_files": 0,
    "total_content_files": 0
  },

  "engagements": {
    "{slug}": {
      "name": "Display Name",
      "status": "active|complete",
      "path": "Engagements/{Name}/",
      "projects": {
        "{slug}": {
          "name": "Display Name",
          "status": "planning|active|paused|complete",
          "path": "Engagements/{Name}/Projects/{Project}/"
        }
      },
      "people": [
        { "name": "Full Name", "path": "Engagements/{Name}/People/{Name}.md" }
      ]
    }
  },

  "tags": {
    "taxonomy": {
      "engagement": ["#engagement/cdmo-ddx", "#engagement/walmart", "#engagement/tiffany", "#engagement/artefact-bd"],
      "project": ["#project/b2c-renovate", "#project/bar-dashboard", "#project/1p-acquisition", "#project/gold-layer-qa"],
      "scope": ["#scope/decision", "#scope/action-item", "#scope/essay", "#scope/braindump", "#scope/inbox"],
      "status": ["#status/processed", "#status/pending", "#status/needs-review"]
    },
    "in_use": { "#engagement/cdmo-ddx": 0 },
    "orphaned": [],
    "unrecognized": []
  },

  "xref_graph": {
    "summary": {
      "total_edges": 0,
      "total_orphaned": 0,
      "total_broken": 0
    },
    "orphaned_files": [],
    "broken_links": [
      { "source": "path", "target": "[[link]]", "line": 0 }
    ],
    "edges_file": "librarian-manifest-edges.json"
  },

  "scan_state": {
    "last_full_scan": "ISO",
    "last_scoped_scan": "ISO",
    "findings_by_capability": {
      "frontmatter-enforce": { "last_run": "ISO", "issues": 0, "auto_fixed": 0 },
      "xref-check": { "last_run": "ISO", "issues": 0 },
      "log-archive": { "last_run": "ISO", "archived": 0, "remaining": 0 },
      "stale-detect": { "last_run": "ISO", "stale": 0 },
      "placement-validate": { "last_run": "ISO", "issues": 0 }
    }
  },

  "pending_issues": [
    {
      "id": "FM-001",
      "capability": "frontmatter-enforce",
      "file": "path",
      "issue": "description",
      "classification": "manual",
      "since": "ISO"
    }
  ],

  "backend_sync": {
    "skill_runtimes": {
      "{name}": {
        "backend_path": "~/.claude/skills/{name}/SKILL.md",
        "vault_copy_path": ".claude/skills/{name}.md",
        "in_sync": true,
        "backend_mtime": "ISO",
        "vault_mtime": "ISO"
      }
    }
  },

  "architect_recommendations": {
    "last_scanned_log": "architect-2026-04-02-gold-layer-qa.md",
    "recommendations": [
      {
        "id": "R-001",
        "title": "...",
        "source_log": "architect-2026-03-30.md",
        "status": "tracked|deferred|completed|rejected",
        "backlog_entry": true,
        "last_checked": "2026-04-02"
      }
    ]
  },

  "drift_findings": {
    "schema_version": 1,
    "last_scan": "ISO",
    "provides_canonicality": [
      {
        "id": "DC-001",
        "type": "provides-canonicality-drift",
        "severity": "blocking|warning",
        "capability": "task-rules",
        "owners": ["Vault Architecture - Inbox.md", "Vault Architecture - Tasks.md"],
        "first_seen": "ISO",
        "remediation": "Designate one canonical owner..."
      }
    ],
    "size_monitoring": [
      {
        "id": "SM-001",
        "type": "size-warning-soft|size-warning-strong|size-guard-violation",
        "severity": "info|warning|blocking",
        "file": "Vault Architecture.md",
        "declared_max": 400,
        "declared_source": "frontmatter|default_root",
        "actual_lines": 681,
        "pct_of_max": 170.2,
        "delta": 281,
        "first_seen": "ISO",
        "recommendation": "Convert to hub-spoke: ..."
      }
    ]
  },

  "drift_allowlist": {
    "provides_overlap": []
  }
}
```

**Schema notes:**
- `inventory.by_type` uses the same file-type detection logic as `frontmatter-enforce` (path-pattern matching). No new detection logic.
- `engagements` is derived by scanning `Engagements/*/` directories and reading Overview frontmatter for status + PRD frontmatter for project status. Also includes `Artefact-BD/` with its own structure.
- `xref_graph` stores summary stats and broken/orphaned lists inline. Full edge list goes to a companion file (`librarian-manifest-edges.json`) only when >1000 edges — otherwise inline under an `edges` array.
- `pending_issues` carries forward unresolved manual-classification findings across runs so they don't get rediscovered every time. Auto-fixed items are removed on the run that fixes them.
- `backend_sync` covers global skills: session-close, digest-run, design-audit, meeting-processor, librarian, architect.
- `architect_recommendations` tracks triaged `[R-NNN]` recommendations from architect logs. Populated by the `architect-triage` capability. Prevents re-proposing previously triaged items.

### Manifest Generation Process

**Runs as the final step of every librarian invocation** (any capability, any scope):

1. **If manifest does not exist:** Generate from scratch.
   - Full vault glob to enumerate all `.md` files (excluding `.obsidian/`, `.git/`)
   - Classify each file by type using path-pattern matching
   - Parse frontmatter for each content file
   - Extract all wikilinks for xref_graph
   - Scan engagement/project/people structure
   - Compute tag usage counts
   - Write full manifest

2. **If manifest exists:** Load and diff.
   - Glob all `.md` files, compare against manifest inventory
   - **New files** (in glob, not in manifest): classify, parse frontmatter, extract links, add to inventory
   - **Modified files** (mtime differs): re-parse frontmatter, re-extract links, update inventory entry
   - **Deleted files** (in manifest, not in glob): remove from inventory, remove outbound edges, flag inbound edges as newly broken
   - **Engagement/project structure:** re-scan only if any file in `Engagements/` or `Artefact-BD/` has changed mtime
   - **Tags:** recompute `in_use` counts from inventory entries (cheap — iterate manifest, not files)

3. **Merge findings:** Capability findings from this run update `scan_state.findings_by_capability`. New manual items added to `pending_issues`. Auto-fixed items removed from `pending_issues`.

4. **Write manifest** to `~/Documents/Obsidian Vault/Logs/librarian-manifest.json` (overwrite).

### Manifest as API

Other skills **read** the manifest (never write). Available data:

| Need | Manifest Path |
|------|--------------|
| Active engagements and status | `engagements[slug].status` |
| Projects within an engagement | `engagements[slug].projects` |
| People files per engagement | `engagements[slug].people[]` |
| Valid tag taxonomy | `tags.taxonomy` |
| Whether a routing destination exists | `inventory.by_type` + `engagements` structure |
| Existing files (duplicate check) | `inventory.by_type[*][].path` |
| Known broken links | `xref_graph.broken_links` |
| Last scan results | `scan_state.findings_by_capability` |

**Staleness:** If `generated` is >24 hours old, consuming skills should log a warning but proceed. The manifest is advisory, not blocking. If the manifest is missing entirely, skills fall back to direct filesystem scanning (the old behavioral approach).
