---
name: morning-brief
description: >
  Generate a concise daily brief that surfaces overnight build results, scheduled
  cron statuses, on-demand review findings, backlog health, and a prioritized
  action-required list. Designed to be injected by the SessionStart hook on the
  first session of the day. Trigger on "/morning-brief", "morning brief", or via
  the user's cron at the configured time.
disable-model-invocation: false
argument-hint: ""
---
> **BLOCKED-BY-REDERIVATION** — see `_doc-overhaul/REDERIVATION-REQUIRED.md`


# Morning Brief

A user with autonomous overnight processes (build crons, librarian sweeps, architect
reviews, backlog research) needs to know in 30 seconds what happened while they
slept. Reading 7 different log files is the wrong shape of work. The morning-brief
is the consolidated pull: it scans build reports, plan-execution logs, scheduled-task
logs, on-demand job logs (with reviewer-finding extraction across three resolution
signals), pending dispatch state, cron-error files, tripwire deltas, and the
backlog-hygiene report. The output is one Markdown file at a stable path, ready
to be injected into the user's first session of the day.

The skill enforces a **never-suppress invariant**: every classification surfaces
somewhere. Findings that look resolved are folded into a summary line rather than
hidden; weakly-resolved findings escalate to a Verify Resolution block; unresolved
findings become Action Required.

Curly-brace tokens (`{vault.root}`, `{paths.hooks_state}`, `{paths.cron_log_dir}`,
`{paths.plans_root}`, `{brief_repos[]}`, `{crons.groups[]}`, `{dashboard.enabled}`,
`{dashboard.path}`) resolve at runtime from `user-manifest.json` via `lib/paths.sh`.
Defaults when unset: `crons.groups[]` → `["librarian", "architect"]`; `brief_repos[]`
→ `[{path: {paths.plans_root}, role: plans}, {path: $CLAUDE_HOME, role: claude-home, exclude: [plans]}]`.
When `dashboard.enabled == false`, the dashboard brief-repo entry is omitted.

## Output Contract

**Files written:**
- `{paths.hooks_state}/morning-brief.md` — the Markdown brief, consumed by the SessionStart hook.
- After SessionStart injection, the file is renamed to `morning-brief-<date>-delivered.md` to prevent re-injection.
- `{paths.hooks_state}/tripwire.log.cursor` — updated to current EOF after a successful brief write (delta-based, not mtime-based).

**Schema:** N/A — the output lives outside the vault.

**Pre-write validation:**
1. All data-source sections are present in the output (each becomes a one-line "no data" row when its source is missing).
2. Action items include specific file paths.
3. The date header matches the current date.

**Failure mode:** the skill aborts on validation failure rather than writing partial state. Graceful degradation across data sources (missing sources produce a one-line "no data" row, not an error); the output is always written.

## Data sources

1. **Overnight build reports** — `{vault.root}/Logs/build-*-{today}.md` and `build-*-{yesterday}.md`.
2. **Backlog hygiene report** — `{paths.hooks_state}/backlog-hygiene-report.md`.
3. **Plan execution logs** — `{paths.cron_log_dir}/plan-execution-*.log`.
4. **Cron group logs** — `{paths.cron_log_dir}/<group>-*.log` for each entry in `{crons.groups[]}`.
5. **Meeting processor logs (optional)** — `{paths.cron_log_dir}/meeting-processor-*.log` if a meeting-processing cron is configured.
6. **Backlog research logs** — `{paths.cron_log_dir}/backlog-research-*.log`.
7. **On-demand job logs** — `{paths.cron_log_dir}/job-*-*.log`.
8. **Pending dispatch** — `{paths.hooks_state}/pending-dispatch.json`.
9. **Cron error files** — `{vault.root}/Logs/*cron-error*.md` and `{vault.root}/Logs/*-error-*.md`.
10. **Tripwire log** — `{paths.hooks_state}/tripwire.log` with the cursor at `{paths.hooks_state}/tripwire.log.cursor`. Records unexpected contents in the placeholder directory the harness occasionally re-creates at `$CLAUDE_HOME/plans/` (any file other than `README.md`) — NOT mere directory existence.

