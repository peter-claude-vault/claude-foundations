---
name: backlog-research
description: >
  Deep research on a triaged backlog item. Analyzes vault dependencies, system infrastructure,
  and external best practices. Produces an ideation brief with feasibility assessment and
  recommendation. Use when a backlog item needs research before planning.
  Trigger on: "research this backlog item", "backlog research", "/backlog-research",
  or any request to investigate feasibility of a system project idea.
disable-model-invocation: false
argument-hint: "<backlog-item-name> [--budget <dollars>]"
---

# Backlog Research

Deep-dive research on a triaged backlog item. Produces a structured ideation brief
covering vault impact, infrastructure dependencies, external best practices, feasibility,
and a PROCEED/DEFER/MERGE/KILL recommendation.

## Path Resolution

Curly-brace tokens (`{vault.root}`, `{vault.context_documents[]}`, `{paths.plans_root}`, `{paths.hooks_state}`, `{backlog.index_path}`, `{backlog.progress_dir}`, `{dashboard.enabled}`, `{dashboard.path}`, `{foundation_repo}`) are resolved at runtime from `user-manifest.json` via `lib/paths.sh`. Shell-style `$VAULT_ROOT` etc. denote the same values exported as environment variables for runtime use. When `vault.context_documents[]` is unset or empty, the default is `["CLAUDE.md"]`. When `dashboard.enabled` is `false`, dashboard read steps are skipped cleanly.

## Output Contract

**Writes to:**
- `{paths.plans_root}/<nn>-<slug>/00-ideation-brief.md` — canonical ideation brief (R-40 `type: ideation-brief`)
- `{paths.plans_root}/<nn>-<slug>/spec.md` — draft plan spec (R-40 `type: plan-spec`)
- `{paths.plans_root}/<nn>-<slug>/tasks.md` — draft tasks ledger (R-40 `type: plan-tasks`)
- `{paths.plans_root}/<nn>-<slug>/handoff.md` — session-handoff stub (R-40 `type: plan-handoff`)
- `{paths.plans_root}/<nn>-<slug>/manifest.json` — plan manifest (R-40 `type: plan-manifest`)
- `{vault.root}/Logs/ideation-brief-<slug>.md` — symlink to the canonical ideation brief (vault visibility)
- `{backlog.index_path}` — updates target row: Status → `researched`, Plan column → plan path, Notes annotated with research date
- `{backlog.progress_dir}/<slug>.md` — satellite progress log (sentinel-pattern compliance per R-29/30/31)

**Schema:** `ideation-brief` (vault-schema.json); `plan-spec`, `plan-tasks`, `plan-handoff`, `plan-manifest` (plans-schema.json / R-40).

**Pre-write validation:**
1. Target backlog item is in `triaged` or `researching` status — refuse `idea`-status items (must triage first).
2. Next-available NN prefix computed via `ls {paths.plans_root}/ | grep -oE '^[0-9]+' | sort -n | tail -1` + 1 (plan-creation convention rule 2).
3. Slug rejected if it matches the shame-slug regex (`/new-plan` convention).
4. R-40 frontmatter emitted on every plan-artifact file (validated against `plans-schema.json` before write).
5. Vault symlink only created if `{vault.root}/Logs/` is writable and no collision exists.
6. Backlog row edit preserves table structure and touches only the target row.
7. Budget cap enforced — refuse to commit if session spend exceeded `--budget` (default $8).

**Failure mode:** **block and log** — never "write and hope". On any validation failure, abort ALL writes in the transaction (atomicity — never leave a plan directory half-populated). Log diagnostic to `{paths.hooks_state}/backlog-research-errors.jsonl` and surface to user. Partial plan directories constitute contract violation.

## Hard Rules

1. **Only research triaged or researching items.** Refuse to research items in `idea` status — they must be triaged first via `/backlog-triage`.
2. **Budget cap.** Default $8 per research session. Override with `--budget`. Never exceed the cap.
3. **Concrete file paths.** Every vault impact and infrastructure dependency must reference specific file paths, not vague descriptions.
4. **Template compliance.** Output follows `{foundation_repo}/templates/ideation-brief-template.md` exactly.
5. **No modifications.** Research reads and analyzes. It does not modify vault files, skills, or infrastructure. The only files it writes are the ideation brief, draft plan artifacts (spec.md, tasks.md, manifest.json), and backlog status update.
6. **Source attribution.** Every external research finding must include a source URL or reference.

## Invocation

