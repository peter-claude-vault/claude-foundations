# Claude Stem v2.1.0 — Connector Wizard

**Released:** 2026-05-05
**Tag:** `v2.1.0`
**Predecessor:** `v2.0.0` (2026-05-03)
**Plan:** Plan 71 SP14 (Connector Wizard) — closed 17/17 tasks, 5 sessions, 9 unit-test suites, 225 sub-checks pass

---

## Headline

The connector wizard ships. Adopters can now run `/connectors` (via `onboarding/connectors/wizard.sh`) to walk a 4-beat flow — role question → multiselect catalog of 12 known MCPs → per-app schedule confirm → OAuth-at-first-use sequential walk — and produce a working multi-connector cron install with reliability infrastructure (auto-disable on auth-expiry, run-history JSONL logs, RECONNECT REQUIRED status badges, 5-mode failure-handling catalog).

The first reference pipeline template ships at `connectors/templates/granola-meetings.json` — Granola transcripts pulled daily into the vault Inbox and processed via the SP13 portable meeting-note ingestor. Generic by construction (no Peter-isms; 4-layer grep-audit clean) and serves as the canonical example for adopter-authored pipeline templates in v2.2+.

---

## What's new

### Group A — orchestration + schema

- **`onboarding/lib/job-iterator.sh`** — N-job iteration helper (`for_each_job <fn>` + `count_jobs`) over `orchestration.json#/jobs[]`. Sourced by multi-job consumers (T-2 multi-plist install, wizard runtime). Bash 3.2 + jq compatible.
- **5 new launchd plist templates** at `templates/launchd/`: `digest-run`, `chat-scrape`, `calendar-sync`, `meeting-processor`, `connector-runtime` (parameterized via `${CONNECTOR_ID}`). Total: 8 templates (3 baseline + 5 new).
- **`installer/render-all-launchd.sh`** — multi-job wrapper that walks `.jobs[]` via the iterator and invokes `render-launchd.sh` per declared job. Skips `connector-runtime` in batch mode (parameterized; per-CONNECTOR_ID render owned by the wizard).
- **`installer/render-launchd.sh`** extended: 5 new case branches with per-job env-var groups; `.schedule.interval_sec` generalized to all jobs (orchestration-schema's `oneOf` already supported it).
- **`schemas/user-manifest-schema.json`** extended (1.6.0 additive, no const bump): adds `connectors[]` (11-field per-entry shape) + `connectors_meta` (user_role + wizard_version + last_wizard_run).
- **`schemas/connectors-runtime-schema.json`** — new Draft-07 standalone schema for the runtime artifact at `~/.claude/connectors/manifest.json`.

### Group B — catalog + discovery

- **`onboarding/connectors/catalog.json`** — 12 curated connectors (Granola, Google Calendar, Gmail, Google Drive, Atlassian, Slack, Teams, Notion, GitHub, Linear, Asana, Figma) with role-based pre-checked recommendations across 5 roles (consultant/solo-founder/engineer/researcher/operator). Validated against `schemas/connector-catalog-schema.json`.
- **`onboarding/lib/mcp-registry-probe.sh`** — fetches official MCP Registry (`registry.modelcontextprotocol.io/v0/servers`) with 10s timeout + offline graceful-degrade. Enumerates Anthropic-bundled `claude_ai_*` connectors via `tengu_claudeai_mcp_connectors` flag. Tool-count cap warning at >80 mcpServers.
- **`onboarding/lib/settings-paths-probe.sh`** — reads MCP-server inventory from THREE canonical paths (`~/.claude/settings.json`, `~/.claude.json`, `~/Library/Application Support/Claude/claude_desktop_config.json`) and emits deduplicated list. Closes the v2.0.0 audit finding that v2.0.0's probe only inspected the first path.

### Group C — 4-beat wizard UX

- **Beat 1** (`beats/beat-1-role.sh`) — single multi-choice prompt persisting to `connectors_meta.user_role`.
- **Beat 2** (`beats/beat-2-multiselect.sh`) — catalog grid with role-recommended pre-checks, `--search` filter, `[installed]` badges per Beat 6/T-6 probe. Apply writes `connectors[]` with catalog defaults.
- **Beat 3** (`beats/beat-3-schedule.sh`) — per-connector schedule + target_vault_path + processor_skill confirm. SP12 three-step gate (`gate_apply` from `lib/three-step-gate.sh`) fires before manifest write.
- **Beat 4** (`beats/beat-4-oauth.sh`) — OAuth walk for each `auth_status: pending` connector. Bundled-auth instructions for `claude_ai_*` MCPs; community-OAuth URLs for others. Skip-and-resume supported. Settings.json merge appends `mcpServers.<id>` placeholder entries with SP12 gate per merge.
- **Final gate** (`beats/final-gate.sh`) — mandatory "show me what auto-runs" step. Renders all `.jobs[]` + non-manual `connectors[]` schedules. `--input abort` rc=2 (clean refusal); `--input accept` rc=0.
- **`onboarding/connectors/wizard.sh`** — top-level entry point orchestrating Beats 1-4 + final gate. `--reconnect <id>` re-runs Beat 4 for a single connector (auto-flips `auth_status:expired → pending` first).

### Group D — reliability infrastructure

- **`connectors/lib/status-render.sh`** — generates `~/.claude/connectors/STATUS.md` with markdown table per connector. RECONNECT REQUIRED badge for `auth_status:expired` entries. "No connectors configured" placeholder for empty fixture.
- **`connectors/lib/log-append.sh`** — per-connector append-only JSONL run history at `~/.claude/connectors/logs/<id>.log`. Record shape: `{ts, connector_id, status, items_pulled, duration_ms, error?}`.
- **`connectors/lib/log-rotate.sh`** — rotates logs >1MB OR >90 days old to `<id>.log.1` (single-generation; truncates fresh).
- **`connectors/lib/auth-detect.sh`** — auth-failure pattern matcher (HTTP 401/403, `unauthorized`, `forbidden`, `token expired`, `invalid_grant`, etc.). On match: flips `auth_status:expired` + `launchctl unload`s the connector's plist. Cascade-safe.
- **`connectors/failure-mode-catalog.json`** — declarative 5-mode catalog: `block-and-log` (default per R-43), `auto-disable` (delegates to T-15), `backoff-retry` (exponential `[1, 2, 4, 8, 16]` capped 5 attempts), `skip-and-log` (`[1, 2, 4]` capped 3), `no-op` (source-empty).
- **`connectors/runner.sh`** — per-connector run orchestrator. Validates catalog with `jq -e .` at start (refuses on invalid). Updates `manifest.last_run` + `manifest.last_status` post-run; re-renders STATUS.md.

### Group E — reference pipeline + smoke

- **`connectors/templates/granola-meetings.json`** — first reference pipeline template. Declares MCP calls (`mcp__claude_ai_Granola__list_meetings` + `mcp__claude_ai_Granola__get_meeting_transcript`) + write target (`Inbox/Meetings/{date}-{slug}.md`) + processor invocation (wraps SP13 T-11 `meeting-note-ingestor-granola`) as data, NOT code. Generic — no Peter-isms (4-layer grep-audit clean).
- **`schemas/connector-pipeline-template-schema.json`** — Draft-07 standalone schema for SP14 pipeline templates. Future templates (gmail-digest, gcal-agenda, etc.) follow the same shape.
- **`docs/connectors-granola-pipeline.md`** — explains connector→orchestration.json job derivation, SP12 coordination contract, failure-mode catalog mapping to R3 §6, and adapter-authoring guidance.
- **`tests/sp14/cross-cutting-smoke-test.sh`** — end-to-end smoke against synthetic 3-connector flow in isolated `$CLAUDE_HOME=/tmp/sp14-smoke-XXXXXX`. Exercises Group A→D + template + R-55 path-isolation. 41/41 pass.

---

## Test surface

9 unit-test suites under `tests/sp14/`, **225 sub-checks pass green**:
- `job-iterator-unit-test.sh` (17)
- `multi-plist-render-unit-test.sh` (22)
- `connectors-schema-unit-test.sh` (17)
- `catalog-discovery-unit-test.sh` (30)
- `wizard-beats-1-3-unit-test.sh` (27)
- `wizard-beat-4-final-gate-unit-test.sh` (19)
- `reliability-infra-unit-test.sh` (52)
- `cross-cutting-smoke-test.sh` (41)

Plus regression: existing single-job `render-launchd.sh librarian` flow unchanged.

---

## Three real bugs caught + fixed during dev

1. **zsh `path` is a special variable mirrored to `PATH`** — initial `local path=...` in `job-iterator.sh` clobbered PATH when sourced under zsh. Renamed to `_ji_p`.
2. **Bash 3.2's `[!...]` negation in `case` patterns is unreliable** — input validation in `log-append.sh` fell through silently. Switched to `grep -qE '^[a-z][a-z0-9-]*$'`.
3. **`$ts_` parsed as `${ts_}`** (underscores valid in bash identifiers) and tripped `set -u` in `status-render.sh`. Switched to `${ts}_` brace-disambiguation.

---

## Compatibility

- **Schema**: 1.6.0 additive on `user-manifest-schema.json` (no const bump). Existing v1.5.x manifests validate cleanly without migration; `connectors[]` and `connectors_meta` carry `default: []` and `default: {}`.
- **Render-launchd backward-compat**: existing `librarian` / `architect` / `inbox-processor` flows unchanged. The `.schedule.interval_sec` generalization is permissive; no existing job manifests change behavior.
- **Install.sh**: post-install info-message updated to mention `render-all-launchd.sh` alongside the original `render-launchd.sh <job>` invocation. Single-job render path preserved.

---

## R-55 isolation honored throughout

Zero live `~/.claude/` writes during SP14 development. All paths in foundation-repo + plan-tree + `/tmp` synthetic fixtures. Plan-71-live-guard's harness-intrinsic carve-out (Phase 4, 2026-04-29) correctly exempted auto-memory writes to `~/.claude/projects/**`.

---

## What's NOT in v2.1.0 (deferred)

- Per-connector pipeline templates beyond Granola (gmail-digest, gcal-agenda, etc.) — adopter-authoring per the SP14 template-as-data pattern; v2.2 scope.
- Daily applet/template recommendations (R3 §6 reliability-pattern #7) — depends on librarian usage telemetry; v2.2+.
- Tier-3 connectors: librarian-suggested pipelines based on observed vault usage — v2.2+.

---

## Provenance

- Foundation-repo commits: `b76c230` (T-1) → `2d7716e` (T-2) → `75fa605` (T-3) → `03e0a88` (Session 2 catalog/discovery) → `fe0b84b` (Session 3a wizard 1-3) → `cd6f355` (Session 3b wizard 4 + final gate) → `8a48b62` (Session 4 reliability) → `6bc2c33` (Session 5 pipeline + smoke). 8 commits ahead of v2.0.0 GA tag `a8efd81`.
- Sigstore-attested in Rekor via `macos-smoke.yml` workflow on the v2.1.0 tag SHA; `release.yml` four-stage gate (Sigstore verify + smoke_exit=0 + foundation_sha match + age <7d) verified.
- Burner-key audit: NO-OP for v2.1.0 cycle (zero keys issued — all SP14 tests use stub modes with `ANTHROPIC_API_KEY` / `VOYAGE_API_KEY` unset; documented in `burner-keys.registry`).
