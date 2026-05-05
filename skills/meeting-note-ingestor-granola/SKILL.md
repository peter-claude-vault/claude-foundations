---
name: meeting-note-ingestor-granola
description: SP13 T-11 connector. Wraps the foundation-portable meeting-note-ingestor with Granola MCP. Fetches a Granola transcript via MCP, writes to a tmp JSON file, and invokes the portable ingestor with --format granola. Produces a structured meeting note (frontmatter + cleaned body) with title/date/participants pulled from Granola JSON metadata.
disable-model-invocation: true
argument-hint: "--granola-json PATH [--output PATH|-] [--ingestor PATH]"
---

# meeting-note-ingestor-granola

Granola MCP → foundation-portable `meeting-note-ingestor`. Thin connector pattern:
this skill fetches/accepts Granola transcript JSON and pipes through the portable
T-11 ingestor.

## Personalization tier

**Universal capability (connector pattern)** per `docs/personalization-model.md` §1.
Adopters who use Granola.ai for meeting capture invoke this skill; adopters who use
Otter, Zoom, or Word transcripts use `meeting-note-ingestor` directly. Both paths
land at the same structured-note output shape.

## How adopters use this

Two invocation paths depending on whether the Granola transcript is already on disk:

### A. Granola transcript already on disk

```sh
./from-granola.sh --granola-json /tmp/granola-meeting-abc123.json --output /tmp/note.md
# → writes structured note at /tmp/note.md
#   (delegates to ../meeting-note-ingestor/ingest.sh with --format granola)
```

### B. Granola transcript fetched via MCP at runtime

The connector pattern below — Claude (or an automation harness) fetches the Granola
transcript, writes it to a tmp file, then invokes `from-granola.sh`:

```text
1. Call mcp__claude_ai_Granola__get_meeting_transcript(meeting_id) → transcript JSON
2. Write transcript JSON to /tmp/granola-<meeting-id>.json
3. Run: ./from-granola.sh --granola-json /tmp/granola-<meeting-id>.json
4. Capture stdout (or read --output PATH) as the structured meeting note
```

This skill does NOT include the MCP fetch step in code — Granola MCP availability
varies per adopter (some have it, some don't), and embedding MCP calls in a shell
skill would couple the foundation repo to a specific MCP version. The pattern is
documented; the orchestration layer (Claude session, cron job, or
`/meeting-processor`-style consumer skill) owns the MCP fetch.

## Flags (`from-granola.sh`)

| Flag | Default | Meaning |
|---|---|---|
| `--granola-json <path>` | required | Granola transcript JSON file. |
| `--output <path|->` | `-` (stdout) | Pass-through to portable ingestor. |
| `--ingestor <path>` | sibling-skill `../meeting-note-ingestor/ingest.sh` | Override the portable ingestor path. |
| `--title <str>` | derived | Override extracted title (passes through). |
| `--date <YYYY-MM-DD>` | derived | Override extracted date (passes through). |

All other flags accepted by `meeting-note-ingestor/ingest.sh` are passed through
verbatim after `--`.

## Output Contract

**Files written:** zero by default (pipes through stdout). When `--output PATH`
supplied, writes exactly one structured note via the portable ingestor.

**Schema-types:** Same as `meeting-note-ingestor` — `provenance-frontmatter-schema.json`
required fields + meeting-note-specific fields (title, date, source_format,
source_path, participants[]).

**Pre-write validation:**
- Granola JSON file existence + readability checked.
- Portable ingestor existence checked.
- Granola JSON parseability validated by the portable ingestor's granola.sh parser
  (this connector does not re-validate).

**Failure mode:** **Block and log.** Non-zero exit on missing JSON file or missing
ingestor. Otherwise inherits the portable ingestor's failure semantics.

## Architecture decisions (T-11)

### Connector shape — thin wrapper, not a re-implementation

Spec L355 + T-11 build-decision: this skill ships a 1-script wrapper, not a parallel
ingestor. The Granola JSON parsing logic lives ONCE at
`skills/meeting-note-ingestor/parsers/granola.sh` (co-located with the portable
ingestor because the JSON shape is transcript-specific, not generic seed-content).
This connector skill is documentation + invocation pattern.

### MCP fetch — orchestration layer's problem

Embedding `mcp__claude_ai_Granola__*` calls in a shell skill would couple the
foundation repo to a specific MCP version + the adopter's MCP availability. The
fetch step is documented as a pattern; consumers (Claude sessions, cron, or a
v2.x successor skill) own the orchestration. Pure shell stays portable.

### Why a separate skill at all (vs. just docs)

Three reasons: (a) `disable-model-invocation: true` lets the wrapper participate in
the skill registry without being auto-invoked by Claude — adopters opt in via the
connector skill name; (b) the wrapper smooths over flag-name differences (the
adopter-facing flag `--granola-json` is friendlier than `--transcript --format
granola`); (c) the existence of a Granola-named skill in the registry signals to
consumers that the connector pattern is sanctioned (no need to wonder if there's a
different "right way").

## Provenance

Notes generated through this connector carry `generated_by: sp13-t11/1` (same
surface_id as the portable ingestor — this is a routing layer, not a separate
generator). To distinguish Granola-sourced from VTT-sourced notes downstream,
read the `source_format` field in the frontmatter (`granola` vs `otter-vtt`).

## R-55 + test isolation

Zero `~/.claude/` writes. Hermetic tests for this connector are folded into
`onboarding/tests/sp13-meeting-note-ingestor-test.sh` (Granola fixture is one of
the format probes covered there). R-55 G1 override-log delta asserted == 0.

## Relationship to Peter's hard-coded `meeting-processor`

`~/.claude/skills/meeting-processor/SKILL.md` (Peter's existing version) is a
fully-coupled adopter skill — Granola MCP fetch + transcript parsing + vault path
resolution + People-registry fuzzy-match + engagement/project tag inference + dedup
state file. T-11 splits the responsibilities:

| Responsibility | T-11 home | Peter's `meeting-processor` |
|---|---|---|
| MCP fetch | orchestration layer | embedded |
| Transcript JSON parsing | `meeting-note-ingestor/parsers/granola.sh` | embedded |
| Format-agnostic ingestion | `meeting-note-ingestor/ingest.sh` | Granola-only |
| Frontmatter assembly | `meeting-note-ingestor/ingest.sh` | embedded |
| Vault placement | downstream (T-12 / per-adopter) | embedded |
| People-registry enrichment | NOT in T-11 (v2.x backlog: CONFIG-consuming variant) | embedded |
| Engagement/project tagging | NOT in T-11 (v2.x backlog: same) | embedded |
| Dedup state | downstream (T-12 owns its own) | embedded |

Peter's existing skill is unaffected by T-11 ship. v2.x may add a CONFIG-consuming
generic variant that reads `user-manifest.json` for engagement/People metadata,
landing the missing rows above on the foundation-portable side. Per
`feedback_no_skill_code_generation`, that variant ships as a CONFIG-consuming
generic skill, NOT as a generated skill body.
