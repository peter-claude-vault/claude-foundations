---
type: reference
parent_folder: target-state/_index.md-design
tags:
  - "#scope/reference"
updated: 2026-05-14
source_packet: ../../research/vault-construction/_index.md-design.md
---

# `_index.md` design — governance

## Hooks and skills enforcing governance

The `_index.md` mandate + structural-requirements contract are enforced by a small set of existing hooks/skills plus one new librarian capability. Each consumer reads the machine contract at [`structural-requirements.json`](./structural-requirements.json).

### Hooks

- **`pre-write-guard.sh`** (existing) — Tier 2 DENY for unknown `type:` values via R-32; reads `governance/foundation-master.json` (bundle-at-load per SP13 T-3); enforces frontmatter compliance at write time on every Edit/Write tool call.
- **`post-write-verify.sh`** (existing, EXTENDED for `_index.md`) — original role: post-write schema validation + advisory cascade emission. New role: Tier 1 live-sync of `_index.md` on every Edit/Write tool call to a vault folder + auto-bootstrap at first-write to a non-exempt folder lacking one + one-line `_index.md` self-exempt loop guard at entry. See §Maintenance architecture below.

### Librarian capabilities

- **`placement-validate.sh`** (existing) — whitelists `_index.md` against the file-naming convention; passes through valid placement; flags drift findings for `_index.md` missing at mandated locations OR present at out-of-scope locations.
- **`frontmatter-enforce.sh`** (existing) — validates frontmatter schema conformance at audit time; covers the `parent_folder:` + `tags:` + `updated:` field contract for `_index.md` via the `index` type entry.
- **`rename-cascade.sh`** (existing) — handles rename-driven entry updates in `_index.md` contents-enum tables; cooperates with Tier 1 hook on Edit/Write but catches Bash-driven moves the hook misses.
- **`xref-check.sh`** (existing) — validates wikilink integrity (relevant when an `_index.md` references files that have been renamed/moved).
- **`wikilink-repair.sh`** (existing) — auto-fixes broken wikilinks in `_index.md` tables; cooperates with `rename-cascade.sh`.
- **`index-maintain.sh`** *(NEW capability)* — Tier 2 audit sweep reconciling `_index.md` contents-enum against folder filesystem reality (adds missing entries, removes orphan rows, corrects drifted line counts and types). Tier 3 `--deep` flag enables opt-in semantic validation (description-vs-H1 match, ordering coherence). First self-healing capability in the canonical set under the R-34 boundary — mutations bounded to mechanically-derivable values; semantic content (descriptions, ordering, exemptions) is flagged for review and never auto-overwritten.

---

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

