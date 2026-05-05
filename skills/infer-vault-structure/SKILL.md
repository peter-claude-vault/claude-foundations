---
name: infer-vault-structure
description: Four-stage pipeline that takes a corpus of seed content (your existing notes), clusters by semantic similarity, proposes a vault taxonomy via LLM, renders a user-reviewable import plan, then runs a 3-step gate so you apply / edit / skip / abort before any vault writes happen.
disable-model-invocation: true
argument-hint: "cluster [--ir <ir.jsonl>] [...] | propose-taxonomy --cluster-output <path> --ir <ir.jsonl> [--llm-mode {stub|live|auto}] | import-plan [--propose-taxonomy <path>] [--out <path>] | review-gate [--import-plan <path>] [--approved-out <path>]"
---

# infer-vault-structure

A pipeline that turns "a directory of existing notes" into "a vault taxonomy you've reviewed and approved." Four stages — `cluster.sh`, `propose-taxonomy.sh`, `import-plan.sh`, `review-gate.sh` — share stdlib-Python helpers. No `numpy`, `requests`, `scikit-learn`, `pydantic`, or `pyyaml` dependency.

Stage 1 (the IR builder under `onboarding/seed-content/`) is upstream of this skill; it produces the JSONL records each row of which is one source file with its content plus metadata. The four stages here turn that IR into the artifacts Stage 3 (`seed-projects`) consumes.

## Personalization tier

This is a **Universal capability** — the skill body is identical for every adopter. Personalization comes from the contents of your IR (your seeded files), not from per-user code. Output artifacts (`state/cluster-output.json`, `import-plan.md`, the PRD/Context/Updates triads downstream) carry provenance frontmatter via `lib/provenance-frontmatter.sh`. See [`docs/personalization-model.md`](../../docs/personalization-model.md) for the universal/combined/personal classification.

## When this skill runs

Invoked by:

- `/onboard --seed-content <path>` — the greenfield personalization path: Section F dispatches the orchestrator after the seven auto-author surfaces complete.
- `/adopt --retrofit-existing` — walks an existing populated vault as IR source.
- The orchestrator: `skills/infer-vault-structure/orchestrate.sh` chains all four stages with per-stage idempotency markers and a halt-resume on review-gate stall.

You can also invoke each stage directly for testing.

## Invocation

```sh
./cluster.sh --ir /tmp/seed-fixture/ir.jsonl
# → onboarding/seed-content/state/cluster-output.json

./propose-taxonomy.sh \
  --cluster-output onboarding/seed-content/state/cluster-output.json \
  --ir /tmp/seed-fixture/ir.jsonl
# → onboarding/seed-content/state/propose-taxonomy-output.json

./import-plan.sh
# → onboarding/seed-content/state/import-plan.md

./review-gate.sh
# → onboarding/seed-content/state/approved-import-plan.md (on user 'apply')
# → audit log entries appended at onboarding/auto-author-log.jsonl
```

### Flags

#### `cluster.sh`

| Flag | Default | Meaning |
|---|---|---|
| `--ir <path>` | required | Stage 1 IR JSONL (one record per line). |
| `--out <path>` | `onboarding/seed-content/state/cluster-output.json` | Output cluster-output JSON. |
| `--min-cluster-size N` | 3 | Density threshold; clusters smaller than N collapse to unclassified. |
| `--eps F` | 0.45 | Cosine-distance neighborhood radius (0.0–2.0); larger = looser clusters. |
| `--embedding-mode {stub\|voyage\|auto}` | `auto` | `auto`: Voyage when `VOYAGE_API_KEY` is set, else stub. |

#### `propose-taxonomy.sh`

