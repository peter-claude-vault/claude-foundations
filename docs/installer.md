# installer.md — `install.sh` reference

`install.sh` materializes the foundation engine — hooks, skills, schemas, onboarding scripts, installer plumbing, plist templates, and the bundled claude-mem plugin — into a target `$CLAUDE_HOME` directory. It is **CLAUDE_HOME-first** (the directory is named explicitly via env, never inferred from `$HOME/.claude` defaults) and **dry-run-by-default** (`--apply` is required to make any filesystem changes).

**Audience:** developers adopting Claude Stem for the first time.
**Companion:** [adopt.md](adopt.md) for fresh-vault scaffolding.

---

## What it does

The script writes 14 asset categories (hooks, hooks/lib, 8 skills, 6 schemas, the full onboarding subtree, orchestrator, installer, templates, the claude-mem plugin, and `foundation-manifest.json`), atomically merges a `settings.json` snippet, and emits a deterministic provenance log under `$CLAUDE_HOME/logs/install-<ts>-<pid>.log`.

---

## Quickstart

```bash
# Set the target home (always required — no implicit default).
export CLAUDE_HOME="$HOME/.claude"

# Dry-run by default — emits an action-plan JSON, makes zero changes.
bash install.sh

# Apply for real:
bash install.sh --apply
```

The default dry-run path is the safe entry point. It emits a JSON document on stdout describing what `--apply` would do (asset counts, guards that would fire, sentinel files it would consult). Always run dry-run first, eyeball the output, then re-run with `--apply`.

---

## Flags

| Flag                     | Effect                                                                                                       |
|--------------------------|--------------------------------------------------------------------------------------------------------------|
| `--apply`                | Leave dry-run; perform the actual install. Without this flag, no filesystem mutation happens.               |
| `--force-install`        | Acknowledge the equality / drift sentinel; required when `$CLAUDE_HOME` already contains non-foundation content. |
| `--force-all`            | Catch-all override across guards. Use sparingly — narrows blast-radius assumptions.                         |
| `--no-preserve-config`   | Permit clobbering claude-mem `settings.json` keys. Requires `--force-install` (mutual-exclusion gate).      |
| `--backup-dir <path>`    | Custom backup target for the proof-of-life check. Default: `$CLAUDE_HOME/.pre-install-<ts>/`.               |
| `--backup-dir=<path>`    | Same as `--backup-dir <path>` in `=`-form.                                                                   |
| `--retrofit-existing`    | Permit install over a non-empty `$PLANS_HOME` (`NN-*/` plans present). For adopters with prior plans.       |

---

## Exit codes

`install.sh` uses a structured exit-code map so you can branch programmatically. Codes group by surface: 0 success, 10/11 prereq + write surface, 21 state, 30/40 schema/merge, 51-58 guards, 59 reserved.

| Code | Surface              | Cause                                                                                       |
|------|----------------------|---------------------------------------------------------------------------------------------|
| 0    | success              | Install completed (dry-run JSON emit OR `--apply` round-trip).                              |
| 10   | prereq missing       | `CLAUDE_HOME` unset/empty; required binary absent; SOURCE_REPO not a foundation-repo.       |
| 11   | write failure        | Permission denied; provenance-log write failed; `--no-preserve-config` without `--force-install`.|
| 21   | state                | `$CLAUDE_HOME` contains only non-foundation content without `--force-install`.              |
| 30   | schema parse         | Post-install schema parse failure.                                                          |
| 40   | settings.json merge  | jq merge conflict requires human resolution.                                                |
| 51   | G1-main              | `$HOME/.claude` equality + non-foundation content; missing `--force-install` or `I-UNDERSTAND-OVERWRITE-RISK` sentinel.|
| 52   | G2                   | Foreign-content sha256 drift in foundation files; missing `--force-install` or sentinel.    |
| 53   | G3                   | Backup proof-of-life failed.                                                                |
| 54   | G4                   | Vault-symlink reachable under `$CLAUDE_HOME` (no override).                                 |
| 55   | G5                   | `$PLANS_HOME` contains `NN-*/` plans without `--retrofit-existing`.                         |
| 57   | G7                   | settings.json merge would silently delete keys.                                             |
| 58   | G8                   | Process running as UID 0; install refuses unconditionally.                                  |
| 59   | G9 (reserved)        | Allocated for dry-run-violation tampering detection. Not reachable under current implementation.|

**Reserved (not yet emitted):**

| Code | Reserved name        | Future meaning                                                                              |
|------|----------------------|---------------------------------------------------------------------------------------------|
| 20   | conflict-manifest    | Refuse on collision with unrelated `$CLAUDE_HOME` content; layered atop G2 sha256 drift.    |
| 22   | rsync-backup         | `--backup-mode=rsync` failure (alternate backup backend; current ships cp-R only).          |
| 56   | G6-explicit          | Install-time namespace gate when foundation asset's in-content Label drifts. Symmetric with `bootout-launchd.sh` exit 56.|
| 60   | grep-audit-consumer  | Pre-install `tests/grep-audit.sh` consumer fails when SOURCE_REPO has hits.                 |

---

## Guards (G1 through G10)

