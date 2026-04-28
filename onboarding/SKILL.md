---
title: bootstrap-schemas — populate 4 schemas from per-section onboarding extractions
type: skill
status: active
created: 2026-04-25
updated: 2026-04-25
parent_plan: 71-claude-foundations-engine-v2
sub_plan: 01-schemas-and-onboarder-contract
task: T-11
---

# bootstrap-schemas

Shell engine that consumes per-section extraction outputs from the verbal-first
onboarder and writes 4 populated schemas atomically with confidence + source-span
audit logging.

## Trigger

Invoked by SP07 onboarder UX after all 5 sections complete (or by an operator
during onboarder iteration). Inputs are 5 `extraction-output-{A..E}.json` files
plus `q-field-map.json`; outputs are the 4 populated schema instances.

## Output Contract

> R-43 mandate: every skill that writes to the user filesystem MUST declare
> files written, schema-types, pre-write validation steps, and failure mode.

### Files written (atomic `tmp+rename`)

| Order | Path | Mode | Schema-type validated against |
|---|---|---|---|
| 1 | `~/.claude/schemas/plans-schema.json` | STATIC (no transform) | JSON Schema Draft-07 (ajv compile only) |
| 2 | `~/.claude/user-manifest.json` | POPULATED instance | `~/.claude/schemas/user-manifest-schema.json` |
| 3 | `~/.claude/schemas/vault-schema.json` | PASS-THROUGH | structural — `_tag_prefixes` array shape + at least one type-key with `required[]` |
| 4 | `~/.claude/orchestration.json` | POPULATED instance | `~/.claude/schemas/orchestration-schema.json` |

### Audit log (append-only)

`~/.claude/onboarding/bootstrap-log.jsonl` — JSON-Lines.

Per-field record:
```json
{"ts":"<iso8601>","run_id":"<utc-pid>","event":"field","q_id":"B-1","section_id":"B","path":"U.identity.role","value":"<json>","confidence":<0..1|null>,"source_span":"<string|null>"}
```

Run terminator records:
- `{"event":"BOOTSTRAP_COMPLETED", ...}` — all 4 outputs written or skipped-identical.
- `{"event":"BOOTSTRAP_FAILED", ...}` — validation/parse/IO failure; rollback executed.
- `{"event":"BOOTSTRAP_DIFFER", ...}` — one or more outputs differ from live and `--force` not supplied.

### Pre-write validation steps

For each populated output (in order plans → user-manifest → vault-schema → orchestration):

1. **Parse:** instance must parse as JSON (`jq -e .`).
2. **Schema validation:**
   - If `ajv` is on PATH (or `--ajv-bin` provided), validate instance against its schema with `--strict=false`.
   - Otherwise, fall back to **structural validation**: required top-level keys from `<schema>.required[]` must be present. Documented degradation; the AC is "validates each output against schema before rename" — when `ajv` is absent, the structural check is the validator-of-record.
3. **Special-case structural checks:**
   - `vault-schema.json`: `_tag_prefixes` must exist as an array.
   - `orchestration.json`: top-level `schema_version`, `platform`, `jobs`, `tripwires`, `observability` required.
4. Only after ALL validations pass does the run move to atomic `mv` of any output.

### Failure mode — BLOCK AND LOG

Any failure (missing input file, invalid JSON, validation failure, schema source missing, IO error during atomic write) triggers:

1. Roll back every staged `*.tmp` file from this run (no live target is partially written).
2. Append `{"event":"BOOTSTRAP_FAILED","message":"<reason>"}` to the audit log.
3. Print `BOOTSTRAP_FAILED: <reason>` to stderr.
4. Exit non-zero.

Live targets remain untouched on failure (atomic `tmp+rename` semantics + pre-validation gate). No silent partial writes; no "write and hope."

### Idempotency

- Live target byte-for-byte matches `tmp` ⇒ skip rename, audit `skip-identical`, no-op success.
- Live target differs and `--force` NOT supplied ⇒ write `<target>.new` adjacent + emit unified diff on stderr + audit `differs-no-force` + exit 2 (`BOOTSTRAP_DIFFER`).
- Live target differs and `--force` supplied ⇒ atomic overwrite, audit `wrote`.

## Engine surfaces

Concentrated in this engine per T-9 hand-off contract:

