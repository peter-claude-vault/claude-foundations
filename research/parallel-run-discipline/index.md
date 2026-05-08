---
altitude: system
scope: SP01 cutover discipline — parallel-run validation for live-mutation gate migration
validity_window: 2026-05-08..2026-11-08
source_dependencies:
  - Strangler Fig pattern (martinfowler.com/bliki/StranglerFigApplication.html)
  - Pact consumer-driven contract testing (docs.pact.io/getting_started/how_pact_works)
  - Flyway versioned migration + repeatable validation (documentation.red-gate.com/fd/migrations-184127470.html)
  - Argo CD progressive delivery / blue-green analysis (argoproj.github.io/argo-rollouts/features/bluegreen/)
  - GitHub progressive rollout / dark-launch pattern (docs.github.com/en/actions/deployment/about-deployments/deploying-with-github-actions)
  - OPA Gatekeeper audit-then-enforce phasing (open-policy-agent.github.io/gatekeeper/website/docs/howto/#audit)
  - Plan 71 SP09 postmortem (~/.claude-plans/71-claude-foundations-engine-v2/09-live-mutation-remediation/POSTMORTEM-2026-04-28-live-mutation-creep.md)
last_reviewed: 2026-05-08
canonical_url: https://stem.peter.dev/research/parallel-run-discipline/
url_stability: locked-from-2026-05-08
---

# Parallel-run discipline

The cutover protocol for migrating from one live-mutation gate implementation to another without trusting unit tests to prove decision-equivalence under real traffic. Both gates run against every write; their decisions are logged side-by-side; every divergence is disposed manually; only when the disposition queue clears does the new gate become authoritative.

## Theme

Audit before enforce, observe before retire. Replacing a security-critical gate is a migration with two failure modes: cutting over too soon ships regressions invisible until production traffic exercises edge cases; cutting over never freezes the system on stale infrastructure that successor plans cannot extend. Parallel-run discipline makes the cutover legible — not by adding tests, but by adding a phase where the system itself records the divergences for human disposition.

## The problem the discipline solves

Plan 71 shipped a hardcoded `plan-71-live-guard.sh` to contain live-mutation creep. SP01 replaces it with a manifest-driven engine (`hooks/lib/live-guard.sh` plus `active-gates.json`). The new engine is unit-tested, fixture-tested, and structurally argued to be at least as strict as the old. None of that is sufficient to flip the live tree's gate from old to new in a single commit.

The reason: the old helper has emergent behavior the spec does not capture. Plan 71 SP09's Incidents β / γ / δ each surfaced a behavior that wasn't in any spec but was in the helper's runtime — first-match-glob nonce consumption, transcript-tail mtime stochasticity, R-26 checkpoint write-paths overlapping the gate scope. The new helper might match the spec exactly while diverging from the runtime artifact users actually depend on. Cutting over on spec-equivalence alone trades documented containment for hoped-for containment.

The structural fix: run both helpers against every write through a defined ramp window. Record both decisions to a parallel-run log. Surface divergences to a librarian capability that prompts manual disposition. Phase advance is gated on disposition queue depth, not elapsed time. The N=3 iteration cap prevents infinite-loop fixing — three rounds of regenerate-after-investigation, then escalate to scope-redesign.

This is the **strangler fig pattern** applied to security gates. It is **Pact's CDC** applied to gate decisions: producer (old helper) and consumer (downstream audit tools) share a contract; the new producer must satisfy the same contract before the old one retires. It is **Argo CD blue-green analysis**: traffic is shadowed, metrics are gated, promotion is explicit. The success criteria are the success criteria for those systems: **the cutover is reversible until the moment of promotion, and promotion is contingent on observed (not asserted) parity**.

## The three contracts of a parallel run

A parallel run is not "run two helpers and diff the output." It is three contracts the harness enforces simultaneously.

### Decision-equivalence (Class A)

Same input, same env, same scope-relevant detection signals → same decision. Class A scenarios assert the new helper does what the old helper did when the old helper was right. SP01's T-19 fixture suite exercises seven Class A scenarios:

| Scenario | Trigger | Expected |
|---|---|---|
| A1 | none | both pass-through silently |
| A2 | `PLAN_ID=71-…` | both deny |
| A3 | `PLAN_71_MODE=1` against in-scope path | both deny |
| A4 | `PLAN_71_MODE=1` against carve-out path (`projects/**`) | both allow-carve-out |
| A5 | `PLAN_71_MODE=1` + `PLAN_71_NONCE_TASK=…` + planted basename-matching nonce | both allow-override + nonce consumed |
| A6 | `PLAN_71_MODE=1 PLAN_71_GATE_BYPASS=1` | both pass-through (env bypass) |
| A7 | `PLAN_71_MODE=1` against out-of-scope path (`/tmp/**`) | both pass-through |

The hermeticity discipline matters here. The harness uses `env -i` to reset the full environment per call, then injects only the variables under test, because the calling shell may carry ambient `$PLAN_ID` / `$PLAN_71_MODE` that would leak detection signals. Every scenario also redirects HOME / HOOKS_STATE_OVERRIDE / PLANS_ROOT_OVERRIDE / CLAUDE_HOME to a sandbox so the old helper's hardcoded `$HOME/.claude/` paths resolve into the sandbox, not the live tree. Without `env -i` plus path-redirect, decision-equivalence becomes an artifact of test-harness ambient state, not an assertion about the helpers.

### Divergence disposition (Class B)

Some divergences are by design. The R-26 session-checkpoint case is canonical: the old helper denies writes to `~/.claude/hooks/state/checkpoint.md` under `PLAN_71_MODE=1` because its hardcoded carve-out covers `projects/**` only. The new helper allows the same write because the migrated Plan 71 manifest's `live_mutation_scope.exempt_paths` declares both `projects/**` AND `hooks/state/**`. This divergence is not a regression — it is the closure of SP07 OQ-H, surfaced as Session 1 audit finding #5, pre-disposed in the master Plan 71 manifest's `r55_sunset.divergence_log`.

The disposition grammar is locked to four states:

| Disposition | Meaning | Phase advance impact |
|---|---|---|
| `expected` | Divergence is by design (new scope, deliberate semantic enrichment, closed open question) | does not block |
| `bug-old` | New helper is more correct; old helper had a latent defect | does not block (this is the desired direction) |
| `bug-new` | New helper has a regression vs. old | **blocks Phase A → B advance** |
| `undisposed` | Not yet triaged | **blocks Phase A → B advance** |

T-9's `r55-parallel-run-audit phase-advance-check` returns rc=0 iff `undisposed = 0 AND bug-new = 0`. The grammar is deliberately small. A larger grammar (`severity_low`, `pending_review`, `under_investigation`) would invite indefinite parking; the four-state model forces a binary read at every triage round.

### Audit-log shape (Class C)

The parallel-run log is a JSONL contract — one row per emitted decision, schema-versioned, downstream-stable. Required-always fields: `ts`, `decision`, `plan_id`, `rule`, `tool`, `file`, `schema_version`. Conditional: `signal` (when detection triggered), `reason` (when set), `nonce_task` + `sha` (allow-override only). Empty fields are stripped via `with_entries(select(.value != "" and .value != null))` per `feedback_jq_select_object_construction`.

The contract holds because three downstream consumers depend on the row shape: `r55-parallel-run-audit summary` (counts), `r55-parallel-run-audit list` (joins to disposition file), `r55-parallel-run-audit phase-advance-check` (binary gate). A schema regression in one row class silently breaks one or more consumers — not via crash, via miscount. T-19's Class C fixtures explicitly assert `jq -s 'map(.schema_version) | unique' == "[1]"` across every emitted row, catching both schema drift (mixed values) and silent `schema_version=null` regression (would surface as `[1, null]`).

This is OPA Gatekeeper's **audit-decoupled-from-enforcement** convention. The same log records `allow`, `deny`, `allow-carve-out`, `allow-override`, `warn`, `dryrun` — every decision class fires a row, even when the decision is "no enforcement action taken." Coupling audit emission to enforcement decision creates audit gaps; decoupling them is structural.

## R-37 as a parallel-run hazard

R-37 is the coupled-surface lockstep rule: if a commit touches one surface in a coupled set (e.g., schema add + writer + tests), it must touch the full set. Without R-37, a parallel-run window can ship partial migrations: the new helper lands in foundation-repo, but a sister sub-plan's writer expects the old helper's signal grammar. The decision log accumulates rows that look like divergences but actually reflect schema drift between two halves of the same commit set.

SP01 T-7 promotes R-37 from documentary (`pre-write-guard.sh:25` advisory comment) to structural via Option α: G2 pre-commit denial of partial coupled-surface commits. The hook reads `gate-config.json::r37.{enabled, enforcement_action, coupled_surfaces[], override_sentinel}`. Per coupled set: matched_count ≥ min_match AND matched_count < total_paths → partial → REJECT. Sentinel `.allow-r37-partial` plus `--no-verify` is the two-physical-action override.

The cutover-ramp shape for R-37 itself mirrors the discipline it protects:

| Phase | `enforcement_action` | Behavior |
|---|---|---|
| Shadow | `warn` or `dryrun` | row emitted with `decision:"warn"`; rc=0; commit proceeds |
| Soak | `warn` for 7 days | accumulate log; run audit weekly; zero unjustified `bug-new` rows required |
| Promote | `deny` | row emitted with `decision:"deny"`; rc=1; commit blocked |

The same row schema fires in shadow and deny modes — `set_name`, `missed`, `matched`, `rule:"R-37"`, `schema_version:1`. T-18's T4 fixture explicitly asserts decision-equivalent log entries across enforcement modes, because if shadow-mode and deny-mode emitted different row shapes, the soak window would be measuring a different log than the promotion window's audit consumed.

## The cutover ramp (Phase A → B → C)

R-55 retirement is the canonical SP01 ramp. Calendar-gated to ≥2026-05-17 (the deferral close); structurally gated on T-19 fixtures plus the disposition contract.

**Phase A — parallel run.** Both helpers fire on every gate-evaluable tool call. New helper's decision is recorded but not authoritative; old helper's decision still drives the actual `permissionDecision`. Every divergence appends a row to `parallel-run.log`. Run `r55-parallel-run-audit` daily during the soak; triage `undisposed` rows into `expected` / `bug-old` / `bug-new`. Phase A entry condition: T-3 / T-4 / T-6 / T-7 done plus T-19 fixture green plus install-hooks.sh dispatcher live (T-20 deploy task).

**Phase B — cutover.** New helper becomes authoritative; old helper retired. T-22 deletes `plan-71-live-guard.sh`; T-23 flips Plan 71 manifest `live_mutation_scope.enabled: false`. Entry gate: `phase-advance-check rc=0` for ≥7 consecutive days, no `bug-new` rows in window. Phase B is the irreversible step — once the old helper is gone, rolling back means re-deploying it from git history.

**Phase C — scope retirement.** R-55 paragraph removed from `~/.claude/CLAUDE.md`; sentinel + nonce override grammar dismantled or generalized; the Plan 71 plan-tree `r55_sunset.teardown_status` flips to `RETIRED-FULL`. The mechanism (manifest-driven gate engine) survives Phase C; the specific R-55 instantiation does not.

Phase A → B is the load-bearing transition. The discipline's value is concentrated there: it converts an unbounded "are we sure?" into a bounded "show me the disposition queue."

## The N=3 iteration cap

`r55-parallel-run-audit iteration-count` returns the count of `bug-new` dispositions accumulated across investigation rounds. If the count reaches 3, the audit emits an escalation banner and exits rc=2.

The cap exists because gate-fix loops have a failure mode: each round patches one regression class, and the patch surfaces a new regression class. Three rounds of patch-then-discover indicate the new helper's design is wrong at a level finer than the spec captures. Continuing the loop trades structural correctness for incremental local fixes. The right move at N=3 is escalation: open a fresh ideation, redesign the helper, restart the parallel-run window from Phase A.

This mirrors **the two-strikes rule in industrial control safety** (NRC reg 10 CFR 50, App R) and **OPA Gatekeeper's recommendation to redesign rather than tighten constraints when override rates trend up**. The signal of "this design needs rework" is structurally cheap to emit; the cost of ignoring it is a long-tail bug surface that the team will accept by attrition rather than fix.

## Anti-patterns this discipline prevents

| Anti-pattern | Failure mode | How prevented |
|---|---|---|
| Cutover on spec-equivalence alone | Emergent runtime behavior unspecified; new helper diverges in the wild | Class A decision-equivalence + Class B divergence disposition over real-shaped traffic |
| Parallel-run log without disposition grammar | Divergences accumulate; "we'll triage later" never happens | Four-state grammar (`expected` / `bug-old` / `bug-new` / `undisposed`); phase advance gated on queue depth |
| Time-based phase advance ("7 days then flip") | Calendar-only gate ignores divergence backlog | `phase-advance-check rc=0` requires `undisposed=0 AND bug-new=0` regardless of soak duration |
| Audit log coupled to enforcement decision | Allow rows missing → silent miscount; bug-new vs expected indistinguishable | OPA decoupled-from-enforcement; every decision class emits row including `warn` and `dryrun` |
| Schema drift across enforcement-mode flips | Shadow-mode rows differ from deny-mode rows; soak validates a different log than production reads | T-18 T4 fixture asserts decision-equivalent log entries across `warn` / `dryrun` / `deny` |
| Test-harness ambient env leaks | Caller's `$PLAN_ID` / `$PLAN_71_MODE` flips signal detection inside fixture | `env -i` reset per call; HOME / HOOKS_STATE / PLANS_ROOT redirected to sandbox |
| Indefinite gate-fix loop | Round-N patch surfaces round-N+1 regression; never converges | N=3 iteration cap; escalation to scope-redesign rather than ever-tighter patches |
| Irreversible cutover step omitted from spec | Team rolls forward "just one more fix" past the safe-revert boundary | Phase B explicitly named irreversible; entry gate documented; rollback cost stated |

## Articulation test

After reading, a novice should be able to articulate:

1. **Why decision-equivalence isn't enough** — emergent runtime behavior isn't in the spec; only real traffic exercises it. Class B divergence disposition is the manual loop that catches what Class A misses.
2. **What disposition states block phase advance** — `bug-new` and `undisposed`. `expected` and `bug-old` do not block (the latter because it indicates the new helper is more correct, the desired direction).
3. **Why R-37 is part of the discipline** — partial coupled-surface commits during parallel-run create schema drift between the two helpers, polluting the divergence log with non-bugs that look like bugs.
4. **What the N=3 iteration cap signals** — three rounds of patch-then-discover means the design is wrong at a level the spec doesn't reach; the right move is redesign, not another patch.
5. **Why the audit log decouples from enforcement** — every decision (allow, deny, warn, dryrun, allow-carve-out, allow-override) writes one row; downstream consumers filter by decision class; coupling audit to enforcement creates gaps.

If a reader cannot articulate these, the page has failed its quality bar (SP03 §3.3 criterion 3).

## Open questions (deferred)

- **Real-traffic divergence count vs. T-19 B1 fixture row.** When Phase A deploys, real Plan 71 sessions accumulate `parallel-run.log` rows including the same `hooks/state/checkpoint.md` class via R-26 session-checkpoint writes. T-9 audit should not double-count: B1 fixture proves the row shape; real-traffic rows appear post-deploy. The disposition `expected` for the `hooks/state/**` class can be pre-applied at Phase A start to suppress B1-class noise. Tracked in Session 6 open questions.
- **Tier-2 active-plans.txt detection in fixture coverage.** T-19 covers tier-1 (cwd / plan-id / plan-mode) signals; the OLD helper has no tier-2 surface (transcript-regex tier-3 only), so tier-2 cannot exercise OLD–NEW equivalence at the parallel-run layer. Tier-2 is structurally tested elsewhere (T-3.5 fixture + new helper smoke corpus). Whether the discipline should extend to assert new-helper-only tier-2 coverage at Phase A is open — current scope says no.
- **Multi-master parallel-run shape.** When two future plans both run parallel-run windows simultaneously (e.g., R-55 retirement overlapping a successor plan's gate cutover), divergence-log rows from both windows interleave. Disposition grammar is per-row not per-window; cross-window auditing would need additional metadata. Deferred until a second use-case emerges.
- **Phase B → Phase C duration floor.** Phase A → B has a 7-day soak floor with disposition gate; Phase B → C has no analogous floor today. The argument for one: post-cutover regressions can surface days after the old helper retires, and Phase C scope-retirement removes the override grammar that would otherwise catch them. Unanswered until SP01 master ramp empirically completes.

## Closed questions (with disposition)

| Question | Disposition | Where |
|---|---|---|
| Disposition grammar size — should it support `severity_low` / `pending_review`? | NO — four states only; larger grammar invites indefinite parking | T-9 capability schema |
| Should `phase-advance-check` accept a "max-stale-day" tolerance? | NO — disposition queue depth is the gate, not calendar time | T-9 implementation |
| Should the new helper emit rows during Phase A even when it agrees with old? | YES — agree-rows enable count baselines and Class A regression detection | T-19 Class A scenarios |
| Should the audit log carry `helper_version` tags? | YES — `schema_version:1` covers row shape; helper_version is implied by `rule` field + emit context | T-19 Class C fixtures |
| Should `bug-old` block phase advance? | NO — bug-old is the desired direction; new helper closing a latent old-helper defect is what the migration is for | T-9 `phase-advance-check` rc contract |
| Should N>3 iteration auto-rollback? | NO — escalation only; rollback is an explicit human decision after redesign | T-9 `iteration-count` rc=2 contract |
| Should R-37 promote-to-deny require a separate observation window from R-55 cutover? | YES — distinct rule scopes; T-7 7-day soak independent of R-55 ramp | Spec L192; T-7 ship Session 7 |

## Source pointers

- T-19 parallel-run fixture suite (Class A × 7 + Class B × 1 + Class C × 3): `~/Code/claude-stem/tests/gate-config/r55-parallel-run-fixtures/parallel-run-test.sh`
- T-7 R-37 G2 hook: `~/Code/claude-stem/git-hooks/pre-commit-r37.sh`
- T-18 R-37 fixture suite: `~/Code/claude-stem/tests/gate-config/r37-fixtures/r37-test.sh`
- T-9 `r55-parallel-run-audit` librarian capability: `~/Code/claude-stem/skills/librarian/capabilities/r55-parallel-run-audit.sh`
- Old helper (authoritative through Phase A): `~/.claude/hooks/lib/plan-71-live-guard.sh`
- New helper (authoritative from Phase B): `~/Code/claude-stem/hooks/lib/live-guard.sh`
- Plan 71 SP09 postmortem (origin of disposition-grammar lessons): `~/.claude-plans/71-claude-foundations-engine-v2/09-live-mutation-remediation/POSTMORTEM-2026-04-28-live-mutation-creep.md`
- SP01 spec (this plan): `~/.claude-plans/81-claude-stem-dogfood-optimization/01-manifest-generalization/spec.md`
- Plan 71 master manifest `r55_sunset.divergence_log`: `~/.claude-plans/71-claude-foundations-engine-v2/manifest.json`

## Related principle pages

- [manifest-mechanism](../manifest-mechanism/) — the engine being migrated to; parallel-run validates its decision-equivalence with the legacy hardcoded helper
- [override-mechanisms](../override-mechanisms/) — the grammar (nonce / sentinel / env) that must remain intact across the cutover; sentinel `.allow-r37-partial` is itself part of the discipline being protected