| Flag | Default | Meaning |
|---|---|---|
| `--cluster-output <path>` | `state/cluster-output.json` | Cluster output (`schema_version: sp13-t4/1`). |
| `--ir <path>` | required | Stage 1 IR JSONL — needed for live-mode prompt context (sample text per cluster) and for schema-shape parity in stub mode. |
| `--out <path>` | `state/propose-taxonomy-output.json` | Output taxonomy JSON (`sp13-t5/1`). |
| `--llm-mode {stub\|live\|auto}` | `auto` | `auto`: live when `ANTHROPIC_API_KEY` is set, else stub. |
| `--model-pass1 <model-id>` | `claude-haiku-4-5-20251001` | Model for pass-1 initial taxonomy proposal. |
| `--model-pass2 <model-id>` | `claude-sonnet-4-6` | Model for pass-2 outlier re-pass plus merge/split. |
| `--max-passes {2\|3}` | `3` | Cap on passes; pass-3 only fires when `items_mapped_pct < threshold`. |
| `--low-mapped-threshold F` | `0.80` | Items-mapped-fraction below which pass-3 is triggered. |

#### `import-plan.sh`

| Flag | Default | Meaning |
|---|---|---|
| `--propose-taxonomy <path>` | `state/propose-taxonomy-output.json` | Taxonomy input (`sp13-t5/1`); validated before consumption. |
| `--out <path>` | `state/import-plan.md` | Output import-plan markdown (`sp13-t6/1` declared in YAML frontmatter). |
| `--generated-at <ISO-8601>` | current UTC | Override timestamp; useful for reproducible test runs. |

#### `review-gate.sh`

| Flag | Default | Meaning |
|---|---|---|
| `--import-plan <path>` | `state/import-plan.md` | Import plan input (`sp13-t6/1`); validated before consumption. |
| `--approved-out <path>` | `state/approved-import-plan.md` | Output approved plan written on user `apply`; consumed by Stage 3. |
| `--gate-lib <path>` | `onboarding/lib/three-step-gate.sh` | Gate library; sourced — never forked or re-implemented. |
| `--accept-on-eof` | off | Treat stdin EOF as default `apply` (smoke-test convenience; never default-on for interactive runs). |

## Architecture decisions

### Embedding model — Voyage AI default; deterministic stub fallback

Anthropic does not ship a first-party embeddings API. The recommended provider is **Voyage AI** (`voyage-3-lite` by default; configurable):

- **Production:** when `VOYAGE_API_KEY` is set, batch-call Voyage's `/v1/embeddings` endpoint via `urllib.request` (stdlib-only; no `requests` dependency).
- **Stub:** when no API key is set (or `--embedding-mode stub` is forced), use deterministic hashed-term-frequency vectors (128-dim, MD5-hashed tokens, L2-normalized). Reproducible across runs — used by the test fixture and by adopters without an API account.

Mode is recorded in `cluster-output.json` (`embedding_mode` field) so downstream stages know whether they're consuming high-quality or stub embeddings.

### Clustering — density-based with explicit unclassified bucket

Pure-Python stdlib clustering — **no `hdbscan`, no `numpy`, no `scikit-learn`**. The algorithm is DBSCAN-flavored with HDBSCAN-style semantics in the dimensions that matter:

- **Density expansion** with cosine-similarity neighborhoods (`eps`, default 0.45).
- **`min_cluster_size`** (default 3) — clusters below this collapse to noise.
- **Explicit unclassified bucket** as a first-class cluster record (`cluster_id: "unclassified"`) — never a silent floor. **Data is never silently dropped at the gate.**
- **Per-cluster confidence** in `[0.0, 1.0]` = average pairwise cosine similarity within the cluster. `< 0.5` flagged as `low_confidence: true` for downstream user merge/split.
- **Centroid topic keywords** = top-5 within-cluster tokens by frequency (stopword-filtered) — cheap human-readable summary of each cluster.

Why not `hdbscan`: it would force a numpy / scikit-learn dependency at install time, breaking the foundation's "pure stdlib + jq" profile. The pragmatic loss (true HDBSCAN's hierarchical condensation tree) is small at this corpus scale (50–500 items per onboarding); the user merge/split at the review gate plus the unclassified-pile callout carry the long tail.

### Small-corpus mode

