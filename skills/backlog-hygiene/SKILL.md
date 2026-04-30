---
name: backlog-hygiene
description: >
  Scan the System Backlog for stale items, enforce lifecycle timeouts, auto-archive
  completed items, and produce a hygiene report. Use as a scheduled maintenance task
  or on demand.
  Trigger on: "backlog hygiene", "clean up backlog", "/backlog-hygiene", "stale backlog items",
  or any request to audit backlog freshness and lifecycle compliance.
disable-model-invocation: false
argument-hint: "[--auto-archive] [--dry-run] [--fix]"
---

# Backlog Hygiene

Scan the System Backlog for stale items, enforce lifecycle timeouts, auto-archive
old completed items, and produce a structured hygiene report. Designed for both
manual invocation and scheduled automation.

## Path Resolution

Curly-brace tokens (`{backlog.index_path}`, `{backlog.archive_path}`, `{backlog.progress_dir}`, `{backlog.clusters[]}`, `{paths.hooks_state}`) are resolved at runtime from `user-manifest.json` via `lib/paths.sh`. Shell-style `$BACKLOG_INDEX_PATH` etc. denote the same values exported as environment variables for runtime use. When `backlog.clusters[]` is unset or empty, the cluster H2 list defaults to `["Infrastructure", "Skills", "Content"]`.

## Output Contract

**Writes to:**
- `{backlog.index_path}` (row removals from active tables, Notes annotations)
- `{backlog.archive_path}` (archived rows appended under matching cluster H2)
- `{paths.hooks_state}/backlog-hygiene-report.md` (hygiene report)

**Schema:** N/A (System Backlog is a standalone file, not a vault-schema.json type; report is outside vault)
**Pre-write validation:**
1. Backlog table structure preserved (columns, separators, row data intact)
2. Archived rows retain all original data — only location in file changes
3. Report written to known state path, never to vault
**Failure mode:** **block and log** — never "write and hope". On validation failure, abort the write, log the error, surface the failure to the user.
**Librarian's role:** Post-hoc audit confirming contract was met. Not first line of defense.

## Hard Rules

1. **Never delete entries.** Stale items are flagged or archived, never removed.
2. **Auto-archive only moves to archive section.** All data preserved — plan references, notes, dates.
3. **Dry-run is safe.** With `--dry-run`, produce the report but make zero changes.
4. **Report always written.** Even if no issues found, write the report (with "all clear" status).
5. **Date math uses Last Updated column.** Not file modification times or git history.

## Invocation

`/backlog-hygiene`
`/backlog-hygiene --auto-archive`
`/backlog-hygiene --dry-run`

| Flag | Default | Purpose |
|------|---------|---------|
| `--auto-archive` | off | Actually move `complete` >30d items to archive section. Without this flag, only flags them. |
| `--dry-run` | off | Report only, no backlog modifications |
| `--fix` | off | Apply safe auto-fixes: generate skeleton satellite file for R-30 (sentinel present, satellite missing). Never auto-fixes R-29 (oversize) or R-31 (orphan) — both require judgment. Mutually exclusive with `--dry-run`. |

---

## Execution

### Step 1: Load Backlog

Read `{backlog.index_path}` in full. Parse every entry across all sections. For each entry, extract:
- Project name
- Status
- Last Updated date
- Notes
- Location (for checking if referenced artifacts exist)

Calculate `days_stale` = today's date minus Last Updated date.

### Step 2: Apply Staleness Rules

Check each entry against the following timeout rules:

| Status | Timeout | Condition | Severity | Recommended Action |
|--------|---------|-----------|----------|-------------------|
| `triaged` | 7 days | No promotion to `researching` or `briefed` | Warning | Promote to research or defer with reason |
| `researching` | 3 days | No research output produced | Alert | Check if research session failed; restart or defer |
| `briefed` | 14 days | No plan created, no decision recorded | Warning | Review brief and decide: plan, defer, or kill |
| `active` | 7 days | No file changes in related plan/skill dirs | Alert | Check if blocked; update Notes with blocker or mark complete |
| `complete` | 30 days | Still in main section, not archived | Info | Archive (move to archive section) |

