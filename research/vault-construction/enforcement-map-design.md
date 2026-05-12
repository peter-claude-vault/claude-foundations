---
altitude: system
scope: How vault governance rules become structural enforcement. R-XX numbering convention, the four hook gate categories, the librarian audit pattern, and the two-surface dual architecture (Claude-consumed JSON registries + user-consumed narrative spokes) that keeps rules teachable and machine-enforceable without drift.
validity_window: 2026-05-12..2026-11-12
source_dependencies:
  - schema: claude-stem/governance/enforcement-map.schema.json
  - governance: claude-stem/governance/_index.json
  - governance: claude-stem/governance/frontmatter-rules.json (R-37 lockstep peer)
  - governance: claude-stem/governance/tagging-rules.json (R-37 lockstep peer)
  - governance: claude-stem/governance/naming-rules.json (R-37 lockstep peer)
  - governance: claude-stem/governance/mandatory-files-rules.json (R-37 lockstep peer)
  - governance: claude-stem/governance/doc-dependencies.json
  - companion: ./frontmatter-design.md
  - companion: ./vault-construction-principles.md
  - companion: ./tagging-strategy.md
  - decision: ../../docs/decisions/0001-tiered-compliance.md
  - decision: ../../docs/decisions/0003-folder-lineage-as-fields.md
  - decision: ../../docs/decisions/0004-system-utility-dimension-exemption.md
  - decision: ../../docs/decisions/0005-two-surface-governance-dual-pattern.md
last_reviewed: 2026-05-12
canonical_url: https://stem.peter.dev/research/vault-construction/enforcement-map-design/
url_stability: locked-from-2026-05-12
---

# Enforcement-map design — how rules become structural enforcement

## Theme

Vault governance only works when rules are both *teachable* (a human can read them, learn them, and recognize when they apply) and *enforced* (a machine refuses to ship work that violates them). The two requirements pull in opposite directions: teachable rules want narrative, examples, and rationale; enforced rules want structured data, deterministic gates, and machine-readable conditions. Collapsing them into a single artifact — the one-big-markdown-file approach — produces a document that is bad at both jobs at once. Narrative gets diluted by enforcement metadata; machine consumption pays a 23–28K-token cost per read for content where the section-of-interest ratio is under 10%.

The architecture in this packet refuses the collapse. Rules live on two surfaces with synchronized content but separate consumers: structured JSON registries that hooks load at runtime, and narrative markdown spokes that users read for learning. An atomic write-time commit pattern (R-37) prevents the surfaces from drifting; an audit-time librarian capability (`governance-parity-audit`) detects the drift that R-37 misses. The pattern is not theoretical — the reference deployment ran a single-pillar instantiation (schema ↔ narrative spoke for frontmatter) through a multi-week production validation before this codification. This packet generalizes the pattern from one pillar to four. See [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md) for the design rationale.

## Vision / approach

The enforcement layer is not "documentation that hooks happen to honor." It is a machine-readable substrate that hooks load directly, paired with a human-readable companion that explains the same content as pedagogy. Rules carry a stable `R-XX` identifier so they can be cited from incident reports, commits, and future rules without renumbering churn. Each rule names the enforcement *layer* — not just the rule — so when a layer fails (a hook crashes, a librarian capability is uninstalled, a schema field is removed) the failure mode is recoverable: another layer named on the same rule row catches the slip.

The architecture is shaped by three structural commitments:

1. **Two surfaces, one content.** JSON registries for Claude (hook-loaded, deterministic, terse); narrative spokes for users (pedagogy, examples, citations, anti-patterns). Bounded drift tolerated; visibility guaranteed.
2. **Four pillars, one schema.** Frontmatter, Tagging, Naming, Mandatory-Files. Each pillar gets its own JSON registry and its own narrative spoke. A thin `_index.json` registers them. A thin `Vault Architecture - Enforcement.md` covers cross-cutting meta-rules.
3. **Write-time + audit-time alignment.** R-37 atomic lockstep at write-time (every governance commit touches JSON + narrative + enforcement-map row + CLAUDE.md ref together). Librarian `governance-parity-audit` capability at audit-time (weekly cron + on-demand). Two layers; bounded drift treated as a signal, not a failure.

