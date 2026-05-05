---
name: adopt
description: Vault adoption skill. Two modes — (1) fresh-vault scaffolding from $CLAUDE_HOME/user-manifest.json (5 directories, seeded CLAUDE.md, empty System Backlog.md, canonical_file_types skeleton), (2) retrofit-existing for populated vaults (delegates to retrofit.sh — walks vault as IR source, renders collision matrix, runs Stage 2/3 against truly-new candidates with provenance idempotency). Refuses if vault.is_fresh != true (in fresh mode) or foundation install state is user-only without --force-install. Idempotent in both modes.
disable-model-invocation: false
argument-hint: "[--force-install] [--dry-run] [--verbose] [--retrofit-existing [<path>] [--retrofit-cap N] [--retrofit-keep-threshold F] [--seed-batch-cap N]]"
---

# /adopt — Fresh-Vault MVP

User-facing entry for `/adopt`. Wraps `skills/adopt/adopt.sh` (deterministic
bash scaffolding) in a slash-command surface. Runs AFTER `/onboard`
(SP07) has populated `$CLAUDE_HOME/user-manifest.json` and the user has chosen
to bring up a fresh vault. Hands the user a vault skeleton ready for daily
capture — Inbox, Logs, System Backlog, CLAUDE.md, Plans symlink — in <2 min on
the Alex archetype fixture.

## Invocation

| Command | Behavior |
|---------|----------|
| `/adopt` | Default: scaffold the fresh-vault skeleton at `$CLAUDE_HOME/user-manifest.json:vault.root` |
| `/adopt --dry-run` | Fresh-vault: print scaffolding plan to stdout; zero filesystem mutations. With `--retrofit-existing`: render collision matrix to stdout; skip gate + Stage 3. |
| `/adopt --force-install` | Bypass user-only state refusal (foundation install incomplete or absent) |
| `/adopt --retrofit-existing [<path>]` | **Retrofit mode (SP13 T-13, v2.1).** Delegates to `retrofit.sh`. Walks the existing vault (or `<path>` sub-tree) as IR source; augments import plan with collision matrix appendix; runs Stage 2/3 against truly-new candidates only. Idempotent via `generated_by: retrofit@v2.1.0` provenance. |
| `/adopt --retrofit-existing --retrofit-cap N` | Refuse retrofit if walked corpus exceeds N records (default 500). Forces sub-tree scoping on large vaults. |
| `/adopt --retrofit-existing --retrofit-keep-threshold F` | Modal-parent-dir ratio above which reference/meeting candidates are `keep` rather than `move-to` (default 0.8). |
| `/adopt --verbose` | Verbose progress output (info-level diagnostics to stdout) |
| `/adopt --version` | Print scaffolding-script version and exit |

`SessionStart` triggers `/adopt` automatically when SP07's `/onboard` completes
Section E AND `vault.is_fresh == true` AND `paths.vault_root` (or `vault.root`)
is set AND the directory does not yet exist as a populated vault. The
`/onboard` skill hands off explicitly per its Section E close-out.

## Prerequisites

Per spec §`/adopt` prerequisites (audit F-13):

1. `/onboard` (SP07) must have run to completion (or to Section A
   minimum) and populated `$CLAUDE_HOME/user-manifest.json` with at least
   `identity.name`, `vault.root`, and `vault.is_fresh = true`.
2. `install.sh` (SP08 T-1) must have completed cleanly — `$CLAUDE_HOME/foundation-manifest.json`
   present is the proxy for foundation install state. If absent, `/adopt`
   refuses with exit 21 unless `--force-install` is passed.
3. `$PLANS_HOME` must be resolvable — defaults to `$HOME/.claude-plans` if the
   env var is unset. The directory is created idempotently if absent.
4. `jq` must be on `$PATH` (foundation install dependency, baseline-checked at
   install time).

## Fresh-Vault Flow

Per spec §`/adopt` fresh-vault flow (MVP), the scaffolding script executes:

1. **Refusal gate.** Read `$CLAUDE_HOME/user-manifest.json`. If `vault.is_fresh`
   is not literal `true`, exit 20 with the deferral pointer.
