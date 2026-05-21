---
name: govern register
description: >
  Canonical /govern register skill family. 4 modes (folder / file-type /
  tag-extension / writer) per Plan 81 SP13 alignment Session 3 A31 + Session
  5 A44 (Class D writer mode). Orchestrates the 6-step propose-and-validate
  protocol per canonical §A6 + §A30: CONFIRM INTENT → PROPOSE per-pillar
  rules → USER VALIDATE PER-FIELD (full draft + per-field redline per F3
  lock) → MUTATE OVERLAY-MASTER + APPEND ACTION-LOG (atomic via
  `lib/overlay-master-mutate.sh`) → VAULT-ROOT CLAUDE.md tree self-update
  (Class A folder mode only; no `[F]` marker per T-13 v3.1 template).
  Authored under SP14 Batch H T-10 (2026-05-19).
disable-model-invocation: true
argument-hint: "--kind <folder|file-type|tag-extension|writer> --target <T> [...]"
---

# /govern register

Skill body for the canonical adopter-side governance-mutation entry point.
Both hook-invocation (via additionalContext from `pre-write-guard.sh` branch
#1 detection Classes A/B/C/D) and direct user invocation share a single
code path. Plans-tree creation is ORTHOGONAL — use `/new-plan` or
`/backlog-research`; never `/govern register`.

## Invocation contracts (per A31 + L-72)

```sh
# Class A — new top-level vault folder
/govern register --kind folder --target <vault-relative-path> [--inherit-from <parent-path>]

# Class B/C — new vault-root file or new file-type within existing folder
/govern register --kind file-type --name <type-slug> --contract <path-to-file-type-contract.json>

# Tag-dimension extension (operator-driven; no hook auto-fire)
/govern register --kind tag-extension --dimension <prefix> --values <comma-list>

# Class D — new vault-writer registration (hook auto-fire OR SP07 wizard OR direct)
/govern register --kind writer --writer-name <name> --writer-kind <connector|agentic-flow|auto-research|scheduled-skill|custom> [--writer-subtype <s>] [--writer-skill <skill-slug>] [--from-template <path>]
```

`process.sh` exposes three sub-verbs matching the 6-step protocol's
deliberation/commit/skip arcs:

- `process.sh propose --kind <K> --target <T> [...]` — emit proposal JSON
  to stdout (Claude renders it for the user; user redlines per-field).
- `process.sh commit --kind <K> --proposal <validated.json>` — invoke
  `lib/overlay-master-mutate.sh` to atomically apply mutations + append
  action-log row.
- `process.sh skip --kind <K> --target <T> [--reason <free-text>]` —
  append a frictionless-skip action-log row (`unregistered: true`,
  `proposed_by: skipped`); no overlay mutation.

## Modes

| Mode | Pillars touched (R-37 atomic) | Vault writes | Action-log `kind` |
|---|---|---|---|
| `folder` | `frontmatter.path_routing` + optional `mandatory_files` | vault-root `CLAUDE.md` Vault Structure tree append (Class A only) | `folder` |
| `file-type` | `frontmatter.types` + `file_type_contracts.<type-slug>` | (none) | `file-type` |
| `tag-extension` | `tagging.taxonomy.dimension_prefixes` | (none) | `tag-extension` |
| `writer` | `vault_writers` (no-op `{}` payload for atomic action-log) | `Vault Writers/<slug>.md` writer-reference file | `writer` |

Each mode handler lives at `modes/<kind>.sh` and is sourced by
`process.sh`. Adding a mode = adding a new `modes/<kind>.sh` file + a
case-arm in the dispatcher.

## 6-step protocol mapping

| Step | Where it lives |
|---|---|
| 1. DETECT | `pre-write-guard.sh` branch #1 (Classes A/B/C/D) — UPSTREAM; not part of this skill |
| 2. CONFIRM INTENT | Claude (in conversation) reads hook-supplied `additionalContext` OR user-direct argv, confirms target with operator |
| 3. PROPOSE | `process.sh propose <kind> ...` → `modes/<kind>.sh propose()` — emits draft JSON of per-pillar fields |
| 4. USER VALIDATE PER-FIELD | Claude (in conversation) renders proposal, gathers per-field accept/edit/reject; composes `validated.json` |
| 5. MUTATE + ACTION-LOG | `process.sh commit <kind> <validated.json>` → `modes/<kind>.sh commit()` → `lib/overlay-master-mutate.sh` (atomic; appends row) |
| 6. VAULT-ROOT CLAUDE.md SELF-UPDATE | `modes/folder.sh` only — appends user-cluster entry to vault-root `CLAUDE.md` Vault Structure tree (no `[F]` marker per L-37) — invoked AFTER step 5 commit succeeds |

Frictionless skip (per `feedback_soft_mandate_pattern`): any step,
operator dismisses → `process.sh skip` records `unregistered: true`;
librarian governance-parity-audit surfaces as drift finding.

## Proposal shape (stdout from `process.sh propose`)

All modes emit a single JSON object on stdout:

```jsonc
{
  "kind": "folder | file-type | tag-extension | writer",
  "target": "<path or name>",
  "proposed_by": "claude-skill-invocation | hook-class-a/b/c/d | user-direct",
  "pillars": [
    {
      "pillar": "<top-level pillar slot name>",
      "payload": { /* deep-merge payload — see mode docs */ },
      "field_descriptions": {
        "<field-key>": "human-readable rationale for this field"
      },
      "collisions": [
        {"field": "<field-path>", "foundation_value": "...", "proposed_value": "...", "requires_override_reason": true}
      ]
    }
  ],
  "notes": [ /* freeform strings for user context */ ]
}
```

Claude renders this proposal to the operator, gathers per-field
edits/rejects, and composes a `validated.json` of the SAME shape with:
- Accepted pillar payloads carried through verbatim
- Rejected fields removed from `payload` + listed under top-level
  `rejected_fields: {pillar: {field: reason}}`
- Override reasons captured per-entry as `_override_reason: "<text>"`
  fields inline on each shadowing payload entry (ADR-0006 canonical
  shape; per SP17a T-5 Decision Point #1, 2026-05-21). The retired
  top-level `override_reasons.<pillar>.<field>` dict pathway is no
  longer accepted by the hook-side R-52 check.

The validated.json is then passed to `process.sh commit`.

## Per-mode proposal payloads

### `folder` mode

```jsonc
{
  "kind": "folder",
  "target": "Engagements",
  "pillars": [
    {
      "pillar": "frontmatter",
      "payload": {
        "path_routing": [
          {"pattern": "Engagements/**", "type": "engagement-note", "auto_create": true}
        ]
      }
    },
    {
      "pillar": "mandatory_files",
      "payload": {
        "by_folder": {
          "Engagements/**": ["_index.md"]
        }
      }
    }
  ]
}
```

R-37 atomic: both pillars apply in a single `lib/overlay-master-mutate.sh`
invocation (two `--pillar/--payload-file` pairs).

### `file-type` mode

```jsonc
{
  "kind": "file-type",
  "target": "engagement-note",
  "pillars": [
    {
      "pillar": "frontmatter",
      "payload": {
        "types": ["engagement-note"]
      }
    },
    {
      "pillar": "file_type_contracts",
      "payload": {
        "engagement-note": {
          "$schema": "schemas/file-type-contract-schema.json",
          "type": "engagement-note",
          "frontmatter": { "required": ["type", "tags", "created", "updated"], "enums": {"type": ["engagement-note"]} },
          "body": { "free_form": true }
        }
      }
    }
  ]
}
```

R-37 atomic across the two pillars.

### `tag-extension` mode

```jsonc
{
  "kind": "tag-extension",
  "target": "delivery",
  "pillars": [
    {
      "pillar": "tagging",
      "payload": {
        "taxonomy": {
          "dimension_prefixes": {
            "delivery": ["spec", "build", "ship", "retro"]
          }
        }
      }
    }
  ]
}
```

Single-pillar mutation.

### `writer` mode

Writer mode is structurally distinct — the canonical declaration is a
markdown file at `Vault Writers/<slug>.md` (writer-reference file per
Session 5 L-58), not an overlay-master entry. The library is still
invoked (with a no-op `{}` vault_writers payload) so the action-log row
appends atomically under the same lockf serialization the other modes
use.

```jsonc
{
  "kind": "writer",
  "target": "granola-meetings",
  "pillars": [
    {
      "pillar": "vault_writers",
      "payload": {}
    }
  ],
  "writer_reference": {
    "destination": "<vault-root>/Vault Writers/granola-meetings.md",
    "frontmatter": {
      "type": "vault-writer",
      "writer_name": "granola-meetings",
      "writer_kind": "connector",
      "writer_subtype": "granola",
      "writer_skill": "meeting-note-ingestor-granola",
      "destinations": [
        {"path": "Meetings/{{date}} - {{title}}.md", "output_type": "markdown", "posture": "direct"}
      ],
      "status": "active",
      "source": "granola-workspace-id",
      "schedule": "manual",
      "created": "<ISO>",
      "updated": "<ISO>",
      "tags": ["#scope/writer", "#status/active"]
    },
    "body_template": "_generic-writer.md.template"
  }
}
```

The writer-reference file write goes through the standard write path
(tempfile + mv); `pre-write-guard.sh` branch #3 validates the resulting
frontmatter against `governance/file-type-contracts/vault-writer.md.json`
on write — schema-violation surfaces as DENY at hook time (the skill
trusts pre-write enforcement and does NOT re-validate downstream).

## Coordination locks

- **Hook entry (Class A/B/C):** `pre-write-guard.sh` branch #1 surfaces
  `additionalContext` proposing `/govern register --kind <X> --target <Y>`.
  Action-log `proposed_by` records `hook-class-a/b/c`.
- **Hook entry (Class D):** `pre-write-guard.sh` branch #1 (integrated
  into existing SKILL CHANGE PROTOCOL block) surfaces propose-and-validate
  on a vault-writing SKILL.md edit with no matching writer-reference.
  Action-log `proposed_by: hook-class-d`.
- **SP07 wizard entry:** SP07 Beat 5 emits writer-reference files via
  the SAME 4-mode skill body. Action-log `proposed_by: sp07-wizard`.
- **Direct invocation:** Operator runs `/govern register --kind <X>`
  outside any hook trigger. Action-log `proposed_by: user-direct`.

## Output Contract

**Files written (by mode):**

| Mode | Files written | Schema validated against |
|---|---|---|
| `folder` | `~/.claude/governance/overlay-master.json` (atomic via library) + `~/.claude/governance/governance-action-log.jsonl` (append) + `<vault-root>/CLAUDE.md` (Class A tree append; no `[F]` marker) | `schemas/overlay-master-schema.json` + `schemas/governance-action-log-schema.json` |
| `file-type` | overlay-master.json + governance-action-log.jsonl | same as folder mode |
| `tag-extension` | overlay-master.json + governance-action-log.jsonl | same as folder mode |
| `writer` | `<vault-root>/Vault Writers/<slug>.md` (writer-reference file; standard atomic write through pre-write-guard.sh + post-write-verify.sh) + overlay-master.json no-op + governance-action-log.jsonl | `governance/file-type-contracts/vault-writer.md.json` (enforced at pre-write-guard.sh branch #3 downstream) + governance-action-log-schema.json |

**Skip-path file writes (all modes):** one row to
`~/.claude/governance/governance-action-log.jsonl` with `unregistered: true`,
`proposed_by: skipped`, `target: <T>`. No overlay-master mutation. No vault
writes. Original triggering write proceeds (frictionless skip per
`feedback_soft_mandate_pattern`).

**Pre-write validation:**
- `process.sh commit` REQUIRES `--proposal <validated.json>` with the
  shape documented above; rejects (rc=2) if missing or malformed.
- Mode handlers compose pillar payloads from the proposal and write each
  to a tempfile under `$TMPDIR`; payloads are validated as parseable JSON
  before invoking the library.
- `lib/overlay-master-mutate.sh` performs (a) jsonschema Draft 2020-12
  validation against `schemas/overlay-master-schema.json` on the
  composed tempfile, (b) `lockf -k -t 0` serialization under
  `~/.claude/governance/.overlay-master.lock`, (c) atomic rename, and
  (d) action-log row append — all under the same lock.
- Writer mode additionally relies on `pre-write-guard.sh` branch #3 to
  validate the writer-reference frontmatter against
  `governance/file-type-contracts/vault-writer.md.json` at write time.
  Schema violation surfaces as DENY at hook time.
- R-37 multi-pillar bundling: file-type and folder modes invoke the
  library with two `--pillar/--payload-file` pairs in a single call;
  either both apply or neither does.
- R-52 collision tiebreaker: `process.sh propose` flags collisions
  against `~/.claude/governance/foundation-master.json` in the proposal
  output; commit phase rejects (rc=4) any shadowing payload entry that
  lacks an inline `_override_reason: "<text>"` field (ADR-0006 canonical
  shape; per-entry only since SP17a T-5).

**Failure mode:** block-and-log per `feedback_no_skill_code_generation`
(failure-mode discipline) + `feedback_structural_over_bandaid`:

- Library `rc=2` (bad argv) / `rc=3` (pre-flight failure) / `rc=4`
  (schema validation failure) / `rc=5` (lock contention) / `rc=6`
  (atomic rename or action-log append failure) — surfaced verbatim by
  `process.sh commit`. No silent fallback. No retry loop.
- Writer-reference write failure (pre-write-guard.sh DENY) — surfaced
  by the standard write path; the skill does NOT retry; the operator
  must address the schema violation and re-invoke.
- Vault-root CLAUDE.md self-update failure (folder mode Class A step
  6) — emitted as a sidecar `_claude-md-tree-update-failed.json` next to
  vault-root CLAUDE.md; the overlay mutation (step 5) is NOT rolled
  back (canonical; survives). Librarian governance-parity-audit
  surfaces `vault-claude-md-tree-drift` finding for operator triage.

## Constraints

- All overlay-master mutations flow through `lib/overlay-master-mutate.sh`
  per `feedback_no_skill_code_generation` (single mutation library;
  schema-drift prevention). No mode handler writes `overlay-master.json`
  or `governance-action-log.jsonl` directly. No mode handler hand-composes
  action-log row JSON.
- Bash 3.2 compatible per existing skill substrate (no `declare -A`, no
  `mapfile`, no `${var,,}`).
- Foundation-repo-only authoring per `feedback_no_live_edits_during_foundation_repo_build`.
  Live `~/.claude/` install scaffolding ships via SP15.
- Plans-tree governance is ORTHOGONAL — `/govern register` declines
  `--kind plan` (use `/new-plan` or `/backlog-research`).

## See also

- `lib/overlay-master-mutate.sh` (atomic mutation library — SP14 Batch B T-8)
- `schemas/overlay-master-schema.json` (overlay pillar shape — SP14 Batch A)
- `schemas/governance-action-log-schema.json` (action-log row shape — SP14 Batch A)
- `governance/file-type-contracts/vault-writer.md.json` (writer-reference contract — SP13 T-12)
- `~/.claude-plans/81-claude-stem-dogfood-optimization/13-post-onboarding-governance-architecture/alignment/semantic-extension-flow.md` (Session 3 + 4 + 5 lock chain — A31 + Class D)
- `~/.claude-plans/81-claude-stem-dogfood-optimization/foundation-governance-target-state.md` §A6 / §A30 / §A31 / §A32 (6-step protocol canonical)
