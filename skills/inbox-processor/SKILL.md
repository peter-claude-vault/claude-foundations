---
name: inbox-processor
description: >
  Standing background processor that classifies and routes files dropped into the
  vault Inbox/ folder while the user works. One file → one classification → one
  routing decision → one audit log line. Transcript shapes route via the meeting
  note ingestor; project-shaped and ambiguous items remain in Inbox/ with
  "attempted" frontmatter so the user can triage manually.
disable-model-invocation: true
argument-hint: "--vault-root PATH [--audit-log PATH] [--gate-each-item] [--dry-run]"
---

# Inbox Processor

Standing classifier for vault `Inbox/` drops. Picked up by a launchd cron (default
every 15 minutes); processes one batch per tick. The routing decisions are deliberately
conservative: VTT / Zoom / Granola transcripts get routed to `Meetings/`,
reference-shaped notes get routed to `Reference/`, project-shaped items get a hint
frontmatter and stay put (because scaffolding a project tree is too consequential
to do without the user), and genuinely-ambiguous items get tagged `unclassified`
and stay in `Inbox/` for manual triage.

The processor is idempotent. A sha256 content cache means re-running on an
unchanged file is a no-op. Once a file leaves `Inbox/`, the processor forgets it;
nothing is reversed if the user later edits or moves it.

## Invocation

```sh
# One-shot batch (terminal)
./process.sh --vault-root /path/to/vault

# Dry-run — see routing decisions, write nothing
./process.sh --vault-root /path/to/vault --dry-run

# Per-item user-confirmation gate (opt-in; off by default)
./process.sh --vault-root /path/to/vault --gate-each-item

# Install the launchd cron (renders templates/launchd/inbox-processor.plist.tmpl)
./install-cron.sh

# Preview the rendered plist without bootstrapping
./install-cron.sh --dry-run
```

The cron interval is read from `user-manifest.json#/inbox/poll_interval_minutes`
(default 15).

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--vault-root <path>` | required | Vault root. `<vault>/Inbox/` is enumerated. |
| `--audit-log <path>` | `$CLAUDE_LOG_DIR/inbox-processor-audit.log` | Append-only routing-decision audit log (JSONL). |
| `--gate-each-item` | off | Per-item user-confirmation gate. Adds friction; off by default because the processor is the autonomous-routing surface. |
| `--dry-run` | off | Emit routing-decision report on stdout; no file writes. |
| `--state-file <path>` | `$CLAUDE_HOME/inbox-processor-state.json` | Per-file dedup state (content hash + last-routed timestamp). Gitignored at install. |
| `--ingestor <path>` | `skills/meeting-note-ingestor/ingest.sh` | Override the meeting-note-ingestor entry. |
| `--format-detector <path>` | `onboarding/seed-content/format-detector.sh` | Override the format detector. |
| `--meetings-subdir <name>` | `Meetings` | Where transcript-shape routes land under `<vault>/`. |
| `--reference-subdir <name>` | `Reference` | Where reference-shape routes land under `<vault>/`. |

## Three-tier classifier

Per file in `<vault>/Inbox/`:

1. **Format tier (extension first).** `format-detector.sh` resolves the format. Transcript shapes (`otter-vtt`, `zoom-transcript`, `*.docx` with a transcript filename, `*.granola.json`, `granola-*.json`) route as `meeting`.
2. **Heuristic tier.** For non-transcript Markdown / plaintext, check the filename slug and first 50 lines for project-shape signals — frontmatter `type:` value matching a known canonical type from `vault-schema.json`, an `#engagement/*` or `#project/*` tag, an H1 plus multi-section structure. Reference shapes have a `#reference` tag, README-style naming, or notes / cheatsheet shape.
3. **LLM fallback (opt-in).** If format and heuristic are inconclusive AND `ANTHROPIC_API_KEY` is set in the environment AND `--gate-each-item` is OFF (gate-mode prefers user disposition over an LLM call), run a single-pass classifier returning `project | reference | meeting | unclassified`. The LLM call is the only place this skill consumes API budget; the cron interval is the throttle. Inconclusive output or a missing API key falls through to step 4.
4. **Unclassified disposition.** Doesn't fit any classifier. The file stays in `Inbox/`. Two frontmatter fields are appended atomically: `processor_attempted_at: <UTC ISO-8601>` and `processor_classification: unclassified`. No rename, no relocation, no body mutation. The user manually triages later. The next tick sees `processor_attempted_at` and skips re-classification (idempotent).

## Routing targets

