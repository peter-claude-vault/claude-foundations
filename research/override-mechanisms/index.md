---
altitude: system
scope: SP01 override grammar — out-of-band escape valves for live-mutation gates
validity_window: 2026-05-08..2026-11-08
source_dependencies:
  - Bell-LaPadula no-read-up / no-write-down (NIST SP 800-53 AC-3)
  - OAuth 2.0 RFC 6749 §1.3.1 client-credential vs resource-owner separation
  - PostgreSQL row-level security GRANT semantics (postgresql.org/docs/current/ddl-rowsecurity.html)
  - "two-person rule" (NRC nuclear control reg 10 CFR 73.55 / IAEA INFCIRC/225)
  - Plan 71 SP09 nonce-affinity Incident β postmortem
last_reviewed: 2026-05-08
canonical_url: https://stem.peter.dev/research/override-mechanisms/
url_stability: locked-from-2026-05-08
---

# Override mechanisms

The grammar by which authorized humans bypass live-mutation gates without weakening the gates themselves. Three primitives — nonce, sentinel, env — composed in a way that prevents agent self-issuance.

## Theme

Overrides exist because gates are imperfect: legitimate work occasionally needs to write through containment. The design challenge is preserving the gate's structural integrity while admitting that exceptional access. The answer: **out-of-band only**, never in-band.

## In-band vs out-of-band — the load-bearing distinction

**In-band override** = the override is declared in the same data the agent is writing. Example: `{"bypass": true, ...}` as a manifest field.

**Out-of-band override** = the override lives somewhere the agent cannot reach in the same call. Example: a nonce file the user touches manually, consumed atomically when the gate evaluates.

In-band overrides fail because **the agent can self-issue them**. If `{"bypass": true}` is a valid manifest field, an agent that has been instructed to bypass — by accident, by hostile prompt, or by misinterpretation — can simply add the field. The gate has no defense.

Out-of-band overrides hold because **the agent cannot perform two physical actions** within a single tool call. Touching a file in a different filesystem path, setting a shell-rc env var, creating a `git commit` sentinel — these require user-side hands on the system. The gate's containment property reduces from "everything in scope is gated" to "everything in scope is gated unless the user has authorized it via a parallel side-channel" — still a useful invariant.

This is the same structural property that justifies **physical key cards** in datacenters, **2FA hardware tokens** in finance, and **two-person rule** in nuclear weapons handling. The system grants access only when two independent channels both confirm.

## The three SP01 override primitives

### Nonce

A short-lived authorization token planted on disk by the user, consumed atomically by the gate on first match. Schema-locked content format:

```
<task_id>\t<reason ≥12 chars>\t<sha-of-anchor-tag>
```

- **`task_id`** — basename of the nonce file MUST match this field; an environment variable named in `nonce_affinity_env` (e.g., `PLAN_71_NONCE_TASK`) MUST be set to this value at gate evaluation. This is the **basename-match-env** consume strategy, locked to that string in the schema. The previous strategy (first-match-glob) was deprecated after Plan 71 SP09 Incident β.
- **`reason ≥12 chars`** — forces the issuer to type a real justification, not a placeholder. Audit-log copy is the reason.
- **`sha-of-anchor-tag`** — must equal the SHA of a git ref named in `nonce_sha_anchor` (typically `refs/tags/<consume-anchor>`). Binds the nonce to a specific repository state; if the anchor moves, the nonce no longer validates. Prevents long-lived nonce stockpiles.

**Atomic consume.** When the gate matches a nonce, it `rm`s the nonce file. The atomic-rm is the serialization mechanism: 3 parallel calls all see the same eligible nonce; first to consume wins; remaining two see no nonce → DENY. This is not a bug — it's how the nonce ensures one-shot-per-issuance.

**Why not "consume on commit" instead of "consume on use"?** Because gates fire pre-commit, and many gated writes never become commits. Consume-on-use accepts the parallel-call serialization cost in exchange for closing the multi-write reuse hazard.

### Sentinel

A flag file at a fixed filesystem path that, when present, suppresses the gate for the entire commit (G2) or hook invocation (G1). Examples:

- `~/.claude/.allow-plan-71-commit` (G2 R-55 G2 escape)
- `~/Code/claude-stem/.allow-harness-validation-skip` (R-46-cousin escape)
- `~/.claude/.allow-r37-partial` (R-37 coupled-surface partial-set escape)

Sentinels are **broader than nonces**: a sentinel + `--no-verify` is a global-scope bypass, not a per-task bypass. They exist because some override scenarios are too coarse for nonces (e.g., "I know the partial commit looks weird; ship it anyway"). The composition rule: sentinel use is logged with full justification; auditing reviews sentinel-use rate over time, and abnormal frequency triggers the override-grammar redesign.

### Env (bypass_env_var)

A shell-rc-defined environment variable (e.g., `R55_FOUNDATION_REPO_BYPASS=1`) that suppresses the gate when set. **Scoped exclusively to user shell-rc files** — not Claude Code's per-call env scoping, which prevents agents from setting it inline.

