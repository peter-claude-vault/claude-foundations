---
altitude: system
scope: Per-folder index file conventions. Why every folder in the vault carries an `_index.md`, what goes in it, how the underscore-prefix gets it to sort to the top of the folder listing, how it differs from `README.md`, which folders legitimately don't carry one, and how it stays in sync with the filesystem via the three-tier maintenance architecture.
validity_window: 2026-05-14..2026-11-14
source_dependencies:
  - companion: ./vault-construction-principles.md
  - companion: ./enforcement-map-design.md
  - companion: ./file-naming-conventions.md
  - companion: ./inbox-flow-architecture.md
  - governance: claude-stem/governance/mandatory-files-rules.json
  - capability: claude-stem/skills/librarian/capabilities/index-maintain.sh (Tier 2 + Tier 3 contract authored in this packet; implementation deferred to SP05)
  - external: Hugo branch-bundle convention (gohugo.io/content-management/page-bundles/)
  - external: mkdocs-material section-root index.md convention (squidfunk.github.io/mkdocs-material/)
last_reviewed: 2026-05-14
canonical_url: https://stem.peter.dev/research/vault-construction/_index.md-design/
url_stability: locked-from-2026-05-12
---

# `_index.md` design — per-folder index file conventions

## Theme

Folder-scoped navigation is a structural primitive. Every folder in the vault needs an entry-point document that answers three questions in the first paragraph: *what lives here*, *how is it organized*, *what should you look at first*. Without that document, the folder appears as a leaf in graph view, LLMs reading the folder have no orientation surface, and human readers fall back on filename-by-filename scanning — lossy, slow, stochastic across sessions.

`_index.md` is that entry-point. The convention is mandatory per the universal mandatory-file lock. The underscore-prefix is not decoration — it is a filesystem-sort hack that places the file at the top of the folder's alphabetical listing, so anything that walks a directory in lexical order (Obsidian's file pane, `ls`, file-tree viewers in IDEs) encounters the index before any content file. The same hack appears in Hugo's static-site-generator convention; the convergence is not coincidence.

## Vision / approach — five structural commitments

### 1. Every non-exempt folder carries an `_index.md` — auto-bootstrapped, not merely mandated

The universal mandatory-file lock makes `_index.md` non-optional at folder root. Principle: a folder without an index is a folder whose contents are not navigable except by filename inspection — works at three files, breaks at ten, unusable at fifty. A project folder with a dozen content files plus an `_index.md` is readable in 25 lines — each entry one line with file type, line count, and description — instead of opening every file at 100–700 lines each.

**The mandate is enforced structurally, not advisorily.** The post-write hook (§Maintenance architecture Tier 1) detects on every write whether the target folder lacks an `_index.md`; if the folder is non-exempt the hook auto-creates the file before reconciling the entry for the write that triggered it. Folder creation is not a separate event Claude Code surfaces as a hook — folders come into existence as side effects of file writes — so the first-write to a new folder IS the bootstrap trigger. The adopter never has to remember to author the index; the system creates it. Hand-creating a folder via `mkdir` without a subsequent write leaves no orphan because the librarian `index-maintain` sweep (Tier 2) catches it on the next periodic scan.

### 2. `_index.md` is the folder's API to readers

Both humans and LLMs read the index before doing anything else in the folder. The vault-root `CLAUDE.md` (§Behavioral Rules) names this explicitly: *"Index-first loading: Check `_index.md` before loading multiple files from an engagement directory. Use `provides` frontmatter to decide what to load."* The index is the gate that prevents context-budget waste on the wrong files.

### 3. Underscore-prefix is a filesystem-sort hack

`_` (0x5F in ASCII) sorts before alphanumeric characters in standard locale-aware sort orders. `_index.md` appears before `2026-01-15-meeting.md`, before `Action-Items.md`, before `Contact-Name.md`. Without the underscore, `index.md` would sort somewhere in the middle of the directory listing, defeating the index's purpose as the first thing a reader sees. The underscore-prefix sorts to top of directory listings in Obsidian and CLIs; the name is unambiguous versus a human-facing `README.md`.

