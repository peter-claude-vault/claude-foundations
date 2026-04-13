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

Installs into `$HOME/.claude`. Idempotent — re-running picks up updates and merges `settings.json` instead of overwriting. Requires `jq` and `bash`.

## First run

Launch Claude Code, then inside the session:

```
/onboard-foundation     # produces ~/.claude/user-manifest.json
/librarian scan         # bootstraps from the manifest
```

## Isolated testing (no touch to your real ~/.claude)

Override `HOME` to point Claude Code at a throwaway directory. Because Claude Code resolves its config from `$HOME/.claude`, a `HOME` override gives you a clean room with no symlinks or project-local hacks:

```bash
HOME=/tmp/fresh-claude ./install.sh
HOME=/tmp/fresh-claude claude
```

Inside the isolated session, run `/onboard-foundation` as normal. When you're done, `rm -rf /tmp/fresh-claude` throws everything away. Your real `~/.claude` is never touched.

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
