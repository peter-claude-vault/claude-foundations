# Personalization Model — Universal, Combined, Personal

Every artifact Claude Stem ships falls into one of three tiers: **Universal** (identical for every user), **Combined** (universal skeleton with onboarding-filled slots), and **Personal** (composed entirely from your interview answers). This document explains what gets auto-authored at onboarding time, what stays generic, and how to audit any generated artifact.

**Audience:** users running `/onboard` or working in an adopted Claude Stem install.

---

## 1. The 3-tier model

| Tier | What it means | Examples | Re-author cadence |
|---|---|---|---|
| **Universal** | Ships generic; identical for every user. No interview input changes the contents. | Hook scripts (`pre-write-guard.sh`), the rule taxonomy, vault-schema.json `types[]` definitions, the `lib/three-step-gate.sh` library, every generic skill body. | Upstream-only; users get changes via `/adopt --refresh`. |
| **Combined** | Ships generic skeleton; onboarding fills personal slots. The skeleton is universal; the slot values are yours. | `~/.claude/CLAUDE.md` (universal sections from template + composed-prose personal sections from interview), vault `CLAUDE.md` (universal routing-tree shape + your declared organizational method drives which branch renders), `doc-dependencies.json` (always-on cascades + structure-conditional cascades). | Re-runnable via `/onboard --section <X>`; existing user edits preserved. |
| **Personal** | Composed entirely from your interview answers. Generic-only baseline does not exist for these. | Memory seeds under `~/.claude/projects/<user>/memory/` (5 seeds), `vault.tag_prefixes[]`, `architect.prior_seed[]`, `architect.research_topics[]`, `vault.projects_root_dirname` and consumers, archetype-keyed `_tag_prefixes` selection. | Re-runnable; user edits to seed files mark `last_user_edit` and are skipped on re-author. |

The distinction matters because **only Combined and Personal artifacts carry provenance frontmatter** — Universal ones are version-controlled in the foundation-repo and have a git history instead. See §4 for the audit story.

---

## 2. Per-capability classification

Each shipped capability lives at exactly one tier. The artifacts a capability *reads* may live at different tiers — what counts here is the capability's own code.

| Capability / artifact | Tier | What's universal vs personalized |
|---|---|---|
| `librarian` (skill body) | Universal | The capability code (sub-capabilities + dispatcher) is identical for every user. Reads `vault.root`, `vault.tag_prefixes`, `vault.engagement_aliases`, `vault.required_fields_overrides`, `vault.architecture_doc` from your manifest at runtime. |
| `architect` (skill body) | Universal | The 7-dimension analysis code is identical. Reads `architect.prior_seed[]`, `architect.research_topics[]`, `architect.benchmarks{}` from manifest at runtime. The onboarder auto-authors prior_seed + research_topics from your declared `identity.industry`. |
| `frontmatter-enforce.sh` | Universal (capability) + Personal (config) | Capability code is universal. The `FM_PROJECTS_ROOT_DIRNAME` env var (sourced from `vault.projects_root_dirname`) parameterizes the projects-root regex patterns. There are no hardcoded folder-name literals; default fallback "Engagements" preserves backward compatibility. |
| `prompt-context.sh` (context-pressure hook) | Universal (hook) + Combined (thresholds) | Hook is universal. Reads `hooks.context_pressure.{warn_pct, mandate_pct, hard_pct}` from manifest with sane defaults (45 / 48 / 80) when fields are absent or null. |
| `doc-dependencies.json` (registry) | Combined | Always-on entries (system-backlog, vault-claude-md, plan-state) ship for every user. Conditional entries (engagement-list, people-list) ship when `vault.has_structured_projects: true` and your declared `organizational_method` matches. The onboarder generates 3-5 entries per user. |
| Vault `CLAUDE.md` | Combined | Template ships universal frame (header, identity table, conventions, directory layout, working-with-Claude block). The onboarder layers in a routing decision tree tuned to your declared `vault.organizational_method` (Engagements / PARA / topic-based / fallback) plus a tag taxonomy section keyed off your `_tag_prefixes` plus a pre-write checklist tuned to your declared file types. |
| `~/.claude/CLAUDE.md` | Combined | Ships the identity-substituted template (universal sections: Output Contracts, Plan Creation Conventions, Hard Constraints Override, Compact Instructions schema, Skill Creation Rules). The onboarder layers in three composed-prose personal sections (Communication Style, Working Patterns, Feedback Preferences) sourced from your interview answers. |
| Memory seeds (`MEMORY.md` + 5 seed files) | Personal | The bootstrap shape (`MEMORY.md` skeleton with H2 routing + 5 seed files derived mechanically from Section A/C/D fields) is written first. A second pass enriches with LLM-composed prose using the Mirror Collision Contract (UPGRADE / SKIP / ABORT semantics; provenance lineage preserved). |
| `vault.tag_prefixes[]` | Personal | Archetype-keyed selection from `vault.tag_prefix_archetype`. consultant→engagement/project/scope; researcher→topic/paper/dataset; developer→project/repo/feature; educator→course/module/student; manager→team/project/kpi; custom→LLM-compose fallback. Merge mode (no clobber) when an existing prefix list is present. |
| `architect.prior_seed[]` + `research_topics[]` | Personal | Industry-tuned phrasing from `identity.industry`. Five known industries (consulting, research, software, education, product) plus a generic-fallback path. Each entry namespace-marked for downstream auditing. Additive merge preserves existing user content. |

---

## 3. What onboarding produces and why

The seven personalization surfaces auto-authored at onboarding time, in the order the flow runs them. Each surface sources interview input from a specific Q-ID (Section A through E of the onboarder), passes through the three-step gate (generate → preview/edit → apply), and writes to the path listed.

