---
title: Verbal-First Onboarder — Design Doc
type: design-doc
status: stable
---

# Verbal-First Onboarder — Design Doc

The onboarder collects identity + config into a populated `user-manifest.json`,
`vault-schema.json`, and `orchestration.json` via a verbal-first 5-section
flow. Each section presents one prompt card, captures a free-form recording
(or typed fallback), and runs a per-section extraction pass that writes
schema fragments. Total user budget: ~25–35 minutes.

This doc is the onboarder's machine-checkable design contract:

- 5 sections (A–E), each with prompt card / seeded schema fields /
  minimum-viable acceptance / fallback.
- Archetype inference heuristic (keyword tables in companion JSON).
- Confidence threshold policy.
- 17 direct questions + 6 checkbox fields enumerated by stable Q-ID.

`archetype-inference.sh` consumes the keyword tables at
`archetype-keywords.json`. `q-field-map.json` owns the Q-ID →
schema-path mapping; this doc declares the Q-ID set and target schema paths
that map encodes.

---

## 1. Schema alignment

All seeded fields below resolve to live paths in
`~/.claude/schemas/user-manifest-schema.json`,
`~/.claude/schemas/orchestration-schema.json`, and
`~/.claude/schemas/vault-schema.json`.

**Three field names from prior research that do NOT exist in the live
schema** — the onboarder aliases as noted:

| Research-cited path | Live schema destination | Notes |
|---|---|---|
| `identity.archetype` | `architect.prior_seed` (string) | No dedicated archetype field. Inference label written as a single token to `architect.prior_seed`; Section D answers append to the same field, comma-joined. |
| `identity.projects[]` | `projects.active[]` | Top-level `projects` section in the canonical 10-section shape. |
| `hooks.{auto_commit,memory_consolidation,multi_session}.enabled` | `behavioral.hook_preferences.<key>_enabled` | The schema's `hook_preferences` is `additionalProperties: true`; the opaque keys defined here are the de-facto contract until a `hooks-schema.json` lands. |

These aliases are deterministic — extraction targets the live paths, not
the research-cited names.

---

## 2. Section flow at a glance

| Section | Mode | User time | Direct Qs | Checkbox fields | Binary toggles |
|---|---|---|---|---|---|
| A — Discovery Review | confirmation, no recording | ~2 min | 4 (A-1..A-4) | 6 (A-CB1..A-CB6) | — |
| B — Who You Are | recording, 3–5 min | 3–5 min | 5 (B-1..B-5) | — | — |
| C — Knowledge System | recording, 2–4 min | 2–4 min | 4 (C-1..C-4) | — | — |
| D — Trust & Automation | recording, 2–3 min | 2–3 min | 4 (D-1..D-4) | — | — |
| E — Final Checkboxes | confirmation, no recording | ~1 min | — | — | 3 (E-1..E-3) |

**Direct Qs total: 17.** **Checkbox fields total: 6** (Section A tool
checklist). **Section E binaries** (3) are deterministic privacy gates with
their own UX and are tracked separately from the "checkbox fields" count.

---

## 3. Section A — Discovery Review (no recording)

**Purpose.** Confirm filesystem pre-fills before the user records anything.
Single screen. User accepts all (one keystroke) or types corrections inline.

### Prompt card

```
Here's what we already know. Correct anything wrong, then continue.

  Name:        ${pre_fill.name}        [edit]
  Email:       ${pre_fill.email}       [edit]
  Timezone:    ${pre_fill.timezone}    [edit]
  Vault root:  ${pre_fill.vault_root}  [edit]   (or "no vault yet")

Tools detected on this machine — confirm which you actively use:

  [x] Calendar:       ${pre_fill.calendar}
  [x] Messaging:      ${pre_fill.messaging[*]}     (multi-select)
  [x] Email:          ${pre_fill.email_client}
  [ ] Transcription:  ${pre_fill.transcription}
  [x] Tasks:          ${pre_fill.tasks}
  [x] Dev environment:${pre_fill.dev_env}
```

### Direct Qs (4)

