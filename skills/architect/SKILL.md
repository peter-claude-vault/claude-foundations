---
name: architect
description: Strategic vault system evolution. Analyzes health trends, intake effectiveness, rule coverage, skill gaps. Produces recommendations, never modifies.
disable-model-invocation: false
argument-hint: "[--skill {name}] [--focus {dimension}] [--compare {report-path}] [--adaptive] [--verbose]"
---

# Architect

Strategic advisor for the vault system. Analyzes the vault across 7 dimensions, measures convergence over time, and produces actionable recommendations. Reads from the librarian manifest + logs + Vault Architecture + Skills `_index.md` + its own previous reports. Proposes, never modifies.

## Invocation

`/architect [flags]`

| Command | Runs | Scope |
|---------|------|-------|
| `/architect` | Full 7-dimension analysis | Full vault (via manifest) |
| `/architect --skill {name}` | Deep single-skill analysis | Target skill + dependency graph |
| `/architect --focus {dimension}` | Single dimension deep dive | Full vault |
| `/architect --compare {report-path}` | Full analysis + convergence tracking | Full vault + previous report |
| `/architect --adaptive` | Full analysis with progressive depth | Full vault (depth varies per dimension) |
| `/architect --verbose` | Full analysis with raw data tables | Full vault |

Flags combine: `/architect --adaptive --compare {path}` or `/architect --skill librarian --verbose`.

**Dimensions:** `metrics`, `structure`, `content`, `flow`, `rules`, `skills`, `research`

## Data Sources

Curly-brace tokens (`{VAULT_ROOT}`, `{VAULT_LOGS}`, `{CLAUDE_HOME}`, `{PLANS_ROOT}`, `{architect.output_dir}`) are resolved at runtime from `user-manifest.json` via `lib/paths.sh`. Shell-style `$VAULT_ROOT` etc. denote the same values exported as environment variables for runtime use.

| Source | What it provides | Required? | First-run fallback |
|--------|-----------------|-----------|--------------------|
| `{VAULT_LOGS}/librarian-manifest.json` | Current vault state — inventory, top-level grouping, tags, xref graph, scan history, pending issues | **Yes** (PRIMARY) | If absent: tell the user to run `/librarian full`; cannot proceed |
| `{VAULT_LOGS}/session-close-*.md` | Session audit history, error trends | No | Empty set (no history yet) |
| `{VAULT_LOGS}/librarian-*.md` | Librarian run logs, findings over time | No | Empty set (no history yet) |
| `{VAULT_ROOT}/{VAULT_ARCHITECTURE_DOC}` | The rules — structure, conventions, routing, frontmatter specs (filename resolved from `manifest.vault.architecture_doc`) | Yes | If absent: note in report; analyze without rules-context |
| `{VAULT_ROOT}/Skills/_index.md` | Automation landscape — all skills, triggers, status | Yes | If absent: note in report; Dimension 6 reduces to "no automation declared" |
| `{VAULT_ROOT}/System Backlog.md` | System project portfolio — status, dependencies, cross-project conflicts | Yes | If absent: note in report; Dimension 6 skill-coverage analysis runs without backlog cross-reference |
| `{VAULT_LOGS}/architect-*.md` | Previous architect reports for convergence | Only with `--compare` | If absent with `--compare`: warn user; run as if no prior report |

**If manifest is stale (>24h):** Tell the user, then run `/librarian` to refresh it before proceeding.
**If manifest is missing:** Cannot run. Tell the user to run `/librarian full` first.

---

## Analysis Dimensions

### Dimension 1: Metrics Collection

Quantitative vault health. Computed from manifest data + targeted reads.

