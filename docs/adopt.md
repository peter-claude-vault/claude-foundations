# adopt.md — `/adopt` reference

`/adopt` reads the manifest produced by `/onboard` and scaffolds a working Obsidian-compatible vault on disk. It writes directories, seeds the three vault-root mandatory files (`CLAUDE.md`, `System Backlog.md`, `Vault Architecture.md`), seeds the six governance spokes under `Vault Architecture/`, and symlinks a `Plans/` directory into your plan root.

**Audience:** anyone who has run `/onboard` and wants a working vault skeleton.
**Companion:** [installer.md](installer.md) for `install.sh` reference.

---

## What `/adopt` does

`/adopt` reads `$CLAUDE_HOME/user-manifest.json` and scaffolds a minimum-viable vault at `vault.root`. It writes the foundation-scaffolded directory set, seeds the three vault-root mandatory files (`CLAUDE.md`, `System Backlog.md`, `Vault Architecture.md`) and the six governance spokes under `Vault Architecture/`, and symlinks `Plans/` to `$PLANS_HOME`.

A round-trip on a fresh vault takes seconds (the documented ceiling is two minutes for slow filesystems). The skill is **idempotent** — re-running on an already-scaffolded vault is a no-op modulo post-write validation.

It does **not** import existing content. The retrofit-existing flow is reserved for a future release; today, passing `--retrofit-existing` exits with a refusal.

---

## When to run it

`/adopt` runs automatically at `SessionStart` when:

1. `/onboard` has completed.
2. `vault.is_fresh == true` in the manifest.
3. `paths.vault_root` (or `vault.root`) is set.
4. The directory does not yet exist as a populated vault.

Otherwise, run it manually:

```bash
# Inside Claude Code
/adopt --dry-run     # print the scaffolding plan; zero filesystem changes
/adopt               # apply
/adopt --verbose     # apply with info-level diagnostics on stdout
```

---

## Pre-flight

Four conditions must be true before `/adopt` will write anything:

1. **Manifest present.** `$CLAUDE_HOME/user-manifest.json` exists and contains at least `identity.name`, `vault.root`, and `vault.is_fresh = true`.
2. **Foundation install evidence.** `$CLAUDE_HOME/foundation-manifest.json` exists. If absent, `/adopt` refuses with exit 21 unless `--force-install` is passed.
3. **`$PLANS_HOME` resolvable.** Defaults to `$HOME/.claude-plans` if the env var is unset. Created idempotently if absent.
4. **`jq` on `$PATH`.** A foundation install dependency.

If any pre-flight gate fails, `/adopt` exits non-zero with a diagnostic naming the missing piece.

---

## Walkthrough

To make this concrete: imagine you're "Jane Doe", a Staff SWE at Acme Co working in fintech. You ran `/onboard`, accepted the defaults, and gave your vault root as `~/notes/jane-vault`. Here's what `/adopt` does.

### Inputs

After `/onboard` completes, `$CLAUDE_HOME/user-manifest.json` contains (excerpt):

```json
{
  "identity": {
    "name": "Jane Doe",
    "role": "Staff SWE",
    "organization": "Acme Co",
    "industry": "fintech"
  },
  "vault": {
    "root": "~/notes/jane-vault",
    "organizational_method": "engagements-based",
    "top_level_folder": "Engagements",
    "default_audience": "team",
    "is_fresh": true,
    "canonical_file_types": null
  }
}
```

### Step-by-step

1. **Refusal gate.** Reads the manifest. `vault.is_fresh == true` → proceed. (Anything else exits 20.)
2. **State gate.** `$CLAUDE_HOME/foundation-manifest.json` exists → proceed.
3. **Retrofit gate.** No `--retrofit-existing` flag → proceed. (With the flag, exits 22.)
4. **Path resolution.** `~/notes/jane-vault` expands to an absolute path. `$PLANS_HOME` resolves (env or `$HOME/.claude-plans` fallback).
5. **Directory scaffold** (`mkdir -p`, idempotent):
   - `~/notes/jane-vault/Inbox/`
   - `~/notes/jane-vault/Logs/`
   - `~/notes/jane-vault/Logs/backlog-progress/`
   - `~/notes/jane-vault/Vault Architecture/`
   - `~/notes/jane-vault/Plans` symlinked via `ln -sfn` to `$PLANS_HOME`
6. **`CLAUDE.md` seed.** If `~/notes/jane-vault/CLAUDE.md` does not exist, render the vault template with substitution:
   - `{{IDENTITY_NAME}}` → `Jane Doe`
   - `{{IDENTITY_ROLE}}` → `Staff SWE`
   - `{{IDENTITY_ORGANIZATION}}` → `Acme Co`
   - `{{IDENTITY_INDUSTRY}}` → `fintech`
   - `{{VAULT_ORGANIZATIONAL_METHOD}}` → `engagements-based`
   - `{{VAULT_TOP_LEVEL_FOLDER}}` → `Engagements`
   - `{{VAULT_DEFAULT_AUDIENCE}}` → `team`

   Atomic tmp+rename. Post-write validation greps for `{{[A-Z_]+}}`; any remaining placeholder triggers exit 50 (the script halts and logs rather than shipping a broken file).

