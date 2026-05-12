---
altitude: system
scope: Per-folder index file conventions. Why every folder in the vault carries an `_index.md`, what goes in it, how the underscore-prefix gets it to sort to the top of the folder listing, how it differs from `File-Index.md` and `README.md`, and which folders legitimately don't carry one.
validity_window: 2026-05-12..2026-11-12
source_dependencies:
  - companion: ./vault-construction-principles.md
  - companion: ./enforcement-map-design.md
  - companion: ./file-naming-conventions.md
  - governance: claude-stem/governance/mandatory-files-rules.json
  - external: Hugo branch-bundle convention (gohugo.io/content-management/page-bundles/)
  - external: mkdocs-material section-root index.md convention (squidfunk.github.io/mkdocs-material/)
last_reviewed: 2026-05-12
canonical_url: https://stem.peter.dev/research/vault-construction/_index.md-design/
url_stability: locked-from-2026-05-12
---

# `_index.md` design — per-folder index file conventions

## Theme

Folder-scoped navigation is a structural primitive. Every folder in the vault needs an entry-point document that answers three questions in the first paragraph: *what lives here*, *how is it organized*, *what should you look at first*. Without that document, the folder appears as a leaf in graph view, LLMs reading the folder have no orientation surface, and human readers fall back on filename-by-filename scanning — lossy, slow, stochastic across sessions.

`_index.md` is that entry-point. The convention is mandatory per the universal mandatory-file lock. The underscore-prefix is not decoration — it is a filesystem-sort hack that places the file at the top of the folder's alphabetical listing, so anything that walks a directory in lexical order (Obsidian's file pane, `ls`, file-tree viewers in IDEs) encounters the index before any content file. The same hack appears in Hugo's static-site-generator convention; the convergence is not coincidence.

## Vision / approach — five structural commitments

### 1. Every non-exempt folder carries an `_index.md`

The universal mandatory-file lock makes `_index.md` non-optional at folder root. Principle: a folder without an index is a folder whose contents are not navigable except by filename inspection — works at three files, breaks at ten, unusable at fifty. A project folder with a dozen content files plus an `_index.md` is readable in 25 lines — each entry one line with description, line count, and `provides:` hint — instead of opening every file at 100–700 lines each.

### 2. `_index.md` is the folder's API to readers

Both humans and LLMs read the index before doing anything else in the folder. The vault-root `CLAUDE.md` (§Behavioral Rules) names this explicitly: *"Index-first loading: Check `_index.md` before loading multiple files from an engagement directory. Use `provides` frontmatter to decide what to load."* The index is the gate that prevents context-budget waste on the wrong files.

### 3. Underscore-prefix is a filesystem-sort hack

`_` (0x5F in ASCII) sorts before alphanumeric characters in standard locale-aware sort orders. `_index.md` appears before `2026-01-15-meeting.md`, before `Action-Items.md`, before `Contact-Name.md`. Without the underscore, `index.md` would sort somewhere in the middle of the directory listing, defeating the index's purpose as the first thing a reader sees. The underscore-prefix sorts to top of directory listings in Obsidian and CLIs; the name is unambiguous versus a human-facing `README.md`.

### 4. `_index.md` is whitelisted infrastructure

The librarian's `placement-validate` capability whitelists `_index.md` at every directory level. The whitelist is structural: `_index.md` has a special filename (leading underscore + lowercase) that would otherwise fail vault file-naming conventions, but the librarian doesn't relocate or normalize it. The same whitelist applies to `File-Index.md`, legacy `Logs/ideation-brief-*.md` symlink artifacts, and legacy `Logs/build-*.md` files.

### 5. `_index.md` is distinct from `File-Index.md` and `README.md`

The three index conventions coexist; each does a different job. The distinction matters because conflating them produces either bloat (one file trying to be all three) or gaps. Locked in §Distinction below.

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
tags:
  - "#scope/reference"        # OR engagement/project/initiative scope tag matching the folder
updated: 2026-05-12
---
```

Optional: `description:` (one-line scope description); `provides:` (capability hint, e.g. `provides: [skills-catalog]`).

`type: index` maps to the canonical type enumeration in `schemas/vault-schema.json`; R-32 Tier 2 DENY rejects unknown types. The `tags:` field is mandatory because `_index.md` files participate in the folder-mirrors-tag invariant — the tag matches the folder's structural-dimension scope (e.g., `Engagements/<X>/_index.md` carries `#engagement/<X>`; `Reference/_index.md` carries `#scope/reference`).

### H1 heading (mandatory)

Matches the folder name or close variant. Examples: `Acme Corp`, `Reference — Tier 1`, `Skills Index`, `Data-Platform`. Reinforces the folder-mirrors-tag invariant — the heading reads like a tag value.

### Folder-context paragraph (mandatory)

