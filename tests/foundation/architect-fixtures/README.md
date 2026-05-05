# tests/foundation/architect-fixtures/

Per-archetype contract harness for the `/architect` skill. Verifies that architect's data-source surface is satisfied by the three onboarding archetype fixtures (consultant, developer, writer).

## What this asserts

Architect is LLM-interpreted — its outputs are produced by the model, not by deterministic code. The achievable contract for tests is **structural**: each archetype fixture's manifest pair (user-manifest plus a materialized librarian-manifest skeleton) satisfies the data-source surface architect declares in `skills/architect/SKILL.md`.

`architect-triage.sh` is **runnable** (it's a Python heredoc, not LLM-interpreted), so the triage assertion runs at test time against per-archetype-materialized fixtures.

## Layout

```
tests/foundation/architect-fixtures/
  README.md            (this file)
  structural.sh        # data-surface assertions × 3 archetypes
  triage-runtime.sh    # architect-triage.sh runtime assertion × 3 archetypes
```

Both scripts are stand-alone — invoke either directly. Fixtures are read from `onboarding/fixtures/{consultant,developer,writer}.json` plus their sidecars; no per-archetype paired manifests are authored, the librarian-manifest is materialized at test runtime from `templates/librarian-manifest-skeleton.json`.

## Acceptance contract

For each of the three archetype fixtures (consultant, developer, writer):

- The user-manifest is `jq`-parseable and its `architect` block carries all required fields per the architect SKILL contract
- Zero identity-leak hits across `{archetype}.json` and its sidecars (`-section-{B,C,D}.txt`, `-vault-schema.json`, `-orchestration.json`)
- The librarian-manifest skeleton's `architect_recommendations.items[]` is empty (no legacy-prefix recommendations to migrate)
- The librarian-manifest skeleton's `architect_recommendations.last_scanned_log == null` (the convergence section will say "first scan, no prior data")
- `architect-triage.sh` ingests a synthesized architect-report fixture without error, populating `architect_recommendations.recommendations[]` per archetype

## Hermetic isolation

`triage-runtime.sh`:

1. Sources `tests/dogfood-root-helper.sh` for `$DOGFOOD_ROOT` plus cleanup trap.
2. Builds a per-archetype subroot: `$DOGFOOD_ROOT/{archetype}/` with `vault/`, `.claude/`, and `plans/` subdirectories.
3. Materializes a per-archetype `librarian-manifest.json` by copying `templates/librarian-manifest-skeleton.json` into `vault/Logs/`.
4. Synthesizes a per-archetype `architect-{today}.md` with three `[AR-NNN]` recommendations under `vault/Logs/`.
5. Writes an empty `vault/System Backlog.md` (no dedupe pre-population).
6. Sets `MANIFEST_PATH`, `ARCHITECT_LOGS_GLOB`, `SYSTEM_BACKLOG_PATH`, `FINDINGS_OUTPUT`, `VAULT_ROOT`, `VAULT_LOGS` env per archetype.
7. Invokes `architect-triage.sh` from `skills/librarian/capabilities/`.
8. Asserts exit 0, three populated `recommendations[]` entries with `[AR-NNN]` IDs, no legacy-prefix-skipped advisory finding.

`structural.sh` is read-only — no `$DOGFOOD_ROOT` needed.

## Why structural rather than runtime

Running architect end-to-end requires a live model invocation. The cost and non-determinism would put a model call in the per-PR test path, which is the wrong tradeoff for a check whose job is "did the data surface stay shaped right." The runtime cross-check happens during the Lima dogfood pass before each release; the per-PR contract is structural here.
