---
altitude: system
scope: SP01 manifest mechanism — plan-agnostic live-mutation gate engine
validity_window: 2026-05-08..2026-11-08
source_dependencies:
  - K8s CRD pattern (kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)
  - OPA Gatekeeper Constraint Templates (open-policy-agent.github.io/gatekeeper/website/docs/constrainttemplates/)
  - Argo CD sync waves (argoproj.github.io/argo-cd/operator-manual/sync-waves/)
  - Terraform state-version upgrade pattern (developer.hashicorp.com/terraform/internals/json-format)
  - dbt schema-evolution (docs.getdbt.com/docs/build/projects)
  - Plan 71 SP09 postmortem (~/.claude-plans/71-claude-foundations-engine-v2/09-live-mutation-remediation/POSTMORTEM-2026-04-28-live-mutation-creep.md)
last_reviewed: 2026-05-08
canonical_url: https://stem.peter.dev/research/manifest-mechanism/
url_stability: locked-from-2026-05-08
---

# Manifest mechanism

A plan-agnostic engine for declaring live-mutation gates as configuration data, replacing the per-plan hardcoded approach (R-55 / Plan 71 `plan-71-live-guard.sh`). New plans declare their gate scope via a JSON manifest field; the engine consumes manifests at runtime — no code changes required.

## Theme

Configuration-as-data, not configuration-as-code. The same engine evaluates Plan 71's `~/.claude/**` containment, Plan 80's onboarder deployment scope, and any future plan's novel scope, given only a manifest declaration.

## The problem the mechanism solves

Plan 71 SP09 produced a hardcoded `plan-71-live-guard.sh` to contain live-mutation creep. The hardcoding made the gate non-extensible: any successor plan needing equivalent containment had to copy-paste-modify the helper, fork the detection signals, and re-derive the override grammar. Worse, hardcoding bound the gate to a single plan's lifecycle — `R-55` could not retire cleanly without removing the helper, but the helper was load-bearing for in-flight Plan 71 sub-plans.

The structural fix: lift the gate into a manifest-described mechanism. Each plan declares a `live_mutation_scope` block with scope paths, detection signals, override grammar, and sunset semantics. A single engine reads all active plans' declarations and evaluates them at every tool-mediated write.

This pattern is identical to **Kubernetes CRDs**: the API server doesn't know about `MyCustomResource` until you POST a CustomResourceDefinition; once posted, the object becomes plug-and-play. **OPA Gatekeeper** uses ConstraintTemplate + Constraint to do the same for policy. The success criteria for the manifest mechanism are the success criteria for those systems: a new plan with a novel scope is discoverable, enforceable, override-able, and sunsettable **without engine modification**.

## Engine surface

| Component | Responsibility | Foundation-repo path |
|-----------|---------------|----------------------|
| Schema | Defines `live_mutation_scope` field shape (additive forward-compatible) | `schemas/plan-manifest-schema.json` |
| Read-replica producer | Walks plan-tree manifests; emits flat `active-gates.json` for fast-path consumption | `skills/librarian/capabilities/active-gates-rebuild.sh` |
| Live-guard helper | Evaluates a tool call against the active gates; emits decision JSON; logs to gate-decisions.log | `hooks/lib/live-guard.sh` |
| L3 pause helper | Quiesces L3 writers (launchd labels, SessionEnd hooks, UserPromptSubmit writers) during sensitive windows | `hooks/lib/l3-pause-helper.sh` |
| PostToolUse hook | Triggers read-replica regen on plan manifest writes (mtime-cache invalidation) | `hooks/post-tool-use-manifest.sh` |
| Audit capabilities | r55-parallel-run-audit, l3-registry-audit, waiver-audit, gate-config integrity | `skills/librarian/capabilities/r55-*.sh`, `l3-*.sh` |

## Why the read-replica

Live-guard.sh runs synchronously inside the PreToolUse hook. Walking `~/.claude-plans/` on every write would add ~50-100ms latency per evaluation — unacceptable for an interactive shell. The read-replica `active-gates.json` collapses the walk into one mtime-cache check + one JSON parse.

Read-replica invalidation is **mtime-fast-path with slow-path fallback**: if any plan manifest has a younger mtime than the read-replica, the helper falls back to walking the plan-tree directly (correctness preserved at latency cost). The PostToolUse hook on plan manifest writes regenerates the read-replica eagerly, so the slow-path fires only on hook-miss (e.g., manifest edited via shell, not via tool-mediated write).

This mirrors PostgreSQL's logical-replication slot: the writer publishes change events to a slot; consumers read from the slot at their own pace; if the slot lags, consumers re-derive from base tables. The pattern is durable because the source of truth (manifests) is single-writer + the replica (active-gates.json) is regenerable.

## Sub-plan UNION merging

A sub-plan's `live_mutation_scope` block can declare `inherits_from: <master-plan-slug>`. The read-replica producer UNION-merges the sub-plan's declared paths/labels/hooks into its master. Merging is **additive-only** — sub-plans cannot subtract scope or carve exemptions out from under their master. The merge stamps `_merged_sub_plans[]` provenance for downstream auditing.

Why additive-only: subtraction at the sub-plan layer would let a sub-plan silently weaken its master's containment, defeating the structural purpose of the gate. If a master needs to relax, that's a master-manifest edit, reviewed in PR.

## Compile-time scope-overlap detection

