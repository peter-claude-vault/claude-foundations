---
type: reference
parent_folder: target-state/_index.md-design
tags:
  - "#scope/reference"
updated: 2026-05-14
source_packet: ../../research/vault-construction/_index.md-design.md
---

# `_index.md` design — conventions and rationale

This file carries the *why* behind the `_index.md` convention: the theme, the four structural commitments, and the industry convergence that informs the design. The companion [`structural-requirements.md`](./structural-requirements.md) carries the *what* (mandatory structure); [`governance.md`](./governance.md) carries the *how* (enforcement architecture + exemptions + anti-patterns).

## Theme

Folder-scoped navigation is a structural primitive. Every folder in the vault needs an entry-point document that answers three questions in the first paragraph: *what lives here*, *how is it organized*, *what should you look at first*. Without that document, the folder appears as a leaf in graph view, LLMs reading the folder have no orientation surface, and human readers fall back on filename-by-filename scanning — lossy, slow, stochastic across sessions.

`_index.md` is that entry-point. The convention is mandatory per the universal mandatory-file lock. The underscore-prefix is not decoration — it is a filesystem-sort hack that places the file at the top of the folder's alphabetical listing, so anything that walks a directory in lexical order (Obsidian's file pane, `ls`, file-tree viewers in IDEs) encounters the index before any content file. The same hack appears in Hugo's static-site-generator convention; the convergence is not coincidence.

## Vision / approach — four structural commitments

### 1. Every non-exempt folder carries an `_index.md` — auto-bootstrapped, not merely mandated

The universal mandatory-file lock makes `_index.md` non-optional at folder root. Principle: a folder without an index is a folder whose contents are not navigable except by filename inspection — works at three files, breaks at ten, unusable at fifty. A project folder with a dozen content files plus an `_index.md` is readable in 25 lines — each entry one line with file type, line count, and description — instead of opening every file at 100–700 lines each.

**The mandate is enforced structurally, not advisorily.** The post-write hook (see [`governance.md`](./governance.md) §Maintenance architecture Tier 1) detects on every write whether the target folder lacks an `_index.md`; if the folder is non-exempt the hook auto-creates the file before reconciling the entry for the write that triggered it. Folder creation is not a separate event Claude Code surfaces as a hook — folders come into existence as side effects of file writes — so the first-write to a new folder IS the bootstrap trigger. The adopter never has to remember to author the index; the system creates it. Hand-creating a folder via `mkdir` without a subsequent write leaves no orphan because the librarian `index-maintain` sweep (Tier 2) catches it on the next periodic scan.

### 2. `_index.md` is the folder's API to readers

Both humans and LLMs read the index before doing anything else in the folder. The vault-root `CLAUDE.md` (§Behavioral Rules) names this explicitly: *"Index-first loading: Check `_index.md` before loading multiple files from an engagement directory. Use `provides` frontmatter to decide what to load."* The index is the gate that prevents context-budget waste on the wrong files.

### 3. Underscore-prefix is a filesystem-sort hack

`_` (0x5F in ASCII) sorts before alphanumeric characters in standard locale-aware sort orders. `_index.md` appears before `2026-01-15-meeting.md`, before `Action-Items.md`, before `Contact-Name.md`. Without the underscore, `index.md` would sort somewhere in the middle of the directory listing, defeating the index's purpose as the first thing a reader sees. The underscore-prefix sorts to top of directory listings in Obsidian and CLIs; the name is unambiguous versus a human-facing `README.md`.

### 4. `_index.md` is whitelisted infrastructure

The librarian's `placement-validate` capability whitelists `_index.md` at every directory level. The whitelist is structural: `_index.md` has a special filename (leading underscore + lowercase) that would otherwise fail vault file-naming conventions, but the librarian doesn't relocate or normalize it. The same whitelist applies to legacy `Logs/ideation-brief-*.md` symlink artifacts and legacy `Logs/build-*.md` files.

## Industry convergence — folder-bundled section landing pages

The folder-bundled section-landing-page pattern is the dominant 2026 convention across static-site generators and PKM systems:

- **Hugo** (gohugo.io/content-management/page-bundles/). `_index.md` is the canonical filename for *branch bundles* — a folder that renders as a list of its children. The underscore-prefix is Hugo's own convention; Hugo distinguishes branch bundles (`_index.md`, lists children) from leaf bundles (`index.md`, terminal page). The vault adopts the branch-bundle convention as the canonical name.
- **Obsidian Map-of-Content (MOC) pattern.** Obsidian has no native `_index.md` support — every `.md` file renders identically — but the PKM community converges on folder-level MOC notes as a navigation primitive. The vault uses `_index.md` as the MOC for every folder; the underscore-prefix is the local addition.
- **Static-site generators broadly.** Jekyll/mkdocs/Docusaurus use `index.md`; Hugo uses `_index.md`. Across the SSG ecosystem, *some* convention for a folder-landing-page exists; the underscore-prefix is Hugo's distinctive contribution.
- **mkdocs-material — the divergence to document.** The foundation-repo's GH Pages docs site uses mkdocs-material, which expects `index.md` (no underscore) at section roots. The divergence is intentional: the vault uses `_index.md` filesystem-side for the sort-to-top property; the docs site uses `index.md` at the rendering layer. The CI workflow bridges the two via rename or symlink at build time. Both filenames coexist without conflict because they live at different stages of the pipeline.

The architectural pattern across all four: **a folder needs an entry-point document, and the document's job is to enumerate the folder's contents and orient the reader.**

## Source pointers

- Source packet: [`research/vault-construction/_index.md-design.md`](../../research/vault-construction/_index.md-design.md) — the master narrative document that this file decomposes
- Companion specs in this folder: [`structural-requirements.md`](./structural-requirements.md) (mandatory structure), [`structural-requirements.json`](./structural-requirements.json) (machine contract), [`governance.md`](./governance.md) (enforcement + exemptions)
- External convergence: Hugo branch-bundle convention (`gohugo.io/content-management/page-bundles/`); mkdocs-material section-root index convention (`squidfunk.github.io/mkdocs-material/`)
