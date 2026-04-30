---
name: backlog-triage
description: >
  Auto-classify new System Backlog items as NOVEL, DUPLICATE, OVERLAP, or DEFERRED.
  Use when a new idea is added to the backlog or when the user asks to triage a
  backlog item.
  Trigger on: "triage this idea", "backlog triage", "/backlog-triage", or any request
  to classify a new system project idea against the existing backlog.
disable-model-invocation: false
argument-hint: "<idea description> [--item <backlog-item-name>]"
---

# Backlog Triage

Classify new backlog items against the existing System Backlog. Detects duplicates,
overlaps, and items that should be deferred. Updates the backlog entry in-place with
classification metadata.

## Path Resolution

Curly-brace tokens (`{backlog.index_path}`, `{paths.hooks_state}`) are resolved at runtime from `user-manifest.json` via `lib/paths.sh`. Shell-style `$BACKLOG_INDEX_PATH` etc. denote the same values exported as environment variables for runtime use.

## Output Contract

**Writes to:**
- `{backlog.index_path}` — either (a) appends a new row under the target cluster H2 when triaging an inline idea, or (b) updates the target row's Status / Triage-Class / Notes columns when triaging an existing `idea`-status row.

**Schema:** N/A (System Backlog is a standalone index file, not a vault-schema.json type).

**Pre-write validation:**
1. Read full System Backlog before write — confirm target cluster H2 exists and row count parses cleanly.
2. Classification value is exactly one of: `NOVEL` | `DUPLICATE` | `OVERLAP` | `DEFERRED`.
3. Only the target row is modified; all other rows byte-identical before and after.
4. Table structure preserved (column count, separator row, pipe alignment).
5. On `--item` mode, refuse if the target row is not in `idea` status (triage is a one-way transition).

**Failure mode:** **block and log** — never "write and hope". If any validation fails, abort the write, surface the failure to the user, and write diagnostic to `{paths.hooks_state}/backlog-triage-errors.jsonl`. Never write partial state.

## Hard Rules

1. **Read-before-write.** Always read the full System Backlog before classifying.
2. **Conservative duplicate threshold.** Only classify as DUPLICATE when semantic overlap is >80% with an existing item. When in doubt, classify as NOVEL.
3. **Preserve existing data.** Never modify existing backlog entries except the item being triaged.
4. **One item at a time.** Each invocation triages exactly one item.
5. **No auto-promotion past triaged.** Triage sets status to `triaged` at most. Research is a separate step.

## Invocation

`/backlog-triage <idea description>`
`/backlog-triage --item <existing-backlog-item-name>`

| Mode | Input | Action |
|------|-------|--------|
| Inline idea | Free-text description | Add new entry to backlog, then classify |
| Existing item | `--item` flag with item name | Classify an existing `idea` status entry |

---

## Execution

### Step 1: Load Current Backlog

Read `{backlog.index_path}` in full. Parse all entries across all sections. Build an index of:
- Project names
- Status values
- Notes/descriptions
- Category and Type
- Related Items (existing links)

### Step 2: Parse the Input

**Inline idea mode:** Extract the core concept from the user's description. Identify:
- What it does (capability)
- What it touches (vault areas, skills, infrastructure)
- Why it matters (motivation)

**Existing item mode:** Find the named item in the backlog. Read its current Notes field and any linked Location artifacts.

### Step 3: Classify

Compare the input against every existing backlog entry. Evaluate on three axes:

| Axis | Question | Weight |
|------|----------|--------|
| **Functional overlap** | Does an existing item deliver the same capability? | High |
| **Scope overlap** | Does an existing item touch the same files/skills/infrastructure? | Medium |
| **Motivation overlap** | Does an existing item serve the same underlying need? | Low |

**Classification rules:**

| Result | Criteria | Action |
|--------|----------|--------|
| **DUPLICATE** | >80% functional overlap with a single existing item | Link to duplicate. Recommend merge. Do NOT promote to `triaged`. |
| **OVERLAP** | Significant scope or motivation overlap with 1-3 existing items, but distinct functionality | Link related items. Promote to `triaged`. Suggest grouping strategy. |
| **NOVEL** | No significant overlap on any axis | Promote to `triaged`. Flag for `/backlog-research`. |
| **DEFERRED** | Valid idea but blocked by prerequisites, timing, or resource constraints | Keep as `idea` or set to `triaged` with deferred note. Record reason. |

### Step 4: Update Backlog

Modify `{backlog.index_path}`:

**For new ideas (inline mode):**
1. Determine correct section based on Category/Type
2. Add new row to the appropriate table with all columns populated
3. Set Origin to `user-filed`
4. Set Triage Result to the classification
5. Set Status per classification rules above
6. Set Last Updated to today's date
7. **Keep the row compact.** Triage-written rows should stay well under 2000 chars (R-29 soft-warn threshold). Rationale + Related Items + classification note belong in the Notes cell — session-by-session history does NOT. If a row later needs accumulating work history, `/backlog-hygiene` will flag it for sentinel-pattern migration (satellite at `Logs/backlog-progress/<slug>.md`). Do not pre-emptively create a satellite at triage time — NOVEL items have no history yet.

**For existing items (--item mode):**
1. Find the existing row
2. Update: Status (if promoting), Triage Result, Related Items (if OVERLAP/DUPLICATE), Notes (append classification rationale), Last Updated
3. Do NOT modify any other columns
4. If the existing row already uses the sentinel pattern (Notes cell contains `See [[Logs/backlog-progress/<slug>.md]]` or `**Progress Log:** [[Logs/backlog-progress/<slug>|progress log]]`), append the triage note to the satellite's Session Log — NOT to the sentinel row. The row remains a current-state pointer.

### Step 5: Report

Output a concise classification report:

```
## Triage Result: {NOVEL | DUPLICATE | OVERLAP | DEFERRED}

**Item:** {name}
**Classification rationale:** {2-3 sentences explaining why}
**Related items:** {linked items, if any}
**Next step:** {what should happen next — e.g., "Ready for /backlog-research" or "Merge with {item}"}
```

---

## Examples

**NOVEL:** "Build a skill that auto-generates project handoff documents when status changes to COMPLETED"
- No existing skill handles project wind-down document generation
- Touches project structure but distinct from existing cleanup automation
- Result: NOVEL, promoted to `triaged`

**DUPLICATE:** "Create a tool to process meeting transcripts into vault notes"
- meeting-processor already does exactly this
- Result: DUPLICATE, linked to Meeting Processor

**OVERLAP:** "Build automated stale content detection for project files"
- Librarian already has content freshness checks
- But project-specific staleness rules differ from general vault rules
- Result: OVERLAP, linked to Librarian System, suggest as librarian capability extension

**DEFERRED:** "Build Slack integration for real-time vault updates"
- Valid idea but no Slack MCP available, no Slack workspace in scope
- Result: DEFERRED, reason: "No Slack MCP or workspace; revisit when infrastructure exists"
