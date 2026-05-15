---
name: backlog-research
description: >
  Deep research on a triaged System Backlog item. Reads the vault, the user's
  infrastructure, and external best practices, then writes an ideation brief plus
  a draft plan directory. Use when a backlog item needs research before planning.
  Trigger on: "research this backlog item", "backlog research", "/backlog-research",
  or any request to investigate feasibility of a system project idea.
disable-model-invocation: false
argument-hint: "<backlog-item-name> [--budget <dollars>]"
---

# Backlog Research

Once an idea has been triaged as NOVEL, the next question is: "is this actually
buildable, and what would it take?" Doing that by hand means flipping between vault
docs, the user's `~/.claude/` configuration, the relevant skill specs, and external
prior art. This skill does the full pass in one session: it loads vault context,
walks infrastructure dependencies, runs targeted external research, assesses
feasibility on four dimensions, and writes a structured ideation brief at the
canonical location. If the recommendation is PROCEED, it also generates a draft
plan directory (`spec.md`, `tasks.md`, `manifest.json`) so a build session can
start immediately. A per-session budget cap keeps research from spiralling.

Curly-brace tokens (`{vault.root}`, `{paths.plans_root}`, `{backlog.index_path}`,
`{paths.hooks_state}`, `{foundation_repo}`, etc.) resolve at runtime from
`user-manifest.json` via `lib/paths.sh`. When `vault.context_documents[]` is unset,
it defaults to `["CLAUDE.md"]`. When `dashboard.enabled` is `false`, dashboard
read steps are skipped cleanly.

## Output Contract

**Files written:**
- `{paths.plans_root}/<NN>-<slug>/00-ideation-brief.md` — the canonical ideation brief.
- `{paths.plans_root}/<NN>-<slug>/spec.md`, `tasks.md`, `handoff.md`, `manifest.json` — only when the recommendation is PROCEED or MERGE.
- `{vault.root}/Logs/ideation-brief-<slug>.md` — symlink to the canonical brief for vault visibility.
- `{backlog.index_path}` — in-place row update: status `researching` → `briefed`, Plan column populated, Notes annotated with research date and recommendation.
- `{backlog.progress_dir}/<slug>.md` — satellite progress log entry.
- On failure: a JSONL diagnostic at `{paths.hooks_state}/backlog-research-errors.jsonl`; no partial plan directory.

**Schema:** `ideation-brief` against `governance/frontmatter-rules.json#types`; `plan-spec`, `plan-tasks`, `plan-handoff`, `plan-manifest` against `plans-schema.json`.

**Pre-write validation:**
1. The target backlog item is in `triaged` or `researching` status — refuse `idea`-status items (must triage first).
2. Next-available `NN-` prefix computed by inspecting `{paths.plans_root}/`.
3. Slug rejected if it matches the auto-generated meaningless-slug pattern.
4. Plan-artifact frontmatter emitted on every generated file (validated against `plans-schema.json` before write).
5. Vault symlink only created if `{vault.root}/Logs/` is writable and no collision exists.
6. Backlog row edit preserves table structure and touches only the target row.
7. Budget cap enforced — refuse to commit if session spend exceeded `--budget`.

**Failure mode:** the skill aborts on validation failure rather than writing partial state. ALL writes in the transaction are atomic — no half-populated plan directory ever lands on disk. Diagnostic logged to `{paths.hooks_state}/backlog-research-errors.jsonl`.

## Hard rules

1. **Only research triaged or researching items.** Refuse `idea`-status items; tell the user to run `/backlog-triage` first.
2. **Budget cap.** Default $8 per research session. Override with `--budget`. Never exceed.
3. **Concrete file paths.** Every vault impact and infrastructure dependency must reference specific paths, not vague descriptions.
4. **Template compliance.** Output follows the templates in `{foundation_repo}/templates/` exactly.
5. **No modifications.** Research reads and analyzes. The only files it writes are the ideation brief, the draft plan artifacts, and the backlog status update. Vault files, skills, and infrastructure are read-only.
6. **Source attribution.** Every external research finding includes a source URL or reference.

