# tests/foundation/architect-fixtures/

Per-archetype contract harness for architect against the 3 SP01 fixtures
(consultant, developer, writer).

Landed by Plan 71 SP05 T-5 (2026-04-30).

## Scope

Asserts the per-archetype contract surface that `/architect --adaptive` depends
on, across the 3 SP01 archetype fixtures shipped at
`onboarding/fixtures/{consultant,developer,writer}.json`.

Architect is LLM-interpreted. The achievable contract is **structural**: the
fixture manifest pair (user-manifest + materialized librarian-manifest skeleton)
satisfies the data-source surface architect declares in `skills/architect/SKILL.md`.
Per-archetype-LLM-driven runtime is deferred to SP08 T-7 (Lima dogfood) per
SP04 T-13 deferred-observation-gate pattern.

`architect-triage.sh` is **runnable** (Python heredoc, not LLM-interpreted),
so AC #6 of T-5 is asserted at runtime against per-archetype-materialized
fixtures.

## Layout

```
tests/foundation/architect-fixtures/
  README.md            (this file)
  structural.sh        # ACs 1-5 reframed × 3 archetypes (T-5 c1)
  triage-runtime.sh    # AC 6 × 3 archetypes (T-5 c2)
  run.sh               # orchestrator: invokes structural + triage-runtime
```

Fixtures are read from `onboarding/fixtures/{consultant,developer,writer}.json`
+ sidecars (no per-archetype paired manifests are authored — the librarian-manifest
is materialized at test-runtime from `templates/librarian-manifest-skeleton.json`,
matching T-12 c1's hermetic-isolation precedent).

## Acceptance contract (SP05 T-5)

Verbatim spec ACs (`05-generic-architect/tasks.md` L134-141):

- [ ] AC #1: Architect executes against consultant fixture → valid report + 0 leak-audit hits
- [ ] AC #2: Architect executes against developer fixture → valid report + 0 leak-audit hits
- [ ] AC #3: Architect executes against writer fixture → valid report + 0 leak-audit hits
- [ ] AC #4: All 3 reports use `[AR-NNN]` format exclusively for generated IDs
- [ ] AC #5: All 3 reports' Convergence section notes "first scan, no prior data"
- [ ] AC #6: `architect-triage.sh` ingests all 3 reports without error; populates `architect_recommendations.recommendations[]` per fixture

### Spec-vs-implementation reframe

ACs #1-5 read as runtime ("Architect executes against ... fixture → valid
report"). Architect is LLM-interpreted (carry-forward from SP05 T-3 c3:
"synthetic test structural-not-runtime — architect is LLM-interpreted;
structural assertion is the achievable contract"). The achievable contract
for ACs #1-5 is **structural**: the fixture manifest pair satisfies the
data-source surface architect requires in SKILL.md. Reframed assertions:

| Spec AC | Reframed structural assertion |
|---------|------------------------------|
| #1-3 (`Architect executes against {archetype} → valid report + 0 leak`) | Per-archetype: user-manifest jq-parseable + `architect` block has all 8 Q1-Q8 fields per Lead 5 §6 + zero leak hits across `{archetype}.json` + sidecars (`-section-{B,C,D}.txt`, `-vault-schema.json`, `-orchestration.json`) |
| #4 (`[AR-NNN] format exclusively`) | Per-archetype: skeleton's `architect_recommendations.items[]` is empty (no legacy `R-NNN` to migrate); SP05 T-4 already proved architect-triage.sh's regex matches `AR-NNN` exclusively (synthetic-architect-triage-ar-prefix.sh Test A 4/4) |
| #5 (`Convergence "first scan, no prior data"`) | Per-archetype: skeleton's `architect_recommendations.last_scanned_log == null`; SP05 T-3 already proved SKILL.md emits the exact "first scan, no prior data" wording when `last_scanned_log == null` (synthetic-architect-first-scan.sh Case 3) |

AC #6 remains runtime (architect-triage.sh is a runnable script).

This reframe is consistent with SP05 T-3 + T-4 precedents (LLM-interpreted
contracts asserted via SKILL.md + skeleton structural surfaces). T-13 deferred
observation gate (Reviewer B §5; SP08 T-7 Lima dogfood) provides the runtime
cross-check; spec AC text reconcile is one of T-13's reconcile items.

## Hermetic-isolation contract

`triage-runtime.sh` MUST:

1. Source `tests/dogfood-root-helper.sh` for `$DOGFOOD_ROOT` + cleanup trap
2. Per-archetype subroot: `$DOGFOOD_ROOT/{archetype}/` with `vault/`, `.claude/`, `plans/`
3. Materialize per-archetype `librarian-manifest.json` by copying
   `templates/librarian-manifest-skeleton.json` to `vault/Logs/`
4. Synthesize per-archetype `architect-{today}.md` with 3 `[AR-NNN]`
   recommendations at `vault/Logs/`
5. Empty `vault/System Backlog.md` (no dedupe pre-population)
6. Set `MANIFEST_PATH`, `ARCHITECT_LOGS_GLOB`, `SYSTEM_BACKLOG_PATH`,
   `FINDINGS_OUTPUT`, `VAULT_ROOT`, `VAULT_LOGS` env per archetype
7. Invoke `architect-triage.sh` (sourced from `skills/librarian/capabilities/`)
8. Assert exit 0 + `recommendations[]` populated to 3 with AR-NNN IDs +
   no `architect-legacy-prefix-skipped` advisory finding

`structural.sh` is read-only — no $DOGFOOD_ROOT needed.
