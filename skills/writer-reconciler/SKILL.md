---
name: writer-reconciler
description: >
  Runtime reconciler for vault writer staged packets. Picks up packets from
  `~/.claude/state/vault-staging/`; applies mechanical-only reconciliation
  (winner-pick / dedup / append per R-34) keyed by per-folder
  `_processing-rules.json` resolution (folder > file-type-contracts >
  universal pillar 7 default). NO classification, NO routing decisions —
  those are the writers' responsibility upstream. Renamed + reshaped from
  inbox-processor under Plan 81 SP14 Batch B T-11 (2026-05-18) per SP13
  alignment Session 4 A37. Extended SP14 Batch F T-27 (2026-05-19) with
  step 8.5 (daily-processing JSONL append) + step 8.6 (manifest.sqlite
  record-write) per writer-pipeline-layering L-102..L-104 / §A61 — both
  mechanical writes preserving R-34.
disable-model-invocation: true
argument-hint: "[--staging-root PATH] [--destination PATH] [--dry-run]"
---

# Writer Reconciler

Runtime reconciler for the vault writer pipeline (Posture D — per-destination
contract-driven hybrid; Session 4 L-41). Writers running under `posture: staged`
emit content packets to `~/.claude/state/vault-staging/<writer-id>/<sha>.json`
via `lib/staging-emit.sh`. This skill picks up packets on cron tick (15-min
default per pillar 7 `reconciler_tick_minutes_default`) and writes the resolved
content to the canonical destination via mechanical-only reconciliation.

Reconciliation rules resolution follows three-tier precedence per Session 4 L-44:

1. **Folder-level `_processing-rules.json`** at the destination directory (or
   walked-up parent); honors `applies_to: this-folder-and-subfolders` inheritance.
2. **File-type-contracts** (`governance/file-type-contracts/<type>.md.json`)
   when the destination's `output_type` matches a known contract.
3. **Universal pillar 7 defaults** (`governance/vault-writers-rules.json :: processing_defaults`)
   as the floor — `dedup: content-hash`, `survivorship: newer-mtime-wins`,
   `merge: union-dedupe-by-key`.

The reconciler is **mechanical-only** per Session 4 L-50 + R-34 self-healing
boundary. Semantic merging (paraphrase, summarization, re-ordering by meaning)
is OUT of scope. Operator edits are preserved via two-signal detection per
Session 4 L-45.

## Invocation

```sh
# Cron tick (every 15 min default; bootstrapped by install-cron.sh)
./process.sh

# Explicit flush of a single destination (waits for packets, applies, exits)
./process.sh --destination /path/to/Vault/Engagements/X/Updates.md

# Dry-run — see reconciliation plan, write nothing
./process.sh --dry-run

# Install the launchd cron (renders templates/launchd/writer-reconciler.plist.tmpl)
./install-cron.sh

# Preview the rendered plist without bootstrapping
./install-cron.sh --dry-run
```

