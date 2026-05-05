---
title: Section E — Final Checkboxes (stub, no LLM extraction)
type: extraction-prompt
status: stub
section: E
extraction_mode: deterministic
---

# Section E — Final Checkboxes (stub)

**No LLM extraction runs for this section.** Section E is three
deterministic privacy/automation toggles. Inputs are checkbox UX state,
not free-form transcripts; there is no transcript to interpret, no
confidence to score, and no follow-up loop to run.

This stub exists so the prompt-set has 1:1 coverage of the 5 sections
declared in `onboarder-design.md` §2 — every section gets a file even
when extraction does not. Consumers (`bootstrap-schemas.sh`) can
iterate `extraction-prompts/section-{A..E}.md` deterministically.

## What runs instead

Section E is a single checkbox screen (`onboarder-design.md` §7). The
user toggles three independent boolean gates. The bootstrap engine
writes them **directly from UX state** to
`U.behavioral.hook_preferences.*` — no model call, no transcript
ingestion, no JSON inference.

Q-IDs handled this way:

- `E-1` — auto-commit + push (`auto_commit_enabled`)
- `E-2` — claude-mem cross-session memory (`memory_consolidation_enabled`)
- `E-3` — multi-session coordination (`multi_session_enabled`)

Their target schema paths and default values are defined in
`~/.claude/onboarding/q-field-map.json` (`section_e_binaries.E-*`).
All three default OFF; if the user closes the screen without checking
anything, defaults persist.

## Why no extraction prompt

Three structural reasons:

1. **No transcript.** The user does not record audio in Section E.
   There is nothing for an extraction model to read.
2. **Binary semantics.** Each toggle is `true` or `false`; no
   natural-language interpretation can shift that.
3. **Privacy-affecting.** These three flags govern what `~/.claude/`
   data leaves the user's machine (auto-commit + push, claude-mem
   consolidation, multi-session shared state). Inferring privacy
   choices from speech would invert the consent model — explicit click
   is the only acceptable input mode.

Failure modes are not applicable. The screen is non-blocking; the user
can skip it entirely, in which case all three flags persist as `false`.

## Output (engine-written, not model-written)

The engine writes the same JSON shape that B/C/D extractions emit, so
`bootstrap-schemas.sh` can consume all five sections uniformly:

```json
{
  "section_id": "E",
  "extraction_mode": "deterministic",
  "populated": {
    "U.behavioral.hook_preferences.auto_commit_enabled": false,
    "U.behavioral.hook_preferences.memory_consolidation_enabled": false,
    "U.behavioral.hook_preferences.multi_session_enabled": false
  },
  "confidence": {},
  "source_spans": {},
  "missing_required": [],
  "conflicts": [],
  "follow_up": null
}
```

`confidence` and `source_spans` are intentionally empty — deterministic
writes carry no probabilistic claim. `missing_required` is always
empty for Section E (no required toggles; defaults are valid).
`populated` values reflect actual UX state at section-exit time; the
shape above shows the all-defaults case.

## Pre-condition note for E-1

`E-1` ships with a prerequisite check (per
`q-field-map.json:section_e_binaries.E-1.prerequisite_check`) — a
configured git remote on `~/.claude/` is required before the toggle is
honored at runtime. The bootstrap engine writes the boolean
unconditionally; the SessionEnd hook is the consumer that checks the
remote at fire time and refuses to push if absent. No extraction
involvement either way.
