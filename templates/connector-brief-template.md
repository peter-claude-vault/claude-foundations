---
type: connector-brief
connector: {{CONNECTOR_SLUG}}
status: configured
data_location: {{DATA_LOCATION}}
last_run: {{LAST_RUN_TIMESTAMP}}
cadence: "{{CADENCE}}"
destinations:
{{#each DESTINATIONS}}
  - {{this}}
{{/each}}
tags:
  - "#log/connector"
  - "#connector/{{CONNECTOR_SLUG}}"
updated: {{ONBOARDING_DATE}}
---

# {{CONNECTOR_DISPLAY_NAME}}

> **Setup note.** This brief describes the connector wiring. The actual data the connector pulls lives at the path declared in `data_location:` (frontmatter above and §Data location below) — outside the vault by foundation default at `$CLAUDE_HOME/connector-data/{{CONNECTOR_SLUG}}/`. The brief is the human-readable companion; the data is the operational substrate consumed by `/ingest`, the dashboard, and other downstream skills.

## What this is

{{ONE_TO_TWO_SENTENCE_IDENTITY_STATEMENT}}

## Connection mechanism

- **Tool / API / MCP:** {{TOOL_NAME_AND_VERSION}}
- **Auth:** {{AUTH_MECHANISM}}
- **Scope:** {{ACCESS_SCOPE}}

## What it pulls

{{ONE_TO_TWO_PARAGRAPH_DATA_DESCRIPTION}}

Reference the structured emission shape at `data_location:` (§Data location below); the emission contract is canonically declared at `$CLAUDE_HOME/governance/connector-emission-rules.adopter.json` under the `{{CONNECTOR_SLUG}}` key.

## Cadence

{{CADENCE_NARRATIVE}}

Specific schedule: `{{CADENCE}}` (cron expression) or on-demand via `/digest-run` / `/sync-{{CONNECTOR_SLUG}}` / equivalent invocation.

## Processing rules

{{PROCESSING_RULES_NARRATIVE}}

The machine-readable equivalents are at `$CLAUDE_HOME/governance/processing-rules.adopter.json` under the `{{CONNECTOR_SLUG}}` keys for `smart_routing[]`, `deduplication[]`, and `survivorship[]`. R-37 lockstep applies — the markdown declaration above and the JSON overlay below MUST update atomically. Edit via `/configure-connector {{CONNECTOR_SLUG}}` (which authors both surfaces) rather than hand-editing either independently.

## Destinations

Per the frontmatter `destinations:` field, this connector writes content to:

{{#each DESTINATIONS}}
- **{{this}}** — {{rationale}}
{{/each}}

## Destination overlap

{{!-- Auto-populated by librarian inbox-index-refresh capability. Empty when no other active connector writes to the destinations above. --}}

{{#if HAS_OVERLAP}}
The following destinations are also written to by other active connectors. Review the overlap and configure deduplication / survivorship rules at §Processing rules above (or via `/configure-connector {{CONNECTOR_SLUG}}`) to prevent duplicate writes.

{{#each OVERLAP_ENTRIES}}
- **{{destination}}** — also written by: {{other_connectors}}. {{notes}}
{{/each}}
{{else}}
*No destination overlap with other active connectors detected.*
{{/if}}

## Data location

**Foundation default:** `$CLAUDE_HOME/connector-data/{{CONNECTOR_SLUG}}/{{ARTIFACT_FILENAME}}`

**Current adopter path:** `{{DATA_LOCATION}}`

{{#if PATH_OVERRIDDEN}}
The default has been overridden via Layer-3 overlay (`$CLAUDE_HOME/governance/connector-data.adopter.json` → `{{CONNECTOR_SLUG}}.path`). To revert to the foundation default, run `/configure-connector {{CONNECTOR_SLUG}} --reset-data-location`.
{{/if}}

## Status / errors

{{STATUS_NARRATIVE}}

- **Last run:** `{{LAST_RUN_TIMESTAMP}}` ({{LAST_RUN_OUTCOME}})
- **Last error:** {{LAST_ERROR_OR_NONE}}
- **Self-check:** {{SELF_CHECK_STATUS}}

{{!-- The §Status / errors section is updated by the connector's self-check on each run. Operator-facing notes (manual triage flags, paused-state rationale, etc.) may be appended here; the connector's auto-update preserves operator additions per the survivorship discipline (user edits win). --}}