| Q-ID | Path | Engine logic |
|---|---|---|
| C-3 | `U.system.opt_outs[]` | Conditional append `"sensitive_isolation"` (idempotent dedupe via `unique`). Boolean true / array containing token / case-insensitive yes-string ⇒ append. False / null / array without token ⇒ no-op. |
| D-2 | `O.jobs[0].id` | Mutual exclusion: string job-id ⇒ wire defaults bundle (`enabled:true` + archetype schedule from `q-field-map.json:direct_qs.D-2.defaults_applied` + log_path/command/idle_watchdog). Empty array / null ⇒ `O.jobs:[]` and skip D-3. |
| D-3 | `U.architect.prior_seed` | Conditional on D-2 == "architect" only. Comma-join append to existing seed (typically the inferred archetype label). Token-set deduplication prevents double-append on re-run. Off-condition emission audited as warning + omitted. |
| D-4 | `U.behavioral.hook_preferences.notification_style` | Default `"digest"` applied when extraction omits the key (read from `q-field-map.json:direct_qs.D-4.targets[0].default_value`). |
| A/E | various | Deterministic write paths — extraction outputs A/E carry the same JSON shape as B/C/D outputs but originate from UX state / binary-toggle deterministic engines, not from LLM extraction. The bootstrap engine treats them uniformly. |

## Usage

```bash
~/.claude/onboarding/bootstrap-schemas.sh \
  [--force] \
  [--dry-run] \
  [--inputs-dir DIR]      # default ~/.claude/onboarding
  [--schemas-dir DIR]     # default ~/.claude/schemas
  [--ajv-bin PATH]        # default: search PATH
  [--audit-log PATH]      # default ~/.claude/onboarding/bootstrap-log.jsonl
```

### `--dry-run` (preview mode)

Emits a unified diff per output (`current` vs `would-write`) on stderr, plus a `no-op (byte-match)` line for any output that would not change. Performs **zero filesystem mutations** to live targets or the audit log; the TMPDIR scratch directory is exempt (it lives outside any live target and is removed by the `EXIT` trap).

The validator pipeline (parse + schema check) **still runs** under `--dry-run`. This is a deliberate non-bypass: the point of dry-run is to debug the run *before* a live write, so skipping validation would defeat the purpose. A validation/parse failure exits non-zero with `BOOTSTRAP_FAILED` on stderr and **no** audit-log append.

Exit codes under `--dry-run`:

- `0` — preview emitted (any mix of `would-create` / `would-update` / `no-op`).
- `1` — parse or validation failure (no audit append; live targets untouched).
- `2` is **never** emitted under `--dry-run` (dry-run is informational, not write-attempting).

Example session:

```bash
# Preview what a fresh onboarder run would produce
$ bootstrap-schemas.sh --dry-run
DRY-RUN: plans-schema — no-op (byte-match) at ~/.claude/schemas/plans-schema.json
DRY-RUN: user-manifest — would-create at ~/.claude/user-manifest.json (full content as diff vs /dev/null):
--- /dev/null
+++ /tmp/.../user-manifest.json
@@ ... @@
+{ ... }
DRY-RUN: vault-schema — no-op (byte-match) at ~/.claude/schemas/vault-schema.json
DRY-RUN: orchestration — would-create at ~/.claude/orchestration.json (full content as diff vs /dev/null):
... 
DRY-RUN: complete — 2 would-write, 2 no-op (byte-match); zero filesystem mutations
```

## Constraints

- bash 3.2.57 (Apple `/bin/bash`) — no `declare -A`, no `mapfile`/`readarray`, no `${var,,}`.
- `jq` required on PATH; `ajv` optional (structural fallback).
- macOS Sequoia or later.

## Cross-references

- Spec: `~/.claude-plans/71-claude-foundations-engine-v2/01-schemas-and-onboarder-contract/spec.md`
- Tasks: same dir, `tasks.md` T-10 (lines 544–565), T-11 (`--dry-run`, lines 608–622).
- Q→field map: `~/.claude/onboarding/q-field-map.json` (T-8).
- Extraction prompts: `~/.claude/onboarding/extraction-prompts/section-{A..E}.md` (T-9).
- Archetype-inference companion: `~/.claude/onboarding/archetype-inference.sh` (T-7a).

## Deferred / out-of-scope

- **`_tag_prefixes` archetype-seed merge.** `q-field-map.json` carries no direct path mapping to `vault-schema.json:_tag_prefixes`; the archetype-seed merge (consultant ⇒ engagement/deliverable/stakeholder, developer ⇒ repo/commit-log/design-doc, writer ⇒ essay/draft/outline per `archetype-keywords.json`) is a separate engine pass owned by T-12 fixture round-trips. T-10 ships vault-schema as PASS-THROUGH.
