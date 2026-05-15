---
name: backlog-hygiene
description: >
  Scan the System Backlog for stale items, enforce lifecycle timeouts, auto-archive
  completed items, and produce a hygiene report. Use as a scheduled maintenance task
  or on demand. Trigger on: "backlog hygiene", "clean up backlog", "/backlog-hygiene",
  "stale backlog items", or any request to audit backlog freshness.
disable-model-invocation: false
argument-hint: "[--auto-archive] [--dry-run] [--fix]"
---

# Backlog Hygiene

Periodic sweep over the vault's System Backlog. Flags timeouts, enforces row-size
and satellite-file conventions, archives finished work into a separate file so
the active list stays scannable. Refuses to delete anything — stale or oversized
rows are flagged, completed items are moved (not deleted) into an archive file
with the same column structure.

Curly-brace tokens in this doc (`{backlog.index_path}`, `{backlog.archive_path}`,
`{paths.hooks_state}`, etc.) resolve at runtime from `user-manifest.json` via
`lib/paths.sh`. Shell-style `$BACKLOG_INDEX_PATH` denotes the same value as an
environment variable. When `backlog.clusters[]` is unset, the cluster list
defaults to `["Infrastructure", "Skills", "Content"]`.

## Output Contract

**Files written:**
- `{backlog.index_path}` — row removals from active tables (only on `--auto-archive`); Notes-cell annotations.
- `{backlog.archive_path}` — archived rows appended under matching cluster H2.
- `{paths.hooks_state}/backlog-hygiene-report.md` — the hygiene report itself.
- With `--fix`: skeleton satellite files at `{backlog.progress_dir}/<slug>.md` for rows whose sentinel reference points to a missing file.

**Schema:** the System Backlog is a standalone Markdown index, not a `governance/frontmatter-rules.json#types` type; the report is written outside the vault. Generated satellite files validate as `type: log` against `governance/foundation-master.json#frontmatter.types` after creation; if validation fails the partial file is deleted and the rule is downgraded to a report-only finding.

**Pre-write validation:**
1. Backlog table structure preserved (column count, separator row, pipe alignment).
2. Archived rows retain all original data — only location in the file changes.
3. The report is always written to `{paths.hooks_state}`, never to the vault.

**Failure mode:** the skill aborts on validation failure rather than writing partial state. On any failure, the original files are untouched and the user is told what went wrong.

## Hard rules

1. **Never delete entries.** Stale items are flagged or archived, never removed.
2. **Auto-archive only moves rows.** All data is preserved — plan references, notes, dates.
3. **Dry-run is safe.** With `--dry-run`, the report is produced and zero changes are written.
4. **Report always written.** Even on "all clear", the report is written so consumers (`morning-brief`) have a fresh data point.
5. **Date math uses the Last Updated column,** not file modification times or git history.

## Invocation

```sh
/backlog-hygiene                    # report-only
/backlog-hygiene --auto-archive     # move complete >30d items into the archive file
/backlog-hygiene --dry-run          # preview without writing
/backlog-hygiene --fix              # generate skeleton satellite files for broken sentinel references
```

| Flag | Default | Purpose |
|------|---------|---------|
| `--auto-archive` | off | Actually move `complete` rows older than 30 days into the archive file. Without this flag, those rows are flagged but left in place. |
| `--dry-run` | off | Produce the report only; make zero changes. |
| `--fix` | off | Apply safe auto-fixes — currently only "generate skeleton satellite when the row's sentinel reference points to a missing file." Mutually exclusive with `--dry-run`. Oversize rows and orphan satellites are never auto-fixed; both require judgment. |

---

## Execution

### 1. Load the backlog

Read `{backlog.index_path}` in full. Parse every entry across all sections. For each entry, extract project name, status, Last Updated date, Notes, and Location.

Calculate `days_stale = today - Last Updated`.

### 2. Apply staleness rules

| Status | Timeout | Trigger | Severity | Recommended action |
|---|---|---|---|---|
| `triaged` | 7 days | No promotion to `researching` or `briefed` | Warning | Promote to research, or defer with reason |
| `researching` | 3 days | No research output produced | Alert | Check whether the research session failed; restart or defer |
| `briefed` | 14 days | No plan created, no decision recorded | Warning | Review the brief and decide: plan, defer, or kill |
| `active` | 7 days | No file changes in related plan/skill dirs | Alert | Check whether blocked; update Notes with blocker, or mark complete |
| `complete` | 30 days | Still in main section, not archived | Info | Archive |

**Refinements:**
- For `researching` items, if an ideation brief exists at the Location path but the row's status wasn't updated, that's a missed status update — flag it as such, not as a stale item.
- For `active` items, if the plan directory referenced in Location has recent git activity, the item is moving even though Last Updated is old — flag as "needs Last Updated refresh" rather than as stale work.

### 3. Check lifecycle integrity

