---
name: adopt
description: Scaffolds an Obsidian-compatible vault from the user manifest. Two modes — fresh-vault (creates Inbox/Logs/Plans/.coordination plus a personalized CLAUDE.md and System Backlog index) and retrofit-existing (walks an existing populated vault, renders a collision matrix, scaffolds only truly-new project candidates). Idempotent in both modes.
disable-model-invocation: false
argument-hint: "[--force-install] [--dry-run] [--verbose] [--retrofit-existing [<path>] [--retrofit-cap N] [--retrofit-keep-threshold F] [--seed-batch-cap N]]"
---

# /adopt

User-facing entry for `/adopt`. Wraps `skills/adopt/adopt.sh` (fresh-vault scaffolding) and `skills/adopt/retrofit.sh` (existing-vault retrofit) in a single slash-command surface.

`/adopt` runs after `/onboard` has populated `$CLAUDE_HOME/user-manifest.json`. Round-trip on a fresh archetype takes seconds (the spec ceiling is two minutes for slow filesystems).

## Invocation

| Command | Behavior |
|---|---|
| `/adopt` | Default fresh-vault scaffold at `vault.root`. |
| `/adopt --dry-run` | Fresh-vault: print scaffolding plan to stdout; zero filesystem changes. With `--retrofit-existing`: render the collision matrix; skip the gate and Stage 3. |
| `/adopt --force-install` | Bypass the user-only-state refusal (no foundation install detected). |
| `/adopt --retrofit-existing [<path>]` | Retrofit mode. Walks the existing vault (or `<path>` sub-tree), renders an import plan with a collision-matrix appendix, and scaffolds only truly-new candidates. |
| `/adopt --retrofit-existing --retrofit-cap N` | Refuse retrofit if the walked corpus exceeds N records (default 500). |
| `/adopt --retrofit-existing --retrofit-keep-threshold F` | Modal-parent-dir ratio above which reference / meeting candidates are `keep` rather than `move-to` (default 0.8). |
| `/adopt --verbose` | Info-level diagnostics on stdout. |
| `/adopt --version` | Print scaffolding-script version and exit. |

`SessionStart` triggers `/adopt` automatically when `/onboard` has completed Section E AND `vault.is_fresh == true` AND `paths.vault_root` is set AND the directory does not yet exist as a populated vault.

## Prerequisites

1. **Manifest present.** `$CLAUDE_HOME/user-manifest.json` exists and contains at least `identity.name`, `vault.root`, and `vault.is_fresh = true`.
2. **Foundation install evidence.** `$CLAUDE_HOME/governance/foundation-manifest.json` exists (SP18 T-3 relocated from `$CLAUDE_HOME` root). If absent, `/adopt` refuses with exit 21 unless `--force-install` is passed.
3. **`$PLANS_HOME` resolvable.** Defaults to `$HOME/.claude-plans` if the env var is unset. Created idempotently if absent.
4. **`jq` on `$PATH`.** A foundation-install dependency.

## Fresh-vault flow

1. **Refusal gate.** Read the manifest. `vault.is_fresh != true` → exit 20. Strict comparison; null / false / missing all refuse.
2. **State gate.** No `governance/foundation-manifest.json` → exit 21 unless `--force-install`.
3. **Retrofit gate.** `--retrofit-existing` → exit 22 with the deferral message and manual-copy workaround.
4. **Path resolution.** Expand `~/` in `vault.root`. Resolve `$PLANS_HOME` via env or `$HOME/.claude-plans` fallback.
5. **Directory scaffold** (`mkdir -p`, idempotent):
   - `<vault_root>/Inbox/`
   - `<vault_root>/Logs/`
   - `<vault_root>/Logs/backlog-progress/`
   - `<vault_root>/.coordination/`
   - `<vault_root>/Plans` symlinked via `ln -sfn` to `$PLANS_HOME`.
