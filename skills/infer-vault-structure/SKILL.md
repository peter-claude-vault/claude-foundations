---
name: infer-vault-structure
description: SP13 Stage 2 INFER pipeline. Consumes Stage 1 IR (seed-content-ir-schema.json), clusters records by semantic similarity with explicit unclassified bucket (T-4), proposes a per-cluster taxonomy with TnT-LLM iterative refinement (T-5), and renders a user-reviewable import-plan.md (T-6). cluster.sh + propose-taxonomy.sh + import-plan.sh share stdlib-Python helpers; no numpy / requests / sklearn / pydantic / pyyaml.
disable-model-invocation: true
argument-hint: "cluster [--ir <ir.jsonl>] [...] | propose-taxonomy --cluster-output <path> --ir <ir.jsonl> [--llm-mode {stub|live|auto}] | import-plan [--propose-taxonomy <path>] [--out <path>]"
---

# infer-vault-structure

Stage 2 of the SP13 content-seeding pipeline. Stage 1 (`onboarding/seed-content/`) produces a unified IR; this skill turns that IR into a cluster map, a proposed vault taxonomy, and a user-reviewable import plan markdown file. T-4 ships the clustering entry; T-5 layers the LLM-proposed taxonomy with TnT-LLM iterative refinement; T-6 layers the import-plan markdown generator (Copilot-Workspace plan-then-code pattern); T-7 wires the SP12 3-step gate for user review/edit.

## Personalization tier

This is a **Universal capability** per `docs/personalization-model.md` §1 — the skill body is identical for every adopter. Personalization comes from the user's IR contents (their seeded files), not from per-user code. Output artifacts (`state/cluster-output.json`, downstream `import-plan.md`, generated PRD/Context/Updates triads in T-8) carry SP12 provenance frontmatter via `lib/provenance-frontmatter.sh::pf_emit`. See `docs/personalization-model.md` for the full classification framing — this skill does not re-declare it.

## Invocation

`/infer-vault-structure cluster --ir <ir.jsonl> [...]` — calls `cluster.sh` (T-4).
`/infer-vault-structure propose-taxonomy --cluster-output <path> --ir <ir.jsonl> [...]` — calls `propose-taxonomy.sh` (T-5).
`/infer-vault-structure import-plan [--propose-taxonomy <path>] [--out <path>]` — calls `import-plan.sh` (T-6).

Direct script invocation:

```sh
./cluster.sh --ir /tmp/sp13-fixture/ir.jsonl
# → onboarding/seed-content/state/cluster-output.json
./propose-taxonomy.sh --cluster-output onboarding/seed-content/state/cluster-output.json \
                     --ir /tmp/sp13-fixture/ir.jsonl
# → onboarding/seed-content/state/propose-taxonomy-output.json
./import-plan.sh --propose-taxonomy onboarding/seed-content/state/propose-taxonomy-output.json
# → onboarding/seed-content/state/import-plan.md
```

### `cluster.sh` flags (T-4)

| Flag | Default | Meaning |
|---|---|---|
| `--ir <path>` | required | Stage 1 IR JSONL (one IR record per line) |
| `--out <path>` | `onboarding/seed-content/state/cluster-output.json` | Output cluster-output JSON |
| `--min-cluster-size N` | 3 | Density threshold; clusters smaller than N collapse to unclassified |
| `--eps F` | 0.45 | Cosine-distance neighborhood radius (0.0–2.0); larger = looser clusters |
| `--embedding-mode {stub|voyage|auto}` | `auto` | `auto`: Voyage when `VOYAGE_API_KEY` set, else stub |

### `propose-taxonomy.sh` flags (T-5)