| Metric | How Computed | Benchmark |
|--------|-------------|-----------|
| Orphan % | `xref_graph.orphaned_files.length / inventory.total_content_files` | < 5% |
| Avg links/note | `xref_graph.summary.total_edges / inventory.total_content_files` | > 3 |
| Tag sprawl ratio | `tags.unrecognized.length / Object.keys(tags.in_use).length` | < 10% |
| Frontmatter consistency | Files with `frontmatter_status: ok` / total content files | > 95% |
| Max folder depth | Glob deepest path, count `/` segments from vault root | <= 5 |
| File distribution Gini | Distribution of files across `inventory.by_type` categories | < 0.6 |
| Pipeline coverage | Files with `processed: true` or equivalent / applicable files | > 90% |
| RDT branch utilization | Count files routed to each Routing Decision Tree branch | No dead branches |
| Skill automation coverage | Vault operations mapped to automating skill vs "manual" | > 70% |
| Content duplication score | Grep for repeated H2+ headers or paragraph fingerprints across files | < 3% |
| Pending issue age | Average days since `pending_issues[].since` | < 14 days |
| Scan recency | Days since `scan_state.last_full_scan` | < 14 days |

### Dimension 2: Structural Analysis

Directory patterns, depth, and balance. Main thread analysis (requires cross-cutting judgment).

**Examines:**
- Directory tree shape: balance across the user's declared top-level grouping (`manifest.vault.top_level_folder`)
- Empty directories (signal vs noise)
- Naming convention adherence across all levels
- Archive utilization: is content being archived on schedule?
- File-to-folder ratio: are folders earning their keep?

**Classifies findings as:** `aligned` (matches VA.md intent), `drift` (evolved away from spec), `opportunity` (could be improved)

### Dimension 3: Content Organization

File-type alignment, reference tiers, duplication, and navigation quality.

**Examines:**
- File type distribution: are types correctly classified per path-pattern matching?
- Reference tier usage: Tier 1 (Reference/), Tier 2 (Engagement Reference.md), Tier 3 (Project Context.md) — are they used appropriately?
- Content duplication: same information in multiple places (Context vs PRD, Reference vs Context)
- Navigation effectiveness: can Claude find information in 1-2 hops from root CLAUDE.md?
- Context files: do they function as navigation indexes or have they accumulated content that belongs elsewhere?

### Dimension 4: Information Flow

Routing effectiveness, dead ends, and intake pipeline analysis.

**Examines:**
- Routing Decision Tree coverage: are all 9 branches producing output? Which are underused?
- Dead-end files: content with no outbound links (terminal nodes in the knowledge graph)
- Intake pipeline analysis: how effectively are digest-run, meeting-processor, process-notes converting raw input to structured vault content?
- Cross-channel flow: does information from the user's declared intake sources (`manifest.vault.intake_channels[]`) flow correctly through declared pipeline stages (`manifest.vault.pipeline_stages[]`)?
- Stale intake: content that entered the vault but was never processed further

### Dimension 5: Rules & Processes

Behavioral rule coverage, processing rule gaps, and cadence adherence. Main thread analysis.

**Examines:**
- Behavioral rules in vault CLAUDE.md: are they all still accurate and observed?
- Processing rules in VA.md: do they cover all content types that actually enter the vault?
- Pre-write validation: are the 13 checks sufficient? Are any redundant?
- Cadence adherence: are daily/weekly/periodic activities happening on schedule?
- Rule conflicts: do any rules contradict each other?

### Dimension 6: Skill & Automation

Coverage map, composition analysis, gap detection, and new skill proposals. Highest-value dimension.

**Process:**
1. **Skill inventory** — Read `Skills/_index.md`. Extract each skill's purpose, reads/writes, integrations, and status.
2. **Coverage map** — Enumerate ALL vault operations (from processing rules, cadences, behavioral rules, intake pipelines). Map each operation to its automating skill or "manual". The coverage map is mandatory.
3. **Composition analysis** — Identify overlaps, gaps, and missing handoffs between skills. Which skills call which? Where does the chain break?
4. **Automation opportunity scan** — Detect repetitive manual patterns that could be skill-ified. Look at: the user's most common edits, frequently flagged librarian issues, operations that always follow the same steps.
5. **Gap scan** — Operations in the coverage map marked "manual" that could be automated.

**Every skill proposal must reference a gap in the coverage map.**

