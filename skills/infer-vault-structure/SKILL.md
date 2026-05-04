---
name: infer-vault-structure
description: SP13 Stage 2 INFER pipeline. Consumes Stage 1 IR (seed-content-ir-schema.json), clusters records by semantic similarity with explicit unclassified bucket, and (in T-5/T-6) emits an LLM-proposed taxonomy + user-reviewable import-plan.md. T-4 ships the cluster.sh entry — density-based, stdlib-Python, optional Voyage AI embeddings.
disable-model-invocation: true
argument-hint: "[--ir <ir.jsonl>] [--out <cluster-output.json>] [--min-cluster-size N] [--eps F] [--embedding-mode {stub|voyage|auto}]"
---

# infer-vault-structure

Stage 2 of the SP13 content-seeding pipeline. Stage 1 (`onboarding/seed-content/`) produces a unified IR; this skill turns that IR into a cluster map and (downstream) a proposed vault taxonomy. T-4 ships the clustering entry only — T-5 layers the LLM-proposed taxonomy with TnT-LLM iterative refinement; T-6 layers the import-plan markdown generator; T-7 wires the SP12 3-step gate for user review/edit.

## Personalization tier

This is a **Universal capability** per `docs/personalization-model.md` §1 — the skill body is identical for every adopter. Personalization comes from the user's IR contents (their seeded files), not from per-user code. Output artifacts (`state/cluster-output.json`, downstream `import-plan.md`, generated PRD/Context/Updates triads in T-8) carry SP12 provenance frontmatter via `lib/provenance-frontmatter.sh::pf_emit`. See `docs/personalization-model.md` for the full classification framing — this skill does not re-declare it.

## Invocation

`/infer-vault-structure cluster --ir <ir.jsonl> [...]` — calls `cluster.sh`.

Direct script invocation:

```sh
./cluster.sh --ir /tmp/sp13-fixture/ir.jsonl
# → onboarding/seed-content/state/cluster-output.json
```

| Flag | Default | Meaning |
|---|---|---|
| `--ir <path>` | required | Stage 1 IR JSONL (one IR record per line) |
| `--out <path>` | `onboarding/seed-content/state/cluster-output.json` | Output cluster-output JSON |
| `--min-cluster-size N` | 3 | Density threshold; clusters smaller than N collapse to unclassified |
| `--eps F` | 0.45 | Cosine-distance neighborhood radius (0.0–2.0); larger = looser clusters |
| `--embedding-mode {stub|voyage|auto}` | `auto` | `auto`: Voyage when `VOYAGE_API_KEY` set, else stub |

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

## Output Contract (R-43)

- **Files written:** `onboarding/seed-content/state/cluster-output.json` only. Path is gitignored at the foundation-repo `/state/` rule (added 2026-05-03 by SP10 T-13). No live `~/.claude/` writes; no foundation-library mods.
- **Schema type:** `sp13-t4/1` (declared inline in this doc; T-5 may extend or fork into a propose-taxonomy schema per spec L165 carry-forward). JSON Schema declaration deferred until T-5 builds (avoids T-6 hardcoding stale assumptions).
- **Pre-write validation:** `bash -n` on `cluster.sh`; Python `ast.parse` on `cluster.py`; `jq -e .` on emitted `cluster-output.json` before downstream consumers read.
- **Failure mode:** Block and log. Missing IR → exit 2 with stderr line. Voyage API error → exit 3 (caller decides to fall back to stub or fail). Empty output → exit 1 (cluster.sh enforces non-empty file post-helper).

## Dependencies

- **Stage 1 IR** (`onboarding/seed-content/ir-builder.sh` output) — required input.
- **`python3`** on PATH (stdlib only — no pip installs).
- **Voyage AI account** for production embeddings (`VOYAGE_API_KEY` env var); optional — stub fallback covers test + smaller-corpus mode.
- **`jq`** — used in `cluster.sh` for the post-run summary line; non-blocking if absent (output JSON is produced by `cluster.py`).

## Downstream consumers

| Task | Consumes | Notes |
|---|---|---|
| **T-5** propose-taxonomy.sh | `cluster-output.json` | LLM proposes per-cluster project candidate + folder placement; iterates with TnT-LLM (≥2 LLM passes; merge/split over outliers + unclassified pile) |
| **T-6** import-plan.sh | T-5 taxonomy output | Emits user-reviewable `import-plan.md` (Copilot-Workspace plan-then-code pattern) |
| **T-7** review-gate.sh | T-6 import-plan.md | Wires SP12's 3-step gate (`lib/three-step-gate.sh`) for user generate / preview / apply |
| **T-15** UX validation | `cluster-output.json` (unclassified bucket) | Verifies the "review unclassified pile" gate fires correctly across high / low / zero unclassified-density fixtures |

## R-55 isolation

T-4 produces no `~/.claude/` writes. Output target (`onboarding/seed-content/state/`) is foundation-repo internal; gitignored at the `/state/` rule. The hermetic test (`tests/sp13-cluster-test.sh`) provisions everything under `$TMPDIR/sp13-t4-test-XXXXXX` per `feedback_test_isolation_for_hooks_state`. G1 should never fire on a T-4 invocation.
