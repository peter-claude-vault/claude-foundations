# Connectors Schema — `connectors[]` + `connectors_meta` + Runtime Manifest

**Status:** SP14 T-3 (Plan 71 v2.1 deliverable, shipped 2026-05-05)
**Schemas:** `schemas/user-manifest-schema.json#/properties/connectors`, `schemas/user-manifest-schema.json#/properties/connectors_meta`, `schemas/connectors-runtime-schema.json`
**Audit source:** `~/.claude-plans/71-claude-foundations-engine-v2/_audit-2026-05-03/02-A2-connectors-gap.md` + `08-R3-connector-ux.md` §3

---

## What this schema is

`connectors[]` is the per-user declarative inventory of MCP connectors the user has wired through the SP14 connector wizard (or that SP12 auto-authoring populated from interview answers). `connectors_meta` carries wizard-state metadata (user role, wizard version, last-run timestamp). Together they declare *which* MCPs the user has chosen, *how often* each runs, *where* its data lands, and *which skill* processes it.

The runtime artifact at `~/.claude/connectors/manifest.json` (validated by `schemas/connectors-runtime-schema.json`) is the materialized form: it carries per-run mutations (`last_run`, `last_status`, `auth_status`) that user-manifest.json never sees. This is the same read-replica pattern librarian-manifest.json uses against the live vault — declarative source, runtime-mutated cache.

---

## Connector → orchestration.json job derivation

Each `connectors[]` entry produces one `.jobs[]` entry in `orchestration.json` at install time (or at `/connectors --resync` time). The mapping is:

| `connectors[]` field | `orchestration.json#/jobs[]` field |
|---|---|
| `id` | `id` (with `connector-runtime-` prefix or as-is for first-class connector ids) |
| `schedule` (cron-style string) | `schedule.{hour,minute}` (calendar) OR `schedule.interval_sec` (interval), per cron-string parsing |
| `processor_skill` | `command` (resolved to `${CLAUDE_HOME}/orchestrator/cron-wrappers/connector-runtime-cron.sh`) |
| `target_vault_path` | exposed as env var `CONNECTOR_TARGET_VAULT_PATH` to the cron-wrapper |

The connector-runtime template (`templates/launchd/connector-runtime.plist.tmpl`) is parameterized via `CONNECTOR_ID`. The SP14 wizard renders one connector-runtime plist per `connectors[].id`, NOT one shared connector-runtime plist for all connectors.

**Why parameterized rather than per-connector first-class templates?** Two reasons:
1. Connectors share a uniform runtime shape (auth → pull → process → log). A single connector-runtime template + cron-wrapper handles all of them.
2. Adding a new connector becomes a config change (one `connectors[]` entry + one wizard run), not a foundation-repo change. Avoids template proliferation.

First-class non-connector jobs (librarian, architect, digest-run, chat-scrape, calendar-sync, meeting-processor, inbox-processor) keep their own templates — they have idiosyncratic schedule shapes, env-var groups, or runtime semantics that don't fit the parameterized connector pattern.

---

## SP12 coordination

SP12 (auto-authored personalization, shipped pre-GA) writes the user-manifest schema fields populated from the onboarding interview. SP14 (connector wizard) writes `connectors[]` + `connectors_meta`. The two surfaces coordinate as follows:

**SP12 surfaces NOT touching `connectors[]`** (the 7 Tier-1 surfaces shipped pre-GA per `_audit-2026-05-03/10-recalibration-decision-record.md` L70):
1. `~/.claude/CLAUDE.md` — generated from interview
2. `~/.claude/projects/<user>/memory/` — seed memory files
3. Vault `CLAUDE.md` — routing decision tree
4. `_tag_prefixes[]` — workflow-derived tags
5. `doc-dependencies.json` — generated cascade entries
6. `frontmatter-enforce.sh` per-capability config
7. `architect.prior_seed` + research_topics — generated prompt-tuning artifacts

**None of these overlap with connector wiring semantically.** SP12 added 5 user-manifest fields (`vault.tag_prefix_archetype`, `vault.projects_root_dirname`, `system.required_fields_overrides`, `architect.research_topics`, `inbox.poll_interval_minutes`) — all orthogonal to `connectors[]` / `connectors_meta`.

**SP12 may pre-populate `connectors[]` from interview** (Tier-1 surface boundary, NOT yet implemented in SP12 v1):
If the SP12 interview detects a known MCP server in `~/.claude/settings.json#/mcpServers` (e.g., the user mentions "I use Granola for meetings"), SP12's auto-authoring may seed a `connectors[]` entry with `auth_status: "pending"` and `failure_mode: "block-and-log"`. The SP14 wizard then completes the entry through the three-step gate (Beats 2-4) — adopting the SP12 seed if accepted, or overwriting if the user picks a different schedule / scope / processor_skill. Re-run semantics: SP14 wizard's three-step gate (per `_audit-2026-05-03/06-R1-pkm-bootstrapping.md` §4 Capacities pattern) means the user always sees the SP12-seeded entry as a "preview" before commit; no silent rewrites.

**SP14 wizard may surface SP12-seeded connectors as Beat 2 pre-checked** (UX optimization — the user sees the SP12-detected connectors already checked, with a one-click "uncheck if I don't use this") — saves a click for the common case and surfaces the auto-author audit-trail.

---

## Failure modes

Per R3 §6 (six reliability patterns) and the SP14 T-15 auth-expiry detector, every `connectors[]` entry declares a `failure_mode`:

| Mode | Trigger | Action |
|---|---|---|
| `block-and-log` (default) | Any non-transient error | Halt this connector's pull; log to `~/.claude/connectors/logs/<id>.log`; surface to user via `~/.claude/connectors/STATUS.md` (T-13 dashboard) |
| `auto-disable` | OAuth `auth_status: expired` (T-15 detector flips this) | Pause runtime; flip `auth_status` to `expired`; require `/connectors reconnect <id>` to resume |
| `backoff-retry` | Rate-limit response (HTTP 429 or MCP equivalent) | Exponential backoff 3x then log; reset on next successful run |
| `skip-and-log` | Transient network error / source-temporarily-unavailable | Log + skip this run; retry next cycle |
| `no-op` | Source-empty (no new data since `last_run`) | Log + zero-error rc; do not invoke `processor_skill` |

These match the R3 §6 catalog (auth-expired, rate-limit, schema-drift, network/transient, source-empty) one-to-one. Schema-drift detection (R3 §6.6) is a T-13/T-14 concern — runtime-only, not declared in the per-connector schema.

---

## Migration note (additive, no const bump)

`connectors[]` and `connectors_meta` are **additive 1.6.0** properties on the user-manifest schema. They carry `default: []` and `default: {}` respectively, so existing v1.5.x manifests validate cleanly without any migration step. This matches the v1.5.x `vault.architecture_doc` + `vault.tag_prefix_archetype` + `inbox` additive pattern.

No const bump required. v1.6.0 is descriptive (top-level description string updated to note the addition), not a structural break.

---

## Reference: schema example (R3 §3)

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
