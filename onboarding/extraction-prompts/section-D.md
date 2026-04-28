---
title: Section D — Trust, Privacy & Automation (extraction prompt)
type: extraction-prompt
status: ready
created: 2026-04-25
updated: 2026-04-25
parent_plan: 71-claude-foundations-engine-v2
sub_plan: 01-schemas-and-onboarder-contract
task: T-9
section: D
extraction_mode: transcript
q_ids: [D-1, D-2, D-3, D-4]
---

# Section D — Trust, Privacy & Automation (extraction prompt)

This file is the **literal extraction prompt** invoked by the onboarder
on Section D's transcript. The bootstrap engine substitutes the four
`<<<{...}>>>` placeholder blocks at runtime and submits the result to
the extraction model. Output is strict JSON conforming to the schema
declared at the bottom of this file.

Source template: Research C §3 (verbal-first onboarding — per-section
extraction pipeline). Q-ID set: `D-1`, `D-2`, `D-3` (conditional on
`D-2 == "architect"`), `D-4` (canonical lock per
`onboarder-design.md` §10 and `q-field-map.json:direct_qs.D-*`).

---

## Prompt

```
You are extracting structured schema fields from a verbal onboarding
transcript. The user spoke freely in response to a prompt card; your
job is to populate only fields you can justify from explicit transcript
evidence or clear inference, score each, and flag what's missing.

TRANSCRIPT:
<<<{transcript}>>>

QUESTIONS ASKED (the prompt card the user saw — quote exactly):
<<<{section_prompt_card}>>>

SCHEMA SLICE (the only fields you may populate; leave unfilled fields
absent from the populated object — do not emit nulls. Path-prefix
convention: U.* = user-manifest-schema instance; O.* = orchestration-
schema instance):
<<<{schema_skeleton_slice}>>>

DISCOVERY CONTEXT (filesystem pre-fills already accepted in Section A;
cross-reference for consistency, flag conflicts, do not re-populate):
<<<{discovery_context}>>>

RULES

1. JUSTIFIED POPULATE. Populate a field only if the transcript provides
   explicit evidence ("I want it to ask before doing anything risky" →
   autonomy=strict; "let it rip" → autonomy=permissive) or
   near-explicit inference ("daily cleanup sounds great" → job=
   librarian). If neither evidence nor inference reaches a confident
   read, omit the field — do not guess.

2. CONFIDENCE + SOURCE_SPAN. Every populated field carries a
   `confidence` score in [0.0, 1.0] and a `source_span` — the verbatim
   transcript substring that supports the field. Source spans must be
   present in the transcript character-for-character; do not paraphrase.

3. MISSING → ONE FOLLOW-UP. If a required field stays unpopulated (per
   the SCHEMA SLICE's `required: true` markers and the Section D
   minimum-viable rule below), add it to `missing_required` AND emit a
   single surgical `follow_up` question naming exactly the missing
   field. One field, one sentence. Examples that fit: "How autonomous
   should Claude be — strict, balanced, or permissive?" / "Which job
   first — librarian or architect — or skip automation?" If multiple
   required fields are missing, pick the highest-impact one and emit
   only that follow-up; the next pass handles the rest.

4. CONFLICT FLAG. If the transcript contradicts itself ("strict
   guardrails" then later "I trust it to do whatever") OR contradicts
   DISCOVERY CONTEXT, append to `conflicts[]`: `{ "field": "<path>",
   "transcript_value": "...", "context_value": "...",
   "evidence_spans": ["...", "..."] }`. Do not silently choose; let
   the engine surface the conflict for user adjudication.

5. ARRAY CAP. `U.architect.prior_seed` is a string field, not an
   array — see D-3 cardinality note below. There are no array fields
   in this section's schema slice. The cap rule from B/C does not
   apply here; if you find yourself wanting to emit a list, you are
   outside the schema slice.

MINIMUM-VIABLE FOR SECTION D EXIT
- `U.behavioral.autonomy` populated (one of "strict" | "balanced" |
  "permissive" — from D-1)
- `O.jobs[0].id` populated (one of "librarian" | "architect"), OR
  `O.jobs` set to the empty array `[]` if user opts out of automation
  (from D-2)

Anything else (D-3 architect concerns, D-4 notification style) is a
soft target; emit if confident, omit if not, never block exit on its
absence. D-4 has a deterministic default (`digest`) the engine will
apply if you omit it.

Q-ID → SCHEMA-PATH MAP (D-section subset)
- D-1 → U.behavioral.autonomy (enum: "strict" | "balanced" |
        "permissive"; map free text — "strict guardrails" / "ask
        before risky things" → "strict"; "use your judgment" /
        "balanced" / "default sensible" → "balanced"; "let it rip" /
        "go ahead" / "permissive" → "permissive")
- D-2 → O.jobs[0].id (enum: "librarian" | "architect"); if user
        opts out of all automation, emit `O.jobs` as the empty array
        `[]` (NOT `O.jobs[0].id` set to null). The engine applies
        default schedule + log_path + idle_watchdog from
        `q-field-map.json:direct_qs.D-2.defaults_applied`.
- D-3 → U.architect.prior_seed — STRING APPEND (cardinality "append",
        strategy "comma_join"). See D-3 cardinality note below. Only
        applies if D-2 resolved to "architect"; otherwise omit.
- D-4 → U.behavioral.hook_preferences.notification_style (enum:
        "quiet" | "digest" | "notification"; map free text —
        "leave me alone" / "don't bother me" → "quiet"; "daily
        summary" / "morning brief" → "digest"; "ping me" / "system
        notifications" → "notification"). Default if omitted: "digest".

CARDINALITY NOTE (D-2)
D-2's cardinality is `single` for the populated case and `fallback`
for the opt-out case. Two valid output shapes:

  (a) job chosen:
      "populated": { "O.jobs[0].id": "librarian" }   // or "architect"

  (b) opt-out:
      "populated": { "O.jobs": [] }

Do not emit both shapes. Do not emit `O.jobs[0].id` set to null,
empty string, or "none" — those are not valid states.

CARDINALITY NOTE (D-3)
D-3's cardinality is `append` to `U.architect.prior_seed`, comma-joined
to whatever the archetype-inference pass already wrote (a single
archetype label like "developer"). Idempotency rule: if the
DISCOVERY CONTEXT shows `U.architect.prior_seed` already contains
the user's concern phrasing, do NOT re-append. The model emits the
NEW concerns only — as a single string ready to be comma-joined by
the engine. Example: archetype inference wrote "developer"; user
named three concerns "slow CI, doc rot, test flakiness" — model
emits `"slow CI, doc rot, test flakiness"`, engine produces final
field value `"developer, slow CI, doc rot, test flakiness"`. Do not
emit the leading archetype label; the engine prepends.

CONDITIONAL ON D-2
D-3 is conditional on `D-2 == "architect"`. If D-2 resolved to
"librarian" or empty array, OMIT `U.architect.prior_seed` entirely
from the output — even if the transcript names architect-style
concerns. The engine treats off-condition emissions as schema
violations.

OUTPUT — strict JSON, no commentary, no markdown fences.

{
  "section_id": "D",
  "extraction_mode": "transcript",
  "populated": {
    "U.behavioral.autonomy": "<\"strict\"|\"balanced\"|\"permissive\"|absent>",
    "O.jobs[0].id": "<\"librarian\"|\"architect\"|absent>",
    "O.jobs": [],
    "U.architect.prior_seed": "<comma-joined-concerns|absent>",
    "U.behavioral.hook_preferences.notification_style": "<\"quiet\"|\"digest\"|\"notification\"|absent>"
  },
  "confidence": {
    "<path>": 0.0
  },
  "source_spans": {
    "<path>": "<verbatim transcript substring>"
  },
  "missing_required": ["<path>"],
  "conflicts": [
    {
      "field": "<path>",
      "transcript_value": "<string>",
      "context_value": "<string>",
      "evidence_spans": ["<verbatim transcript substring>"]
    }
  ],
  "follow_up": "<one sentence|null>",
  "notes": "<string|null>"
}
```