| Q-ID | Prompt | Target schema path | Source of pre-fill |
|---|---|---|---|
| A-1 | Confirm full name | `identity.name` | `git config --global user.name` |
| A-2 | Confirm email | `identity.email` | `git config --global user.email` |
| A-3 | Confirm timezone | `system.timezone` | `systemsetup -gettimezone` (or `date +%Z`) |
| A-4 | Confirm vault root (or declare "no vault") | `paths.vault_root` + `vault.root` (mirror) | filesystem scan: `~/Documents/*Vault*`, `~/Vault`, `~/Obsidian` |

### Checkbox fields (6)

| Q-ID | Field | Schema path | Detection source |
|---|---|---|---|
| A-CB1 | Calendar | `tools.calendar` | reads connected MCPs from `settings.json` |
| A-CB2 | Messaging | `tools.messaging[]` | reads connected MCPs (multi-select) |
| A-CB3 | Email client | `tools.email` | reads connected MCPs |
| A-CB4 | Transcription | `tools.transcription` | reads connected MCPs |
| A-CB5 | Tasks | `tools.tasks` | reads connected MCPs |
| A-CB6 | Dev environment | `tools.dev_env` | `which code cursor zed nvim` + shell PATH probe |

### Schema fields seeded

`identity.name`, `identity.email`, `system.timezone`, `paths.vault_root`,
`vault.root`, `tools.calendar`, `tools.messaging[]`, `tools.email`,
`tools.transcription`, `tools.tasks`, `tools.dev_env`.

### Minimum-viable

User hits Enter to accept all pre-fills. No recording, no extraction pass.

### Fallback

User types corrections inline; deterministic write. If a tool was not
detected and the user does not check the box, the field is left `null`.
If no vault is declared, `paths.vault_root` and `vault.root` are written
`null` and Section C's vault questions degrade to stub mode (see §5
Fallback).

---

## 4. Section B — Who You Are (record 3–5 min)

### Prompt card

```
Record yourself answering all five, in any order. Aim for 3–5 minutes.
You can re-record this section without losing anything from other sections.

  1. What do you do — in one or two sentences?
     (Role, firm or independent, industry.)

  2. What are your 3–5 active projects or clients right now?
     What stage is each at?

  3. Who are the 3–5 people you work with most closely?
     Names and roles.

  4. What's your typical work cadence — daily standups, weekly sprints,
     ad hoc, something else?

  5. Who's your audience for the work you produce —
     internal team, clients, executives, public, mix?
```

### Direct Qs (5)

| Q-ID | Prompt focus | Target schema path |
|---|---|---|
| B-1 | Role / firm / industry | `identity.role`, `identity.organization`, `identity.industry`, `identity.seniority` |
| B-2 | Active projects + stages | `projects.active[].{name,status}` (cap 5) |
| B-3 | Collaborators | `people[].{name,role,relationship}` (cap 5) |
| B-4 | Cadence | `behavioral.cadence_default` |
| B-5 | Audience | `vault.default_audience` (one of `claude` \| `joint` \| `human`; "internal/clients/execs" → `joint`, "public" → `human`, "self/notes" → `claude`) |

### Schema fields seeded

`identity.role`, `identity.organization`, `identity.industry`,
`identity.seniority`, `projects.active[]`, `people[]`,
`behavioral.cadence_default`, `vault.default_audience`. The transcript also
feeds the archetype-inference pass (§7) which writes
`architect.prior_seed` and appends to `vault.canonical_file_types[]`.

### Minimum-viable

Role string + at least one project + at least one person. If transcript
yields fewer, extraction returns `missing_required` and the onboarder runs
one surgical text follow-up (§6).

### Fallback

If transcript is too thin after one follow-up, block section exit, surface
yellow-highlighted summary, accept inline-typed corrections. If the user
declines audio entirely, swap the recorder for a single multi-line textbox
displaying the same prompt card; same extraction pipeline runs on the
typed prose.

---

## 5. Section C — Your Knowledge System (record 2–4 min)

### Prompt card

