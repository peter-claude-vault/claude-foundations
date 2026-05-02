---
title: Initial Autonomous Job Setup — 8-Question Flow
type: design-doc
status: draft
created: 2026-04-30
updated: 2026-04-30
parent_plan: 71-claude-foundations-engine-v2
sub_plan: 03-orchestration-engine
task: T-12
schema_version: 1.0.0
---

# Initial Autonomous Job Setup — 8-Question Flow

The orchestration sub-flow that customizes a single launchd job at first install. SP07 T-9 (`onboarding/initial-job-setup.sh`) absorbs this spec when SP07 unpauses; this document is the canonical source for question text, validation rules, defaults, and the Q→field map.

## 1. Scope and relationship to SP01

This is a **sub-flow of SP01 D-2** ("First scheduled job choice"), not a new Q-ID block. The 8 questions are user-facing surfacings of D-2's `defaults_applied` table (`~/Code/claude-foundations-v2/onboarding/q-field-map.json` D-2 entry). They do not introduce new Q-IDs into the §10 namespace lock at `onboarder-design.md`.

Two manifest fields surfaced for the first time — `jobs[].budget_usd` and `jobs[].model` — are added to D-2's `defaults_applied` block via additive amendment per the SP02-T-0 precedent (foundation-repo `f9e096a`). No SP01 T-8 reopening required.

The flow runs **after** Section D commits its schema fragment. Q1's value is pre-filled from D-2 (`O.jobs[0].id`); the remaining 7 questions customize the other `jobs[0]` fields. If D-2 resolved to `none`, this entire 8-Q flow is skipped — `O.jobs: []` is written, no plist is staged, no terminal prompt fires.

## 2. The flow at a glance

| Q | Question | Manifest field | Default | Skip condition |
|---|---|---|---|---|
| 1 | First job | `O.jobs[0].id` | `librarian` | — (entry gate) |
| 2 | Time of day | `O.jobs[0].schedule.{hour,minute}` | `06:00` | Q1=`none` |
| 3 | Timezone | `U.system.timezone` (already A-3) | autodetected | Q1=`none` |
| 4 | Weekly day | `O.jobs[0].schedule.dow` | `1` (Monday) | Q1≠`architect` |
| 5 | Cron log directory | `O.jobs[0].log_path` | `~/.claude/logs` | Q1=`none` |
| 6 | Per-call budget | `O.jobs[0].budget_usd` | `5` (lib) / `10` (arch) | Q1=`none` |
| 7 | Model | `O.jobs[0].model` | `sonnet` (lib) / `opus` (arch) | Q1=`none` |
| 8 | Skip weekends | `O.jobs[0].skip_weekends` | `true` | Q1≠`librarian` |

Total user time: 60–90 seconds typical (most defaults accepted with Enter).

## 3. Question specifications

### Q1 — First autonomous job

**Prompt:**
```
Which autonomous job should we set up for you first?

  1. librarian — daily vault hygiene + memory consolidation (~6:00 AM, ~$5/run, sonnet)
  2. architect — weekly system audit + recommendations (Mondays 6:00 AM, ~$10/run, opus)
  3. none      — skip; no scheduled job is set up.

Default: librarian
```

**Field:** `O.jobs[0].id`
**Type:** string, enum
**Allowed values:** `librarian` | `architect` | `none`
**Validation:** Q1=`none` → write `O.jobs: []` and short-circuit Q2-Q8.
**Pre-fill:** SP01 D-2 (`O.jobs[0].id`); user confirms or changes here.

### Q2 — Time of day

**Prompt:**
```
What time should the job fire? (24-hour HH:MM, your local timezone)

Default: 06:00
```

**Fields:** `O.jobs[0].schedule.hour` (integer 0–23), `O.jobs[0].schedule.minute` (integer 0–59)
**Validation:** parse `^([01]?\d|2[0-3]):[0-5]\d$`; reject otherwise.
**Pre-fill:** SP01 D-2 `defaults_applied.O.jobs[0].schedule.{hour,minute}` (06:00 for both jobs).

