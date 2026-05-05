---
name: meeting-note-ingestor
description: SP13 T-11. Foundation-portable, source-agnostic transcript ingestor. Consumes a transcript file path (Otter VTT, Word, Zoom, generic LLM-export, or Granola JSON) and emits a structured meeting note (frontmatter + cleaned body) on stdout or to --output PATH. Replaces hard-coded Granola+vault-paths-and-People-registry workflows with a portable variant; Granola becomes one connector via meeting-note-ingestor-granola.
disable-model-invocation: true
argument-hint: "--transcript PATH [--format FMT] [--output PATH|-] [--title STR] [--date YYYY-MM-DD]"
---

# meeting-note-ingestor

Source-agnostic transcript → structured meeting note. File path in, frontmatter+body out.
Foundation-portable: zero vault-coupling, zero People-registry coupling, zero engagement
lookup. Adopters' Granola/People/engagement workflows live in connector skills (e.g.
`meeting-note-ingestor-granola`) that wrap this primitive.

## Personalization tier

**Universal capability** per `docs/personalization-model.md` §1 — the skill body is
identical for every adopter. Personalization comes from the user's source transcript
(format, content, speaker labels), the user-supplied flags (`--title`, `--date`),
and downstream connector skills (e.g. Granola-MCP wrapper). This skill does NOT
re-declare the classification framing — see `docs/personalization-model.md`.

## Invocation

```sh
./ingest.sh --transcript /path/to/2026-04-21-DDX-Standup.vtt
# → structured note on stdout

./ingest.sh --transcript /path/to/transcript.docx --output ./out/note.md
# → writes structured note file at ./out/note.md

./ingest.sh --transcript /tmp/granola-meeting-abc123.json --format granola
# → uses Granola JSON parser; pulls title/date/participants from JSON top-level
```

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--transcript <path>` | required | Input transcript file. Any supported format (auto-detected via T-3 format-detector unless `--format` overrides). |
| `--format <fmt>` | auto | Force format. Supported: `otter-vtt`, `word`, `zoom-transcript`, `llm-export`, `granola`, `markdown`, `plaintext`. |
| `--output <path|->` | `-` (stdout) | Write structured note to PATH; `-` for stdout. Parent directory auto-created. |
| `--title <str>` | derived | Override extracted/derived title. Default: filename stem with leading `YYYY-MM-DD` stripped, fallback `"Meeting Note"`. Granola JSON `title` field used when present. |
| `--date <YYYY-MM-DD>` | derived | Override extracted/derived date. Default: filename `YYYY-MM-DD` prefix; Granola JSON `date` field; file mtime fallback. |
| `--surface-id <id>` | `sp13-t11/1` | Provenance `generated_by` value. Per SP12 T-2 contract. |
| `--seed-parsers-dir <path>` | `onboarding/seed-content/format-parsers` | Override T-3 parsers dir (vtt, word, zoom-transcript, llm-export, markdown, plaintext). |
| `--format-detector <path>` | `onboarding/seed-content/format-detector.sh` | Override T-3 detector. |
| `--ingestor-parsers-dir <path>` | `skills/meeting-note-ingestor/parsers` | Override the co-located parsers dir (granola.sh). |
| `--pf-lib <path>` | `lib/provenance-frontmatter.sh` | SP12 T-2 helper; sourced (never forked). |

## Output Contract

**Files written:** zero by default (stdout). When `--output PATH` supplied, writes
exactly one structured note file at PATH. Parent dirs auto-created.

**Schema-types:**
- Frontmatter validates against `schemas/provenance-frontmatter-schema.json` (Draft-07,
  SP12 T-2): required `generated_by` + `generated_from` + `last_user_edit`. Plus
  meeting-note fields: `title` (string), `date` (string `YYYY-MM-DD`),
  `source_format` (enum of supported formats), `source_path` (string),
  `participants` (array of strings; may be empty).

**Pre-write validation:**
- Transcript file existence + readability checked before format dispatch.
- pf-lib path existence + jq availability checked before normalization.
- Granola parser output validated as JSON before metadata extraction.
- Empty transcript → graceful-degrade frontmatter with `_(empty transcript body)_`
  body marker. Pipeline does not halt.

**Failure mode:** **Block and log.** Non-zero exit on missing transcript, missing
parser, unsupported format with no override, malformed Granola JSON. Stdout silent
on failure (caller never gets a half-rendered note).

## Architecture decisions (T-11)

### Format-parser dispatch — extension-first with `--format` override

T-3's `format-detector.sh` already handles 7 formats via extension match → filename
heuristic → JSON-shape sniff → magic-byte fallback. Reusing it (not duplicating)
keeps the format inventory single-source-of-truth. The ingestor adds two thin layers
on top: (a) Granola filename heuristic (`*.granola.json`, `granola-*.json`,
`granola_*.json`) before the detector fires; (b) JSON-shape promotion that flips
`llm-export` or `plaintext` → `granola` when the JSON has `title` + (`transcript`
| `body` | `attendees`).

`--format` always wins. PDFs require explicit override (auto-detected PDFs are
rejected — they aren't typical transcript shapes).

### Output target — stdout default

T-11 is a primitive consumed by other skills (T-12 standing-Inbox processor,
`/seed-content` for transcript-shaped seeds, ad-hoc CLI use). Stdout default keeps
composition cheap — caller pipes into `tee`, `process_substitution`, or a file.
`--output PATH` is for direct invocation; `--output -` is the explicit stdout
sentinel for symmetry. NO 3-step gate involvement at this layer (T-11 is the
generator; T-12 is the gate-orchestrator for inbox-routed transcript notes).

### participants[] extraction — per-format with regex fallback

Granola JSON: extracted from top-level `attendees`, `participants`, or `speakers`
array (lenient — accepts string entries, object entries with `name`/`full_name`/
`first_name`, drops empties). This is the high-fidelity path because Granola already
has structured speaker metadata.

Other formats: post-normalization regex over speaker labels — matches
`^Name:`, `^First Last:`, `^Speaker N:`, with hyphen-bearing names supported
(`Pierre-Olivier:`). False-positive allowlist filters common transcript-header
tokens (`WEBVTT`, `NOTE`, `STYLE`, `Subject`, `From`, `To`, `Topic`, etc.).
Per-format extraction was rejected as over-engineering — the regex covers
~95% of speaker-labeled transcript shapes after normalization.

### Granola-connector shape — thin sibling skill

`meeting-note-ingestor-granola/SKILL.md` is a connector pattern (Granola MCP →
JSON file → portable ingestor `--format granola`), not a re-implementation. The
heavy lifting lives in `parsers/granola.sh` co-located with the portable ingestor
because the JSON shape is transcript-specific (not generic seed-content). The
connector skill ships a 1-line wrapper `from-granola.sh` that takes a JSON path
and pipes through `ingest.sh`. Adopters write Granola MCP transcript fetches to
disk (or pipe via tmpfile), then invoke this skill.

The hard-coded Granola+vault-paths-and-People-registry skill at `~/.claude/
skills/meeting-processor/` (Peter's existing version) is unaffected. The portable
T-11 ingestor is parallel; v2.x may evolve a config-driven adopter that consumes
`user-manifest.json`'s engagement+People metadata, but THAT is per
`feedback_no_skill_code_generation` a CONFIG-consuming generic skill, not a
generated skill body.

## Frontmatter shape (example)

```yaml
---
generated_by: sp13-t11/1
generated_from: /tmp/sp13-t11/2026-04-21-ddx-standup.vtt
last_user_edit: null
title: "DDX Standup"
date: 2026-04-21
source_format: otter-vtt
source_path: "/tmp/sp13-t11/2026-04-21-ddx-standup.vtt"
participants:
  - "Ellie Chen"
  - "Peter Tiktinsky"
