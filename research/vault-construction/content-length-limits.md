---
altitude: system
scope: Retrieval-optimized content lengths per vault file class. Establishes target ranges and hard caps for every load-bearing file shape in the architecture (system-altitude packets, narrative spokes, governance JSONs, CLAUDE.md files, SKILL.md, plan files, meeting notes, _index.md, pointer files), grounded in 2026 industry convergence (Anthropic Skills 500-line ceiling, Copilot 1,536-char description cap, Cursor unwieldy-rule guidance, AGENTS.md nested-instructions), cognitive-load literature (Miller, Forte, Dubois), and reference-deployment empirical measurements. Length is treated as a contract enforced by R-37 lockstep + librarian audits, not a preference.
validity_window: 2026-05-12..2026-11-12
source_dependencies:
  - companion: ./enforcement-map-design.md
  - companion: ./vault-construction-principles.md
  - companion: ./frontmatter-design.md
  - companion: ./file-naming-conventions.md
  - companion: ./_index.md-design.md
  - governance: claude-stem/governance/_index.json
  - schema: claude-stem/governance/enforcement-map.schema.json
  - decision: ../../docs/decisions/0005-two-surface-governance-dual-pattern.md
  - external: Anthropic Skills progressive disclosure (claude.com/skills)
  - external: GitHub Copilot path-scoped instructions (docs.github.com/copilot)
  - external: Cursor .cursor/rules/*.mdc unwieldy-rule guidance (cursor.com/docs)
  - external: AGENTS.md nested-instructions (agents-md.com)
  - external: Miller, G. A. (1956) The Magical Number Seven, Plus or Minus Two (Psychological Review 63:81-97)
  - external: Forte working-vocabulary tagging-cap research (6-8 items)
  - external: Dubois faceted-classification literature (10-max cap)
last_reviewed: 2026-05-12
canonical_url: https://stem.peter.dev/research/vault-construction/content-length-limits/
url_stability: locked-from-2026-05-12
---

# Content length limits — retrieval-optimized lengths per file class

## Theme

A vault file is read by two consumers: a human scanning for the section that answers their current question, and an LLM agent loading the file as context before acting. Both pay a cost when files exceed their access-pattern budget. The human loses section-of-interest ratio (fraction of loaded bytes that answer the query) and falls back to keyword-skimming. The agent pays a token cost per fetch, crowds out downstream budget, and above a threshold loses the ability to act on a section because the surrounding context dilutes the signal. Both failures are silent — they surface as worse-than-expected outcomes attributed to the wrong cause.

Length is therefore not a stylistic preference. It is a property of the file's access pattern: a hook loading a JSON registry on every PreToolUse call has a fundamentally different budget than a narrative spoke a user reads once on onboarding. The architecture treats length as a contract — each file class has a target range and a hard cap; exceeding the cap signals that content wants to split by pillar rather than grow. The canonical example is a single legacy enforcement-map ledger measured at ~95K bytes: the file worked as a human-readable ledger but failed as a runtime artifact, costing 23–28K tokens per hook lookup with section-of-interest ratio under 10%. The fix was not "compress the table" — it was to split the runtime surface into four pillar JSONs (≤5K each) and five narrative spokes (4–8K each), preserving the monolith as historical ledger only ([`enforcement-map-design.md`](./enforcement-map-design.md) §Two-surface dual pattern).

This packet locks the file-class thresholds, names the access pattern each threshold serves, and enumerates the anti-patterns that produce drift.

## Vision / approach — four structural commitments

The thresholds below are commitments that the architecture enforces structurally, with industry-converged rationale and reference-deployment empirical grounding. Four principles shape them.

**1. Files are bounded by access pattern, not by topic.** A file's length budget is determined by *how* it is read, not *what* it contains. Three access patterns dominate:

- *Single-fetch agent loads* — hook PreToolUse, librarian audits, skill-time governance lookups. Loaded in full; cost paid every call. Budget small (≤5K target, ≤10K cap) so section-of-interest ratio approaches 1.
- *Progressive-disclosure reads* — human scanning a narrative spoke for the section that answers a question. Whole file available; subsection consumed. Budget moderate (4–8K) so the file fits a single human reading window.
- *Append-only logs* — handoff files, daily logs, enforcement-map ledgers. Read pattern is "find recent entry" or "scan history." Grows without bound; budget is operational (rotation, archival), not per-fetch.

A file mis-classified against its pattern silently fails. A monolithic enforcement-map ledger at ~95K is mis-classified as single-fetch (hooks load governance) when its actual pattern is append-only ledger. The fix is to split: single-fetch portion → small JSONs; append-only portion stays at native length.

**2. Length thresholds map to file classes, not authoring preferences.** Every file belongs to a named class with target range + hard cap (see §File-class thresholds). When content wants to exceed budget, the response is split-by-pillar (not "raise the cap"). Canonical exemplar — the enforcement-map split: one file at ~95K → four pillar JSONs (≤5K each) + four narrative spokes (4–8K each) + thin meta-spoke + vault-root pointer. Total bytes increase modestly; per-fetch cost drops an order of magnitude.

**3. Bounded length enables bounded read cost enables predictable agent behavior.** When file sizes are bounded by class, the orchestrator computes read budgets in advance. A dispatched session loading "the four governance pillars + meta spoke" knows it will spend ≤20K on governance context. When file sizes are unbounded, every dispatch pays whatever size the file happens to be — a regression silently degrades effective task budget. Length-as-contract makes orchestration cost predictable.

**4. Enforcement layers, not authoring discretion.** R-37 atomic lockstep (see [`enforcement-map-design.md`](./enforcement-map-design.md) §Two-surface dual pattern) keeps governance pillars in size-class. Librarian `packet-staleness-audit` (and a candidate `length-class-audit`) surfaces drift at audit-time. Length violations are advisory by default; graduate to blocking when a class-cap breach causes a measurable read-cost regression.

## Industry convergence — the 2026-converged length thresholds

Four independent LLM-tooling vendors have converged on size-discipline practices that this packet draws thresholds from. [`enforcement-map-design.md`](./enforcement-map-design.md) §Industry convergence treats the convergence as a multi-file-vs-monolith decision; this packet applies the same convergence at the per-file-length altitude.

- **Anthropic Skills — SKILL.md ≤500 lines + `reference/` progressive disclosure** (claude.com/skills). Always-loaded `SKILL.md` carries the skill description; detailed reference loads on-demand. Reference-deployment measurement: roughly a third of installed skills exceeded the 500-line ceiling in early-adoption observation — treated as known compaction debt, not working state. New skills hold the line.
- **GitHub Copilot path-scoped instructions — 1,536-character description cap** (docs.github.com/copilot). `.github/instructions/*.md` files declare `applyTo:` frontmatter; description cap is 1,536 chars; longer content shards.
- **Cursor `.cursor/rules/*.mdc` — "unwieldy" guidance** (cursor.com/docs). No published byte cap; user reports surface slower context-load and worse rule matching past ~10K; structural posture is split-when-scopes-diverge.
- **AGENTS.md nested-instructions convention** (agents-md.com). Hierarchical files at directory levels, scoped to subtree. No published per-file cap; structural posture is "small files at the level they apply to."

Across the four implementations: multi-file with scope-declaration is the dominant pattern past small-monolith size, and each vendor encodes size discipline as either a hard cap or a "split when scopes diverge" guideline. The thresholds in §File-class thresholds below are calibrated against this family.

## File-class thresholds — load-bearing inventory

The table below enumerates every load-bearing file class in the architecture. Each row declares: `class`, `path pattern`, `target range`, `hard cap`, `access pattern`, `rationale`. Empirical observations cited inline; sources at §Source pointers.

| Class | Path pattern | Target range | Hard cap | Access pattern | Rationale |
|---|---|---|---|---|---|
| System-altitude research packet | `research/vault-construction/*.md` | 8–12K | 30K | Single-fetch cross-reference lookup by orchestrator + dispatched sessions | Pattern-survey altitude rewards conciseness. Observed siblings range from ~10K (UX primitives, mental-model) to ~28K (architecture-decision anchors). Top-tier anchor packets carry overarching substance; baseline class target is 8–12K. Hard cap 30K acknowledges anchor packets need extra density. **System is the only altitude the foundation imposes** (Session 16 lock #8); adopter-authored packets at non-system altitudes (if adopters choose to write them) are governed by adopter-set thresholds, not by this table. |
| Plan ideation brief | `{plans_root}/<plan>/00-ideation-brief.md` | 6–12K | 25K | Single-fetch session-start load | Reference-deployment range across sampled plans: ~6K–26K. Larger ideation briefs reflect master-initiative complexity; class baseline is 6–12K for single-scope plans. Cap closes at plan close-out. (Plan-tree file class; previously labeled "initiative-altitude packet" pre-Session-16; the altitude framing is retired but the threshold rule still applies to the plan-tree path.) |
| Narrative spoke (pillar) | Vault: `Vault Architecture/Vault Architecture - <Pillar>.md` | 4–8K | 12K | Progressive-disclosure user read | Reference-deployment range across the seven live spokes: ~3.5K–10K. Target sits in the middle of observed range so spokes fit a single human reading window. Hard cap 12K signals "split by sub-topic if accumulating." |
| Thin meta-spoke | `Vault Architecture/Vault Architecture - Enforcement.md` | 3–5K | 7K | Progressive-disclosure user read | Thinner than pillar spokes because the content is cross-cutting meta (R-37 lockstep, promotion framework) — narrative is leaner, fewer worked examples. |
| Vault-root thin pointer | Vault root: `enforcement-map.md` | ≤2K | 3K | Single-fetch navigation lookup | Pointer indexes the four pillar spokes + meta spoke + foundation-repo JSON registries. Bulk content lives downstream; vault-root file is navigation only. |
| Governance JSON `_index` | `governance/_index.json` | ≤2K | 3K | Single-fetch hook load (every PreToolUse) | Pillar registry + cross-cutting meta-rules. Always-loaded overlay — must stay small. |
| Governance JSON pillar | `governance/{frontmatter,tagging,naming,mandatory-files}-rules.json` | 3–5K | 7K | Single-fetch hook load (one pillar per hook gate) | Per-pillar load locality: each gate reads one pillar's rules; unified file would force longer jq selectors against more loaded bytes than needed. |
| Governance JSON cascade | `governance/doc-dependencies.json` | ≤10K | 15K | Single-fetch hook load | Different shape from pillar files (cascade entries are denser). Reference deployment measures ~10K / ~230 lines; preserved standalone. |
| Governance JSON schema | `governance/enforcement-map.schema.json` | ≤3K | 5K | Single-fetch validation load | JSON Schema validating the four pillar files. |
| SKILL.md | `{claude_home}/skills/<skill>/SKILL.md` | ≤500 lines (~15K) | 700 lines (~20K) | Always-on skill description load | Per Anthropic Skills convention. Reference-deployment measurement: about a third of installed skills exceeded 500 lines — known compaction debt; new skills hold the line. Reference material goes in `reference/` subdirectory. |
| Vault-root CLAUDE.md | Vault root: `CLAUDE.md` | 8–15K | 25K | Always-on session-start load (per project) | Global navigation guide. Reference-deployment measure ~26K in a long-running primary vault; flagged as known compaction debt, candidate for `reference/` split in a future hardening pass. New adopters scaffold-emitted at ≤15K. |
| `_index.md` | `<folder>/_index.md` | 0.5–2K | 3K | Single-fetch folder-contents enumeration | Reference-deployment range across sampled folders: ~0.75K–2.6K; an outlier near ~9K signals a legacy artifact candidate for split. Index files are scannable enumerations, not narrative — kept very small by design. (Replaces what folder-scoped CLAUDE.md used to carry pre-Session-16-lock-#1; the one-class CLAUDE.md mandate retired folder-scoped CLAUDE.md as a file class, and `_index.md` is the navigation-surface successor at the same path scope.) |
| Meeting note | Vault: `Meetings/YYYY-MM-DD-*.md` | 1–5K | 8K | Single-fetch lookup by date or by topic | Reference-deployment range: ~0.6K–5.6K across sampled notes. Cap signals "this meeting probably wants a follow-up doc split out." |
| Daily log | Vault: `Daily/YYYY-MM-DD.md` | 0.5–3K | 5K | Single-fetch lookup by date | Brief reflections + day's events; bounded by activity. Cap signals "daily content is overflowing — consider topic-split or sub-page." |
| Plan spec.md | `{plans_root}/<plan>/spec.md` | 8–20K | 30K | Single-fetch session-start load | Reference-deployment range across sampled plans: ~5.5K–25K. Master-initiative specs trend larger than single-scope; class baseline accommodates both. |
| Plan tasks.md | `{plans_root}/<plan>/tasks.md` | 3–15K | 25K | Single-fetch session-start load | Reference-deployment range: ~3K–22K. Larger task files signal master initiative; consider sub-plan decomposition past 25K. |
| Plan handoff.md | `{plans_root}/<plan>/handoff.md` | n/a | n/a (append-only) | Sequential append, full-read on session-start | Append-only session record; no length cap. Rotation/archival handled at plan close. Reference-deployment range: ~1.3K with no upper bound. |
| Plan manifest.json | `{plans_root}/<plan>/manifest.json` | ≤3K | 5K | Single-fetch session-start + librarian audit load | Structured plan metadata; small by design. Hand-editing is forbidden; librarian regenerates. |
| Long-form archive | `Archive/` or `Logs/<subsystem>/` | Variable | n/a (operational) | Sequential append; rotation-bound | Audit trail; budget is operational (rotation, archival), not per-fetch. |
| Enforcement-map ledger | `{plans_root}/ENFORCEMENT-MAP.md` | n/a | n/a (append-only) | Sequential append; full-read on operator scan only | Append-only narrative ledger. Reference-deployment measure ~95K. NOT runtime-loaded by hooks (the empirical finding that shaped the two-surface architecture); preserved as historical ledger only. Runtime governance lives in pillar JSONs. |

The numbers are not arbitrary. Empirically observed classes (narrative spokes, governance JSONs, ideation briefs, vault-root CLAUDE.md, instance `_index.md`) target the middle of the reference-deployment distribution; the hard cap leaves headroom for legitimate complexity but signals a split-point. Externally bounded classes (SKILL.md) follow published convention. Operational classes (handoff.md, archive, append-only ledger) are not bounded per-fetch.

## Cognitive-load rationale

The thresholds align with two distinct cost models that happen to converge.

**Human working memory.** Miller (1956) established the seven-plus-or-minus-two working-memory cap. Forte's tagging research tightens to six-to-eight working items; Dubois's faceted-classification work caps actively-tracked dimensions at ten. Human comprehension degrades sharply past a low-single-digits chunk count. A narrative spoke at 4–8K presents roughly six to ten sections of digestible substance; past 12K the file requires sub-navigation, and the reader either skims (losing detail) or sub-navigates (paying re-orientation cost). The 4–8K target sits at the upper end of single-window readability before that cost kicks in.

**LLM context economics.** Every file an agent loads is paid for in tokens against a finite per-call budget. The section-of-interest ratio — fraction of loaded bytes that answer the active question — determines how much of that budget is productive. A monolithic enforcement-map at ~95K loaded by an orchestrator to find one rule citation has a section-of-interest ratio under 10% — 23–28K tokens spent, ~2–3K productive (see [`enforcement-map-design.md`](./enforcement-map-design.md) §Why this architecture). A pillar JSON at 4K loaded by the same hook has a ratio approaching 1: every byte answers the active question because the file is scoped to one pillar.

The two cost models converge because the same property — bounded scope per file — produces both human readability and machine retrieval efficiency. The thresholds in §File-class thresholds are picked at the joint optimum.

## Anti-patterns the architecture preempts

Four length-discipline anti-patterns recur. Each pairs the temptation with the failure mode and the structural preempt.

### "Raise the cap"

**Temptation.** A file is approaching its hard cap; the author has content that wants to ship; raising the cap 2K seems harmless. **Failure mode.** Caps signal a split-point. Raising the cap defers the split, which is fine once; the second time the file is 1.5× class target and the split is structurally harder (cross-references, embedded examples needing re-anchoring); the third time the file is the monolithic enforcement-map at ~95K and the operator has spent a session researching whether the monolith is salvageable. **Preempt.** When content exceeds threshold, the structural answer is split-by-pillar — see the enforcement-map split ([`enforcement-map-design.md`](./enforcement-map-design.md) §Two-surface dual pattern): one file at ~95K → four pillar JSONs + four narrative spokes + thin meta-spoke + vault-root pointer. Per-fetch cost drops an order of magnitude; pedagogy improves because each spoke focuses examples on one pillar.

### "Single mega-file for searchability"

**Temptation.** "If everything is in one file, I can grep for anything." **Failure mode.** Grep is not the access pattern hooks use. Hooks load via jq selectors against JSON or direct read against markdown; the load cost is paid in full per call regardless of which section the call uses. A ~90K monolith loaded to look up one rule pays the same load cost as one loaded to read every rule — but the productive bytes are vastly different. Section-of-interest ratio collapses; per-call token cost stays at 23–28K. **Preempt.** Scope the file to its access pattern. jq selectors against a 4K pillar JSON give *better* retrieval than against a ~90K monolith because the selector returns the same result against far fewer loaded bytes. Cross-pillar queries hit four small files instead of one huge one.

### "Length is a preference, not a contract"

**Temptation.** Length-as-preference feels less rigid than length-as-contract; one author wants 30K narrative, another wants 8K, the system should accommodate both. **Failure mode.** When length isn't bounded, the orchestrator can't reason about per-call read budget in advance. A spoke that drifted from 8K to 25K silently regresses every dispatch's effective task budget. The cost shows up as worse-than-expected outcomes attributed to other causes; the actual cause (length regression) is invisible. **Preempt.** Length-as-contract. Each class has documented target + hard cap; R-37 lockstep and audit-time backstops keep drift visible. The discipline does not require length to be *low* — it requires length to be *predictable*.

### "Length is for prose; structured data doesn't count"

**Temptation.** Thresholds apply to narrative; JSON files are "just data" and can grow to whatever size the data needs. **Failure mode.** Hooks load JSON in full on every fire. A registry that drifts from 4K to 40K silently 10× the per-call cost of every gate consuming it. Worse, structured-data drift is harder to spot at review than prose drift — no obvious "this section is getting long" moment for a reviewer to flag. **Preempt.** Same discipline for structured data as for prose. Governance pillar JSONs ship with target ranges and hard caps (see §File-class thresholds). When a JSON exceeds threshold, the answer is split-by-pillar or move-detail-to-referenced-lookup. The cascade-dependencies file is preserved at ~10K because its access pattern differs (cascade entries are denser); the exemption is named, not implicit.

## Open questions

- **OQ-L1** — exact frontmatter field for advisory length-class declaration on system-altitude packets (`length_class: pattern-survey` vs `anchor`). Two approaches viable — extend frontmatter schema with `length_class` enum, or infer the class from path + `altitude`. Decision deferred until `packet-staleness-audit` stabilizes and provides the co-location point.
- **OQ-L2** — whether to graduate a dedicated `length-class-audit` librarian capability walking every file class against §File-class thresholds (analogous to `governance-parity-audit` for content drift). Advisory by default; promotion to blocking requires evidence that length drift caused a measurable read-cost regression.

## Closed questions (with disposition)

- **CQ-L1** Single target for all files or class-specific thresholds? → **Class-specific.** Rationale: a single number can't honor (a) pillar JSONs at 4K, (b) narrative spokes at 4–8K, and (c) append-only handoff files simultaneously.
- **CQ-L2** Hard cap on append-only files (handoff.md, enforcement-map ledger, daily logs)? → **No cap; operational rotation/archival instead.** Rationale: truncating append-only history loses the audit trail. A ~95K ledger is acceptable AS LEDGER; it failed only when mis-classified as runtime artifact.
- **CQ-L3** Should SKILL.md follow Anthropic's 500-line guideline despite reference-deployment exceedances? → **Yes — target the convention; live exceedances are known debt.** Treated as forward discipline (new skills hold the line) not retroactive normalization (consistent with the append-only history posture).
- **CQ-L4** Should vault-root `enforcement-map.md` carry the wide-table monolith for backward-compatibility? → **No — pointer-only.** Rationale: the legacy ledger is preserved at its plan-tree path as historical record; vault-root role is navigation only. Keeping the wide table replays the empirical-cost failure mode.

## Source pointers

- Companion packets: [`enforcement-map-design.md`](./enforcement-map-design.md) (Two-surface dual pattern; Why this architecture; Industry convergence), [`vault-construction-principles.md`](./vault-construction-principles.md) (Two-surface governance dual pattern), [`frontmatter-design.md`](./frontmatter-design.md), [`file-naming-conventions.md`](./file-naming-conventions.md), [`_index.md-design.md`](./_index.md-design.md)
- Governance JSON registries (the size targets in this packet apply to these files): `governance/_index.json`, `governance/frontmatter-rules.json`, `governance/tagging-rules.json`, `governance/naming-rules.json`, `governance/mandatory-files-rules.json`, `governance/doc-dependencies.json`, `governance/enforcement-map.schema.json`
- Architecture decision record: [ADR-0005](../../docs/decisions/0005-two-surface-governance-dual-pattern.md)
- External references: Anthropic Skills (`claude.com/skills`); GitHub Copilot path-scoped instructions (`docs.github.com/copilot`); Cursor `.cursor/rules/*.mdc` (`cursor.com/docs`); AGENTS.md (`agents-md.com`); Miller, G. A. (1956) — *Psychological Review* 63:81–97; Forte (6–8 working-vocabulary tagging-cap); Dubois (10-max faceted classification)