When `n_records < 2 * min_cluster_size`, the algorithm short-circuits: returns `small_corpus: true` with a structured message and a single cluster carrying all members. Small corpora always produce a meaningful cluster or an explicit message — never silent unclassified-bucketing.

### LLM model — Haiku 4.5 pass-1; Sonnet 4.6 pass-2

Pass 1 proposes one candidate per input cluster — high volume, low judgment (the cluster centroid keywords already tell the LLM what each cluster is about). Haiku 4.5 is the right cost/quality point: roughly 10× cheaper than Sonnet, fast enough for 4–8 clusters per typical onboarding corpus.

Pass 2 is the higher-judgment task — re-passing over outliers, proposing merge/split, deciding whether to promote items out of the unclassified pile. Sonnet 4.6 default. Both models are configurable via `--model-pass1` / `--model-pass2`.

### API access — Anthropic Messages API via stdlib `urllib.request`

The skill calls `https://api.anthropic.com/v1/messages` directly via `urllib.request` (matches the Voyage call pattern). API key sourced from `ANTHROPIC_API_KEY`. Credential runbook: [`docs/burner-key-runbook.md`](../../docs/burner-key-runbook.md).

When `ANTHROPIC_API_KEY` is unset (or `--llm-mode stub` is forced), the helper produces a deterministic taxonomy from cluster keywords via local heuristics (meeting / reference / project type classification by token presence). Stub mode is reproducible.

### TnT-LLM iterative refinement — minimum 2 passes; optional pass-3

Per the design contract: minimum 2 LLM passes per run. Pass 1 proposes; pass 2 re-passes over outliers (low-confidence clusters plus the unclassified pile) and emits merge/split/promote operations. Optional pass-3 fires only when `items_mapped_pct < 0.80` after pass-2 — a residual-recovery sweep focused on the remaining unclassified pile.

Merge/split/promote operations are **surfaced** in the per-pass log, **not auto-applied** to the candidate set. The downstream review gate is where the user accepts or rejects refinements — keeping the user-in-the-loop guarantee. Plan-then-code: this skill emits a user-reviewable `import-plan.md` BEFORE any vault mutation.

### Confidence calibration — heuristic, NOT LLM self-reported

LLM self-reported confidence is untrusted per literature consensus. Per-candidate confidence is computed as the dominant-origin-cluster fraction:

```
confidence = max(count_per_origin_cluster) / len(source_items)
```

Candidates whose source items all come from one origin cluster get `confidence = 1.0`. Candidates whose source items split across origin clusters get a penalized score reflecting the spillover. The unclassified pile gets `confidence = 0.0`. `low_confidence: true` fires below 0.5.

### Per-candidate type — explicit enumeration; never silent floor

Candidate `type` is one of `project | reference | meeting | unclassified`. The taxonomy enumerates non-project candidates rather than dropping them on the floor. Stage 3 routing depends on type:

- `project` → PRD/Context/Updates triad scaffolding.
- `reference` → reference doc folder.
- `meeting` → meeting note folder.
- `unclassified` → vault `Inbox/` with `disposition: unclassified` frontmatter.

### Renderer split — bash 3.2 wrapper + pure-stdlib python helper

Each stage has a thin shell wrapper (bash 3.2 compliant) and a Python helper. Markdown table joining and nested YAML emission are awkward in jq; Python is cleaner. No `pyyaml` / `markdown` / `jinja2` dependencies — pure stdlib only.

### Output format — markdown with YAML frontmatter plus inline per-candidate yaml blocks

The on-disk import plan is a single markdown file structured as:

