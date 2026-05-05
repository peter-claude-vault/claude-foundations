# Connectors Schema — `connectors[]`, `connectors_meta`, and the runtime manifest

`connectors[]` is the per-user declarative inventory of MCP connectors you have wired through `/connectors`. Each entry says *which* MCP, *how often* it runs, *where* its data lands, and *which skill* processes it. The runtime artifact at `~/.claude/connectors/manifest.json` is the materialized form: it carries per-run mutations like `last_run`, `last_status`, and `auth_status` that user-manifest.json never sees.

**Schemas:**
- `schemas/user-manifest-schema.json#/properties/connectors`
- `schemas/user-manifest-schema.json#/properties/connectors_meta`
- `schemas/connectors-runtime-schema.json`

---

## What this schema is

`connectors[]` is the declarative inventory. `connectors_meta` carries wizard-state metadata (user role, wizard version, last-run timestamp). Together they declare which MCPs you've chosen and how each runs. The runtime manifest is the same shape with mutable runtime fields layered on top — a read-replica pattern (declarative source, runtime-mutated cache) that the librarian uses elsewhere as well.

---

## Connector → orchestration.json job derivation

Each `connectors[]` entry produces one `.jobs[]` entry in `orchestration.json` at install time (or when you re-run `/connectors --resync`). The mapping:

| `connectors[]` field | `orchestration.json#/jobs[]` field |
|---|---|
| `id` | `id` (with `connector-runtime-` prefix or as-is for first-class connector ids) |
| `schedule` (cron-style string) | `schedule.{hour,minute}` (calendar) OR `schedule.interval_sec` (interval), per cron-string parsing |
| `processor_skill` | `command` (resolved to `${CLAUDE_HOME}/orchestrator/cron-wrappers/connector-runtime-cron.sh`) |
| `target_vault_path` | exposed as env var `CONNECTOR_TARGET_VAULT_PATH` to the cron-wrapper |

The connector-runtime template (`templates/launchd/connector-runtime.plist.tmpl`) is parameterized via `CONNECTOR_ID`. The wizard renders one connector-runtime plist per `connectors[].id` — not one shared plist for all connectors.

**Why parameterized rather than per-connector first-class templates?** Two reasons:

1. Connectors share a uniform runtime shape (auth → pull → process → log). A single template plus cron-wrapper handles all of them.
2. Adding a new connector becomes a config change (one `connectors[]` entry plus one wizard run), not a foundation-repo change. Avoids template proliferation.

First-class non-connector jobs (librarian, architect, digest-run, chat-scrape, calendar-sync, meeting-processor, inbox-processor) keep their own templates — they have idiosyncratic schedule shapes, env-var groups, or runtime semantics that don't fit the parameterized connector pattern.

---

## How `/onboard` and `/connectors` coordinate

The interview can pre-populate `connectors[]` from interview answers. If the interview detects a known MCP server in `~/.claude/settings.json#/mcpServers` or hears you mention "I use Granola for meetings", it may seed a `connectors[]` entry with `auth_status: "pending"` and `failure_mode: "block-and-log"`. The wizard then completes the entry through its normal three-step gate — adopting the seed if you accept it, or overwriting if you pick a different schedule, scope, or processor skill.

The wizard surfaces the pre-seeded entries as Beat 2 pre-checked items. You see the detected connectors already checked, with a one-click "uncheck if I don't use this" — saves a click for the common case and surfaces the auto-author audit trail.

---

## Failure modes

Every `connectors[]` entry declares a `failure_mode`:

| Mode | Trigger | Action |
|---|---|---|
| `block-and-log` (default) | Any non-transient error | Halt this connector's pull; log to `~/.claude/connectors/logs/<id>.log`; surface to the user via `~/.claude/connectors/STATUS.md` |
| `auto-disable` | OAuth `auth_status: expired` (the auth-detect helper flips this) | Pause runtime; flip `auth_status` to `expired`; require `/connectors reconnect <id>` to resume |
| `backoff-retry` | Rate-limit response (HTTP 429 or MCP equivalent) | Exponential backoff 3x then log; reset on next successful run |
| `skip-and-log` | Transient network error / source-temporarily-unavailable | Log + skip this run; retry next cycle |
| `no-op` | Source-empty (no new data since `last_run`) | Log + zero-error rc; do not invoke `processor_skill` |

These match the canonical reliability-pattern catalog (auth-expired, rate-limit, schema-drift, network/transient, source-empty) one-to-one. Schema-drift detection is a runtime concern handled by the runner, not a per-connector schema field.

---

## Migration note (additive, no const bump)

`connectors[]` and `connectors_meta` are **additive** properties on the user-manifest schema. They carry `default: []` and `default: {}` respectively, so existing manifests validate cleanly without any migration step. No const bump required.

---

## Reference: schema example

```json
{
  "user_role": "consultant",
  "connectors": [
    {
      "id": "granola",
      "mcp_server": "claude_ai_Granola",
      "auth_status": "connected",
      "auth_expires_at": "2026-08-01T00:00:00Z",
      "schedule": "0 6 * * *",
      "scope": "read",
      "target_vault_path": "Inbox/Meetings/",
      "processor_skill": "meeting-processor",
      "last_run": "2026-05-02T06:00:00Z",
      "last_status": "ok",
      "failure_mode": "block-and-log"
    }
  ]
}
```

This validates against both `schemas/user-manifest-schema.json#/properties` (when wrapped in a full user-manifest envelope) and `schemas/connectors-runtime-schema.json` (the runtime artifact form).