### 4. `_index.md` is whitelisted infrastructure

The librarian's `placement-validate` capability whitelists `_index.md` at every directory level. The whitelist is structural: `_index.md` has a special filename (leading underscore + lowercase) that would otherwise fail vault file-naming conventions, but the librarian doesn't relocate or normalize it. The same whitelist applies to legacy `Logs/ideation-brief-*.md` symlink artifacts and legacy `Logs/build-*.md` files.

### 5. `_index.md` is distinct from `README.md`

The two conventions coexist; each does a different job for a different audience. The distinction matters because conflating them produces either bloat (one file trying to do both) or gaps. Locked in §Distinction below.

## Industry convergence — folder-bundled section landing pages

The folder-bundled section-landing-page pattern is the dominant 2026 convention across static-site generators and PKM systems:

- **Hugo** (gohugo.io/content-management/page-bundles/). `_index.md` is the canonical filename for *branch bundles* — a folder that renders as a list of its children. The underscore-prefix is Hugo's own convention; Hugo distinguishes branch bundles (`_index.md`, lists children) from leaf bundles (`index.md`, terminal page). The vault adopts the branch-bundle convention as the canonical name.
- **Obsidian Map-of-Content (MOC) pattern.** Obsidian has no native `_index.md` support — every `.md` file renders identically — but the PKM community converges on folder-level MOC notes as a navigation primitive. The vault uses `_index.md` as the MOC for every folder; the underscore-prefix is the local addition.
- **Static-site generators broadly.** Jekyll/mkdocs/Docusaurus use `index.md`; Hugo uses `_index.md`. Across the SSG ecosystem, *some* convention for a folder-landing-page exists; the underscore-prefix is Hugo's distinctive contribution.
- **mkdocs-material — the divergence to document.** The foundation-repo's GH Pages docs site uses mkdocs-material, which expects `index.md` (no underscore) at section roots. The divergence is intentional: the vault uses `_index.md` filesystem-side for the sort-to-top property; the docs site uses `index.md` at the rendering layer. The CI workflow bridges the two via rename or symlink at build time. Both filenames coexist without conflict because they live at different stages of the pipeline.

The architectural pattern across all four: **a folder needs an entry-point document, and the document's job is to enumerate the folder's contents and orient the reader.**

## Per-folder `_index.md` structure — locked

Every `_index.md` in the vault follows the same shape. Empirically derived from the reference-deployment corpus.

### Frontmatter (mandatory)

```yaml
---
type: index
parent_folder: <Cluster>/<Instance>          # MANDATORY at depth ≥ 2; OMIT at depth 1
tags:
  - "#<cluster-dim>/<instance-slug>"          # structural-dimension lineage; mirrors folder per folder-lineage convention
updated: 2026-05-14
---
```

Optional: `description:` (one-line scope description); `provides:` (cross-folder grep handle when this index is the canonical source for a domain).

**Field roles:**

| Field | Role |
|---|---|
| `type: index` | Maps to the canonical type enumeration in `schemas/vault-schema.json`; R-32 Tier 2 DENY rejects unknown types |
| `parent_folder:` | Path string relative to vault root, naming the parent folder of this `_index.md`. **Mandatory at depth ≥ 2** (any `_index.md` not directly under vault root). **Omitted at depth 1** (e.g., `<Cluster>/_index.md`, `<PersonalTracks>/_index.md` — the "parent" is the vault root itself, which is not a folder in the meaningful sense). Gives Claude a programmatic parent-pointer for index-tree traversal without path-parsing. Auto-populated by the bootstrap hook; librarian `index-maintain` audits for path-vs-frontmatter drift. |
| `tags:` | Mandatory because `_index.md` files participate in the folder-mirrors-tag invariant. Tag matches the folder's structural-dimension lineage — `Engagements/<X>/_index.md` carries `#engagement/<X>`; `Reference/_index.md` carries `#scope/reference` |
| `updated:` | ISO date; bumped by every machine-maintenance pass on the file |

