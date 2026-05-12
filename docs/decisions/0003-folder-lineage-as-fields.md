# ADR-0003: Folder Lineage as Fields, Not Types

**Status:** accepted
**Date:** 2026-05-11
**Deciders:** Foundation-repo architecture (Plan 81 SP03)
**Tags:** frontmatter, schema, taxonomy, folder-lineage

## Context

The vault schema originally carried `engagement` and `project` as canonical TYPE values — files at `Engagements/<X>/CLAUDE.md` could declare `type: engagement`, and files at `Engagements/<X>/Projects/<Y>/<file>.md` could declare `type: project`. These TYPE slots were aspirational design from the schema's first version.

Empirical measurement at design-review time (production vault audit): **zero files carried `type: engagement`; two files carried `type: project`**. Meanwhile, **237 files carried `engagement: <slug>` as a FIELD** and **125 files carried `project: <slug>` as a FIELD** under the folder tree. The TYPE slots were never instantiated — the files that *should* have been engagement-level overview docs were actually `type: navigation` (the CLAUDE.md at the engagement root) or `type: context` (the project-overview doc).

The empirical disposition was clear: `engagement` and `project` are not what a file IS. They are where a file LIVES. The structural confusion between "what a file is" and "where a file lives" was producing aspirational-but-unused TYPE slots while the actual lineage propagation happened at FIELD level.

A second concern surfaced: LLMs that consume vault files read frontmatter, not directory ancestry. A file moved between engagements would silently lose its engagement context unless lineage propagated to file-level fields. The folder is the structural artifact; the LLM needs the field.

## Decision

- **Retire `engagement` and `project` from the TYPE allowlist.** Documented in the schema's `_retired_types` block with `decision_ref`, `reason`, and `replacement` guidance.
- **Mandate `engagement:` and `project:` as FIELD slots.** Any file living at `Engagements/<X>/Projects/<Y>/**` MUST carry `engagement: <X>` + `project: <Y>` as frontmatter fields AND `#engagement/<X>` + `#project/<Y>` as tags.
- **Encode the rule generically in `_path_rules`.** The schema declares `_path_rules.rules[]` as a parameterized array; the foundation-repo ships the consultant default; adopter archetypes extend with their own lineage patterns (`Topics/<X>/Studies/<Y>/` for researcher, `Repos/<X>/Epics/<Y>/` for developer, etc.) by adding entries to the array.
- **Hook contract:** writes that violate the lineage rule are DENIED at write-time. The hook validates that `engagement:` + `project:` field values match the directory ancestor segments.
- **Exempt folder-level navigation files** (`Engagements/<X>/CLAUDE.md`, `Engagements/<X>/_index.md`, plus equivalent files at project depth) — they are about the folder itself, not about a file within it.

## Consequences

**Positive:**
- TYPE allowlist gets honest. The slots that aspirational-but-unused are retired explicitly with `_retired_types` documentation; the field slots that are actually load-bearing are codified.
- LLM consumers can resolve hierarchical context from frontmatter alone (no need to walk directory ancestry).
- Folder-mirrors-tag invariant holds: a file's `engagement:` field, its `#engagement/<slug>` tag, and its parent directory name all match.
- Generic `_path_rules` encoding lets researcher / developer / manager / custom archetypes extend without schema-shape changes.

**Negative:**
- Existing files that did carry `type: engagement` or `type: project` (2 files in the reference vault) need migration. Migration tooling deferred.
- The lineage rule must be enforced consistently — files moved between engagements without frontmatter update become silent drift. Hook enforcement closes the gap at write-time; librarian audit catches existing drift.
- Adopters whose archetype doesn't fit the folder-hierarchy assumption (e.g., a flat-vault archetype) must either accept the consultant default or author a Layer-3 overlay that adds their lineage pattern.

**Neutral:**
- The retirement is documented, not undone. Future-readers see `_retired_types.engagement.decision_ref` pointing to this ADR.
- The rule's `rule_id_ref` is left as a placeholder for the hook-implementation-time canonical R-XX assignment (the schema-side encoding lands first; the rule ID assignment happens at hook-landing).

## Source decision provenance

- Plan 81 SP03 spec §Frontmatter schema — Folder-lineage frontmatter convention (D1 resolution, 2026-05-11) (`~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/spec.md` L39)
- Plan 81 SP03 Session 4 architecture decision (`~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/Session-04-architecture-decision.md` — Peter-approved 2026-05-11)
- Session 4 follow-up handoff narrative (`~/.claude-plans/81-claude-stem-dogfood-optimization/03-standards/handoff.md` L1044-1120)
- Empirical measurement: zero files at TYPE `engagement`; 2 files at TYPE `project`; 237 + 125 files at FIELD slots in the reference vault at design-review time
- T-20 hook contract specification (in flight at Plan 81 SP03)

## Related ADRs

- [ADR-0002](./0002-unified-with-per-archetype-entries.md) — schema's per-type entries declare which fields reference engagement/project
- [ADR-0001](./0001-tiered-compliance.md) — the lineage hook fires at the Strict tier's DENY layer