```
Record yourself answering all four, in any order. Aim for 2–4 minutes.

  1. Do you already have an Obsidian vault? If yes, describe how it's
     organized — folders, tags, links, or a mix.

  2. For this new foundation: fresh vault, or retrofit your existing one?

  3. Is any of your content sensitive enough to live in a separate,
     Claude-isolated vault? Yes/no is fine.

  4. What kinds of files do you most want Claude to help you manage —
     meetings, projects, people, notes, code, writing? List them.
```

### Direct Qs (4)

| Q-ID | Prompt focus | Target schema path |
|---|---|---|
| C-1 | Existing vault + organization style | `vault.organizational_method` (free text), `vault.has_structured_projects` (boolean inferred) |
| C-2 | Fresh vs retrofit | `vault.is_fresh` (boolean) |
| C-3 | Sensitive content separate vault | `system.opt_outs[]` appends `"sensitive_isolation"` if yes; otherwise no-op |
| C-4 | File types | `vault.canonical_file_types[]` |

### Schema fields seeded

`vault.organizational_method`, `vault.is_fresh`,
`vault.has_structured_projects`, `vault.canonical_file_types[]`,
`system.opt_outs[]` (conditional). Archetype inference (§7) seeds
additional canonical-file-types per its `seeds.vault_canonical_file_types_add`
table.

### Minimum-viable

Fresh-vs-retrofit decision (C-2) + at least one named file type (C-4).

### Fallback

If Section A captured `paths.vault_root: null`, Section C runs in stub
mode: skip C-1 and C-2; ask only C-3 and C-4 (or skip the section
entirely). Manifest records `vault.root: null` and downstream librarian
runs in stub mode until a vault is created.

---

## 6. Section D — Trust, Privacy & Automation (record 2–3 min)

### Prompt card

```
Record yourself answering all four, in any order. Aim for 2–3 minutes.

  1. How autonomous should Claude be — strict guardrails, balanced,
     or permissive? Use your own words.

  2. Should Claude run one background job for you on a schedule?
     If yes, which sounds more useful first —
       a daily librarian that keeps your vault clean, or
       a weekly architect that audits your system and recommends
       improvements?

  3. (Only if you chose architect.)
     What top three things would you want that weekly audit to watch for?

  4. How should Claude nudge you about its work —
     quiet, daily digest, or macOS notifications?
```

### Direct Qs (4)

| Q-ID | Prompt focus | Target schema path |
|---|---|---|
| D-1 | Autonomy level | `behavioral.autonomy` (one of `strict` \| `balanced` \| `permissive`; free text mapped) |
| D-2 | First scheduled job | `orchestration.jobs[0].id` (one of `librarian` \| `architect`; or empty array if user opts out) |
| D-3 | Architect concerns (conditional on D-2 = architect) | `architect.prior_seed` (concerns joined by `; `; appends to whatever the archetype inference wrote) |
| D-4 | Notification style | `behavioral.hook_preferences.notification_style` (one of `quiet` \| `digest` \| `notification`) |

### Schema fields seeded

`behavioral.autonomy`, `orchestration.jobs[0]` (id, enabled=true,
schedule defaulted to `06:00` for librarian and `Mon 06:00` for architect,
log_path defaulted, idle_watchdog_sec=180, budget_usd=5/10 per-job,
model=sonnet/opus per-job, skip_weekends=true for librarian),
`architect.prior_seed`,
`behavioral.hook_preferences.notification_style`.

The 8-question customization sub-flow that surfaces `budget_usd`, `model`,
and `skip_weekends` as user-facing overrides is documented at
`onboarding/initial-job-setup-flow.md`.

### Minimum-viable

Autonomy level (D-1) + job choice (D-2). D-3 is conditional and may be
skipped without blocking. D-4 has a deterministic default (`digest`) if
omitted.

### Fallback

If user says "skip automation" anywhere in the transcript,
`orchestration.jobs: []` is written and D-2/D-3 are skipped without
follow-up. If autonomy level is ambiguous, surgical follow-up presents
three radio buttons.

---

## 7. Section E — Final Checkboxes (no recording)

### Prompt card

