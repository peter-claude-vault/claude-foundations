# Claude Stem v2.1.0 — Connector Wizard

**Released:** 2026-05-05

The connector wizard ships. Run `/connectors` to walk a four-step flow that wires MCP connectors into your vault, confirms their schedules, runs OAuth at first use, and produces a working multi-connector cron install. The wizard ships with a curated catalog of 12 known MCP servers (Granola, Google Calendar, Gmail, Google Drive, Atlassian, Slack, Teams, Notion, GitHub, Linear, Asana, Figma) and role-based recommendations for five common roles.

The first reference connector pipeline ships at `connectors/templates/granola-meetings.json` — Granola transcripts pulled daily into your vault Inbox and processed by the meeting-note ingestor. The pipeline is declared as data, not code; adding a new connector pipeline is a config change. See [connectors-granola-pipeline.md](connectors-granola-pipeline.md).

---

## What's new

### `/connectors` wizard

A four-step flow:

1. **Role question.** Single multi-choice prompt persists to `connectors_meta.user_role`.
2. **Catalog multiselect.** 12 curated connectors with role-recommended pre-checks and `[installed]` badges per the MCP-registry probe. `--search` filters the grid.
3. **Schedule confirm.** Per-connector schedule, target vault path, and processor-skill confirmation. The three-step gate previews each manifest write.
4. **OAuth walk.** For each connector with `auth_status: pending`, walks an OAuth flow. Bundled-auth instructions for `claude_ai_*` MCPs; community-OAuth URLs for others. Skip-and-resume supported.

A final gate renders all jobs and non-manual connector schedules before commit.

### Reliability features

- `auto-disable` on auth expiry (HTTP 401/403 / `unauthorized` / `forbidden` / `token expired` / `invalid_grant`). The plist is `launchctl unload`'d; a `RECONNECT REQUIRED` badge appears in `~/.claude/connectors/STATUS.md`.
- Append-only JSONL run history at `~/.claude/connectors/logs/<id>.log`. Records carry `{ts, connector_id, status, items_pulled, duration_ms, error?}`.
- Five failure modes per connector: `block-and-log` (default), `auto-disable`, `backoff-retry`, `skip-and-log`, `no-op`.
- Log rotation: logs >1MB OR >90 days old roll to `<id>.log.1`.

### New launchd plist templates

Five additions at `templates/launchd/`: `digest-run`, `chat-scrape`, `calendar-sync`, `meeting-processor`, and `connector-runtime` (parameterized via `${CONNECTOR_ID}`). Total: 8 templates. The launchd renderer (`installer/render-launchd.sh`) supports schedule shapes from `orchestration.json#/jobs[].schedule.interval_sec` and `.schedule.{hour,minute}` for all jobs.

### Schema additions

- `schemas/user-manifest-schema.json` adds `connectors[]` (11 fields per entry) and `connectors_meta` (user role, wizard version, last run). Additive — no const bump; existing manifests validate cleanly.
- `schemas/connectors-runtime-schema.json` is a new standalone schema for the runtime artifact at `~/.claude/connectors/manifest.json`.
- `schemas/connector-pipeline-template-schema.json` is the schema for connector pipeline templates.

---

## Compatibility

- **Schema:** existing manifests validate cleanly without migration; `connectors[]` and `connectors_meta` carry empty defaults.
- **launchd renderer:** existing `librarian` / `architect` / `inbox-processor` flows unchanged.
- **install.sh:** post-install info-message updated to mention `render-all-launchd.sh` alongside the original `render-launchd.sh <job>` invocation. Single-job render path preserved.

---

## What's not in this release

- Connector pipeline templates beyond Granola (gmail-digest, gcal-agenda, etc.) — author your own using the data-driven pattern.
- Daily applet/template recommendations based on observed vault usage — depends on librarian usage telemetry.
