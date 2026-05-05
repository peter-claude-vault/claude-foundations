---
title: Seed-Content Pipeline
type: doc
status: shipped
---

# Seed-Content Pipeline

The seed-content pipeline lets you drop existing notes, meeting transcripts, and reference docs into onboarding. The pipeline ingests the corpus, clusters it by similarity, proposes a vault structure via LLM, renders a markdown plan you read top-to-bottom, and writes nothing until you approve.

The flow is four stages plus a one-time intake step. Each stage is independently testable and resumable; the pipeline can fall back to deterministic stubs when API keys aren't available.

---

## Invocation

```
/onboard --seed-content <path-or-paste>
```

The argument can be:

- **Directory path** — recursive walk; each regular file under the path becomes one intake record.
- **Single file path** — one intake record.
- **Paste string** — anything that doesn't resolve to a directory or file is treated as paste content. The paste is materialized to disk under `$INPUTS_DIR/seed-content/paste/paste-<sha-prefix>.txt` so downstream stages have a stable file path to read.

A `seed content detected: N items` line is emitted to stdout before the interview surface fires.

---

## Stage 0 — Intake

`onboarding/seed-content/intake.sh` walks the input and emits a JSONL manifest, one line per record:

```json
{"path": "/abs/path/to/file", "size_bytes": 1234, "source_type": "file"}
{"path": "/tmp/.../paste/paste-abc123.txt", "size_bytes": 56, "source_type": "paste"}
```

Default location: `$INPUTS_DIR/seed-content/intake-manifest.jsonl`.

### `.seedignore`

Place a `.seedignore` file at the seed-content root to exclude paths from ingest. Patterns mirror a subset of gitignore semantics:

- Blank lines and `#` comments are ignored.
- Patterns ending with `/` match any path component — `node_modules/` excludes every directory named `node_modules` anywhere under the root.
- Other patterns are shell globs matched against both basename and the path relative to the root — `*.key` excludes all `.key` files; `secrets/credentials.json` excludes that exact relative path.

Missing `.seedignore` = no exclusions (default permissive). A starter template ships at `onboarding/seed-content/.seedignore.example` covering VCS caches, credentials, OS noise, and build output.

---

## Stage 1 — IR (intermediate representation)

`onboarding/seed-content/ir-builder.sh` consumes the intake manifest, runs format detection (`format-detector.sh`), parses each file via the appropriate format-specific parser, and emits a unified IR JSONL. Each record carries content (cleaned text), metadata (source path, size, format, detected timestamps), and a stable record ID.

The IR is the contract between intake and the four-stage chain. Every downstream stage reads JSONL.

---

## Stage 2 — Cluster

`skills/infer-vault-structure/cluster.sh` takes the IR and groups records by semantic similarity.

```
./cluster.sh --ir /tmp/ir.jsonl
```

Flags: `--min-cluster-size N` (default 3), `--eps F` (cosine-distance neighborhood, default 0.45), `--embedding-mode {stub|voyage|auto}`.

The `auto` mode uses the Voyage AI embeddings API when `VOYAGE_API_KEY` is set and falls back to a deterministic stub when it isn't. The stub produces stable, reproducible clusters from token-overlap heuristics — useful for tests and for trying the pipeline without an API key.

Output: `onboarding/seed-content/state/cluster-output.json` (`schema_version: sp13-t4/1`).

---

## Stage 3 — Propose taxonomy

`skills/infer-vault-structure/propose-taxonomy.sh` takes the cluster output plus the IR and produces a taxonomy proposal: per-cluster labels (e.g., `Engagements/alpha`, `References/policy`, `Meetings/q2-syncs`), confidence scores, and a callout for unclassified residuals.

```
./propose-taxonomy.sh \
  --cluster-output onboarding/seed-content/state/cluster-output.json \
  --ir /tmp/ir.jsonl
```