The pattern reuses the most-converged 2026 industry primitive (multi-file with scope-frontmatter; see §Industry convergence below) without inventing a new vocabulary. Cursor calls them `.cursor/rules/*.mdc`. GitHub Copilot calls them path-scoped instructions. Anthropic Skills use progressive disclosure. The shape is the same: small files, declared scope, lazy loading. This packet lands the shape inside vault governance.

## The R-XX numbering convention

Every enforcement rule in the system carries a stable `R-NN` identifier registered in the canonical enforcement-map ledger. The convention has four properties:

- **Stable.** Rule IDs never renumber. An R-XX assigned years ago keeps the same slot today. Retired rules keep their slot with a `RETIRED` marker; the row stays so historical commits and incident reports stay readable.
- **Append-only.** New rules take the next integer. The ledger has reached the mid-50s in a reference deployment; collisions are resolved in-row (with a one-line note) rather than by reshuffling. No backfill, no reorder.
- **Citable.** Commits, incident reports, hook DENY messages, and CLAUDE.md prose reference rules by ID: "R-32 Tier 2 DENY," "R-37 atomic lockstep," "R-47 advisory." The ID is shorter than the rule text and survives rewrites.
- **Layer-aware.** Each row enumerates *every* enforcement layer that participates — CLAUDE.md, hook, cron, librarian-capability, schema, manifest-registry, git/gitignore, SSOT. The redundancy is intentional: when one layer fails, another catches the slip, and the row tells the operator which layers are still standing.

The canonical enforcement-map ledger is a process artifact — the human-readable narrative history of the system's enforcement evolution. It is NOT a runtime artifact: no hook loads it as data. Hooks reference it only in header comments ("# R-XX rules implemented here") and in their own write-time whitelist so the ledger's own writes don't trip plan-status enforcement. This distinction matters for the architecture decisions below.

**Anti-pattern: renumbering on insert.** Rules added mid-history get the next sequential ID, not a logical insert point. Renumbering breaks every historical citation. The ledger is append-only by construction.

## Hook gate categories

Hooks are the write-time enforcement layer. They fire on specific Claude Code lifecycle events and either permit, deny, or annotate the proposed action. Four categories cover the surface. (Note: governance-relevant gating lives in Claude Code lifecycle hooks, not in git `pre-commit` / `post-commit` hooks — the latter are unused by this project for governance enforcement. The lifecycle hooks below are where rules actually fire.)

**PreToolUse hooks** — fire before a tool call executes. Used for write-time validation: schema conformance, path allowlisting, structural rule enforcement. Canonical implementation: `hooks/pre-write-guard.sh`. Outputs DENY (block the call), ALLOW (proceed silently), or WARN (proceed with operator annotation). R-32 Tier 2 DENY (frontmatter validation), R-04 (vault-root allowlist), R-09 (Logs/ deny-list), R-15 (plan-backlog row), R-26 (context-pressure mandate), and ~30 more rules fire through this layer. The hook reads governance JSON registries (`governance/_index.json` and the four pillar files) at runtime.

**PostToolUse hooks** — fire after a tool call returns. Used for post-write verification, cascade emission, and self-healing nudges. Canonical implementation: `hooks/post-write-verify.sh`. Less DENY-heavy than PreToolUse; mostly emits structured findings to logs and surfaces them at session-close. R-07 cascade audits and R-47 orphan-tag advisories live here.

**SessionStart / SessionEnd hooks** — fire at session boundary. Used for context loading (SessionStart) and reconciliation (SessionEnd). Cross-session-pollution failure modes live in this layer — peer sessions racing on a shared file path can clobber state. SessionStart hooks include `prompt-context.sh` (R-26 mandate injection), `session-register.sh` (per-session checkpoint rotation), and `cron-health-banner.sh` (R-02). SessionEnd hooks include `auto-commit-surfaces.sh` (R-17) and `reconcile-sessions.sh` (R-42).

**PreCompact hook** — fires before context compaction. Used for state preservation across the compact boundary. `pre-compact-checkpoint.sh` writes the Session Continuity Block schema (R-26) to per-session paths only. A prior single-file `checkpoint.md` design was retired after a cross-session-pollution incident reshaped this category; per-session paths under `$HOOKS_STATE/sessions/<sid>/` are now the contract.

Each gate is named in enforcement-map rows as `hook` in the enforcement layer column, with the specific file path and line range in the row text. When a hook is touched, R-37 lockstep requires the JSON registry it consumes and the narrative spoke it documents to be updated in the same commit.