### Q3 — Timezone

**Prompt:**
```
Confirm your timezone:

Detected: ${TZ_DEFAULT}

Press Enter to accept, or type an IANA name (e.g. America/Los_Angeles, Europe/London).
```

**Field:** `U.system.timezone` (already captured at SP01 A-3; this Q is a confirm-and-correct display, not a re-prompt).

**Autodetect:** privilege-free, launchd-context-safe, byte-identical to `installer/render-launchd.sh:169`.

```sh
TZ_DEFAULT="${TZ:-$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')}"
TZ_DEFAULT="${TZ_DEFAULT:-America/New_York}"
```

**Fallback chain:** `$TZ` env → `readlink /etc/localtime` → hardcoded `America/New_York`.

**Validation:** must be IANA `Continent/City` form. `date +%Z` (returns `EDT`) is **NOT** a valid value — abbreviation rejected at extraction. `systemsetup -gettimezone` is intentionally not used (requires admin even for read; fails under launchd).

**Render flow:** the value is read from manifest at install time and passed as `$TZ` env var to `render-launchd.sh`'s envsubst pass. It is **not** a jq-extracted field of `orchestration.json` at render time — it flows via process env.

### Q4 — Weekly day (architect only)

**Prompt (asked only if Q1 = architect):**
```
Which day of the week should the architect run?

  Sun=0  Mon=1  Tue=2  Wed=3  Thu=4  Fri=5  Sat=6

Default: 1 (Monday)
```

**Field:** `O.jobs[0].schedule.dow` (array of integers 0–6, single-element `[N]`)
**Validation:** integer 0–6; serialized as a single-element array `[N]`.
**Skip condition:** Q1 = `librarian` → field omitted entirely; librarian fires daily.
**Render-launchd consumption:** `installer/render-launchd.sh:155` reads `.schedule.dow[0]`; only the first element is consumed.

> **Drift note (CFF-S56-7):** `orchestration-schema.json` declares `dow` as a multi-element array, but `render-launchd.sh` reads only `[0]`. Either the schema needs `maxItems: 1` for the StartCalendarInterval branch, or the renderer needs to emit launchd's `StartCalendarInterval` array form. Tracked as SP03 v2_1_deferral.

### Q5 — Cron log directory

**Prompt:**
```
Where should cron logs be written?

Default: ~/.claude/logs
```

**Field:** `O.jobs[0].log_path`
**User-facing form:** displayed as `~/.claude/logs` (familiar to most users).
**Manifest write form:** absolute path (eval-expanded). Tilde and `$VAR` references must be resolved before write so downstream consumers (jq → bash without `eval`) don't emit literal tildes.
**Default value resolution:** `$CLAUDE_HOME/logs` where `CLAUDE_HOME` defaults to `$HOME/.claude` per `orchestrator/lib/paths.sh:21,83`.

> **Drift note (CFF-S56-4):** `orchestration-schema.json` declares `jobs[].log_path` required, but `render-launchd.sh` consumes `$CLAUDE_LOG_DIR` env directly (templates `librarian.plist.tmpl:14, 26-28` and `architect.plist.tmpl:13-14, 26-28`) — `log_path` is currently a write-only field. Forward-compat: T-12 doc still writes the field. Either wire `log_path` through the templates or drop `log_path` from the schema's required list. Tracked as SP03 v2_1_deferral.

### Q6 — Per-call budget cap

**Prompt:**
```
Per-call budget cap (USD)?

Default: $5 (librarian) | $10 (architect)

Note: librarian fires up to 3 sub-calls per run + 1 cold-wake probe; architect fires once.
```

**Field:** `O.jobs[0].budget_usd` (number, ≥0)
**Default (per-job conditional):**
- librarian → `5` (mirrors `librarian-cron.sh:177` `--max-budget-usd 5`)
- architect → `10` (mirrors `architect-cron.sh:84,90` `--max-budget-usd 10`)

