---
name: bootstrap-schemas
description: >
  Atomic finalizer for the onboarder. Consumes per-section LLM extraction outputs
  and writes 4 schema-validated configuration files (plans-schema, user-manifest,
  vault-schema, orchestration) with confidence + source-span audit logging. Block
  and log on any failure — no partial writes ever land. Invoked by the onboarder UX,
  not by adopters directly.
disable-model-invocation: true
argument-hint: "[--force] [--dry-run] [--inputs-dir DIR] [--schemas-dir DIR] [--ajv-bin PATH] [--audit-log PATH]"
---

# bootstrap-schemas

The shell engine the onboarder uses to populate your config files. After the
verbal-first onboarder runs all five sections (A: identity, B: work, C: vault,
D: trust, E: confirmation), it has five `extraction-output-{A..E}.json` files
sitting in `~/.claude/onboarding/`. Each populates different fields scattered
across multiple schemas.

Doing the merge naively means partial state on failure, no audit trail of which
question populated which field, no idempotency check, no atomicity guarantee.
This engine is the deterministic finalizer: it reads the five extraction outputs,
applies the question-ID-to-schema-path map (`q-field-map.json`), writes each
populated schema instance through a tmp+rename atomic gate, validates against
the declared schema, and emits per-field plus per-run JSONL audit records.

Block and log on any failure: rollback every staged tmp file, append a
`BOOTSTRAP_FAILED` terminator to the audit log, exit non-zero. Live targets
remain untouched. Idempotent: if a target byte-matches the would-write payload,
skip the rename and audit `skip-identical`. If it differs without `--force`,
write a `<target>.new` sidecar plus a unified diff and exit 2.

Most adopters never invoke this script directly — the onboarder calls it.

## Output Contract

### Files written (atomic `tmp + rename`)

| Order | Path | Mode | Validated against |
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

Run-terminator records:

- `{"event":"BOOTSTRAP_COMPLETED", ...}` — all 4 outputs written or skipped-identical.
- `{"event":"BOOTSTRAP_FAILED", ...}` — validation, parse, or IO failure; rollback executed.
- `{"event":"BOOTSTRAP_DIFFER", ...}` — one or more outputs differ from live and `--force` not supplied.

### Pre-write validation

For each populated output (in order plans → user-manifest → vault-schema → orchestration):

1. **Parse.** Instance must parse as JSON (`jq -e .`).
2. **Schema validation.**
   - If `ajv` is on PATH (or `--ajv-bin` provided), validate the instance against its schema with `--strict=false`.
   - Otherwise, fall back to **structural validation**: required top-level keys from `<schema>.required[]` must be present. Documented degradation; the acceptance criterion is "validates each output against schema before rename" — when `ajv` is absent, the structural check is the validator of record.
3. **Special-case structural checks.**
   - `vault-schema.json`: `_tag_prefixes` must exist as an array.
   - `orchestration.json`: top-level `schema_version`, `platform`, `jobs`, `tripwires`, `observability` required.
4. Only after ALL validations pass does the run move to atomic `mv` of any output.

### Failure mode — block and log

Any failure (missing input file, invalid JSON, validation failure, schema source missing, IO error during atomic write) triggers:

1. Roll back every staged `*.tmp` file from this run — no live target is partially written.
2. Append `{"event":"BOOTSTRAP_FAILED","message":"<reason>"}` to the audit log.
3. Print `BOOTSTRAP_FAILED: <reason>` to stderr.
4. Exit non-zero.

Live targets remain untouched on failure (atomic `tmp + rename` semantics + pre-validation gate). No silent partial writes; no "write and hope."

### Idempotency

- Live target byte-for-byte matches `tmp` ⇒ skip rename, audit `skip-identical`, no-op success.
- Live target differs and `--force` NOT supplied ⇒ write `<target>.new` adjacent + emit unified diff on stderr + audit `differs-no-force` + exit 2 (`BOOTSTRAP_DIFFER`).
- Live target differs and `--force` supplied ⇒ atomic overwrite, audit `wrote`.

## Engine surfaces

The engine has special logic for a handful of question IDs whose mapping isn't a straight field copy. These are documented for contributors wiring new questions into the map:

| Q-ID | Path | Engine logic |
|---|---|---|
| C-3 | `U.system.opt_outs[]` | Conditional append `"sensitive_isolation"` (idempotent dedupe via `unique`). Boolean true / array containing the token / case-insensitive yes-string ⇒ append. False / null / array without token ⇒ no-op. |
| D-2 | `O.jobs[0].id` | Mutual exclusion: a string job-id ⇒ wire defaults bundle (`enabled:true` + archetype schedule from `q-field-map.json:direct_qs.D-2.defaults_applied` + `log_path` / `command` / `idle_watchdog`). Empty array / null ⇒ `O.jobs:[]` and skip D-3. |
| D-3 | `U.architect.prior_seed` | Conditional on `D-2 == "architect"` only. Comma-join append to existing seed (typically the inferred archetype label). Token-set deduplication prevents double-append on re-run. Off-condition emission audited as warning + omitted. |
| D-4 | `U.behavioral.hook_preferences.notification_style` | Default `"digest"` applied when extraction omits the key (read from `q-field-map.json:direct_qs.D-4.targets[0].default_value`). |
| A / E | various | Deterministic write paths — extraction outputs A and E carry the same JSON shape as B/C/D outputs but originate from UX state and binary-toggle deterministic engines, not from LLM extraction. The engine treats them uniformly. |

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

- bash 3.2.57 (Apple `/bin/bash`) — no `declare -A`, no `mapfile` / `readarray`, no `${var,,}`.
- `jq` required on PATH; `ajv` optional (structural fallback).
- macOS Sequoia or later.

## Cross-references

- Question-to-field map: `~/.claude/onboarding/q-field-map.json`.
- Extraction prompts: `~/.claude/onboarding/extraction-prompts/section-{A..E}.md`.
- Archetype-inference companion: `~/.claude/onboarding/archetype-inference.sh`.
