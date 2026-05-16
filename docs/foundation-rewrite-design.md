# Dropped Rules — pre-write-guard.sh foundation rewrite

The live (operator-internal) `pre-write-guard.sh` referenced 30+ R-rules across its
header comment, embedded enforcement blocks, and cross-reference annotations.
The foundation rewrite (SP02 T-4) preserves 13 generic R-rules and drops the
rest. This file documents every dropped rule with a one-line rationale.

Ground-truth context: of the 16 R-rules listed in SP02 spec Lead 2 §2 as
"preserved", 13 are actually enforced by logic in `pre-write-guard.sh`. The
remaining 3 (R-26, R-38, R-46) are enforced by other hooks/skills and are
documented in the **Covered-elsewhere** section below.

## Preserved (13)

R-01, R-02, R-04, R-15, R-23, R-24, R-27, R-28, R-32, R-33, R-40, R-42, R-45, R-54.

(R-04 is implemented across multiple sections: size guards, vault-root allowlist,
folder placement.)

## Dropped — operator-workflow-specific

These rules enforced conventions specific to the operator's vault structure, engagement
taxonomy, or operational workflow. The foundation distribution does not bundle
them because they have no generic interpretation.

- **R-03** — VA.md size guard hardcode. Generalized into `manifest.schema.size_guards[]` (per-file template); the original hardcoded `Vault Architecture.md`/400-line cap moves to user manifest.
- **R-05** — _(unassigned)_
- **R-06** — _(unassigned)_
- **R-07** — Doc-dependency cascade. Reframed as **R-54** in foundation (generic, reads `$HOOKS_DIR/config/doc-dependencies.json`).
- **R-08** — _(unassigned)_
- **R-09** — Logs/ deny-list soft-warn for deliverable types. Vault-specific routing convention; foundation hooks make no assumption about Logs/ semantics.
- **R-10** — _(unassigned)_
- **R-11** — _(unassigned)_
- **R-12** — _(unassigned)_
- **R-13** — _(unassigned)_
- **R-14** — _(unassigned)_
- **R-16** — _(unassigned)_
- **R-17** — _(unassigned)_
- **R-18** — _(unassigned)_
- **R-19** — _(unassigned)_
- **R-20** — _(unassigned)_
- **R-21** — _(unassigned)_
- **R-22** — _(unassigned)_
- **R-25** — claude-mem SessionEnd pin. Subsumed by **R-24 generic** (`manifest.hooks.protected_session_end_hooks[]` with `HOOK_GUARD_DISABLE_OK=<name>` escape; `CLAUDE_MEM_DISABLE_OK=1` preserved for back-compat).
- **R-29 / R-30 / R-31** — Backlog row size + sentinel pattern. Live in `backlog-hygiene` skill, not in pre-write-guard.
- **R-34** — Self-healing boundary. Documentary rule, no hook enforcement.
- **R-35** — Stage-gated promotion framework. Documentary rule, no hook enforcement.
- **R-36** — Stop-hook touched-file drift scan. Lives in `stop-drift-scan.sh`, not pre-write-guard.
- **R-37** — Schema-addition lockstep commit rule. Enforced by git atomicity + commit hooks, not pre-write-guard.
- **R-47** — Tag-presence advisory. Required operator-specific tag taxonomy (`#engagement/`, `#project/`, `#scope/`, etc.); generic install has no tag taxonomy to enforce against.
- **R-48** — Broken wikilink advisory. Vault-walking advisory tied to Obsidian-style `[[target]]` semantics; foundation defers wikilink validation to per-vault skills.
- **R-49** — _(auto-commit-related; opt-in installer flag, not a hook rule)_
- **R-50** — Shell-lib retrofit. Enforcement-map process rule, not runtime.
- **R-51** — Entity-parity Monday cron. Operational rule, not pre-write-guard.
- **R-52** — Taxonomy ceiling. Process rule, not pre-write-guard.
- **R-53** — Spine-remediation cleanup. Historical migration rule, not generic.

## Dropped — covered-elsewhere

These rules are real and enforced — just not by `pre-write-guard.sh`. Pointers
provided so adopters can locate the canonical enforcement.

- **R-26** — Session-checkpoint mandate (context-pressure thresholds 45% / 48% / 80%). Enforced by `prompt-context.sh` (UserPromptSubmit re-firing mandate) + `stop-checkpoint-check.sh` (stop-blocker). NOT in pre-write-guard.
- **R-38** — Blockquote summary advisory. Enforced by `post-write-verify.sh` (PostToolUse[Edit|Write] runs after the write completes; pre-write inspection is impractical). NOT in pre-write-guard.
- **R-39** — `provides:` presence advisory. Same enforcement location as R-38 (`post-write-verify.sh`). NOT in pre-write-guard.
- **R-41** — Subsumed by R-40 plan-artifact frontmatter schema (single-source consolidation 2026-04-17). Reading R-41 in any spec means "see R-40".
- **R-43** — Track-vault-write registry. Enforced by `track-vault-write.sh` (PostToolUse). NOT in pre-write-guard.
- **R-44** — Post-write-verify pipeline. Enforced by `post-write-verify.sh` (entire script). NOT in pre-write-guard.
- **R-46** — Waiver-audit 4-shape tolerant parser. Lives in librarian skill (`waiver-audit` capability). Pre-write-guard references the cascade-waiver writer (lib/cascade-waiver.sh) but does not run the audit.

## Audit-log path migration

The live hook wrote audit lines to an installation-specific filesystem path
under `$HOME/Desktop/`. The foundation hook writes to `$HOOKS_STATE/hook-audit.log`
(manifest-overridable via `manifest.hooks.audit_log_path`). Four write sites
consolidated through a single `audit_log()` helper function.

## Helper-function consolidation

Three helpers were factored from the live hook to reduce line count:
- `audit_log()` — replaces 4 inline `echo … >> <hardcoded-audit-path>` blocks.
- `literal_replace()` — replaces 5 inline python-heredoc Edit-content reconstruction blocks.
- `emit_deny()` / `emit_allow_ctx()` — replace 12+ inline `jq -n` deny/allow blocks.

Net: ~140 lines saved through deduplication, on top of ~480 lines saved by
dropping operator-workflow rules and externalizing 6 hardcoded blocks to manifest.
Final size: 635 lines vs. live 1257 lines (49% reduction).