**Semantics:** per-`claude -p`-invocation cap, NOT per-wall-clock-run total. Consumed by `orchestrator/job-runner.sh:94,158` as the `--max-budget-usd` flag passed to a single claude invocation.

**Worst-case wall-clock cost:**
- librarian: `$5 × 3 calls + $1 cold-wake probe = $16/run`
- architect: `$10 × 1 call = $10/run`

**Absent value:** schema permits omission → no `--max-budget-usd` flag passed → unlimited. Onboarder writes the explicit default; users may delete the field manually post-onboard for unlimited.

> **Drift note (CFF-S56 covered):** SP03 tasks.md L304 wording "(6) budget/run" is misleading; it's per-call. Inline-fixed in S56 close-out.

### Q7 — Model

**Prompt:**
```
Which Claude model should this job use?

  1. sonnet (default for librarian)
  2. opus   (default for architect)
  3. haiku

Default: ${PER_JOB_DEFAULT}
```

**Field:** `O.jobs[0].model`
**Type:** string, enum
**Allowed values:** `sonnet` | `opus` | `haiku` (per `orchestration-schema.json:74-78`)
**Default (per-job conditional):**
- librarian → `sonnet` (mirrors `librarian-cron.sh:89,176`)
- architect → `opus` (mirrors `architect-cron.sh:83,89`)

**Schema fallback:** `orchestration-schema.json` declares uniform `default: "sonnet"`. The cron-wrappers override to opus for architect; the onboarder mirrors cron-wrapper truth (per-job conditional default), not schema fallback — otherwise architect users always pay the manual override tax.

### Q8 — Skip weekends (librarian only)

**Prompt (asked only if Q1 = librarian):**
```
Skip weekend runs (Saturday + Sunday)?

  yes / no

Default: yes
```

**Field:** `O.jobs[0].skip_weekends` (boolean, default `true`)
**Skip condition:** Q1 ≠ `librarian` → field omitted entirely. Architect already runs once per week (Q4 picks the day) — skip-weekends is meaningless for architect.

**Wiring:**
- The boolean is exported by `render-launchd.sh` into `librarian.plist.tmpl`'s `EnvironmentVariables` block as `SKIP_WEEKENDS=true|false`.
- `orchestrator/cron-wrappers/librarian-cron.sh` reads `${SKIP_WEEKENDS:-true}` from env; gates the `if [ "$DOW" -gt 5 ]; then exit 0` block on this value.
- Default `true` preserves backward-compat with the pre-T-12 hardcoded weekend-skip behavior.

**Required c1.5 changes (shipped this session):**
1. `schemas/orchestration-schema.json` — add `jobs[].skip_weekends: boolean` (additive; default `true`)
2. `orchestrator/cron-wrappers/librarian-cron.sh` — gate weekend-skip by `SKIP_WEEKENDS` env

**Deferred to SP03 T-15 / SP07 T-9 (not c1.5 scope):**
1. `templates/launchd/librarian.plist.tmpl` — add `SKIP_WEEKENDS` to `EnvironmentVariables` block
2. `installer/render-launchd.sh` — export `SKIP_WEEKENDS` from `jobs[0].skip_weekends`; add to allowlist for librarian branch

The wrapper gate alone is sufficient for backward-compat (defaults to `true` if env unset). Plist/render wiring lands when SP07 T-9 implements the rendering pipeline.

## 4. Q→field map (canonical)

| Q | Manifest path | Type | Default | Source-of-truth |
|---|---|---|---|---|
| 1 | `O.jobs[0].id` | string enum | `librarian` | `q-field-map.json` D-2 |
| 2 | `O.jobs[0].schedule.hour` | int 0-23 | `6` | D-2 `defaults_applied` |
| 2 | `O.jobs[0].schedule.minute` | int 0-59 | `0` | D-2 `defaults_applied` |
| 3 | `U.system.timezone` | string IANA | autodetected | A-3 (pre-existing) |
| 4 | `O.jobs[0].schedule.dow` | int[] | `[1]` | D-2 `defaults_applied` (architect only) |
| 5 | `O.jobs[0].log_path` | string abs-path | `$CLAUDE_HOME/logs` | D-2 `defaults_applied` |
| 6 | `O.jobs[0].budget_usd` | number ≥0 | `5`/`10` per-job | D-2 `defaults_applied` (added S56) |
| 7 | `O.jobs[0].model` | string enum | `sonnet`/`opus` per-job | D-2 `defaults_applied` (added S56) |
| 8 | `O.jobs[0].skip_weekends` | boolean | `true` | NEW field S56 (orchestration-schema.json + librarian-cron.sh) |