| Flag | Default | Meaning |
|---|---|---|
| `--cluster-output <path>` | `onboarding/seed-content/state/cluster-output.json` | T-4 cluster-output (`schema_version: sp13-t4/1`) |
| `--ir <path>` | required | Stage 1 IR JSONL — needed for live-mode prompt context (sample text per cluster) and for schema-shape parity in stub mode |
| `--out <path>` | `onboarding/seed-content/state/propose-taxonomy-output.json` | Output taxonomy JSON (`sp13-t5/1`) |
| `--llm-mode {stub|live|auto}` | `auto` | `auto`: live when `ANTHROPIC_API_KEY` set, else stub |
| `--model-pass1 <model-id>` | `claude-haiku-4-5-20251001` | Model for pass-1 initial taxonomy proposal |
| `--model-pass2 <model-id>` | `claude-sonnet-4-6` | Model for pass-2 outlier re-pass + merge/split |
| `--max-passes {2|3}` | `3` | Cap on TnT-LLM passes; pass-3 only fires when `items_mapped_pct < threshold` |
| `--low-mapped-threshold F` | `0.80` | Items-mapped-fraction below which pass-3 is triggered |

### `import-plan.sh` flags (T-6)

| Flag | Default | Meaning |
|---|---|---|
| `--propose-taxonomy <path>` | `onboarding/seed-content/state/propose-taxonomy-output.json` | T-5 propose-taxonomy output (`schema_version: sp13-t5/1`); validated before consumption |
| `--out <path>` | `onboarding/seed-content/state/import-plan.md` | Output import-plan markdown (`schema_version: sp13-t6/1` declared in YAML frontmatter) |
| `--generated-at <ISO-8601>` | current UTC | Override timestamp; useful for reproducible test runs |

## Architecture decisions (T-4)

### Embedding model — Voyage AI default; deterministic stub fallback

Anthropic does not ship a first-party embeddings API. The Anthropic-recommended provider is **Voyage AI** (`voyage-3-lite` by default; configurable). T-4 takes the path:

- **Production**: when `VOYAGE_API_KEY` is set, batch-call Voyage's `/v1/embeddings` endpoint. Stdlib-only (`urllib.request`); no `requests` dependency. The Voyage path is what users hit when they `/onboard --seed-content` against a real corpus.
- **Stub fallback**: when no API key is set (or `--embedding-mode stub` is forced), use deterministic hashed-term-frequency vectors (128-dim, MD5-hashed tokens, L2-normalized). Reproducible across runs — used by the hermetic test fixture and by users who opt into smaller-corpus mode without an API account.

`auto` mode picks at runtime; `--embedding-mode {stub,voyage}` forces a specific path. Mode is recorded in `cluster-output.json` (`embedding_mode` field) so downstream stages know whether they're consuming high-quality or stub embeddings.

### Clustering — density-based with explicit unclassified bucket

T-4 ships pure-Python stdlib clustering — **no `hdbscan` package, no `numpy`, no `scikit-learn`**. The algorithm is DBSCAN-flavored with HDBSCAN-style semantics in the dimensions that matter for SP13:

- **Density expansion** with cosine-similarity neighborhoods (`eps` parameter; default 0.45 cosine distance).
- **`min_cluster_size`** (default 3) — clusters below this collapse to noise.
- **Explicit unclassified bucket** as a first-class cluster record (`cluster_id: "unclassified"`) — never a silent floor. R1 §6 risk #1 mitigation; T-15 verifies the UX.
- **Per-cluster confidence** in `[0.0, 1.0]` = average pairwise cosine similarity within the cluster. `< 0.5` flagged as `low_confidence: true` for downstream T-7 user merge/split.
- **Centroid topic keywords** = top-5 within-cluster tokens by frequency (stopword-filtered) — cheap human-readable summary of each cluster.

Why not the `hdbscan` package: would force a numpy/scikit-learn dependency on every adopter at install time, breaking the foundation-repo's "pure stdlib + jq" profile. The pragmatic loss (true HDBSCAN's hierarchical condensation tree) is small at SP13's corpus scale (50–500 items per onboarding); user merge/split in T-7 + the unclassified-pile gate in T-15 carry the long tail.

### Small-corpus mode

When `n_records < 2 * min_cluster_size`, the algorithm short-circuits: returns `small_corpus: true` with a structured message and a single cluster carrying ALL members. T-4 AC-5 — small corpora produce meaningful clusters or an explicit message, never silent unclassified-bucketing.

