---
altitude: system
scope: Per-folder index file conventions. Why every folder in the vault carries an `_index.md`, what goes in it, how the underscore-prefix gets it to sort to the top of the folder listing, how it differs from `File-Index.md` and `README.md`, and which folders legitimately don't carry one.
validity_window: 2026-05-12..2026-11-12
source_dependencies:
  - Plan 81 SP03 spec §Universal mandatory file enumeration (~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md L152-172; per-folder mandate at L164)
  - Plan 81 SP03 spec §Research context packets schema (same file L97-150; mkdocs-material at L150)
  - feedback_index_file_convention (~/.claude/projects/-Users-petertiktinsky/memory/feedback_index_file_convention.md, 2026-04-13 + 2026-04-17 rename entry)
  - Live vault `_index.md` corpus (18 files; sampled `Reference/`, `Skills/`, `Engagements/CDMO DDX/{,People,Projects/Gold-Layer-QA}/`, `Personal Initiatives/Claude Foundations/`)
  - Live vault `CLAUDE.md` §Behavioral Rules (index-first loading directive) + §Vault Structure (`_index.md` at engagement/project/People/Personal-Initiatives roots)
  - Live `~/.claude/skills/librarian/capabilities/placement-validate.sh` — `_index.md` whitelist at L72, L76, L79, L186
  - Hugo `_index.md` docs (gohugo.io/content-management/page-bundles/) — branch-bundle convention
  - mkdocs-material (squidfunk.github.io/mkdocs-material/) — `index.md` no-underscore at section roots
  - Companion packet — vault-construction-principles.md (folder-mirrors-tag invariant; mandatory-file lock)
  - Companion packet — enforcement-map-design.md (whitelist exemption pattern)
last_reviewed: 2026-05-12
canonical_url: https://stem.peter.dev/research/vault-construction/_index.md-design/
url_stability: locked-from-2026-05-12
---

# `_index.md` design — per-folder index file conventions

## Theme

Folder-scoped navigation is a structural primitive. Every folder in the vault needs an entry-point document that answers three questions in the first paragraph: *what lives here*, *how is it organized*, *what should you look at first*. Without that document, the folder appears as a leaf in graph view, LLMs reading the folder have no orientation surface, and human readers fall back on filename-by-filename scanning — lossy, slow, stochastic across sessions.

`_index.md` is that entry-point. The convention is mandatory per the universal mandatory-file lock (SP03 spec L164). The underscore-prefix is not decoration — it is a filesystem-sort hack that places the file at the top of the folder's alphabetical listing, so anything that walks a directory in lexical order (Obsidian's file pane, `ls`, file-tree viewers in IDEs) encounters the index before any content file. The same hack appears in Hugo's static-site-generator convention; the convergence is not coincidence.

## Vision / approach — five structural commitments

### 1. Every non-exempt folder carries an `_index.md`

The universal mandatory-file lock makes `_index.md` non-optional at folder root. Principle: a folder without an index is a folder whose contents are not navigable except by filename inspection — works at three files, breaks at ten, unusable at fifty. Peter's `Engagements/CDMO DDX/Projects/Gold-Layer-QA/` has ten content files; the `_index.md` enumerates each with a one-line description, ~line count, and `provides:` hint — readable in 25 lines instead of opening ten files at 100-700 lines each.

### 2. `_index.md` is the folder's API to readers

Both humans and LLMs read the index before doing anything else in the folder. Vault-root `CLAUDE.md` (§Behavioral Rules) names this explicitly: *"Index-first loading: Check `_index.md` before loading multiple files from an engagement directory. Use `provides` frontmatter to decide what to load."* The index is the gate that prevents context-budget waste on the wrong files.

### 3. Underscore-prefix is a filesystem-sort hack

