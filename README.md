# Claude Stem

Personalization engine for [Claude Code](https://www.anthropic.com/claude-code).

`/onboard` interviews you once, generates a user-manifest describing your role, vault, and preferences, and bootstraps a personalized `~/.claude/` directory: hooks, skills, schemas, daily-cron jobs, and an Obsidian vault scaffold. Generic skills then read the manifest at runtime — no per-user template forks.

> **Status:** v2.0.0. macOS only. Single-user. Designed for cold-start adopters who have never run Claude Code before.

---

## What's in the box

- **`install.sh`** — copies foundation assets to `$CLAUDE_HOME` (default `~/.claude/`), bootstraps schemas, stages daily-cron job templates without enabling them.
- **`/onboard` skill** — interactive interview (Sections A–E: identity → vault → working style → daily jobs → confirmation) producing a complete user-manifest.
- **`/adopt` skill** — scaffolds a fresh Obsidian vault from the manifest's identity. Refuses adoption when `vault.is_fresh != true` (use `--retrofit-existing`, deferred to v2.1).
- **`uninstall.sh --full`** — clean removal. Foundation files only; user data (logs, journals, vault) preserved as uninstall provenance.
- **Daily crons** (off by default) — `librarian` (vault hygiene scan) and `architect` (system-evolution recommendations). Enable via `$CLAUDE_HOME/orchestration.json`.
- **Hermetic test harness** (`docker/`, `lima/`, `tests/`) — Lima VM with `mounts: []` invariant; full E2E install → onboard → adopt → cron-fire → uninstall → grep-audit cycle.
- **Sigstore-attested release artifact** — every release tag fires `macos-smoke.yml`, signs the resulting `macos-smoke-passed.json` via OIDC, and persists the attestation to GitHub's Rekor-backed registry.

---

## Quick start (rc1)

**Prerequisites:** macOS 14+, Lima VM (`brew install lima`) for the test harness, [Obsidian](https://obsidian.md) for the vault.

```bash
# 1. Clone
git clone https://github.com/peter-claude-vault/claude-stem.git
cd claude-stem

# 2. Inspect what install.sh will do (dry-run posture is the default)
./install.sh

# 3. Apply (real write to ~/.claude/)
./install.sh --apply

# 4. Onboard inside Claude Code
claude
> /onboard

# 5. Adopt — scaffold the vault from the manifest
> /adopt
```

For non-default installations (test directories, isolated dogfood):

```bash
# Install into a non-default $CLAUDE_HOME
CLAUDE_HOME=/tmp/test-claude PLANS_HOME=/tmp/test-plans ./install.sh --apply

# Or use Lima for full hermetic isolation
bash tests/e2e-lima-dogfood.sh
```

`install.sh` refuses to overwrite an existing `~/.claude/` (G1-main install-side guard) unless you pass `--force-install` AND pipe the sentinel `I-UNDERSTAND-APRIL-13` to stdin. See [docs/april-13-autopsy.md](docs/april-13-autopsy.md) for what April 13 was and why this guard exists.

---

## Architecture in one paragraph

The foundation is a **manifest-driven generic-skills runtime**: one set of skills + hooks + schemas, parameterized at runtime by a single user-manifest written during `/onboard`. Skills read identity/vault/preferences from `$CLAUDE_HOME/user-manifest.json` rather than carrying user-specific content. Daily crons are launchd plists rendered from `$CLAUDE_HOME/orchestration.json` at install time, gated behind explicit user opt-in. The vault is a separate concern owned by `/adopt`, which scaffolds an Obsidian directory tree from the manifest's identity fields and seeds a small set of canonical files (CLAUDE.md, System Backlog.md, .coordination/canonical-file-types.json). Everything below `~/.claude/` is foundation-owned and uninstall-removable; everything in the vault is user-owned and uninstall-preserved.

---

## What's NOT in v2.0.0

- **Linux / Windows support.** macOS-only by design (launchd as the cron substrate). Linux port is post-v2.1 territory.
- **`--retrofit-existing` for `/adopt`.** Existing-vault retrofit is deferred to v2.1.
- **Real-onboarder dogfood (Section A–E inside container).** rc1 ships with fixture-staged manifests for the test harness; real-onboarder execution is absorbed into the 30-day GA observation window.
See `~/.claude-plans/71-claude-foundations-engine-v2/` (private, not in this repo) for the master plan and sub-plan tracking.

---

## Release artifacts

Every `v*-rc*` and `v*` tag fires `.github/workflows/macos-smoke.yml` on `macos-14`, runs the install → render → bootstrap → uninstall lifecycle, and produces a Sigstore-signed `macos-smoke-passed.json` with this shape:

```json
{
  "schema": "macos-smoke-passed.v1",
  "smoke_exit": 0,
  "foundation_sha": "<git SHA the smoke ran against>",
  "generated_at": "<ISO-8601 UTC>"
}
```

The `release.yml` workflow gates the v2.0.0 (non-rc) tag-cut against this attestation: smoke must be green, `foundation_sha` must match the tag's commit SHA, and the attestation must be < 7 days old. Tag deletion does NOT retract Sigstore attestations — they're permanent in Rekor's transparency log.

---

## Provenance

- **Repository:** https://github.com/peter-claude-vault/claude-stem
- **Predecessor:** Plan 38 (`38-claude-foundations-onboarding-engine`, commits up to `0adb10c`) — the engine that became Claude Stem. Plan 71 (`71-claude-foundations-engine-v2`) supersedes Plan 38 after the April 13, 2026 incident, and produced this v2.0.0 release under the Claude Stem name. The `main` branch retains Plan 38 history at `0adb10c`; `v2-engine` is the active development branch.
- **Memorial:** [docs/april-13-autopsy.md](docs/april-13-autopsy.md) — what happened, what we learned, what guards now exist.
- **License:** Apache-2.0 — see [LICENSE](LICENSE).

---

## Author

Built by [Peter Tiktinsky](https://github.com/peter-claude-vault). Personal initiative, not work-for-hire.