## Execution

### 1. Collect overnight builds

Glob for `build-*-{today}.md` and `build-*-{yesterday}.md` in `{vault.root}/Logs/`. For each, extract project name, status, task count, cost, and `action_required` field.

### 2. Check plan execution

Find the most recent `plan-execution-*.log` in `{paths.cron_log_dir}/` from today or yesterday. Extract project name, status (`success` / `timeout` / `error`), and budget used.

### 3. Check research results

Find the most recent `backlog-research-*.log`. Extract items processed, succeeded/failed counts, and paths to new ideation briefs. Also check the backlog-hygiene report's "Overnight Research Run" section — it lists new briefs awaiting review with their recommendation (PROCEED / DEFER / MERGE / KILL).

### 4. Check scheduled task statuses

For each `<group>` in `{crons.groups[]}`, find the most recent `<group>-*.log` and extract the last `=== ... end:` line to determine SUCCESS / FAILED / timeout. Report the timestamp and status. Optionally check `meeting-processor-*.log` and `backlog-research-*.log` if configured.

### 4b. Cron Health scan

Two surfaces:

- **Vault cron error files.** Glob `{vault.root}/Logs/*cron-error*.md` and `{vault.root}/Logs/*-error-*.md`. **Do NOT use filesystem mtime** — it is unreliable (all files may share an mtime from a recent touch event). Parse the embedded `YYYYMMDD-HHMMSS` timestamp from the filename and include only files where `(now - filename_epoch) <= 48*3600`. Group by cron-name prefix (the entries of `{crons.groups[]}` plus any system-level watchdog name). For each group with errors, record count, latest filename, and the last 20 lines of the newest file for context.

- **Tripwire delta.** Read `{paths.hooks_state}/tripwire.log`. Read the byte offset from `{paths.hooks_state}/tripwire.log.cursor` (default 0 if missing). Any bytes from cursor to EOF are unsurfaced entries; capture those lines. After the brief is written successfully, update the cursor to the current EOF byte offset. First-run behavior (cursor file missing): seed the cursor to current EOF — do NOT surface historical entries.

Reference helper for filename-epoch parsing on macOS:

```bash
cron_error_epoch() {
  local ts
  ts=$(basename "$1" | grep -oE '[0-9]{8}-[0-9]{6}' | head -1)
  [[ -z "$ts" ]] && { echo 0; return; }
  date -j -f "%Y%m%d%H%M%S" "${ts:0:8}${ts:9:6}" +%s 2>/dev/null || echo 0
}
```

### 5. Check on-demand runs and extract reviewer findings

Glob `{paths.cron_log_dir}/job-*-*.log` from today or yesterday. For each, read the header block (lines between `=== job-runner start` and `---`) for `trigger_type`, `requested_by`, and `job_name`. Read the footer block for `cost_usd` and status. Only include logs where `trigger_type: on-demand`. Also check `{paths.hooks_state}/pending-dispatch.json` for jobs scheduled but not yet fired.

Extract `review_ts` from the `=== job-runner start: <iso-ts> ===` line. Validate it matches `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}`. If extraction fails, **skip finding extraction entirely** for that log — substituting epoch or null would widen `--since=""` to all history and silently produce false positives. Emit a single diagnostic line under graceful degradation.

**Finding extraction (per on-demand log).** Wrap the entire pass in try/catch. Any failure (malformed JSON, unreadable brief, git error) emits one diagnostic line (`Finding extraction failed for <log>: <err>`) and continues with the unextended on-demand-run header. No partial state; no LLM calls in the tiering path.

