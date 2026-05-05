---
title: Section B — Who You Are (extraction prompt)
type: extraction-prompt
status: ready
section: B
extraction_mode: transcript
q_ids: [B-1, B-2, B-3, B-4, B-5]
---

# Section B — Who You Are (extraction prompt)

This file is the **literal extraction prompt** invoked by the onboarder
on Section B's transcript. The bootstrap engine substitutes the four
`<<<{...}>>>` placeholder blocks at runtime and submits the result to
the extraction model. Output is strict JSON conforming to the schema
declared at the bottom of this file.

Q-ID set: `B-1`, `B-2`, `B-3`, `B-4`, `B-5` (canonical lock per
`onboarder-design.md` §10 and `q-field-map.json:direct_qs.B-*`).

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
convention: U.* = user-manifest-schema instance):
<<<{schema_skeleton_slice}>>>

DISCOVERY CONTEXT (filesystem pre-fills already accepted in Section A;
cross-reference for consistency, flag conflicts, do not re-populate):
<<<{discovery_context}>>>

RULES

1. JUSTIFIED POPULATE. Populate a field only if the transcript provides
   explicit evidence ("I'm a senior partner at a consulting firm" →
   role, seniority, industry) or near-explicit inference ("I run my own
   shop" → organization=independent). If neither evidence nor inference
   reaches a confident read, omit the field — do not guess.

2. CONFIDENCE + SOURCE_SPAN. Every populated field carries a
   `confidence` score in [0.0, 1.0] and a `source_span` — the verbatim
   transcript substring that supports the field. Source spans must be
   present in the transcript character-for-character; do not paraphrase.

3. MISSING → ONE FOLLOW-UP. If a required field stays unpopulated (per
   the SCHEMA SLICE's `required: true` markers and the Section B
   minimum-viable rule below), add it to `missing_required` AND emit a
   single surgical `follow_up` question naming exactly the missing
   field — not a re-interview, not a multi-question prompt, not a
   re-record request. One field, one sentence. Examples that fit: "You
   mentioned your role but didn't name the organization — what's it
   called, or type 'independent'?" / "You named projects but not who
   you work with most closely — list one or two names." If multiple
   required fields are missing, pick the highest-impact one and emit
   only that follow-up; the next pass handles the rest.

4. CONFLICT FLAG. If the transcript contradicts itself ("I'm at a
   consulting firm" then "I'm independent") OR contradicts the
   DISCOVERY CONTEXT (transcript names a different timezone than
   `discovery_context.system.timezone`), append an entry to
   `conflicts[]`: `{ "field": "<U.path>", "transcript_value": "...",
   "context_value": "...", "evidence_spans": ["...", "..."] }`. Do
   not silently choose; let the engine surface the conflict for user
   adjudication.

5. ARRAY CAP 5. The `U.projects.active[]` and `U.people[]` arrays cap
   at 5 entries each (per `onboarder-design.md` §4 and
   `q-field-map.json:direct_qs.B-2.targets[0].max_items` /
   `B-3.targets[0].max_items`). If the transcript names more than 5,
   keep the most-emphasized or most-recent 5 — never truncate
   alphabetically or by transcript order alone. If you drop entries,
   note the count in `notes` (see output schema).

MINIMUM-VIABLE FOR SECTION B EXIT
- `U.identity.role` populated (string non-empty)
- `U.projects.active[]` has at least 1 entry with `name` + `status`
- `U.people[]` has at least 1 entry with `name` + `role`

Anything else (organization, industry, seniority, cadence, audience)
is a soft target; emit if confident, omit if not, never block exit on
its absence.

Q-ID → SCHEMA-PATH MAP (B-section subset)
- B-1 → U.identity.role, U.identity.organization, U.identity.industry,
        U.identity.seniority
- B-2 → U.projects.active[] (each: { name, status }, cap 5)
- B-3 → U.people[] (each: { name, role, relationship }, cap 5)
- B-4 → U.behavioral.cadence_default
- B-5 → U.vault.default_audience (enum: "claude" | "joint" | "human";
        map "internal/clients/execs" → "joint", "public" → "human",
        "self/notes" → "claude")

OUTPUT — strict JSON, no commentary, no markdown fences.

{
  "section_id": "B",
  "extraction_mode": "transcript",
  "populated": {
    "U.identity.role": "<string|absent>",
    "U.identity.organization": "<string|absent>",
    "U.identity.industry": "<string|absent>",
    "U.identity.seniority": "<string|absent>",
    "U.projects.active": [
      { "name": "<string>", "status": "<string>" }
    ],
    "U.people": [
      { "name": "<string>", "role": "<string>", "relationship": "<string>" }
    ],
    "U.behavioral.cadence_default": "<string|absent>",
    "U.vault.default_audience": "<\"claude\"|\"joint\"|\"human\"|absent>"
  },
  "confidence": {
    "<U.path or U.path[index].subfield>": 0.0
  },
  "source_spans": {
    "<U.path or U.path[index].subfield>": "<verbatim transcript substring>"
  },
  "missing_required": ["<U.path>"],
  "conflicts": [
    {
      "field": "<U.path>",
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
  `onboarder-design.md` §4 verbatim, the schema slice from
  `q-field-map.json` filtered to `direct_qs.B-*`, the discovery context
  from `~/.claude/onboarding/discovery-context.json`.
- **Output sink.** Model output is appended to
  `~/.claude/onboarding/extraction-output-B.json` (atomic
  tmp+rename). Confidence + source-span entries also append to
  `~/.claude/onboarding/bootstrap-log.jsonl` per the engine's audit
  contract.
- **Archetype handoff.** B-section transcripts are also fed to
  `archetype-inference.sh` after extraction completes; that
  pass writes `U.architect.prior_seed` and seeds
  `U.vault.canonical_file_types[]`. The extraction pass here does NOT
  populate `U.architect.prior_seed` — leave it for the inference
  step.
- **Industry-neutral framing.** Examples in the prompt body intentionally
  span four archetypes (consultant — engagement / client; developer —
  repository / deploy; writer — essay / draft; academic — paper /
  citation) so the model does not anchor on one.
