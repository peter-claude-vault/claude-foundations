# Morning Brief

**Trigger:** `/morning-brief`, "morning brief", or scheduled via the user's cron at the configured time
**Output:** `{paths.hooks_state}/morning-brief.md`

## Path Resolution

Curly-brace tokens (`{vault.root}`, `{paths.hooks_state}`, `{paths.cron_log_dir}`, `{paths.plans_root}`, `{brief_repos[]}`, `{crons.groups[]}`, `{dashboard.enabled}`, `{dashboard.path}`) are resolved at runtime from `user-manifest.json` via `lib/paths.sh`. Shell-style `$HOOKS_STATE` etc. denote the same values exported as environment variables for runtime use. When `crons.groups[]` is unset or empty, the cron group list defaults to `["librarian", "architect"]` (matching the SP03 default autonomous-jobs set). When `brief_repos[]` is unset or empty, the brief-repo set defaults to `[{path: {paths.plans_root}, role: plans}, {path: $CLAUDE_HOME, role: claude-home, exclude: [plans]}]`. When `dashboard.enabled` is `false`, the dashboard brief-repo entry is omitted.

## Output Contract

**Writes to:**
- `{paths.hooks_state}/morning-brief.md` (consumed by SessionStart hook)

**Schema:** N/A (output is outside vault, not a vault-schema.json type)
**Pre-write validation:**
1. All data source sections present (even if degraded to "No data available" fallback)
2. Action items include specific file paths
3. Date header matches current date

**Failure mode:** **block and log** — never "write and hope". On validation failure, abort the write, log the error, surface the failure to the user. Never write invalid data.
**Librarian's role:** Post-hoc audit confirming contract was met. Not first line of defense.

## Purpose

Generate a concise morning brief that surfaces overnight build results, scheduled task status, backlog health, and required actions. Written to a known path for SessionStart hook consumption.

## Data Sources

1. **Overnight build reports:** `{vault.root}/Logs/build-*-{today}.md` and `build-*-{yesterday}.md`
2. **Backlog hygiene report:** `{paths.hooks_state}/backlog-hygiene-report.md` (research results + hygiene findings)
3. **Plan execution logs:** `{paths.cron_log_dir}/plan-execution-*.log` (overnight plan execution cron results)
4. **Cron group logs:** `{paths.cron_log_dir}/<group>-*.log` for each entry in `{crons.groups[]}` (e.g. librarian-*.log, architect-*.log under the default group set)
5. **Meeting processor logs (optional):** `{paths.cron_log_dir}/meeting-processor-*.log` if a meeting-processing cron is configured
6. **Backlog research logs:** `{paths.cron_log_dir}/backlog-research-*.log` (overnight research results)
7. **On-demand job logs:** `{paths.cron_log_dir}/job-*-*.log` (on-demand dispatch runs — distinguished by `trigger_type: on-demand` header)
8. **Pending dispatch:** `{paths.hooks_state}/pending-dispatch.json` (delayed jobs awaiting execution)
9. **Cron error files:** `{vault.root}/Logs/*cron-error*.md` and `{vault.root}/Logs/*-error-*.md` (one error stream per group in `{crons.groups[]}` plus any system-level watchdog stream)
10. **Tripwire log:** `{paths.hooks_state}/tripwire.log` with cursor at `{paths.hooks_state}/tripwire.log.cursor`. Records **unexpected contents** in the placeholder directory the harness occasionally re-creates at `$CLAUDE_HOME/plans/` (any file other than `README.md`) — NOT mere directory existence. The placeholder is permanent; the canary fires only on real stale-reference writes, not harmless cosmetic re-creation.

## Execution Steps

1. **Collect build reports.** Glob for `build-*-{today}.md` and `build-*-{yesterday}.md` in `{vault.root}/Logs/`. For each report, extract: project name, status, task count, cost, and action_required field.

2. **Check plan execution.** Find the most recent `plan-execution-*.log` in `{paths.cron_log_dir}/` from today or yesterday. Extract: project name, status (success/timeout/error), budget used. This is the overnight autonomous build cron.

3. **Check research results.** Find the most recent `backlog-research-*.log` in `{paths.cron_log_dir}/` from today or yesterday. Extract: items processed, succeeded/failed counts, and paths to new ideation briefs. Also check `{paths.hooks_state}/backlog-hygiene-report.md` for the "Overnight Research Run" section — it lists new briefs awaiting review with their recommendation (PROCEED/DEFER/MERGE/KILL).