**For `researching` items:** Check if an ideation brief exists at the Location path. If brief exists but status wasn't updated, that's a missed status update, not a stale item — flag differently.

**For `active` items:** Check if the plan file referenced in Location has been modified in the last 7 days (use `git log` on the plan directory if available). If recent git activity exists, the item is active despite the Last Updated column — flag as "needs Last Updated refresh" instead.

### Step 3: Check Lifecycle Integrity

Beyond staleness, check for structural issues:

| Check | Condition | Severity |
|-------|-----------|----------|
| **Missing Location** | `planned` or later status with no Location link | Error |
| **Orphaned plans** | Location points to a file that doesn't exist | Error |
| **Stuck dependencies** | Item blocked by another item whose status is `archived` or `complete` — dependency resolved, should unblock | Warning |
| **Status regression** | Item went backward in lifecycle without Notes explanation | Warning |
| **Duplicate triage results** | Multiple items with identical Triage Result=`duplicate` pointing at same target | Info |

### Step 3b: Apply Structural Rules (R-29, R-30, R-31)

Scan every row in `{backlog.index_path}` and every file in `{backlog.progress_dir}`.

**R-29 — Row Oversize:** For each row, compute `char_count` as the raw byte length of the full Markdown row (leading `|` through trailing `|`).
- `char_count > 4000`: **Hard block.** Add Error finding to report with `severity: error`, `rule: R-29`, `action: "MUST migrate to sentinel pattern before next backlog write"`. If other pending backlog writes exist this session, halt them.
- `2000 <= char_count <= 4000`: **Soft warn.** Add Warning finding, `rule: R-29`, `action: "Migrate to sentinel pattern"`. Do not block.
- `char_count < 2000`: pass.

Never auto-fix R-29 — migration to sentinel pattern requires choosing what to hoist to the satellite, which is a judgment call.

