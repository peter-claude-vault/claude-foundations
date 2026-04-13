# Claude Foundations — Onboarding Engine

A research-backed personalization layer for Claude Code. Replaces hand-tuned configs with a conversational onboarder, a runtime-parameterized hook set, and a Librarian skill that owns your `user-manifest.json` and enforces Output Contracts on every vault write.

## What this gives you

- **`/onboard-foundation`** — a <20-question interview that produces your first `user-manifest.json`. Runs an automatic read-only discovery scan first, so questions answered by your environment aren't asked twice.
- **Generic hook set** — `pre-tool-use`, `post-tool-use`, `session-start`, `user-prompt-submit`, `pre-compact`, `stop`. Every hook resolves its configuration from the manifest at runtime; no hardcoded paths.
- **`/librarian`** — a scan/classify/maintain/intake skill that takes ownership of the manifest after onboarding and enforces Output Contracts on everything written into your vault.
- **Manifest schema + validator** — `manifest/schema.json` plus a jq-only validator with no npm or Python dependencies.

## Install

```bash
./install.sh
```

Target directory defaults to `~/.claude`. Override with `CLAUDE_HOME=/some/other/path ./install.sh`. The installer is idempotent and merges with any existing `settings.json` instead of overwriting it.

Requires `jq` and `bash`.

## First run

```bash
/onboard-foundation     # produces ~/.claude/user-manifest.json
/librarian scan         # bootstraps from the manifest
```

## Design philosophy

See `docs/philosophy.md` for why the engine is built as a cold-start research project (no personal data as input), why the manifest is the source of truth, and why every skill that writes to the vault must declare an Output Contract.

## Repository layout

```
manifest/          # schema.json, validator, archetype examples
onboarder/         # /onboard-foundation skill + discovery engine
skills/librarian/  # /librarian skill + handoff protocol
hooks/             # generic hook set + lib/manifest.sh
docs/              # philosophy, build order, skill authoring guide
install.sh         # installer
```

## License

MIT. See `LICENSE`.