Always written:
- `O.jobs[0].enabled` = `true` (D-2 `defaults_applied`)
- `O.jobs[0].command` = `$CLAUDE_HOME/orchestrator/cron-wrappers/<id>-cron.sh` (manifest contract; rendered into plist `ProgramArguments`)
- `O.jobs[0].idle_watchdog_sec` = `180` (D-2 `defaults_applied`)
- `O.platform` = `darwin-launchd` (constant)

## 5. Production output chain

```
Q1-Q8 answers
  ↓
write to orchestration.json (jobs[0] populated; budget_usd + model + schedule + skip_weekends)
  ↓
$CLAUDE_HOME/installer/render-launchd.sh \
  --staging-dir $CLAUDE_HOME/Library/LaunchAgents.staging/ \
  <job-id>
  ↓
plist staged at $CLAUDE_HOME/Library/LaunchAgents.staging/com.claude-foundations.<label>.plist
  ↓
terminal prompt: "Onboarding complete. Run `claude system enable-daemon` to activate."
  ↓
[user-initiated, separate invocation; SP08-owned]
  ↓
claude system enable-daemon
  ├─ G1–G10 installer-tree validation (G6 enforces com.claude-foundations.* prefix)
  ├─ mv staged plist → ~/Library/LaunchAgents/<Label>.plist
  └─ launchctl bootout (idempotent) + launchctl bootstrap gui/$UID
```

**SP07 onboarder does NOT invoke `launchctl bootstrap` on the user's real host** (per SP07 spec L86-102 + SP00 invariant I2). Activation is opt-in and gated by SP08's G1-G10 validation.

> **Inter-project gap (CFF-S56-2):** The `claude system enable-daemon` CLI is named in SP07 spec L99 but is not yet shipped as a named SP08 task line-item. SP08 tasks.md ships `install.sh` (T-1) and `uninstall.sh` (T-2). Whether `enable-daemon` is part of `install.sh` or a separate CLI shim is unowned. Flagged as a missing-task gap on the SP08 manifest; T-12 doc still references the contracted command name per the SP07 spec promise.

## 6. Test/dogfood output chain (footnote)

For SP07 T-11 Alex-archetype greenfield dogfood and Peter reinstall:
- `launchctl bootstrap` invocations run inside SP00 T-1 Lima VM
- Wrapped in SP00 T-9 sandbox-exec profile (deny-default; allow only `$DOGFOOD_ROOT/Library/LaunchAgents/` writes + launchctl IPC)
- `$DOGFOOD_ROOT` is the Lima-scoped `CLAUDE_HOME` isolation root; never resolves to `$HOME` on the real host

See SP00 (isolation-harness) tasks.md T-9 (sandbox-exec profile) and SP07 (onboarder-ux) tasks.md T-11 (Alex dogfood).

## 7. TCC grant pointer

After running `claude system enable-daemon`, the user's first launchd fire requires Full Disk Access for the cron-wrapper to read `$VAULT_ROOT` and write `$VAULT_LOGS`. The terminal prompt at the end of the onboarder includes:

```
After running `claude system enable-daemon`, grant Full Disk Access to /bin/bash
in System Settings → Privacy & Security → Full Disk Access.

See docs/installer.md §TCC for step-by-step instructions including
MDM-managed-device caveats.
```

Full macOS-specific instructions (MDM caveats, signed-binary inheritance, sandbox-exec interactions under launchd) are deferred to SP08's `docs/installer.md` runbook (SP08 T-9 deliverable). T-12 surfaces the pointer; SP08 owns the content.

