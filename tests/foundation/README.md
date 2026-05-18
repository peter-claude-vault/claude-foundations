# tests/foundation/

Hermetic end-to-end test harness for foundation distribution validation.

The harness installs `skills/librarian/`, `lib/`, and `schemas/` into a fresh `$CLAUDE_HOME` and runs them end-to-end against a synthetic vault — without ever touching the host's live `~/.claude/` or vault directories.

This is stand-alone from the per-capability test suite under `skills/librarian/capabilities/tests/`. That suite asserts each capability's contract in isolation; this harness asserts the install + chain-invocation contract.

## When to run it

- Before opening a PR that touches anything under `skills/librarian/`, `lib/`, `schemas/`, or `templates/`.
- Before cutting a release (the harness is part of [`docs/release-runbook.md`](../../docs/release-runbook.md) Step 2).
- Whenever you want to verify a new capability composes into the full chain without breaking siblings.

## Layout

```
tests/foundation/
  README.md                          (this file)
  librarian-full/
    run.sh                           # hermetic test driver
    capability-coverage.sh           # per-capability coverage harness
  fixtures/
    claude-home/                     # synthetic $CLAUDE_HOME data
      user-manifest-structured.json    # has_structured_projects: true
      user-manifest-flat.json          # has_structured_projects: false
      librarian-manifest.json          # copy of templates/librarian-manifest-skeleton.json
    vault-minimal/                   # synthetic vault root (passes both manifests)
      CLAUDE.md                        # plain markdown, no frontmatter (silent skip)
      System Governance.md            # plain markdown, no frontmatter (silent skip)
      Logs/.gitkeep                    # empty Logs/ → log-archive no-op
```

The minimal vault has no engagement tree. The structured manifest finds nothing engagement-related to check (still passes); the flat manifest skips engagement-tree checks silently.

## Hermetic isolation

The driver:

1. Creates a fresh `$DOGFOOD_ROOT` via `mktemp -d`.
2. Materializes `$DOGFOOD_ROOT/.claude/` by symlinking foundation `lib/`, `skills/`, `schemas/` into install-shape (capabilities source from `$CLAUDE_HOME/hooks/lib/paths.sh`, so `lib/` materializes there).
3. Materializes `$DOGFOOD_ROOT/vault/` from `fixtures/vault-minimal/`.
4. Materializes `$DOGFOOD_ROOT/.claude/user-manifest.json` from one of the two fixture manifests, templating `vault.root` and `paths.vault_root` to the materialized vault path.
5. Sets `CLAUDE_HOME`, `VAULT_ROOT`, `HOOKS_STATE`, `PLANS_DIR` env vars to fixture paths so no live-host paths leak in.
6. Invokes the integrity-capability chain.
7. Asserts and tears down.

`tests/dogfood-root-helper.sh` (sourced by the drivers) provides `$DOGFOOD_ROOT` plus a cleanup trap.

## Acceptance contract

A green run requires:

- `/librarian full` chain completes against the synthetic vault with exit 0
- An aggregated log written to `{fixture.vault.root}/Logs/session-close-*.md`
- `librarian-manifest.json` populated with seven expected top-level data sections
- Zero unexpected findings (the baseline fixture has known-zero drift)
- Both `has_structured_projects: true` and `false` fixtures pass

## Adding a new test

1. Drop the new fixture under `fixtures/` — manifest files into `claude-home/`, vault content into `vault-minimal/` or a sibling vault directory.
2. Extend `librarian-full/run.sh` (or `capability-coverage.sh`) to materialize and invoke against your fixture.
3. Add the assertion lines.
4. Run from a clean shell to confirm the cleanup trap restores the host state.

If you need a shape `vault-minimal/` doesn't cover, add a new fixture vault rather than mutating the minimal one — the minimal one is the baseline known-zero-drift case and other tests rely on it staying that way.