**Anti-pattern: silently changing hook behavior without updating the registry.** A hook that loads `frontmatter-rules.json` and adds a new validation branch without adding the matching rule entry is undocumented enforcement — the operator can't tell which rule fired from the DENY message. R-37 lockstep prevents the divergence at write-time.

## Librarian audit capability pattern

Hooks catch violations *at write-time*. They do not catch violations that already exist, violations introduced by tools that bypass hooks (manual file moves, external editors, scraper output), or drift between governance surfaces that should be aligned. The complementary layer is the librarian audit capability: a periodic scan that walks vault state, evaluates rules against it, and emits findings.

Capabilities are first-class enforcement layers, named in enforcement-map rows as `librarian-capability`. The pattern has four properties:

- **Read-only by default.** A capability surfaces findings; it does not auto-mutate. Self-healing capabilities exist (R-34 boundary) but require explicit declaration and a higher bar.
- **Categorized findings.** Each finding carries a category (`stale-status-no-evidence`, `provides-canonicality-drift`, `cron-log-architecture-mismatch`, `governance-parity-drift`) so the operator can triage by class, not by line.
- **Cron + on-demand invocation.** Each capability runs on a weekly cron and is callable on-demand via `/librarian <capability>` for ad-hoc checks.
- **Blocking vs advisory.** Findings carry a severity: `blocking` (close-out cannot proceed without resolution) or `advisory` (logged, surfaced at session-close, doesn't block). The severity is a property of the rule, not the capability.

The architecture adds two new capabilities in this pattern. `governance-parity-audit` compares each pillar JSON to its narrative spoke field-by-field and emits drift findings by pillar. `packet-staleness-audit` walks system-altitude research packets and surfaces those approaching the 180-day `last_reviewed` cadence. `log-subtype-audit` detects unregistered `#log/*` and `#status/*` values across the vault (see §System-utility dimension exemption below).

**Anti-pattern: capability that mutates without operator review.** A capability that finds drift and silently rewrites the drifted file is enforcement-via-stealth. Operators lose the audit trail. The R-34 self-healing boundary explicitly limits auto-mutation; everything else surfaces findings for human disposition.

## Two-surface dual pattern (the load-bearing architecture)

Governance ships across two surfaces with separate consumers but synchronized content. This is the load-bearing architectural commitment of the packet — every other decision flows from it. See [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md) for the full decision record.

### Surface 1 — Claude-consumed (foundation-repo `governance/`)

Structured JSON registries loaded by hooks at runtime. Files are small (≤10K each), terse (rule entries are `{id, pillar, tier, source, enforcement_layer, failure_mode, rule_text}` records), and validated by a JSON Schema (`enforcement-map.schema.json`).

| File | Size target | Pillar / role |
|---|---|---|
| `_index.json` | ≤2K | Pillar registry + cross-cutting meta-rules (R-37, R-35, R-34) |
| `frontmatter-rules.json` | ~3-5K | R-32, R-33, R-37, R-39, R-40 |
| `tagging-rules.json` | ~3-5K | R-05, R-32-taxonomy, R-47, R-50 |
| `naming-rules.json` | ~3-5K | R-04, R-10, R-20, R-27, R-28 |
| `mandatory-files-rules.json` | ~3-5K | R-07, R-09, R-12, R-14 |
| `doc-dependencies.json` | ≤10K | R-07 cascade (preserved standalone — different shape from pillar files) |
| `enforcement-map.schema.json` | ≤3K | JSON Schema validating the 4 pillar files |

Hooks load only the pillar they need: `pre-write-guard.sh` frontmatter branch reads `frontmatter-rules.json`; tag-validation branch reads `tagging-rules.json`. Per-pillar load locality matches the access pattern — a single hook gate evaluates one pillar's worth of rules, so unified-file would force longer jq selectors against more bytes than needed.

### Surface 2 — User-consumed (vault `Vault Architecture/`)

Narrative markdown spokes following the 7-spoke pattern carried in the scaffold. Each spoke is hand-authored, carries the project's voice + pedagogy, and ships pre-populated in the adopter scaffold (install.sh writes spokes from foundation-repo into the adopter's vault).