4. **Check scheduled task statuses.** For each entry `<group>` in `{crons.groups[]}` (default `["librarian", "architect"]`), find the most recent `<group>-*.log` in `{paths.cron_log_dir}/`. Optionally also check `meeting-processor-*.log` and `backlog-research-*.log` if those crons are configured. For each, extract the last `=== ... end:` line to determine SUCCESS/FAILED/timeout. Report the timestamp and status.

4b. **Cron Health scan.** Check two surfaces for failures:
   - **Vault cron error files:** glob `{vault.root}/Logs/*cron-error*.md` and `{vault.root}/Logs/*-error-*.md`. **Do NOT use filesystem mtime** — it is unreliable (all files may share an mtime from a recent touch event). Parse the embedded `YYYYMMDD-HHMMSS` timestamp from each filename and include only files where `(now - filename_epoch) <= 48*3600` (48-hour threshold). Group by cron name prefix, where the prefixes are the entries of `{crons.groups[]}` plus any system-level watchdog name (e.g. a cron-health-banner self-observer if configured). For each group with errors, record: count, latest error filename, and last 20 lines of the newest file for the action-item context.
   - **Tripwire delta:** read `{paths.hooks_state}/tripwire.log`. Read the byte offset from `{paths.hooks_state}/tripwire.log.cursor` (default 0 if missing). Any bytes from cursor to EOF are unsurfaced entries. If non-empty, capture those lines for the output. **After the brief is written successfully**, update the cursor to the current EOF byte offset. First-run behavior (cursor file missing): seed cursor to current EOF — do NOT surface historical entries. This is delta-based, not mtime-based.
   - Reference helper (bash) for filename-epoch parsing:
     ```bash
     cron_error_epoch() {
       local ts
       ts=$(basename "$1" | grep -oE '[0-9]{8}-[0-9]{6}' | head -1)
       [[ -z "$ts" ]] && { echo 0; return; }
       date -j -f "%Y%m%d%H%M%S" "${ts:0:8}${ts:9:6}" +%s 2>/dev/null || echo 0
     }
     ```