**Skill health interop (split 2026-04-21):** Mechanical frontmatter parity comes from the **librarian `skill-parity`** capability — read `drift_findings.skill_parity` from `Logs/librarian-manifest.json` for the current mechanical gap inventory. Per-skill LLM-judgment review lives in `/skill-optimizer --skill {name}` which writes `Logs/skill-review-{name}-{date}.md` on demand. If a recent skill-review brief exists for a skill in scope, reference it rather than re-auditing intent alignment or benchmarking; otherwise note that `/skill-optimizer --skill {name}` should be run for deeper analysis.

### Dimension 7: External Research

Best practices from the broader Obsidian/PKM ecosystem and Claude Code community. Informational only.

**Search targets:**
- Obsidian community plugins and workflows relevant to vault management
- PKM methodologies (PARA, Zettelkasten, etc.) that might improve organization
- Claude Code community patterns for skill composition and vault management
- Any relevant tooling updates (MCP servers, Obsidian plugins, Claude features)

**Uses:** WebSearch, WebFetch. If unavailable, skip and note in report.

---

## Skill-Focused Analysis Mode (`--skill {name}`)

Deep-dive analysis of a single skill and its immediate dependency graph. Goes extra deep compared to standard dimensions — this is not a surface scan.

### Data Sources (Skill Mode)

For the target skill, load ALL of:
1. **Backend runtime:** `{CLAUDE_HOME}/skills/{name}/SKILL.md` (full read, not summary)
2. **Vault design spec:** `{VAULT_ROOT}/Skills/{name}.md`
3. **Vault runtime copy:** `{VAULT_ROOT}/.claude/skills/{name}.md`
4. **Plan files:** `{PLANS_ROOT}/*{name}*` (any plan referencing this skill)
5. **Memory entries:** `{MEMORY_DIR}/*{name}*` (resolved at runtime via `lib/paths.sh::resolve_memory_dir`)
6. **Hook references:** Grep `{CLAUDE_HOME}/hooks/` and `{CLAUDE_HOME}/settings.json` for the skill name
7. **Manifest entry:** `backend_sync.skill_runtimes[{name}]`
8. **System Backlog entry:** Row referencing this skill
9. **Skills Index entry:** `Skills/_index.md` row for this skill
10. **Logs:** `{VAULT_LOGS}/*{name}*` (previous runs, session-close mentions)

### Analysis (5 Parts)

#### Part 1: Skill Anatomy
- Config quality: frontmatter fields, argument-hint completeness, disable-model-invocation setting
- Intent clarity: does the description accurately reflect what the skill does? Are invocation modes well-documented?
- Completeness: are all code paths described? Are edge cases handled (missing data, stale inputs, concurrent access)?
- Hard rules: are they sufficient? Are any missing given the skill's write surface?
- Output format: is it well-specified? Does it match actual output from logs?

#### Part 2: Dependency Map
- **Reads:** What data sources does this skill consume? (manifest, vault files, external APIs, other skill outputs)
- **Writes:** What does it produce? (vault files, logs, manifest updates, state files)
- **Composes with:** Which skills call this one, or are called by it? (trace the chain)
- **Gated by:** Which hooks fire on this skill's operations? (PreToolUse guards, PostToolUse tracking)
- **Shared state:** What mutable state does this skill share with others? (manifest, Tasks.md, registry)

Build a dependency diagram (text-based) showing the skill at center with all connections.

#### Part 3: Integration Surface
- How does this skill fit into the broader skill ecosystem? Map to `Skills/_index.md`.
- Identify handoff points: where does this skill's output become another skill's input?
- Identify gaps: are there manual steps between this skill and its neighbors that could be automated?
- Composition friction: are there format mismatches, stale assumptions, or missing contracts between this skill and its dependencies?

#### Part 4: Optimization Analysis
- Performance: are there redundant reads, unnecessary full scans, or missing caching opportunities?
- Robustness: what happens when inputs are missing, stale, or malformed? Does it fail gracefully?
- Scope creep: has the skill accumulated responsibilities that should be separated?
- Simplification: are there sections that could be removed or consolidated without losing functionality?

