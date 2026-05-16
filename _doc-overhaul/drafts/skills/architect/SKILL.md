---
name: architect
description: Strategic vault system review. Reads the librarian manifest plus skill index plus prior architect reports and produces a dated recommendations report across seven dimensions. Read-only — proposes changes, never makes them.
disable-model-invocation: false
argument-hint: "[--skill {name}] [--focus {dimension}] [--compare {report-path}] [--adaptive] [--verbose]"
---
> **BLOCKED-BY-REDERIVATION** — see `_doc-overhaul/REDERIVATION-REQUIRED.md`


# Architect

Strategic advisor for your vault. Analyzes the system across seven dimensions, optionally measures convergence over time, and writes a single report with confidence-tagged recommendations. Reads from the librarian manifest, your Vault Architecture document, the skills index, the System Backlog, and prior architect reports. Proposes; never modifies.

## Invocation

`/architect [flags]`

| Command | Runs | Scope |
|---|---|---|
| `/architect` | Full 7-dimension analysis. | Full vault (via manifest). |
| `/architect --skill {name}` | Deep single-skill analysis. | Target skill plus dependency graph. |
| `/architect --focus {dimension}` | Single-dimension deep dive. | Full vault. |
| `/architect --compare {report-path}` | Full analysis plus convergence tracking. | Full vault plus previous report. |
| `/architect --adaptive` | Full analysis with progressive depth. | Full vault (depth varies per dimension). |
| `/architect --verbose` | Full analysis with raw data tables. | Full vault. |

Flags combine: `/architect --adaptive --compare {path}` or `/architect --skill librarian --verbose`.

**Dimensions:** `metrics`, `structure`, `content`, `flow`, `rules`, `skills`, `research`

## Data sources

Curly-brace tokens (`{VAULT_ROOT}`, `{VAULT_LOGS}`, `{CLAUDE_HOME}`, `{PLANS_ROOT}`, `{architect.output_dir}`) are resolved at runtime from `user-manifest.json` via `lib/paths.sh`.

| Source | What it provides | Required? | First-run fallback |
|---|---|---|---|
| `{VAULT_LOGS}/librarian-manifest.json` | Current vault state — inventory, top-level grouping, tags, xref graph, scan history, pending issues. | Yes (PRIMARY) | If absent: tell the user to run `/librarian full`; cannot proceed. |
| `{VAULT_LOGS}/session-close-*.md` | Session audit history, error trends. | No | Empty set. |
| `{VAULT_LOGS}/librarian-*.md` | Librarian run logs over time. | No | Empty set. |
| `{VAULT_ROOT}/{VAULT_ARCHITECTURE_DOC}` | The rules — structure, conventions, routing, frontmatter specs (filename resolved from `manifest.vault.architecture_doc`). | Yes | If absent: note in report; analyze without rules-context. |
| `{VAULT_ROOT}/Skills/_index.md` | Automation landscape. | Yes | If absent: note in report; the Skills dimension reduces to "no automation declared". |
| `{VAULT_ROOT}/System Backlog.md` | System project portfolio — status, dependencies, cross-project conflicts. | Yes | If absent: note in report; the Skills dimension runs without backlog cross-reference. |
| `{VAULT_LOGS}/architect-*.md` | Previous architect reports for convergence. | Only with `--compare` | If absent with `--compare`: warn the user; run as if no prior report. |

If the manifest is stale (> 24 h), the architect tells you and refuses to proceed until you run `/librarian` to refresh. If the manifest is missing, the architect refuses outright.

---

## Analysis dimensions

### Dimension 1 — Metrics

Quantitative vault health, computed from manifest data plus targeted reads.