2. **State gate.** If `$CLAUDE_HOME/foundation-manifest.json` is absent
   (state user-only proxy), refuse with exit 21 unless `--force-install`.
3. **Retrofit gate.** If `--retrofit-existing` is passed, refuse with exit 22
   and emit the v2.1 deferral message + manual-copy workaround.
4. **Path resolution.** Resolve `vault.root` (expand leading `~/` via bash 3.2
   safe substring slice — NOT `${var#~/}` which matches against expanded `~`).
   Resolve `$PLANS_HOME` via env or `$HOME/.claude-plans` fallback.
5. **Directory scaffold.** `mkdir -p` (idempotent) for:
   - `<vault_root>/Inbox/`
   - `<vault_root>/Logs/`
   - `<vault_root>/Logs/backlog-progress/`
   - `<vault_root>/.coordination/`
   - `<vault_root>/Plans` symlinked via `ln -sfn` to `$PLANS_HOME`
6. **CLAUDE.md seed.** If `<vault_root>/CLAUDE.md` does not exist, render
   `~/Code/claude-stem/templates/vault-claude-md-template.md` (or the
   runtime-installed copy at `$CLAUDE_HOME/templates/...`) with substitution of:
   - `{{IDENTITY_NAME}}` ← `identity.name`
   - `{{IDENTITY_ROLE}}` ← `identity.role`
   - `{{IDENTITY_ORGANIZATION}}` ← `identity.organization`
   - `{{IDENTITY_INDUSTRY}}` ← `identity.industry`
   - `{{VAULT_ORGANIZATIONAL_METHOD}}` ← `vault.organizational_method`
   - `{{VAULT_TOP_LEVEL_FOLDER}}` ← `vault.top_level_folder` (default `Engagements`)
   - `{{VAULT_DEFAULT_AUDIENCE}}` ← `vault.default_audience`

   Empty manifest fields fall back to generic placeholders (`(unset)`) — not
   Peter-specific values — to preserve the reference-leak floor.

   Atomic `tmp + rename`. Post-write validation greps for `{{[A-Z_]+}}` —
   any remaining placeholder triggers exit 50 (block-and-log).
7. **System Backlog.md seed.** Empty index file with `type: index` frontmatter
   and `## Active` / `## Archived` H2 sections (atomic write, idempotent).
8. **canonical-file-types skeleton.** Write `<vault_root>/.coordination/canonical-file-types.json`
   stub `{"schema_version": "skeleton-1.0.0", "phase": "MVP", "file_types": []}`.
   Phase 2 in v2.1 will populate from the archetype heuristic.
9. **Manifest update.** If `user-manifest.json:vault.canonical_file_types` is
   `null`, initialize to `[]` via jq + atomic tmp+rename. If already populated
   by SP07 archetype heuristic, preserve.
10. **Summary emit.** Print scaffolding summary + next-steps pointer to stdout.

Idempotency: every step is `mkdir -p` / `ln -sfn` / `cp -n` / `[ ! -f ]` guarded.
Re-running `/adopt` on an already-scaffolded vault is a no-op modulo post-write
validation re-running. Round-trip time on Alex archetype fixture: <2 min (in
practice ~1–3 seconds — the <2 min ceiling is for slow filesystems).

## Output Contract

Per CLAUDE.md skill-creation rules: every vault-writing skill declares files
written, schema type, pre-write validation steps, and failure mode.

### Files written

