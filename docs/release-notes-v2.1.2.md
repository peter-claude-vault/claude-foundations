# Claude Stem v2.1.2 — Greenfield Personalization Wiring

**Released:** 2026-05-05

`/onboard --seed-content <path>` now actually runs end-to-end on greenfield onboarding. The seven personalization surfaces and the four-stage infer-vault chain — both shipped earlier — were unit-tested in isolation but had no entry point invoking them on a fresh adopter run. v2.1.2 wires the entry point.

A first-time adopter walking `/onboard --seed-content <path>` against an empty vault now sees the seven personalization surfaces fire and (when seed content is supplied) the four-stage cluster → propose → import → review chain run. Earlier 2.1.x releases produced a single connector entry where the architecture promised seven surface records plus a four-stage orchestrator log.

---

## What's fixed

### Greenfield wiring

- **The onboarder now invokes the seven personalization surfaces post-finalize** on greenfield runs. Three flags let you opt out: `--skip-auto-author` skips all seven surfaces; `--skip-content-seeding` skips the four-stage chain; `--auto-author-only-surfaces=<csv>` runs a subset by surface number.
- **`skills/infer-vault-structure/orchestrate.sh`** wraps the four-stage chain (`cluster.sh → propose-taxonomy.sh → import-plan.sh → review-gate.sh`). Idempotent re-run via per-stage state markers. Halt-resume on review-gate stall: the gate writes `state/review-pending.flag`; the orchestrator exits 64 with a clear message; `--resume` skips completed stages.
- **`skills/infer-vault-structure/`** now ships in the install allowlist. v2.1.0 had this directory in the source repo but excluded from `install.sh`; adopter machines could not invoke it.
- **`tests/greenfield-end-to-end.sh`** drives the full intake → 7-surface auto-author → 4-stage orchestrator pipeline against a sandboxed `$HOME` and asserts on auto-author log records, the approved import plan, consultation records, identity-token leakage, and the rendered vault `CLAUDE.md`.

### Engagement-folder taxonomy parameterized

The frontmatter enforcer now reads `vault.{people,projects_subdirname,strategic,planning}_dirname` from your manifest. Six previously-hardcoded substring assumptions in the `detect_type()` regex now consume manifest values. Defaults (`People`, `Projects`, `Strategic`, `Planning`) preserve backward compatibility.

### MCP-registry probe parses the canonical shape

The probe now validates `id`, `display_name`, and `mcp_server_id` before emitting a connector record, and reads the per-server name from the standard `server.{name,...}` shape. Live registry probes return ~21 valid records instead of one placeholder. The legacy flat-fields shape is still tolerated via fallback.

### Test fixtures scrubbed

Removed 28 named clients and engagement slugs from grep-audit literal patterns. The audit detector still passes its full unit suite.

---

## Adopter-side notes

- **Existing installs.** Re-run `install.sh` to land the new onboarder logic and `skills/infer-vault-structure/orchestrate.sh`. No schema bump; `user-manifest.json` carries forward.
- **First-time greenfield run.** `/onboard --seed-content <path>` now dispatches the seven surfaces and the four-stage chain. Stub-mode tests cover the wiring; live LLM invocation requires `ANTHROPIC_API_KEY` set in your environment.
- **Section F is opt-out, not opt-in.** Default greenfield behavior fires the seven surfaces; `--skip-auto-author` opts out. Default content-seeding behavior is gated by `SEED_CONTENT_PATH` being set; `--skip-content-seeding` opts out when it is.
