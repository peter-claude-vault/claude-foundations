# adopt.md — `/adopt` reference

**Status:** active — adopter-facing reference for fresh-vault scaffolding.
**Audience:** developers who have run `/onboard` and want a working vault skeleton.
**Companion:** [installer.md](installer.md) for `install.sh` reference.

---

## What `/adopt` does

`/adopt` reads `$CLAUDE_HOME/user-manifest.json` (the output of `/onboard`) and scaffolds a minimum-viable Obsidian-compatible vault at `vault.root`. It writes five top-level directories, seeds a personalized `CLAUDE.md`, creates an empty `System Backlog.md` index, drops a `canonical-file-types.json` skeleton for v2.1 to populate, and symlinks `Plans/` to `$PLANS_HOME`.

Round-trip on a fresh archetype takes seconds (the SKILL.md spec ceiling is two minutes for slow filesystems). The skill is **idempotent** — re-running on an already-scaffolded vault is a no-op, modulo post-write validation.

It does **not** import existing content. `--retrofit-existing` is reserved for v2.1 (exit 22 today).

---

## When to run it

`/adopt` runs automatically at `SessionStart` when:

1. `/onboard` has completed Section E.
2. `vault.is_fresh == true` in the manifest.
3. `paths.vault_root` (or `vault.root`) is set.
4. The directory does not yet exist as a populated vault.

Otherwise, run it manually after `/onboard`:

```bash
# Inside Claude Code
/adopt --dry-run     # print the scaffolding plan; zero filesystem changes
/adopt               # apply
/adopt --verbose     # apply with info-level diagnostics on stdout
```

---

## Pre-flight

Per spec §`/adopt` prerequisites, four conditions must be true:

1. **Manifest present.** `$CLAUDE_HOME/user-manifest.json` exists and contains at least `identity.name`, `vault.root`, and `vault.is_fresh = true`.
2. **Foundation install evidence.** `$CLAUDE_HOME/foundation-manifest.json` exists. If absent, `/adopt` refuses with exit 21 unless `--force-install` is passed.
3. **`$PLANS_HOME` resolvable.** Defaults to `$HOME/.claude-plans` if env unset. Created idempotently if absent.
4. **`jq` on `$PATH`.** Foundation install dependency.

If any pre-flight gate fails, `/adopt` exits non-zero with a diagnostic naming the missing piece.

---

## Walkthrough — Alex archetype

The Alex archetype is the project-team-lead persona shipped in the SP01 fixture set. Walk through what `/adopt` does end-to-end.

### Inputs

After `/onboard` completes, `$CLAUDE_HOME/user-manifest.json` contains (excerpt):

```json
{
  "identity": {
    "name": "Alex Engineer",
    "role": "Staff SWE",
    "organization": "Acme Co",
    "industry": "fintech"
  },
  "vault": {
    "root": "~/notes/alex-vault",
    "organizational_method": "engagements-based",
    "top_level_folder": "Engagements",
    "default_audience": "team",
    "is_fresh": true,
    "canonical_file_types": null
  }
}
```

### Step-by-step

1. **Refusal gate.** Reads the manifest. `vault.is_fresh == true` → proceed. (Not `true` would exit 20 with the v2.1 retrofit pointer.)
2. **State gate.** `$CLAUDE_HOME/foundation-manifest.json` exists → proceed.
3. **Retrofit gate.** No `--retrofit-existing` flag → proceed. (With the flag, exits 22.)
4. **Path resolution.** `~/notes/alex-vault` expands to an absolute path. `$PLANS_HOME` resolves (env or `$HOME/.claude-plans` fallback).
5. **Directory scaffold** (`mkdir -p`, idempotent):
   - `~/notes/alex-vault/Inbox/`
   - `~/notes/alex-vault/Logs/`
   - `~/notes/alex-vault/Logs/backlog-progress/`
   - `~/notes/alex-vault/.coordination/`
   - `~/notes/alex-vault/Plans` symlinked via `ln -sfn` to `$PLANS_HOME`
6. **`CLAUDE.md` seed.** If `~/notes/alex-vault/CLAUDE.md` does not exist, render the vault template with substitution:
   - `{{IDENTITY_NAME}}` → `Alex Engineer`
   - `{{IDENTITY_ROLE}}` → `Staff SWE`
   - `{{IDENTITY_ORGANIZATION}}` → `Acme Co`
   - `{{IDENTITY_INDUSTRY}}` → `fintech`
   - `{{VAULT_ORGANIZATIONAL_METHOD}}` → `engagements-based`
   - `{{VAULT_TOP_LEVEL_FOLDER}}` → `Engagements`
   - `{{VAULT_DEFAULT_AUDIENCE}}` → `team`

   Atomic tmp+rename. Post-write validation greps for `{{[A-Z_]+}}`; any remaining placeholder triggers exit 50 (block-and-log).