1. **YAML frontmatter** (between `---` lines): `schema_version`, `input_propose_taxonomy_schema_version`, `generated_at`, `header` (corpus stats), `unclassified_callout`, `vault_tree`. Heavy fields render in the body.
2. **Top callout** (above `# Import plan` H1) when the unclassified pile carries items: a fenced markdown blockquote with welcoming, options-first copy. Silent skip when `count = 0`.
3. **`# Import plan — review and edit`** intro paragraph explaining your three options (approve as-is / edit inline / abort).
4. **`## Corpus stats`** bullet list — same data as `header` in frontmatter, surfaced for human reading.
5. **`## Proposed vault tree`** nested bullet list (Engagements/<x>, References/<y>, Meetings/<z>, Inbox/). Markdown bullets chosen over ASCII box-drawing for portability across Obsidian and plain-text editors.
6. **`## Project candidates`** — H3 per project candidate, each with an inline ```yaml block carrying the full structured form. Below the YAML, a prose summary plus rationale.
7. **`## Per-source-item routing`** — markdown table with one row per source item. Columns: source path, candidate_id, destination, type, confidence, ⚠️ flag for low-confidence. Edit individual cells to re-route a single item without changing the candidate.
8. **`## Doesn't fit any project — disposition`** — same H3 + ```yaml pattern as Project candidates, but for non-project types (reference, meeting, unclassified).
9. **`## Refinements (pass-2 merge/split)`** — a single ```yaml block with all merge/split/promote/demote operations surfaced from pass-2 (and pass-3 if triggered).

The review gate reassembles the wrapper from the markdown by parsing frontmatter plus walking H3 sections plus parsing the routing table plus parsing the refinements block. Schema is permissive on user-editable fields so an in-place edit does not break round-trip validation.

### Schema is authoritative for round-trip

`sp13-t6/1` is declared formally as JSON Schema Draft-07 at `schemas/import-plan-schema.json`. The review gate validates the user-edited plan against this schema before consuming. The schema describes the LOGICAL wrapper that the gate reassembles from the markdown — not the markdown layout itself.

Validation properties that matter for round-trip:
- `schema_version` and `input_propose_taxonomy_schema_version` are `const` fields — bumping them requires a coordinated review-gate update.
- `routing_table` row count MUST equal `header.n_records` — every IR record routes to exactly one candidate; the renderer enforces this and exits 1 if upstream candidates do not cover all records.
- `vault_tree` uses `additionalProperties: true` so you can add a top-level folder (e.g. `Personal/`) without breaking validation.
- `metadata` on candidate_block uses `additionalProperties: true` so you can add free-form fields the LLM did not produce.
- `refinements[].from` and `refinements[].into` use `oneOf` (string OR array) — both shapes round-trip without normalization.

### Unclassified callout copy — welcoming, options-first

The callout copy is welcoming, explanatory, and options-first — not jargon-heavy. You see three concrete actions per unclassified item: route to `Inbox/` (default — handed off to the standing inbox processor for later), merge into an existing candidate (edit candidate_id), or remove from the plan entirely. The phrase "no item is silently dropped" reassures you that no data loss is possible at the gate.

Silent skip when `count = 0`: no top callout, no fenced block. The body's "Doesn't fit any project — disposition" section renders with empty-state copy explaining no non-project candidates were detected.

### YAML emitter — defensive quoting; Unicode preserved

The hand-rolled YAML dumper covers the limited shapes this plan emits (scalars + lists + nested dicts + empty containers). Defensive quoting:

- Strings starting with a digit (e.g. timestamps `2026-05-04T17:30:00Z`) are double-quoted to avoid YAML 1.1's implicit timestamp parsing.
- Strings matching reserved YAML words (`true`, `false`, `null`, `yes`, `no`, `on`, `off`, `~`) are double-quoted.
- Strings containing reserved leading characters are double-quoted.
- Unicode characters (em-dashes, smart quotes) are preserved literally for human readability via `json.dumps(..., ensure_ascii=False)`.

### Gate library — sourced, not forked

`review-gate.sh` is a thin shell wrapper that **sources** `onboarding/lib/three-step-gate.sh` via `. "$GATE_LIB"`. The library exposes `gate_generate / gate_preview / gate_apply / gate_set_dry_run`; this skill composes them. The library owns audit-log shape, atomic write semantics, and the inner `[a/e/s/b]` prompt loop. This skill owns the orchestration around it (input validation, the "what happens next" UX, post-edit schema validation, edit-diff-against-original UX surface).