6. **`CLAUDE.md` seed.** If `<vault_root>/CLAUDE.md` does not exist, render `templates/vault-claude-md-template.md` with substitution from the manifest:

   | Token | Manifest field | Default fallback |
   |---|---|---|
   | `{{IDENTITY_NAME}}` | `identity.name` | `(unset)` |
   | `{{IDENTITY_ROLE}}` | `identity.role` | `(unset)` |
   | `{{IDENTITY_ORGANIZATION}}` | `identity.organization` | `(unset)` |
   | `{{IDENTITY_INDUSTRY}}` | `identity.industry` | `(unset)` |
   | `{{VAULT_ORGANIZATIONAL_METHOD}}` | `vault.organizational_method` | `(unset)` |
   | `{{VAULT_TOP_LEVEL_FOLDER}}` | `vault.top_level_folder` | `Engagements` |
   | `{{VAULT_DEFAULT_AUDIENCE}}` | `vault.default_audience` | `(unset)` |
   | `{{VAULT_ARCHITECTURE_DOC}}` | `vault.architecture_doc` | `(unset)` |

   Empty manifest fields render as the literal `(unset)` so the seed `CLAUDE.md` stays portable across users — no operator-specific defaults leak.

   Atomic `tmp + rename`. Post-write validation greps for `{{[A-Z_]+}}`; any remaining placeholder triggers exit 50.

7. **`System Backlog.md` seed.** Empty index file with `type: index` frontmatter and `## Active` / `## Archived` H2 sections.
8. **`canonical-file-types.json` skeleton.** Stub at `<vault_root>/.coordination/`:

   ```json
   {"schema_version": "skeleton-1.0.0", "phase": "MVP", "file_types": []}
   ```

9. **Manifest update.** `vault.canonical_file_types` was `null` → initialized to `[]` via jq + atomic tmp+rename. If non-null, preserve.
10. **Summary emit.** Print the scaffolding summary plus next-steps to stdout.

After step 10, `<vault_root>/` contains:

```
Inbox/
Logs/
  backlog-progress/
.coordination/
  canonical-file-types.json
Plans -> ~/.claude-plans/
CLAUDE.md           ← personalized with your identity
System Backlog.md   ← empty index, ready for backlog rows
```

Open the vault in Obsidian or any editor. The `CLAUDE.md` carries identity-substituted instructions; `System Backlog.md` is the entry point for system-project tracking.

## Retrofit-existing flow

When `--retrofit-existing` is passed, `adopt.sh` execs into `retrofit.sh`. The fresh-vault flow does not fire.

1. **Resolve vault root and optional sub-tree.** Sub-tree must be under vault root.
2. **Walk vault tree** for known text formats (`.md`, `.txt`, `.markdown`, `.vtt`), honoring `<vault>/.seedignore` if present.
3. **Idempotency filter.** Files whose first 20 lines contain `^generated_by: retrofit@` are skipped. They surface in the matrix as `idempotency-skip` rows.
4. **Cap check.** Default 500. Exceeding the cap refuses with guidance — forces sub-tree scoping rather than producing an unwieldy matrix.
5. **Stage 1 IR build** (uses `infer-vault-structure/ir-builder.sh` unmodified).
6. **Stage 2: cluster + propose taxonomy** (uses `infer-vault-structure/cluster.sh` and `propose-taxonomy.sh` unmodified).
7. **Retrofit prefilter** (`retrofit-prefilter.py`):
   - Drops project candidates whose `proposed_path` is already scaffolded (folder exists with `PRD.md` / `Context.md` / `Updates.md`). Stage 3 does not re-scaffold these.
   - Annotates each candidate with a retrofit-action enum (`scaffold`, `keep`, `move-to`, `inbox`, `review`).
   - Applies the keep-heuristic: reference / meeting candidates whose source items already cluster under a coherent existing parent (≥ keep-threshold ratio; default 0.8) are marked `keep` rather than `move-to`. **Default-keep posture protects user-organized vault structure from LLM-proposed reorganization.**
