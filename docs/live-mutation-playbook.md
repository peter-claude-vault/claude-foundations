# Live-Mutation Containment Playbook

**Status:** v1 (Plan 81 SP01 graduation, 2026-05-11)
**Audience:** Plan authors who need to gate live `~/.claude/` writes during their plan's lifetime.
**Successor pattern:** Replaces Plan 71's hardcoded R-55 mechanism with a manifest-driven, plan-agnostic gate. Future plans declare scope in their `manifest.json`; no hook code changes required.

---

## When you need this playbook

Use a `live_mutation_scope` declaration when your plan:

1. Mutates files under `$HOME/.claude/**` (hooks, schemas, skills, settings, CLAUDE.md)
2. Wants structural protection against off-scope writes during its lifetime
3. Needs an audit trail of every override decision (`gate-decisions.log` JSONL)

You do **not** need this for:

- Foundation-repo (`~/Code/claude-stem/**`) edits — out of scope by path prefix
- Plan-tree (`~/.claude-plans/**`) edits — out of scope by path prefix
- Vault (`~/Documents/Obsidian Vault/**`) writes — separate gate surface
- Read-only investigation work

## Declaration site

Add to your plan's `~/.claude-plans/<plan>/manifest.json`:

```json
{
  "live_mutation_scope": {
    "enabled": true,
    "schema_version": 1,
    "inherits_from": null,
    "scope_paths": ["$HOME/.claude/path/under/scope/**"],
    "exempt_paths": ["$HOME/.claude/projects/**"],
    "detection_signals": { ... },
    "override": { ... },
    "enforcement": { "match_action": "deny", "error_action": "ignore" },
    "sunset": { ... }
  }
}
```

The canonical reference implementation is **Plan 71's manifest** at `~/.claude-plans/71-claude-foundations-engine-v2/manifest.json :: live_mutation_scope`. Read it before authoring your own — it covers every field, with rationale comments inline.

## Detection signals — three tiers

The helper at `~/.claude/hooks/lib/live-guard.sh` evaluates detection signals in three tiers. **Any one signal triggers DETECTED.**

### Tier 1 — deterministic, cheap (preferred)

```json
"detection_signals": {
  "cwd_pattern": "$HOME/.claude-plans/<plan-slug>-*",
  "plan_id_pattern": "^<plan-id>($|-)",
  "plan_mode_env_var": "PLAN_<ID>_MODE"
}
```

Tier 1 fires on: `pwd` glob match, `$PLAN_ID` env regex match, or explicit `$PLAN_<ID>_MODE=1` env var. Use Tier 1 for the vast majority of plans.

### Tier 2 — deterministic session-state file

The helper reads `$HOOKS_STATE/$CLAUDE_SESSION_ID/active-plans.txt` (written at SessionStart by `session-start-canary.sh`). If the file lists your plan slug, detection fires. Requires no manifest declaration beyond Tier 1; activates automatically.

### Tier 3 — transcript-regex (opt-in fallback)

```json
"detection_signals": {
  "transcript_regex": "\\b(Plan <N>|<plan-slug>)\\b",
  "deterministic_only": false
}
```

Tier 3 greps the session transcript for plan-specific keywords. **Avoid for new plans** — Plan 71 SP09 Incident δ proved transcript signals are stochastic. Locked to `$CLAUDE_SESSION_ID` in v1 (not `find ... | sort -rn | head -1`), but still classifies as "best-effort." Declare `deterministic_only: true` to disable Tier 3 entirely.

## Override mechanisms — out-of-band only

When you legitimately need to write to a scoped path, three override paths exist (in order of precedence):

### 1. Bypass env (rare; high blast radius)

```json
"override": { "bypass_env_var": "PLAN_<ID>_GATE_BYPASS" }
```

Setting `PLAN_<ID>_GATE_BYPASS=1` in your shell rc disables the gate. Use only for emergency unstick situations. **Do not delegate bypass to model — agents cannot self-issue env vars.**

### 2. Sentinel file

```json
"override": { "sentinel_override_path": "$HOME/.claude/.allow-<plan>-commit" }
```

Touch the sentinel file; the next gated write allows. Use for G2 (pre-commit) overrides. Two physical actions required (`touch` + `git commit --no-verify`).

### 3. Nonce file (recommended for runtime overrides)

```json
"override": {
  "nonce_dir": "$HOME/.claude/hooks/state/<plan>-nonces",
  "nonce_sha_anchor": "<plan>/pre-flight",
  "nonce_min_reason_length": 12,
  "nonce_consume_strategy": "basename_match_env",
  "nonce_affinity_env": "PLAN_<ID>_NONCE_TASK"
}
```

**Issuance:**

```bash
echo -e "<task-id>\t<reason ≥12 chars>\t$(git -C ~/Code/claude-stem rev-parse <plan>/pre-flight)" \
  > ~/.claude/hooks/state/<plan>-nonces/<task-id>.nonce
```

**Consumption:** Set `PLAN_<ID>_NONCE_TASK=<task-id>` in the calling shell. The helper looks for `<task-id>.nonce` (basename-match-env), validates the SHA matches the current anchor, validates the reason is ≥12 chars, then `rm`s the file on use (single-use).

