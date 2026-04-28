---
title: Section C — Your Knowledge System (extraction prompt)
type: extraction-prompt
status: ready
created: 2026-04-25
updated: 2026-04-25
parent_plan: 71-claude-foundations-engine-v2
sub_plan: 01-schemas-and-onboarder-contract
task: T-9
section: C
extraction_mode: transcript
q_ids: [C-1, C-2, C-3, C-4]
---

# Section C — Your Knowledge System (extraction prompt)

This file is the **literal extraction prompt** invoked by the onboarder
on Section C's transcript. The bootstrap engine substitutes the four
`<<<{...}>>>` placeholder blocks at runtime and submits the result to
the extraction model. Output is strict JSON conforming to the schema
declared at the bottom of this file.

Source template: Research C §3 (verbal-first onboarding — per-section
extraction pipeline). Q-ID set: `C-1`, `C-2`, `C-3`, `C-4` (canonical
lock per `onboarder-design.md` §10 and
`q-field-map.json:direct_qs.C-*`).

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
   explicit evidence ("I organize everything by client engagement" →
   organizational_method, has_structured_projects=true) or
   near-explicit inference ("nothing's organized — it's all loose
   notes" → has_structured_projects=false). If neither evidence nor
   inference reaches a confident read, omit the field — do not guess.

2. CONFIDENCE + SOURCE_SPAN. Every populated field carries a
   `confidence` score in [0.0, 1.0] and a `source_span` — the verbatim
   transcript substring that supports the field. Source spans must be
   present in the transcript character-for-character; do not paraphrase.

3. MISSING → ONE FOLLOW-UP. If a required field stays unpopulated (per
   the SCHEMA SLICE's `required: true` markers and the Section C
   minimum-viable rule below), add it to `missing_required` AND emit a
   single surgical `follow_up` question naming exactly the missing
   field. One field, one sentence. Examples that fit: "Should this be
   a fresh vault, or are you retrofitting an existing one?" / "Name at
   least one type of file you want managed — meetings, projects,
   essays, papers, repository notes, anything." If multiple required
   fields are missing, pick the highest-impact one and emit only that
   follow-up; the next pass handles the rest.

4. CONFLICT FLAG. If the transcript contradicts itself ("starting
   fresh" then later "I want to keep my existing folder structure")
   OR contradicts DISCOVERY CONTEXT (transcript says "no vault" but
   `discovery_context.paths.vault_root` is non-null), append to
   `conflicts[]`: `{ "field": "<U.path>", "transcript_value": "...",
   "context_value": "...", "evidence_spans": ["...", "..."] }`. Do
   not silently choose; let the engine surface the conflict for user
   adjudication.

5. ARRAY CAP. `U.vault.canonical_file_types[]` has no hard cap from
   the design doc, but practically: keep entries the user names
   explicitly; do not invent types. The archetype-inference pass
   (T-7a) appends archetype-derived seeds AFTER this extraction
   runs — this prompt should NOT pre-populate types it didn't hear.
   `U.system.opt_outs[]` is a conditional append (see C-3 cardinality
   note below); cap not applicable.

MINIMUM-VIABLE FOR SECTION C EXIT
- `U.vault.is_fresh` populated (boolean — from C-2)
- `U.vault.canonical_file_types[]` has at least 1 entry (from C-4)

Anything else (organizational_method, has_structured_projects,
opt_outs append) is a soft target; emit if confident, omit if not,
never block exit on its absence.

Q-ID → SCHEMA-PATH MAP (C-section subset)
- C-1 → U.vault.organizational_method (free-form short string),
        U.vault.has_structured_projects (boolean inferred from
        organizational_method text — set true if the user describes
        any structured pattern, false if "loose notes" / "no
        structure" / similar)
- C-2 → U.vault.is_fresh (boolean — true for "fresh vault", false
        for "retrofit existing")
- C-3 → U.system.opt_outs[] — CONDITIONAL APPEND, append the literal
        string value "sensitive_isolation" if and only if the user
        answers yes to the sensitive-content separate-vault question.
        Idempotent: if "sensitive_isolation" is already present in
        DISCOVERY CONTEXT's opt_outs[], do NOT re-append. If user
        answers no, omit the field entirely (no negative write).
- C-4 → U.vault.canonical_file_types[] — array of strings naming
        file types the user wants managed. Examples spanning
        archetypes: "engagement", "deliverable", "meeting",
        "repository", "deploy-log", "essay", "draft", "paper",
        "citation", "people". Do not invent; keep what the user said.

CARDINALITY NOTE (C-3)
The cardinality of C-3 is `conditional_append`, not `single`. Encode
this in your output as a single-element array assigned to
`U.system.opt_outs` ONLY when the answer is yes; omit the field
otherwise. Do not emit `false`, `null`, or an empty array — the
engine reads "field absent" as the no-op signal and "field present
with [\"sensitive_isolation\"]" as the append signal.

OUTPUT — strict JSON, no commentary, no markdown fences.

{
  "section_id": "C",
  "extraction_mode": "transcript",
  "populated": {
    "U.vault.organizational_method": "<string|absent>",
    "U.vault.has_structured_projects": "<true|false|absent>",
    "U.vault.is_fresh": "<true|false|absent>",
    "U.vault.canonical_file_types": ["<string>"],
    "U.system.opt_outs": ["sensitive_isolation"]
  },
  "confidence": {
    "<U.path>": 0.0
  },
  "source_spans": {
    "<U.path>": "<verbatim transcript substring>"
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
  `onboarder-design.md` §5 verbatim, the schema slice from
  `q-field-map.json` filtered to `direct_qs.C-*`, the discovery context
  from `~/.claude/onboarding/discovery-context.json`.
- **Stub-mode short-circuit.** If Section A captured
  `U.paths.vault_root: null`, the engine SKIPS this prompt entirely
  and writes a stub extraction output: `{ "section_id": "C",
  "extraction_mode": "stub_no_vault", "populated": {},
  "missing_required": [], "follow_up": null }`. The model is not
  invoked. Resumption when a vault is later created re-runs Section
  C from scratch.
- **C-3 idempotency.** T-10 `bootstrap-schemas.sh` is responsible for
  the de-duplicated append on `U.system.opt_outs[]`. The model emits
  the single-element array; the engine merges. Do not require the
  model to read prior state.
- **Archetype handoff.** C-section transcripts feed
  `archetype-inference.sh` (T-7a) alongside Section B. That pass
  appends archetype-derived entries to
  `U.vault.canonical_file_types[]`. The extraction pass here populates
  only what the user named; the inference pass handles the seeds.
- **Industry-neutral framing.** Examples in the prompt body span four
  archetypes (consultant, developer, writer, academic) so the model
  does not anchor on one. Same posture as the T-7 design doc.
