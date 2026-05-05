# Contributing

Claude Stem is a personal project that may be useful to others. Contributions, bug reports, and feedback are welcome. There is no roadmap obligation, no SLA, and no guarantee a PR lands — but if you've found a bug or built something genuinely portable on top of this, please open an issue or PR.

## Get the code

```bash
git clone https://github.com/peter-claude-vault/claude-stem.git
cd claude-stem
```

The repo contains no submodules and no committed binaries. Everything is plaintext: shell, JSON, Markdown.

## Run the test harness

The hermetic test harness installs the foundation into a fresh `$CLAUDE_HOME` inside a Lima VM with `mounts: []` (host filesystem unreachable), runs install → onboard → adopt → uninstall end-to-end, and asserts a clean uninstall residue. You need [Lima](https://lima-vm.io/) installed:

```bash
brew install lima
./tests/foundation/librarian-full/run.sh
```

For per-rule and per-capability fixtures (faster, no VM), see [`docs/test-harness.md`](docs/test-harness.md). The full Lima run takes a few minutes; the fixture-level tests are sub-second and run on every PR via CI.

## What's in scope

- **Bug fixes** — installer corruption, hook failure modes, schema-validation false positives, broken cross-doc links.
- **Generic capabilities** — skills or hooks that read identity from `user-manifest.json` rather than carrying a hardcoded vault path or person name. If your contribution would only work for your own vault, it doesn't belong in `skills/` — it belongs in your own `~/.claude/skills/`.
- **Documentation** — clarifying ambiguous specs, adding worked examples, fixing stale references.
- **Test coverage** — fixtures that exercise edge cases the existing harness misses.
- **Portability fixes** — anything that quietly assumes a path inside `$HOME/Documents/Vault` or a specific archetype.

## What's out of scope

- **Linux or Windows ports.** The cron substrate is `launchd`. Cross-platform support would require a parallel scheduler abstraction the project hasn't been designed for.
- **Multi-user installs.** One operator per `$CLAUDE_HOME`.
- **Vault-specific business logic.** If a skill needs to know about your firm's account taxonomy or your specific reporting cadence, it lives in your own `~/.claude/skills/<your-skill>/`, not here.
- **Hardcoded identity.** PRs that name a person, organization, vault path, or engagement in code or templates will be sent back to read identity from the manifest.

## The bash 3.2 compatibility constraint

Every shell script that runs on macOS — including hooks, cron wrappers, the installer, and onboarding scripts — is constrained to bash 3.2 syntax. macOS ships `/bin/bash` as 3.2 and `launchd` invokes it directly; bash-4 idioms fail silently under cron with no error to a log file you'll find.

The pre-write guard's R-23 rule (see [`hooks/RULES.md`](hooks/RULES.md)) blocks the obvious offenders at write time. Things to avoid:

- Associative arrays (`declare -A`)
- `${var,,}` lowercasing and `${var^^}` uppercasing
- `readarray` / `mapfile`
- Range expansion with stride (`{0..10..2}`)
- The `&>>` shorthand for combined-stream redirection

If you need a feature only bash 4+ provides, write the logic in `python3` or `awk` and call it from the shell script.

## The Output Contract rule

If you're adding a skill that writes to the user's filesystem, its `SKILL.md` must include an **Output Contract** section declaring:

1. **Files written** — every path the skill writes, with the schema each is gated by.
2. **Pre-write validation steps** — the schema or shape check that runs before each write.
3. **Failure mode** — `block and log` when validation fails. Never `write and hope`.

Skills without an Output Contract fail review. The reasoning is structural: this distribution treats schema violations as bugs, not warnings, and the Output Contract is how a future reader (or audit) verifies that a skill's writes are gated.

## Schema changes

Vault schema, plans schema, manifest schema, and orchestration schema are coordinated changes — extending one almost always requires lockstep updates to the hooks and skills that consume it. See [`docs/adding-a-vault-file-type.md`](docs/adding-a-vault-file-type.md) for the worked example and the checklist.

## Cutting releases

Maintainer-only. The procedure is at [`docs/release-runbook.md`](docs/release-runbook.md). Nothing in CI is wired to publish from a PR — releases are triggered by the maintainer pushing a `v*` tag, and only after the runbook checklist is green.

## A note on style

- **No emojis in code or docs** unless explicitly requested.
- **No marketing language.** Don't add "powerful", "seamless", "revolutionary". Show what the change does, not how impressive it is.
- **Plain English in user-facing text.** R-NN numbers are fine in audit logs and rule names; user-facing prose attaches a one-line gloss on first mention.

## Filing an issue

When opening an issue, include:

- macOS version and `bash --version` output.
- The exact command you ran and the exact failure output.
- Whether the failure reproduces under `tests/foundation/librarian-full/run.sh` against a clean fixture.

The third item matters because most install-time failures are environmental — a stale `~/.claude/`, a manifest from a prior version, an aborted onboard mid-write — and the hermetic harness is the cheapest way to bisect.
