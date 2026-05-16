---
name: backlog-triage
description: >
  Auto-classify a new or existing System Backlog item as NOVEL, DUPLICATE, OVERLAP,
  or DEFERRED. Use when a new idea is added to the backlog or when the user asks to
  triage an existing one. Trigger on: "triage this idea", "backlog triage",
  "/backlog-triage", or any request to classify a system project idea against the
  existing backlog.
disable-model-invocation: false
argument-hint: "<idea description> [--item <backlog-item-name>]"
---
> **BLOCKED-BY-REDERIVATION** — see `_doc-overhaul/REDERIVATION-REQUIRED.md`


# Backlog Triage

Cheap-up-front classification step for the System Backlog. Reads the entire backlog,
compares the new idea on three axes (functional / scope / motivation overlap), assigns
one of four classifications, and either appends a new row (inline-idea mode) or updates
the existing `idea`-status row in place (item mode). Triage promotes items at most to
`triaged`; research is a separate, more expensive step.

Curly-brace tokens (`{backlog.index_path}`, `{paths.hooks_state}`) resolve at runtime
from `user-manifest.json` via `lib/paths.sh`.

## Output Contract

**Files written:**
- `{backlog.index_path}` — either (a) a new row appended under the matching cluster H2 (inline-idea mode), or (b) an in-place update to the target row's Status / Triage Result / Related Items / Notes / Last Updated columns (item mode).
- On `--item` mode targeting a row already using the sentinel pattern, the triage note is appended to the satellite file at `Logs/backlog-progress/<slug>.md`, not the row itself.

**Schema:** N/A — the System Backlog is a standalone Markdown index, not a `vault-schema.json` type.

**Pre-write validation:**
1. Read the full backlog before writing — confirm the target cluster H2 exists and the row count parses cleanly.
2. Classification value is exactly one of `NOVEL` / `DUPLICATE` / `OVERLAP` / `DEFERRED`.
3. Only the target row is modified; every other row is byte-identical before and after.
4. Table structure preserved (column count, separator row, pipe alignment).
5. In `--item` mode, refuse if the target row is not in `idea` status — triage is a one-way transition.

**Failure mode:** the skill aborts on validation failure rather than writing partial state. Diagnostic written to `{paths.hooks_state}/backlog-triage-errors.jsonl` and the user is told what went wrong.

## Hard rules

1. **Read-before-write.** Always read the full backlog before classifying.
2. **Conservative duplicate threshold.** Classify as DUPLICATE only when semantic overlap with a single existing item exceeds ~80%. When in doubt, classify as NOVEL.
3. **Preserve existing data.** Never modify any row except the one being triaged.
4. **One item per invocation.**
5. **No auto-promotion past `triaged`.** Triage sets status to `triaged` at most. Research is a separate skill.

## Invocation

```sh
# Inline new idea
/backlog-triage "Build a skill that auto-summarizes long meeting transcripts into 5-bullet briefs"

# Triage an existing idea-status row
/backlog-triage --item "meeting-transcript-summarizer"
```

| Mode | Input | Action |
|---|---|---|
| Inline idea | Free-text description | Adds a new row to the backlog and classifies it |
| Existing item | `--item <name>` | Classifies an existing row that's currently in `idea` status |

---

## Execution

### 1. Load the current backlog

Read `{backlog.index_path}` in full. Build an index of project names, status values, Notes/descriptions, Category, Type, and Related Items.

### 2. Parse the input

**Inline-idea mode:** extract the core concept from the description. Identify what the idea does (capability), what it touches (vault areas, skills, infrastructure), and why it matters (motivation).

**Existing-item mode:** find the named item in the backlog. Read its current Notes field and any linked Location artifacts.

### 3. Classify

Compare the input against every existing entry on three axes:

| Axis | Question | Weight |
|---|---|---|
| Functional overlap | Does an existing item deliver the same capability? | High |
| Scope overlap | Does an existing item touch the same files / skills / infrastructure? | Medium |
| Motivation overlap | Does an existing item serve the same underlying need? | Low |

Classification rules:

| Result | Criteria | Action |
|---|---|---|
| **DUPLICATE** | >80% functional overlap with a single existing item | Link to the duplicate. Recommend merge. Do NOT promote to `triaged`. |
| **OVERLAP** | Significant scope or motivation overlap with 1-3 existing items, but distinct functionality | Link related items. Promote to `triaged`. Suggest a grouping strategy. |
| **NOVEL** | No significant overlap on any axis | Promote to `triaged`. Flag for `/backlog-research`. |
| **DEFERRED** | Valid idea but blocked by prerequisites, timing, or resource constraints | Keep as `idea` or set `triaged` with a deferred note. Record the reason. |

### 4. Update the backlog

**Inline-idea mode:**
1. Determine the correct cluster H2 from Category/Type.
2. Add a new row to that cluster's table with all columns populated.
3. Set Origin to `user-filed`.
4. Set Triage Result to the classification.
5. Set Status per the classification rules above.
6. Set Last Updated to today.
7. **Keep the row compact.** Triage-written rows should stay well under 2000 characters. Rationale, related items, and the classification note belong in the Notes cell — session-by-session history does NOT. If the row later accumulates work history, `/backlog-hygiene` will flag it for migration to a satellite file at `Logs/backlog-progress/<slug>.md`. Don't pre-emptively create a satellite at triage time — NOVEL items have no history yet.

**Existing-item mode:**
1. Find the existing row.
2. Update only Status (if promoting), Triage Result, Related Items (if OVERLAP/DUPLICATE), Notes (append the classification rationale), and Last Updated.
3. Touch no other columns.
4. If the row already uses the sentinel pattern (Notes cell points at `Logs/backlog-progress/<slug>.md`), append the triage note to the satellite's Session Log — not to the sentinel row. The row remains a current-state pointer.

### 5. Report

```
## Triage Result: <NOVEL | DUPLICATE | OVERLAP | DEFERRED>

Item: <name>
Rationale: <2-3 sentences>
Related items: <linked items, if any>
Next step: <e.g. "Ready for /backlog-research" or "Merge with <item>">
```

---

## Examples

**NOVEL** — "Build a skill that auto-generates project handoff documents when status changes to COMPLETED."
- No existing skill handles project wind-down doc generation.
- Touches project structure but distinct from existing cleanup automation.
- Result: NOVEL, promoted to `triaged`.

**DUPLICATE** — "Create a tool to process meeting transcripts into vault notes."
- `meeting-note-ingestor` already does exactly this.
- Result: DUPLICATE, linked.

**OVERLAP** — "Build automated stale-content detection for project files."
- Librarian already has content-freshness checks.
- But project-specific staleness rules differ from general vault rules.
- Result: OVERLAP, linked to librarian, suggested as a librarian capability extension.

**DEFERRED** — "Build a Slack integration for real-time vault updates."
- Valid idea but no Slack MCP available, no Slack workspace in scope.
- Result: DEFERRED, reason: "No Slack MCP or workspace; revisit when infrastructure exists."
