# Changelog

All notable changes to Claude Stem are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/), and the project follows semantic versioning.

For longer release narratives, see `docs/release-notes-v<version>.md`.

## [v2.1.2] — 2026-05-05

Greenfield content seeding now actually runs end-to-end.

### Fixed

- **Seed-content pipeline reaches the user.** When you run `/onboard --seed-content <path>`, the seven personalization surfaces and the four-stage infer-vault chain now execute on greenfield onboarding. Earlier 2.1.x releases shipped these as code paths reachable only through the retrofit flow.
- **Connector probe parses the canonical MCP server shape.** The MCP registry probe now validates `id`, `display_name`, and `mcp_server_id` before emitting a connector record, and reads the per-server name from the standard `server.{name,...}` shape. Live registry probes now return ~21 valid records instead of one placeholder.

### Changed

- **Engagement-folder taxonomy is parameterized.** The frontmatter enforcer reads `vault.{people,projects_subdirname,strategic,planning}_dirname` from your manifest instead of assuming default folder names.
- **Test fixtures scrubbed.** Removed 28 named clients and engagement slugs from grep-audit fixtures. The audit detector still passes its full unit suite.

### Added

- **`infer-vault-structure` skill is now installed.** The four-stage cluster → propose → import-plan → review-gate chain ships to `~/.claude/skills/infer-vault-structure/`. Earlier 2.1.x releases left this directory off the install allowlist.
- **End-to-end greenfield test.** `tests/greenfield-pipeline/greenfield-end-to-end.sh` drives the full intake → 7-surface auto-author → 4-stage orchestrator pipeline against a sandboxed `$HOME` and asserts on auto-author log records, the approved import plan, consultation records, and identity-token leakage.

## [v2.1.0] — 2026-05-05

Connector wizard.

### Added

- **`/connectors` wizard.** A four-step flow that walks you through wiring MCP connectors (12 known servers in the catalog), confirms a per-app schedule, and runs OAuth at first use. Produces a working multi-connector cron install.
- **First reference connector pipeline.** `connectors/templates/granola-meetings.json` pulls Granola transcripts daily into your vault Inbox and processes them via the meeting-note ingestor. Generic by construction; intended as the canonical example for adopter-authored pipeline templates.
- **Five new launchd plist templates** at `templates/launchd/`: `digest-run`, `chat-scrape`, `calendar-sync`, `meeting-processor`, `connector-runtime` (parameterized per connector).
- **Reliability features for connectors:** auto-disable on auth-expiry, run-history JSONL logs, RECONNECT REQUIRED status badges, and a five-mode failure-handling catalog.

### Changed

- The launchd renderer (`installer/render-launchd.sh`) supports schedule shapes from `orchestration.json#/jobs[].schedule.interval_sec` and `.schedule.{hour,minute}` for all jobs, not just the baseline three.

## [v2.0.0] — 2026-05-03

Initial public release of the personalization engine.

### Added

- **Manifest-driven runtime.** Every skill and hook reads `~/.claude/user-manifest.json` instead of carrying per-user content.
- **`/onboard` interview.** Five-section flow (identity → vault → working style → daily jobs → confirmation), voice-first with typed fallback, producing a populated manifest in roughly 25 minutes.
- **`/adopt` vault scaffold.** Idempotent fresh-vault creation from the manifest's identity and vault fields.
- **Generic skill set.** `/librarian`, `/architect`, `/inbox-processor`, `/meeting-note-ingestor`, `/morning-brief`, `/backlog-{triage,research,hygiene}`, `/seed-projects`.
- **17 default-on hooks.** Write-time policy, frontmatter validation, session lifecycle, multi-session coordination, context-pressure mandates.
- **Daily cron infrastructure.** `librarian` (vault hygiene) and `architect` (strategic review) plist templates, off by default.
- **Installer with vault-protection guard.** Refuses to clobber an existing `~/.claude/` without an explicit confirmation phrase.
- **Hermetic test harness.** Lima VM with `mounts: []` invariant; `tests/runner-shell.sh` is the single approved entrypoint.
- **Sigstore-signed release attestation.** Every tag fires a macOS smoke workflow that signs `macos-smoke-passed.json` via OIDC.