`_` (0x5F in ASCII) sorts before alphanumeric characters in standard locale-aware sort orders. `_index.md` appears before `2026-01-15-meeting.md`, before `Action-Items.md`, before `Cedric-Ly.md`. Without the underscore, `index.md` would sort somewhere in the middle of the directory listing, defeating the index's purpose as the first thing a reader sees. The convention is documented in `feedback_index_file_convention`: *"underscore prefix sorts to top of directory listings in Obsidian and CLIs; name is unambiguous versus human-facing README.md."*

### 4. `_index.md` is whitelisted infrastructure

The librarian's `placement-validate.sh` whitelists `_index.md` at every directory level (L72, L186: `"_index.md", "File-Index.md"` in the allowlist; L76 + L79 add it to per-folder regex allowlists). The whitelist is structural: `_index.md` has a special filename (leading underscore + lowercase) that would otherwise fail vault file-naming conventions, but the librarian doesn't relocate or normalize it. Per `feedback_index_file_convention`, the same whitelist applies to `File-Index.md`, `Logs/ideation-brief-*.md`, and `Logs/build-*.md`.

### 5. `_index.md` is distinct from `File-Index.md` and `README.md`

The three index conventions coexist; each does a different job. The distinction matters because conflating them produces either bloat (one file trying to be all three) or gaps. Locked in §Distinction below.

## Industry convergence — folder-bundled section landing pages

The folder-bundled section-landing-page pattern is the dominant 2026 convention across static-site generators and PKM systems:

- **Hugo** (gohugo.io/content-management/page-bundles/). `_index.md` is the canonical filename for *branch bundles* — a folder that renders as a list of its children. The underscore-prefix is Hugo's own convention; Hugo distinguishes branch bundles (`_index.md`, lists children) from leaf bundles (`index.md`, terminal page). Plan 81's vault adopts the branch-bundle convention as the canonical name.
- **Obsidian Map-of-Content (MOC) pattern.** Obsidian has no native `_index.md` support — every `.md` file renders identically — but the PKM community converges on folder-level MOC notes as a navigation primitive. Peter's vault uses `_index.md` as the MOC for every folder; the underscore-prefix is the local addition.
- **Static-site generators broadly.** Jekyll/mkdocs/Docusaurus use `index.md`; Hugo uses `_index.md`. Across the SSG ecosystem, *some* convention for a folder-landing-page exists; the underscore-prefix is Hugo's distinctive contribution.
- **mkdocs-material — the divergence to document.** Plan 81's GH Pages docs site uses mkdocs-material (SP03 spec L150), which expects `index.md` (no underscore) at section roots. The divergence is intentional: the vault uses `_index.md` filesystem-side for the sort-to-top property; the docs site uses `index.md` at the rendering layer. The GH Actions workflow bridges the two via rename or symlink at build time. Both filenames coexist without conflict because they live at different stages of the pipeline.

The architectural pattern across all four: **a folder needs an entry-point document, and the document's job is to enumerate the folder's contents and orient the reader.**

## Per-folder `_index.md` structure — locked

Every `_index.md` in the vault follows the same shape. Empirically derived from the 18 `_index.md` files in Peter's live vault.

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

`type: index` maps to the canonical type enumeration in `~/.claude/schemas/vault-schema.json`; R-32 Tier 2 DENY rejects unknown types. The `tags:` field is mandatory because `_index.md` files participate in the folder-mirrors-tag invariant — the tag matches the folder's structural-dimension scope (`Engagements/CDMO DDX/_index.md` carries `#engagement/cdmo-ddx`; `Reference/_index.md` carries `#scope/reference`).

### H1 heading (mandatory)

Matches the folder name or close variant. Examples: `CDMO DDX`, `Reference — Tier 1`, `Skills Index`, `Gold-Layer-QA`. Reinforces the folder-mirrors-tag invariant — the heading reads like a tag value.

### Folder-context paragraph (mandatory)

2-4 sentences describing what lives in the folder, what doesn't, why the folder exists. Pedagogical — both humans and LLMs read this to orient. The paragraph is the **load-bearing** content of the index; without it, the file is regeneratable boilerplate. Live example from `Engagements/CDMO DDX/People/_index.md`: *"CRM files for all contacts on the CDMO DDX engagement. Each file covers role, org, interaction history, and relationship context."*

