# Granola → Inbox → meeting-processor Reference Pipeline

**Status:** SP14 T-12 (Plan 71 v2.1 deliverable, shipped 2026-05-05)
**Template:** `connectors/templates/granola-meetings.json`
**Schema:** `schemas/connector-pipeline-template-schema.json`
**Audit source:** `~/.claude-plans/71-claude-foundations-engine-v2/_audit-2026-05-03/02-A2-connectors-gap.md` §4 (no Granola pipeline ships at v2.0.0); `_audit-2026-05-03/08-R3-connector-ux.md` §5 (Architecture A)
**Wraps:** SP13 T-11 `skills/meeting-note-ingestor-granola/SKILL.md`

---

## What this template is

`connectors/templates/granola-meetings.json` is the first reference pipeline template for the SP14 connector wizard. It declares — **as data, not code** — the full Granola → vault flow that the v2.0.0 audit identified as missing infrastructure (`02-A2-connectors-gap.md` §4: "Zero documentation, scaffolding, or example exists in the foundation-repo").

The template ships generically (no Peter-isms), wraps the SP13-shipped meeting-note ingestor, and serves both as (a) the wizard's default-pipeline for any connector with `default_pipeline_template_id: "granola-meetings"` and (b) the canonical example for adopters writing their own connector pipeline templates in v2.2+.

---

## Architecture (R3 §5 Architecture A — adopted)

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
  → log run record (T-14)
  → re-render STATUS.md (T-13)
```

The `connectors/runner.sh` (T-16) is the orchestrator; the template tells it WHAT to do and WHEN. No Peter-specific paths, names, or vault structure assumptions.

---

## Coordination with SP13 ingestor

SP13 T-11 shipped two skills:
- `skills/meeting-note-ingestor/` — foundation-portable, source-agnostic. Consumes a transcript file path; emits structured meeting-note. Supports Otter VTT, Word, Zoom, generic LLM-export, Granola JSON.
- `skills/meeting-note-ingestor-granola/` — Granola-specific connector wrapper. Calls the portable ingestor with `--format granola`.

SP14 T-12 does NOT re-implement the ingestor. The pipeline template's `processor_invocation.skill_path` points at `skills/meeting-note-ingestor-granola`; the runner shells out to it with the transcript JSON path. Schema-drift surfaces as a runtime error: if the SP13 ingestor's argv contract changes, the template's `argv_template` must update in lockstep — `ingestor_signature` field carries the integration anchor.

---

## Connector → orchestration.json job derivation

When the SP14 wizard adds a Granola connector to `connectors[]`:
- `connectors[].id`: "granola"
- `connectors[].mcp_server`: "claude_ai_Granola"
- `connectors[].schedule`: "0 6 * * *" (default from catalog; user-overridable in Beat 3)
- `connectors[].target_vault_path`: "Inbox/Meetings/" (default; overridable)
- `connectors[].processor_skill`: "meeting-note-ingestor-granola" (default; overridable)
- `connectors[].failure_mode`: "block-and-log" (default per R-43)

The runtime materialization (per `docs/connectors-schema.md` §connector-job-derivation):
- One `orchestration.json#/jobs[]` entry: `id="connector-runtime-granola"` (or similar runtime-stable id), `schedule.{hour:6, minute:0}` (parsed from cron string), `command="${CLAUDE_HOME}/connectors/runner.sh"`
- One `templates/launchd/connector-runtime.plist.tmpl` rendered instance: Label `${LABEL_PREFIX}.connector-runtime.granola`, ProgramArguments includes `${CONNECTOR_ID}=granola`

The connector-runtime template is parameterized; one plist per connector instance.

---

## Adapting this template for other connectors

Future connector templates (e.g., `gmail-digest.json`, `gcal-agenda.json`) follow the same shape:
1. Declare MCP calls in order with stdout shapes
2. Point at the appropriate ingestor skill (or a connector-specific wrapper)
3. Define target_vault_path_template + slug source
4. Set failure_mode_default + per-step overrides
5. Document the schedule rationale

The template-as-data pattern means adding a new connector pipeline is a config change (write a JSON file + add a catalog entry), NOT a code change.

---

## Why "ingestor wraps the processor" (not vice versa)

The audit's R3 §3 schema example used `processor_skill: "meeting-processor"` as a single field. SP13 T-11 split this into the foundation-portable ingestor + the Granola-specific wrapper. SP14 T-12 honors that split:

- `processor_skill` field (SP14 T-3 schema): the wrapper that knows the connector's data shape
- `processor_skill` invocation (this template): shells out via `skills/<name>/`
- The portable ingestor (SP13) is invoked transitively by the wrapper

This keeps each layer single-responsibility:
- Connector wizard (SP14 Group C) knows the catalog + the user's choices
- Connector runner (SP14 T-16) knows the failure modes + run history
- Pipeline template (SP14 T-12) knows the MCP-call sequence + filesystem layout
- Ingestor wrapper (SP13 T-11 Granola variant) knows Granola's JSON shape
- Portable ingestor (SP13 T-11) knows the structured-note output shape

Each layer is independently testable; no layer reaches across boundaries.
