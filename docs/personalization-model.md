# Personalization Model — Universal, Combined, Personal

**Audience:** users running `/onboard` or working in an adopted Claude
Foundations install. This doc explains what gets auto-authored at onboarding
time, what stays generic, and how to audit any generated artifact.

**Status:** authoritative for v2.0.0 (Plan 71 SP12 Tier-1 surfaces).
Re-generation workflow + per-user R-rule packs + `_index.md` autogeneration
are deferred to v2.1 (Tier 2; charter rows in Plan 71 master manifest).

---

## 1. The 3-tier model

Every artifact Claude Foundations ships falls into exactly one tier:

| Tier | What it means | Examples | Re-author cadence |
|---|---|---|---|
| **Universal** | Ships generic; identical for every user. No interview input changes the contents. | Hook scripts (`pre-write-guard.sh`), R-rule taxonomy, vault-schema.json `types[]` definitions, the `lib/three-step-gate.sh` library, every generic skill body. | Upstream-only; users get changes via `/adopt --refresh`. |
| **Combined** | Ships generic skeleton + onboarding fills personal slots. The skeleton is universal; the slot values are yours. | `~/.claude/CLAUDE.md` (universal sections from template + composed-prose personal sections from interview), vault `CLAUDE.md` (universal RDT shape + your declared organizational method drives which RDT branch renders), `doc-dependencies.json` (always-on cascades + structure-conditional cascades). | Re-runnable via `/onboard --section <X>`; existing user edits preserved. |
| **Personal** | Composed entirely from your interview answers. Generic-only baseline does not exist for these. | Memory seeds under `~/.claude/projects/<user>/memory/` (5 seeds), `vault.tag_prefixes[]`, `architect.prior_seed[]`, `architect.research_topics[]`, `vault.projects_root_dirname` and consumers, `_tag_prefixes` archetype-keyed selection. | Re-runnable; user edits to seed files mark `last_user_edit` and are skipped on re-author. |

The distinction matters because **only Combined and Personal artifacts carry
provenance frontmatter** — Universal ones are version-controlled in the
foundation-repo and have a git history instead. See §4 for the audit story.

---

## 2. Per-capability classification

Each shipped capability lives at exactly one tier. The artifacts a capability
*reads* may live at different tiers — what counts here is the capability's
own code.

