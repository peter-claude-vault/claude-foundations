# ADR-0005: Two-Surface Governance Dual Pattern (JSON + narrative spoke)

**Status:** accepted
**Date:** 2026-05-11
**Deciders:** Foundation-repo architecture (Plan 81 SP03)
**Tags:** governance, architecture, enforcement-map

## Context

Vault governance must do two jobs at once:

1. **Be teachable** — a human can read the rules, learn them, recognize when they apply, and understand the rationale. This requires narrative, examples, anti-patterns, citations.
2. **Be enforced** — a machine refuses to ship work that violates them. This requires structured data, deterministic gates, machine-readable conditions.

The two requirements pull in opposite directions. Collapsing them onto a single artifact — the one-big-markdown-file approach — produces a document that's bad at both jobs at once. Narrative gets diluted by enforcement metadata; machine consumption pays a 23-28K-token cost per read for content where the section-of-interest ratio is under 10%.

A comprehensive research lane (Plan 81 SP03 Session 4) measured the failure of the monolith approach. The original ENFORCEMENT-MAP.md ledger ran 90K with 4,247-character rows. Hooks referenced it only in header comments — no runtime load. It functioned as a process artifact (the R-XX narrative ledger) but failed as a runtime artifact. Meanwhile, the reference deployment's existing dual-surface PoC — `vault-schema.json` (Claude-consumed) + `System Governance - Frontmatter.md` (user-consumed) — had coexisted for ~4 weeks with ~2-3 types of bounded drift, manageable via atomic-lockstep commit discipline.

Industry-converged signal: Anthropic Skills (progressive disclosure), Cursor `.cursor/rules/*.mdc` (multi-file scoped rules), GitHub Copilot path-scoped instructions, AGENTS.md (nested instructions) — all four reference implementations exile build-tier metadata from runtime artifacts and split human-narrative from machine-readable scope declarations.

## Decision

Governance ships across **two surfaces** with separate consumers but synchronized content:

**Surface 1 — Claude-consumed** (`claude-stem/governance/`):
- Structured JSON registries loaded by hooks at runtime
- Files: `_index.json` (pillar registry), `frontmatter-rules.json`, `tagging-rules.json`, `naming-rules.json`, `mandatory-files-rules.json`, `doc-dependencies.json`, `enforcement-map.schema.json`
- Each ≤10K, terse, rule-entry shape `{id, pillar, tier, source, enforcement_layer, failure_mode, rule_text}`
- Validated by `enforcement-map.schema.json`

**Surface 2 — User-consumed** (adopter vault `System Governance/`):
- Narrative markdown spokes following a 7-spoke pattern
- Files: `System Governance - Frontmatter.md`, `- Tagging.md`, `- Naming.md`, `- Mandatory-Files.md`, `- Enforcement.md` (meta)
- Each 4-8K, hand-authored narrative voice + pedagogy + examples + anti-patterns + citations
- Rendered from foundation-repo scaffold at install time

**Alignment mechanism — two-layer drift control:**

1. **Write-time (R-37 atomic lockstep).** Every governance commit must update all four coupled artifacts in one commit: (a) JSON registry, (b) matching narrative spoke, (c) the corresponding rule entry, (d) CLAUDE.md ref if global. R-37 fires from `pre-write-guard.sh` — a write that touches one of the four without the others is DENY-blocked with the missing-surface enumerated.

2. **Audit-time (`governance-parity-audit` librarian capability).** Weekly cron + on-demand. Compares each pillar JSON to its narrative spoke field-by-field. Categories: `rule-id-mismatch`, `field-missing`, `tier-mismatch`, `source-divergence`. Findings are advisory by default.

Bounded drift is tolerated (the reference deployment runs at 2-3 types of drift between schema and spoke at any given time; the system functions). Visibility is guaranteed: drift surfaces in the weekly audit.

