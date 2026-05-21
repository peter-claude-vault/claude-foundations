# vault-init/

Seed tree `/adopt` copies wholesale into a fresh vault. Source-tree organization mirrors the TARGET adopter vault tree EXACTLY (per Plan 81 SP13 Session 7 L-86): foundation authors edit `vault-init/` in target shape; install/adopt copies wholesale; what you see here is what the adopter gets on day one.

## Layout

| Path | Purpose |
|---|---|
| `System Governance/` | 6 narrative spokes + `_index.md` covering the 8-pillar foundation: Frontmatter, Tagging, Naming, Mandatory-Files, Doc-Dependencies, File-Type-Contracts. Stable narrative + research + rationale + pointer-to-JSON + foundation-stable-or-hypothetical examples. Authored under SP15 T-5 / T-6a. |
| `Vault Writers/` | `_index.md` seed (positive override of `_index.md` exemption per SP13 Alignment Session 1 L-1). Adopter-visible catalog of writers landing into this folder. Authored under SP15 T-6b. |
| `file-type-contracts/` | Reference examples (`updates.md.json` + `prd.md.json`) demonstrating Bucket-1(a) `append-template` + Bucket-1(b) `amend-via-prompt` write_shape patterns. SHIP AS REFERENCE ONLY; NOT bundled into `foundation-master.json` (user customizes post-install; install/adopt never re-touches). Authored under SP15 T-6c. |
| `Logs/Archive/` | Empty scaffold (`.gitkeep`) — adopter-side archive landing zone. |
| `Logs/backlog-progress/_template.md` | Surviving v2 file (skill-data seed). Per-backlog-row progress log template used by `/backlog-triage` when promoting a row. |
| `Meetings/` | Empty scaffold (`.gitkeep`) — meeting-processor landing zone. |

## What install/adopt does in addition to copying this tree

- Creates `CLAUDE.md` from `templates/vault-claude-md-template.md` (Mustache substitution at adopt time; not shipped here).
- Symlinks `Plans/` → `$PLANS_HOME` (default `~/.claude-plans/`).
- Symlinks `Skills/` → `~/.claude/skills/`.
- Two-root state-tier scaffold at `$VAULT_WRITER_STATE_ROOT` + `$CLAUDE_STATE_ROOT` (install.sh Step 1.5; not under the vault).

## Editing seed content

Files in this directory are foundation-canonical. They ship sha256-protected via `foundation-manifest.json`; G2 sha256-fingerprint detects drift at install time. If you want a different starting state, edit here and your next install/adopt picks it up.

`/adopt` is idempotent. Re-running it on an already-scaffolded vault leaves user edits in place — seed files are written only when the target file does not already exist.

## Pending relocation (deferred from SP15)

`System Backlog.md` + `System Backlog - Archive.md` carry over from v2 `vault-scaffolding/` pending relocation to `~/.claude-plans/_backlog.md` + `~/.claude-plans/_archive.md` per SP13 §A53. Relocation targets and librarian-managed write surface not yet implemented; tracked as deferred follow-up.

## See also

- `docs/adopt.md` — `/adopt` reference (manifest-field → vault-output mapping).
- `skills/adopt/SKILL.md` — adopt skill output contract.
- `~/.claude-plans/81-claude-stem-dogfood-optimization/foundation-governance-target-state.md` §A53 — vault-init/ source-tree organization lock.
