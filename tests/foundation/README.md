# tests/foundation/

Hermetic end-to-end test harness for foundation-repo distribution validation.

Landed by Plan 71 SP04 T-12 (2026-04-29).

## Scope

Validates that the foundation-repo `skills/librarian/`, `lib/`, and `schemas/`
distribution can be installed into a fresh `$CLAUDE_HOME` and run end-to-end
against a synthetic vault — without touching Peter's live `~/.claude/` or
vault.

Stand-alone from the per-capability `skills/librarian/capabilities/tests/`
suite. That suite asserts each capability's contract in isolation; this
harness asserts the install + chain-invocation contract.

## Layout

```
tests/foundation/
  README.md                          (this file)
  librarian-full/
    run.sh                           # hermetic test driver (T-12 c4)
    capability-coverage.sh           # per-capability coverage harness (T-12 c5)
  fixtures/
    claude-home/                     # synthetic $CLAUDE_HOME data
      user-manifest-structured.json    # has_structured_projects: true
      user-manifest-flat.json          # has_structured_projects: false
      librarian-manifest.json          # copy of templates/librarian-manifest-skeleton.json
    vault-minimal/                   # synthetic vault root (single tree, both manifests pass)
      CLAUDE.md                        # plain markdown, no frontmatter -> detect_type=None -> silent skip
      Vault Architecture.md            # plain markdown, no frontmatter -> silent skip
      Logs/.gitkeep                    # empty Logs/ -> log-archive no-op
      # No Engagements/ -> structured manifest finds nothing to check (still passes);
      # flat manifest skips engagement-tree checks silently per SKILL.md L55.
```

## Hermetic-isolation contract

The driver MUST:

1. mktemp -d a fresh `$DOGFOOD_ROOT`
2. Materialize `$DOGFOOD_ROOT/.claude/` by symlinking foundation-repo
   `lib/`, `skills/`, `schemas/` into install-shape (capabilities source from
   `$CLAUDE_HOME/hooks/lib/paths.sh` so `lib/` materializes there)
3. Materialize `$DOGFOOD_ROOT/vault/` from `fixtures/vault-minimal/`
4. Materialize `$DOGFOOD_ROOT/.claude/user-manifest.json` by selecting one of
   the two fixture manifests and templating `vault.root`/`paths.vault_root`
   to the materialized vault path
5. Set CLAUDE_HOME, VAULT_ROOT, HOOKS_STATE, PLANS_DIR env to fixture paths
   (no live-host paths leak in)
6. Invoke the integrity-capability chain
7. Assert + teardown

`tests/dogfood-root-helper.sh` (sourced) provides $DOGFOOD_ROOT + cleanup
trap; harness inherits.

## Acceptance contract (SP04 T-12)

- [ ] `/librarian full` chain completes against synthetic vault with exit 0
- [ ] Aggregated log written to `{fixture.vault.root}/Logs/session-close-*.md`
- [ ] `librarian-manifest.json` populated with 7 expected top-level data sections
- [ ] Zero unexpected findings (baseline fixture has known-zero drift)
- [ ] Both `has_structured_projects: true` + `false` fixtures pass
