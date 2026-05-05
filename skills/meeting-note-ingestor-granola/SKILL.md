---
name: meeting-note-ingestor-granola
description: >
  Granola connector for meeting-note-ingestor. Wraps the portable ingestor with a
  friendlier flag (--granola-json) for users whose meeting capture pipeline is
  Granola.ai. The MCP fetch step is documented as an orchestration pattern, not
  embedded in this skill.
disable-model-invocation: true
argument-hint: "--granola-json PATH [--output PATH|-] [--ingestor PATH]"
---

# meeting-note-ingestor-granola

Thin connector around `meeting-note-ingestor` for Granola.ai users. Granola JSON
has a recognizable shape (top-level `title`, `attendees`, `transcript` fields), but
the portable ingestor expects either a transcript file path with auto-detection
or an explicit `--format granola` flag. This skill smooths the entry point: pass
`--granola-json <path>`, get back the same structured note. It's a routing layer,
not a separate generator — same output shape as the portable ingestor.

The MCP fetch step itself is documented as an orchestration pattern (Claude session,
cron, or downstream consumer skill calls `mcp__claude_ai_Granola__get_meeting_transcript`
and writes the JSON to a tmp file), not embedded here. Embedding MCP calls in a
shell skill would couple the foundation repo to a specific MCP version and to the
adopter's MCP availability. Adopters who don't use Granola never invoke this
skill; they call the portable ingestor directly with their format.

## How adopters use this

There are two paths depending on whether the Granola transcript is already on disk:

### A. Granola transcript already on disk

```sh
./from-granola.sh --granola-json /tmp/granola-meeting-abc123.json --output /tmp/note.md
# → writes structured note at /tmp/note.md
#   (delegates to ../meeting-note-ingestor/ingest.sh with --format granola)
```

### B. Granola transcript fetched via MCP at runtime

The connector pattern: Claude (or an automation harness) fetches the transcript, writes it to a tmp file, then invokes `from-granola.sh`:

```text
1. Call mcp__claude_ai_Granola__get_meeting_transcript(meeting_id) → transcript JSON
2. Write transcript JSON to /tmp/granola-<meeting-id>.json
3. Run: ./from-granola.sh --granola-json /tmp/granola-<meeting-id>.json
4. Capture stdout (or read --output PATH) as the structured meeting note
```

## Flags (`from-granola.sh`)

| Flag | Default | Meaning |
|---|---|---|
| `--granola-json <path>` | required | Granola transcript JSON file. |
| `--output <path\|->` | `-` (stdout) | Pass-through to the portable ingestor. |
| `--ingestor <path>` | `../meeting-note-ingestor/ingest.sh` | Override the portable ingestor path. |
| `--title <str>` | derived | Override extracted title (passes through). |
| `--date <YYYY-MM-DD>` | derived | Override extracted date (passes through). |

Any other flag accepted by `meeting-note-ingestor/ingest.sh` is passed through verbatim after `--`.

## Output Contract

**Files written:** zero by default (pipes through stdout). When `--output PATH` is supplied, exactly one structured note via the portable ingestor.

**Schema:** same as `meeting-note-ingestor` — `provenance-frontmatter-schema.json` required fields plus meeting-note-specific fields (`title`, `date`, `source_format`, `source_path`, `participants[]`).

**Pre-write validation:**
- The Granola JSON file exists and is readable.
- The portable ingestor exists.
- Granola JSON parseability is validated by the portable ingestor's Granola parser; this connector does not re-validate.

**Failure mode:** non-zero exit on a missing JSON file or missing ingestor. Otherwise inherits the portable ingestor's failure semantics — the connector aborts on validation failure rather than emitting a partial note.

## Why a separate skill (vs. just docs)

Three reasons:

1. `disable-model-invocation: true` lets the wrapper participate in the skill registry without being auto-invoked by Claude. Adopters opt in by name.
2. The wrapper smooths over flag-name differences. `--granola-json <path>` is friendlier than `--transcript <path> --format granola` for callers who only ever consume Granola.
3. Having a Granola-named skill in the registry signals to other consumers that the connector pattern is sanctioned — no need to wonder whether there's a "different right way."

## Provenance

Notes generated through this connector carry `generated_by: meeting-note-ingestor`
(same surface ID as the portable ingestor — this is a routing layer, not a separate
generator). Downstream consumers that want to distinguish Granola-sourced from
VTT-sourced notes read the `source_format` field in the frontmatter (`granola`
vs `otter-vtt`).
