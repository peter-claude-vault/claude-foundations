# April 13, 2026 — Foundation Install Corruption

**Memorial document.** This is the incident that ended Plan 38 and forced the Plan 71 rewrite. Every guard in v2 — G1-main install-side gate, the `I-UNDERSTAND-APRIL-13` sentinel, R-55 live-mutation containment, the `--force-install` flag — exists because of what happened that night.

---

## TL;DR

A dogfood test plan instructed `CLAUDE_HOME=/tmp/test ./install.sh`. `install.sh` did not honor `CLAUDE_HOME` — it hardcoded `CLAUDE_DIR="$HOME/.claude"` at line 21, silently ignored the env var, and overwrote 21 files in the real `~/.claude/`. Recovery was clean (Claude Code's `~/.claude/file-history/` versioning + an accidental naming mismatch that protected production hooks), but Plan 38 was effectively dead by midnight. Plan 71 rebuilt the engine with structural guards that make this failure mode impossible.

**No data was lost. No production system was permanently damaged.** The lesson is structural: an install script that names a destructive default and accepts an env-var override must enforce that override or refuse to run.

---

## What happened (chronological)

### 18:12 EDT — Plan 04 build complete
Plan 38 sub-plan 04 ("Phase 2 Populate") dispatched cleanly via the orchestrator. 11 files staged at `/tmp/foundations-build/`, all verification gates passed (grep-clean, schema validation, archetype self-dry-run). Build was ready to dogfood.

### 19:13 EDT — Dogfood instruction
The dogfood test plan (`DOGFOOD-TEST-PLAN-2026-04-13.md`) instructed:
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

1. **`~/.claude/file-history/`** — Claude Code's built-in per-edit versioning (organized as `{session-uuid}/{filename-hash}@vN`). Recovered the 6 vestigial hooks + `settings.json` from the most recent pre-install version (Apr 13 18:12).

2. **Vault git** — `Documents/Obsidian Vault/.claude/skills/librarian.md` (1,277 lines, last commit `41e7e3b`) used as basis for reconstructing `~/.claude/skills/librarian/SKILL.md` with proper SKILL.md frontmatter prepended.

### Mid-recovery insight that saved production
Peter's actual production hooks have descriptive names — `pre-write-guard.sh`, `session-register.sh`, `prompt-context.sh`, `track-vault-write.sh`, `post-write-verify.sh`, `stop-checkpoint-check.sh`, `pre-compact-checkpoint.sh`, `session-deregister.sh`, `memory-consolidation-check.sh` — referenced in `settings.json` under their descriptive names.

The 6 generic-named hook files the install touched (`pre-tool-use.sh`, `post-tool-use.sh`, etc.) were **vestigial** — leftover from a pre-rename naming convention. Production hooks were never invoked under those names; the install overwrote shadow files that nothing in the live system depended on.

**This was an accidental safety margin, not a designed one.** A different rename history would have left those names live and the production system would have been substantively damaged.

### 22:30–23:45 EDT — Cleanup + validation
Post-recovery: deleted 6 vestigial hooks (zero references anywhere on the system, confirmed by exhaustive grep), deleted empty legacy `~/.claude-plans/` (post-migration to current `~/.claude-plans/`), deleted empty `~/.claude/downloads/`. Recovery snapshot at `~/.claude.pre-recovery-snapshot-20260413-1916/` (476K, 73 files) deleted after `/librarian full` end-to-end validation passed.

End of night: production system intact and cleaner than before. Plan 38 dead.

---

## Root causes

1. **`install.sh` advertised behavior that didn't match reality.** The docstring said `HOME=/tmp/foo ./install.sh` was the supported isolation. The dogfood test plan invented `CLAUDE_HOME=/tmp/foo` as a parallel. install.sh accepted neither — it just hardcoded `$HOME/.claude/` and ran. The fix is not "support both env vars"; the fix is "refuse to run if the configured target collides with an existing live `~/.claude/` without explicit acknowledgement."

2. **Test plans don't bind the production code.** A test plan that says "run with `CLAUDE_HOME=/tmp/foo`" doesn't make `install.sh` honor `CLAUDE_HOME`. The script does what the script does. Treat test-plan instructions as suspect; verify against the actual code paths.

3. **No structural barrier between development install and live install.** The same script that adopters would run was the script Peter ran for dogfood. There was no flag, no sentinel, no environmental check that distinguished "I am building this and want a fresh hermetic install" from "I am an adopter installing for the first time."

---

## Structural fixes shipped in v2

### G1-main install-side guard
`install.sh` detects when `$CLAUDE_HOME` resolves to the canonical real-home path (`$HOME/.claude` on macOS) and refuses to proceed without explicit acknowledgement. The detection is invariant — it doesn't matter what env var you set or didn't set. If the resolved write target is `$HOME/.claude` and it already contains foundation artifacts, the script halts.

### `--force-install` + `I-UNDERSTAND-APRIL-13` sentinel
The only way to bypass G1-main is two physical actions:

1. Pass `--force-install` on the command line.
2. Pipe the literal string `I-UNDERSTAND-APRIL-13` to stdin.

The script reads stdin once, compares against the sentinel, and refuses if absent. There is no way to express "yes, overwrite my live `~/.claude/`" except by typing that string. The April 13 incident is the canonical bypass authorization — the name itself is a memory of why the gate exists.

### R-55 live-mutation containment (Plan 71 SP09)
A separate concern: once Plan 71 development started, every Claude Code session working on Plan 71 sub-plans had to be prevented from writing to live `~/.claude/` outside the sanctioned scope of the active task. R-55 implements two layers:

- **G1 (PreToolUse runtime gate):** `pre-write-guard.sh` invokes `lib/plan-71-live-guard.sh` on every `Edit/Write/MultiEdit`. Plan-71 context is detected via 4 OR'd signals (cwd, env, transcript-tail). Matched writes against `~/.claude/**` are denied unless overridden by a Peter-issued single-use nonce file.
- **G2 (diff-based pre-commit gate):** `~/.claude/.git/hooks/pre-commit` inspects staged paths against the plan-71 denylist; matched paths reject the commit.

Sunset: R-55 retires when v2 distribution is published and the development gates are no longer needed. See `~/.claude/CLAUDE.md` ENFORCEMENT-MAP for the live wording.

### Hermetic test harness (Lima VM with `mounts: []`)
The Plan 71 test harness runs entirely inside a Lima VM whose configuration enforces `mounts: []` — the host filesystem is structurally unreachable from inside the VM. Every install/uninstall cycle in CI runs against `--tmpfs` containers; the host's real `~/.claude/` is invisible to the test code. The Plan 38 corruption couldn't happen here because the test code can't see the target it would have corrupted.

### `~/.claude/file-history/` as recovery backstop
Not a v2 invention — Claude Code's built-in per-edit versioning was the actual recovery mechanism on April 13. Keep using Claude Code, keep the file-history directory, and you have a recovery surface for any future `install.sh` mistake.

---

## Things we did NOT change

**The script is still destructive when authorized.** `--force-install` + sentinel will still overwrite a live `~/.claude/`. The fix is structural ack, not destructive-mode removal — the install path has to work for adopters who genuinely want a fresh install. The guard prevents accidents; it does not prevent intentional destruction.

**`~/.claude/file-history/` is still required.** v2 doesn't ship its own backup. Adopters using Claude Code already have it; anyone running the installer outside Claude Code is operating without that safety net. Document this; don't try to replicate it.

---

## What this means for adopters

If you are reading this as an adopter installing v2 for the first time, the relevant takeaways are:

1. **Run the installer once, against a fresh `~/.claude/`.** The default behavior is exactly what you want.
2. **If you have an existing `~/.claude/`, the installer will refuse.** The April-13 sentinel is not a quirk — it is the structural barrier you should respect. If you genuinely want to overwrite an existing live `~/.claude/`, you know what you're doing; pass `--force-install` and pipe the sentinel.
3. **Keep using Claude Code.** Its `~/.claude/file-history/` directory is the recovery backstop if anything goes wrong. The directory is per-session-UUID and grows over time — leave it alone.

If you are reading this as a developer working on the foundation, the relevant takeaway is: **never trust a test plan over the actual code.** The April 13 plan said `CLAUDE_HOME=/tmp/foo`. The install script ignored it. The plan was wrong; the script was authoritative; production paid the cost.

---

## References

- Plan 38 post-recovery handoff: `~/.claude-plans/38-claude-foundations-onboarding-engine/HANDOFF-POST-RECOVERY-2026-04-13.md`
- Plan 71 SP09 live-mutation postmortem: `~/.claude-plans/71-claude-foundations-engine-v2/09-live-mutation-remediation/POSTMORTEM-2026-04-28-live-mutation-creep.md` (separate incident class — R-55 development-time containment)
- ENFORCEMENT-MAP R-55: `~/.claude/CLAUDE.md`