| Classification | Target | Notes |
|---|---|---|
| `meeting` | `<vault>/<meetings-subdir>/<YYYY-MM-DD>-<slug>.md` | Routed via `meeting-note-ingestor`. Output carries provenance frontmatter. |
| `reference` | `<vault>/<reference-subdir>/<basename>.md` | Frontmatter `disposition: reference`; tag `#reference`; provenance frontmatter. |
| `project` | `<vault>/Inbox/` (left in place; frontmatter only) | Project-shaped items REQUIRE user disposition (folder, engagement linkage). The processor refuses to scaffold project trees autonomously. Frontmatter appended: `processor_classification: project`, `processor_suggestion: "review for /seed-projects retrofit"`. |
| `unclassified` | `<vault>/Inbox/` (left in place; frontmatter only) | See step 4. |

Project-shape items deliberately stay in `Inbox/` because autonomous project scaffolding is the job of `/seed-projects`, which is gated and user-supervised. The standing processor only takes autonomous action on the safe classes (meeting and reference).

## Per-tick state and dedup

`--state-file` (default `$CLAUDE_HOME/inbox-processor-state.json`) records a content-hash → metadata map:

```json
{
  "items": {
    "<sha256-of-file-content>": {
      "first_seen": "<UTC ISO-8601>",
      "last_attempt": "<UTC ISO-8601>",
      "last_classification": "meeting|reference|project|unclassified",
      "last_route": "<absolute path or 'in-place'>"
    }
  }
}
```

Re-running on an unchanged file is a no-op (state cache hit; classification skipped). When a file's content changes its sha256 changes, so it gets reclassified on the next tick. The state file is gitignored at install.

## Audit log

Append-only JSONL at `--audit-log` (default `$CLAUDE_LOG_DIR/inbox-processor-audit.log`). One line per file processed:

```json
{"ts":"2026-05-04T12:34:56Z","file":"Inbox/foo.md","sha":"<sha256>","classification":"meeting","route":"Meetings/2026-05-04-foo.md","gate":false,"tier":"format"}
```

`tier` is one of `format` / `heuristic` / `llm` / `state-cache` / `unclassified-frontmatter`. The audit log is rotated externally (the librarian's log-archive capability handles this); this skill writes only.

## Output Contract

**Files written:**
- For each `meeting` route: a structured note at `<vault>/<meetings-subdir>/<YYYY-MM-DD>-<slug>.md` produced by the meeting-note-ingestor.
- For each `reference` route: a normalized Markdown file at `<vault>/<reference-subdir>/<basename>.md`.
- For each `unclassified` or `project` route: zero relocations; two frontmatter fields appended to the existing `Inbox/` file (atomic via tmpfile + rename).
- One JSONL line per file processed in the audit log.
- One state-file write per tick (atomic via tmpfile + rename).

**Schema:** all generated artifact frontmatter validates against `schemas/provenance-frontmatter-schema.json`.

**Pre-write validation:**
- `--vault-root` exists and is a directory.
- `<vault>/Inbox/` exists, OR the processor exits 0 with a no-work log line — a cron firing on a vault without an `Inbox/` should be silent, not an error.
- The format detector and meeting-note-ingestor entry points are resolvable.
- Per write: parent directory `mkdir -p`; tmpfile + atomic rename. Never partial.
- For unclassified frontmatter append: read existing file, parse and amend frontmatter, write to tmpfile, atomic rename. If parse fails, log and skip the file — never destructive.

**Failure mode:** the skill aborts on validation failure rather than writing partial state. Per-file errors log to the audit log + stderr and proceed to the next file (one bad file does not halt the batch). Tick-level errors (vault missing, state file unreadable, lock contention) exit non-zero so launchd can detect them.

## Why cron, not SessionStart

The processor needs to run while the user works, not only when they start a new Claude session. Cron is the right shape for time-driven autonomy. SessionStart would only fire on session boot; long backlogs would burst against the LLM-fallback tier. The cron interval is also the implicit budget throttle.

## Limitations and non-goals

- **No autonomous project scaffolding.** Project-shape items get a classification hint but stay in `Inbox/`. `/seed-projects` and `/adopt --retrofit-existing` handle project-tree creation.
- **No multi-batch corpus reasoning.** The standing processor classifies one file at a time. The heavier iterative-clustering pass is reserved for `/onboard --seed-content`.
- **No re-cluster on incremental drop.** Every file is classified independently against the canonical types in `vault-schema.json`; no cross-file relationship inference.
- **No vault-side cleanup.** If a previous tick wrote a file to `Meetings/` and the user then deletes the original `Inbox/` file before the next tick, the routed file stays. Routes are not reversed.
- **No re-routing on user edit.** Once a file leaves `Inbox/`, the processor forgets it.
- **No connectors.** Multi-source pulls (Notion, Evernote, Slack) are out of scope. This skill processes the local filesystem `Inbox/` only.