7. **`System Backlog.md` seed.** Empty index file with `type: index` frontmatter and `## Active` / `## Archived` H2 sections.
8. **`Vault Architecture.md` seed.** Governance overview hub at vault root — describes the six-pillar governance architecture in human-readable form and links to the spokes in `Vault Architecture/`.
9. **`Vault Architecture/` spokes seed.** Six narrative markdown files (one per governance pillar) seeded from foundation scaffold:
   - `Vault Architecture - Frontmatter.md`
   - `Vault Architecture - Tagging.md`
   - `Vault Architecture - Naming.md`
   - `Vault Architecture - Mandatory-Files.md`
   - `Vault Architecture - Doc-Dependencies.md`
   - `Vault Architecture - File-Type-Contracts.md`
10. **Manifest update.** Vault root confirmed written; manifest `vault.is_fresh` flipped to `false` via jq + atomic tmp+rename.
11. **Summary emit.** Print scaffolding summary + next-steps pointer to stdout.

### Result

`~/notes/jane-vault/` now contains:

```
Inbox/
Logs/
  backlog-progress/
Vault Architecture/
  Vault Architecture - Frontmatter.md
  Vault Architecture - Tagging.md
  Vault Architecture - Naming.md
  Vault Architecture - Mandatory-Files.md
  Vault Architecture - Doc-Dependencies.md
  Vault Architecture - File-Type-Contracts.md
Plans -> /home/jane/.claude-plans/
CLAUDE.md                 ← personalized with Jane's identity
System Backlog.md         ← empty index, ready for backlog rows
Vault Architecture.md     ← governance hub; load when architecture questions arise
```

Open the vault in Obsidian (or any editor). The `CLAUDE.md` carries identity-substituted instructions; `System Backlog.md` is the entry point for system-project tracking; `Vault Architecture.md` + `Vault Architecture/` spokes are the governance reference.

---

## Manifest fields → vault output mapping

The substitution tokens above are the entire interface between `/onboard`'s output and `/adopt`'s `CLAUDE.md` seed. Empty manifest fields fall back to the literal string `_not provided_` (rendered into the template) — never to operator-specific defaults — so the rendered file never ships hard-coded identity for a different person.

| Manifest field                  | Substitution token                | Default fallback   |
|---------------------------------|-----------------------------------|--------------------|
| `identity.name`                 | `{{IDENTITY_NAME}}`               | `_not provided_`   |
| `identity.role`                 | `{{IDENTITY_ROLE}}`               | `_not provided_`   |
| `identity.organization`         | `{{IDENTITY_ORGANIZATION}}`       | `_not provided_`   |
| `identity.industry`             | `{{IDENTITY_INDUSTRY}}`           | `_not provided_`   |
| `vault.organizational_method`   | `{{VAULT_ORGANIZATIONAL_METHOD}}` | `_not provided_`   |
| `vault.top_level_folder`        | `{{VAULT_TOP_LEVEL_FOLDER}}`      | `_not provided_`   |
| `vault.default_audience`        | `{{VAULT_DEFAULT_AUDIENCE}}`      | `_not provided_`   |

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
| 20   | `vault.is_fresh != true` — retrofit-existing flow not supported in this release.|
| 21   | `$CLAUDE_HOME/foundation-manifest.json` absent. Pass `--force-install` to override.|
| 22   | `--retrofit-existing` passed — deferred. Manual-copy workaround in the diagnostic.|
| 50   | Post-write validation found unresolved `{{IDENTITY_*}}` placeholder. The script halts and logs. |

---

## Common questions

**How do I get an existing vault adopted?** Not yet. The `--retrofit-existing` path is reserved; today it exits 22 with a diagnostic pointing at the manual-copy workaround (you copy your existing notes into `Inbox/` after running `/adopt` cold).

**Can I run `/adopt` without `/onboard`?** Not directly — the manifest is the input contract. You can stage a hand-written `user-manifest.json` at `$CLAUDE_HOME/user-manifest.json` if you want to bypass the verbal flow, but you take ownership of schema validity.

**Does `/adopt` modify `$CLAUDE_HOME`?** No. All writes land under `vault.root`. The manifest at `$CLAUDE_HOME/user-manifest.json` has `vault.is_fresh` flipped from `true` to `false` after a successful scaffold, but otherwise `/adopt` does not touch `$CLAUDE_HOME` contents.

**What if `vault.root` is already populated?** `/adopt` is idempotent. It will recreate missing directories, leave existing `CLAUDE.md` untouched, and re-validate the canonical-file-types skeleton. There is no clobber.

**Where does the `CLAUDE.md` template live?** Source: `templates/vault-claude-md-template.md` in the repo. After install: `$CLAUDE_HOME/templates/vault-claude-md-template.md`. `/adopt` resolves the runtime path first, falls back to repo-relative for development.

---

## See also

- [`onboarder/SKILL.md`](../skills/onboarder/SKILL.md) — verbal-first interview that produces `user-manifest.json`.
- [`adopt/SKILL.md`](../skills/adopt/SKILL.md) — full skill spec with output contract.
- [`installer.md`](installer.md) — `install.sh` companion reference.
- [`personalization-model.md`](personalization-model.md) — how manifest fields flow through the engine.