#### Part 5: External Research (Deep)
- Search for 3-5 patterns from the broader ecosystem relevant to this skill's specific domain
- Compare against similar tools, plugins, or workflows in the Obsidian/PKM/Claude Code community
- Look for anti-patterns this skill might be exhibiting
- **Go deeper than standard Dimension 7**: follow references, read documentation, compare implementations

### Agent Dispatch (Skill Mode)

| Agent | Part | Key Tools | Launch |
|-------|------|-----------|--------|
| Anatomy | 1. Skill Anatomy | Read, Grep | Immediate |
| Dependencies | 2. Dependency Map | Read, Grep, Glob | Immediate |
| Integration | 3. Integration Surface | Read, Grep | Immediate |
| Research | 5. External Research | WebSearch, WebFetch | Immediate |
| Main thread | 4. Optimization, Synthesis | Read | After agents complete |

All 4 agents launch immediately. Main thread runs Part 4 (requires cross-cutting judgment from Parts 1-3) then synthesizes.

### Output (Skill Mode)

Report written to `{architect.output_dir}/architect-{YYYY-MM-DD}-{skill-name}.md` (default `{architect.output_dir}` resolves to `{VAULT_LOGS}`):

```yaml
---
type: architect-report
subtype: skill-analysis
date: YYYY-MM-DD
timestamp: ISO
target-skill: {name}
dependencies-mapped: N
recommendations-total: N
quick-wins: N
structural: N
exploratory: N
---
```

Sections: Skill Anatomy → Dependency Map (with diagram) → Integration Surface → Optimization Analysis → External Research → Recommendations → Summary.

Recommendations use the same `[R-NNN]` format as standard reports, plus a new **Skill Enhancement Proposal** format when applicable.

---

## Adaptive Depth Mode (`--adaptive`)

Progressive elaboration: scan shallow first, then invest time only where signal density is high.

### Process

1. **Phase 1 — Quick Scan (all dimensions):** Read manifest + 5 spot-reads per dimension. Produce preliminary issue counts.
2. **Phase 2 — Score:** For each dimension, compute signal density = `issues_found / items_checked`. Classify:
   - **Hot** (density > 20%): Deep dive — expand scope to full vault for this dimension, run all sub-checks
   - **Warm** (density 5-20%): Standard analysis — normal depth as in non-adaptive mode
   - **Cool** (density < 5%): Summary only — report the quick-scan numbers, skip deep analysis
3. **Phase 3 — Targeted Deep Dive:** Re-dispatch agents only for Hot dimensions with expanded scope. Skip Cool dimensions entirely.
4. **Phase 4 — Synthesis:** Combine all findings. Note which dimensions were Hot/Warm/Cool and why.

### Output Additions

Report includes a **Depth Allocation** table:

```
## Depth Allocation

| Dimension | Quick-Scan Issues | Items Checked | Signal Density | Depth |
|-----------|-------------------|---------------|----------------|-------|
| Metrics | 4 | 12 | 33% | Hot — full deep dive |
| Structure | 1 | 20 | 5% | Warm — standard |
| Content | 0 | 15 | 0% | Cool — summary only |
| Flow | 3 | 8 | 38% | Hot — full deep dive |
| Rules | 1 | 13 | 8% | Warm — standard |
| Skills | 2 | 24 | 8% | Warm — standard |
| Research | — | — | — | Always runs |
```

This prevents over-investment in healthy dimensions and concentrates effort where it matters.

---

## Recommendation Validation Gate

Before any recommendation enters the final report, it passes through a 4-check validation:

| # | Check | Method | Fail Action |
|---|-------|--------|-------------|
| 1 | **Rule check** | Does this recommendation conflict with any rule in Vault Architecture.md or skill hard rules? | Drop the recommendation. |
| 2 | **History check** | Has a similar recommendation appeared in a previous architect report? If so, was it implemented or rejected? | If rejected: drop. If implemented: check if issue recurred (systemic). If never acted on: flag as recurring. |
| 3 | **Impact check** | What files, skills, and systems does this affect? Grep for downstream references to every entity mentioned in the recommendation. | If blast radius > 10 files or > 3 skills: escalate to `structural` category regardless of initial classification. |
| 4 | **External validation** | For `structural` and `exploratory` recommendations: search for community experience with similar patterns. Does evidence support the approach? | If no supporting evidence and no clear first-principles argument: downgrade to `exploratory` with a confidence caveat. |

