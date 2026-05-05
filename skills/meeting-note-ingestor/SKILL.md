---
name: meeting-note-ingestor
description: >
  Foundation-portable, source-agnostic transcript ingestor. Consumes a transcript
  file path (Otter VTT, Word, Zoom, generic LLM-export, or Granola JSON) and emits
  a structured meeting note (frontmatter + cleaned body) on stdout or to --output PATH.
  Zero vault coupling, zero People-registry coupling, zero engagement lookup.
disable-model-invocation: true
argument-hint: "--transcript PATH [--format FMT] [--output PATH|-] [--title STR] [--date YYYY-MM-DD]"
---

# meeting-note-ingestor

Source-agnostic transcript-to-meeting-note converter. File path in, structured Markdown
note (frontmatter + cleaned body) out. The skill is deliberately portable: no vault
path resolution, no People-registry fuzzy matching, no engagement tagging. Those
belong to connector or downstream-consumer skills (e.g. `meeting-note-ingestor-granola`,
`inbox-processor`). By default the output goes to stdout so callers can pipe it
anywhere.

## Invocation

```sh
# Otter VTT to stdout
./ingest.sh --transcript /path/to/2026-04-21-DDX-Standup.vtt

# Word doc, written to a file
./ingest.sh --transcript /path/to/transcript.docx --output ./out/note.md

# Granola JSON; pulls title/date/participants from the JSON top-level
./ingest.sh --transcript /tmp/granola-meeting-abc123.json --format granola
```

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--transcript <path>` | required | Input transcript file. Any supported format. Auto-detected unless `--format` overrides. |
| `--format <fmt>` | auto | Force the format. Supported: `otter-vtt`, `word`, `zoom-transcript`, `llm-export`, `granola`, `markdown`, `plaintext`. |
| `--output <path\|->` | `-` (stdout) | Write structured note to PATH; `-` for stdout. Parent directory auto-created. |
| `--title <str>` | derived | Override extracted/derived title. Default: filename stem with leading `YYYY-MM-DD` stripped, fallback `"Meeting Note"`. Granola JSON `title` field used when present. |
| `--date <YYYY-MM-DD>` | derived | Override extracted/derived date. Default precedence: filename `YYYY-MM-DD` prefix → Granola JSON `date` → file mtime. |
| `--surface-id <id>` | `meeting-note-ingestor` | Provenance `generated_by` value. |
| `--seed-parsers-dir <path>` | `onboarding/seed-content/format-parsers` | Override the parser directory. |
| `--format-detector <path>` | `onboarding/seed-content/format-detector.sh` | Override the detector. |
| `--ingestor-parsers-dir <path>` | `skills/meeting-note-ingestor/parsers` | Override the co-located parsers dir (currently `granola.sh`). |
| `--pf-lib <path>` | `lib/provenance-frontmatter.sh` | Provenance helper; sourced (never forked). |

## Format dispatch

The format detector handles seven formats by extension match → filename heuristic → JSON-shape sniff → magic-byte fallback. Two thin layers run on top:

- A Granola filename heuristic (`*.granola.json`, `granola-*.json`, `granola_*.json`) checked before the detector fires.
- A JSON-shape promotion that flips `llm-export` or `plaintext` to `granola` when the JSON has `title` plus one of `transcript` / `body` / `attendees`.

`--format` always wins. PDFs require an explicit `--format pdf` override — auto-detected PDFs are rejected because they aren't typical transcript shapes and the conservative default avoids false positives.

## Participant extraction

For Granola JSON, participants are extracted from the top-level `attendees`, `participants`, or `speakers` array. The parser is lenient — accepts string entries, object entries with `name` / `full_name` / `first_name`, and drops empties. This is the high-fidelity path because Granola already has structured speaker metadata.

For other formats, participants are extracted by regex over speaker labels in the normalized body — `^Name:`, `^First Last:`, `^Speaker N:`, with hyphenated names supported (`Pierre-Olivier:`). A false-positive allowlist filters common transcript-header tokens (`WEBVTT`, `NOTE`, `STYLE`, `Subject`, `From`, `To`, `Topic`, etc.). This covers the bulk of speaker-labeled transcript shapes; users can always override participants in the frontmatter post-hoc.

## Output Contract

**Files written:** zero by default (stdout). When `--output PATH` is supplied, exactly one structured note file at PATH. Parent directories auto-created.

**Schema:** Frontmatter validates against `schemas/provenance-frontmatter-schema.json` — required `generated_by`, `generated_from`, `last_user_edit`. Plus meeting-note fields:
- `title` (string)
- `date` (string, `YYYY-MM-DD`)
- `source_format` (one of the supported format names)
- `source_path` (string)
- `participants` (array of strings; may be empty)

**Pre-write validation:**
- Transcript file exists and is readable.
- The provenance helper and `jq` are available.
- Granola parser output is validated as JSON before metadata extraction.
- Empty transcript: graceful-degrade frontmatter with a `_(empty transcript body)_` body marker. The pipeline does not halt.

**Failure mode:** the skill aborts on validation failure rather than emitting a half-rendered note. Non-zero exit on a missing transcript, missing parser, unsupported format with no override, or malformed Granola JSON. Stdout is silent on failure — the caller never gets a partial note.

## Frontmatter shape (example)

```yaml
---
generated_by: meeting-note-ingestor
generated_from: /tmp/2026-04-21-ddx-standup.vtt
last_user_edit: null
title: "DDX Standup"
date: 2026-04-21
source_format: otter-vtt
source_path: "/tmp/2026-04-21-ddx-standup.vtt"
participants:
  - "Jane Doe"
  - "Sam Khan"
---

# DDX Standup

Sam Khan: Welcome to the DDX standup...
Jane Doe: Thanks Sam. Let me cover the dashboard...
```

## Dependencies

- `lib/provenance-frontmatter.sh` — sourced for `pf_emit`.
- `onboarding/seed-content/format-detector.sh` — invoked for format detection.
- `onboarding/seed-content/format-parsers/{otter-vtt,word,zoom-transcript,llm-export,markdown,plaintext}.sh` — invoked per-format.
- `parsers/granola.sh` (co-located with this skill) — invoked for Granola JSON.
- `jq`.

## Limitations and non-goals

- **No live MCP calls.** This skill consumes a transcript FILE. MCP fetches are the connector's job (see `meeting-note-ingestor-granola`).
- **No vault writes.** The skill emits a structured note; it does not place the note anywhere. Placement is the consumer's responsibility (`inbox-processor` or a connector).
- **No People-registry enrichment.** Adopters who want to link participants to vault People files do that in a downstream consumer.
- **No dedup state.** Per-meeting tracking is the consumer's concern.
- **No transcript merging.** Multi-party recordings of the same meeting aren't merged here.
- **PDF transcripts require `--format pdf`.** Auto-detected PDFs are rejected.