## Invocation

```sh
/backlog-research "<backlog-item-name>"
/backlog-research "<backlog-item-name>" --budget 3
```

| Flag | Default | Purpose |
|---|---|---|
| `--budget N` | 8 | Maximum dollar spend on this research session |

---

## Execution

### 1. Validate input

Read `{backlog.index_path}`. Find the named item.
- If the row doesn't exist: abort and tell the user to file via `/backlog-triage` first.
- If status is `idea`: refuse and tell the user to triage first.
- If status is `triaged`: update to `researching` and refresh Last Updated.
- If status is `researching`: continue (resuming a prior session).

### 2. Gather vault context

Read these to understand current system state:

| Source | What to extract |
|---|---|
| Each path in `{vault.context_documents[]}` (default `["CLAUDE.md"]`) | Vault structure, behavioral rules, routing conventions, file specs. Iterate the array; missing files log a warning and continue. |
| `{backlog.index_path}` | Related items (from triage), dependency chain |
| `$CLAUDE_HOME/settings.json` | Hooks, MCP servers, permissions — infrastructure constraints |
| `$CLAUDE_HOME/skills/*/SKILL.md` | Skills that this item would interact with — read their interfaces |

Targeted reads based on the item type:
- Project-area-specific items: read that area's local `CLAUDE.md` (if present).
- Skill-specific items: read that skill's full SKILL.md.
- Dashboard items: read relevant files under `{dashboard.path}/` (skipped when `dashboard.enabled == false`).
- Scraper / pipeline items: read the relevant capability spec under `{foundation_repo}/`.

### 3. Analyze infrastructure dependencies

Identify what infrastructure the item requires:
- **Hooks** — does it need new PreToolUse / PostToolUse / SessionEnd hooks?
- **MCP servers** — does it need MCPs not currently connected?
- **Scheduled tasks** — does it need cron / launchd automation?
- **External tools** — does it need CLI tools, APIs, browser automation, hardware?
- **Existing skills** — what skills must complete or be modified first?

### 4. External research

Use `WebSearch` and `WebFetch` to investigate best practices, prior art, and known pitfalls. Target 3-5 high-quality sources, prioritizing official documentation, implementation case studies, and architecture-pattern references.

Skip this step entirely if the item is purely internal vault/skill work with no external dependencies.

### 5. Assess feasibility

Evaluate across four dimensions:

| Dimension | Question |
|---|---|
| Complexity | How many files, skills, and systems does this touch? (Low / Medium / High) |
| Sessions | How many Claude sessions to build? |
| Cost | Estimated $ per session and total |
| Confidence | How sure are we this approach works? (High / Medium / Low) |

Identify technical risks with likelihood and mitigation for each.

### 6. Consider alternatives

For every item, identify at least one alternative approach. Compare on implementation effort, maintenance burden, integration complexity, and future extensibility.

### 7. Write the ideation brief

The canonical location is `{paths.plans_root}/<slug>/00-ideation-brief.md`. The plan folder is the single source of truth — never write the brief to `{vault.root}/Logs/` as a primary destination.

1. Determine the project slug from the item name (lowercase, hyphenated). Reject auto-generated meaningless slugs.
2. Compute the next-available `NN-` prefix by listing `{paths.plans_root}/` and incrementing the highest existing prefix.
3. Create `{paths.plans_root}/<NN>-<slug>/`.
4. Write `00-ideation-brief.md` with canonical frontmatter:
   ```yaml
   ---
   title: <Project Name> — Ideation Brief
   type: ideation-brief
   status: planned
   created: YYYY-MM-DD
   updated: YYYY-MM-DD
   ---
   ```
   Render the body from `{foundation_repo}/templates/ideation-brief-template.md`. Fill every section. No placeholders, no TBDs.
