# onboarding/

The interview engine behind `/onboard`. Captures who you are, where your vault is, how you want the system to behave, then writes a populated `user-manifest.json` and (on greenfield seed-content runs) drives a four-stage chain that proposes a vault taxonomy from your existing notes.

## What's here

| Path | Role |
|---|---|
| `bootstrap-schemas.sh` | Atomic writer for the four schema instances onboarding produces (`plans-schema.json`, `user-manifest.json`, `vault-schema.json`, `orchestration.json`). Validates every output, blocks on failure, never writes partially. |
| `archetype-inference.sh` | Deterministic keyword-scored pass over Section B/C transcripts. Emits an archetype label (consultant / developer / writer / academic / generalist) plus a confidence score. |
| `archetype-keywords.json` | The keyword table the inference reads. Override via `KEYWORDS_FILE` for tests. |
| `q-field-map.json` | The Q-ID → schema-field map. 17 direct questions, 6 checkboxes, 3 binary toggles. Code iterates this map's keys; never enumerates Q-IDs inline. |
| `onboarder-design.md` | Per-section prompt cards (Section A: identity, B: work, C: vault, D: trust, E: confirmation). The onboarder UX anchor-parses prompts from this file. |
| `extraction-prompts/section-{A..E}.md` | LLM extraction templates run against per-section transcripts. Section A is a deterministic stub; B/C/D/E run extraction. |
| `fixtures/{consultant,developer,writer}.json` | Three reference manifest shapes for round-trip tests. |
| `ux/` | Section-by-section interview UX scripts. |
| `lib/` | Helpers — `job-iterator.sh`, `mcp-registry-probe.sh`, etc. |
| `connectors/wizard.sh` | The `/connectors` four-step flow: role question → multiselect MCP catalog → schedule confirm → OAuth at first use. |
| `auto-author/` | The seven personalization surfaces dispatched after the interview completes (claude-home `CLAUDE.md`, memory seeds, vault `CLAUDE.md`, `_tag_prefixes`, `doc-dependencies.json`, frontmatter-enforce config, architect prior-seed). |
| `seed-content/` | Stage 1 of the seed-content pipeline: `intake.sh`, `ir-builder.sh`, `format-parsers/`. Produces the JSONL the `infer-vault-structure` skill consumes. |
| `initial-job-setup-flow.md` | Reference for Section D's "stage exactly one launchd plist" flow. |

## How a run works

```
A → B → C → D → E
    (interview UX writes per-section extraction outputs)
        ↓
    bootstrap-schemas.sh
    (validates and writes the 4 schemas atomically)
        ↓
    Section F (greenfield personalization)
        ├── 7 auto-author surfaces (LLM + deterministic mix)
        └── 4-stage infer-vault chain (only if --seed-content was passed)
```

Each section emits a JSON extraction stub. After the last section, `bootstrap-schemas.sh` consumes the five stubs plus the Q-field map and writes the four output schemas. Section F runs after the manifest is populated because every personalization surface reads from manifest fields.

## Output contract

`bootstrap-schemas.sh` writes these in order, atomically (`tmp+rename`):

1. `~/.claude/schemas/plans-schema.json` (static; no transformation)
2. `~/.claude/user-manifest.json` (populated)
3. `~/.claude/schemas/vault-schema.json` (pass-through)
4. `~/.claude/orchestration.json` (populated)

Every output is validated against its schema (via `ajv` if on PATH, structural fallback otherwise). Any failure rolls back every staged tempfile and exits non-zero — there are no partial writes.

Audit trail at `~/.claude/onboarding/bootstrap-log.jsonl` (JSON-Lines, one record per field). Run-terminator records: `BOOTSTRAP_COMPLETED`, `BOOTSTRAP_FAILED`, `BOOTSTRAP_DIFFER` (live target differs from staged output and `--force` was not passed).

## See also

- [`skills/onboarder/SKILL.md`](../skills/onboarder/SKILL.md) — the user-facing `/onboard` skill that wraps this engine.
- [`skills/infer-vault-structure/SKILL.md`](../skills/infer-vault-structure/SKILL.md) — the four-stage chain Section F invokes on seed-content runs.
- [`docs/personalization-model.md`](../docs/personalization-model.md) — what's universal, combined, and personal across the auto-author output.
- [`docs/llm-cost-model.md`](../docs/llm-cost-model.md) — token costs for the four LLM surfaces.