`install.sh` runs ten ordered guards before any destructive step. Each guard has a single responsibility and emits a specific exit code on refusal. See [install-corruption-incident.md](install-corruption-incident.md) for the historical incident motivating G1, G2, and G4.

| Guard | Name                          | Fires when                                                                                       |
|-------|-------------------------------|--------------------------------------------------------------------------------------------------|
| G1-pre| CLAUDE_HOME unset/empty       | `$CLAUDE_HOME` is not set or is the empty string. Hard-refuses (no `--force` override).          |
| G1-main| $HOME/.claude equality       | `$CLAUDE_HOME == $HOME/.claude` AND directory contains non-foundation content. Demands sentinel. |
| G2    | sha256 drift                  | Foundation file paths exist in `$CLAUDE_HOME` with content hashes that diverge from baseline.    |
| G3    | backup proof-of-life          | Destructive op pending without a writable, round-trip-verified backup directory.                 |
| G4    | vault-symlink reachable       | A symlink under `$CLAUDE_HOME/...` resolves into a vault directory tree. Hard-refuses.           |
| G5    | $PLANS_HOME plans present     | `$PLANS_HOME` contains `NN-*/` plan directories without `--retrofit-existing`.                   |
| G6    | namespace gate                | Foundation-prefixed launchd Label drifts outside `com.claude-stem.*`. Activation-time enforcement at `installer/render-launchd.sh` and `installer/bootout-launchd.sh`.|
| G7    | settings.json silent-delete   | Pre-merge jq diff shows the merge would silently drop user-defined keys.                         |
| G8    | UID 0                         | `id -u` returns 0. Hard-refuses unconditionally.                                                 |
| G9    | dry-run posture               | Reserved — `--apply` is required to leave dry-run; G9 fires only on tamper detection.            |
| G10   | provenance write              | The provenance log under `$CLAUDE_HOME/logs/` cannot be written.                                 |

The `I-UNDERSTAND-OVERWRITE-RISK` sentinel is shared between G1-main and G2: a single ceremony per install invocation. Set the sentinel at the prompt — do not commit it. See [install-corruption-incident.md](install-corruption-incident.md) for the origin of the name.

---

## Provenance log

Every successful invocation writes one line per asset to `$CLAUDE_HOME/logs/install-YYYYMMDD-HHMMSS-pid.log`. Filenames are deterministic (no spaces; sortable) so `ls -1t` is parsable by `uninstall.sh`. The log header carries the resolved `CLAUDE_HOME` path for symmetry verification at uninstall time.

```text
CLAUDE_HOME: /home/example/.claude
SOURCE_REPO: /tmp/claude-stem
TIMESTAMP: 2026-05-03T18:42:15Z
APPLY_MODE: 1
hooks/pre-write-guard.sh sha256:abcd... bytes:8421
schemas/user-manifest-schema.json sha256:efgh... bytes:5102
...
```

`uninstall.sh` consumes this log to walk fingerprints and refuse if `$CLAUDE_HOME` does not match the provenance header.

---

## Backup

Default backup directory is `$CLAUDE_HOME/.pre-install-<ts>/`. The G3 guard runs a proof-of-life check before any destructive step:

1. Create the backup directory.
2. Write a sentinel file.
3. Read it back and verify byte-for-byte equality.
4. If the round-trip fails (filesystem full, permissions, etc.), refuse install with exit 53.

Override via `--backup-dir <path>` for adopters who want backups outside `$CLAUDE_HOME`. The path must be writable by the install user.

`cp -R` is the current backup backend; `--backup-mode=rsync` is reserved (exit 22).

---

## Troubleshooting

**Install refuses with exit 51 (G1-main).** `$CLAUDE_HOME` resolves to `$HOME/.claude` AND contains files outside the foundation-known basename allowlist. Either: (a) point `$CLAUDE_HOME` at a different directory; (b) move pre-existing content out of the way; (c) verify the sentinel ceremony before re-running with `--force-install`.

**Install refuses with exit 54 (G4).** A symlink under `$CLAUDE_HOME` resolves into a vault tree. There is no override. Remove the symlink before re-running.

**Install refuses with exit 53 (G3).** Backup proof-of-life failed. Check disk space, permissions on the backup-dir parent, and `--backup-dir` argument validity. Retry with a clean backup target.

**`settings.json` merge fails with exit 40.** The installer attempted an atomic `jq` merge but found a conflict. The error message names the conflicting key path. Resolve manually in `$CLAUDE_HOME/settings.json`, then re-run.

**Re-installing.** Re-running `install.sh --apply` against a clean foundation install is idempotent on a per-asset basis (cp-R + atomic merge + post-write fingerprint match). Use `uninstall.sh` first if you want a true cold reinstall.

---

## See also

- [`uninstall.sh`](../uninstall.sh) — symmetric removal; consumes the provenance log.
- [`installer/disable-daemon.sh`](../installer/disable-daemon.sh) — selective daemon teardown without full uninstall.
- [`adopt.md`](adopt.md) — fresh-vault scaffolding via `/adopt`.
- [`install-corruption-incident.md`](install-corruption-incident.md) — historical incident motivating G1, G2, and G4.
- [`provenance-frontmatter.md`](provenance-frontmatter.md) — provenance schema for auto-authored assets.