5. Create the vault-visible symlink: `ln -s {paths.plans_root}/<NN>-<slug>/00-ideation-brief.md "{vault.root}/Logs/ideation-brief-<slug>.md"`. The user can then open the brief from either the plans tree or `Logs/`. If a regular file already exists at the Logs/ path with identical content, replace it with the symlink. If the content differs, abort and flag — never overwrite a `Logs/` brief with a different file.

**Permission-restricted fallback:** if `mkdir {paths.plans_root}/<NN>-<slug>/` fails (autonomous cron sessions running with restricted permissions), write the brief to `{vault.root}/Logs/ideation-brief-<slug>.md` directly. The next librarian sweep migrates it to the canonical location and replaces the `Logs/` file with a symlink. The cron wrapper at `{foundation_repo}/orchestrator/cron-wrappers/backlog-research-cron.sh` performs a dual-path check so no item is marked failed during the transition.

### 8. Generate draft plan artifacts

If the recommendation is **PROCEED** or **MERGE**, generate the draft plan in the same session — the research context is already loaded, so re-loading it would waste budget.

1. Read the templates and schema:
   - `{foundation_repo}/templates/spec-template.md`
   - `{foundation_repo}/templates/tasks-template.md`
   - `{foundation_repo}/schemas/plan-manifest-schema.json`

   Both Markdown templates ship with canonical plan-artifact frontmatter stubs. Substitute placeholders: `{{title}}` → the human-readable project name, `{{date}}` → today (YYYY-MM-DD), `{{plan_dir}}` → `{paths.plans_root}/<NN>-<slug>`. The resulting file MUST carry a canonical `type:` value (`spec` or `tasks`) — never `<none>`, `reference`, or a log-shape value.

2. Generate `spec.md`. Set Status to `planned`. Include concrete file paths, design decisions, and constraints. The spec should be complete enough for a developer to implement without re-reading the brief.

3. Generate `tasks.md`. Break the work into 3-8 tasks with clear dependencies. Every task MUST include File References (absolute paths). Acceptance Criteria: 3-5 verb-first bullets each. Descriptions: 200-800 tokens each.

4. Generate `manifest.json` against `plan-manifest-schema.json`:
   - `project`: the backlog item name
   - `spec_path`: the absolute path to `spec.md`
   - Task IDs: `T-1`, `T-2`, ...
   - Sensible `max_budget_usd` per task (default 5)
   - Use `parallel_group` where tasks are independent and don't share file_references

5. Run `{foundation_repo}/orchestrator/validate-manifest.sh` as a self-check. If validation fails, fix the manifest before continuing.

Skip this step entirely if the recommendation is DEFER, MERGE (into another item), or KILL — draft plans for non-PROCEED items waste budget.

### 9. Update the backlog

In `{backlog.index_path}`:
1. Update the row's status: `researching` → `briefed`.
2. Update the Location column with a link to the ideation brief (and the plan directory if Step 8 ran).
3. Update Last Updated to today.
4. Update Notes: "Ideation brief complete. Recommendation: <PROCEED/DEFER/MERGE/KILL>." Add "Draft plan generated — review spec + tasks before setting `planned`." if Step 8 ran.

This skill updates an existing row; it never creates new ones. If no row exists at Step 1, it aborts (see Step 1). When Step 8 generates a new plan directory, the existing row's Location column MUST be updated to link the plan slug; otherwise the next librarian sweep flags a missing-backlog-row finding against the new plan root.

### 10. Report

```
## Research Complete: <item name>

Recommendation: <PROCEED | DEFER | MERGE | KILL>
Complexity: <Low | Medium | High>
Estimated sessions: <N-M>
Brief: {paths.plans_root}/<NN>-<slug>/00-ideation-brief.md

Key findings:
- <finding 1>
- <finding 2>
- <finding 3>

Next step: <e.g. "Ready for plan creation" or "Merge into <item>">
```