| Metric | How computed | Benchmark |
|---|---|---|
| Orphan % | `xref_graph.orphaned_files.length / inventory.total_content_files` | < 5% |
| Avg links/note | `xref_graph.summary.total_edges / inventory.total_content_files` | > 3 |
| Tag sprawl ratio | `tags.unrecognized.length / Object.keys(tags.in_use).length` | < 10% |
| Frontmatter consistency | Files with `frontmatter_status: ok` / total content files | > 95% |
| Max folder depth | Glob deepest path, count `/` segments from vault root | ≤ 5 |
| File-distribution Gini | Distribution across `inventory.by_type` categories | < 0.6 |
| Pipeline coverage | Files with `processed: true` or equivalent / applicable files | > 90% |
| RDT branch utilization | Files routed to each Routing Decision Tree branch | No dead branches |
| Skill automation coverage | Vault operations mapped to a skill vs "manual" | > 70% |
| Content duplication score | Repeated H2+ headers or paragraph fingerprints across files | < 3% |
| Pending issue age | Average days since `pending_issues[].since` | < 14 days |
| Scan recency | Days since `scan_state.last_full_scan` | < 14 days |

### Dimension 2 — Structure

Directory patterns, depth, balance. Cross-cutting judgment runs on the main thread.

Examines:
- Directory tree shape: balance across the user's declared top-level grouping (`manifest.vault.top_level_folder`).
- Empty directories (signal vs noise).
- Naming convention adherence at every level.
- Archive utilization: is content being archived on schedule?
- File-to-folder ratio: are folders earning their keep?

