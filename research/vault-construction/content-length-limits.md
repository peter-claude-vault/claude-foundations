---
altitude: system
scope: Retrieval-optimized content lengths per vault file class. Establishes target ranges and hard caps for every load-bearing file shape in the architecture (system-altitude packets, narrative spokes, governance JSONs, CLAUDE.md files, SKILL.md, plan files, meeting notes, _index.md, pointer files), grounded in 2026 industry convergence (Anthropic Skills 500-line ceiling, Copilot 1,536-char description cap, Cursor unwieldy-rule guidance, AGENTS.md nested-instructions), cognitive-load literature (Miller, Forte, Dubois), and live-vault empirical measurements. Length is treated as a contract enforced by R-37 lockstep + librarian audits, not a preference.
validity_window: 2026-05-12..2026-11-12
source_dependencies:
  - Plan 81 SP03 spec §Research context packets schema (~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md L97-150)
  - Plan 81 SP03 spec §Universal mandatory file enumeration (~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md L152-172)
  - Plan 81 SP03 spec §Governance Architecture — Two-Surface Dual Pattern (same file L174-222)
  - Plan 81 SP03 spec §Files modified table (same file L362-385)
  - Plan 81 SP03 Session 4 architecture decision (~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/Session-04-architecture-decision.md, Peter-approved 2026-05-11)
  - Companion packet — enforcement-map design §Why this architecture (Lane J empirical 23-28K read cost; ENFORCEMENT-MAP 90K monolith critique) (~/Code/claude-stem/research/vault-construction/enforcement-map-design.md L133-143, L145-156)
  - Companion packet — vault-construction-principles §Two-surface governance dual pattern (~/Code/claude-stem/research/vault-construction/vault-construction-principles.md L71-75)
  - Live ENFORCEMENT-MAP.md monolith (94,575 bytes / 145 lines / 4,247-char rows — the canonical anti-pattern measurement)
  - Live Vault Architecture spokes (3.4K-9.9K observed range; 7 files at ~/Documents/Obsidian Vault/Vault Architecture/)
  - Live governance JSON PoC (doc-dependencies.json 10,088 bytes / 233 lines)
  - Live folder-scoped CLAUDE.md observations (3,124-9,359 bytes across Engagements/ + Artefact-BD/)
  - Live _index.md observations (752-2,589 bytes across 10 folders sampled)
  - Live SKILL.md observations (871-115,682 bytes across 23 skills; many exceed Anthropic 500-line guidance)
  - Anthropic Skills progressive disclosure pattern (claude.com/skills documentation — SKILL.md ≤500 lines + reference/ subdirectory)
  - GitHub Copilot path-scoped instructions description cap (docs.github.com/copilot — 1,536-char description cap on .github/instructions/*.md)
  - Cursor .cursor/rules/*.mdc unwieldy-rule guidance (cursor.com/docs)
  - AGENTS.md nested-instructions convention (agents-md.com)
  - Miller, G. A. (1956) The Magical Number Seven, Plus or Minus Two (Psychological Review 63:81-97)
  - Forte tagging-cap research (cited in Peter's foundations-doc-7: ~/Documents/Obsidian Vault/Vault/Logs/foundations-docs/07-the-tagging-taxonomy.md, 6-8 working items)
  - Dubois faceted-classification literature (cited in same foundations-doc, 10-max cap)
last_reviewed: 2026-05-12
canonical_url: https://stem.peter.dev/research/vault-construction/content-length-limits/
url_stability: locked-from-2026-05-12
---

# Content length limits — retrieval-optimized lengths per file class

## Theme

A vault file is read by two consumers: a human scanning for the section that answers their current question, and an LLM agent loading the file as context before acting. Both pay a cost when files exceed their access-pattern budget. The human loses section-of-interest ratio (fraction of loaded bytes that answer the query) and falls back to keyword-skimming. The agent pays a token cost per fetch, crowds out downstream budget, and above a threshold loses the ability to act on a section because the surrounding context dilutes the signal. Both failures are silent — they surface as worse-than-expected outcomes attributed to the wrong cause.

Length is therefore not a stylistic preference. It is a property of the file's access pattern: a hook loading a JSON registry on every PreToolUse call has a fundamentally different budget than a narrative spoke a user reads once on onboarding. The architecture treats length as a contract — each file class has a target range and a hard cap; exceeding the cap signals that content wants to split by pillar rather than grow. The canonical example is `ENFORCEMENT-MAP.md` at 94,575 bytes (Lane J measurement, 2026-05-11): the file works as a human-readable ledger but failed as a runtime artifact, costing 23-28K tokens per hook lookup with section-of-interest ratio under 10%. The fix was not "compress the table" — it was to split the runtime surface into 4 pillar JSONs (≤5K each) and 5 narrative spokes (4-8K each), preserving the monolith as historical ledger only ([`enforcement-map-design.md`](./enforcement-map-design.md) §Two-surface dual pattern).

This packet locks the file-class thresholds, names the access pattern each threshold serves, and enumerates the anti-patterns that produce drift.

## Vision / approach — four structural commitments

The thresholds below are commitments that the architecture enforces structurally, with industry-converged rationale and live-vault empirical grounding. Four principles shape them.

**1. Files are bounded by access pattern, not by topic.** A file's length budget is determined by *how* it is read, not *what* it contains. Three access patterns dominate:

- *Single-fetch agent loads* — hook PreToolUse, librarian audits, skill-time governance lookups. Loaded in full; cost paid every call. Budget small (≤5K target, ≤10K cap) so section-of-interest ratio approaches 1.
- *Progressive-disclosure reads* — human scanning a narrative spoke for the section that answers a question. Whole file available; subsection consumed. Budget moderate (4-8K) so the file fits a single human reading window.
- *Append-only logs* — handoff files, daily logs, ENFORCEMENT-MAP ledger. Read pattern is "find recent entry" or "scan history." Grows without bound; budget is operational (rotation, archival), not per-fetch.

A file mis-classified against its pattern silently fails. ENFORCEMENT-MAP at 94K was mis-classified as single-fetch (hooks load governance) when its actual pattern is append-only ledger. The fix is to split: single-fetch portion → small JSONs; append-only portion stays at native length.

**2. Length thresholds map to file classes, not authoring preferences.** Every file belongs to a named class with target range + hard cap (see §File-class thresholds). When content wants to exceed budget, the response is split-by-pillar (not "raise the cap"). Canonical exemplar — the Plan 81 ENFORCEMENT-MAP split: 1 file at 94K → 4 pillar JSONs (≤5K each) + 4 narrative spokes (4-8K each) + thin meta-spoke + vault-root pointer. Total bytes increase modestly; per-fetch cost drops an order of magnitude.

**3. Bounded length enables bounded read cost enables predictable agent behavior.** When file sizes are bounded by class, the orchestrator computes read budgets in advance. A dispatched session loading "the four governance pillars + meta spoke" knows it will spend ≤20K on governance context. When file sizes are unbounded, every dispatch pays whatever size the file happens to be — a regression silently degrades effective task budget. Length-as-contract makes orchestration cost predictable.

**4. Enforcement layers, not authoring discretion.** R-37 atomic lockstep (see [`enforcement-map-design.md`](./enforcement-map-design.md) §Two-surface dual pattern) keeps governance pillars in size-class. Librarian `packet-staleness-audit` (and a candidate `length-class-audit`, OQ-L2) surfaces drift at audit-time. Length violations are advisory by default; graduate to blocking when a class-cap breach causes a measurable read-cost regression.

## Industry convergence — the 2026-converged length thresholds

Four independent LLM-tooling vendors have converged on size-discipline practices that this packet draws thresholds from. [`enforcement-map-design.md`](./enforcement-map-design.md) §Industry convergence treats the convergence as a multi-file-vs-monolith decision; this packet applies the same convergence at the per-file-length altitude.

- **Anthropic Skills — SKILL.md ≤500 lines + `reference/` progressive disclosure** (claude.com/skills). Always-loaded `SKILL.md` carries the skill description; detailed reference loads on-demand. Live measurement: 8 of Peter's 23 skills exceed 500 lines — known compaction debt, not working state. New skills hold the line.
- **GitHub Copilot path-scoped instructions — 1,536-character description cap** (docs.github.com/copilot). `.github/instructions/*.md` files declare `applyTo:` frontmatter; description cap is 1,536 chars; longer content shards.
- **Cursor `.cursor/rules/*.mdc` — "unwieldy" guidance** (cursor.com/docs). No published byte cap; user reports surface slower context-load and worse rule matching past ~10K; structural posture is split-when-scopes-diverge.
- **AGENTS.md nested-instructions convention** (agents-md.com). Hierarchical files at directory levels, scoped to subtree. No published per-file cap; structural posture is "small files at the level they apply to."

Across the four implementations: multi-file with scope-declaration is the dominant pattern past small-monolith size, and each vendor encodes size discipline as either a hard cap or a "split when scopes diverge" guideline. The thresholds in §File-class thresholds below are calibrated against this family.

## File-class thresholds — load-bearing inventory

The table below enumerates every load-bearing file class in the architecture. Each row declares: `class`, `path pattern`, `target range`, `hard cap`, `access pattern`, `rationale`. Empirical observations cited inline; sources at §Source pointers.

| Class | Path pattern | Target range | Hard cap | Access pattern | Rationale |
|---|---|---|---|---|---|
| System-altitude research packet | `~/Code/claude-stem/research/vault-construction/*.md` | 8-12K | 30K | Single-fetch cross-reference lookup by orchestrator + dispatched sessions | Pattern-survey altitude rewards conciseness. Observed siblings: `ux-primitives.md` 9.8K, `mental-model.md` 13.0K, `vault-construction-principles.md` 27.9K, `enforcement-map-design.md` 28.9K. Top two carry overarching anchoring / architecture-decision substance; baseline class target is 8-12K. Hard cap 30K acknowledges anchor packets need extra density. |
| Engagement-altitude packet | Vault: `Engagements/<X>/` (e.g., per-client deep-context briefs) | Varies | n/a (operational) | Progressive disclosure as engagement progresses | Length is engagement-lifecycle-driven; not retrieval-budget-driven. Audit is "engagement closed → archive," not "file at threshold → split." |
| Topic-altitude packet | Vault: `Reference/<topic>/` | 4-10K | 20K | Single-fetch domain primer | Topic primers are read once when starting work in a domain; budget similar to narrative spokes. 90-day review cadence per spec L103. |
| Initiative-altitude packet | `~/.claude-plans/<plan>/00-ideation-brief.md` | 6-12K | 25K | Single-fetch session-start load | Observed range: 6.3K-25.6K across 8 sampled plans. Larger ideation briefs (Plan 53 at 25.6K) reflect master-initiative complexity; class baseline is 6-12K for single-scope plans. Cap closes at plan close-out. |
| Narrative spoke (pillar) | Vault: `Vault Architecture/Vault Architecture - <Pillar>.md` | 4-8K | 12K | Progressive-disclosure user read | Observed range: 3.4K-9.9K across Peter's 7 live spokes. Target sits in the middle of observed range so spokes fit a single human reading window. Hard cap 12K signals "split by sub-topic if accumulating." |
| Thin meta-spoke | `Vault Architecture/Vault Architecture - Enforcement.md` | 3-5K | 7K | Progressive-disclosure user read | Thinner than pillar spokes because the content is cross-cutting meta (R-37 lockstep, promotion framework) — narrative is leaner, fewer worked examples. Per spec L204. |
| Vault-root thin pointer | Vault root: `enforcement-map.md` | ≤2K | 3K | Single-fetch navigation lookup | Per spec L158 — pointer indexes the 4 pillar spokes + meta spoke + foundation-repo JSON registries. Bulk content lives downstream; vault-root file is navigation only. |
| Governance JSON `_index` | `~/Code/claude-stem/governance/_index.json` | ≤2K | 3K | Single-fetch hook load (every PreToolUse) | Per spec L186. Pillar registry + cross-cutting meta-rules. Always-loaded overlay — must stay small. |
| Governance JSON pillar | `~/Code/claude-stem/governance/{frontmatter,tagging,naming,mandatory-files}-rules.json` | 3-5K | 7K | Single-fetch hook load (one pillar per hook gate) | Per spec L187-190. Per-pillar load locality: each gate reads one pillar's rules; unified file would force longer jq selectors against more loaded bytes than needed. |
| Governance JSON cascade | `~/Code/claude-stem/governance/doc-dependencies.json` | ≤10K | 15K | Single-fetch hook load | Different shape from pillar files (cascade entries are denser). Live PoC measures 10,088 bytes / 233 lines; preserved standalone per spec L191. |
| Governance JSON schema | `~/Code/claude-stem/governance/enforcement-map.schema.json` | ≤3K | 5K | Single-fetch validation load | JSON Schema validating the 4 pillar files. Per spec L192. |
| SKILL.md | `~/.claude/skills/<skill>/SKILL.md` | ≤500 lines (~15K) | 700 lines (~20K) | Always-on skill description load | Per Anthropic Skills convention. Live measurement: 8 of Peter's 23 skills exceed 500 lines — known compaction debt; new skills hold the line. Reference material goes in `reference/` subdirectory. |
| Vault-root CLAUDE.md | Vault root: `CLAUDE.md` | 8-15K | 25K | Always-on session-start load (per project) | Global navigation guide. Live measures 25.9K (Peter's primary vault); current value above class target — flagged as known compaction debt, candidate for `reference/` split in a future hardening pass. New adopters scaffold-emitted at ≤15K. |
| Folder-scoped CLAUDE.md | `<folder>/CLAUDE.md` | 1-3K | 5K | Always-on folder-entry load | Pedagogically dense, small enough to load on every folder-scoped agent invocation. Live observations: 3.1K (Artefact-BD), 4.1K-4.8K (most Engagements), 9.4K (CDMO DDX — known outlier reflecting engagement complexity). Target captures the typical case; outlier signals candidate split. |
| `_index.md` | `<folder>/_index.md` | 0.5-2K | 3K | Single-fetch folder-contents enumeration | Live observations: 0.75K-2.6K across 10 sampled folders; Skills/ outlier at 9.3K (legacy artifact, candidate for split). Index files are scannable enumerations, not narrative — kept very small by design. |
| Meeting note | Vault: `Meetings/YYYY-MM-DD-*.md` | 1-5K | 8K | Single-fetch lookup by date or by topic | Observed range: 0.6K-5.6K across 5 sampled notes. Cap signals "this meeting probably wants a follow-up doc split out." |
| Daily log | Vault: `Daily/YYYY-MM-DD.md` | 0.5-3K | 5K | Single-fetch lookup by date | Brief reflections + day's events; bounded by activity. Cap signals "daily content is overflowing — consider topic-split or sub-page." |
| Plan spec.md | `~/.claude-plans/<plan>/spec.md` | 8-20K | 30K | Single-fetch session-start load | Observed range: 5.5K-25K across 8 sampled plans. Master-initiative specs (Plan 42 at 25K, Plan 53 at 19.4K) larger than single-scope; class baseline accommodates both. |
| Plan tasks.md | `~/.claude-plans/<plan>/tasks.md` | 3-15K | 25K | Single-fetch session-start load | Observed range: 3.1K-22K. Larger task files signal master initiative; consider sub-plan decomposition past 25K. |
| Plan handoff.md | `~/.claude-plans/<plan>/handoff.md` | n/a | n/a (append-only) | Sequential append, full-read on session-start | Append-only session record; per CLAUDE.md exemption, no length cap. Rotation/archival handled at plan close. Observed: 1.3K-33.6K with no upper bound. |
| Plan manifest.json | `~/.claude-plans/<plan>/manifest.json` | ≤3K | 5K | Single-fetch session-start + librarian audit load | Structured plan metadata; small by design. Hand-editing is forbidden (`feedback_manifest_no_hand_edit`); librarian regenerates. |
| Long-form archive | `Archive/` or `Logs/<subsystem>/` | Variable | n/a (operational) | Sequential append; rotation-bound | Audit trail; budget is operational (rotation, archival), not per-fetch. |
| ENFORCEMENT-MAP ledger | `~/.claude-plans/ENFORCEMENT-MAP.md` | n/a | n/a (append-only) | Sequential append; full-read on operator scan only | Append-only narrative ledger. Live measure 94.6K. NOT runtime-loaded by hooks (Lane J finding); preserved as historical ledger only. Runtime governance lives in pillar JSONs. |

The numbers are not arbitrary. Empirically observed classes (narrative spokes, governance JSONs, ideation briefs, folder-scoped CLAUDE.md) target the middle of the live distribution; the hard cap leaves headroom for legitimate complexity but signals a split-point. Externally bounded classes (SKILL.md) follow published convention. Operational classes (handoff.md, archive, ENFORCEMENT-MAP) are not bounded per-fetch.

## Cognitive-load rationale

The thresholds align with two distinct cost models that happen to converge.

**Human working memory.** Miller (1956) established the seven-plus-or-minus-two working-memory cap. Forte's tagging research (cited in Peter's foundations-doc-7) tightens to six-to-eight working items; Dubois's faceted-classification work caps actively-tracked dimensions at ten. Human comprehension degrades sharply past a low-single-digits chunk count. A narrative spoke at 4-8K presents roughly six to ten sections of digestible substance; past 12K the file requires sub-navigation, and the reader either skims (losing detail) or sub-navigates (paying re-orientation cost). The 4-8K target sits at the upper end of single-window readability before that cost kicks in.

**LLM context economics.** Every file an agent loads is paid for in tokens against a finite per-call budget. The section-of-interest ratio — fraction of loaded bytes that answer the active question — determines how much of that budget is productive. ENFORCEMENT-MAP at 94K loaded by an orchestrator to find one rule citation has a section-of-interest ratio under 10% — 23-28K tokens spent, ~2-3K productive ([`enforcement-map-design.md`](./enforcement-map-design.md) §Why this architecture, Lane J empirical). A pillar JSON at 4K loaded by the same hook has a ratio approaching 1: every byte answers the active question because the file is scoped to one pillar.

The two cost models converge because the same property — bounded scope per file — produces both human readability and machine retrieval efficiency. The thresholds in §File-class thresholds are picked at the joint optimum.

## Anti-patterns the architecture preempts

Four length-discipline anti-patterns recur. Each pairs the temptation with the failure mode and the structural preempt.

### "Raise the cap"

**Temptation.** A file is approaching its hard cap; the author has content that wants to ship; raising the cap 2K seems harmless. **Failure mode.** Caps signal a split-point. Raising the cap defers the split, which is fine once; the second time the file is 1.5× class target and the split is structurally harder (cross-references, embedded examples needing re-anchoring); the third time the file is `ENFORCEMENT-MAP.md` at 94K and the operator has spent a session researching whether the monolith is salvageable. **Preempt.** When content exceeds threshold, the structural answer is split-by-pillar — see the ENFORCEMENT-MAP split ([`enforcement-map-design.md`](./enforcement-map-design.md) §Two-surface dual pattern): 1 file at 94K → 4 pillar JSONs + 4 narrative spokes + thin meta-spoke + vault-root pointer. Per-fetch cost drops an order of magnitude; pedagogy improves because each spoke focuses examples on one pillar.

### "Single mega-file for searchability"

**Temptation.** "If everything is in one file, I can grep for anything." **Failure mode.** Grep is not the access pattern hooks use. Hooks load via jq selectors against JSON or direct read against markdown; the load cost is paid in full per call regardless of which section the call uses. A 90K monolith loaded to look up one rule pays the same load cost as one loaded to read every rule — but the productive bytes are vastly different. Section-of-interest ratio collapses; per-call token cost stays at 23-28K. **Preempt.** Scope the file to its access pattern. jq selectors against a 4K pillar JSON give *better* retrieval than against a 90K monolith because the selector returns the same result against far fewer loaded bytes. Cross-pillar queries hit four small files instead of one huge one.

### "Length is a preference, not a contract"

**Temptation.** Length-as-preference feels less rigid than length-as-contract; one author wants 30K narrative, another wants 8K, the system should accommodate both. **Failure mode.** When length isn't bounded, the orchestrator can't reason about per-call read budget in advance. A spoke that drifted from 8K to 25K silently regresses every dispatch's effective task budget. The cost shows up as worse-than-expected outcomes attributed to other causes; the actual cause (length regression) is invisible. **Preempt.** Length-as-contract. Each class has documented target + hard cap; R-37 lockstep and audit-time backstops keep drift visible. The discipline does not require length to be *low* — it requires length to be *predictable*.

### "Length is for prose; structured data doesn't count"

**Temptation.** Thresholds apply to narrative; JSON files are "just data" and can grow to whatever size the data needs. **Failure mode.** Hooks load JSON in full on every fire. A registry that drifts from 4K to 40K silently 10× the per-call cost of every gate consuming it. Worse, structured-data drift is harder to spot at review than prose drift — no obvious "this section is getting long" moment for a reviewer to flag. **Preempt.** Same discipline for structured data as for prose. Governance pillar JSONs ship with target ranges and hard caps (see §File-class thresholds). When a JSON exceeds threshold, the answer is split-by-pillar or move-detail-to-referenced-lookup. Live PoC `doc-dependencies.json` is preserved at 10K because its access pattern differs (cascade entries are denser); the exemption is named, not implicit.

## Open questions

- **OQ-L1** (deferred to librarian-capability authoring): exact frontmatter field for advisory length-class declaration on system-altitude packets (`length_class: pattern-survey` vs `anchor`). Two approaches viable — extend frontmatter schema with `length_class` enum, or infer the class from path + `altitude`. Decision deferred until `packet-staleness-audit` (T-19) stabilizes and provides the co-location point.
- **OQ-L2** (deferred to downstream sub-plan): whether to graduate a dedicated `length-class-audit` librarian capability walking every file class against §File-class thresholds (analogous to `governance-parity-audit` for content drift). Likely SP05 or successor. Advisory by default; promotion to blocking requires evidence that length drift caused a measurable read-cost regression.

## Closed questions (with disposition)

- **CQ-L1** Single target for all files or class-specific thresholds? → **Class-specific.** Decided 2026-05-11 (Plan 81 SP03 spec §Governance Architecture). Rationale: a single number can't honor (a) pillar JSONs at 4K, (b) narrative spokes at 4-8K, (c) handoff.md as append-only simultaneously.
- **CQ-L2** Hard cap on append-only files (handoff.md, ENFORCEMENT-MAP, daily logs)? → **No cap; operational rotation/archival instead.** Decided as Peter's standing posture (`feedback_no_remembered_followups`; R-34). Rationale: truncating append-only history loses the audit trail. ENFORCEMENT-MAP at 94K is acceptable AS LEDGER; it failed only when mis-classified as runtime artifact.
- **CQ-L3** Should SKILL.md follow Anthropic's 500-line guideline despite live exceedances? → **Yes — target the convention; live exceedances are known debt.** Decided this packet (2026-05-12). 8 of 23 live skills exceed 500 lines; treated as forward discipline (new skills hold the line) not retroactive normalization (consistent with CQ-P4 / append-only).
- **CQ-L4** Should vault-root `enforcement-map.md` carry the wide-table monolith for backward-compatibility? → **No — pointer-only.** Decided Session 4 (Plan 81 SP03 spec L158). Rationale: the live ENFORCEMENT-MAP is preserved at `~/.claude-plans/ENFORCEMENT-MAP.md` as historical ledger; vault-root role is navigation only. Keeping the wide table replays the Lane J failure mode.

## Source pointers

**Spec authority:**
- Plan 81 SP03 spec §Research context packets schema (cadence + quality bar): `~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md` L97-150
- Same file §Universal mandatory-file enumeration (vault-root pointer ≤2K): L152-172
- Same file §Governance Architecture (JSON + spoke sizing tables): L174-222
- Same file §Files modified (full file-class enumeration): L362-385
- Plan 81 SP03 Session 4 architecture decision: `~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/Session-04-architecture-decision.md`

**Companion packets:**
- `enforcement-map-design.md` §Why this architecture (Lane J 23-28K read cost; <10% section-of-interest): L133-143
- Same file §Industry convergence (multi-file vs monolith decision): L145-156
- `vault-construction-principles.md` §Two-surface governance dual pattern: L71-75

**Live empirical measurements (sampled 2026-05-12):**
- ENFORCEMENT-MAP monolith (94,575 B / 145 lines): `~/.claude-plans/ENFORCEMENT-MAP.md`
- Vault-root CLAUDE.md (25,909 B; above class target — known debt): `~/Documents/Obsidian Vault/CLAUDE.md`
- Vault Architecture spokes (3.4K-9.9K observed): `~/Documents/Obsidian Vault/Vault Architecture/`
- Governance JSON PoC (`doc-dependencies.json` 10,088 B / 233 lines): `~/.claude/hooks/doc-dependencies.json`
- Folder-scoped CLAUDE.md (3.1K-9.4K across 4 Engagements + Artefact-BD): `~/Documents/Obsidian Vault/Engagements/<X>/CLAUDE.md`
- `_index.md` (0.75K-2.6K across 10 folders sampled): `~/Documents/Obsidian Vault/<folder>/_index.md`
- SKILL.md (18-2,006 lines across 23 skills): `~/.claude/skills/<X>/SKILL.md`
- Ideation briefs (6.3K-25.6K across 8 plans sampled): `~/.claude-plans/<plan>/00-ideation-brief.md`
- Plan spec.md (5.5K-25K across 8 plans sampled): `~/.claude-plans/<plan>/spec.md`

**External references:**
- Anthropic Skills (SKILL.md ≤500 lines + `reference/` progressive disclosure): claude.com/skills
- GitHub Copilot path-scoped instructions (1,536-char description cap): docs.github.com/copilot
- Cursor `.cursor/rules/*.mdc` "unwieldy" guidance: cursor.com/docs
- AGENTS.md nested-instructions: agents-md.com
- Miller, G. A. (1956) — *Psychological Review* 63:81-97
- Forte 6-8 / Dubois 10-max citations: `~/Documents/Obsidian Vault/Vault/Logs/foundations-docs/07-the-tagging-taxonomy.md`

**Memory references:**
- `feedback_manifest_no_hand_edit` — manifest.json hand-edit prohibition
- `feedback_no_remembered_followups` — append-only history posture