| Path | Schema type | Cardinality | Lifecycle |
|---|---|---|---|
| `<vault_root>/CLAUDE.md` | Substituted instance of `~/Code/claude-stem/templates/vault-claude-md-template.md`; identity placeholders all replaced | Single | Seeded once on first `/adopt`; preserved on re-run |
| `<vault_root>/System Backlog.md` | Markdown index with `type: index` frontmatter (validated against `vault-schema.json` `index` type) | Single | Seeded once; preserved on re-run; populated by `/backlog-triage` over time |
| `<vault_root>/.coordination/canonical-file-types.json` | Skeleton JSON `{schema_version, phase, file_types[]}`; validates against future v2.1 vault-canonical-file-types-schema (deferred) | Single | Seeded once as MVP stub; v2.1 populates |
| `<vault_root>/Inbox/` | Directory only | Single | Capture surface; populated by daily reconcile |
| `<vault_root>/Logs/` | Directory only | Single | Append-only log surface |
| `<vault_root>/Logs/backlog-progress/` | Directory only | Single | Per-backlog-item satellite logs (R-29/R-30/R-31) |
| `<vault_root>/.coordination/` | Directory only | Single | Multi-session shared state (Plan 42 R-42) |
| `<vault_root>/Plans` | Symlink to `$PLANS_HOME` | Single | Read-only navigation surface |
| `$CLAUDE_HOME/user-manifest.json` | In-place update of `vault.canonical_file_types` field (null → `[]`); validates against `~/Code/claude-stem/schemas/user-manifest-schema.json` v1.5.0 | Single existing | Atomic update via jq + tmp+rename; preserved if already populated |

### Pre-write validation

For every vault scaffolding write, in order:

1. **CLAUDE_HOME presence** — exit 10 if `$CLAUDE_HOME` is unset, empty, or
   does not resolve to an existing directory.
2. **user-manifest.json validity** — exit 10 if missing or `jq -e .` fails.
3. **vault.is_fresh assertion** — exit 20 if `.vault.is_fresh` is not literal
   `true`. Strict comparison; null/false/missing all refuse.
4. **State classification** — exit 21 if `$CLAUDE_HOME/foundation-manifest.json`
   absent and `--force-install` not passed (state user-only proxy).
5. **Retrofit gate** — exit 22 if `--retrofit-existing` passed (v2.1 deferral).
6. **vault.root non-empty** — exit 30 if `.vault.root` is empty or null.
7. **Template locatable** — exit 40 if `vault-claude-md-template.md` not found
   in either `$CLAUDE_HOME/templates/` (runtime) or
   `$SCRIPT_DIR/../../templates/` (foundation-repo source).
8. **Atomic tmp+rename** — every file write goes through `<target>.adopt.tmp.$$`
   then `mv`. Failure to rename → exit 40 with diagnostic.
9. **Post-write placeholder scan** — `grep -E '{{[A-Z_]+}}' CLAUDE.md` after
   render-and-write; any match → exit 50.

Validation against `vault-schema.json` for the seeded `System Backlog.md`
frontmatter (`type: index`) is a v2.1 enhancement — MVP relies on the template
being correct-by-construction. The schema is shipped at
`$CLAUDE_HOME/schemas/vault-schema.json` (post-install) for future pre-write
validators.

### Failure mode

**block-and-log** — never "write and hope". On any validation, parse, or IO
failure:

1. Roll back any `*.adopt.tmp.$$` files in the current run (atomic semantics —
   live targets remain untouched).
2. Emit a structured diagnostic to stderr: failed step, expected condition,
   actual condition, remediation hint.
3. Exit non-zero with the per-class exit code (10 / 20 / 21 / 22 / 30 / 40 / 50)
   — never exit 1 for a known failure class.
4. Idempotency contract: failed `/adopt` runs leave the vault in either the
   pre-run state OR a partially-scaffolded state where every individual file
   is well-formed (post-tmp+rename). Re-running `/adopt` after a transient
   failure is safe.

The user sees the exit code + diagnostic and chooses whether to re-run
`/adopt` (typical case after a transient mkdir/jq failure) or address the
failure manually (re-run `/onboard --section a` to fix `vault.root`, etc.).

## Retrofit-Existing Flow (SP13 T-13, v2.1)

When `--retrofit-existing` is passed, `adopt.sh` delegates (via `exec`) to
`skills/adopt/retrofit.sh`. The fresh-vault flow above does NOT fire. Retrofit
is a separate orchestrator that:

1. **Resolves vault root + optional sub-tree.** Reads
   `$CLAUDE_HOME/user-manifest.json:vault.root` and (when supplied) the
   positional `<path>` argument. Sub-tree must be under vault root.
2. **Walks vault tree** for known text formats (.md / .txt / .markdown /
   .vtt) honoring `<vault>/.seedignore` if present.