Flags: `--llm-mode {stub|live|auto}`, `--model-pass1`, `--model-pass2`, `--max-passes`, `--low-mapped-threshold`.

The `auto` mode uses the Anthropic Messages API when `ANTHROPIC_API_KEY` is set; the `stub` mode generates deterministic labels from cluster content. Two LLM passes are standard (initial proposal + refinement against residuals); a third pass triggers if too many records remain unclassified.

**Crucially, an explicit unclassified bucket exists.** Records that don't fit any cluster's proposed label are routed to an "unclassified" pile rather than silently dropped. You see them in the import plan and can decide where they go.

Output: `onboarding/seed-content/state/propose-taxonomy-output.json` (`schema_version: sp13-t5/1`; logical schema at `schemas/propose-taxonomy-schema.json`).

---

## Stage 4 — Import plan

`skills/infer-vault-structure/import-plan.sh` renders the taxonomy proposal as a markdown plan you can read top-to-bottom: every cluster, every record, every routing decision, every confidence score, every unclassified residual.

Output: `onboarding/seed-content/state/import-plan.md` (`schema_version: sp13-t6/1`; logical schema at `schemas/import-plan-schema.json`).

---

## Stage 5 — Review gate

`skills/infer-vault-structure/review-gate.sh` surfaces the import plan to you with four actions:

- `[a]pply` — approve the plan as-is. Writes `approved-import-plan.md`.
- `[e]dit` — open the plan in `${EDITOR:-vi}`. Your edits become the approved plan.
- `[s]kip` — skip the import; the plan is recorded but not applied.
- `[b]bort` — abandon the run.

No vault writes happen until you `[a]pply` (or `[e]dit` then apply). If you edit a routing decision inline, the round-trip preserves your edits — the orchestrator does not silently overwrite changes.

Output (only on apply): `onboarding/seed-content/state/approved-import-plan.md`.

---

## Schema versions

The four state files carry `schema_version` fields (`sp13-t4/1`, `sp13-t5/1`, `sp13-t6/1`). These are wire-format identifiers: stages downstream of a producer check the version and refuse to run on an unrecognized schema. Bumping a schema is a breaking change for downstream consumers; the stages run as a chain so a coordinated bump is the standard upgrade path.

---

## Orchestration

`skills/infer-vault-structure/orchestrate.sh` chains the four stages. Per-stage state markers (`state/<stage>.done`) make the chain idempotent on re-run. If the review gate stalls (you walk away mid-review), the orchestrator writes `state/review-pending.flag` and exits 64; you re-invoke with `--resume` after review and it skips the completed stages.

One JSONL record per stage lands in `$CLAUDE_HOME/projects/<slug>/inferred/orchestrate-log.jsonl` carrying `{timestamp, stage, exit_code, duration_ms, evidence_path}`.

The onboarder Section F greenfield path invokes `orchestrate.sh` when `SEED_CONTENT_PATH` is set; `/adopt --retrofit-existing` invokes the same chain to produce a collision matrix when retrofitting an existing vault.

---

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. |
| 1 | User abort or empty output. |
| 2 | Missing or invalid input; schema-version mismatch. |
| 3 | API error in live mode (Anthropic or Voyage). |
| 64 | Review-gate stall; resume with `--resume`. |

---

## Stub mode

Both LLM and embeddings stages have deterministic stubs. Set `LLM_MODE=stub` and `EMBEDDING_MODE=stub` (or invoke each script with `--llm-mode stub --embedding-mode stub`) to run the full pipeline without any API keys. The stubs produce stable, reproducible output suitable for tests and for trying the pipeline before paying for an LLM run.

---

## Where this is consumed

- **`/onboard --seed-content <path>`** — invokes the orchestrator on a greenfield run.
- **`/adopt --retrofit-existing`** — invokes the orchestrator to produce a collision matrix when retrofitting an existing vault.
- **`seed-projects`** — consumes the approved import plan to scaffold PRD / Context / Updates triads under each project candidate's proposed_path.