Classifies findings as `aligned` (matches the architecture doc's intent), `drift` (evolved away from spec), or `opportunity` (could be improved).

### Dimension 3 — Content organization

File-type alignment, reference tiers, duplication, and navigation quality.

Examines:
- File type distribution: are types correctly classified per path-pattern matching?
- Reference tier usage: Tier 1 (`Reference/`), Tier 2 (engagement reference docs), Tier 3 (project context docs) — used appropriately?
- Content duplication: same information in multiple places.
- Navigation effectiveness: can Claude find information in 1–2 hops from the root `CLAUDE.md`?
- Context files: do they function as navigation indexes, or have they accumulated content that belongs elsewhere?

### Dimension 4 — Information flow

Routing effectiveness, dead ends, intake pipeline analysis.

Examines:
- Routing Decision Tree coverage: are all branches producing output? Which are underused?
- Dead-end files: terminal nodes in the knowledge graph.
- Intake-pipeline effectiveness: how well do the connectors / meeting-processor / inbox-processor convert raw input to structured vault content?
- Cross-channel flow: does information from declared intake channels flow correctly through declared pipeline stages?
- Stale intake: content that entered the vault but was never processed further.

### Dimension 5 — Rules and processes

Behavioral rule coverage, processing rule gaps, cadence adherence. Runs on the main thread.

Examines:
- Behavioral rules in vault `CLAUDE.md`: still accurate? Still observed?
- Processing rules in the architecture doc: cover all content types that actually enter the vault?
- Pre-write validation: are the active rules sufficient? Are any redundant?
- Cadence adherence: are daily / weekly / periodic activities happening on schedule?
- Rule conflicts: do any rules contradict each other?

### Dimension 6 — Skill and automation

Coverage map, composition analysis, gap detection, new-skill proposals. Highest-value dimension.

Process:
1. **Skill inventory.** Read `Skills/_index.md`. Extract each skill's purpose, reads/writes, integrations, status.
2. **Coverage map.** Enumerate every vault operation (from processing rules, cadences, behavioral rules, intake pipelines). Map each to its automating skill or to `manual`. The coverage map is mandatory.
3. **Composition analysis.** Identify overlaps, gaps, missing handoffs. Which skills call which? Where does the chain break?
4. **Automation opportunity scan.** Detect repetitive manual patterns that could be skill-ified.
5. **Gap scan.** Operations marked `manual` that could be automated.

**Every skill proposal must reference a gap in the coverage map.**

For mechanical frontmatter parity across skills, read `drift_findings.skill_parity` from the librarian manifest. Per-skill judgment review lives in `/skill-optimizer --skill {name}`.

### Dimension 7 — External research

Best practices from the broader Obsidian / PKM ecosystem and Claude Code community. Informational only.

Search targets:
- Obsidian community plugins and workflows relevant to vault management.
- PKM methodologies (PARA, Zettelkasten, etc.).
- Claude Code community patterns for skill composition and vault management.
- Tooling updates (MCP servers, Obsidian plugins, Claude features).

**Try/skip pattern.** Wrap WebSearch + WebFetch invocations in try/skip. On any failure (no network, tool unavailable, rate limit, non-zero exit, timeout), emit the dimension section with the literal note `> External research unavailable in this environment (no network / tool access); skipped.` and continue. **Never cascade-fail the run on Dimension 7 errors** — this dimension is informational and must not block report emission.

---

## Skill-focused mode (`--skill {name}`)

Deep dive into one skill plus its immediate dependency graph.

### Data sources (skill mode)

For the target skill, load all of:
1. **Backend runtime:** `{CLAUDE_HOME}/skills/{name}/SKILL.md` (full read).
2. **Vault design spec:** `{VAULT_ROOT}/Skills/{name}.md`.
3. **Vault runtime copy:** `{VAULT_ROOT}/.claude/skills/{name}.md`.
4. **Plan files:** `{PLANS_ROOT}/*{name}*`.
5. **Memory entries:** `{MEMORY_DIR}/*{name}*` (resolved at runtime).
6. **Hook references:** Grep `{CLAUDE_HOME}/hooks/` and `{CLAUDE_HOME}/settings.json` for the skill name.
7. **Manifest entry:** `backend_sync.skill_runtimes[{name}]`.
8. **System Backlog entry:** Row referencing this skill.
9. **Skills Index entry:** `Skills/_index.md` row.
10. **Logs:** `{VAULT_LOGS}/*{name}*`.

### Analysis (5 parts)

**Part 1: Skill anatomy.** Config quality (frontmatter completeness, argument-hint, `disable-model-invocation`), intent clarity, completeness of code-path coverage, hard rules sufficiency, output-format specification.

**Part 2: Dependency map.** What this skill reads, writes, composes with, is gated by, and shares mutable state with.

**Part 3: Integration surface.** How the skill fits into the broader ecosystem; handoff points; gaps; composition friction.

**Part 4: Optimization analysis.** Performance, robustness, scope creep, simplification opportunities.

**Part 5: External research (deep).** 3–5 patterns from the broader ecosystem; comparison to similar tools; anti-patterns; documentation follow-ups.

### Agent dispatch (skill mode)

| Agent | Part | Tools | Launch |
|---|---|---|---|
| Anatomy | 1 | Read, Grep | Immediate |
| Dependencies | 2 | Read, Grep, Glob | Immediate |
| Integration | 3 | Read, Grep | Immediate |
| Research | 5 | WebSearch, WebFetch | Immediate |
| Main thread | 4, synthesis | Read | After agents complete |

### Output (skill mode)

Report at `{architect.output_dir}/architect-{YYYY-MM-DD}-{skill-name}.md`:

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

Recommendations use the same `[AR-NNN]` format, plus a Skill Enhancement Proposal format when applicable.

---

## Adaptive depth (`--adaptive`)

Progressive elaboration: scan shallow first, invest time only where signal density is high.

1. **Quick scan (all dimensions).** Read manifest plus 5 spot-reads per dimension. Produce preliminary issue counts.
2. **Score.** For each dimension, compute signal density = `issues_found / items_checked`. Classify:
   - **Hot** (> 20%): deep dive — expand to full vault for this dimension.
   - **Warm** (5–20%): standard analysis.
   - **Cool** (< 5%): summary only — report quick-scan numbers; skip deep analysis.
3. **Targeted deep dive.** Re-dispatch agents only for Hot dimensions with expanded scope. Skip Cool dimensions entirely.
4. **Synthesis.** Combine all findings. Note which dimensions were Hot / Warm / Cool and why.

The report includes a Depth Allocation table:

```
## Depth Allocation

| Dimension | Quick-Scan Issues | Items Checked | Signal Density | Depth |
|-----------|-------------------|---------------|----------------|-------|
| Metrics   | 4                 | 12            | 33%            | Hot   |
| Structure | 1                 | 20            | 5%             | Warm  |
| Content   | 0                 | 15            | 0%             | Cool  |
...
```

Prevents over-investment in healthy dimensions and concentrates effort where it matters.

---

## First-scan behavior

The architect runs cleanly on a freshly-onboarded user with zero prior reports. Two implementation branches handle the empty-state path; both are detected from manifest state, not from a CLI flag.

**`--compare` short-circuit.** If `--compare` is passed (or auto-resolves from `manifest.architect.auto_compare: true`) and `librarian_manifest.architect_recommendations.last_scanned_log == null`, the Convergence section emits `> First scan, no prior data to compare.` and continues to Recommendations with an empty Convergence table. Exit code is 0.

**`--adaptive` natural downgrade (recommended default).** On a freshly-onboarded user, Dimensions 1 (Metrics) and 6 (Skills) naturally fall to **Cool** because the librarian's `findings_by_capability` is empty (no signal density) and `manifest.skills[]` lists only foundation-shipped skills (sparse coverage by definition, not by drift). Both dimensions produce shallow base-foundation summaries. This is expected first-scan behavior, not degradation; the Depth Allocation table reflects it explicitly.

There is no `--first-scan` flag. First-scan is detected from manifest state. `--adaptive` is the recommended default UX for first-scan and steady-state alike.

---

## Recommendation validation gate

Before any recommendation enters the final report, it passes through a 4-check validation:

| # | Check | Method | Fail action |
|---|---|---|---|
| 1 | Rule | Does this conflict with any rule in the architecture doc or skill hard rules? | Drop. |
| 2 | History | Has a similar recommendation appeared in a previous architect report? Was it implemented or rejected? | If rejected: drop. If implemented: check if the issue recurred (systemic). If never acted on: flag as recurring. |
| 3 | Impact | What files, skills, and systems does this affect? Grep for downstream references. | If blast radius > 10 files or > 3 skills: escalate to `structural` regardless of initial classification. |
| 4 | External | For `structural` and `exploratory` recommendations: does community evidence support the approach? | If no supporting evidence and no clear first-principles argument: downgrade to `exploratory` with a confidence caveat. |

### Confidence scoring

- **High confidence:** All 4 checks pass.
- **Medium confidence:** 3 checks pass. One caveat noted inline.
- **Low confidence:** ≤ 2 checks pass. Recommendation included only in `exploratory` with explicit caveats.

The validation gate runs on the main thread after all dimension agents complete and before the report is written. It is not optional.

---

## Agent dispatch (standard mode)

| Agent | Dimension | Tools | Launch |
|---|---|---|---|
| Metrics | 1 | Glob, Grep, Read, Bash | Immediate |
| Content | 3 | Read, Grep | Immediate |
| Flow | 4 | Read, Grep, Glob | Immediate |
| Skills | 6 | Read | Immediate |
| Research | 7 | WebSearch, WebFetch | Immediate |
| Main thread | 2, 5, synthesis | Read | After agents complete |

All 5 agents launch in parallel. The main thread waits, runs Dimensions 2 and 5, then synthesizes.

`--focus` mapping: each focus value dispatches only its corresponding agent.

---

## Convergence (`--compare`)

When `--compare {previous-report}` is provided:

1. Load the previous report's metrics section.
2. For each metric, compute directional change: improving / stable / degrading.
3. Check `scan_state.findings_by_capability` — are issue counts trending down across the last 3+ runs?
4. Produce a Convergence section:

```
## Convergence

| Metric                  | Previous | Current | Direction |
|-------------------------|----------|---------|-----------|
| Orphan %                | 8.2%     | 5.1%    | Improving |
| Frontmatter consistency | 91%      | 96%     | Improving |
| Tag sprawl ratio        | 15%      | 12%     | Improving |
| Pending issue age       | 21d      | 18d     | Improving |

Overall: System is converging. 3 of 4 tracked metrics improving.
```

If 3+ runs show consistent improvement, call it out as positive convergence. If metrics plateau or regress, flag the specific areas.

---

## Output format

Report written to:
- Standard: `{architect.output_dir}/architect-{YYYY-MM-DD}.md`
- Skill mode: `{architect.output_dir}/architect-{YYYY-MM-DD}-{skill-name}.md`

```yaml
---
type: architect-report
subtype: full|skill-analysis
date: YYYY-MM-DD
timestamp: ISO
target-skill: null|{name}
dimensions-analyzed: [list]
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

Body sections, in order:
1. Vault Health Metrics — table from Dimension 1.
2. Structural Findings — narrative from Dimension 2.
3. Content Organization Findings — narrative from Dimension 3.
4. Information Flow Findings — narrative from Dimension 4.
5. Rules & Process Findings — narrative from Dimension 5.
6. Skill & Automation Findings — narrative plus coverage map from Dimension 6.
7. Convergence — trend table (if `--compare`).
8. Recommendations — grouped by category.
9. External Research — synthesis from Dimension 7.
10. Summary — classification counts, top 3 recommendations, suggested next-run date.

---

## Recommendation formats

### Standard recommendation

```
### [AR-NNN] {Title}

**Problem:** {What's wrong, with evidence — metrics, file paths, or pattern}
**Proposal:** {What to change}
**Category:** quick-win | structural | exploratory
**Classification:** structure | content | rules | skills | flow
**Affects:** {files, skills, or systems impacted}
**Trade-offs:** {cost, risk, what gets worse}
**Implementation:** {concrete steps}
```

### New skill proposal

```
### [AR-NNN] New Skill: {name}

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

### Skill enhancement proposal

```
### [AR-NNN] Enhance: {skill name}

**Current:** {what the skill does now}
**Proposed:** {what it should do}
**Why:** {gap reference or trend data}
**Affects:** {files, integrations changed}
**Complexity:** low | medium | high
```

---

## Output Contract

The architect writes one artifact per invocation — its own report — and never modifies vault content, skill specs, or configuration files.

- **Files written:**
  - Standard: `{architect.output_dir}/architect-{YYYY-MM-DD}.md`
  - Skill mode: `{architect.output_dir}/architect-{YYYY-MM-DD}-{skill-name}.md`
  - Same-day re-invocations overwrite the existing file.
- **Schema type:** `architect-report` (validated against `vault-schema.json`'s `type` enum entry; frontmatter must carry `type: architect-report` plus `subtype: full|skill-analysis` plus the report-specific fields documented above).
- **Pre-write validation:**
  1. Frontmatter completeness — `type`, `subtype`, `date`, `timestamp`, `recommendations-total`, confidence-tier counts must be populated; missing fields block the write.
  2. Vault-schema validation — frontmatter parses against the `architect-report` entry; type-mismatch blocks the write.
  3. Recommendation-validation gate — every `[AR-NNN]` item passes the 4-check gate before inclusion.
  4. Coverage Map presence — Dimension 6 must include a Coverage Map table; missing-coverage-map blocks the write.
- **Failure mode — block-and-log.** Never "write and hope." On validation failure: emit a structured diagnostic to `{VAULT_LOGS}/architect-error-{YYYY-MM-DD}.md` (payload + failed-validation-class + remediation hint) and abort the report write.

---

## Hard rules

1. **Propose, never modify.** Writes only to `Logs/` (its own report). Never edits vault content, skill specs, or configuration files.
2. **Manifest is the data layer.** Never scan the vault directly when manifest data suffices.
3. **If manifest is stale (> 24 h), refresh first.** Tell the user, run `/librarian`, then proceed.
4. **Previous reports are reference, not source of truth.** Each run re-analyzes from current manifest. Don't carry forward stale recommendations.
5. **External research is informational.** Never recommend changes solely because "the Obsidian community does it."
6. **Ground in data.** Every recommendation cites metrics, file paths, or research. No vibes-based proposals.
7. **Respect design intent.** Acknowledge original rationale before proposing changes. Evolution, not revolution.
8. **Coverage map is mandatory.** The backbone of Dimension 6. Every skill proposal must reference a gap in it.

---

## See also

- [`skills/librarian/SKILL.md`](../librarian/SKILL.md) — the data layer the architect reads from.
- [`skills/onboarder/SKILL.md`](../onboarder/SKILL.md) — produces `architect.prior_seed[]` and `architect.research_topics[]` during Section F.
- [`docs/personalization-model.md`](../../docs/personalization-model.md) — what's universal vs personal across the auto-author output.