`/backlog-research <backlog-item-name>`
`/backlog-research <backlog-item-name> --budget 3`

| Flag | Default | Purpose |
|------|---------|---------|
| `--budget N` | 8 | Maximum dollar spend on this research session |

---

## Execution

### Step 1: Validate Input

1. Read `{backlog.index_path}`
2. Find the named item
3. Verify status is `triaged` or `researching`
4. If status is `idea`: refuse, tell user to run `/backlog-triage` first
5. If status is `triaged`: update to `researching` and set Last Updated

### Step 2: Gather Vault Context

Read the following to understand current system state:

| Source | What to extract |
|--------|----------------|
| Each path in `{vault.context_documents[]}` (default `["CLAUDE.md"]`, resolved relative to `{vault.root}`) | Vault structure, behavioral rules, structural conventions, routing rules, file specs — whatever the user has configured as canonical context. Iterate the array; missing files log a warning and continue (graceful degrade). |
| `{backlog.index_path}` | Related items (from triage), dependency chain |
| `$CLAUDE_HOME/settings.json` | Hooks, MCP servers, permissions — infrastructure constraints |
| `$CLAUDE_HOME/skills/*/SKILL.md` | Skills that this item would interact with — read their interfaces |

**Targeted reads based on item type:**
- If item touches a specific project area: read that area's local `CLAUDE.md` (if present)
- If item involves a specific skill: read that skill's full SKILL.md
- If item involves the dashboard AND `dashboard.enabled == true`: read relevant files under `{dashboard.path}/` (skip cleanly when `dashboard.enabled == false`)
- If item involves scrapers/pipeline: read the relevant capability spec under `{foundation_repo}/`

### Step 3: Analyze Infrastructure Dependencies

Identify what infrastructure the item requires:

- **Hooks:** Does it need new PreToolUse/PostToolUse/SessionEnd hooks?
- **MCP servers:** Does it need MCP tools not currently connected?
- **Scheduled tasks:** Does it need cron/launchd automation?
- **External tools:** Does it need CLI tools, APIs, browser automation, hardware?
- **Existing skills:** What skills must complete or be modified first?

### Step 4: External Research

Use WebSearch and WebFetch to investigate:

- **Best practices:** How do others solve this problem?
- **Prior art:** Existing tools, libraries, or patterns that could be leveraged
- **Known pitfalls:** What goes wrong when people build this?

Target 3-5 high-quality sources. Prioritize:
1. Official documentation (Anthropic, tool vendors)
2. Implementation case studies
3. Architecture pattern references

Skip this step if the item is purely internal vault/skill work with no external dependencies.

### Step 5: Assess Feasibility

Evaluate across four dimensions:

| Dimension | Question |
|-----------|----------|
| **Complexity** | How many files, skills, and systems does this touch? (Low/Medium/High) |
| **Sessions** | How many Claude sessions to build this? |
| **Cost** | Estimated $ per session and total |
| **Confidence** | How sure are we this approach works? (High/Medium/Low) |

Identify technical risks with likelihood and mitigation for each.

### Step 6: Consider Alternatives

For every item, identify at least one alternative approach. Compare on:
- Implementation effort
- Maintenance burden
- Integration complexity
- Future extensibility

### Step 7: Write Ideation Brief

**Canonical location:** `{paths.plans_root}/{project-slug}/00-ideation-brief.md`. The plan folder is the single source of truth — never write the brief to `{vault.root}/Logs/` as a primary destination.

1. Determine the project slug from the item name (lowercase, hyphenated)
2. Create directory: `{paths.plans_root}/{project-slug}/`
3. Write `{paths.plans_root}/{project-slug}/00-ideation-brief.md` — prepend canonical frontmatter per `plans-schema.json` (R-40), then render the body from `{foundation_repo}/templates/ideation-brief-template.md`:
   ```yaml
   ---
   title: {Project Name} — Ideation Brief
   type: ideation-brief
   status: planned
   created: {YYYY-MM-DD}
   updated: {YYYY-MM-DD}
   ---
   ```
   Required fields per plans-schema.json: `type`, `title`, `status`, `created`, `updated`. Optional: `parent_plan` if this brief is for a sub-plan.
