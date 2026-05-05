# Granola → Inbox Connector Pipeline

A reference pipeline that pulls Granola meeting transcripts daily into your vault Inbox and processes them via the meeting-note ingestor. The pipeline is declared as data — a single JSON template — not as code, so adding a new connector is a config change, not a foundation change.

**Template:** `connectors/templates/granola-meetings.json`
**Schema:** `schemas/connector-pipeline-template-schema.json`
**Wraps:** `skills/meeting-note-ingestor-granola/SKILL.md`

---

## What this template is

`connectors/templates/granola-meetings.json` is the first reference pipeline template for the connector wizard. It declares — **as data, not code** — the full Granola → vault flow: which MCP calls run, in what order, where their output lands, and which skill processes the result.

The template ships generic (no per-user content), wraps the meeting-note ingestor, and serves both as (a) the wizard's default pipeline for any connector that points at it, and (b) the canonical example for adopters writing their own pipeline templates.

---

## Architecture

```
launchd (StartCalendarInterval, daily 06:00)
  → connectors/runner.sh --id granola
  → reads connectors/templates/granola-meetings.json
  → mcp__claude_ai_Granola__list_meetings (since: {last_run_iso})
  → for each meeting with has_transcript=true:
      → mcp__claude_ai_Granola__get_meeting_transcript
      → write transcript JSON to tmp file
      → invoke skills/meeting-note-ingestor-granola
        → wraps skills/meeting-note-ingestor with --format granola
        → emits frontmatter + cleaned body
      → atomic-mv to {target_vault_path}/Inbox/Meetings/{date}-{slug}.md
  → log run record
  → re-render STATUS.md
```

`connectors/runner.sh` is the orchestrator; the template tells it WHAT to do and WHEN. No user-specific paths, names, or vault-structure assumptions.

---

## Coordination with the ingestor skills

Two skills cooperate here:

- `skills/meeting-note-ingestor/` — source-agnostic. Consumes a transcript file path; emits a structured meeting note. Supports Otter VTT, Word, Zoom, generic LLM-export, and Granola JSON.
- `skills/meeting-note-ingestor-granola/` — Granola-specific connector wrapper. Calls the portable ingestor with `--format granola`.

The pipeline template's `processor_invocation.skill_path` points at `skills/meeting-note-ingestor-granola`; the runner shells out to it with the transcript JSON path. Schema-drift surfaces as a runtime error: if the ingestor's argv contract changes, the template's `argv_template` must update in lockstep — the `ingestor_signature` field carries the integration anchor.

---

## How a connector becomes a launchd job

When the wizard adds a Granola connector to `connectors[]`:
- `connectors[].id`: `"granola"`
- `connectors[].mcp_server`: `"claude_ai_Granola"`
- `connectors[].schedule`: `"0 6 * * *"` (default from the catalog; user-overridable in the schedule beat)
- `connectors[].target_vault_path`: `"Inbox/Meetings/"` (default; overridable)
- `connectors[].processor_skill`: `"meeting-note-ingestor-granola"` (default; overridable)
- `connectors[].failure_mode`: `"block-and-log"` (default)

The runtime materialization (per [connectors-schema.md](connectors-schema.md)):
- One `orchestration.json#/jobs[]` entry: `id="connector-runtime-granola"`, `schedule.{hour:6, minute:0}` (parsed from the cron string), `command="${CLAUDE_HOME}/connectors/runner.sh"`.
- One `templates/launchd/connector-runtime.plist.tmpl` rendered instance: Label `${LABEL_PREFIX}.connector-runtime.granola`, ProgramArguments includes `${CONNECTOR_ID}=granola`.

The connector-runtime template is parameterized; one plist per connector instance.

---

## Adapting this template for other connectors

Future connector templates (e.g., `gmail-digest.json`, `gcal-agenda.json`) follow the same shape:

1. Declare MCP calls in order with stdout shapes.
2. Point at the appropriate ingestor skill (or a connector-specific wrapper).
3. Define `target_vault_path_template` plus a slug source.
4. Set `failure_mode_default` plus per-step overrides.
5. Document the schedule rationale.

The template-as-data pattern means adding a new connector pipeline is a config change (write a JSON file plus add a catalog entry), NOT a code change.

---

## Why "ingestor wraps the processor" (not vice versa)

An earlier design used `processor_skill: "meeting-processor"` as a single field. The current design splits that into the foundation-portable ingestor plus a Granola-specific wrapper. The pipeline template honors the split:

- `processor_skill` field (in the schema): the wrapper that knows the connector's data shape.
- `processor_skill` invocation (in this template): shells out via `skills/<name>/`.
- The portable ingestor is invoked transitively by the wrapper.

This keeps each layer single-responsibility:

- **Connector wizard** knows the catalog and the user's choices.
- **Connector runner** knows the failure modes and run history.
- **Pipeline template** knows the MCP-call sequence and filesystem layout.
- **Ingestor wrapper** knows the connector's specific data shape (Granola JSON in this case).
- **Portable ingestor** knows the structured-note output shape.

Each layer is independently testable; no layer reaches across boundaries.