```
Three privacy and automation toggles. All default OFF.

  [ ] Auto-commit and push ~/.claude/ changes to a git remote at
      session end. (Requires a configured remote.)

  [ ] Let Claude consolidate cross-session memory via claude-mem.

  [ ] Enable multi-session coordination. Useful if you run multiple
      Claude Code windows simultaneously.
```

### Binary toggles (3)

| Q-ID | Field | Schema path |
|---|---|---|
| E-1 | Auto-commit + push | `behavioral.hook_preferences.auto_commit_enabled` (boolean) |
| E-2 | claude-mem consolidation | `behavioral.hook_preferences.memory_consolidation_enabled` (boolean) |
| E-3 | Multi-session coordination | `behavioral.hook_preferences.multi_session_enabled` (boolean) |

### Schema fields seeded

Three boolean keys under `behavioral.hook_preferences`.

### Minimum-viable

All boxes default OFF. No required interaction.

### Fallback

None — deterministic. If the user closes the screen, defaults persist.

---

## 8. Confidence threshold policy

Each extracted field carries a confidence score in `[0.0, 1.0]` and a
`source_span` (the transcript substring that supports it).

| Confidence | Behavior |
|---|---|
| ≥ 0.85 | Populate silently. Field appears in the post-section summary screen, but no confirmation is required. |
| 0.5 – 0.85 | Populate, **flag for confirmation** in the summary. User can accept, edit, or clear. |
| < 0.5 | Surface as `missing_required`. Trigger **one surgical text follow-up** ("You mentioned your role but didn't name the organization — fill in or type 'independent'"). Never re-interview. Never re-record for one field. |

If a **required** field stays unpopulated after the single follow-up,
block section exit and require inline-typed correction in the summary
screen. This is the "block and log" failure mode declared in the
onboarder Output Contract.

A required field is any field whose absence would make the manifest fail
schema validation. Section minimum-viable lists (above) are the
authoritative required-field set per section.

---

## 9. Archetype inference heuristic

Archetype inference runs on the concatenated transcripts from Section B
and Section C, after extraction completes for both. The inference is a
deterministic shell pass implemented in `archetype-inference.sh`,
loading keyword tables from
`~/.claude/onboarding/archetype-keywords.json`.

**The keyword tables are not duplicated in this design doc** — they live
exclusively in the JSON file, which `archetype-inference.sh` reads at
runtime. This doc owns the scoring rule and write targets.

### Scoring rule

For each archetype `A` with positive set `P_A` and negative set `N_A`:

```
positive_hits(A) = count of distinct tokens in P_A that appear in
                   the lowercased B+C transcript
negative_hits(A) = count of distinct tokens in N_A that appear in
                   the lowercased B+C transcript
score(A)         = positive_hits(A) - 0.5 * negative_hits(A)
```

Selection rule:

```
top       = argmax_A score(A)
runner_up = second-highest score
IF score(top) >= 2 AND (score(top) - score(runner_up)) >= 1:
    archetype = top
ELSE:
    archetype = "generalist"
```

**Confidence**: `min(1.0, score(top) / 6.0)`. The divisor 6 is calibrated
so that ~6 unambiguous positive hits saturate to confidence 1.0.

The match mode is case-insensitive, word-or-phrase. Multi-word tokens
require exact phrase order. Tokenization details and the constants
(`negative_weight=0.5`, `min_score=2`, `min_margin=1`,
`fallback_archetype="generalist"`) are mirrored in
`archetype-keywords.json` under `scoring`.

### Write targets

- `architect.prior_seed` — set to the chosen archetype label as a single
  token (e.g., `"developer"`). Section D-3 architect-concerns text appends
  to this field, comma-joined.
- `vault.canonical_file_types[]` — extended with the archetype's
  `seeds.vault_canonical_file_types_add` list (deduplicated against
  whatever Section C-4 produced).
- `vault.organizational_method` — if Section C-1 returned null or
  low-confidence, fall back to the archetype's
  `seeds.vault_organizational_method_hint` (e.g.,
  `"engagement-based"` for consultant).

### Generalist fallback

When the archetype is `generalist`, `architect.prior_seed` is set to
`"generalist"` and `system.opt_outs[]` appends
`"architect_first_run_recheck"` so the architect's first scheduled run
proposes a refined archetype with the benefit of the populated vault.