| File | Size target |
|---|---|
| `Vault Architecture - Frontmatter.md` | 4-8K |
| `Vault Architecture - Tagging.md` | 4-8K |
| `Vault Architecture - Naming.md` | 4-8K |
| `Vault Architecture - Mandatory-Files.md` | 4-8K |
| `Vault Architecture - Enforcement.md` | 3-5K (thin meta-spoke) |

The vault-root `enforcement-map.md` becomes a thin pointer file (≤2K) — indexes the 5 spokes + foundation-repo governance JSONs. Bulk content lives in the spokes; the vault-root file is navigation only.

### Alignment mechanism — R-37 atomic lockstep + governance-parity-audit

The surfaces drift if they're allowed to drift independently. The alignment mechanism is two-layer:

**Write-time (R-37 atomic lockstep).** Every governance commit must update *all four* coupled artifacts in one commit: (a) the JSON registry; (b) the matching narrative spoke; (c) the enforcement-map row; (d) the CLAUDE.md reference if global. R-37 fires from `pre-write-guard.sh` — a write that touches one of the four without the others is DENY-blocked with the missing-surface enumerated. R-37 is the same rule that held the reference deployment's single-pillar pair (schema ↔ narrative spoke for frontmatter) coherent through multi-week production validation before this codification generalized it from one pillar to four.

**Audit-time (`governance-parity-audit` capability).** Weekly cron + on-demand via `/librarian govern`. The capability walks each pillar JSON and its narrative spoke, compares field-by-field (rule IDs, tier assignments, source citations, rule-text alignment), and emits drift findings by pillar. Categories: `rule-id-mismatch`, `field-missing`, `tier-mismatch`, `source-divergence`. Findings are advisory by default; the operator triages.

Bounded drift is tolerated (the reference deployment ran at 2-3 types of drift between schema and spoke at any given time; the system functioned). Visibility is guaranteed: drift surfaces in the weekly audit, not in incident response three months later.

**Anti-pattern: aligning surfaces by generation.** A "generate the narrative spoke from the JSON registry" approach was considered and rejected. Narrative spokes carry voice, examples, anti-patterns, and citations — content that doesn't round-trip through JSON without lossy transformation. Generated narrative loses pedagogy. R-37 lockstep + audit catches drift without flattening the spokes.

### Why this architecture (the empirical evidence)

The architecture was decided after a single-comprehensive-lane research dispatch measured the existing surface. Three findings shaped it:

**Finding 1 — the `librarian-manifest.json` is machine-generated inventory, not governance.** Empirical measurement: the manifest is ~150K with thousands of lines, fully regenerated on every full scan. The actual hand-authored Claude-consumed governance JSONs are the schema (a few KB, a few hundred lines) and `doc-dependencies.json` (~10K, ~250 lines) — both small, both runtime-loaded by hooks. The architecture's ask is therefore *extending an existing dual-surface pattern from 2 files to 5*, not introducing a new pattern.

**Finding 2 — the enforcement-map ledger is NOT load-bearing for runtime.** Grepping `pre-write-guard.sh` + `post-write-verify.sh` for ledger references showed only header comments and the write-time whitelist. No hook loads the ledger as data. The ledger at ~90K with multi-thousand-character rows is a *process artifact* — purely a human and dispatched-Claude reading cost, 23-28K tokens per read with section-of-interest ratio under 10%.

**Finding 3 — the dual-surface pattern already existed at single-pillar scale.** The frontmatter schema (Claude-consumed) and `Vault Architecture - Frontmatter.md` (user-consumed) split the frontmatter pillar into two surfaces in the reference deployment. They coexisted through multi-week production validation with ~2-3 types of bounded drift. R-37 lockstep held them aligned. The architecture *documents and scales* the existing dual-surface pattern from 1 pillar to 4 — it is not inventing a new architecture.

**Anti-pattern: the monolith.** A single canonical runtime-consumed markdown ledger was the original framing before the empirical measurement. It fails on three independent axes simultaneously: (a) hooks have no runtime load — the file is comments and whitelist references only; (b) 23-28K-token read cost crowds out skill-listing budget per dispatched session; (c) wide-table monolith with hundreds of rows fails every 2026 industry-convergence threshold for scoped-rule files. The monolith is preserved as the historical narrative ledger (where it works) and superseded as a runtime artifact (where it never was).

## Industry convergence

The two-surface dual pattern reuses the 2026 industry-converged primitive without inventing vocabulary. Four reference implementations:

- **Anthropic Skills progressive disclosure** (claude.com/skills). Skills consist of a short `SKILL.md` (≤500 lines) plus a `reference/` subdirectory of detailed lookups loaded on demand. The pattern: small always-on overlay + lazy load of detail.
- **Cursor `.cursor/rules/*.mdc`** (cursor.com/docs). Multi-file rules with frontmatter declaring `globs:` scope. Rules apply only to files matching their declared paths. Cursor's own "unwieldy" guidance triggers when a `.mdc` file exceeds size thresholds.
- **GitHub Copilot path-scoped instructions** (`.github/instructions/*.md`). Frontmatter declares `applyTo:` path patterns. Copilot's description cap is 1,536 characters; longer content must shard.
- **AGENTS.md nested-instructions convention** (agents-md.com). Nested `AGENTS.md` files at directory levels; each file scopes to its subtree. Pattern is hierarchical, scope-by-location.

The convergence across four independent implementations: (1) multi-file is the dominant pattern past small-monolith size; (2) each file declares its scope via frontmatter; (3) a small always-on overlay carries cross-cutting rules; (4) detailed reference material is load-on-demand; (5) file-size hygiene is a first-class concern with documented thresholds. A monolithic ledger at ~90K with multi-thousand-character rows is on the wrong side of every documented threshold.

The 4-pillar JSON + 4-spoke narrative + thin `_index.json` + thin meta-spoke maps onto the converged primitive cleanly. The `_index.json` is the always-on overlay; pillar JSONs are scope-declared; narrative spokes are load-on-demand from the user side; sizes are bounded.

## Folder-lineage convention

Type information lives at file level only — folders do not carry frontmatter. This forces a workaround for hierarchical context: any file living at `Engagements/<X>/Projects/<Y>/` must carry `engagement: <X>` + `project: <Y>` as frontmatter *fields* AND `#engagement/<X>` + `#project/<Y>` as tags. The folder is the structural artifact; frontmatter fields + tags propagate folder lineage to every file.

The convention has a structural enforcement contract: an R-32 hook contract (folder-lineage validation) DENIES writes where `engagement:` + `project:` field values don't match the directory ancestor names. Tier assignment is advisory Tier 1 → DENY Tier 2 promotion eligible once empirical drift is measured.

**Decision-traceability.** `engagement` and `project` were retired from the canonical TYPE allowlist; in the reference deployment, zero files held those values at TYPE while hundreds held them at FIELD slots — empirical disposition decided the call. The retirement closes a long-deferred ambiguity: are `engagement` and `project` archetypes, or are they navigation slots? Answer: navigation slots, encoded as fields. See [ADR-0003](../../docs/decisions/0003-folder-lineage-as-fields.md).

**Anti-pattern: assuming folder context propagates to LLM consumption automatically.** It doesn't. Claude reads a file's frontmatter, not its directory ancestors. Without the field-propagation rule, a file moved between engagements silently loses its engagement context; without the matching tags, the file disappears from engagement-scoped graph queries. The convention closes both holes.

## System-utility dimension exemption

The 25-tag cap discipline (research-backed by Forte / Dubois / cognitive working-memory literature; see [`tagging-strategy.md`](./tagging-strategy.md)) applies to user-facing dimensions. System-utility dimensions — `#log/*` and `#status/*` — are exempt. They are machine-emitted by skills, crons, and capabilities; they never enter the user's working vocabulary.

The exemption is not "anything goes." System-utility dimensions are subject to a different discipline: the **log-subtype registry**. Every routine activity must use a STABLE, canonical tag value across runs. Example: every `backlog-hygiene` execution tags `#log/backlog-hygiene` — never `#log/backlog-cleanup`, never `#log/backlog-audit`. New subtypes register via the registration hook pattern (the adopter is prompted to register the new subtype + owner; commits to Layer 3 vault-overlay).

The enforcement contract has three layers:

- **Registry primitive** at `governance/log-subtype-registry.json` — canonical enumeration of all `#log/*` and `#status/*` subtype values + the skill/cron that owns each.
- **Skill-side declaration** — every skill or cron that emits log files declares `log_subtype: <slug>` in its SKILL.md / launchd plist frontmatter. The declared value is immutable across runs.
- **Hook gate** — when a file is written to `Logs/` with a `#log/*` or `#status/*` tag, `pre-write-guard.sh` consults the registry. Tag matches a registered value → ALLOW. Near-match (Levenshtein ≤2 or substring containment) → DENY with "did you mean #log/<canonical>?" Genuinely new → require registration.