---

# DDX Standup

Peter Tiktinsky: Welcome to the DDX standup...
Ellie Chen: Thanks Peter. Let me cover the BAR dashboard...
```

## Dependencies

- `lib/provenance-frontmatter.sh` (SP12 T-2) — sourced for `pf_emit`.
- `onboarding/seed-content/format-detector.sh` (SP13 T-3) — invoked for format detection.
- `onboarding/seed-content/format-parsers/{otter-vtt,word,zoom-transcript,llm-export,markdown,plaintext}.sh` (SP13 T-3) — invoked per-format for normalization.
- `parsers/granola.sh` (this skill, T-11 co-located) — invoked for Granola JSON.

## Downstream consumers (planned)

- **T-12 (`inbox-processor`)** — calls this skill when an Inbox/ drop has a
  transcript-shaped extension. Wraps the structured note in T-12's gate.
- **`/seed-content` (T-3 path)** — when a seeded item is transcript-shaped, the
  seed-projects pipeline can route via this skill instead of generic parsing.
- **`meeting-note-ingestor-granola/from-granola.sh`** — Granola MCP connector
  wrapper.

## R-55 + test isolation

This skill performs zero `~/.claude/` writes. All output goes to stdout or a
caller-supplied path. Hermetic tests live at `onboarding/tests/sp13-meeting-
note-ingestor-test.sh`; per `feedback_test_isolation_for_hooks_state`, tests
run under `$TMPDIR/sp13-t11-test-XXXXXX` and unset `ANTHROPIC_API_KEY` +
`VOYAGE_API_KEY` before any normalization step. R-55 G1 override-log delta is
asserted == 0 by the test orchestrator.

## Limitations + non-goals

- **No live MCP calls.** This skill consumes a transcript FILE. MCP fetches
  belong to connector skills (`meeting-note-ingestor-granola`).
- **No vault writes.** This skill emits a structured note; it does NOT place
  the note in `Meetings/` or any vault location. T-12 does that placement.
- **No People-file enrichment.** Peter's hard-coded skill enriches People-file
  Timelines; the portable variant doesn't (no People registry assumption).
  v2.x may layer this in via a CONFIG-consuming variant.
- **No Granola ID dedup.** Per-meeting state tracking is the consumer's
  problem (T-12 will own its own state file).
- **No transcript merging.** Multi-party recordings of the same meeting
  aren't merged here; that's a Granola-connector concern + may evolve in v2.x.
- **PDF transcripts require explicit `--format pdf`.** Auto-detected PDFs
  are rejected. PDFs aren't typical transcript shapes; the conservative
  default avoids false positives.
