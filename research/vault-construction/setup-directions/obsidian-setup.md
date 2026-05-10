---
altitude: system
scope: Setup direction for the Obsidian pre-req — content-layer interface for Claude Stem. Soft-mandated; skip path coherent.
validity_window: 2026-05-10..2026-11-10
source_dependencies:
  - Plan 81 SP02 spec.md §Pre-reqs (L137-141)
  - Plan 80 SP02 packet T8 §6 (pre-req table)
  - obsidian.md/download (Obsidian distribution; URL stable)
last_reviewed: 2026-05-10
canonical_url: https://stem.peter.dev/research/vault-construction/setup-directions/obsidian/
url_stability: locked-from-2026-05-10
---

# Obsidian — content-layer interface

## Rationale

The content layer of your AI system lives in an Obsidian vault. Native Obsidian gives you the visual interface, plugin ecosystem, and graph view that make the vault navigable for both you and Claude. Claude reads markdown files directly — Obsidian is not required for Claude to work — but the vault is designed around the affordances Obsidian provides.

You will encounter the vault structure (folders, frontmatter, tags, `_index.md` files, per-folder `CLAUDE.md` navigation guides) constantly during use. Doing that without Obsidian's visual surface means navigating a directory tree in Finder or a file manager — workable, but you lose the graph view, the plugin ecosystem, and the live-preview rendering that make the vault feel like a knowledge system rather than a folder of files.

## Install steps

1. Download Obsidian from <https://obsidian.md/download>. macOS, Windows, and Linux builds available. The free plan is sufficient — no subscription needed.
2. Install the application.
3. On first launch, select **Open folder as vault** when prompted. Point Obsidian at the directory the onboarder will scaffold (it will tell you the path during step 7). Or, if your vault already exists, point it there now.
4. Confirm Obsidian opens the vault and you can see folders + files in the left sidebar.

That is the whole pre-req. Plugin recommendations land later in the flow once your vault is scaffolded.

## If skipped

The vault still works as a plain markdown directory. Claude reads and writes files exactly the same way. What you lose:

- **Visual interface** — no left-sidebar tree, no live preview, no graph view. You navigate via Finder / your shell.
- **Plugin extensibility** — the dataview, tag-wrangler, and templater plugins (which the system uses for vault-side enrichment) cannot run.
- **Graph view** — the visual map of how your notes link to each other. Useful for spotting orphans and clusters.

The skip path is coherent: every system feature still functions because everything is plain markdown underneath. You lose the human-facing interface, not any backend capability.

## Source pointers

- Plan 81 SP02 spec.md §Pre-reqs table (L137-141)
- Plan 80 SP02 packet T8 §6 (Obsidian row)
- Obsidian distribution: <https://obsidian.md/download>