**R-30 — Satellite Missing:** For each row whose Notes cell matches the sentinel regex `See \[\[Logs/backlog-progress/([^\]]+)\.md\]\]`, verify the referenced file exists.
- File missing: Error finding, `rule: R-30`, `action: "Generate skeleton satellite"`.
- With `--fix`: Create the satellite at the referenced path using the skeleton template (see R-30 Enforcement Rules section below). Populate `title`, `parent_plan` (if the row's Location column points at a plan slug — extract from `[[...]]`), `date`, `timestamp`, `created`, `updated` = today. Re-read the file after write to verify frontmatter validates against `vault-schema.json` for `type: log`. If validation fails, delete the partial file and downgrade to error-report-only.
- Without `--fix`: report only.

**R-31 — Satellite Orphan:** Enumerate every `.md` file under `{backlog.progress_dir}`. For each, grep `{backlog.index_path}` for a sentinel reference to that exact filename.
- No reference found: also grep `{backlog.archive_path}`. If found there, suppress the finding (archived-row satellite is expected to linger).
- No reference in either: Audit finding, `rule: R-31`, `action: "Verify orphan is intentional; no auto-fix"`.

Never auto-fix R-31 — deletion requires verifying the satellite isn't load-bearing for a recently-archived row whose sentinel was stripped during archiving.

### Step 4: Auto-Archive (if --auto-archive)

For items matching **any** of: `complete` / `completed` / `done` + >30 days, **or** `superseded` / `replaced` / `obsolete` (no age threshold — archive immediately):

1. Find the item's current table row in `{backlog.index_path}`
2. Read the row's `Category` column (maps to cluster name)
3. Map category → H2 section name in `{backlog.archive_path}`. Cluster H2s are read from `backlog.clusters[]` in `user-manifest.json`. When unset or empty, the default cluster list is `["Infrastructure", "Skills", "Content"]` and H2 sections are `## Infrastructure`, `## Skills`, `## Content`. If category maps to an unknown cluster, fall back to the source file's H2 parent section.
4. If the target H2 does not exist in `{backlog.archive_path}`, create it with the same column structure as `{backlog.index_path}`:
   ```
   | Project | Status | Category | Type | Scope | Location | Dependencies | Last Updated | Notes |
   |---------|--------|----------|------|-------|----------|--------------|--------------|-------|
   ```
5. Append the row verbatim to the target H2's table
6. Append ` (archived {YYYY-MM-DD})` to the Notes column of the archived row
7. Remove the row from `{backlog.index_path}`
8. Re-read both files after the move to verify: row count in Archive increased by 1, row count in Backlog decreased by 1, no accidental edits to other rows

**Skip auto-archive if `--dry-run` is set.**

**Never edit any row's data fields other than appending the archived annotation to Notes.**

### Step 5: Write Hygiene Report

Write report to `{paths.hooks_state}/backlog-hygiene-report.md`:

```markdown
# Backlog Hygiene Report

**Date:** {YYYY-MM-DD}
**Items scanned:** {N}
**Issues found:** {N}
**Auto-archived:** {N or "disabled"}

## Flagged Items

| Item | Status | Days Stale | Severity | Issue | Recommended Action |
|------|--------|------------|----------|-------|-------------------|
| {name} | {status} | {N} | {Warning/Alert/Error/Info} | {description} | {action} |

## Lifecycle Issues

| Item | Issue | Severity | Detail |
|------|-------|----------|--------|
| {name} | {check name} | {severity} | {explanation} |

## Structural Findings (R-29 / R-30 / R-31)

| Rule | Item | Severity | char_count or satellite path | Action |
|------|------|----------|------------------------------|--------|
| R-29 | {row name} | {error/warning} | {N chars} | {sentinel migration required/recommended} |
| R-30 | {row name} | error | {missing satellite path} | {skeleton generated via --fix / pending --fix} |
| R-31 | {orphan satellite path} | audit | {path} | Verify intentional before deletion |

## Summary

- **Warnings:** {N}
- **Alerts:** {N}
- **Errors:** {N}
- **Info:** {N}
- **All clear:** {Yes/No}

{If issues found: "Run `/backlog-hygiene --auto-archive` to archive eligible items."}
{If no issues: "Backlog is healthy. No action needed."}
```

### Step 6: Report to User

Output a concise summary:

```
## Backlog Hygiene Complete

**Scanned:** {N} items
**Issues:** {N} ({breakdown by severity})
**Archived:** {N} items

{Top 3 most urgent items, if any}

Full report: {paths.hooks_state}/backlog-hygiene-report.md
```

---

## Enforcement Rules

### R-29: Row Oversize Hybrid

Applies to every row in `{backlog.index_path}`.

| Threshold | Severity | Action |
|-----------|----------|--------|
| >4000 chars | Hard block | MUST migrate to sentinel pattern before any other backlog write. Log error. |
| 2000-4000 chars | Soft warn | Flag in hygiene report. Recommend sentinel migration but do not block. |
| <2000 chars | Pass | No action. |

Measurement: raw character count of the full Markdown table row (pipe to pipe, including cell content).

Sentinel pattern: replace the row's Notes cell with `See [[Logs/backlog-progress/{slug}.md]]` and move the detail to a satellite file at that path. Satellite frontmatter: `type: log`, `log-type: backlog-progress`, `title`, `parent_plan` (if applicable), `date`, `timestamp`, `created`, `updated`.

### R-30: Satellite Missing

Fires when a backlog row's Notes cell contains a sentinel reference (`See [[Logs/backlog-progress/{slug}.md]]`) but the referenced satellite file does not exist.

| Severity | Action |
|----------|--------|
| Error | Flag in hygiene report. With `--fix`: generate a skeleton satellite with correct frontmatter and a `## Plan Shape` + `## Session Log` scaffold. Without `--fix`: report only. |

Skeleton satellite template:
```markdown
---
type: log
log-type: backlog-progress
title: {Project Name} — Progress Log
parent_plan: {slug if Location points to a plan}
date: {today}
timestamp: {today}T00:00:00-04:00
created: {today}
updated: {today}
---

# {Project Name} — Progress Log

## Plan Shape

{Pending — fill on first session.}

## Session Log
```

### R-31: Satellite Orphan

Fires when a file exists at `{backlog.progress_dir}/{slug}.md` but no row in `{backlog.index_path}` contains a matching sentinel reference to it.

| Severity | Action |
|----------|--------|
| Audit | Flag in hygiene report. No auto-fix — orphan may be from a recently archived row (check `{backlog.archive_path}` before deleting). |