### Contents enumeration (mandatory, machine-regeneratable)

Tabular list of child files with one-line description and `provides:` extracted from frontmatter. Empirical convention: 4-column table `File | Lines | Provides | Description`. For light-content folders, a prose "Current Contents" section replaces the table when enumeration would be premature.

### Cross-references (recommended)

Bottom-of-file links to parent `_index.md`, peer folders, related tags. Bridges hierarchical (filesystem) navigation to flat (tag) navigation.

### Last-regenerated footer (future, when librarian regen ships)

`<!-- regenerated by librarian index-regen at <timestamp> -->` — see OQ-I1.

## Librarian regeneration capability

`_index.md` files are partially machine-generated. The contents enumeration (table of child files with line counts + `provides:` extracted from frontmatter) is mechanical work that drifts the moment a child file is added, removed, or renamed. Hand-authored portions (folder-context paragraph; cross-references) are preserved via the survivorship pattern: regeneration touches only the enumeration table and the `updated:` timestamp.

**Live-state gap (verified 2026-05-12).** No dedicated `index-regen.sh` capability ships in `~/.claude/skills/librarian/capabilities/`. The 28 capabilities include `placement-validate.sh` (whitelists `_index.md`), `plan-index.sh` (regenerates `~/.claude-plans/_index.md` — different artifact: plan-tree index, not folder-level vault index), and `tag-coverage-audit.sh` — but no `_index.md` content regenerator. `File-Index.md` is auto-maintained by `digest-run` Phase 2.5 link indexing; `_index.md` is hand-maintained today. The regenerator is OQ-I1.

The capability, when it ships, should: (1) walk the folder, list child `.md` files (exclude `_index.md`, `File-Index.md`, gitignored paths); (2) extract H1 or frontmatter `description:`/`scope:` for the one-line description; (3) extract `provides:` from each child's frontmatter for the Provides column; (4) `wc -l` for line counts; (5) regenerate between sentinel markers (`<!-- contents-enum:start -->` / `<!-- contents-enum:end -->`); (6) update the `updated:` frontmatter; (7) preserve all prose outside the markers.

## `_index.md` vs `File-Index.md` vs `README.md` — distinction

| File | Scope | Audience | Update mechanism | Whitelisted? |
|---|---|---|---|---|
| `_index.md` | Per-folder (every non-exempt folder, every depth) | LLM + human; folder-scoped navigation | Hand-authored prose + (future) librarian-regenerated enumeration | Yes — placement-validate L72, L186 |
| `File-Index.md` | Engagement + project roots only | Human; external resource links (SharePoint, GDrive, Excel, file paths) | `digest-run` Phase 2.5 link indexing — auto-maintained | Yes — same whitelist |
| `README.md` | Foundation-repo / vault-root historically / per-project GitHub repo | Human; GitHub/git convention | Hand-authored | Standard markdown — not vault-special |

**`_index.md`** is the in-vault canonical for folder-scoped navigation; indexes vault files; optimized for LLM context-budget efficiency and human filesystem traversal. **`File-Index.md`** is engagement-altitude or project-altitude; indexes *external* resources (links to SharePoint, GDrive, Excel, non-vault assets); auto-maintained by `digest-run`. The two coexist in the same folder (e.g., `Engagements/CDMO DDX/Projects/Gold-Layer-QA/` carries both) — they don't overlap because they index different things. **`README.md`** is the GitHub/git convention; the foundation-repo at `~/Code/claude-stem/` carries one at root; historic vault renames (2026-04-17) consolidated to `_index.md` for in-vault folder indexes. Vault folders do NOT carry `README.md` today.

## Exemptions

Empirical survey (2026-05-12): 18 `_index.md` files; ~12 folders at depth ≤ 3 do NOT carry one. The exemption pattern:

