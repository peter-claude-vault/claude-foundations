# Install Corruption Incident — April 13, 2026

An installer that names a destructive default and accepts an env-var override must enforce that override or refuse to run. This document records the night that lesson cost a development cycle, and the structural guards built afterward to make the same mistake impossible.

---

## TL;DR

A test plan instructed `CLAUDE_HOME=/tmp/test ./install.sh`. The installer did not honor `CLAUDE_HOME` — it hardcoded `CLAUDE_DIR="$HOME/.claude"`, silently ignored the env var, and overwrote 21 files in the real `~/.claude/`. Recovery was clean (Claude Code's `~/.claude/file-history/` versioning plus an accidental naming mismatch that protected production hooks), but the development cycle was effectively dead by midnight. The follow-on rewrite added structural guards that make this failure mode impossible.

**No data was lost. No production system was permanently damaged.** The lesson is structural: an env-var override that the script silently ignored is the real story.

---

## What happened (chronological)

### 18:12 EDT — Build complete

A populate-phase build dispatched cleanly via the orchestrator. 11 files staged at `/tmp/foundations-build/`, all verification gates passed. The build was ready to dogfood.

### 19:13 EDT — Dogfood instruction

The dogfood test plan instructed:

```bash
CLAUDE_HOME=/tmp/peter-test-claude-v3 ./install.sh
```

### 19:16:17 EDT — Install ran against real `$HOME/.claude/`

`install.sh` did not honor `CLAUDE_HOME`. Its docstring documented that the supported isolation mechanism was `HOME=/tmp/fresh-claude ./install.sh` (overriding `$HOME`, not adding a new env var). The hardcoded `CLAUDE_DIR="$HOME/.claude"` at line 21 silently bypassed the test plan's intent.

21 files were overwritten in the real `~/.claude/`:
- `manifest/{schema.json, validate-manifest.sh}`
- `hooks/{pre-tool-use.sh, post-tool-use.sh, session-start.sh, user-prompt-submit.sh, pre-compact.sh, stop.sh, README.md, lib/manifest.sh}`
- `skills/{librarian/*, onboard-foundation/*, onboard-behavioral/*}`
- `settings.json`

### 19:17–22:30 EDT — Recovery

Two source-of-truth recovery tracks:

1. **`~/.claude/file-history/`** — Claude Code's built-in per-edit versioning (organized as `{session-uuid}/{filename-hash}@vN`). Recovered the 6 vestigial hooks and `settings.json` from the most recent pre-install version (Apr 13 18:12).

2. **Vault git** — `Documents/Obsidian Vault/.claude/skills/librarian.md` (1,277 lines, last commit `41e7e3b`) used as basis for reconstructing `~/.claude/skills/librarian/SKILL.md` with proper SKILL.md frontmatter prepended.

### Mid-recovery insight that saved production

The actual production hooks have descriptive names — `pre-write-guard.sh`, `session-register.sh`, `prompt-context.sh`, `track-vault-write.sh`, `post-write-verify.sh`, `stop-checkpoint-check.sh`, `pre-compact-checkpoint.sh`, `session-deregister.sh`, `memory-consolidation-check.sh` — referenced in `settings.json` under their descriptive names.

The 6 generic-named hook files the install touched (`pre-tool-use.sh`, `post-tool-use.sh`, etc.) were **vestigial** — leftover from a pre-rename naming convention. Production hooks were never invoked under those names; the install overwrote shadow files that nothing in the live system depended on.

**This was an accidental safety margin, not a designed one.** A different rename history would have left those names live and the production system would have been substantively damaged.

### 22:30–23:45 EDT — Cleanup and validation

Post-recovery: deleted 6 vestigial hooks (zero references anywhere on the system, confirmed by exhaustive grep), deleted empty legacy directories. Recovery snapshot at `~/.claude.pre-recovery-snapshot-20260413-1916/` (476K, 73 files) deleted after end-to-end validation passed.

End of night: production system intact and cleaner than before.

---

## Root causes

1. **`install.sh` advertised behavior that didn't match reality.** The docstring said `HOME=/tmp/foo ./install.sh` was the supported isolation. The dogfood test plan invented `CLAUDE_HOME=/tmp/foo` as a parallel. install.sh accepted neither — it hardcoded `$HOME/.claude/` and ran. The fix is not "support both env vars"; the fix is "refuse to run if the configured target collides with an existing live `~/.claude/` without explicit acknowledgement."

2. **Test plans don't bind the production code.** A test plan that says "run with `CLAUDE_HOME=/tmp/foo`" doesn't make `install.sh` honor `CLAUDE_HOME`. The script does what the script does. Treat test-plan instructions as suspect; verify against the actual code paths.

3. **No structural barrier between development install and live install.** The same script that adopters would run was the script the operator ran for dogfood. There was no flag, no sentinel, no environmental check that distinguished "I am building this and want a fresh hermetic install" from "I am an adopter installing for the first time."

---

## Structural fixes shipped in v2

### CLAUDE_HOME-first installer

`install.sh` now requires `$CLAUDE_HOME` to be set explicitly. There is no `$HOME/.claude` default. Setting `$CLAUDE_HOME` to `$HOME/.claude` is permitted, but the installer detects the equality and routes through the next guard.

### G1-main: $HOME/.claude equality guard

`install.sh` detects when `$CLAUDE_HOME` resolves to the canonical real-home path (`$HOME/.claude` on macOS) and the directory contains non-foundation content. The detection is invariant — it doesn't matter what env var you set or didn't set. If the resolved write target is `$HOME/.claude` and it already contains non-foundation artifacts, the script halts.

### `--force-install` plus `I-UNDERSTAND-APRIL-13` sentinel

The only way to bypass the equality guard is two physical actions:

1. Pass `--force-install` on the command line.
2. Pipe the literal string `I-UNDERSTAND-APRIL-13` to stdin.

The script reads stdin once, compares against the sentinel, and refuses if absent. There is no way to express "yes, overwrite my live `~/.claude/`" except by typing that string. The date is the canonical bypass authorization — the name itself is a memory of why the gate exists.

### Hermetic test harness

The current test harness runs entirely inside a Lima VM whose configuration enforces `mounts: []` — the host filesystem is structurally unreachable from inside the VM. Every install/uninstall cycle in CI runs against `--tmpfs` containers; the host's real `~/.claude/` is invisible to the test code. The April 13 corruption could not happen here because the test code cannot see the target it would have corrupted. See [test-harness.md](test-harness.md).

### `~/.claude/file-history/` as recovery backstop

Not a v2 invention — Claude Code's built-in per-edit versioning was the actual recovery mechanism on the night of the incident. Keep using Claude Code, keep the file-history directory, and you have a recovery surface for any future `install.sh` mistake.

---

## Things we did NOT change

**The script is still destructive when authorized.** `--force-install` plus the sentinel will still overwrite a live `~/.claude/`. The fix is structural acknowledgement, not destructive-mode removal — the install path has to work for adopters who genuinely want a fresh install. The guard prevents accidents; it does not prevent intentional destruction.

**`~/.claude/file-history/` is still required.** v2 doesn't ship its own backup. Adopters using Claude Code already have it; anyone running the installer outside Claude Code is operating without that safety net. Document this; don't try to replicate it.

---

## What this means for adopters

If you are reading this as an adopter installing for the first time:

1. **Run the installer once, against a fresh `~/.claude/`.** The default behavior is exactly what you want.
2. **If you have an existing `~/.claude/`, the installer will refuse.** The April-13 sentinel is not a quirk — it is the structural barrier you should respect. If you genuinely want to overwrite an existing live `~/.claude/`, you know what you're doing; pass `--force-install` and pipe the sentinel.
3. **Keep using Claude Code.** Its `~/.claude/file-history/` directory is the recovery backstop if anything goes wrong. The directory is per-session-UUID and grows over time — leave it alone.

If you are reading this as a developer working on the foundation, the relevant takeaway is: **never trust a test plan over the actual code.** A test plan that names env vars the script ignores is worse than no test plan, because it creates the illusion of isolation while the script writes to production.