If two enabled master plans both claim `$HOME/.claude/**`, the gate has ambiguous coverage at runtime — first-match wins, but "first" is non-deterministic across detection-signal evaluation. The read-replica producer detects this at regen time via pairwise prefix-comparison after `$VAR` expansion + `/**` normalization. Two postures:

- **Default mode:** emit `scope_overlap_check: failed` in the read-replica metadata; do NOT exit non-zero. Active during R-55 retirement transition (Plan 71 + Plan 81 both claim `~/.claude/**` legitimately during Phase A → C).
- **`--strict` mode:** rc=2 on overlap. Used by CI gates and sub-plan transitions where overlap signals authoring drift.

This is OPA Gatekeeper's "audit + enforce" duality: visibility first, blocking second, with explicit phase advancement.

## Anti-patterns this mechanism prevents

| Anti-pattern | Why it fails | How the mechanism prevents |
|---|---|---|
| Hardcoded plan-id in gate logic (`if plan_id =~ "^71-"`) | Successor plans must fork the engine; sunset can't decouple | Detection signals declared per-plan; engine matches generically |
| Runtime-only scope-conflict resolution | First-match-wins is non-deterministic across mtime-collision peer-sessions (Incident δ) | Compile-time overlap detection at read-replica regen |
| Sub-plan scope subtraction | Hidden weakening of master containment | Schema enforces additive-only at sub-plan layer |
| In-band override grammar (`bypass: true` field) | Trivially self-issuable by an agent | Schema rejects in-band fields; out-of-band only (nonce, sentinel, env) |
| Single audit log coupled to enforcement decision | "deny" decisions log; "allow-by-policy" decisions don't → audit gaps | Decoupled `gate-decisions.log` JSONL per OPA Gatekeeper convergent pattern |

## Articulation test

After reading this page, a novice should be able to articulate:
1. **What the manifest mechanism is** — a plan-agnostic engine that reads each plan's `live_mutation_scope` declaration and enforces it at write time.
2. **Why it's better than hardcoded gates** — a new plan with a novel scope plugs in without engine modification (proven structurally via SP08 `manifest_mechanism_extensibility` fixture).
3. **What the read-replica does** — collapses the per-write `~/.claude-plans/` walk into an mtime-cached JSON parse; correctness preserved via slow-path fallback.
4. **Why scope overlap is detected at compile time** — runtime first-match-wins is non-deterministic; visibility precedes blocking per OPA Gatekeeper convention.

If a reader cannot articulate these, the page has failed its quality bar (SP03 §3.3 criterion 3).

## Open questions (deferred)

- **Schema-versioned read-replica.** `active-gates.json` carries `schema_version: 1`. Helper currently doesn't honor schema-version mismatches between reader (live-guard) and writer (rebuild capability). v1.x bump path: helper logs warning + falls back to slow-path; v2: helper invokes `gate-schema-migrate.sh` v1→v2 callback. Tracked under SP01 T-11.
- **Compile-time overlap path-pattern matching is approximation.** `paths_overlap()` uses prefix-comparison after stripping `/**` and `/*`. Edge case: `["$HOME/a/*/c", "$HOME/a/b/c"]` is a false-negative (`*/c` glob would match `b/c`). v1 limitation; current patterns in Plan 71 + Plan 81 are all `prefix/**` form. Documented as v1 limitation.
- **Brace-expansion handling.** `{a,b}/c` patterns not yet supported. Non-blocking for current plans; would require extending the prefix-comparison logic.

## Closed questions (with disposition)

| Question | Disposition | Where |
|---|---|---|
| Should override grammar permit in-band fields (e.g., `bypass: true`)? | NO — schema rejects in-band; A8 anti-success criterion locked Session 1 | SP01 T-1, T-2 |
| Should `nonce_consume_strategy` allow `first_match_glob`? | NO — A5 anti-success; locked to `basename_match_env` since Plan 71 SP09 carve-out (b) | Schema enum const-locked |
| Should detection-signal `transcript_regex` use find-mtime? | NO — pinned to `$CLAUDE_SESSION_ID`; closes Plan 71 SP09 Incident δ stochasticity | SP01 T-3 (Session 2) |
| Should sub-plans flip their master's `enabled: false` independently? | NO — only the master controls `enabled`; sub-plans inherit | Schema description on `enabled` |

## Source pointers

- Schema definition: `~/Code/claude-stem/schemas/plan-manifest-schema.json`
- Engine implementation: `~/Code/claude-stem/hooks/lib/live-guard.sh` + `~/Code/claude-stem/skills/librarian/capabilities/active-gates-rebuild.sh`
- Plan 71 SP09 postmortem: `~/.claude-plans/71-claude-foundations-engine-v2/09-live-mutation-remediation/POSTMORTEM-2026-04-28-live-mutation-creep.md`
- SP01 spec.md (this plan): `~/.claude-plans/81-claude-stem-dogfood-optimization/01-manifest-generalization/spec.md`
- SP08 extensibility fixture (A3 refutation): `~/.claude-plans/81-claude-stem-dogfood-optimization/01-manifest-generalization/sp08-fixture-inputs/`

## Related principle pages

- [override-mechanisms](../override-mechanisms/) — the out-of-band escape valve grammar consumed by this mechanism
- [parallel-run-discipline](../parallel-run-discipline/) — the safe-cutover discipline used to migrate Plan 71 hardcoded gate → manifest-driven gate