### Action handling — apply / edit / skip / abort

The outer loop reads your choice and:

- **apply (`a`/`A`/empty)** — validate the staged content's `schema_version: sp13-t6/1` anchor still intact. On pass: pipe `'a'` to `gate_apply --skip-preview --accept-on-empty-stdin`, which writes `state/approved-import-plan.md` atomically (cp + mv) and audits `apply`. On fail: surface `STAGED PLAN VALIDATION FAILED` and re-prompt.
- **edit (`e`/`E`)** — invoke `${EDITOR:-vi}` (with a vi/nano/vim fallback chain) on the staged file in place. After editor returns, re-loop back to `gate_preview` so you see your post-edit diff before committing.
- **skip (`s`/`S`)** — pipe `'s'` to `gate_apply --skip-preview --accept-on-empty-stdin`; library audits `skip` and returns rc=0 without writing the target.
- **abort (`b`/`B`/`q`/`Q`)** — pipe `'b'` to `gate_apply`; library audits `abort` and returns rc=1.
- **EOF on stdin without `--accept-on-eof`** — abort path (rc=1, audit `abort` with note `stdin-eof`).

### Edit-diff UX — "what *I* changed" surface

`gate_preview` shows the diff between the **target** and the **staged** content — useful for "what's about to be written" but not for "what *I* changed across edits." This skill snapshots the original gate-generated content to `${STAGE}.orig` BEFORE the loop fires and renders a **second** diff after every loop iteration showing `diff -u $ORIG_STAGE $STAGE` whenever the staged content differs from the original.

You see two distinct diffs at the preview surface: (a) target-vs-proposed (gate_preview, framed "what's about to be written") and (b) original-vs-edited (this skill, framed "your edits"). The double-diff makes split-flagged candidates visibly accept/rejectable via the "your edits" diff, not just buried in the larger gate diff.

The `${STAGE}.orig` snapshot is cleaned up via `trap cleanup_orig EXIT` so it does not leak into Stage 3.

### Audit-log shape — reuse the shared stream; differentiate by surface_id and action

This skill writes to the same `auto-author-log.jsonl` stream the personalization gate library writes to (default: `<foundation-repo>/onboarding/auto-author-log.jsonl`; overridable via `AUTO_AUTHOR_LOG`). Single audit stream is the user-facing surface; differentiation comes from the gate's existing `surface_id` field (`"seed-import-plan"`) plus the `action` field (`generate / preview / apply / skip / abort / error`). Records carry `{ts, surface_id, action, target_path, sha_before, sha_after, note}`.

### Post-edit schema validation — block the round-trip

After every edit cycle (and before invoking `gate_apply` for an `apply` action), the skill greps the staged file for the literal line `schema_version: sp13-t6/1`. Missing-or-different → re-prompt with `STAGED PLAN VALIDATION FAILED`. This is the round-trip contract anchor — Stage 3 reads `approved-import-plan.md` expecting `sp13-t6/1`; the skill refuses to write a target that breaks the contract. Full Draft-07 validation of the reassembled wrapper is deferred to Stage 3 if it wants deeper validation.

## Output schemas

### `cluster-output.json` (`schema_version: sp13-t4/1`)

```json
{
  "schema_version": "sp13-t4/1",
  "embedding_mode": "stub" | "voyage",
  "n_records": 50,
  "n_clusters": 4,
  "min_cluster_size": 3,
  "small_corpus": false,
  "small_corpus_message": null,
  "clusters": [
    {
      "cluster_id": "c0001",
      "members": [{"path": "/abs/path", "source_hash": "1234567890abcdef"}],
      "confidence": 0.7321,
      "centroid_topic_keywords": ["sprint", "review", "delivery"],
      "low_confidence": false
    },
    {
      "cluster_id": "unclassified",
      "members": [],
      "confidence": 0.0,
      "centroid_topic_keywords": [],
      "low_confidence": true
    }
  ]
}
```