## Architecture decisions (T-5)

### LLM model — haiku 4.5 pass-1 default; sonnet 4.6 pass-2 default

Pass 1 proposes one candidate per input cluster — a high-volume, low-judgment task (the cluster centroid keywords already tell the LLM what each cluster is about; the LLM mostly needs to type-classify and slug-label). Haiku 4.5 is the right cost/quality point: ~10× cheaper than sonnet, fast enough for 4-8 clusters per typical onboarding corpus.

Pass 2 is the higher-judgment task — re-passing over outliers, proposing merge/split, deciding whether to promote items out of the unclassified pile. Sonnet 4.6 default. Both models are configurable via `--model-pass1` / `--model-pass2`.

### API access — Anthropic Messages API via stdlib `urllib.request`

T-5 invokes `https://api.anthropic.com/v1/messages` directly via `urllib.request` (matches T-4's Voyage-call pattern; no `requests` / `anthropic` SDK dependency). API key sourced from `ANTHROPIC_API_KEY` env var. The runbook for credential management is `docs/burner-key-runbook.md`.

When `ANTHROPIC_API_KEY` is unset (or `--llm-mode stub` is forced), the helper produces a deterministic taxonomy from cluster keywords via local heuristics (meeting / reference / project type classification by token presence). Stub mode is reproducible — used by the hermetic test fixture and by adopters without API access.

### TnT-LLM iterative refinement — minimum 2 passes; optional pass-3

Per spec L162: "minimum 2 LLM passes per run." Pass 1 proposes; pass 2 re-passes over outliers (low-confidence clusters + the unclassified pile) and emits merge/split/promote operations. Optional pass-3 fires only when `items_mapped_pct < 0.80` after pass-2 — a residual-recovery sweep focused on the remaining unclassified pile.

Merge/split/promote operations from pass-2 are SURFACED in the per-pass log, NOT auto-applied to the candidate set. The downstream T-7 review gate is where the user accepts/rejects refinements — keeping the user-in-the-loop guarantee per spec L127 ("Plan-then-code: Stage 2 emits user-reviewable `import-plan.md` BEFORE any vault mutation").

### Confidence calibration — heuristic, NOT LLM self-reported

Per spec L170 design question 4: LLM self-reported confidence is untrusted per literature consensus. T-5 computes per-candidate confidence as the dominant-origin-cluster fraction:

```
confidence = max(count_per_origin_cluster) / len(source_items)
```

Candidates whose source_items all came from one origin cluster get `confidence = 1.0`. Candidates whose source_items are split across origin clusters get a penalized score reflecting the spillover. The unclassified pile gets `confidence = 0.0`. `low_confidence: true` fires below 0.5.

### Per-candidate type — explicit enumeration; never silent floor

Per spec L169: candidate `type` is one of `project | reference | meeting | unclassified`. The taxonomy ENUMERATES non-project candidates rather than dropping them on the floor (R1 §6 risk #2 mitigation). Stage 3 routing depends on type:

- `project` → PRD/Context/Updates triad (T-8)
- `reference` → reference doc folder
- `meeting` → meeting note folder
- `unclassified` → vault `Inbox/` with `disposition: unclassified` frontmatter (T-10)

## Architecture decisions (T-6)

### Renderer split — bash 3.2 wrapper + pure-stdlib python3 helper

`import-plan.sh` is a thin arg-parsing wrapper (R-23 bash 3.2 compliant); `import-plan.py` does the markdown rendering. Mirrors T-4 (cluster.sh + cluster.py) and T-5 (propose-taxonomy.sh + propose-taxonomy.py). Markdown table joining and nested YAML emission are awkward in jq; python is cleaner. No `pyyaml` / `markdown` / `jinja2` deps — pure stdlib only.

### Output format — markdown with YAML frontmatter + inline per-candidate ```yaml blocks

The on-disk import plan is a single markdown file structured as:

1. **YAML frontmatter** (between `---` lines) carries the lightweight wrapper fields: `schema_version`, `input_propose_taxonomy_schema_version`, `generated_at`, `header` (corpus stats), `unclassified_callout`, `vault_tree`. Heavy fields (project_metadata_blocks[], routing_table[], non_project_dispositions[], refinements[]) render in the body.
2. **Top call-out** (above `# Import plan` H1) when the unclassified pile carries items: a fenced markdown blockquote with welcoming + options-first copy. Silent skip (no call-out at all) when `count = 0`.
3. **`# Import plan — review and edit`** intro paragraph explaining the user's three options (approve as-is / edit inline / abort).
4. **`## Corpus stats`** bullet list — the same data as `header` in frontmatter, surfaced for human reading. Pass-3 trigger warnings render as bullets here.
5. **`## Proposed vault tree`** nested bullet list (Engagements/<x>, References/<y>, Meetings/<z>, Inbox/). Chosen over ASCII box-drawing for portability across Obsidian + plain-text editors.
6. **`## Project candidates`** — H3 per project candidate, each with an inline ```yaml block carrying the full structured form (candidate_id, label, type, proposed_path, metadata, source_items, confidence, low_confidence). Below the YAML, a prose summary + rationale render for browsing.
7. **`## Per-source-item routing`** — markdown table with one row per source item (row count = `header.n_records`). Columns: source path, candidate_id, destination, type, confidence, ⚠️ flag for low-confidence. User can edit individual cells to re-route a single item without changing the candidate.
8. **`## Doesn’t fit any project — disposition`** — same H3 + ```yaml pattern as Project candidates, but for non-project types (reference, meeting, unclassified).
9. **`## Refinements (pass-2 merge/split)`** — a single ```yaml block with all merge/split/promote/demote ops surfaced from T-5's pass-2 (and pass-3 if triggered). Renders BOTH `from`/`into` shapes (string or array, per T-5 schema oneOf) faithfully — no normalization.

T-7 reassembles the wrapper from the markdown by parsing frontmatter + walking H3 sections + parsing the routing table + parsing the refinements block. Schema is permissive on user-editable fields (`proposed_path`, `type`, `metadata`) so an in-place edit does not break round-trip validation.

### Schema is authoritative for T-7 round-trip

`sp13-t6/1` declared formally as JSON Schema Draft-07 at `schemas/import-plan-schema.json`. T-7 review-gate.sh MUST validate the user-edited plan against this schema before consuming. Schema describes the LOGICAL wrapper that T-7 reassembles from the markdown — not the markdown layout itself.

Validation properties that matter for round-trip:
- `schema_version` and `input_propose_taxonomy_schema_version` are `const` fields — bumping requires a coordinated T-7 update.
- `routing_table` row count MUST equal `header.n_records` — every IR record routes to exactly one candidate; T-6 enforces this at render time (exits 1 if upstream candidates do not cover all records).
- `vault_tree` uses `additionalProperties: true` so a user can add a top-level folder (e.g., `Personal/`) without breaking validation.
- `metadata` on candidate_block uses `additionalProperties: true` so users can add free-form fields the LLM did not produce.
- `refinements[].from` and `refinements[].into` use `oneOf` (string OR array of strings) — both shapes round-trip without normalization.

### Unclassified call-out copy — welcoming, options-first

Per T-15 UX criterion, the call-out copy is welcoming + explanatory + options-first, NOT jargon-heavy. The user reads three concrete actions per unclassified item: route to Inbox/ (default — handed off to the standing inbox processor for later), merge into an existing candidate (edit candidate_id), or remove from the plan entirely. The phrase "no item is silently dropped" reassures the user that no data loss is possible at the gate.

Silent skip when `count = 0`: no top call-out fenced block at all. Frontmatter `unclassified_callout.present` is `false`; the body's "Doesn’t fit any project — disposition" section renders with empty-state copy explaining no non-project candidates were detected.

### YAML emitter — defensive quoting; Unicode preserved

The hand-rolled YAML dumper covers the limited shapes this plan emits (scalars + lists + nested dicts + empty containers). Defensive quoting policies:
- Strings starting with a digit (e.g., timestamps `2026-05-04T17:30:00Z`) are double-quoted to avoid YAML 1.1's implicit timestamp parsing — a known footgun across pyyaml + go-yaml + ruamel.
- Strings matching reserved YAML words (`true`, `false`, `null`, `yes`, `no`, `on`, `off`, `~`) are double-quoted.
- Strings containing reserved leading characters (`!&*{}[],#?|>'%@\`-:`) are double-quoted.
- Unicode characters (em-dashes, smart quotes, etc.) are preserved literally for human readability via `json.dumps(..., ensure_ascii=False)` — the output round-trips through any YAML 1.1/1.2 parser.

## Output schema (`schema_version: sp13-t4/1`)

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
      "members": [...],
      "confidence": 0.0,
      "centroid_topic_keywords": [...],
      "low_confidence": true
    }
  ]
}
```

`n_clusters` excludes the `unclassified` bucket. Carried forward to T-5 propose-taxonomy as the input boundary.

## Output schema (`schema_version: sp13-t5/1`)

T-5 emits a formal JSON Schema Draft-07 document at `schemas/propose-taxonomy-schema.json` (resolves spec L165 carry-forward — "author choice at build time" closed by T-5 declaring the schema explicitly before T-6 import-plan.sh consumes it). Top-level shape:

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
    },
    {
      "candidate_id": "unclassified",
      "label": "unclassified-pile",
      "type": "unclassified",
      "proposed_path": "",
      "metadata": {...},
      "source_items": [...],
      "confidence": 0.0,
      "low_confidence": true
    }
  ],
  "small_corpus_input": false,
  "warnings": []
}
```