### Confidence Scoring

Each recommendation receives a confidence tag based on validation results:

- **High confidence:** All 4 checks pass. Recommendation is well-grounded.
- **Medium confidence:** 3 checks pass. One caveat noted inline.
- **Low confidence:** ≤2 checks pass. Recommendation included only in `exploratory` category with explicit caveats.

The validation gate runs on the main thread after all dimension agents complete and before the report is written. It is not optional — every recommendation passes through it.

---

## Agent Dispatch

| Agent | Dimension | Key Tools | Launch |
|-------|-----------|-----------|--------|
| Metrics | 1. Metrics Collection | Glob, Grep, Read, Bash | Immediate |
| Content | 3. Content Organization | Read, Grep | Immediate |
| Flow | 4. Information Flow | Read, Grep, Glob | Immediate |
| Skills | 6. Skill & Automation | Read | Immediate |
| Research | 7. External Research | WebSearch, WebFetch | Immediate |
| Main thread | 2. Structure, 5. Rules, Synthesis | Read | After agents complete |

All 5 agents launch immediately in parallel. Main thread waits for agents, then runs Dimensions 2 and 5, then synthesizes all findings into recommendations.

**`--focus` mapping:** Each focus value dispatches only its corresponding agent. `--focus metrics` dispatches Metrics agent only. `--focus skills` dispatches Skills agent only. Main thread dimensions (`structure`, `rules`) run on the main thread without agents.

---

## Convergence Metrics

When `--compare {previous-report}` is provided:

1. Load the previous report's metrics section
2. For each metric, compute directional change: improving, stable, degrading
3. Check manifest `scan_state.findings_by_capability` — are issue counts trending down across the last 3+ runs?
4. Produce a **Trend** section:

```
## Convergence

| Metric | Previous | Current | Direction |
|--------|----------|---------|-----------|
| Orphan % | 8.2% | 5.1% | Improving |
| Frontmatter consistency | 91% | 96% | Improving |
| Tag sprawl ratio | 15% | 12% | Improving |
| Pending issue age | 21d | 18d | Improving |

Overall: System is converging. 3 of 4 tracked metrics improving.
```

If 3+ runs show consistent improvement, call it out as positive convergence. If metrics plateau or regress, flag the specific areas.

---

## Output Format

Report written to:
- Standard: `{architect.output_dir}/architect-{YYYY-MM-DD}.md`
- Skill mode: `{architect.output_dir}/architect-{YYYY-MM-DD}-{skill-name}.md`

(Default `{architect.output_dir}` resolves to `{VAULT_LOGS}` from `manifest.architect.output_dir`.)

```yaml
---
type: architect-report
subtype: full|skill-analysis    # "skill-analysis" when --skill used
date: YYYY-MM-DD
timestamp: ISO
target-skill: null|{name}       # populated when --skill used
dimensions-analyzed: [list]      # null for skill mode
adaptive-mode: false|true
focus: null|{dimension}
compared-to: null|{report-path}
recommendations-total: N
quick-wins: N
structural: N
exploratory: N
confidence-high: N
confidence-medium: N
confidence-low: N
---
```

Report body sections (in order):
1. **Vault Health Metrics** — table from Dimension 1
2. **Structural Findings** — narrative from Dimension 2
3. **Content Organization Findings** — narrative from Dimension 3
4. **Information Flow Findings** — narrative from Dimension 4
5. **Rules & Process Findings** — narrative from Dimension 5
6. **Skill & Automation Findings** — narrative + coverage map table from Dimension 6
7. **Convergence** — trend table (if `--compare`)
8. **Recommendations** — grouped by category (see below)
9. **External Research** — synthesis from Dimension 7
10. **Summary** — classification counts, top 3 recommendations, suggested next run date

---

## Recommendation Formats

### Standard Recommendation