5. **Check on-demand runs and extract reviewer findings.** Glob for `{paths.cron_log_dir}/job-*-*.log` from today or yesterday. For each, read the header block (lines between `=== job-runner start` and `---`) to extract `trigger_type`, `requested_by`, `job_name`. Extract `review_ts` from the `=== job-runner start: <iso-ts> ===` line — validate the extracted value matches `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}`; if the match fails or returns empty, **skip finding extraction entirely for this log** (do NOT substitute epoch or null — an empty `--since=""` widens signal 2/3 to all history and silently produces false positives) and emit the single diagnostic line under graceful degradation. Read the footer block for `cost_usd` and status. Only include logs where `trigger_type: on-demand`. Also check `{paths.hooks_state}/pending-dispatch.json` for jobs scheduled but not yet fired.

   **Finding extraction (per on-demand log).** Wrap the entire extraction pass in try/catch. If any step fails — malformed JSON, unreadable brief file, git error — emit a single diagnostic line (`Finding extraction failed for <log>: <err>`) and continue with the unextended on-demand run header for that log. No partial state; no LLM calls in the tiering path.
   - Read the JSON body between the `---` delimiters. Extract the `result` string and scan the full log for `remediation-briefs/` directory references and `remediation-briefs/\d+-[a-z0-9-]+\.md` path references.
   - If direct filename matches exist, use them. Else if a directory reference is found, enumerate `<plan-path>/remediation-briefs/[0-9][0-9]-*.md` from disk. Else fall through to the per-finding fallback below.
   - For each brief file, read frontmatter (`status`, `parent_plan`, `priority`) and the `## File references` + `## Acceptance criteria` sections to collect cited paths.
   - Run the three-signal resolution check (Signal Definitions below) and classify per-brief as `resolved_authoritative`, `resolved_commit_named`, `verify_resolution`, or `action_required`.
   - Emit `{job_name, brief_number, brief_title, classification, shas: [...]}` records for Step 7 consumption.

   **Per-finding fallback** (reviewer output with no numbered brief files): scan the log text for inline file-path citations of the form `\b[\w/.-]+\.(js|ts|py|sh|md)\b` grouped under each finding ID (e.g. `CF-1`, `I-2`). Run signal 2 (`git log --grep="<finding_id>"`) and signal 3 (path-match on cited files) per finding. Coarser than per-brief but preserves the never-suppress invariant.

   **Signal Definitions** (encode literally; mechanical signal checks only — no LLM interpretation in the tiering path; first hit locks classification, later signals do not override):

   - **Signal 1 (authoritative):** read brief frontmatter. `status: closed` or `status: deferred` → `resolved_authoritative`. Absence of the field is not an error — proceed to signal 2.
   - **Signal 2 (strong):** for each candidate repo (see Brief-Repo Detection), run:
     ```bash
     cd <repo> && git log --grep="[Bb]rief 0*${N}\b" --since="${review_ts}" --format="%H %s"
     ```
     The regex `[Bb]rief 0*${N}\b` matches both `Brief 2` and `Brief 02` (the `0*` absorbs zero-padding). Any output → `resolved_commit_named`; capture SHAs. Union results across repos and **dedupe** — if multiple briefs share a resolving commit, the per-review summary line lists each SHA once.
     **Plan-slug disambiguation:** when the plans repo at `{paths.plans_root}` hosts multiple plans with brief-numbering collisions (e.g. two plans both having a Brief 02), validate each SHA by running `git show --stat ${SHA} | grep -E "${parent_plan}|plan${N_of_parent_plan}"` — drop commits that touch neither the plan's slug nor its numeric prefix. Cross-plan false attribution is a known low-likelihood risk; this guard closes it.
   - **Signal 3 (moderate):** for each cited path, determine the owning repo by path prefix, then:
     ```bash
     cd <owning_repo> && git log --since="${review_ts}" --format="%H %s" -- <cited_path>
     ```
     Any output → `verify_resolution`; capture SHAs. Skip paths that fall outside any known repo.
   - **No signals fire:** `action_required`.

   **Brief-Repo Detection (manifest-driven):**

   The brief-repo set is read from `{brief_repos[]}` in `user-manifest.json`. Default seed at install time:
   - `{paths.plans_root}` (role: `plans`) — plan-doc commits often name the brief
   - `$CLAUDE_HOME` (role: `claude-home`, exclude: `[plans]`) — orchestrator + capability + skill commits

   When `dashboard.enabled == true`, the installer additionally appends `{dashboard.path}` (role: `dashboard`) to the set. When `dashboard.enabled == false`, no dashboard entry is added — the brief-repo set is plans + claude-home only.

   - **Signal 2 (per-brief):** union of all manifest-listed repos plus any repo implied by brief-cited paths.
   - **Signal 3 (per-cited-path):** match the cited path against each `brief_repos[]` entry's `path` prefix in declared order; first match wins. The matched entry's `role` selects the repo for `git log` invocation. Each entry may declare an `exclude` list of subpaths; cited paths under an excluded subpath skip that entry and continue scanning. Paths that fall outside any configured repo are skipped for signal 3.
   - If a brief has no cited paths resolvable to any known repo, skip signal 3 and rely on signals 1 and 2.

6. **Check backlog health.** If `{paths.hooks_state}/backlog-hygiene-report.md` exists, extract stale item counts, names, and recommended actions. Include items promoted overnight (researching→briefed, planned→ready).

7. **Compile action items — three tiers for reviewer findings.** Route the per-brief classifications from Step 5 to output tiers; other action-item sources (failed crons, tripwire, builds) flow to Action Required unchanged.

   **Tier routing (per-brief classification → output tier):**
   - `action_required` → **Action Required** (top of brief, highest urgency). Include brief file path.
   - `verify_resolution` → **Verify Resolution** (new block between On-Demand Runs and Action Required). Surface the SHAs captured by signal 3 for at-a-glance review of whether the commit actually resolves the brief.
   - `resolved_authoritative` or `resolved_commit_named` → **In Context Only**. Do NOT promote anywhere. Fold into the On-Demand Runs block as a per-review summary line of the form: `Plan X review: N/M briefs resolved (via <SHAs>); K open — see Action Required|Verify Resolution`.

   **Never-suppress invariant:** A resolved-looking finding is downgraded, never hidden. Every classification surfaces somewhere — signal-3-only hits land in Verify Resolution with SHAs, signal-1/signal-2 hits appear in the On-Demand Runs summary line. If finding extraction errors entirely, the on-demand run still writes under current Step 5 behavior with a single diagnostic line (graceful degradation).

   Aggregate remaining action-item sources unchanged: escalations from builds, failed crons, new briefs awaiting review, stale backlog items, **any Cron Health red-flag row or unsurfaced tripwire entries from Step 4b**. Each action item in Action Required or Verify Resolution must include a specific file path.