T-5 declares this schema as the authoritative contract for downstream T-6 import-plan generator consumption. T-6 MUST validate `schema_version: sp13-t5/1` before reading; mismatched versions short-circuit with a hard error.

## Output schema (`schema_version: sp13-t6/1`)

T-6 emits a markdown file (`import-plan.md`); the LOGICAL wrapper validates against `schemas/import-plan-schema.json` (Draft-07). T-7 review-gate.sh reassembles the wrapper from the on-disk markdown for round-trip validation. Top-level shape:

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
    - "items_mapped_pct 0.68 < threshold 0.80 — pass-3 triggered (focused on residual unclassified pile)"
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
  - op: split
    from: p0004
    into: ["p0004"]
    rationale: "..."
```

T-6 declares this schema as the authoritative contract for downstream T-7 review-gate.sh consumption. T-7 MUST validate `schema_version: sp13-t6/1` before reading the user-edited plan. Schema is permissive on user-editable fields (`proposed_path`, `type`, `metadata`, `vault_tree.*`) so an in-place user edit at T-7 does not break round-trip validation.

## Output Contract (R-43)

- **Files written:**
  - T-4: `onboarding/seed-content/state/cluster-output.json`
  - T-5: `onboarding/seed-content/state/propose-taxonomy-output.json`
  - T-6: `onboarding/seed-content/state/import-plan.md`

  All paths gitignored at the foundation-repo `/state/` rule (added 2026-05-03 by SP10 T-13) and the SP13-specific `/onboarding/seed-content/state/` rule (T-4 close 2026-05-04). No live `~/.claude/` writes; no foundation-library mods.
- **Schema types:**
  - `sp13-t4/1` declared inline in this doc.
  - `sp13-t5/1` declared formally at `schemas/propose-taxonomy-schema.json` (Draft-07). T-6 import-plan.sh MUST validate schema_version before consuming.
  - `sp13-t6/1` declared formally at `schemas/import-plan-schema.json` (Draft-07). T-7 review-gate.sh MUST validate schema_version before consuming the user-edited plan.
- **Pre-write validation:** `bash -n` on `cluster.sh` + `propose-taxonomy.sh` + `import-plan.sh`; Python `ast.parse` on `cluster.py` + `propose-taxonomy.py` + `import-plan.py`; `jq -e .` on every emitted JSON file before downstream consumers read; on T-6, the renderer enforces `routing_table` row count = `header.n_records` and exits 1 if upstream candidates do not cover every IR record.
- **Failure mode:** Block and log.
  - T-4: Missing IR → exit 2 with stderr line. Voyage API error → exit 3 (caller decides to fall back to stub or fail). Empty output → exit 1.
  - T-5: Missing cluster-output OR IR → exit 2. Cluster-output schema_version mismatch → exit 2 with structured stderr. Anthropic API error in live mode → exit 3 (caller decides). Empty output → exit 1.
  - T-6: Missing propose-taxonomy input → exit 2 with stderr line. Input schema_version != sp13-t5/1 → exit 2 with structured stderr. Routing table row count != n_records (upstream coverage gap) → exit 1. Empty rendered markdown → exit 1.

## Dependencies

- **Stage 1 IR** (`onboarding/seed-content/ir-builder.sh` output) — required input for both T-4 and T-5.
- **T-4 cluster-output** — required input for T-5 (`schema_version: sp13-t4/1`).
- **T-5 propose-taxonomy-output** — required input for T-6 (`schema_version: sp13-t5/1`).
- **`python3`** on PATH (stdlib only — no pip installs).
- **Voyage AI account** for production embeddings — T-4 only (`VOYAGE_API_KEY` env var); optional — stub fallback covers test + smaller-corpus mode.
- **Anthropic API account** for live taxonomy proposal — T-5 only (`ANTHROPIC_API_KEY` env var); optional — stub fallback covers test + adopters without API access. Credential management runbook at `docs/burner-key-runbook.md`.
- **`jq`** — used in `cluster.sh` + `propose-taxonomy.sh` + `import-plan.sh` for post-run summary lines; non-blocking if absent (JSON / markdown output is produced by the Python helpers).

## Downstream consumers

| Task | Consumes | Notes |
|---|---|---|
| **T-5** propose-taxonomy.sh | `cluster-output.json` (sp13-t4/1) | SHIPPED 2026-05-04. LLM proposes per-cluster project candidate + folder placement; iterates with TnT-LLM (≥2 LLM passes; merge/split surfaced over outliers + unclassified pile, NOT auto-applied — T-7 user gate is where refinements are accepted). |
| **T-6** import-plan.sh | T-5 `propose-taxonomy-output.json` (sp13-t5/1) | SHIPPED 2026-05-04. Emits user-reviewable `import-plan.md` (Copilot-Workspace plan-then-code pattern). Validates `schema_version: sp13-t5/1` on input; emits `sp13-t6/1` wrapper as YAML frontmatter + per-candidate ```yaml blocks + routing-table markdown table + refinements ```yaml block. |
| **T-7** review-gate.sh | T-6 `import-plan.md` (sp13-t6/1) | Wires SP12's 3-step gate (`lib/three-step-gate.sh`) for user generate / preview / apply. Reassembles the wrapper from the on-disk markdown; validates against `schemas/import-plan-schema.json` before consuming. Pass-2 merge/split ops surface here for explicit user accept/reject. |
| **T-15** UX validation | `cluster-output.json` (unclassified bucket); T-6 unclassified call-out copy | Verifies the "review unclassified pile" gate fires correctly across high / low / zero unclassified-density fixtures; T-6 already exercises silent-skip (zero unclassified) and prominent-call-out (with unclassified) at fixture level — T-15 adds end-to-end UX-quality validation. |

## R-55 isolation

T-4 + T-5 + T-6 produce no `~/.claude/` writes. Output targets (`onboarding/seed-content/state/`) are foundation-repo internal; gitignored at the `/state/` rule. The hermetic tests (`tests/sp13-cluster-test.sh` + `tests/sp13-propose-taxonomy-test.sh` + `tests/sp13-import-plan-test.sh`) provision everything under `$TMPDIR/sp13-{t4,t5,t6}-test-XXXXXX` per `feedback_test_isolation_for_hooks_state`; all unset their respective API keys (`VOYAGE_API_KEY`, `ANTHROPIC_API_KEY`) before running. G1 should never fire on a T-4, T-5, or T-6 invocation.