- Read the JSON body between the `---` delimiters. Extract the `result` string and scan the full log for `remediation-briefs/` directory references and `remediation-briefs/\d+-[a-z0-9-]+\.md` path references.
- If direct filename matches exist, use them. Else if a directory reference is found, enumerate `<plan-path>/remediation-briefs/[0-9][0-9]-*.md` from disk. Else fall through to the per-finding fallback below.
- For each brief file, read the frontmatter (`status`, `parent_plan`, `priority`) and the `## File references` + `## Acceptance criteria` sections to collect cited paths.
- Run the three-signal resolution check (below) and classify per-brief as `resolved_authoritative`, `resolved_commit_named`, `verify_resolution`, or `action_required`.
- Emit `{job_name, brief_number, brief_title, classification, shas: [...]}` records for Step 7.

**Per-finding fallback** (reviewer output with no numbered brief files): scan the log text for inline file-path citations of the form `\b[\w/.-]+\.(js|ts|py|sh|md)\b` grouped under each finding ID (e.g. `CF-1`, `I-2`). Run signals 2 and 3 per finding. Coarser than per-brief but preserves the never-suppress invariant.

**Three resolution signals.** Mechanical checks only — no LLM in the tiering path. First hit locks the classification; later signals do not override.

- **Signal 1 (authoritative):** read the brief frontmatter. `status: closed` or `status: deferred` → `resolved_authoritative`. Absence of the field is not an error — proceed to signal 2.
- **Signal 2 (strong):** for each candidate repo (see Brief-Repo Detection), run:
  ```bash
  cd <repo> && git log --grep="[Bb]rief 0*${N}\b" --since="${review_ts}" --format="%H %s"
  ```
  The `0*` absorbs zero-padding so `Brief 2` and `Brief 02` both match. Any output → `resolved_commit_named`; capture SHAs. Union results across repos and dedupe.
  Plan-slug disambiguation: when the plans repo hosts multiple plans with brief-numbering collisions (two plans both having a Brief 02), validate each SHA via `git show --stat ${SHA} | grep -E "${parent_plan}|plan${N_of_parent_plan}"` and drop commits that touch neither the plan's slug nor its numeric prefix.
- **Signal 3 (moderate):** for each cited path, determine the owning repo by path prefix, then:
  ```bash
  cd <owning_repo> && git log --since="${review_ts}" --format="%H %s" -- <cited_path>
  ```
  Any output → `verify_resolution`; capture SHAs. Skip paths that fall outside any known repo.
- **No signals fire:** `action_required`.

**Brief-Repo Detection (manifest-driven).** The brief-repo set is read from `{brief_repos[]}` in `user-manifest.json`. Default seed at install time:
- `{paths.plans_root}` (role: `plans`) — plan-doc commits often name the brief.
- `$CLAUDE_HOME` (role: `claude-home`, exclude: `[plans]`) — orchestrator + capability + skill commits.

When `dashboard.enabled == true`, the installer also appends `{dashboard.path}` (role: `dashboard`).

For Signal 2, the search runs against the union of all manifest-listed repos plus any repo implied by brief-cited paths. For Signal 3, each cited path is matched against each `brief_repos[]` entry's `path` prefix in declared order; first match wins. Each entry may declare an `exclude` list of subpaths; cited paths under an excluded subpath skip that entry. Paths outside any configured repo are skipped for signal 3.

### 6. Check backlog health

If `{paths.hooks_state}/backlog-hygiene-report.md` exists, extract stale-item counts, names, and recommended actions. Include items promoted overnight (researching → briefed, planned → ready).

### 7. Compile action items — three tiers

Route the per-brief classifications from Step 5 to output tiers; other action-item sources (failed crons, tripwire, builds) flow to Action Required unchanged.

| Classification | Output tier | What it surfaces |
|---|---|---|
| `action_required` | **Action Required** (top of brief) | Brief file path. Highest urgency. |
| `verify_resolution` | **Verify Resolution** | The SHAs captured by signal 3 for at-a-glance review of whether the commit actually resolves the brief. |
| `resolved_authoritative` or `resolved_commit_named` | **In Context Only** | NOT promoted. Folded into the On-Demand Runs block as a per-review summary line: `Plan X review: N/M briefs resolved (via <SHAs>); K open — see Action Required\|Verify Resolution`. |