| Check | Trigger | Severity |
|---|---|---|
| Missing Location | `planned` or later status with no Location link | Error |
| Orphaned plans | Location points to a file that doesn't exist | Error |
| Stuck dependencies | Item blocked by another item whose status is `archived` or `complete` (dependency resolved; should unblock) | Warning |
| Status regression | Item went backward in lifecycle without Notes explanation | Warning |
| Duplicate triage | Multiple items with `Triage Result: duplicate` pointing at the same target | Info |

### 3b. Apply structural rules

Three rules govern row size and satellite-file health. Internally these are tracked as R-29 / R-30 / R-31; the underlying constraints are:

**Oversized row:** Long session-by-session history accumulating in a row's Notes cell makes the backlog unreadable. The convention is to hoist that history into a satellite file at `{backlog.progress_dir}/<slug>.md` and replace the Notes cell with a sentinel pointer: `See [[Logs/backlog-progress/<slug>.md]]`.

For each row, compute `char_count` as the raw byte length of the full Markdown row.
- `char_count > 4000`: hard block. Add an Error finding (`action: "MUST migrate to sentinel pattern before next backlog write"`). Halts other pending backlog writes this session.
- `2000 <= char_count <= 4000`: soft warn. Recommends sentinel migration but does not block.
- `char_count < 2000`: pass.

Never auto-fix. Migration to the sentinel pattern requires choosing what to hoist into the satellite, which is a judgment call.

**Missing satellite file:** For each row whose Notes cell matches the sentinel regex `See \[\[Logs/backlog-progress/([^\]]+)\.md\]\]`, verify the referenced file exists.
- File missing: Error finding.
- With `--fix`: create the satellite at the referenced path using the skeleton template (below). After the write, re-read the file and validate its frontmatter as `type: log` against `governance/foundation-master.json#frontmatter.types`. If validation fails, delete the partial file and downgrade to report-only.
- Without `--fix`: report only.

**Orphan satellite:** Enumerate every `.md` file under `{backlog.progress_dir}`. For each, search `{backlog.index_path}` for a sentinel reference to that exact filename.
- No reference found: also search `{backlog.archive_path}`. If found there, suppress (an archived-row satellite is expected to linger).
- No reference in either: Audit finding.

Never auto-fix. Deletion requires verifying the satellite isn't load-bearing for a recently archived row whose sentinel was stripped during archiving.

### 4. Auto-archive (only if `--auto-archive`)

For items matching **any** of: `complete` / `completed` / `done` + over 30 days old, **or** `superseded` / `replaced` / `obsolete` (no age threshold — archive immediately):

1. Find the row's current location in `{backlog.index_path}`.
2. Read the row's `Category` column (maps to a cluster name).
3. Map the category to a cluster H2 in `{backlog.archive_path}`. The cluster list comes from `backlog.clusters[]` in `user-manifest.json`. Defaults to `["Infrastructure", "Skills", "Content"]`. If the category doesn't map to a known cluster, fall back to the source row's H2 parent.
4. If the target cluster H2 doesn't exist in the archive file, create it with the same column structure as the active backlog:
   ```
   | Project | Status | Category | Type | Scope | Location | Dependencies | Last Updated | Notes |
   |---------|--------|----------|------|-------|----------|--------------|--------------|-------|
   ```
5. Append the row verbatim to that table.
6. Append ` (archived YYYY-MM-DD)` to the Notes cell of the archived row.
7. Remove the row from the active backlog.
8. Re-read both files: row count in archive must increase by 1, row count in active backlog must decrease by 1, no other rows touched.

Never edit any column other than appending the archive annotation to Notes. Skip the entire step if `--dry-run` is set.

### 5. Write the hygiene report

Write `{paths.hooks_state}/backlog-hygiene-report.md`:

```markdown
# Backlog Hygiene Report

**Date:** YYYY-MM-DD
**Items scanned:** N
**Issues found:** N
**Auto-archived:** N (or "disabled")

## Flagged items

| Item | Status | Days stale | Severity | Issue | Recommended action |
| ... |

## Lifecycle issues

| Item | Issue | Severity | Detail |
| ... |

## Structural findings

| Rule | Item | Severity | Detail | Action |
| ... |

## Summary

- Warnings: N
- Alerts: N
- Errors: N
- Info: N
- All clear: Yes/No
```

### 6. Report to the user

```
## Backlog Hygiene Complete

Scanned: N items
Issues: N (breakdown by severity)
Archived: N items

[Top 3 most urgent items, if any]

Full report: {paths.hooks_state}/backlog-hygiene-report.md
```

---

## Skeleton satellite template

When `--fix` generates a missing satellite, the file looks like this:

```markdown
---
type: log
log-type: backlog-progress
title: <Project Name> — Progress Log
parent_plan: <slug if Location points to a plan>
date: <today>
timestamp: <today>T00:00:00-04:00
created: <today>
updated: <today>
---

# <Project Name> — Progress Log

## Plan Shape

(Pending — fill on first session.)

## Session Log
```

`parent_plan` is set only when the row's Location column points at a plan slug; otherwise it's omitted.