7. **`System Backlog.md` seed.** Empty index file with `type: index` frontmatter and `## Active` / `## Archived` H2 sections.
8. **`canonical-file-types.json` skeleton.** Stub at `~/notes/alex-vault/.coordination/canonical-file-types.json`:
   ```json
   {"schema_version": "skeleton-1.0.0", "phase": "MVP", "file_types": []}
   ```
   Phase 2 in v2.1 will populate from the archetype heuristic.
9. **Manifest update.** `vault.canonical_file_types` was `null` → initialized to `[]` via jq + atomic tmp+rename. If non-null (already populated by `/onboard`), preserve.
10. **Summary emit.** Print scaffolding summary + next-steps pointer to stdout.

### Result

`~/notes/alex-vault/` now contains:

```
Inbox/
Logs/
  backlog-progress/
.coordination/
  canonical-file-types.json
Plans -> /home/alex/.claude-plans/
CLAUDE.md           ← personalized with Alex's identity
System Backlog.md   ← empty index, ready for backlog rows
```

Open the vault in Obsidian (or any editor). The `CLAUDE.md` carries identity-substituted instructions; `System Backlog.md` is the entry point for system-project tracking.

---

## Manifest fields → vault output mapping

The eight substitution tokens above are the entire interface between `/onboard`'s output and `/adopt`'s scaffold. Empty manifest fields fall back to the literal string `_not provided_` (rendered into the template) — never to operator-specific defaults — to preserve the reference-leak floor.

| Manifest field                  | Substitution token              | Default fallback           |
|---------------------------------|---------------------------------|----------------------------|
| `identity.name`                 | `{{IDENTITY_NAME}}`             | `_not provided_`           |
| `identity.role`                 | `{{IDENTITY_ROLE}}`             | `_not provided_`           |
| `identity.organization`         | `{{IDENTITY_ORGANIZATION}}`     | `_not provided_`           |
| `identity.industry`             | `{{IDENTITY_INDUSTRY}}`         | `_not provided_`           |
| `vault.organizational_method`   | `{{VAULT_ORGANIZATIONAL_METHOD}}` | `_not provided_`         |
| `vault.top_level_folder`        | `{{VAULT_TOP_LEVEL_FOLDER}}`    | `Engagements`              |
| `vault.default_audience`        | `{{VAULT_DEFAULT_AUDIENCE}}`    | `_not provided_`           |
| `vault.architecture_doc`        | `{{VAULT_ARCHITECTURE_DOC}}`    | `_not provided_`           |

---

## Idempotency

Every scaffolding step is guarded:

- `mkdir -p` for directories (silent on re-run).
- `ln -sfn` for the `Plans/` symlink (replaces target atomically; safe to re-run).
- `cp -n` / `[ ! -f ]` guards before any seed write.
- Post-write fingerprint validation re-runs at every invocation.

Re-running `/adopt` on an already-scaffolded vault is a no-op modulo the post-write checks. User-edited `CLAUDE.md` content is preserved.

---

## Refusals

| Exit | Cause                                                                           |
|------|---------------------------------------------------------------------------------|
| 0    | Success (or dry-run plan emit; or no-op idempotent re-run).                     |
| 20   | `vault.is_fresh != true` — retrofit-existing flow not supported in v2.0.        |
| 21   | `$CLAUDE_HOME/foundation-manifest.json` absent (no foundation install). Pass `--force-install` to override.|
| 22   | `--retrofit-existing` passed — v2.1 deferred. Manual-copy workaround in the diagnostic.|
| 50   | Post-write validation found unresolved `{{IDENTITY_*}}` placeholder (block-and-log). |

---

## Common questions

**Where do I get an existing vault adopted?** v2.1. The `--retrofit-existing` path is reserved; today it exits 22 with a diagnostic pointing at the manual-copy workaround (you copy your existing notes into `Inbox/` after running `/adopt` cold).

**Can I run `/adopt` without `/onboard`?** Not directly — the manifest is the input contract. You can stage a hand-written `user-manifest.json` at `$CLAUDE_HOME/user-manifest.json` if you want to bypass the verbal flow, but you take ownership of schema validity.

**Does `/adopt` modify `$CLAUDE_HOME`?** Only one field: `vault.canonical_file_types` flips from `null` to `[]` via atomic jq tmp+rename. Everything else writes under `vault.root`.

**What if `vault.root` is already populated?** `/adopt` is idempotent. It will recreate missing directories, leave existing `CLAUDE.md` untouched, and re-validate the canonical-file-types skeleton. There is no clobber.

**Where does the `CLAUDE.md` template live?** Source: `templates/vault-claude-md-template.md` in the foundation-repo. After install: `$CLAUDE_HOME/templates/vault-claude-md-template.md`. `/adopt` resolves the runtime path first, falls back to repo-relative for development.

---

## See also

- [`onboarder/SKILL.md`](../skills/onboarder/SKILL.md) — verbal-first interview that produces `user-manifest.json`.
- [`adopt/SKILL.md`](../skills/adopt/SKILL.md) — full skill spec with output contract.
- [`installer.md`](installer.md) — `install.sh` companion reference.
- [`personalization-model.md`](personalization-model.md) — how manifest fields flow through the engine.