**Decision-traceability.** The exemption was driven by empirical measurement: a production-scale deployment carried ~46 distinct `#log/*` values, dramatically above the 25-cap. The values are canonical operational subtypes (digest-run, session-close, cron-error, etc.) — they are not noise. The 25-cap was designed for user-facing dimensions; applying it to system-utility dimensions would either retire useful operational granularity or force the cap to be widened in a way that defeats its working-memory rationale. The exemption is the structurally honest answer: different disciplines for different consumers. See [ADR-0004](../../docs/decisions/0004-system-utility-dimension-exemption.md).

**Anti-pattern: "Claude should assign log subtypes intelligently at write-time."** The pattern surfaces as a recurring temptation — let the LLM choose the right `#log/*` tag from context. It fails because LLM choices are stochastic across runs; two `backlog-hygiene` runs produce two different tags, drift accumulates, and the operational subtype space fragments. The registry + hook gate is the structural answer: stability across runs, near-match drift caught DENY, new subtypes register explicitly with operator review.

## Open questions

- **OQ-E1** — exact rule ID for log-subtype near-match DENY behavior is assigned at hook implementation in the consuming sub-plan's lockstep ledger.
- **OQ-E2** — `governance-parity-audit` finding categories may expand beyond the initial four (`rule-id-mismatch`, `field-missing`, `tier-mismatch`, `source-divergence`) once drift patterns are empirically observed. Schema permits extension.
- **OQ-E3** — two-destination install (foundation-repo governance JSONs → adopter `{claude_home}/governance/`; foundation-repo scaffold spokes → adopter `{vault_root}/Vault Architecture/`) needs an idempotent re-install contract for adopters upgrading between releases. An analogous collision pattern (foundation-repo install paths clobbering downstream nudges) surfaced during cross-plan integration work; the resolution informs install.sh design.

## Closed questions (with disposition)

- **CQ-1** Per-pillar split vs unified single file? → **Per-pillar.** Rationale: per-pillar load locality matches hook access pattern; unified forces longer jq selectors + more loaded bytes than needed.
- **CQ-2** Generation pattern vs R-37 lockstep for alignment? → **R-37 lockstep + audit.** Rationale: narrative spokes carry voice + pedagogy that doesn't round-trip through JSON without loss; generation flattens spokes.
- **CQ-3** Anthropic skill-bundle pattern as canonical home (`{claude_home}/skills/govern/`)? → **Rejected as canonical; preserved as secondary surface.** Rationale: distribution is vault-first; canonical narrative must live in vault, not in `{claude_home}/skills/` orphaned from the vault navigation paradigm.
- **CQ-4** Should the enforcement-map ledger retire entirely? → **No — preserved as historical narrative ledger.** Rationale: ledger function works at ~90K (append-only history); the failure was treating it as a runtime artifact. Process role preserved; runtime role moves to pillar JSONs.

## Source pointers

- Governance JSON registries: `governance/_index.json`, `governance/frontmatter-rules.json`, `governance/tagging-rules.json`, `governance/naming-rules.json`, `governance/mandatory-files-rules.json`
- Cross-cascade governance: `governance/doc-dependencies.json`
- Schema validating the four pillar files: `governance/enforcement-map.schema.json`
- Companion narrative packets: [`frontmatter-design.md`](./frontmatter-design.md), [`vault-construction-principles.md`](./vault-construction-principles.md), [`tagging-strategy.md`](./tagging-strategy.md)
- Architecture decision records: [ADR-0001](../../docs/decisions/0001-tiered-compliance.md), [ADR-0003](../../docs/decisions/0003-folder-lineage-as-fields.md), [ADR-0004](../../docs/decisions/0004-system-utility-dimension-exemption.md), [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md)
- Live runtime artifacts (adopter-deployment paths, parameterized via install.sh): `hooks/pre-write-guard.sh`, `hooks/post-write-verify.sh`, `hooks/pre-compact-checkpoint.sh`, `hooks/session-register.sh`
- Industry references: Anthropic Skills (`claude.com/skills`); Cursor `.cursor/rules/*.mdc` (`cursor.com/docs`); GitHub Copilot path-scoped instructions (`docs.github.com/copilot`); AGENTS.md (`agents-md.com`)