8. **Render the import plan** via `import-plan.sh` (unmodified).
9. **Append the collision matrix** to `import-plan.md` as a `## Collision matrix — N existing files` H2. Paginated at 50 rows when total > 50.
10. **Dry-run path.** Cat the augmented plan to stdout; skip the gate and Stage 3 entirely.
11. **Stage 2.5 consultation** when present at `skills/infer-vault-structure/stage-2-5-consultation.sh`. Falls through gracefully if absent.
12. **Review gate.** You review the augmented plan plus the collision matrix and choose `[a]pply / [e]dit / [s]kip / [b]ort`.
13. **Stage 3 on apply.** `seed-projects/seed.sh` plus `seed-projects/inbox-disposition.sh` run on the filtered taxonomy. Only truly-new candidates scaffold.

### Action enum surfaced in the collision matrix

| Action | Trigger | Stage 3 effect |
|---|---|---|
| `scaffold` | type=project, `proposed_path` not already-scaffolded | `seed.sh` creates a new folder and the PRD/Context/Updates triad. |
| `keep` | type=project already-scaffolded; OR reference/meeting where ≥80% of source items share a parent dir | No-op (advisory). |
| `move-to` | reference/meeting where source items scatter | Advisory; you move manually post-gate. |
| `inbox` | type=unclassified | `inbox-disposition.sh` routes to `<vault>/Inbox/`. |
| `review` | low_confidence (< 0.5) OR unknown type | Advisory; you triage at the gate. |
| `idempotency-skip` | File already carries `generated_by: retrofit@*` | Not walked at all. |

### Retrofit safety guarantees

- **Existing user files are never overwritten** outside the personalization preview/diff cycle. Already-scaffolded folders are dropped from the plan; the matrix surfaces them as `keep` rows (advisory).
- **`move-to` and `merge-into` are advisory only.** Stage 3 only scaffolds new project folders. Moves are surfaced for manual action.
- **Idempotency is structural.** Re-running `/adopt --retrofit-existing` on a partially-retrofitted vault skips files marked `generated_by: retrofit@*` at intake.
- **`.seedignore` is honored.**
- **The cap is the UX guard rail.** Default 500 forces sub-tree scoping on multi-thousand-file vaults.

## Output Contract

### Files written

| Path | Schema type | Cardinality | Lifecycle |
|---|---|---|---|
| `<vault_root>/CLAUDE.md` | Substituted instance of `vault-claude-md-template.md`; identity placeholders all replaced | Single | Seeded once on first `/adopt`; preserved on re-run. |
| `<vault_root>/System Backlog.md` | Markdown index with `type: index` frontmatter | Single | Seeded once; preserved on re-run; populated by `/backlog-triage` over time. |
| `<vault_root>/.coordination/canonical-file-types.json` | Skeleton JSON `{schema_version, phase, file_types[]}` | Single | Seeded once; future versions populate from the archetype heuristic. |
| `<vault_root>/{Inbox,Logs,Logs/backlog-progress,.coordination}/` | Directories | One each | Created idempotently. |
| `<vault_root>/Plans` | Symlink to `$PLANS_HOME` | Single | Read-only navigation surface. |
| `$CLAUDE_HOME/user-manifest.json` | In-place update of `vault.canonical_file_types` (null → `[]`) | Single existing | Atomic update via jq + tmp+rename; preserved if already populated. |

### Pre-write validation

For every vault scaffolding write, in order:

1. **`CLAUDE_HOME` presence.** Exit 10 if unset, empty, or non-existent.
2. **Manifest validity.** Exit 10 if missing or `jq -e .` fails.
3. **`vault.is_fresh` assertion.** Exit 20 if not literal `true`.
4. **State classification.** Exit 21 if `governance/foundation-manifest.json` is absent and `--force-install` not passed.
5. **Retrofit gate.** In retrofit mode, this gate is what selects `retrofit.sh`; in fresh mode, presence of `--retrofit-existing` exits 22.
6. **`vault.root` non-empty.** Exit 30 if empty or null.
7. **Template locatable.** Exit 40 if `vault-claude-md-template.md` is not at `$CLAUDE_HOME/templates/` or the foundation-repo source path.
8. **Atomic tmp+rename.** Every file write goes through `<target>.adopt.tmp.$$` then `mv`. Failure to rename → exit 40.
9. **Post-write placeholder scan.** `grep -E '{{[A-Z_]+}}' CLAUDE.md` after render-and-write; any match → exit 50.