3. **Idempotency filter:** files whose first 20 lines contain
   `^generated_by: retrofit@` are skipped (already retrofitted in a prior
   run). Surfaced in the matrix as `idempotency-skip` rows.
4. **Cap check** (default 500 records). Refuses with guidance if exceeded —
   forces sub-tree scoping on large vaults rather than producing an
   unwieldy matrix.
5. **Stage 1 IR build** (T-3 `ir-builder.sh` unmodified).
6. **Stage 2** (T-4 `cluster.sh` + T-5 `propose-taxonomy.sh` unmodified).
7. **Retrofit prefilter** (`retrofit-prefilter.py` — T-13 layer):
   - Drops type=project candidates whose `proposed_path` is already
     scaffolded (folder exists with PRD.md / Context.md / Updates.md).
     Stage 3 will not re-scaffold these.
   - Annotates each candidate with a retrofit-action enum
     (`scaffold` / `keep` / `move-to` / `inbox` / `review`).
   - Applies the keep-heuristic: reference/meeting candidates whose
     source items already cluster under a coherent existing parent
     (≥ keep-threshold ratio; default 0.8) are marked `keep` rather
     than `move-to`. **Default-keep posture protects user-organized
     vault structure from LLM-proposed reorganization.**
8. **T-6 import-plan.sh** (unmodified) renders the import plan from the
   filtered taxonomy.
9. **Collision matrix appendix** (`retrofit-collision-matrix.sh` — T-13
   layer): appends `## Collision matrix — N existing files` H2 to
   `import-plan.md`. Paginated at 50 rows when total > 50. Schema_version
   anchor `sp13-t6/1` preserved (additive append).
10. **Dry-run path** (`--dry-run`): cat augmented plan to stdout; SKIP
    Stage 2.5, T-7 gate, and Stage 3 entirely. No vault writes.
11. **SP15 Stage 2.5 consultation** when present at
    `skills/infer-vault-structure/stage-2-5-consultation.sh`. Gracefully
    falls through if absent.
12. **T-7 review-gate.sh** (unmodified) — user reviews the augmented plan
    + collision matrix, takes [a]pply / [e]dit / [s]kip / [b]ort.
13. **Stage 3** (T-8 `seed.sh` + transitively T-10 `inbox-disposition.sh`,
    both unmodified) on apply. Filtered taxonomy ensures only truly-new
    candidates scaffold.

### Retrofit safety guarantees

- **Existing user files are never overwritten** outside the SP12 3-step
  gate's preview/diff cycle. Already-scaffolded folders are dropped from
  the plan; the matrix surfaces them as `keep` rows (advisory).
- **`move-to` and `merge-into` are advisory only.** Spec §`Stage 3`
  retrofit defers full auto-merge to v2.x. The matrix surfaces moves
  for user manual action; Stage 3 only scaffolds NEW project folders.
- **Idempotency is structural.** Re-running `/adopt --retrofit-existing`
  on a partially-retrofitted vault skips files marked
  `generated_by: retrofit@*` at intake — they don't even reach Stage 1.
- **`.seedignore` honored.** Same filter as fresh-seed onboarding.
- **Cap refusal preserves UX.** Default 500 — forces sub-tree scoping
  on multi-thousand-file vaults rather than producing an unwieldy matrix.

### Action enum surfaced in the collision matrix

| Action | Trigger | Stage 3 effect |
|---|---|---|
| `scaffold` | type=project, proposed_path NOT already-scaffolded | seed.sh creates new folder + PRD/Context/Updates triad |
| `keep` | type=project already-scaffolded; OR reference/meeting where ≥80% of source items share a parent dir | NO-OP (advisory) |
| `move-to` | reference/meeting where source items scatter | Advisory; user must move manually post-gate |
| `inbox` | type=unclassified | inbox-disposition.sh routes to `<vault>/Inbox/` |
| `review` | low_confidence (<0.5) OR unknown type | Advisory; user must triage at the gate |
| `idempotency-skip` | file already carries `generated_by: retrofit@*` | Not walked at all |

## Hard Rules