**Structural-dimension lineage fields** (`engagement:`, `project:`, etc.) are inherited from the folder-lineage convention in [`frontmatter-design.md`](./frontmatter-design.md). An `_index.md` at `Engagements/CDMO DDX/People/_index.md` carries `engagement: cdmo-ddx` in frontmatter because every file at that path does. Folder-lineage is the content-side lineage convention answering "what engagement does this file belong to"; `parent_folder:` is the navigation-side parent pointer answering "where in the folder tree does this index sit." Different consumers, different jobs, both auto-populated.

### H1 heading (mandatory)

Matches the folder name or close variant. Examples: `Acme Corp`, `Reference — Tier 1`, `Skills Index`, `Data-Platform`. Reinforces the folder-mirrors-tag invariant — the heading reads like a tag value.

### Folder-context paragraph (mandatory)

2–4 sentences describing what lives in the folder, what doesn't, why the folder exists. Pedagogical — both humans and LLMs read this to orient. The paragraph is the **load-bearing** content of the index; without it, the file is regeneratable boilerplate. Example: *"CRM files for all contacts on the engagement. Each file covers role, org, interaction history, and relationship context."*

### Contents enumeration (mandatory, machine-maintained)

Tabular list of child files. Four columns; each earns its keep by mapping to a distinct load-decision input.

#### Why these columns

| Column | Encodes | Why Claude needs it |
|---|---|---|
| **File** | Wikilink to the artifact | Folder navigation — the unambiguous identifier; clickable from any Obsidian reader |
| **Lines** | Line count of the child file | Cost-to-load signal — token-budget approximation before Claude decides to read it |
| **Type** | Frontmatter `type:` value (canonical 26-enum, R-32-enforced) | Structural role identifier — distinguishes the engagement's `overview` from `reference` from `people` without needing separate sectioning |
| **Description** | One-line prose | What reading this file gives you in plain language |

The **`provides:` frontmatter field does NOT surface in this table.** It remains in each file's frontmatter as the cross-folder grep handle (R-39: `grep -r 'provides:.*<concept>'` finds every file declaring canonicality for a concept). Surfacing it per-row in the index duplicated `description:` in practice — same information in two formats — and the hand-authored table cells drifted from source-of-truth frontmatter the moment a file was added or renamed.

**Empirical example — engagement folder `_index.md` contents enumeration:**

```
| File | Lines | Type | Description |
|---|---|---|---|
| [[Acme - Overview.md]] | ~111 | overview | Scope, objectives, team structure |
| [[Acme - Context.md]] | ~67 | context | Current phase, key decisions, navigation cues |
| [[Acme - Updates.md]] | ~145 | updates | Reverse-chronological status log + decisions |
| [[Acme - Reference.md]] | ~141 | reference | Tech stack, vocabulary, meeting calendar |
```

Note the example carries no `CLAUDE.md` row. Per Session 16 lock #1, only the vault-root `CLAUDE.md` exists in the target architecture; engagement-level, folder-scoped, per-cluster, and per-instance `CLAUDE.md` classes are all retired. Engagement-level navigation is delivered by the `_index.md` itself (this file, plus the canonical Overview/Context/Updates trio); see [`claude-md-design.md`](./claude-md-design.md) for the one-class CLAUDE.md mandate.

**Key-file convention surfaced via type, not sectioning.** At engagement folders, the trio `overview` / `context` / `updates` carries primary context — Claude loads these first for any engagement task. At project folders, the trio is `prd` / `context` / `updates`. At about-me folders, `reference` is the dominant type and the `_index.md` itself plus the folder-context paragraph carry the orientation. Adopters learn the convention from the file-type column itself; the canonical type enumeration is small enough (26 values) and stable enough (R-32-enforced) that role-by-type is self-evident without a separate "key files" header.

For light-content folders, a prose "Current Contents" section replaces the table when enumeration would be premature.

### Cross-references (recommended)

Bottom-of-file links to parent `_index.md`, peer folders, related tags. Bridges hierarchical (filesystem) navigation to flat (tag) navigation.