Why env at all, given nonce + sentinel? Because env is the right tool when the override is **work-mode-scoped, not task-scoped**: "I'm in foundation-repo development this week; suppress the gate for this whole shell session." Env's strength is duration; nonce's strength is per-task auditability. The composition: env for sustained foundation-repo work; nonce for one-off cross-scope edits.

## Composition rules (locked)

1. **Schema rejects in-band fields.** `additionalProperties: false` on the `override` block; only `nonce_*`, `sentinel_*`, `bypass_env_var` keys permitted.
2. **Nonce consume strategy locked to `basename_match_env`.** Schema enforces `const`; first-match-glob is structurally unreachable.
3. **Reason length minimum 12 chars.** Schema enforces `minimum: 12` on `nonce_min_reason_length`.
4. **All overrides logged.** `gate-decisions.log` JSONL emits one row per evaluation regardless of decision. Audit decoupled from enforcement (OPA Gatekeeper convergent pattern).
5. **Override use is rate-monitored.** Librarian `waiver-audit` capability surfaces sustained override patterns; abnormal counts escalate to scope-redesign rather than tighter gates.

## Anti-patterns this grammar prevents

| Anti-pattern | Failure mode | How prevented |
|---|---|---|
| `{"bypass": true}` field | Agent self-issuance | Schema rejects in-band fields |
| Nonce stockpile (long-lived) | Reusable past intended task | SHA anchor binds nonce to repo state; SHA moves invalidate stockpile |
| First-match-glob nonce consume | Wrong nonce consumed (Plan 71 SP09 Incident β) | basename-match-env primary; `nonce_affinity_env` mandatory |
| Sentinel without `--no-verify` | Single-action bypass too easy | Two physical actions: touch sentinel + commit with explicit `--no-verify` |
| Env set via Claude Code session | Agent self-issuance via env | Per-call env scoping in Claude Code prevents inline export; env must come from shell-rc files |
| Override decision excluded from audit log | Audit gap | Single decoupled log; allow + deny + override-allow all emit rows |
| In-band reason field <12 chars | Placeholder text | Schema `minimum: 12` enforced |

## Articulation test

After reading, a novice should be able to articulate:
1. **Why in-band overrides fail** — agents can self-issue them; out-of-band requires a parallel user-side channel.
2. **What `basename_match_env` does** — nonce filename must match an env var the caller sets; defeats first-match-glob hazard from Plan 71 SP09 Incident β.
3. **Why atomic-consume is the design** — guarantees one-shot-per-issuance; parallel-call serialization is intentional, not a bug.
4. **When to use env vs nonce vs sentinel** — env for sustained mode, nonce for per-task, sentinel for global-scope-with-justification.

## Open questions (deferred)

- **Sub-candidate (a) basename-match-env hint propagation.** When `nonce_affinity_env` is unset by the caller, the gate currently denies. A future improvement: a suite-level `PLAN_71_NONCE_TASK_HINT` propagated via session env so harness-intrinsic writes can declare affinity per-task without each call re-setting the env. Marked open in Plan 71 SP09 cleanup-pass postmortem; lower priority since Phase 4 carve-out closed the empirical incident class.
- **Multi-anchor nonces.** Currently one `nonce_sha_anchor` per override block. A nonce that's valid against multiple SHAs (e.g., Plan 71 + Plan 81 both at v2.0.0) would need a list-valued anchor field. Deferred until use-case emerges.

## Closed questions (with disposition)

| Question | Disposition | Where |
|---|---|---|
| Permit `bypass: true` in-band field? | NO — A8 anti-success criterion locks schema | SP01 T-1 schema |
| `nonce_consume_strategy: first_match_glob`? | NO — A5; deprecated after Plan 71 SP09 Incident β | Schema const-locked |
| Reason minimum <12 chars? | NO — placeholder hazard; 12-char floor | Schema `minimum: 12` |
| Multiple nonces per task simultaneously? | NO — task-id basename uniqueness implies 1:1 | Implicit in basename-match-env |

## Source pointers

- Schema: `~/Code/claude-stem/schemas/plan-manifest-schema.json` (override block)
- Plan 71 SP09 postmortem (Incident β): `~/.claude-plans/71-claude-foundations-engine-v2/09-live-mutation-remediation/POSTMORTEM-2026-04-28-live-mutation-creep.md`
- Phase-4 carve-out (cleanup-pass implementation): `~/.claude-plans/71-claude-foundations-engine-v2/09-live-mutation-remediation/_cleanup-2026-04-29/Phase-4-gate-carve-out-impl.md`
- Live-guard implementation: `~/Code/claude-stem/hooks/lib/live-guard.sh`
- T-27 R-46-cousin sentinel example: `~/Code/claude-stem/git-hooks/pre-commit-harness-validated.sh`

## Related principle pages

- [manifest-mechanism](../manifest-mechanism/) — the engine that consumes this override grammar
- [parallel-run-discipline](../parallel-run-discipline/) — the cutover protocol that makes parallel-engine validation safe even with overrides active