2–4 sentences describing what lives in the folder, what doesn't, why the folder exists. Pedagogical — both humans and LLMs read this to orient. The paragraph is the **load-bearing** content of the index; without it, the file is regeneratable boilerplate. Example: *"CRM files for all contacts on the engagement. Each file covers role, org, interaction history, and relationship context."*

### Contents enumeration (mandatory, machine-regeneratable)

Tabular list of child files with one-line description and `provides:` extracted from frontmatter. Empirical convention: 4-column table `File | Lines | Provides | Description`. For light-content folders, a prose "Current Contents" section replaces the table when enumeration would be premature.

### Cross-references (recommended)

Bottom-of-file links to parent `_index.md`, peer folders, related tags. Bridges hierarchical (filesystem) navigation to flat (tag) navigation.

### Last-regenerated footer (future, when librarian regen ships)

`<!-- regenerated by librarian index-regen at <timestamp> -->` — see OQ-I1.

## Librarian regeneration capability

`_index.md` files are partially machine-generated. The contents enumeration (table of child files with line counts + `provides:` extracted from frontmatter) is mechanical work that drifts the moment a child file is added, removed, or renamed. Hand-authored portions (folder-context paragraph; cross-references) are preserved via the survivorship pattern: regeneration touches only the enumeration table and the `updated:` timestamp.

**Capability gap.** A dedicated `index-regen` capability is not in the canonical librarian capability set today. Closest precedents are `plan-index` (regenerates the plan-tree `_index.md` — a different artifact: plan-tree index, not folder-level vault index), and the `digest-run` Phase 2.5 link indexing that maintains `File-Index.md`. The folder-level `_index.md` regenerator is OQ-I1.

The capability, when it ships, should: (1) walk the folder, list child `.md` files (exclude `_index.md`, `File-Index.md`, gitignored paths); (2) extract H1 or frontmatter `description:`/`scope:` for the one-line description; (3) extract `provides:` from each child's frontmatter for the Provides column; (4) `wc -l` for line counts; (5) regenerate between sentinel markers (`<!-- contents-enum:start -->` / `<!-- contents-enum:end -->`); (6) update the `updated:` frontmatter; (7) preserve all prose outside the markers.

## `_index.md` vs `File-Index.md` vs `README.md` — distinction

| File | Scope | Audience | Update mechanism | Whitelisted? |
|---|---|---|---|---|
| `_index.md` | Per-folder (every non-exempt folder, every depth) | LLM + human; folder-scoped navigation | Hand-authored prose + (future) librarian-regenerated enumeration | Yes — placement-validate allowlist |
| `File-Index.md` | Engagement + project roots only | Human; external resource links (SharePoint, GDrive, Excel, file paths) | `digest-run` Phase 2.5 link indexing — auto-maintained | Yes — same whitelist |
| `README.md` | Foundation-repo / vault-root historically / per-project GitHub repo | Human; GitHub/git convention | Hand-authored | Standard markdown — not vault-special |

**`_index.md`** is the in-vault canonical for folder-scoped navigation; indexes vault files; optimized for LLM context-budget efficiency and human filesystem traversal. **`File-Index.md`** is engagement-altitude or project-altitude; indexes *external* resources (links to SharePoint, GDrive, Excel, non-vault assets); auto-maintained by `digest-run`. The two coexist in the same folder (e.g., engagement project roots typically carry both) — they don't overlap because they index different things. **`README.md`** is the GitHub/git convention; the foundation-repo carries one at root; historic vault renames consolidated to `_index.md` for in-vault folder indexes. Vault folders do NOT carry `README.md` today.

## Exemptions

A meaningful minority of folders (depth ≤ 3) do NOT carry `_index.md` by design. The exemption pattern:

- **Templates folders** — scaffolding seeds, not consumable files.
- **Archive folders** (`Archive/<YYYY>/`, `Archive/Daily/`, etc.) — cold storage; navigation by name is low-signal because contents are append-only history.
- **`Daily/` and `Meetings/`** — date-prefixed file collections. Navigation by date or tag query, not by folder listing.
- **`Inbox/`** — scraper aggregation surface; the aggregation files are documented inline in vault-root `CLAUDE.md`; a folder-level index would duplicate.
- **`Logs/`** — Claude's scratch space; emission-driven, not navigation-targeted.
- **`Tags/`** — Obsidian Make.md plugin artifact directory; adopter-disposable, gitignored.
- **`_orchestrator/`** directories in plan trees — orchestrator state, not human-navigable.
- **Test fixture directories** (`tests/fixtures/`, `tests/`) — fixture data.

Generalized: **a folder is exempt when its contents are date-prefixed sequences, scraper aggregation surfaces, scratch-space emissions, or non-vault infrastructure.** Folders carrying named content files for human and LLM consumption — engagements, projects, people directories, reference, skills, personal initiatives — are mandatory-`_index.md`.

