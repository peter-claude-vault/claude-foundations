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

## Content-tier discipline (Consumer / Provenance / Build)

Claude Stem is consumer-facing. Adopters install the foundation-repo, render schemas + governance JSONs + narrative spokes into their vault, and read the GH Pages docs site. Build-tier metadata (internal plan numbers, task identifiers, decision dates, session references, author-personal anecdotes) MUST NOT leak into ship-tier surfaces. The discipline is three tiers:

**Tier 1 — Consumer (ship-tier).** Lives in: `schemas/*.json`, `governance/*.json`, `research/`, `onboarding/scaffold/`, `skills/*/SKILL.md`, `README.md`, install.sh banner. Audience: a vault adopter who has never read a plan. Strip all internal-process references from body text. Reframe empirical signals to remove author-personal context.

**Tier 2 — Provenance (frontmatter-link tier).** Lives in: YAML frontmatter (`schema_version`, `version`, `last_reviewed`, `validity_window`, `canonical_url`, `$id`, `source_dependencies`). `source_dependencies:` arrays carry pointers to companion packets, governance JSONs, and ADRs by stable filename — NOT plan-tree paths, NOT task identifiers, NOT dated session refs.

**Tier 3 — Build (exile tier).** Lives in: `docs/decisions/NNNN-*.md` (ADRs — Cognitect/Nygard format), `~/.claude-plans/` (plan tree), `CHANGELOG.md`, git commit history. Plan numbers, task identifiers, decision dates, incident reports, plan-process names — all preserved here for audit-trail use, never in ship-tier prose.

**Common rewrites:**

| Build-tier (out) | Ship-tier (in) |
|---|---|
| `(T-1 close 2026-05-12, schema_version 2.0.0)` | `(canonical, semver-versioned)` |
| `per Plan 81 SP03 spec L27-46` | inline rule + `[ADR-0001](./docs/decisions/0001-tiered-compliance.md)` |
| `D1 resolution 2026-05-11` | `the folder-lineage convention` (with ADR link) |
| `Session 4 architecture decision` | `the governance architecture decision` (with ADR link) |
| `Peter's vault has 501 untagged files in Logs/` | `production-scale untagged-file backlogs accumulate (~500 files observed) without write-time enforcement` |
| `spine-remediation Session 08 — 113 files leaked` | `a production incident saw ~100 files leak through this pattern in a single initial commit` |
| `Peter's live PoC for four weeks` | `the reference deployment ran through a multi-week production validation` |
| `Peter Tiktinsky` (in worked examples) | `Alice Example` (or per-archetype example name) |

**What gets preserved as Provenance (frontmatter only):**
- `schema_version`, `version`, `$id`, `$schema`
- `last_reviewed`, `validity_window` (drives staleness audits)
- `canonical_url`, `url_stability` (stable-URL contract)
- `source_dependencies:` reduced to schema refs + companion packet refs + governance refs + ADR refs (relative paths or stable URLs)

**The discipline survives the author.** A future-reader who needs "where did this design come from" answers via `source_dependencies:` → ADR by stable filename → narrative rationale + commit history. NOT via inline plan refs in body prose.

**Industry-converged signal:** Anthropic Skills (`SKILL.md`), Cursor `.cursor/rules/*.mdc`, GitHub Copilot path-scoped instructions, AGENTS.md — none of these scoped-rule formats carry internal plan/task IDs, dated decision references, or build-process metadata in body text. Provenance, when present, lives in frontmatter or commit history.

**Enforcement (planned):**
- A future foundation-repo CI check (GitHub Actions on PR + on-demand via a `scripts/content-tier-audit.sh` script) will scan the repo for build-tier pollution patterns (`Plan \d+`, `T-\d+`, `D\d+ resolution`, dated `Session \d+`, etc.) and emit advisory findings. The audit is a repo-side concern — it lives in the foundation-repo's CI surface, NOT in the adopter-side librarian (which is scoped to live-vault audits).
- The discipline is the authoring contract; the CI audit is the regression check.

**ADR authoring:** when stripping build-tier provenance from a ship-tier artifact, PRESERVE the provenance in an ADR at `docs/decisions/`. See [`docs/decisions/README.md`](docs/decisions/README.md) for the format and existing ADRs.

## Filing an issue

When opening an issue, include:

- macOS version and `bash --version` output.
- The exact command you ran and the exact failure output.
- Whether the failure reproduces under `tests/foundation/librarian-full/run.sh` against a clean fixture.

The third item matters because most install-time failures are environmental — a stale `~/.claude/`, a manifest from a prior version, an aborted onboard mid-write — and the hermetic harness is the cheapest way to bisect.