| Capability / artifact | Tier | What's universal vs personalized |
|---|---|---|
| `librarian` (skill body) | Universal | The capability code (8 sub-capabilities + dispatcher) is identical for every user. Reads `vault.root`, `vault.tag_prefixes`, `vault.engagement_aliases`, `vault.required_fields_overrides`, `vault.architecture_doc` from your manifest at runtime. |
| `architect` (skill body) | Universal | The 7-dimension analysis code is identical. Reads `architect.prior_seed[]`, `architect.research_topics[]`, `architect.benchmarks{}` from manifest at runtime. SP12 T-10 auto-authors prior_seed + research_topics from your declared `identity.industry`. |
| `frontmatter-enforce.sh` | Universal (capability) + Personal (config) | Capability code is universal. The `FM_PROJECTS_ROOT_DIRNAME` env-var (sourced from `vault.projects_root_dirname`) parameterizes the projects-root regex patterns. SP12 T-9 removed all 12 hardcoded `Engagements/` literals; default fallback "Engagements" preserves backward compat. |
| `prompt-context.sh` (R-26 hook) | Universal (hook) + Combined (thresholds) | Hook is universal. Reads `hooks.context_pressure.{warn_pct, mandate_pct, hard_pct}` from manifest with sane defaults (45 / 48 / 80) when fields are absent or null. SP12 T-13 wires the manifest read; before T-13 the thresholds were hardcoded. |
| `doc-dependencies.json` (registry) | Combined | Always-on entries (system-backlog, vault-claude-md, plan-state) ship for every user. Conditional entries (engagement-list, people-list) ship when `vault.has_structured_projects: true` and your declared `organizational_method` matches. SP12 T-8 generates 3-5 entries per user. |
| Vault `CLAUDE.md` | Combined | Template ships universal frame (header, identity table, conventions, directory layout, working-with-Claude block). SP12 T-6 layers in a routing decision tree (RDT) tuned to your declared `vault.organizational_method` (Engagements / PARA / topic-based / fallback) plus a tag taxonomy section keyed off your `_tag_prefixes` plus a pre-write checklist tuned to your declared file types. |
| `~/.claude/CLAUDE.md` | Combined | SP10 T-4 ships the identity-substituted template (universal sections: Output Contracts, Plan Creation Conventions, Hard Constraints Override, Compact Instructions schema, Skill Creation Rules). SP12 T-4 layers in three composed-prose personal sections (Communication Style, Working Patterns, Feedback Preferences) sourced from your interview answers. |
| Memory seeds (`MEMORY.md` + 5 seed files) | Personal | SP11 T-3 writes the bootstrap shape (`MEMORY.md` skeleton with H2 routing + 5 seed files derived mechanically from Section A/C/D fields). SP12 T-5 enriches with LLM-composed prose using the Mirror Collision Contract (UPGRADE / SKIP / ABORT semantics; provenance lineage preserved). |
| `vault.tag_prefixes[]` (T-7 surface #4) | Personal | Archetype-keyed selection from `vault.tag_prefix_archetype` (Q-ID A-CB-7). consultant→engagement/project/scope; researcher→topic/paper/dataset; developer→project/repo/feature; educator→course/module/student; manager→team/project/kpi; custom→LLM-compose fallback. Merge mode (no clobber) when an existing prefix list is present. |
| `architect.prior_seed[]` + `research_topics[]` | Personal | Industry-tuned phrasing from `identity.industry`. Five known industries (consulting, research, software, education, product) plus a generic-fallback path. Each entry namespace-marked with `[sp12-t10:<industry>]` for downstream auditing. Additive merge preserves existing user content. |

---

## 3. What onboarding produces and why

The seven Tier-1 surfaces auto-authored at onboarding time, in the order the
flow runs them. Each surface sources interview input from a specific Q-ID
(Section A through E of the onboarder), passes through the three-step gate
(generate → preview/edit → apply), and writes to the path listed.

| # | Surface | Input Q-IDs | Output path | Tier |
|---|---|---|---|---|
| 1 | claude-home `CLAUDE.md` composed prose | A-1..A-4, A-CB-1..A-CB-6 | `~/.claude/CLAUDE.md` | Combined |
| 2 | Memory seeds (5 files + index) | A-1, A-CB-3, A-CB-5, B-3, behavioral.autonomy | `~/.claude/projects/<user>/memory/*.md` | Personal |
| 3 | Vault `CLAUDE.md` (RDT + taxonomy + checklist) | C-1..C-4 | `<vault>/CLAUDE.md` | Combined |
| 4 | `_tag_prefixes[]` (archetype-keyed) | A-CB-7 | `vault-schema.json._tag_prefixes` + `user-manifest.json::vault.tag_prefixes` | Personal |
| 5 | `doc-dependencies.json` cascade | C-1, C-2, C-3 | `~/.claude/hooks/config/doc-dependencies.json` | Combined |
| 6 | `frontmatter-enforce` per-capability config | C-2, C-4 | `user-manifest.json::vault.{projects_root_dirname, engagement_aliases, required_fields_overrides}` | Personal |
| 9 | Architect prior-seed + research topics | A-2 (industry), D-1, D-2 | `user-manifest.json::architect.{prior_seed, research_topics}` | Personal |

**Surfaces #7, #8, #10 are deferred to v2.1** (Tier 2). See §6 for what they
will do and why we did not ship them in v2.0.0.

---

## 4. How to audit a generated artifact

Every Combined and Personal artifact carries **provenance frontmatter** at
the top. The contract is documented at `docs/provenance-frontmatter.md` and
schema-validated against `schemas/provenance-frontmatter-schema.json`.

Three required fields:

| Field | Meaning | Example |
|---|---|---|
| `generated_by` | Surface that wrote the artifact (sp10-t4 / sp11-t3 / sp12-t4..sp12-t10). Lets you trace which onboarder pass produced this content. | `sp12-t5` |
| `generated_from` | Interview source — Q-ID(s) or section reference. Lets you audit which interview answers shaped the content. | `A-CB-3+behavioral.autonomy` |
| `last_user_edit` | ISO-timestamp of the most recent hand-edit (or `null` if untouched). Capabilities use this to decide regen-vs-preserve. If `last_user_edit > generated_by` timestamp, the content is treated as user-owned and regeneration SKIPS it. | `2026-04-15T09:30:00Z` |

To audit any artifact:

```bash
head -10 ~/.claude/projects/your-user/memory/user_*.md
# Look for the --- frontmatter block at the top.
```

Optional fields when an artifact has been re-authored (UPGRADE path):

| Field | Meaning |
|---|---|
| `superseded_by` | Surface that re-authored this artifact (e.g., `sp12-t5` when SP12 enriches an SP11 seed). |
| `original_sha256` | Pre-upgrade content hash. Lets you reconstruct the lineage. |
| `schema_version` | When the artifact carries its own schema-versioned content. |

JSON artifacts (`doc-dependencies.json`, `user-manifest.json`) cannot carry
YAML frontmatter without polluting their consumed schema. They use **file-level
provenance** under a top-level `_provenance` key (`doc-dependencies.json`) or
**per-entry namespace markers** prefixed to string content (e.g.,
`[sp12-t10:<industry>]` on architect prior_seed entries).

---

## 5. Re-generation semantics

**Re-generation is opt-in.** When you re-run an onboarder section, the
matching surface re-fires. The three-step gate previews the proposed change
*against your current artifact* before any write. You can edit the staging
file in `${EDITOR:-vi}` before applying.

User-edited content is preserved by two mechanisms:

1. **`last_user_edit` timestamp.** Capabilities that detect a `last_user_edit`
   newer than the original `generated_by` timestamp treat the content as
   user-owned and skip the regeneration path entirely. The Mirror Collision
   Contract (SP12 T-5) implements this for memory seeds — SKIP route logs
   the decision to the audit JSONL.

2. **Additive merge.** Surfaces that write into arrays (`vault.tag_prefixes`,
   `architect.prior_seed`, `architect.research_topics`,
   `vault.engagement_aliases`) use jq union semantics — proposed entries are
   added, existing entries are preserved.

The full regen-diff workflow (propose-then-apply across multiple surfaces in
one pass; conflict resolution UI) is **deferred to v2.1**. SP12 ships the
contract; v2.1 ships the orchestration layer.

---

## 6. What we deliberately did NOT auto-generate (and why)

### Skill bodies

Skill code (`librarian`, `architect`, `frontmatter-enforce`, hooks) ships
universal and stays universal. **Auto-authoring writes configs that generic
skills consume; it does NOT rewrite skill bodies.** This boundary holds
across SP12, v2.1, and v2.2.

Why: research evidence (`_audit-2026-05-03/07-R2-ai-assistant-onboarding.md`)
on every shipping competitor (Cursor, Continue.dev, Aider, Claude Code,
Custom GPTs, Replit) is decisive — none of them auto-generate skill code per
user. The maintenance bomb is: when an upstream skill ships an improvement,
every per-user fork drifts. The industry has implicitly rejected this pattern
and we agree.

### Tier 2 — deferred to v2.1

| Surface | What it would do | Why deferred |
|---|---|---|
| #7 — User-specific R-rule pack | Generate suggestions in `~/.claude/overrides/r-rules.d/` based on declared sensitivities. Mandatory user-validation gate before any rule promoted to blocking. | Validation-gate research (how to safely auto-suggest enforcement rules without bricking day-1 writes) is its own design problem. SP12 ships the advisory-default principle but not the generation pipeline. |
| #8 — `_index.md` autogeneration | Generate `_index.md` files for declared folder taxonomy with `provides:` frontmatter pre-filled. | Net-new generator capability. SP12 documents the convention (G8 in vault CLAUDE.md template) but doesn't ship the generator. |
| #10 — Conditional capability registration | Conditionally enable capabilities per declared tools (don't register `meeting-processor` if user didn't say they take meetings). | The conditional-registration mechanism is its own architectural decision (per-capability opt-in flags vs registry pruning vs runtime gating). v2.1 picks the path. |

### Tier 3 — deferred to v2.1+

- Re-generation orchestration (propose regen-diff vs silent rewrite UI)
- Provenance tracking for hand-edited vs generated content beyond the basic
  frontmatter contract (full diff-and-merge workflow)
- Memory-driven adaptive re-generation (capabilities consult memory for
  re-personalization triggers)

---

## Where to go next

- `docs/provenance-frontmatter.md` — the schema contract for `generated_by` /
  `generated_from` / `last_user_edit` fields.
- `docs/llm-cost-model.md` — per-surface token estimates and the cost-range
  derivation surfaced at onboarder start.
- `docs/r-37-lockstep-walkthrough.md` — the 5-surface commit pattern when
  you add a new vault file type.
- `docs/doc-dependencies-conventions.md` — cascade entry shape and the
  pre-write-guard consumer behavior.