The never-suppress invariant: a resolved-looking finding is downgraded, never hidden. Every classification surfaces somewhere. If finding extraction errors entirely, the on-demand run still writes a single diagnostic line (graceful degradation).

Each action item in Action Required or Verify Resolution must include a specific file path.

### 8. Write the brief

Write to `{paths.hooks_state}/morning-brief.md` in the format below.

## Output format

```markdown
## Morning Brief — YYYY-MM-DD

### Overnight Builds
- <Project>: <STATUS>. <done>/<total> tasks. $<cost>. <action or "No action needed.">
(or "No overnight builds ran." if none found)

### Research Completed
- <Project>: Brief at `{paths.plans_root}/<slug>/00-ideation-brief.md`. Recommendation: <PROCEED|DEFER|MERGE|KILL>.
(or "No new research completed.")

### Scheduled Tasks
- <Group> cron: <SUCCESS|FAILED|NOT RUN> — error context if failed     <-- one row per entry in {crons.groups[]}
- Backlog research (if configured): <STATUS> — <N> items processed
- Plan execution (if configured): <STATUS> — <project name if ran>
(or "No scheduled task logs found.")

### Cron Health
- <group>: <no errors | N errors in last 48h. Latest: Logs/<file>>
- Tripwire (`$CLAUDE_HOME/plans/` unexpected contents): <no new entries | N new entries since last brief: ...>
(or "All cron pipelines healthy, no tripwire hits.")

### On-Demand Runs
- <Job Name>: <STATUS> at <time>. Triggered by <requested_by>. $<cost>.
  - <Plan X review: N/M briefs resolved (via `<SHAs>`); K open — see Action Required|Verify Resolution>
(or "No on-demand runs since last brief.")

### Pending Dispatch
- <Job Name> (<type>) — scheduled for <fire_at>
(omit section entirely if empty)

### Backlog Health
- <N> items stale: "<name>" (<status>, <age>d)
- <N> items promoted overnight: <names and new statuses>
(or "No stale items." / "No backlog hygiene data available.")

### Verify Resolution
- <Plan X, Brief NN — <title>>: signal-3 path-match on `<cited paths>` → candidate resolution in `<SHA> <subject>`. Eyeball to confirm.
(omit section entirely if empty)

### Action Required
1. <Specific action with file path>
2. <Next action>
(or "All systems nominal." if nothing needs attention)
```

## Remediation-brief status convention

Remediation-brief files (`{paths.plans_root}/<slug>/remediation-briefs/<NN>-<slug>.md`) may declare a `status:` field in frontmatter. Optional, opt-in, not hook-enforced. When present it acts as Signal 1 — the cheapest authoritative resolution signal — and short-circuits the git-log-based signals 2 and 3.

Values:
- `open` — unaddressed; promote to Action Required if no other signal fires.
- `closed` — resolved; classify as `resolved_authoritative`; fold into the On-Demand Runs summary.
- `deferred` — intentional non-action; also classify as `resolved_authoritative`.

Absence of the field is not an error.

```yaml
---
type: remediation-brief
parent_plan: <slug>
phase: 2
priority: 1
blast_radius: HIGH
status: open
---
```

When the user or a follow-up session resolves a brief, update the field in place — do NOT delete the brief file. Deletion breaks signal-3 path matching and loses the audit trail.

## Graceful degradation

- Missing data sources produce a single line explaining absence, not an error.
- If ALL sources are missing, write: "No overnight data available. All systems nominal (no data to report)."
- The skill never fails or exits with error — always produces a brief, even if empty.

## SessionStart integration

The brief at `{paths.hooks_state}/morning-brief.md` is consumed by `session-register.sh` on the first `startup` event of the day. After injection, the hook renames the file to `morning-brief-<date>-delivered.md` to prevent re-injection.

## Scheduling

Designed to run as a scheduled cron at the user's configured local time (typically before the first session of the day). The cron invokes `/morning-brief`.