**Anti-pattern:** `nonce_consume_strategy: first_match_glob` is **deprecated** (caused Plan 71 SP09 Incident β — a different task's nonce consumed an unrelated harness-intrinsic write). Always use `basename_match_env`.

## Enforcement modes

```json
"enforcement": { "match_action": "<mode>", "error_action": "<crash-posture>" }
```

| `match_action` | Behavior | Use case |
|---|---|---|
| `deny` | Match → block + log | Production scope |
| `warn` | Match → log + advisory + ALLOW write | New plan onboarding soak window |
| `dryrun` | Match → log only; no user-visible message | Pre-deploy validation |

| `error_action` | Behavior on helper crash | Use case |
|---|---|---|
| `deny` | Fail-closed; deny the write | Security-gate posture (default for new plans) |
| `ignore` | Fail-open; allow the write, log crash | Phase A bootstrap; plans where lockout cost > gate-miss cost |

New plans should onboard in `warn` mode for a soak window, then promote to `deny` after zero unexpected denials. `error_action: ignore` is acceptable during initial deployment; promote to `deny` after Phase A clean record.

## Sunset planning

The gate is **plan-lifetime**, not vault-lifetime. Declare exit conditions explicitly:

```json
"sunset": {
  "trigger_conditions": {
    "master_top_level_status_in": ["closed", "complete"],
    "git_tag_published": "<release-tag>",
    "parallel_run_validated": false
  },
  "deferral_until": null,
  "early_retire_override": {
    "reason": null,
    "authorized_at": null,
    "authorized_by": null
  },
  "phase": "A",
  "retired_at": null
}
```

**Prefer empirical exit conditions over calendar gates** (per `feedback_no_calendar_gates`). "Zero unjustified divergences across ≥50 decisions" is better than ">=7 days post-deploy". Calendar gates calcify into infrastructure debt.

**Retirement flow:** flip `enabled: false` in the manifest. The helper stops reading the gate at next decision. The manifest entry stays as historical record. Delete `nonce_dir` and `sentinel_override_path` when retiring.

## Live-deploy discipline (R-37 lockstep)

Files authored in foundation-repo (`~/Code/claude-stem/`) and live (`~/.claude/`) must stay in sync. Pattern:

1. **Foundation-first.** Author + commit at `~/Code/claude-stem/` before any live write.
2. **Manifest tracking.** Every shipped file enumerated in `governance/foundation-manifest.json` (regenerate via `generate-foundation-manifest.sh`; SP18 T-3 relocated from repo root to governance/).
3. **Install.sh coverage.** Every foundation file's deploy mechanism in `install.sh` (hooks → Step 3/3.5, schemas → Step 9, etc.).
4. **Live-deploy.** Use surgical `cp` + `patch` (not `cp -n`) when live has local additions. Per `feedback_plan_81_83_install_collision`.
5. **Sanity gate.** Run the foundation pre-commit hook + `bash -n` + `jq empty` before pushing.

**Zone-tagged commits.** Each commit should be either 100% STEM-REPO or 100% LIVE-CLAUDE/LIVE-PLANS — never mixed. Mixed-zone commits invite re-clobber on install.sh runs.

## Anti-patterns to avoid

1. **`first_match_glob` nonce strategy.** Use `basename_match_env`. Closes Incident β.
2. **Transcript-tail as sole detection signal.** Layer Tier 1 detection underneath; declare `deterministic_only: true` if your plan doesn't need Tier 3.
3. **Calendar gates as the only sunset condition.** Pair with empirical conditions.
4. **Authoring `enabled: true` without operational fields.** Documentary-only declarations don't fire the gate — the helper silently skips when `scope_paths` is empty. Either declare operational fields fully or hold off until your plan's first session can author them.
5. **Live edits without foundation mirror.** Creates re-clobber risk on next `install.sh` run.
6. **Master nonce (single nonce for all writes).** Deprecated in v1 — task-bound nonces only.
7. **In-band override field in the manifest.** Override declarations are out-of-band by design (env, sentinel, nonce file); never code-paths.

## References

- **Mechanism:** `~/.claude/hooks/lib/live-guard.sh` (plan-agnostic gate; T-3 deliverable)
- **Schema definition:** `~/.claude/schemas/plan-manifest-schema.json :: properties.live_mutation_scope` (T-2 deliverable)
- **Canonical example:** `~/.claude-plans/71-claude-foundations-engine-v2/manifest.json :: live_mutation_scope`
- **Audit log format:** `~/.claude/hooks/state/gate-decisions.log` (JSONL)
- **Audit capability:** `librarian parallel-run-audit` (for plans entering Phase A/B parallel-run validation)
- **L3 writer-pause helper:** `~/.claude/hooks/lib/l3-pause-helper.sh` (optional; for plans with launchd cron writers or SessionEnd hooks that need coordinated quiescence)
- **R-55 retirement audit trail:** `~/.claude-plans/71-claude-foundations-engine-v2/09-live-mutation-remediation/POSTMORTEM-2026-04-28-live-mutation-creep.md`