---

## 10. Q-ID enumeration (canonical lock)

This table is the canonical Q-ID set. `q-field-map.json` encodes the
exact same Q-IDs as keys; the onboarder UX cannot introduce new IDs.

### Direct Qs (17)

| Q-ID | Section | Prompt summary | Target schema path |
|---|---|---|---|
| A-1 | A | Confirm name | `identity.name` |
| A-2 | A | Confirm email | `identity.email` |
| A-3 | A | Confirm timezone | `system.timezone` |
| A-4 | A | Confirm vault root | `paths.vault_root`, `vault.root` |
| B-1 | B | Role / firm / industry | `identity.role`, `identity.organization`, `identity.industry`, `identity.seniority` |
| B-2 | B | Active projects + stages | `projects.active[]` |
| B-3 | B | Collaborators | `people[]` |
| B-4 | B | Cadence | `behavioral.cadence_default` |
| B-5 | B | Audience | `vault.default_audience` |
| C-1 | C | Vault organization style | `vault.organizational_method`, `vault.has_structured_projects` |
| C-2 | C | Fresh vs retrofit | `vault.is_fresh` |
| C-3 | C | Sensitive separate vault | `system.opt_outs[]` (conditional) |
| C-4 | C | File types | `vault.canonical_file_types[]` |
| D-1 | D | Autonomy level | `behavioral.autonomy` |
| D-2 | D | First job choice | `orchestration.jobs[0].id` |
| D-3 | D | Architect concerns (conditional) | `architect.prior_seed` (append) |
| D-4 | D | Notification style | `behavioral.hook_preferences.notification_style` |

### Checkbox fields (6)

| Q-ID | Section | Field | Target schema path |
|---|---|---|---|
| A-CB1 | A | Calendar | `tools.calendar` |
| A-CB2 | A | Messaging | `tools.messaging[]` |
| A-CB3 | A | Email client | `tools.email` |
| A-CB4 | A | Transcription | `tools.transcription` |
| A-CB5 | A | Tasks | `tools.tasks` |
| A-CB6 | A | Dev environment | `tools.dev_env` |

### Section E binary toggles (3, separate from the count above)

| Q-ID | Section | Field | Target schema path |
|---|---|---|---|
| E-1 | E | Auto-commit + push | `behavioral.hook_preferences.auto_commit_enabled` |
| E-2 | E | claude-mem consolidation | `behavioral.hook_preferences.memory_consolidation_enabled` |
| E-3 | E | Multi-session coordination | `behavioral.hook_preferences.multi_session_enabled` |

---

## 11. Failure modes (summary)

| ID | Failure | Mitigation |
|---|---|---|
| F1 | Sloppy / fragmentary transcript | Confidence < 0.5 → one surgical follow-up; if still missing, block exit |
| F2 | Transcript omits a required field | Targeted text follow-up naming the missing field |
| F3 | User refuses audio | Typed-textbox-per-section fallback; same extraction pipeline |
| F4 | Audio retention concern | Transcripts auto-deleted after extraction + summary confirmation; opt-in retention checkbox |
| F5 | Domain jargon / accent | Extraction prompt instructs the model to keep unrecognized terms verbatim with low-confidence flags; architect re-analysis can normalize later |
| F6 | Self-contradiction in transcript | Extraction returns `conflicts[]`; one clarifying follow-up |
| F7 | Mid-section quit | Per-section checkpoint; SessionStart resume prompt offers re-record vs. resume |
| F8 | Mis-extraction | Inline-edit in summary; user override appends to a `corrections[]` JSONL for future tuning |

---

## 12. References

- `~/.claude/schemas/user-manifest-schema.json` — 10-section canonical shape used throughout.
- `~/.claude/schemas/orchestration-schema.json` — `jobs[]`, `tripwires[]`, `observability` shape.
- `~/.claude/schemas/vault-schema.json` — `_tag_prefixes` empty-seeded, populated per Section C-4 + archetype inference.
- `~/.claude/onboarding/archetype-keywords.json` — companion JSON consumed by `archetype-inference.sh`.