1. **Retrofit ships in v2.1 (SP13 T-13).** `--retrofit-existing`
   delegates to `retrofit.sh` which preserves the conservative-scope
   contract: only NEW project folders are auto-scaffolded; moves and
   merges are advisory in the matrix. Fresh-vault behavior is unchanged.
2. **Idempotent on re-run.** Every directory create is `mkdir -p`. Every
   symlink is `ln -sfn`. Every file seed is `[ ! -f ]` guarded. Re-running
   `/adopt` on a populated vault must NOT overwrite any user content. The
   only re-run mutation is the post-write placeholder scan, which is
   read-only.
3. **No live `~/.claude/` mutations from this script.** This skill targets
   `<vault_root>` (an Obsidian vault directory) and `$CLAUDE_HOME/user-manifest.json`.
   It does NOT modify hooks, skills, schemas, or any foundation-tracked file
   under `$CLAUDE_HOME` outside the documented manifest update.
4. **Reference-leak floor.** Empty manifest fields fall back to generic
   placeholders (`(unset)`) — not Peter-specific values — to ensure the
   seeded vault CLAUDE.md is portable. Identity values from the manifest
   are user-provided strings; sed-escape them for shell safety, but do
   NOT scrub or transform them.
5. **Bash 3.2 compatible.** No `declare -A`, no `mapfile`, no `${var,,}`.
   No `${var#~/}` (matches against expanded `~`) — use `${var:0:2}` test +
   `${var:2}` slice. No `${var:-{}}` (3.2 mishandles literal `{}` argv) —
   use empty-default-then-set pattern. Avoid UTF-8 multi-byte glyphs adjacent
   to `$VAR` references under `set -u`.
6. **Output Contract is non-negotiable.** Block-and-log failure mode applies
   to every file write. The scaffolding script's exit-code matrix is the
   audit surface; never strip diagnostic output to stderr.

## Related Skills

- `/onboard` (SP07) — produces `user-manifest.json`; runs BEFORE `/adopt`
- `/onboard --section a` — re-record Section A (vault root, identity) if user
  needs to fix manifest before re-running `/adopt`
- `/backlog-triage` — first user of the seeded `System Backlog.md`
- `/new-plan` — first user of the seeded `Plans/` symlink surface
- `librarian` — ongoing hygiene over the seeded vault structure (R-29/R-30/R-31)
- `/adopt --retrofit-existing` (SP13 T-13, v2.1) — collision matrix flow via `retrofit.sh`

## Cross-Plan References

| Reference | Source |
|---|---|
| Spec §`/adopt` fresh-vault flow (MVP) | `~/.claude-plans/71-claude-foundations-engine-v2/08-distribution-installer-adopt/spec.md` L109-114 |
| Spec §`/adopt` prerequisites (F-13) | spec.md L303-305 |
| Spec §T-6 path rebase (Cross-cutting A9) | spec.md L314-316 |
| T-6 acceptance criteria (7 ACs) | tasks.md L196-203 |
| user-manifest-schema (1.5.0) | `~/Code/claude-stem/schemas/user-manifest-schema.json` |
| vault-schema (1.0.0) | `~/Code/claude-stem/schemas/vault-schema.json` |
| Template | `~/Code/claude-stem/templates/vault-claude-md-template.md` |
| Scaffolding script | `~/Code/claude-stem/skills/adopt/adopt.sh` |
| Retrofit orchestrator | `~/Code/claude-stem/skills/adopt/retrofit.sh` |
| Retrofit prefilter | `~/Code/claude-stem/skills/adopt/retrofit-prefilter.py` |
| Retrofit matrix renderer | `~/Code/claude-stem/skills/adopt/retrofit-collision-matrix.{sh,py}` |
| Test harness (fresh-vault) | `~/Code/claude-stem/tests/sp08/adopt-unit-test.sh` |
| Test harness (retrofit) | `~/Code/claude-stem/tests/sp13/sp13-retrofit-existing-test.sh` |
| R-37 single-deliverable rationale | CLAUDE.md (Plan 71 working agreement) |
| R-55 live-mutation containment | CLAUDE.md (foundation-repo target enforced) |