| # | Surface | Input Q-IDs | Output path | Tier |
|---|---|---|---|---|
| 1 | claude-home `CLAUDE.md` composed prose | A-1..A-4, A-CB-1..A-CB-6 | `~/.claude/CLAUDE.md` | Combined |
| 2 | Memory seeds (5 files + index) | A-1, A-CB-3, A-CB-5, B-3, behavioral.autonomy | `~/.claude/projects/<user>/memory/*.md` | Personal |
| 3 | Vault `CLAUDE.md` (routing tree + taxonomy + checklist) | C-1..C-4 | `<vault>/CLAUDE.md` | Combined |
| 4 | `_tag_prefixes[]` (archetype-keyed) | A-CB-7 | `vault-schema.json._tag_prefixes` + `user-manifest.json::vault.tag_prefixes` | Personal |
| 5 | `doc-dependencies.json` cascade | C-1, C-2, C-3 | `~/.claude/hooks/config/doc-dependencies.json` | Combined |
| 6 | `frontmatter-enforce` per-capability config | C-2, C-4 | `user-manifest.json::vault.{projects_root_dirname, engagement_aliases, required_fields_overrides}` | Personal |
| 7 | Architect prior-seed + research topics | A-2 (industry), D-1, D-2 | `user-manifest.json::architect.{prior_seed, research_topics}` | Personal |

Three additional surfaces (user-specific R-rule pack, `_index.md` autogeneration, conditional capability registration) are deferred — see §6.

---

## 4. How to audit a generated artifact

Every Combined and Personal artifact carries **provenance frontmatter** at the top. The contract is documented at [provenance-frontmatter.md](provenance-frontmatter.md) and schema-validated against `schemas/provenance-frontmatter-schema.json`.

Three required fields:

| Field | Meaning | Example |
|---|---|---|
| `generated_by` | Surface that wrote the artifact. Lets you trace which onboarder pass produced this content. | `onboarder@v2.0.0` |
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
| `superseded_by` | Surface that re-authored this artifact. |
| `original_sha256` | Pre-upgrade content hash. Lets you reconstruct the lineage. |
| `schema_version` | When the artifact carries its own schema-versioned content. |

JSON artifacts (`doc-dependencies.json`, `user-manifest.json`) cannot carry YAML frontmatter without polluting their consumed schema. They use **file-level provenance** under a top-level `_provenance` key (`doc-dependencies.json`) or **per-entry namespace markers** prefixed to string content.

---

## 5. Re-generation semantics

**Re-generation is opt-in.** When you re-run an onboarder section, the matching surface re-fires. The three-step gate previews the proposed change *against your current artifact* before any write. You can edit the staging file in `${EDITOR:-vi}` before applying.

User-edited content is preserved by two mechanisms:

1. **`last_user_edit` timestamp.** Capabilities that detect a `last_user_edit` newer than the original `generated_by` timestamp treat the content as user-owned and skip the regeneration path entirely. The Mirror Collision Contract implements this for memory seeds — the SKIP route logs the decision to the audit JSONL.

2. **Additive merge.** Surfaces that write into arrays (`vault.tag_prefixes`, `architect.prior_seed`, `architect.research_topics`, `vault.engagement_aliases`) use jq union semantics — proposed entries are added, existing entries are preserved.

The full regen-diff workflow (propose-then-apply across multiple surfaces in one pass; conflict resolution UI) is **deferred to a future release**. The current contract is honored; the orchestration layer is not yet shipped.

---

## 6. What we deliberately did NOT auto-generate (and why)

### Skill bodies

Skill code (`librarian`, `architect`, `frontmatter-enforce`, hooks) ships universal and stays universal. **Auto-authoring writes configs that generic skills consume; it does NOT rewrite skill bodies.**

Why: the research evidence on every shipping competitor (Cursor, Continue.dev, Aider, Claude Code, Custom GPTs, Replit) is decisive — none of them auto-generate skill code per user. The maintenance bomb is: when an upstream skill ships an improvement, every per-user fork drifts. The industry has implicitly rejected this pattern and we agree.

### Deferred surfaces

| Surface | What it would do | Why deferred |
|---|---|---|
| User-specific rule pack | Generate suggestions in `~/.claude/overrides/r-rules.d/` based on declared sensitivities. Mandatory user-validation gate before any rule promoted to blocking. | Validation-gate research (how to safely auto-suggest enforcement rules without bricking day-1 writes) is its own design problem. The advisory-default principle ships now; the generation pipeline does not. |
| `_index.md` autogeneration | Generate `_index.md` files for declared folder taxonomy with `provides:` frontmatter pre-filled. | Net-new generator capability. The convention is documented; the generator is not yet shipped. |
| Conditional capability registration | Conditionally enable capabilities per declared tools (don't register `meeting-processor` if user didn't say they take meetings). | The conditional-registration mechanism is its own architectural decision (per-capability opt-in flags vs registry pruning vs runtime gating). |

### Further deferrals

- Re-generation orchestration (propose regen-diff vs silent rewrite UI).
- Provenance tracking for hand-edited vs generated content beyond the basic frontmatter contract (full diff-and-merge workflow).
- Memory-driven adaptive re-generation (capabilities consult memory for re-personalization triggers).

---

## Where to go next

- [provenance-frontmatter.md](provenance-frontmatter.md) — the schema contract for `generated_by` / `generated_from` / `last_user_edit` fields.
- [llm-cost-model.md](llm-cost-model.md) — per-surface token estimates and the cost-range derivation surfaced at onboarder start.
- [adding-a-vault-file-type.md](adding-a-vault-file-type.md) — the 5-surface commit pattern when you add a new vault file type.
- [doc-dependencies-conventions.md](doc-dependencies-conventions.md) — cascade entry shape and the pre-write-guard consumer behavior.