- **Templates folders** — scaffolding seeds, not consumable files.
- **Archive folders** (`Archive/<YYYY>/`, `Archive/Daily/`, etc.) — cold storage; navigation by name is low-signal because contents are append-only history.
- **`Daily/` and `Meetings/`** — date-prefixed file collections. Navigation by date or tag query, not by folder listing.
- **`Inbox/`** — scraper aggregation surface; the seven aggregation files are documented inline in vault-root `CLAUDE.md`; a folder-level index would duplicate.
- **`Logs/`** — Claude's scratch space; emission-driven, not navigation-targeted.
- **`Tags/`** — Obsidian Make.md plugin artifact directory; adopter-disposable, gitignored.
- **`_orchestrator/`** directories in plan trees — orchestrator state, not human-navigable (per `~/.claude/CLAUDE.md` Plan Creation Conventions).
- **Test fixture directories** (`tests/fixtures/`, `tests/`) — fixture data.

Generalized: **a folder is exempt when its contents are date-prefixed sequences, scraper aggregation surfaces, scratch-space emissions, or non-vault infrastructure.** Folders carrying named content files for human and LLM consumption — engagements, projects, people directories, reference, skills, personal initiatives — are mandatory-`_index.md`.

## Anti-patterns

**Folder without `_index.md` (non-exempt).** Folder appears as leaf in graph view; LLM reading the folder has no orientation document and must read each file individually; the cost is paid at every read. *Preempt:* universal mandatory-file lock; the scaffold (SP04) emits one with each new folder; adopters who hand-create folders post-scaffold receive a librarian advisory finding.

**`_index.md` is just a table of contents.** Without the folder-context paragraph and cross-references, the file is regeneratable boilerplate — humans skip it because `ls` produces the same information; LLMs gain nothing from reading it. *Preempt:* the mandatory folder-context paragraph. Pedagogy is the load-bearing content; the table is scaffolding.

**Hand-authored enumeration that drifts.** A `_index.md` whose enumeration was hand-typed at folder creation drifts the moment a file is added, removed, or renamed. Three months in, the enumeration lists three files that no longer exist and misses five that do. *Preempt:* the librarian regeneration capability (OQ-I1). Until it ships, survivorship pattern + lazy `/librarian index-regen <folder>` on demand; treat the table as derivable data, not authoritative content.

**Confusing `_index.md` with `index.md`.** Underscore-prefix is the vault convention (filesystem sort hack); no-underscore is the mkdocs/static-site convention (section-page rendering). A new adopter who copies the mkdocs default loses the sort property; a build engineer who copies the vault convention loses the rendering pipeline. *Preempt:* explicit documentation of the divergence. Vault filesystem uses `_index.md`; foundation-repo GH Pages site uses `index.md` at the rendering layer; the build step bridges via rename or symlink. Both forms are correct in their respective contexts.

## Open questions

- **OQ-I1.** A dedicated `index-regen.sh` librarian capability does not yet ship (verified 2026-05-12 against `~/.claude/skills/librarian/capabilities/`). Closest precedents: `plan-index.sh` (regenerates `~/.claude-plans/_index.md`) and `digest-run` Phase 2.5 (regenerates `File-Index.md`). Schema and survivorship pattern locked in §Librarian regeneration; implementation slot deferred to a near-term librarian addition.
- **OQ-I2.** Cross-folder index aggregation — does the vault need a root-level meta-index, or does the vault-root `CLAUDE.md` §Vault Structure already serve that role? Today the tree names every `_index.md` location implicitly. A meta-index is a candidate librarian capability if folder-discovery becomes a bottleneck; pending empirical signal.

## Closed questions (with disposition)