The cron interval is read from `governance/vault-writers-rules.json :: reconciler_tick_minutes_default`
(default 15). Adopters override via overlay-master `vault_writers` slot.

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--staging-root <path>` | `~/.claude/state/vault-staging` (or `$STAGING_ROOT` env) | Root of the staging area; per-writer subdirs enumerated under it. |
| `--destination <path>` | (off — all destinations) | Process only packets whose `destination_path` matches; useful for explicit flushes. |
| `--dry-run` | off | Emit reconciliation plan on stdout; no file writes. |
| `--rules-file <path>` | `governance/vault-writers-rules.json` | Override pillar-7 universal defaults source. |
| `--audit-log <path>` | `$CLAUDE_LOG_DIR/writer-reconciler-audit.log` | Append-only audit log (one JSONL row per packet processed). |

## Per-tick pipeline

Per packet under `~/.claude/state/vault-staging/<writer-id>/*.json`:

1. **Parse packet.** Validate JSON; extract `destination_path`, `output_type`,
   `body`, `content_sha256`, `metadata`. Reject if malformed → sidecar
   `_reconciler-error.json` written; original packet retained.
2. **Resolve allowed-destination check.** Reject if `destination_path` is
   outside the union of `{$VAULT_ROOT/**, ~/.claude/**}` (librarian-only
   files). Sidecar error; packet retained.
3. **Resolve rules.** Walk up from `destination_path` to find nearest
   `_processing-rules.json` (per `applies_to` inheritance per Session 4 L-53);
   fall back to file-type-contracts based on filename extension /
   frontmatter `type:`; fall back to universal pillar 7 `processing_defaults`.
4. **Apply dedup** (`content-hash | destination-path-key | none`): consult
   prior reconciliation state; skip packet if duplicate.
5. **Apply survivorship** (`operator-edit-wins | newest-wins | merge`):
   if destination already exists, apply the policy. Two-signal operator-edit
   detection per Session 4 L-45 (`last_user_edit` frontmatter timestamp OR
   content-hash diff against last-known-write).
6. **Apply merge** (`append | winner-pick | section-merge`): when
   survivorship requires merge, compose final content per the merge
   strategy.
7. **Atomic write** to `destination_path` via tempfile + mv. The standard
   write path passes through pre-write-guard.sh + post-write-verify.sh.
8. **Remove processed packet** from staging (delete the `.json` file under
   `~/.claude/state/vault-staging/<writer-id>/`).
8.5. **Append row to daily-processing JSONL** per writer-pipeline-layering
   L-99 + L-102 + L-104 / §A61. Target path:
   `$VAULT_WRITER_STATE_ROOT/daily-processing/YYYY-MM-DD/<destination-slug>.jsonl`
   (pillar 7 `daily_processing_root` default
   `~/.local/share/claude-stem/vault-writers/daily-processing/`). One row
   per writer-emit that touched this destination today. Row fields:
   `{ts, packet_sha, writer_id, destination_path, content_sha256,
   output_type, packet_kind, write_bucket}`. **`<destination-slug>`
   derivation:** strip leading `/`; replace `/`, ` `, `.` with `_` (e.g.,
   `/Vault/Meetings/2026-05-19 standup.md` →
   `Vault_Meetings_2026-05-19_standup_md`). **MPSC discipline (L-101):**
   reconciler is the sole writer; subsequent ticks READ this file BEFORE
   step 4 (dedup) / step 5 (survivorship) to recover prior-writer activity
   on the destination without re-reading vault state. **Day-rollover
   immutability (L-100):** filename keyed by UTC date at append time;
   active file freezes at midnight UTC; new day starts empty;
   archived-not-cleared. Atomic append via `>>` (POSIX atomic for
   sub-PIPE_BUF writes; per-line JSONL fits). R-34 preserved: this is a
   LOG OF mechanical decisions, NOT a re-merge surface per L-103.
8.6. **Write manifest.sqlite row** per writer-pipeline-layering L-96 +
   L-104 / §A60 + §A61. Invoke
   `bash $REPO_ROOT/lib/manifest-record.sh record-write` with
   `--writer-id <packet.writer_id>` `--destination-path
   <packet.destination_path>` `--content-sha256 <packet.content_sha256>`
   `--write-bucket <create|modify-append|modify-amend>` (derived from
   prior history at `query-destination-history`: zero rows → `create`;
   non-empty + `packet_kind == amender-replacement` → `modify-amend`;
   else → `modify-append`) `--packet-kind <packet.packet_kind>`
   `[--source-id <packet.source_id>]` `[--raw-path <packet.metadata.raw_path>]`.
   When the new write supersedes a prior active row (same
   `(writer_id, destination_path)` tuple), pass
   `--supersedes <prior-row-id>` so the library marks the predecessor
   `status='superseded' + superseded_by=<new-id>` in the same transaction.
   Target file: `$WRITER_MANIFEST_PATH` (pillar 7 default
   `~/.local/share/claude-stem/vault-writers/manifest.sqlite`); schema
   contract: `schemas/writer-manifest-schema.json`. R-34 preserved: this
   is a mechanical INSERT against a fixed 12-field row contract, NOT a
   semantic merge.
9. **Emit one audit-log row** per reconciliation. Idempotent: re-running on
   an empty staging dir is a no-op.

## Output Contract

**Files written:**
- Destination files at packet-declared `destination_path` — atomic temp+rename
  via the standard write path; passes through `pre-write-guard.sh` (write-time
  governance enforcement) and `post-write-verify.sh` (Tier 1 reconciliation).
  The reconciler NEVER writes outside the staged packet's declared destination.
- Removes processed packets from `~/.claude/state/vault-staging/<writer-id>/`
  after successful reconciliation.
- For rejected/unreconcilable packets: writes a sidecar
  `<packet-sha>._reconciler-error.json` next to the original packet in the
  staging dir; the original packet is RETAINED for operator triage (per
  Session 4 L-55 — packets stay in staging on failure; cron retries up to
  `unreconciled_archive_days_default` per pillar 7).
- One JSONL row per packet processed in `$CLAUDE_LOG_DIR/writer-reconciler-audit.log`
  (append-only; rotated externally by librarian log-archive capability).
- **NEW SP14 Batch F T-27 (2026-05-19) — daily-processing JSONL** at
  `$VAULT_WRITER_STATE_ROOT/daily-processing/YYYY-MM-DD/<destination-slug>.jsonl`
  (pillar 7 `daily_processing_root` default
  `~/.local/share/claude-stem/vault-writers/daily-processing/`). One row
  appended per reconciled write (step 8.5). MPSC discipline (single-writer
  reconciler; multi-reader future) per L-101. Day-rollover immutability per
  L-100. Atomic POSIX `>>` append. Archived-not-cleared lifecycle.
- **NEW SP14 Batch F T-27 (2026-05-19) — SQLite manifest row** at
  `$WRITER_MANIFEST_PATH` (pillar 7 default
  `~/.local/share/claude-stem/vault-writers/manifest.sqlite`). One row
  written per reconciled write (step 8.6) via
  `lib/manifest-record.sh record-write`. Logical supersession on amend
  (predecessor row receives `status='superseded' + superseded_by=<new-id>`
  in same transaction per `--supersedes <id>` flag). WAL mode + 4 indexes
  per L-96.

**Schema:** every reconciled-write conforms to the destination file-type's
contract — the writer-reference frontmatter was validated against
`governance/file-type-contracts/vault-writer.md.json` at staging-emit time per
Session 5 L-58; the reconciler **trusts upstream validation and does NOT
re-validate writer-reference frontmatter** at reconciliation time (per Session
4 L-50 — mechanical-only ops). The destination file shape is governed by its
own file-type-contract (resolved in step 3 above).

**Pre-write validation:**
- Packet JSON validates against the embedded `packet_version` shape — admits
  BOTH `"1.0"` (Session 4 A35 baseline) AND `"1.1"` (SP14 Batch D T-26
  extension; adds optional `source_id` + `packet_kind` fields with
  back-compat defaults). v1.0 packets continue to be admitted; v1.1
  `packet_kind` defaults to `writer-emit` for back-compat. Required fields
  for both versions: `packet_version`, `writer_id`, `emitted_at`,
  `destination_path`, `content_sha256`, `body`, `output_type`, `metadata`.
- Daily-processing JSONL append (step 8.5) validates the constructed row
  shape before `>>` append (block-and-log on malformed row composition).
- Manifest record-write (step 8.6) is gated by `lib/manifest-record.sh`'s
  CHECK constraints (status enum + write_bucket enum + packet_kind enum)
  per `schemas/writer-manifest-schema.json`; SQLite CHECK violation
  surfaces as rc=5 from the library.
- `destination_path` MUST resolve within `{$VAULT_ROOT/**, ~/.claude/**}`.
  Packets declaring out-of-bounds destinations are rejected with sidecar.
- Resolved `_processing-rules.json` (if present at destination folder)
  validates against `schemas/processing-rules-schema.json`. Malformed rules
  → reject + sidecar; do NOT silently fall back to pillar default.
- Per-write atomic temp+rename. Never partial.

**Failure mode:** block-and-log. Per Session 4 L-55:
- Single-packet failure → sidecar `_reconciler-error.json` next to the
  packet; original packet retained; cron retries on next tick.
- After N retries (default 10) OR `unreconciled_archive_days_default` (14
  days) → packet moves to `~/.claude/state/vault-staging/_archive/`; emits
  `unresolved-reconciliation-conflict` finding to librarian (`governance-
  parity-audit` consumes per Session 4 L-55).
- Tick-level errors (lock contention; staging root missing; rules file
  unreadable) exit non-zero so launchd surfaces the failure.
- **NEW SP14 Batch F T-27 (2026-05-19) — step 8.5 / 8.6 failure handling.**
  If destination write (step 7) succeeded but step 8.5 (daily-processing
  append) OR step 8.6 (manifest record-write) fails, the destination is
  already canonical. Reconciler emits a sidecar
  `<packet-sha>._state-tier-error.json` recording which state-tier step
  failed + the SQLite/JSONL error; the destination write is NOT rolled
  back (canonical source of truth wins per L-103). Operator triages via
  `governance-parity-audit` finding `state-tier-write-drift`. Next-tick
  reconciler runs do NOT retry the failed state-tier writes (they would
  double-record); manifest reconstruction (if needed) is a SP15+ recovery
  capability.

## Why cron, not SessionStart

The reconciler runs while writers continuously emit, not only when the user
starts a session. Cron is the right shape — the tick interval is the implicit
budget throttle, and SessionStart would burst the queue at session boot.

## Limitations and non-goals

- **No classification.** Packets arrive with `destination_path` already
  resolved by the writer. The reconciler does not infer destinations.
- **No routing decisions.** Writers decide where content goes. The
  reconciler resolves rules and applies them mechanically.
- **No semantic merging.** Append / winner-pick / section-merge are the
  only merge strategies. Paraphrase / summarization / cross-packet
  inference are out of scope (R-34 boundary).
- **No retroactive overwrite.** Once a destination is written, the
  reconciler treats it as canonical. Operator edits override; subsequent
  packet writes respect survivorship policy.
- **No multi-vault.** One vault per reconciler invocation. Multi-vault
  setups run separate cron jobs per vault.
- **No direct-write fallback.** Writers configured for `posture: direct`
  bypass this skill entirely. The reconciler only consumes staged packets.