Auto-creation of `_index.md` is the action this packet owns. New folders trigger additional setup actions coordinated by the same hook umbrella — folder-lineage frontmatter propagation to any files written in the folder (see [`frontmatter-design.md`](../../research/vault-construction/frontmatter-design.md) folder-lineage convention), an entry add to the **parent** `_index.md` (the new folder appears as a row in its parent's contents-enum or as a sub-folder mention), and a governance audit log emission. The full suite is registered in [`enforcement-map-design.md`](../../research/vault-construction/enforcement-map-design.md) §Hook gate categories; the actions cross-cut packets, and each packet documents the action it owns. This packet's contribution is the `_index.md` auto-creation step.

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

The Inbox folder's `_index.md` carries a different content shape — active-connection enumeration + destination-overlap aggregation drawn from connector briefs. That file is maintained by the dedicated `inbox-index-refresh` capability (see [`inbox-flow-architecture.md`](../../research/vault-construction/inbox-flow-architecture.md)), not by `index-maintain`. The two capabilities coexist: `index-maintain` handles per-folder `_index.md` files with the standard four-column shape; `inbox-index-refresh` handles the Inbox special case.

## Exemptions

A meaningful minority of folders (depth ≤ 3) do NOT carry `_index.md` by design. The exemption pattern:

- **Templates folders** — scaffolding seeds, not consumable files.
- **Archive folders** (`Archive/<YYYY>/`, `Archive/Daily/`, etc.) — cold storage; navigation by name is low-signal because contents are append-only history.
- **`Daily/` and `Meetings/`** — date-prefixed file collections. Navigation by date or tag query, not by folder listing.
- **`Inbox/`** — connector-managed aggregation surface; maintained by dedicated `inbox-index-refresh` capability rather than the standard `index-maintain` sweep.
- **`Logs/`** — Claude's scratch space; emission-driven, not navigation-targeted.

**§E counter-clause:** Every folder NOT listed above — including cluster folders, project folders, people directories, skills, personal tracks, and any user-created named-content directory — is mandatory-`_index.md`. The post-write hook auto-bootstraps `_index.md` at first write to any non-exempt folder. Non-vault infrastructure directories (`Tags/`, `_orchestrator/`, `tests/`, `tests/fixtures/`) are foundation-repo-only and do not appear in adopter vaults; if a user creates a folder by those names, normal `_index.md` auto-bootstrap fires.

Generalized: **a folder is exempt when its contents are date-prefixed sequences, connector-aggregated data, or scratch-space emissions.** Folders carrying named content files for human and LLM consumption — clusters, projects, people directories, reference, skills, personal tracks — are mandatory-`_index.md`.

The canonical exemption list lives at `governance/mandatory-files-rules.json#_index_md_exemption_paths` (per the runtime deployment target declared in [`structural-requirements.json`](./structural-requirements.json) `exemption_list_pointer`); hooks + librarian capability consume from there at runtime.

## Anti-patterns

**Folder without `_index.md` (non-exempt).** Folder appears as leaf in graph view; LLM reading the folder has no orientation document and must read each file individually; the cost is paid at every read. *Preempt:* universal mandatory-file lock; the auto-bootstrap mechanism (post-write hook Tier 1 step 2) creates one whenever a write hits a non-exempt folder lacking an `_index.md`. The mandate is enforced structurally, not advisorily — adopter never has to remember to author the index.

**`_index.md` is just a table of contents.** Without the folder-context paragraph and cross-references, the file is regeneratable boilerplate — humans skip it because `ls` produces the same information; LLMs gain nothing from reading it. *Preempt:* the mandatory folder-context paragraph. Pedagogy is the load-bearing content; the table is scaffolding.

**Hand-authored enumeration that drifts.** A `_index.md` whose enumeration was hand-typed at folder creation drifts the moment a file is added, removed, or renamed. Three months in, the enumeration lists three files that no longer exist and misses five that do. *Preempt:* the three-tier maintenance architecture (post-write hook + librarian `index-maintain` + deep audit). The contents-enum table is derivable data, not authoritative content — the filesystem + each file's frontmatter is the source of truth; the hook and librarian keep the table aligned.

**Confusing `_index.md` with `index.md`.** Underscore-prefix is the vault convention (filesystem sort hack); no-underscore is the mkdocs/static-site convention (section-page rendering). A new adopter who copies the mkdocs default loses the sort property; a build engineer who copies the vault convention loses the rendering pipeline. *Preempt:* explicit documentation of the divergence. Vault filesystem uses `_index.md`; foundation-repo GH Pages site uses `index.md` at the rendering layer; the build step bridges via rename or symlink. Both forms are correct in their respective contexts.

**`Provides` column duplicates `Description`.** The two columns answer the same question in two formats — kebab-case category list vs prose summary. Reference-deployment empirical: 103 files carried empty `provides:` frontmatter placeholders while the `_index.md` tables hand-authored `Provides` cells that drifted from source-of-truth frontmatter; the cells were never machine-extracted. *Preempt:* the contents-enum table surfaces `File | Lines | Type | Description` and does NOT carry a `Provides` column. The `provides:` frontmatter field stays on each file as the cross-folder grep handle (R-39: `grep -r 'provides:.*<concept>'`); the per-row presentation collapses to `Type` (structural role identifier, R-32-enforced) + `Description` (prose orientation). Type and description answer different questions and earn their separate keep; provides and description did not.

## Closed questions (with disposition)

- **CQ-I1.** Underscore-prefix vs no-underscore for the folder index filename? → **Underscore-prefix (`_index.md`).** Rationale: sorts to top of directory listings; unambiguous versus human-facing `README.md`. Adopted via an atomic R-37 commit that renamed several existing folder indexes (e.g., `Skills Index.md`, `README.md` variants) to `_index.md`.
- **CQ-I2.** Should `_index.md` be normalized to mkdocs `index.md` at the vault filesystem layer? → **No — filesystem-sort property is load-bearing.** The underscore-prefix IS the point of the filename. The mkdocs/GH-Pages divergence is resolved at build time via rename/symlink at the rendering layer, not by changing the vault filesystem name.
- **CQ-I3.** Are folders with date-prefixed collections (`Daily/`, `Meetings/`, `Archive/<X>/`) exempt? → **Yes — exempt.** Rationale: contents are sequenced by date, not by name; navigation happens via date queries or tag-based filters; an index-by-name would be the wrong primitive.
- **CQ-I4.** Does the vault need a root-level meta-index aggregating all `_index.md` locations? → **No.** Vault-root `CLAUDE.md` + `Vault Architecture.md` together already serve as the meta-navigation surface. A separate cross-folder index would be redundant.
- **CQ-I5.** Should `_index.md` maintenance ship as a regeneration capability (build-time rebuild) or a per-write sync mechanism (live propagation)? → **Per-write sync, three-tier.** Post-write hook for live Claude-driven writes; librarian `index-maintain` capability for non-Claude writes (cron, Obsidian, manual moves); deep-audit mode for opt-in semantic validation. The hook's one-line loop guard (`_index.md` self-exemption) resolves the recursion concern at architectural cost zero.

## Source pointers

- Source packet: [`research/vault-construction/_index.md-design.md`](../../research/vault-construction/_index.md-design.md)
- Machine contract: [`structural-requirements.json`](./structural-requirements.json) — consumed by post-write hook + librarian `index-maintain` capability
- Companion specs in this folder: [`conventions-and-rationale.md`](./conventions-and-rationale.md) (rationale), [`structural-requirements.md`](./structural-requirements.md) (mandatory structure)
- Governance JSON registry (canonical runtime artifact): `governance/mandatory-files-rules.json` — carries the `_index.md` mandate + the exemption list
- New-folder bootstrap action set umbrella registration: [`enforcement-map-design.md`](../../research/vault-construction/enforcement-map-design.md) §Hook gate categories
- Live runtime artifacts (adopter-deployment paths, parameterized via install.sh): `hooks/pre-write-guard.sh` (R-32 Tier 2 DENY honors the `type: index` enum); `hooks/post-write-verify.sh` (Tier 1 live-sync extension + loop guard + auto-bootstrap); `skills/librarian/capabilities/placement-validate.sh` (`_index.md` placement allowlist); `skills/librarian/capabilities/index-maintain.sh` (Tier 2 sweep + Tier 3 deep audit; NEW capability ships from SP05)