```
### [R-NNN] {Title}

**Problem:** {What's wrong, with evidence — metrics, file paths, or pattern}
**Proposal:** {What to change}
**Category:** quick-win | structural | exploratory
**Classification:** structure | content | rules | skills | flow
**Affects:** {files, skills, or systems impacted}
**Trade-offs:** {cost, risk, or what gets worse}
**Implementation:** {concrete steps}
```

### New Skill Proposal

```
### [R-NNN] New Skill: {name}

**Trigger:** {when/how invoked}
**Purpose:** {what it does}
**Why:** {gap reference from coverage map}
**Replaces:** {manual operation or existing partial automation}
**Reads:** {input files/data}
**Writes:** {output files/data}
**Integrates:** {other skills it composes with}
**Complexity:** low | medium | high
**Priority:** P0 | P1 | P2
```

### Skill Enhancement Proposal

```
### [R-NNN] Enhance: {skill name}

**Current:** {what the skill does now}
**Proposed:** {what it should do}
**Why:** {gap reference or trend data}
**Affects:** {files, integrations changed}
**Complexity:** low | medium | high
```

---

## Output Contract

Per CLAUDE.md skill-creation rules: every vault-writing skill declares files written, schema type, pre-write validation steps, and failure mode. Architect writes ONE artifact per invocation — its own report — and never modifies vault content, skill specs, or configuration files (Hard Rule 1).

- **Files written:**
  - Standard mode: `{architect.output_dir}/architect-{YYYY-MM-DD}.md` (default `{architect.output_dir}` resolves to `{VAULT_LOGS}` from `manifest.architect.output_dir`)
  - Skill mode (`--skill {name}`): `{architect.output_dir}/architect-{YYYY-MM-DD}-{skill-name}.md`
  - Both targets are append-once-per-day; same-day re-invocations overwrite the existing file.

- **Schema type:** `architect-report` (validated against `vault-schema.json` `type` enum entry; frontmatter must carry `type: architect-report` + `subtype: full|skill-analysis` + the report-specific fields documented in §Output Format).

- **Pre-write validation:**
  1. Frontmatter completeness — `type`, `subtype`, `date`, `timestamp`, `recommendations-total`, confidence-tier counts must be populated; missing fields block the write.
  2. Vault-schema validation — frontmatter parses against `vault-schema.json` `architect-report` entry; type-mismatch blocks the write.
  3. Recommendation-validation gate — every `[R-NNN]` (or `[AR-NNN]` post-SP05 T-4 lockstep) item passes the 4-check gate (rule / history / impact / external) before inclusion in the report (§Recommendation Validation Gate).
  4. Coverage Map presence — Dimension 6 must include a Coverage Map table; missing-coverage-map blocks the write (Hard Rule 8).

- **Failure mode:** **block-and-log** — never "write and hope". On validation failure: emit a structured diagnostic to `{VAULT_LOGS}/architect-error-{YYYY-MM-DD}.md` (payload + failed-validation-class + remediation hint) and abort the report write. The user sees the diagnostic path in the run summary; they choose whether to address the failure manually or re-invoke `/architect` once upstream data (manifest, vault state) is corrected.

---

## Hard Rules

1. **Propose, never modify.** Writes only to `Logs/` (its own report). Never edits vault content, skill specs, or configuration files.
2. **Manifest is the data layer.** Never scan the vault directly when manifest data suffices. The manifest is the primary data source.
3. **If manifest is stale (>24h), refresh first.** Tell the user, run `/librarian`, then proceed.
4. **Previous reports are reference, not source of truth.** Each run re-analyzes from current manifest. Don't carry forward stale recommendations.
5. **External research is informational.** Never recommend changes solely because "the Obsidian community does it."
6. **Ground in data.** Every recommendation cites metrics, file paths, or research. No vibes-based proposals.
7. **Respect design intent.** Acknowledge original rationale (from VA.md version history, skill build history) before proposing changes. Evolution, not revolution.
8. **Coverage map is mandatory.** The backbone of Dimension 6. Every skill proposal must reference a gap in it.