4. Fill every section. No placeholders, no TBDs.
5. **Create vault-visible symlink:** `ln -s {paths.plans_root}/{project-slug}/00-ideation-brief.md "{vault.root}/Logs/ideation-brief-{project-slug}.md"`. This gives the user a single canonical file viewable from both the plans tree (through any `Plans/` symlink the vault may carry) and `{vault.root}/Logs/` (backwards-compatible path for cron and existing backlog entries). If a regular file already exists at the Logs/ path with identical content, replace it with the symlink. If content differs, abort and flag — never overwrite a Logs/ brief with a different file.

**Autonomous/bypassPermissions fallback:** If `mkdir {paths.plans_root}/{project-slug}/` fails due to permission constraints (cron-invoked sessions running with `--permission-mode bypassPermissions`), write the brief to `{vault.root}/Logs/ideation-brief-{project-slug}.md` directly. The next librarian session-close run will migrate it to the canonical location and replace the Logs/ file with a symlink automatically. The cron wrapper at `{foundation_repo}/orchestrator/cron-wrappers/backlog-research-cron.sh` performs a dual-path check (primary path first, Logs/ fallback second) so no item is marked failed during the transition.

### Step 8: Draft Plan Generation

If the recommendation is **PROCEED** or **MERGE**, continue in the same session to generate draft plan artifacts. The research context is already loaded — use it.

1. Read the templates:
   - `{foundation_repo}/templates/spec-template.md`
   - `{foundation_repo}/templates/tasks-template.md`
   - `{foundation_repo}/schemas/plan-manifest-schema.json`

   Both Markdown templates ship with canonical plan-artifact frontmatter stubs per `plans-schema.json` (R-40). Render by substituting the placeholders: `{{title}}` → human-readable project name, `{{date}}` → today's YYYY-MM-DD, `{{plan_dir}}` → `{paths.plans_root}/{project-slug}`. The resulting file must carry a canonical `type:` value (`spec` / `tasks`) — never `<none>`, `reference`, or `log+log-type:ideation-brief`.

2. Generate `{paths.plans_root}/{project-slug}/spec.md`:
   - Follow the spec template structure exactly, substituting placeholders (see template header)
   - Fill all sections from the ideation brief findings
   - Set Status to `planned`, include concrete file paths, design decisions, constraints
   - The spec should be complete enough for a developer to implement without the brief

3. Generate `{paths.plans_root}/{project-slug}/tasks.md`:
   - Follow the tasks template structure exactly, substituting placeholders
   - Break work into 3-8 tasks with clear dependencies
   - Every task MUST have File References (absolute paths)
   - Acceptance Criteria: 3-5 bullets each, all verb-first
   - Descriptions: 200-800 tokens each

4. Generate `{paths.plans_root}/{project-slug}/manifest.json`:
   - Must conform to the manifest schema
   - `project`: the backlog item name
   - `spec_path`: `{paths.plans_root}/{project-slug}/spec.md`
   - Task IDs: T-1, T-2, etc.
   - Set sensible `max_budget_usd` per task (default 5)
   - Use `parallel_group` where tasks are independent and don't share file_references

5. Run `{foundation_repo}/orchestrator/validate-manifest.sh` as a self-check. If validation fails, fix the manifest before proceeding.

**Skip this step** if the recommendation is DEFER, MERGE (into another item), or KILL. Draft plans for non-PROCEED items waste budget.

### Step 9: Update Backlog

In `{backlog.index_path}`:
1. Update item status: `researching` -> `briefed`
2. Update Location column: add link to the ideation brief (and plan directory if Step 8 ran)
3. Update Last Updated to today's date
4. Update Notes: "Ideation brief complete. Recommendation: {PROCEED/DEFER/MERGE/KILL}. {If Step 8 ran: 'Draft plan generated — review spec + tasks before setting planned.'}"

**R-15/R-48 guardrail:** `/backlog-research` updates an EXISTING row — it does not create new ones. If no row for the item exists at Step 1, abort and instruct the user to file via `/backlog-triage` first. If Step 8 ran and generated a new plan directory, the existing row's Location column MUST be updated to link the plan slug; otherwise the next librarian session-close will emit a `backlog-row-missing` finding (R-48) against the new plan root.

### Step 10: Report

Output a summary:

```
## Research Complete: {item name}

**Recommendation:** {PROCEED | DEFER | MERGE | KILL}
**Complexity:** {Low | Medium | High}
**Estimated sessions:** {N-M}
**Brief location:** {paths.plans_root}/{slug}/00-ideation-brief.md

**Key findings:**
- {finding 1}
- {finding 2}
- {finding 3}

**Next step:** {what should happen — e.g., "Ready for plan creation" or "Merge into {item}"}
```