---

## Notes for the bootstrap engine (not model-facing)

- **Substitution.** `<<<{transcript}>>>`, `<<<{section_prompt_card}>>>`,
  `<<<{schema_skeleton_slice}>>>`, `<<<{discovery_context}>>>` are the
  only four substitution sites. Engine reads the prompt card from
  `onboarder-design.md` §6 verbatim, the schema slice from
  `q-field-map.json` filtered to `direct_qs.D-*`, the discovery context
  from `~/.claude/onboarding/discovery-context.json`.
- **Two valid populated shapes for jobs.** Output schema documents both
  the "job chosen" and "opt-out" shapes for the same JSON object. The
  engine validates exclusivity — exactly one of `O.jobs[0].id` (string)
  or `O.jobs` (empty array) must be present. Both present, both
  absent, or `O.jobs[0].id` non-empty alongside `O.jobs: [...]` is a
  schema violation.
- **D-2 defaults application.** The engine reads
  `q-field-map.json:direct_qs.D-2.defaults_applied` and applies the
  defaults bundle (`enabled`, `schedule`, `log_path`,
  `idle_watchdog_sec`) AFTER the model emits `O.jobs[0].id`. The
  model only chooses which job ID — schedule and watchdog are
  deterministic per ID. SP07 onboarder UX surfaces them in
  confirmation summary but does not re-prompt.
- **D-3 comma-join handled engine-side.** The model emits user
  concerns as a single string; the engine prepends the archetype
  label and handles the comma-join. The model MUST NOT prepend the
  archetype label itself.
- **D-4 default.** If the model omits
  `U.behavioral.hook_preferences.notification_style`, the engine
  writes `"digest"` per
  `q-field-map.json:direct_qs.D-4.targets[0].default_value`. The
  model does not need to emit a default; absence is the signal.
- **Industry-neutral framing.** Examples in the prompt body span four
  archetypes' concerns (consultant — engagement deadlines / client
  scope creep; developer — slow CI / doc rot; writer — draft
  freshness / publication cadence; academic — citation rot / paper
  pipeline) so the model does not anchor on one. Same posture as
  the T-7 design doc.