- **CQ-I1.** Underscore-prefix vs no-underscore for the folder index filename? → **Underscore-prefix (`_index.md`).** Decided 2026-04-17 (atomic R-37 commit; three folders renamed: `Skills/Skills Index.md`, `Dashboard/README.md`, `Reference/README.md` → `*/_index.md`). Rationale: sorts to top of directory listings; unambiguous versus human-facing `README.md`. Source: `feedback_index_file_convention` 2026-04-17 entry.
- **CQ-I2.** `_index.md` vs `File-Index.md` — same file or different? → **Different; both coexist at engagement/project roots.** Decided historically; documented in `feedback_index_file_convention` and in `placement-validate.sh` allowlist (both listed). Rationale: `_index.md` indexes vault files; `File-Index.md` indexes external links, auto-maintained by `digest-run` Phase 2.5. Different scope, audience, update mechanism — collapsing them produces one file trying to do two jobs.
- **CQ-I3.** Should `_index.md` be normalized to mkdocs `index.md` at the vault filesystem layer? → **No — filesystem-sort property is load-bearing.** Decided implicitly at the 2026-04-17 rename; explicit here. Rationale: the underscore-prefix IS the point of the filename. The mkdocs/GH-Pages divergence is resolved at build time via rename/symlink at the rendering layer, not by changing the vault filesystem name.
- **CQ-I4.** Are folders with date-prefixed collections (`Daily/`, `Meetings/`, `Archive/<X>/`) exempt? → **Yes — exempt.** Decided implicitly via empirical pattern (zero of these folders carry `_index.md`); explicit in §Exemptions. Rationale: contents are sequenced by date, not by name; navigation happens via date queries or tag-based filters; an index-by-name would be the wrong primitive.

## Source pointers

- Plan 81 SP03 spec §Universal mandatory file enumeration (per-folder mandate): `~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md` L152-172 (L164 load-bearing)
- Plan 81 SP03 spec §Research context packets schema (mkdocs-material at L150; packet ID 7 at L116-117; entry-point doc at L365): same file
- `feedback_index_file_convention` memory (whitelist treatment; 2026-04-17 rename history; four whitelisted file patterns): `~/.claude/projects/-Users-petertiktinsky/memory/feedback_index_file_convention.md`
- Live vault `CLAUDE.md` §Behavioral Rules (index-first loading directive) + §Vault Structure (`_index.md` documented at engagement/project/People/Personal-Initiatives roots): `~/Documents/Obsidian Vault/CLAUDE.md`
- Live vault `_index.md` corpus sampled 2026-05-12 (18 files; representative samples):
  - `~/Documents/Obsidian Vault/Reference/_index.md` — prose-form Tier 1
  - `~/Documents/Obsidian Vault/Skills/_index.md` — tabular catalog with `provides: [skills-catalog]`
  - `~/Documents/Obsidian Vault/Engagements/CDMO DDX/_index.md` — engagement-root
  - `~/Documents/Obsidian Vault/Engagements/CDMO DDX/People/_index.md` — people-folder
  - `~/Documents/Obsidian Vault/Engagements/CDMO DDX/Projects/Gold-Layer-QA/_index.md` — project-root, 11-file table
  - `~/Documents/Obsidian Vault/Personal Initiatives/Claude Foundations/_index.md` — initiative-root
- Live librarian whitelist (`_index.md` placement allowlist): `~/.claude/skills/librarian/capabilities/placement-validate.sh` L72, L76, L79, L186
- Live librarian capability inventory (no `index-regen.sh`; gap is OQ-I1; 28 capabilities at 2026-05-12): `~/.claude/skills/librarian/capabilities/`
- Hugo `_index.md` (canonical branch-bundle convention): `https://gohugo.io/content-management/page-bundles/`
- mkdocs-material (`index.md` no-underscore at section roots; the rendering-layer counterpart): `https://squidfunk.github.io/mkdocs-material/`
- Companion packet — `vault-construction-principles.md` (folder-mirrors-tag invariant at commitment 5; mandatory-file lock at commitment 7): `~/Code/claude-stem/research/vault-construction/vault-construction-principles.md`
- Companion packet — `enforcement-map-design.md` (whitelist exemption pattern; librarian audit capability pattern): `~/Code/claude-stem/research/vault-construction/enforcement-map-design.md`