`n_clusters` excludes the `unclassified` bucket.

### `propose-taxonomy-output.json` (`schema_version: sp13-t5/1`)

Formal JSON Schema Draft-07 at `schemas/propose-taxonomy-schema.json`. Top-level shape:

```json
{
  "schema_version": "sp13-t5/1",
  "llm_mode": "stub" | "live",
  "embedding_mode_input": "stub" | "voyage",
  "n_records": 50,
  "n_clusters_input": 8,
  "passes": [
    {"pass": 1, "model": "claude-haiku-4-5-20251001", "n_candidates_proposed": 8, "n_items_mapped": 34, "duration_ms": 1234},
    {"pass": 2, "model": "claude-sonnet-4-6", "n_candidates_proposed": 8, "n_items_mapped": 34, "duration_ms": 2345, "merge_split_ops": [{"op": "merge", "from": ["p0005", "p0006"], "into": "p0005", "rationale": "..."}]}
  ],
  "n_passes": 2,
  "items_mapped_pct": 0.68,
  "candidates": [
    {
      "candidate_id": "p0001",
      "label": "alpha",
      "type": "project",
      "proposed_path": "Engagements/alpha",
      "metadata": {"summary": "...", "tags": ["#project/alpha"], "rationale": "..."},
      "source_items": [{"path": "/abs/path", "source_hash": "1234567890abcdef"}],
      "confidence": 1.0,
      "low_confidence": false
    }
  ],
  "small_corpus_input": false,
  "warnings": []
}
```

### `import-plan.md` logical wrapper (`schema_version: sp13-t6/1`)

The skill emits a markdown file; the LOGICAL wrapper validates against `schemas/import-plan-schema.json` (Draft-07). Top-level shape (rendered as YAML frontmatter plus body):

```yaml
schema_version: sp13-t6/1
input_propose_taxonomy_schema_version: sp13-t5/1
generated_at: "2026-05-04T17:30:00Z"
header:
  n_records: 50
  n_clusters: 8
  n_passes: 3
  items_mapped_pct: 0.68
  llm_mode: stub
  embedding_mode_input: stub
  warnings:
    - "items_mapped_pct 0.68 < threshold 0.80 — pass-3 triggered"
unclassified_callout:
  present: true
  count: 16
  copy: "16 items did not fit any cluster. ..."
vault_tree:
  Engagements: ["alpha", "beta", "gamma"]
  References: ["policy"]
  Meetings: ["q2-syncs"]
  Inbox: {}
project_metadata_blocks:
  - candidate_id: p0001
    label: alpha
    type: project
    proposed_path: Engagements/alpha
    metadata: {summary: "...", tags: ["#project/alpha"], rationale: "..."}
    source_items: [{path: "/abs/path", source_hash: "1234567890abcdef"}]
    confidence: 1.0
    low_confidence: false
routing_table:
  - source_path: "/abs/path"
    source_hash: "1234567890abcdef"
    candidate_id: p0001
    destination: Engagements/alpha
    type: project
    confidence: 1.0
    low_confidence: false
non_project_dispositions:
  - candidate_id: p0007
    label: policy
    type: reference
    proposed_path: References/policy
    metadata: {...}
    source_items: [...]
    confidence: 1.0
    low_confidence: false
refinements:
  - op: merge
    from: ["p0005", "p0006"]
    into: p0005
    rationale: "..."
```

Schema is permissive on user-editable fields (`proposed_path`, `type`, `metadata`, `vault_tree.*`) so an in-place edit at the review gate does not break round-trip validation.

## Output Contract

- **Files written:**
  - `onboarding/seed-content/state/cluster-output.json`
  - `onboarding/seed-content/state/propose-taxonomy-output.json`
  - `onboarding/seed-content/state/import-plan.md`
  - `onboarding/seed-content/state/approved-import-plan.md` (only on user `apply`)
  - Audit log entries appended to `onboarding/auto-author-log.jsonl` (one per gate event).

  All paths are gitignored under the foundation-repo's `/state/` and `/onboarding/seed-content/state/` rules. No live `~/.claude/` writes.