## Maintenance architecture — three-tier sync

`_index.md` files are partially machine-maintained. The contents-enum table drifts the moment a child file is added, removed, or renamed; the `updated:` frontmatter timestamp drifts every time the table changes. Hand-authored content (folder-context paragraph, cross-references) is preserved via the survivorship pattern — automated maintenance touches only the contents-enum block and the `updated:` field, never the surrounding prose.

Three tiers cover the full write surface: Claude writes via `Edit`/`Write` tool calls (the 80% case) + cron-script writes + direct-Obsidian edits + manual moves + deletes (the 20% case).

### Tier 1 — Post-write hook (live sync per Edit/Write tool call)

A post-write hook auto-syncs `_index.md` when a sibling file in the same folder is written via `Edit` or `Write` tool calls. The hook is additive to the existing `post-write-verify.sh` pattern.

**Behavior on each fire:**

1. **Self-exempt loop guard.** If the written file is itself an `_index.md`, exit immediately. This is the one line that prevents the post-write firing from recursing on the hook's own writes.
2. **Determine folder state.** Locate sibling `_index.md` in the same folder.
   - Exists → proceed to step 3.
   - Missing AND folder is exempt (per §Exemptions; exemption list canonicalized in `governance/mandatory-files-rules.json`) → exit cleanly.
   - Missing AND folder is non-exempt → **auto-bootstrap (the structural enforcement of the `_index.md` mandate):**
     - Create `_index.md` with frontmatter stub — `type: index`; `parent_folder:` derived from the path (omit at depth 1); `tags:` inferred from the folder's structural-dimension lineage (e.g., `Engagements/<X>/<...>/` → `#engagement/<X>`); `updated:` today.
     - Write the H1 (derived from folder name) and a placeholder folder-context paragraph the operator fills in on next visit (`*[Folder context paragraph: 2–4 sentences describing what lives here, what doesn't, why the folder exists. Pedagogical.]*`).
     - Emit empty contents-enum table with the four-column header.
     - Log a `bootstrap-auto-created` finding for operator visibility.
     - Proceed to step 3 — the write that triggered the hook becomes the index's first content row.