8. **Write brief** to `{paths.hooks_state}/morning-brief.md` in the format below.

## Remediation Brief Status Convention

Remediation-brief files (`{paths.plans_root}/<slug>/remediation-briefs/<NN>-<slug>.md`) may declare a `status:` field in frontmatter. Optional, opt-in, not hook-enforced. When present, it is Signal 1 — the cheapest authoritative resolution signal — and short-circuits the git-log-based signals 2 and 3.

**Values:**
- `open` — unaddressed; promote to Action Required if no other signal fires.
- `closed` — resolved; classify as `resolved_authoritative`; fold into On-Demand Runs summary.
- `deferred` — intentional non-action; also classify as `resolved_authoritative` (the user has explicitly decided not to act).

Absence of the field is not an error. The check falls through to signals 2 and 3.

**Example frontmatter:**
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

**Emit site.** Reviewer dispatch prompts (`$CLAUDE_HOME/orchestrator/jobs/*-review.md`) should instruct the reviewer to write `status: open` in newly generated remediation briefs by default. When the user or a follow-up session resolves a brief, update the field in place — do NOT delete the brief file (deletion breaks signal 3 path-match and loses audit trail).

## Output Format

```markdown
## Morning Brief — {YYYY-MM-DD}

### Overnight Builds
- {Project}: {STATUS}. {done}/{total} tasks. ${cost}. {action or "No action needed."}
(or "No overnight builds ran." if none found)

### Research Completed
- {Project}: Brief at `{paths.plans_root}/{slug}/00-ideation-brief.md`. Recommendation: {PROCEED|DEFER|MERGE|KILL}.
(or "No new research completed." if none found)

### Scheduled Tasks
- {Group} cron: {SUCCESS|FAILED|NOT RUN} {— error context if failed}    ← one row per entry in {crons.groups[]} (default: librarian + architect)
- Backlog research (if configured): {SUCCESS|FAILED|NOT RUN} — {N} items processed
- Plan execution (if configured): {SUCCESS|FAILED|NOT RUN} — {project name if ran}
(or "No scheduled task logs found." if log dir empty)

### Cron Health
- {group}: {🟢 no errors | 🔴 N errors in last 48h. Latest: Logs/{file}}    ← one row per entry in {crons.groups[]} plus any system-level watchdog stream
- Tripwire ({$CLAUDE_HOME}/plans/ unexpected contents): {🟢 no new entries | 🔴 N new entries since last brief:\n    {iso-timestamp} {line}}
(or "🟢 All cron pipelines healthy, no tripwire hits." if every row is green)

### On-Demand Runs
- {Job Name}: {STATUS} at {time}. Triggered by {requested_by}. ${cost}.
  - {Plan X review: N/M briefs resolved (via `<SHAs>`); K open — see Action Required|Verify Resolution}  ← summary line per review with extracted findings
(or "No on-demand runs since last brief.")

### Pending Dispatch
- {Job Name} ({type}) — scheduled for {fire_at}
(or "No pending delayed jobs." — omit section entirely if empty)

### Backlog Health
- {N} items stale: "{name}" ({status}, {age}d)
- {N} items promoted overnight: {names and new statuses}
(or "No stale items." / "No backlog hygiene data available.")

### Verify Resolution
- {Plan X, Brief NN — <title>}: signal-3 path-match on `<cited paths>` → candidate resolution in `<SHA> <subject>`. Eyeball to confirm.
(or "No findings awaiting verification." — omit section entirely if empty)

### Action Required
1. {Specific action with file path}
2. {Next action}
(or "All systems nominal." if nothing needs attention)
```

## Graceful Degradation

- Missing data sources produce a single line explaining absence, not an error.
- If ALL sources are missing, write: "No overnight data available. All systems nominal (no data to report)."
- Never fail or exit with error — always produce a brief, even if empty.

## SessionStart Integration

The brief at `{paths.hooks_state}/morning-brief.md` is consumed by `session-register.sh` on the first `startup` event of the day. After injection, the hook renames the file to `morning-brief-{date}-delivered.md` to prevent re-injection.

## Scheduling

Designed to run as a scheduled cron at the user's configured local time (typically early morning before the first session). The scheduled task should invoke `/morning-brief` which triggers this skill.
