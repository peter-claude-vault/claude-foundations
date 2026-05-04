---
title: Seed-Content Pipeline
type: doc
status: skeleton
related_plan: 71-claude-foundations-engine-v2 SP13
---

# Seed-Content Pipeline (SP13)

The seed-content pipeline lets adopters drop existing notes / meeting transcripts / reference docs into onboarding so Claude can propose a vault structure, generate per-project triads (PRD / Context / Updates), and route everything else to `Inbox/`.

This skeleton documents the Stage 1 INGEST surface as it ships per-task. T-14 will expand the doc once the full pipeline is green.

## Invocation

```
/onboard --seed-content <path-or-paste>
```

- **Directory path** — recursive walk; each regular file under the path becomes one intake record.
- **Single file path** — one intake record.
- **Paste string** — anything that doesn't resolve to a directory or file is treated as paste content. The paste is materialized to disk under `$INPUTS_DIR/seed-content/paste/paste-<sha-prefix>.txt` so downstream stages have a stable file path to read.

A "seed content detected: N items" line is emitted to stdout before the interview-Q surface fires.

## `.seedignore`

Place a `.seedignore` file at the seed-content root (i.e. inside the directory passed to `--seed-content <DIR>`) to exclude paths from ingest. Patterns mirror a subset of gitignore semantics:

- Blank lines and `#` comments are ignored.
- Patterns ending with `/` match any path component — `node_modules/` excludes every directory named `node_modules` anywhere under the root.
- Other patterns are shell globs matched against both basename and the path relative to the root — `*.key` excludes all `.key` files; `secrets/credentials.json` excludes that exact relative path.

Missing `.seedignore` = no exclusions (default permissive). A file containing only comments/blanks behaves the same as a missing file.

A starter template ships at `onboarding/seed-content/.seedignore.example` covering VCS caches, credentials, OS noise, and build output. Copy it to your seed root as `.seedignore` and edit.

## Output: intake manifest

`intake.sh` emits a JSONL manifest, one line per record:

```json
{"path": "/abs/path/to/file", "size_bytes": 1234, "source_type": "file"}
{"path": "/tmp/.../paste/paste-abc123.txt", "size_bytes": 56, "source_type": "paste"}
```

Default location: `$INPUTS_DIR/seed-content/intake-manifest.jsonl`. Format detection (T-3) consumes this manifest and produces the unified IR.

## Tasks tracked here

- **T-1** — `--seed-content` flag + intake.sh dispatch — _done_
- **T-2** — `.seedignore` scope filter — _done_
- **T-3** — batch cap + format detection + unified IR schema — _next_
- T-4..T-15 — see `~/.claude-plans/71-claude-foundations-engine-v2/13-content-seeding-pipeline/tasks.md`
