---
title: Section A — Discovery Review (stub, no LLM extraction)
type: extraction-prompt
status: stub
created: 2026-04-25
updated: 2026-04-25
parent_plan: 71-claude-foundations-engine-v2
sub_plan: 01-schemas-and-onboarder-contract
task: T-9
section: A
extraction_mode: deterministic
---

# Section A — Discovery Review (stub)

**No LLM extraction runs for this section.** Section A is a deterministic
confirmation pass over filesystem pre-fills surfaced by the bootstrap
engine. Inputs are typed/clicked UX state, not free-form transcripts;
there is no transcript to interpret, no confidence to score, and no
follow-up loop to run.

This stub exists so the prompt-set has 1:1 coverage of the 5 sections
declared in `onboarder-design.md` §2 — every section gets a file even
when extraction does not. Consumers (T-10 `bootstrap-schemas.sh`) can
iterate `extraction-prompts/section-{A..E}.md` deterministically.

## What runs instead

Section A is a single confirmation screen (`onboarder-design.md` §3).
The user sees discovery pre-fills and either accepts all (one keystroke)
or types corrections inline. The bootstrap engine then writes the four
A-prefix direct Qs and six A-CB-prefix checkbox Qs **directly from UX
state** — no model call, no transcript ingestion, no JSON inference.

Q-IDs handled this way:

- **Direct:** `A-1`, `A-2`, `A-3`, `A-4`
- **Checkbox:** `A-CB1`, `A-CB2`, `A-CB3`, `A-CB4`, `A-CB5`, `A-CB6`

Their target schema paths and pre-fill sources are defined in
`~/.claude/onboarding/q-field-map.json` (`direct_qs.A-*` and
`checkbox_qs.A-CB*`). The engine reads the map, applies UX state, and
writes deterministically. Idempotency is trivial — the same UX state
produces the same write.

## Why no extraction prompt

Three structural reasons:

1. **No transcript.** The user does not record audio in Section A. There
   is nothing for an extraction model to read.
2. **No ambiguity.** Each pre-fill is sourced from a deterministic probe
   (`git config --global user.name`, `systemsetup -gettimezone`,
   filesystem scan, MCP enumeration). Confirming a probe result does not
   require natural-language interpretation.
3. **No cardinality decisions.** The schema cardinalities for A-prefix
   Q-IDs are pre-decided in `q-field-map.json`. There are no array caps
   to enforce, no conditional appends to flag, no enum mappings to
   resolve.

Failure modes (probe returns null, user declines a tool, vault root not
detected) are handled by the engine's deterministic fallback rules —
not by an extraction model. See `onboarder-design.md` §3 "Fallback".

## Output (engine-written, not model-written)

The engine writes the same JSON shape that B/C/D extractions emit, so
`bootstrap-schemas.sh` can consume all five sections uniformly:

```json
{
  "section_id": "A",
  "extraction_mode": "deterministic",
  "populated": {
    "U.identity.name": "<from UX>",
    "U.identity.email": "<from UX>",
    "U.system.timezone": "<from UX>",
    "U.paths.vault_root": "<from UX or null>",
    "U.vault.root": "<mirror of paths.vault_root>",
    "U.tools.calendar": "<from UX or null>",
    "U.tools.messaging": ["<from UX>"],
    "U.tools.email": "<from UX or null>",
    "U.tools.transcription": "<from UX or null>",
    "U.tools.tasks": "<from UX or null>",
    "U.tools.dev_env": "<from UX or null>"
  },
  "confidence": {},
  "source_spans": {},
  "missing_required": [],
  "conflicts": [],
  "follow_up": null
}
```

`confidence` and `source_spans` are intentionally empty — deterministic
writes carry no probabilistic claim. `missing_required` is non-empty
only if a required A-prefix Q-ID returned null AND the user did not
type a correction; the engine surfaces those at section-exit time.