## Anti-patterns

**Folder without `_index.md` (non-exempt).** Folder appears as leaf in graph view; LLM reading the folder has no orientation document and must read each file individually; the cost is paid at every read. *Preempt:* universal mandatory-file lock; the scaffold emits one with each new folder; adopters who hand-create folders post-scaffold receive a librarian advisory finding.

**`_index.md` is just a table of contents.** Without the folder-context paragraph and cross-references, the file is regeneratable boilerplate — humans skip it because `ls` produces the same information; LLMs gain nothing from reading it. *Preempt:* the mandatory folder-context paragraph. Pedagogy is the load-bearing content; the table is scaffolding.

**Hand-authored enumeration that drifts.** A `_index.md` whose enumeration was hand-typed at folder creation drifts the moment a file is added, removed, or renamed. Three months in, the enumeration lists three files that no longer exist and misses five that do. *Preempt:* the librarian regeneration capability (OQ-I1). Until it ships, survivorship pattern + lazy `/librarian index-regen <folder>` on demand; treat the table as derivable data, not authoritative content.

**Confusing `_index.md` with `index.md`.** Underscore-prefix is the vault convention (filesystem sort hack); no-underscore is the mkdocs/static-site convention (section-page rendering). A new adopter who copies the mkdocs default loses the sort property; a build engineer who copies the vault convention loses the rendering pipeline. *Preempt:* explicit documentation of the divergence. Vault filesystem uses `_index.md`; foundation-repo GH Pages site uses `index.md` at the rendering layer; the build step bridges via rename or symlink. Both forms are correct in their respective contexts.

## Open questions

- **OQ-I1.** A dedicated `index-regen` librarian capability is not yet in the canonical set. Closest precedents: `plan-index` (regenerates the plan-tree `_index.md`) and `digest-run` Phase 2.5 (regenerates `File-Index.md`). Schema and survivorship pattern locked in §Librarian regeneration; implementation slot deferred to a near-term librarian addition.
- **OQ-I2.** Cross-folder index aggregation — does the vault need a root-level meta-index, or does the vault-root `CLAUDE.md` §Vault Structure already serve that role? Today the tree names every `_index.md` location implicitly. A meta-index is a candidate librarian capability if folder-discovery becomes a bottleneck; pending empirical signal.

## Closed questions (with disposition)

- **CQ-I1.** Underscore-prefix vs no-underscore for the folder index filename? → **Underscore-prefix (`_index.md`).** Rationale: sorts to top of directory listings; unambiguous versus human-facing `README.md`. Adopted via an atomic R-37 commit that renamed several existing folder indexes (e.g., `Skills Index.md`, `README.md` variants) to `_index.md`.
- **CQ-I2.** `_index.md` vs `File-Index.md` — same file or different? → **Different; both coexist at engagement/project roots.** Rationale: `_index.md` indexes vault files; `File-Index.md` indexes external links, auto-maintained by `digest-run` Phase 2.5. Different scope, audience, update mechanism — collapsing them produces one file trying to do two jobs.
- **CQ-I3.** Should `_index.md` be normalized to mkdocs `index.md` at the vault filesystem layer? → **No — filesystem-sort property is load-bearing.** The underscore-prefix IS the point of the filename. The mkdocs/GH-Pages divergence is resolved at build time via rename/symlink at the rendering layer, not by changing the vault filesystem name.
- **CQ-I4.** Are folders with date-prefixed collections (`Daily/`, `Meetings/`, `Archive/<X>/`) exempt? → **Yes — exempt.** Rationale: contents are sequenced by date, not by name; navigation happens via date queries or tag-based filters; an index-by-name would be the wrong primitive.

## Source pointers

- Companion narrative packets: [`vault-construction-principles.md`](./vault-construction-principles.md) (folder-mirrors-tag invariant at commitment 5; mandatory-file lock at commitment 7), [`enforcement-map-design.md`](./enforcement-map-design.md) (whitelist exemption pattern; librarian audit capability pattern), [`file-naming-conventions.md`](./file-naming-conventions.md) (whitelisted-name exemptions)
- Governance JSON registry: `governance/mandatory-files-rules.json` (canonical machine-readable enforcement for the mandatory `_index.md` rule)
- External convergence: Hugo branch-bundle convention (`gohugo.io/content-management/page-bundles/`); mkdocs-material section-root index convention (`squidfunk.github.io/mkdocs-material/`)
- Live runtime artifacts (adopter-deployment paths, parameterized via install.sh): `hooks/pre-write-guard.sh` (R-32 Tier 2 DENY honors the `type: index` enum); `skills/librarian/capabilities/placement-validate.sh` (`_index.md` placement allowlist)