3. **Parse the contents-enum table** in `_index.md`.
4. **Reconcile entry for written file** by wikilink:
   - Missing → append a row populated with (filename, line count via `wc -l`, type from frontmatter, description extracted from the file's H1 or `description:` frontmatter).
   - Line count drifted → update the Lines cell.
   - Type changed → update the Type cell.
   - Description blank → infer from H1 or `description:` frontmatter and populate.
5. **Bump `_index.md` frontmatter `updated:`** to today.
6. **Write `_index.md`.** The hook fires for THAT write; step 1 catches it and exits. No loop.

The loop guard is structurally simple — one filename pattern check at hook entry — and robust against deeper hook chains because the guard fires before any work is done. The auto-bootstrap at step 2 is the **structural enforcement** of the universal mandatory-file lock for `_index.md`: the operator never has to remember to author the index; the system creates it on first write.

### `_index.md` auto-bootstrap as one action in a broader new-folder bootstrap suite

Auto-creation of `_index.md` is the action this packet owns. New folders trigger additional setup actions coordinated by the same hook umbrella — folder-lineage frontmatter propagation to any files written in the folder (see [`frontmatter-design.md`](./frontmatter-design.md) folder-lineage convention), an entry add to the **parent** `_index.md` (the new folder appears as a row in its parent's contents-enum or as a sub-folder mention), and a governance audit log emission. The full suite is registered in [`enforcement-map-design.md`](./enforcement-map-design.md) §Hook gate categories; the actions cross-cut packets, and each packet documents the action it owns. This packet's contribution is the `_index.md` auto-creation step.

### Tier 2 — Librarian `index-maintain` capability (audit + auto-fix sweep)

A librarian capability `index-maintain` (contract authored in this packet; implementation at `skills/librarian/capabilities/index-maintain.sh` ships from SP05) walks the vault and reconciles every non-exempt folder's `_index.md` against its filesystem reality. Catches the writes the hook misses — cron scrapers writing via Bash redirects, direct Obsidian edits, manual file moves, deletes (which never go through the `Edit`/`Write` tool surface).

**Behavior per folder:**

1. Enumerate child `.md` files (exclude `_index.md` itself; exclude gitignored paths).
2. Enumerate rows in the `_index.md` contents-enum table.
3. **Reconcile:**
   - Files with no entry → add row (same logic as Tier 1).
   - Entries with no file → remove row (orphan from a delete or rename).
   - Stale line counts / type drift → auto-correct.
4. Bump `updated:` if any change.

Runs on `/librarian full` and on schedule (default daily; configurable). Cooperates with `rename-cascade.sh` (handles rename-driven row updates) and `placement-validate.sh` (whitelists `_index.md` against the file-naming convention).

### Tier 3 — Librarian `index-maintain --deep` (semantic validation)

Same capability as Tier 2 with deeper checks invoked on demand:

- Does the row's `Description` actually match the file's H1 / `description:` frontmatter? Flag drift for review — do not auto-overwrite, since descriptions can be hand-tuned.
- Does the row's `Lines` cell match `wc -l` exactly? Auto-correct.
- Does the row's `Type` cell match the file's frontmatter `type:`? Auto-correct.
- Is the entry ordering coherent (key-role types — `overview` / `context` / `updates` / `prd` / `navigation` — listed before supporting types like `reference` / `people`)?

Tier 3 is opt-in; Tiers 1 and 2 are the always-on substrate.

### Why post-write, not pre-write

`PreToolUse` hooks in Claude Code are **block-or-allow gates** that return a `permissionDecision`. They cannot atomically write a sibling file as part of the original write. The desired user-experience of "writing to a vault file automatically updates the index" is achieved via post-write auto-sync with the self-exempt loop guard — from the user's view the index update is atomic; under the hood it is two sequential writes with one guarded re-entry.

### Cooperation with `Inbox/_index.md`

The Inbox folder's `_index.md` carries a different content shape — active-connection enumeration + destination-overlap aggregation drawn from connector briefs. That file is maintained by the dedicated `inbox-index-refresh` capability (see [`inbox-flow-architecture.md`](./inbox-flow-architecture.md)), not by `index-maintain`. The two capabilities coexist: `index-maintain` handles per-folder `_index.md` files with the standard four-column shape; `inbox-index-refresh` handles the Inbox special case.

## `_index.md` vs `README.md` — distinction

The two conventions coexist; each does a different job for a different audience.

| File | Audience | Purpose | Where it lives | Update mechanism |
|---|---|---|---|---|
| `_index.md` | LLM + human; in-vault folder navigation | Folder-scoped contents enumeration + context paragraph; load-decision surface for Claude entering the folder | Every non-exempt vault folder, every depth | Hand-authored prose + machine-maintained contents-enum (post-write hook + librarian `index-maintain`) |
| `README.md` | Human; GitHub / public-publishing surface | Project-level introduction for visitors reaching the repo via GitHub UI or package manager | Foundation-repo root; per-Skill repo root; per-personal-initiative GitHub repo root | Hand-authored |

### When you'd use README.md instead

`README.md` is the GitHub / git convention — the file every public-facing code surface carries because GitHub renders it at the repo root and package managers (npm, PyPI, Homebrew, crates.io) surface it on the package page. Its job is **introduction-for-strangers**: what is this project, who is it for, how do I install / use it, what's the license, where do I learn more.

`_index.md` is the in-vault analog optimized for a different audience and access pattern. The audience is Claude + the vault's owner. The access pattern is folder-traversal — the reader is already inside the vault and has decided to enter this specific folder. The job is **contents enumeration + load-decision support**: what files live here, in what role, at what cost to load. README's introduction-for-strangers framing is wasted budget when both reader and writer already know the vault.

**Vault folders do NOT carry `README.md`.** The reference deployment renamed scattered `README.md` files to `_index.md` in 2026-04-17 to consolidate folder navigation under one convention. The foundation-repo root and any standalone GitHub-published artifact (Skill repos, public initiatives' GitHub repos) still carries `README.md` because the repo IS a publishing surface — those are out of scope for this packet's mandate.

Anyone scaffolding a public GitHub artifact uses `README.md`; anyone scaffolding an in-vault folder uses `_index.md`. The two never collide because they live in different stages of the artifact's lifecycle.

## Exemptions

A meaningful minority of folders (depth ≤ 3) are exempt from the standard `_index.md` auto-bootstrap. The canonical exemption list per `governance/mandatory-files-rules.json#mandates._index_md.exemption_paths` is exactly the 5 foundation-shipped folders:

- **`Archive/**`** — cold storage; navigation by name is low-signal because contents are append-only history.
- **`Daily/**`** — date-prefixed file collections. Navigation by date or tag query, not by folder listing.
- **`Inbox/**`** — scraper aggregation surface; uses a different content shape (active-connection enumeration + destination-overlap matrix from connector briefs) maintained by the dedicated `inbox-index-refresh` capability rather than the standard `index-maintain` sweep. Implementation deferred to SP07 (connector wizard) per `feedback_inbox_connector_driven` — Inbox shape is connector-driven, not foundation-locked.
- **`Logs/**`** — Claude's scratch space; emission-driven, not navigation-targeted.
- **`Meetings/**`** — date-prefixed meeting notes. Navigation by date or tag query, not by folder listing.

Per canonical §E counter-clause: every folder NOT listed above — including user-defined clusters, projects, people directories, skills, personal tracks, and any user-created named-content directory — is mandatory-`_index.md` with standard auto-bootstrap. Non-vault infrastructure directories (`Templates/`, `Tags/`, `_orchestrator/`, `tests/`, `tests/fixtures/`) are foundation-repo-only and do not appear in adopter vaults; if a user creates a folder by those names, normal `_index.md` auto-bootstrap fires.

Generalized: **a folder is exempt when it is foundation-shipped AND its contents are date-prefixed sequences, scraper-aggregated data, or scratch-space emissions.** Folders carrying named content files for human and LLM consumption — clusters, projects, people directories, reference, skills, personal tracks — are mandatory-`_index.md`.

## Anti-patterns

**Folder without `_index.md` (non-exempt).** Folder appears as leaf in graph view; LLM reading the folder has no orientation document and must read each file individually; the cost is paid at every read. *Preempt:* universal mandatory-file lock; the scaffold emits one with each new folder; adopters who hand-create folders post-scaffold receive a librarian advisory finding.

**`_index.md` is just a table of contents.** Without the folder-context paragraph and cross-references, the file is regeneratable boilerplate — humans skip it because `ls` produces the same information; LLMs gain nothing from reading it. *Preempt:* the mandatory folder-context paragraph. Pedagogy is the load-bearing content; the table is scaffolding.

**Hand-authored enumeration that drifts.** A `_index.md` whose enumeration was hand-typed at folder creation drifts the moment a file is added, removed, or renamed. Three months in, the enumeration lists three files that no longer exist and misses five that do. *Preempt:* the three-tier maintenance architecture (post-write hook + librarian `index-maintain` + deep audit). The contents-enum table is derivable data, not authoritative content — the filesystem + each file's frontmatter is the source of truth; the hook and librarian keep the table aligned.

**Confusing `_index.md` with `index.md`.** Underscore-prefix is the vault convention (filesystem sort hack); no-underscore is the mkdocs/static-site convention (section-page rendering). A new adopter who copies the mkdocs default loses the sort property; a build engineer who copies the vault convention loses the rendering pipeline. *Preempt:* explicit documentation of the divergence. Vault filesystem uses `_index.md`; foundation-repo GH Pages site uses `index.md` at the rendering layer; the build step bridges via rename or symlink. Both forms are correct in their respective contexts.

**`Provides` column duplicates `Description`.** The two columns answer the same question in two formats — kebab-case category list vs prose summary. Reference-deployment empirical: 103 files carried empty `provides:` frontmatter placeholders while the `_index.md` tables hand-authored `Provides` cells that drifted from source-of-truth frontmatter; the cells were never machine-extracted. *Preempt:* the contents-enum table surfaces `File | Lines | Type | Description` and does NOT carry a `Provides` column. The `provides:` frontmatter field stays on each file as the cross-folder grep handle (R-39: `grep -r 'provides:.*<concept>'`); the per-row presentation collapses to `Type` (structural role identifier, R-32-enforced) + `Description` (prose orientation). Type and description answer different questions and earn their separate keep; provides and description did not.

## Closed questions (with disposition)

- **CQ-I1.** Underscore-prefix vs no-underscore for the folder index filename? → **Underscore-prefix (`_index.md`).** Rationale: sorts to top of directory listings; unambiguous versus human-facing `README.md`. Adopted via an atomic R-37 commit that renamed several existing folder indexes (e.g., `Skills Index.md`, `README.md` variants) to `_index.md`.
- **CQ-I2.** Should `_index.md` be normalized to mkdocs `index.md` at the vault filesystem layer? → **No — filesystem-sort property is load-bearing.** The underscore-prefix IS the point of the filename. The mkdocs/GH-Pages divergence is resolved at build time via rename/symlink at the rendering layer, not by changing the vault filesystem name.
- **CQ-I3.** Are folders with date-prefixed collections (`Daily/`, `Meetings/`, `Archive/<X>/`) exempt? → **Yes — exempt.** Rationale: contents are sequenced by date, not by name; navigation happens via date queries or tag-based filters; an index-by-name would be the wrong primitive.
- **CQ-I4.** Does the vault need a root-level meta-index aggregating all `_index.md` locations? → **No.** Vault-root `CLAUDE.md` + `System Governance.md` together already serve as the meta-navigation surface. A separate cross-folder index would be redundant.
- **CQ-I5.** Should `_index.md` maintenance ship as a regeneration capability (build-time rebuild) or a per-write sync mechanism (live propagation)? → **Per-write sync, three-tier.** Post-write hook for live Claude-driven writes; librarian `index-maintain` capability for non-Claude writes (cron, Obsidian, manual moves); deep-audit mode for opt-in semantic validation. The hook's one-line loop guard (`_index.md` self-exemption) resolves the recursion concern at architectural cost zero. See §Maintenance architecture.

## Source pointers

- Companion narrative packets: [`vault-construction-principles.md`](./vault-construction-principles.md) (folder-mirrors-tag invariant at commitment 5; mandatory-file lock at commitment 7), [`enforcement-map-design.md`](./enforcement-map-design.md) (post-write hook + librarian capability registered under the audit framework), [`file-naming-conventions.md`](./file-naming-conventions.md) (whitelisted-name exemptions), [`inbox-flow-architecture.md`](./inbox-flow-architecture.md) (Inbox/_index.md special case via `inbox-index-refresh` capability)
- Governance JSON registry: `governance/mandatory-files-rules.json` (canonical machine-readable enforcement for the mandatory `_index.md` rule)
- Librarian capability contract: `index-maintain` (Tier 2 sweep + Tier 3 deep audit; contract authored in §Maintenance architecture above; implementation at `skills/librarian/capabilities/index-maintain.sh` ships from SP05 per the same SP03-authors-contract / SP05-implements pattern used for `governance-parity-audit`)
- External convergence: Hugo branch-bundle convention (`gohugo.io/content-management/page-bundles/`); mkdocs-material section-root index convention (`squidfunk.github.io/mkdocs-material/`)
- Live runtime artifacts (adopter-deployment paths, parameterized via install.sh): `hooks/pre-write-guard.sh` (R-32 Tier 2 DENY honors the `type: index` enum); `hooks/post-write-verify.sh` (Tier 1 live-sync extension + loop guard); `skills/librarian/capabilities/placement-validate.sh` (`_index.md` placement allowlist); `skills/librarian/capabilities/index-maintain.sh` (Tier 2 sweep + Tier 3 deep audit)