**Rejected alternative — generated spoke.** A "generate the narrative spoke from the JSON registry" approach was considered and rejected. Narrative spokes carry author voice, examples, anti-patterns, and citations — content that doesn't round-trip through JSON without lossy transformation. Generated narrative loses pedagogy. R-37 lockstep + audit catches drift without flattening the spokes.

## Consequences

**Positive:**
- Both jobs (teachable + enforced) get appropriate artifacts.
- Hook loads are bounded (per-pillar JSON; one pillar's worth of rules per gate).
- Narrative spokes carry hand-authored pedagogy that survives the schema's evolution.
- Industry-converged primitive (multi-file with scope-frontmatter) imported wholesale; no new vocabulary invented.
- Per-pillar split matches the access pattern — hooks load only the pillar they need.

**Negative:**
- Two artifacts per pillar instead of one. Authors must keep both updated.
- R-37 lockstep requires discipline — partial updates are DENY-blocked.
- The `governance-parity-audit` capability is required infrastructure (not yet implemented at this writing; deferred to SP05).
- Adopters who want to bypass R-37 lockstep for emergency fixes need an escape hatch (`PLAN_STATUS_OK=1` env var; audited).

**Neutral:**
- The ENFORCEMENT-MAP.md ledger is preserved as historical narrative ledger (where it works — append-only history) and superseded as a runtime artifact (where it never was).
- The pattern scales: the reference deployment ran it on one pillar; the foundation-repo scales it to four (frontmatter + tagging + naming + mandatory-files) plus the meta-spoke (enforcement).

## Source decision provenance

- Plan 81 SP03 spec §Governance Architecture (`~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md` L174-222)
- Plan 81 SP03 Session 4 architecture decision (`~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/Session-04-architecture-decision.md` — Peter-approved 2026-05-11)
- Research lane (single-comprehensive lane, "Lane J") empirical measurement: ENFORCEMENT-MAP.md monolith at 90K with 4,247-char rows; runtime-cost 23-28K tokens per read with <10% section-of-interest ratio; pre-write-guard.sh + post-write-verify.sh grep results — no runtime load, only header-comment references
- Live PoC: `vault-schema.json` ↔ `System Governance - Frontmatter.md` coexistence for ~4 weeks with bounded drift
- Industry references: Anthropic Skills progressive disclosure (claude.com/skills); Cursor `.cursor/rules/*.mdc` (cursor.com/docs); GitHub Copilot path-scoped instructions (docs.github.com/copilot); AGENTS.md (agents-md.com)

## Related ADRs

- [ADR-0002](./0002-unified-with-per-archetype-entries.md) — schema model that ships on Surface 1
- [ADR-0001](./0001-tiered-compliance.md) — tier definitions are mirrored across Surface 1 + Surface 2 via R-37 lockstep

---

## SP13 Post-Onboarding Governance Architecture — Amendment (2026-05-16)

**Surface 2 spoke count revised to 6.** The `System Governance - Enforcement.md` meta-spoke referenced in this ADR is **retired** per the canonical post-onboarding governance architecture (SP13 Session 9). The meta-spoke carried governance-narrative content that belongs in the JSON pillars and hook logic, not in a user-facing spoke. Surface 2 now mirrors exactly the 6 governance pillars:

1. `System Governance - Frontmatter.md`
2. `System Governance - Tagging.md`
3. `System Governance - Naming.md`
4. `System Governance - Mandatory-Files.md`
5. `System Governance - Doc-Dependencies.md`
6. `System Governance - File-Type-Contracts.md`

**Surface 1 `enforcement-map.schema.json` retired.** The schema referenced in the "Files" list above is retired entirely (SP13 Session 9 reversal of the B-7 kept-orthogonal decision). The 6-pillar governance set described in §A of `foundation-governance-target-state.md` is the canonical Surface 1.

See `foundation-governance-target-state.md` §D (System Governance/ folder content) and §G (retired items) for the canonical reference.