### Failure mode — block-and-log

Never "write and hope." On any validation, parse, or IO failure:

1. Roll back any `*.adopt.tmp.$$` files in the current run; live targets remain untouched.
2. Emit a structured diagnostic to stderr: failed step, expected condition, actual condition, remediation hint.
3. Exit non-zero with the per-class exit code (10 / 20 / 21 / 22 / 30 / 40 / 50) — never exit 1 for a known failure class.
4. Idempotency: failed runs leave the vault in either the pre-run state or a partially-scaffolded state where every individual file is well-formed. Re-running after a transient failure is safe.

## Idempotency

Every step is guarded:

- `mkdir -p` for directories (silent on re-run).
- `ln -sfn` for the `Plans/` symlink (replaces target atomically; safe to re-run).
- `cp -n` and `[ ! -f ]` guards before any seed write.
- Post-write fingerprint validation re-runs at every invocation.

Re-running `/adopt` on an already-scaffolded vault is a no-op modulo the post-write checks. User-edited `CLAUDE.md` content is preserved.

## Refusals

| Exit | Cause |
|---|---|
| 0 | Success (or dry-run plan emit; or no-op idempotent re-run). |
| 10 | `CLAUDE_HOME` unset / manifest missing or invalid. |
| 20 | `vault.is_fresh != true`. Use `--retrofit-existing` for an existing vault. |
| 21 | `governance/foundation-manifest.json` absent. Pass `--force-install` to override. |
| 22 | `--retrofit-existing` with this build's deferral active. |
| 30 | `vault.root` empty or null. |
| 40 | Template missing or atomic rename failed. |
| 50 | Post-write scan found an unresolved `{{IDENTITY_*}}` placeholder. |

## Common questions

**Where do I get an existing vault adopted?** Use `--retrofit-existing`. The collision matrix shows you everything the system would do without committing.

**Can I run `/adopt` without `/onboard`?** Not directly — the manifest is the input contract. You can stage a hand-written `user-manifest.json` at `$CLAUDE_HOME/user-manifest.json` if you want to bypass the interview, but you take ownership of schema validity.

**Does `/adopt` modify `$CLAUDE_HOME`?** Only one field: `vault.canonical_file_types` flips from `null` to `[]`. Everything else writes under `vault.root`.

**What if `vault.root` is already populated?** `/adopt` is idempotent. It will recreate missing directories, leave existing `CLAUDE.md` untouched, and re-validate the canonical-file-types skeleton. There is no clobber.

**Where does the `CLAUDE.md` template live?** Source: `templates/vault-claude-md-template.md`. After install: `$CLAUDE_HOME/templates/vault-claude-md-template.md`. `/adopt` resolves the runtime path first, falls back to the repo-relative path for development.

## Hard rules

1. **Idempotent on re-run.** Every directory create is `mkdir -p`. Every symlink is `ln -sfn`. Every file seed is `[ ! -f ]` guarded. Re-running `/adopt` on a populated vault must NOT overwrite any user content.
2. **No live `~/.claude/` mutations from this script** beyond the documented manifest update. The skill targets the vault directory and one manifest field.
3. **Reference-leak floor.** Empty manifest fields render as `(unset)` so the seeded vault `CLAUDE.md` stays portable. Identity values are user strings; sed-escape them for shell safety, but do not scrub or transform.
4. **Bash 3.2 compatible.** No `declare -A`, `mapfile`, or `${var,,}`.
5. **Output Contract is non-negotiable.** Block-and-log failure mode applies to every file write.

## See also

- [`docs/adopt.md`](../../docs/adopt.md) — full reference doc with manifest-field → vault-output mapping.
- [`skills/onboarder/SKILL.md`](../onboarder/SKILL.md) — the interview that produces the manifest.
- [`skills/infer-vault-structure/SKILL.md`](../infer-vault-structure/SKILL.md) — the four-stage chain retrofit invokes.
- [`skills/seed-projects/SKILL.md`](../seed-projects/SKILL.md) — Stage 3 scaffolder.
- [`vault-scaffolding/`](../../vault-scaffolding/) — the seed files this skill writes.