## 8. Failure modes

| ID | Failure | Mitigation |
|---|---|---|
| F1 | User picks `none` at Q1 | Write `O.jobs: []`; skip Q2-Q8; emit "No autonomous job configured. Run `claude onboard rerun` to add one later." |
| F2 | TZ autodetect returns empty (`/etc/localtime` not a symlink) | Fall back to hardcoded `America/New_York`; surface field for confirmation in Q3 prompt. |
| F3 | User enters non-IANA TZ (e.g., `EDT`, `PST`) | Reject at extraction; re-prompt with "Must be `Continent/City` form, e.g., `America/New_York`." |
| F4 | User enters time outside 0-23:0-59 | Reject; re-prompt. |
| F5 | Q4 weekly day out of range (architect) | Reject; re-prompt with day name table. |
| F6 | User enters relative path at Q5 (e.g., `./logs`) | Reject; require absolute path or `~/...` (which is eval-expanded to absolute). |
| F7 | User enters negative budget at Q6 | Reject (schema `minimum: 0`). |
| F8 | User enters model not in enum at Q7 | Reject; show enum values. |
| F9 | Re-onboard while previous staged plist exists | render-launchd.sh's atomic `mv` overwrites staging cleanly. If a previous `enable-daemon` already moved the staged plist to `~/Library/LaunchAgents/`, staging dir is empty and second `enable-daemon` is a no-op for that job. Document as expected. |

## 9. Acceptance self-check

- [x] 8 questions enumerated with prompt text + manifest mapping
- [x] TCC grant pointer included (defers full instructions to SP08 docs/installer.md §TCC)
- [x] Default first job = librarian (Q1 default)
- [x] Q1=`none` short-circuits to `O.jobs: []` with both jobs effectively disabled (no jobs in array)
- [x] Production chain stages-only (no bootstrap from onboarder)
- [x] Q3 TZ uses `readlink /etc/localtime` (not `systemsetup -gettimezone`)
- [x] Q6 budget defaults match cron-wrapper truth: librarian=$5, architect=$10
- [x] Q7 model defaults match cron-wrapper truth: librarian=sonnet, architect=opus
- [x] Q8 librarian-only; architect skipped (Q4 already picks weekly day)
- [x] CFF-S56-1 (TZ spec drift), CFF-S56-2 (enable-daemon gap), CFF-S56-4 (log_path drift), CFF-S56-7 (dow array drift) flagged inline

## 10. References

- SP03 (orchestration-engine) spec L96-114 — T-12 spec source
- SP03 (orchestration-engine) tasks L296-314 — T-12 task block
- SP07 (onboarder-ux) spec L86-102 — production-vs-test isolation
- SP07 (onboarder-ux) tasks L184-207 — SP07 T-9 absorbs this flow
- SP08 (distribution-installer-adopt) spec L80, L69-105 — G6 + G1-G10 guards
- `~/Code/claude-foundations-v2/installer/render-launchd.sh` L162-203 — TZ + envsubst allowlist (S55 commit `48cee95`)
- `~/Code/claude-foundations-v2/templates/launchd/librarian.plist.tmpl` — daily plist (no Weekday key)
- `~/Code/claude-foundations-v2/templates/launchd/architect.plist.tmpl` — weekly plist (single Weekday)
- `~/Code/claude-foundations-v2/orchestrator/cron-wrappers/librarian-cron.sh` L53-57 — weekend-skip gate (post-S56: SKIP_WEEKENDS env)
- `~/Code/claude-foundations-v2/orchestrator/cron-wrappers/architect-cron.sh` L83-90 — model + budget defaults
- `~/Code/claude-foundations-v2/schemas/orchestration-schema.json` L19-86 — jobs[] schema
- `~/Code/claude-foundations-v2/onboarding/q-field-map.json` D-2 entry — `defaults_applied` table
- `~/Code/claude-foundations-v2/onboarding/onboarder-design.md` §6 + §10 — Section D + Q-ID enumeration