- **Schema types:**
  - `sp13-t4/1` declared inline in this doc.
  - `sp13-t5/1` declared formally at `schemas/propose-taxonomy-schema.json` (Draft-07).
  - `sp13-t6/1` declared formally at `schemas/import-plan-schema.json` (Draft-07).
  - Audit-log records reuse the gate library's JSONL shape with `surface_id="seed-import-plan"`.

- **Pre-write validation:**
  - `bash -n` on every `.sh` wrapper; Python `ast.parse` on every `.py` helper.
  - `jq -e .` on every emitted JSON file before downstream consumers read.
  - The renderer enforces `routing_table` row count = `header.n_records` and exits 1 if upstream candidates do not cover every IR record.
  - The review gate grep-validates the `schema_version: sp13-t6/1` anchor on input AND after each edit cycle BEFORE invoking `gate_apply` for an `apply` action.

- **Failure mode — block and log:**
  - cluster: missing IR → exit 2. Voyage API error → exit 3 (caller decides to fall back to stub or fail). Empty output → exit 1.
  - propose-taxonomy: missing cluster-output OR IR → exit 2. Schema mismatch → exit 2. Anthropic API error in live mode → exit 3. Empty output → exit 1.
  - import-plan: missing input → exit 2. Schema mismatch → exit 2. Routing-table coverage gap → exit 1. Empty rendered markdown → exit 1.
  - review-gate: missing input plan → exit 2. Schema mismatch → exit 2. Missing gate library → exit 2. User abort → exit 1 (audit `abort`). User skip → exit 0 (audit `skip`; no target write). Post-edit schema drift → re-prompt; subsequent EOF without `--accept-on-eof` halts with rc=1.

## Dependencies

- **Stage 1 IR** (`onboarding/seed-content/ir-builder.sh` output) — required input for cluster + propose-taxonomy.
- **`python3`** on PATH (stdlib only — no pip installs).
- **Voyage AI account** for production embeddings (cluster only); optional — stub fallback covers test mode and adopters without an account.
- **Anthropic API account** for live taxonomy proposal (propose-taxonomy only); optional — stub fallback covers test mode and adopters without API access.
- **`jq`** — used in every shell wrapper for post-run summary lines; required by the gate library for audit-log JSONL emission.
- **Editor** — review-gate reads `${EDITOR:-vi}` for the edit action; falls back through `vi → nano → vim`. No editor available → re-prompts without invoking edit.

## Downstream consumers

| Consumer | Consumes | Notes |
|---|---|---|
| `seed-projects/seed.sh` | `approved-import-plan.md` (`sp13-t6/1`) | For each `type: project` candidate, scaffolds the directory plus PRD/Context/Updates triads with provenance frontmatter. Each Stage 3 write flows through the gate library for batched preview/apply. |
| `/adopt --retrofit-existing` | The full chain via `orchestrate.sh` | Walks an existing populated vault as IR source; produces a collision matrix appended to the import plan. |
| `/onboard --seed-content <path>` | The full chain via Section F | Greenfield personalization path: dispatches the orchestrator after the seven auto-author surfaces complete. |

## See also

- [`skills/onboarder/SKILL.md`](../onboarder/SKILL.md) — Section F orchestration that drives this skill on greenfield runs.
- [`skills/adopt/SKILL.md`](../adopt/SKILL.md) — retrofit mode that drives this skill plus a collision matrix.
- [`skills/seed-projects/SKILL.md`](../seed-projects/SKILL.md) — Stage 3 scaffolder that consumes `approved-import-plan.md`.
- [`docs/seed-content-pipeline.md`](../../docs/seed-content-pipeline.md) — Stage 1 IR overview.
- [`docs/personalization-model.md`](../../docs/personalization-model.md) — universal/combined/personal classification.
- [`docs/burner-key-runbook.md`](../../docs/burner-key-runbook.md) — credential management for the live LLM and embedding modes.
