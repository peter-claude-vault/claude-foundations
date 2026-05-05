#!/usr/bin/env python3
"""
cluster.py — SP13 T-4 Stage 2 entry: density-based clustering with explicit
unclassified bucket and per-cluster confidence.

Consumes a Stage 1 IR JSONL file (schemas/seed-content-ir-schema.json) and
emits a cluster-output JSON document of shape:

    {
      "schema_version": "cluster-output/1",
      "embedding_mode": "voyage" | "stub",
      "n_records": <int>,
      "n_clusters": <int>,
      "min_cluster_size": <int>,
      "small_corpus": <bool>,
      "small_corpus_message": <str|null>,
      "clusters": [
        {
          "cluster_id": "c0001" | "unclassified",
          "members": [{"path": "...", "source_hash": "..."}, ...],
          "confidence": 0.0..1.0,
          "centroid_topic_keywords": ["term1", "term2", ...]
        },
        ...
      ]
    }

Stdlib-only — no numpy, no scikit-learn, no hdbscan package. The clustering
is density-based with an explicit noise bucket (DBSCAN-style with HDBSCAN-
style semantics: every record routes to a cluster OR the unclassified
bucket; nothing is silently dropped).

Embedding modes:
  - stub  (default when VOYAGE_API_KEY is unset): deterministic local
          hashed-term-frequency vectors. Reproducible. Used by the hermetic
          test fixture.
  - voyage: invokes the Voyage AI embeddings endpoint (voyage-3-lite) when
          VOYAGE_API_KEY is set in the environment. Anthropic's recommended
          embedding provider (no first-party Anthropic embeddings API).

Small-corpus mode: when n_records < 2 * min_cluster_size, returns
small_corpus=true with a structured message and a single cluster carrying
ALL members (rather than silently bucketing all items as unclassified).
This satisfies AC-5 of T-4 — small corpora produce meaningful clusters or
an explicit message, never a silent floor.

R-23: bash 3.2 not relevant here (Python). PEP 8 style. No external deps.
"""

import argparse
import hashlib
import json
import math
import os
import re
import sys
import urllib.request
import urllib.error


VOYAGE_ENDPOINT = "https://api.voyageai.com/v1/embeddings"
VOYAGE_DEFAULT_MODEL = "voyage-3-lite"

STOPWORDS = {
    "the", "a", "an", "and", "or", "but", "if", "of", "to", "in", "on",
    "at", "by", "for", "with", "as", "is", "was", "are", "were", "be",
    "been", "being", "this", "that", "these", "those", "it", "its", "i",
    "we", "you", "they", "he", "she", "him", "her", "them", "my", "our",
    "your", "their", "from", "have", "has", "had", "do", "does", "did",
    "will", "would", "could", "should", "may", "might", "can", "not",
    "no", "yes", "so", "than", "then", "there", "here", "what", "when",
    "where", "who", "why", "how", "which", "while", "about", "into",
}


def tokenize(text):
    """Lowercase, alpha-only word tokens, length >= 3, stopwords removed."""
    return [
        t for t in re.findall(r"[a-zA-Z][a-zA-Z\-']{2,}", text.lower())
        if t not in STOPWORDS and len(t) >= 3
    ]


def stub_embedding(text, dim=128):
    """
    Deterministic hashed-term-frequency vector. Reproducible across runs.
    Each token contributes to a single dimension via stable hash; vector is
    L2-normalized so cosine similarity is dot product.
    """
    vec = [0.0] * dim
    for tok in tokenize(text):
        h = int(hashlib.md5(tok.encode("utf-8")).hexdigest(), 16)
        vec[h % dim] += 1.0
    norm = math.sqrt(sum(x * x for x in vec))
    if norm > 0:
        vec = [x / norm for x in vec]
    return vec


def voyage_embedding_batch(texts, api_key, model=VOYAGE_DEFAULT_MODEL):
    """
    Batch-call Voyage embeddings for a list of texts. Returns a list of
    L2-normalized float vectors. Raises on HTTP error.
    """
    payload = json.dumps({
        "input": texts,
        "model": model,
        "input_type": "document",
    }).encode("utf-8")
    req = urllib.request.Request(
        VOYAGE_ENDPOINT,
        data=payload,
        headers={
            "Authorization": "Bearer " + api_key,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    out = []
    for item in body["data"]:
        v = item["embedding"]
        norm = math.sqrt(sum(x * x for x in v))
        out.append([x / norm for x in v] if norm > 0 else v)
    return out


def cosine(a, b):
    return sum(x * y for x, y in zip(a, b))


def density_cluster(vectors, eps, min_cluster_size):
    """
    DBSCAN-flavored density clustering.

    - For each unvisited point, expand a cluster from all points within
      cosine distance < eps (i.e., similarity > 1 - eps).
    - Clusters smaller than min_cluster_size collapse to noise.
    - Returns: list of cluster-id-per-point (int >= 0) or -1 for noise.
    """
    n = len(vectors)
    labels = [None] * n
    cluster_id = -1

    def neighbors(i):
        out = []
        sim_threshold = 1.0 - eps
        for j in range(n):
            if i == j:
                continue
            if cosine(vectors[i], vectors[j]) >= sim_threshold:
                out.append(j)
        return out

    for i in range(n):
        if labels[i] is not None:
            continue
        nbrs = neighbors(i)
        if len(nbrs) + 1 < min_cluster_size:
            labels[i] = -1
            continue
        cluster_id += 1
        labels[i] = cluster_id
        seeds = list(nbrs)
        idx = 0
        while idx < len(seeds):
            q = seeds[idx]
            idx += 1
            if labels[q] == -1:
                labels[q] = cluster_id
            if labels[q] is not None:
                continue
            labels[q] = cluster_id
            qn = neighbors(q)
            if len(qn) + 1 >= min_cluster_size:
                for k in qn:
                    if k not in seeds:
                        seeds.append(k)

    return labels


def cluster_confidence(member_vectors):
    """
    Confidence in [0.0, 1.0]: 1 - (avg_pairwise_cosine_distance).

    Single-member clusters get confidence 0.5 (no internal coherence
    measurable). For >= 2 members, average pairwise cosine similarity is
    used directly; clamped to [0, 1].
    """
    n = len(member_vectors)
    if n <= 1:
        return 0.5
    total = 0.0
    pairs = 0
    for i in range(n):
        for j in range(i + 1, n):
            total += cosine(member_vectors[i], member_vectors[j])
            pairs += 1
    avg = total / pairs if pairs > 0 else 0.0
    return max(0.0, min(1.0, avg))


def centroid_topic_keywords(records, top_k=5):
    """
    Top-k tokens by within-cluster term frequency. Stopword-filtered;
    stably sorted (count desc, then token asc). Used as a cheap
    human-readable summary of each cluster.
    """
    counts = {}
    for r in records:
        for tok in tokenize(r.get("normalized_text", "")):
            counts[tok] = counts.get(tok, 0) + 1
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    return [t for t, _ in ranked[:top_k]]


def load_ir(ir_path):
    records = []
    with open(ir_path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            records.append(json.loads(line))
    return records


def main():
    ap = argparse.ArgumentParser(
        description="SP13 T-4 cluster.py — density-based clustering"
    )
    ap.add_argument("--ir", required=True, help="Path to Stage 1 IR JSONL")
    ap.add_argument("--out", required=True, help="Path for cluster-output.json")
    ap.add_argument("--min-cluster-size", type=int, default=3)
    ap.add_argument("--eps", type=float, default=0.45,
                    help="Cosine-distance neighborhood radius (0.0-2.0)")
    ap.add_argument("--embedding-mode", choices=["stub", "voyage", "auto"],
                    default="auto",
                    help="auto: voyage if VOYAGE_API_KEY set, else stub")
    ap.add_argument("--low-confidence-threshold", type=float, default=0.5)
    args = ap.parse_args()

    records = load_ir(args.ir)
    n = len(records)

    mode = args.embedding_mode
    if mode == "auto":
        mode = "voyage" if os.environ.get("VOYAGE_API_KEY") else "stub"

    if n == 0:
        out = {
            "schema_version": "cluster-output/1",
            "embedding_mode": mode,
            "n_records": 0,
            "n_clusters": 0,
            "min_cluster_size": args.min_cluster_size,
            "small_corpus": True,
            "small_corpus_message": "ir is empty; nothing to cluster",
            "clusters": [],
        }
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(out, fh, indent=2, sort_keys=True)
        return 0

    texts = [r.get("normalized_text", "") for r in records]
    if mode == "voyage":
        api_key = os.environ.get("VOYAGE_API_KEY", "")
        if not api_key:
            print("cluster.py: --embedding-mode voyage requires VOYAGE_API_KEY",
                  file=sys.stderr)
            return 2
        try:
            vectors = voyage_embedding_batch(texts, api_key)
        except urllib.error.URLError as e:
            print("cluster.py: voyage api error: %s" % e, file=sys.stderr)
            return 3
    else:
        vectors = [stub_embedding(t) for t in texts]

    small_corpus = n < (2 * args.min_cluster_size)
    small_corpus_message = None

    if small_corpus:
        keywords = centroid_topic_keywords(records)
        confidence = cluster_confidence(vectors)
        small_corpus_message = (
            "corpus too small for confident clustering — proceed to "
            "taxonomy proposal directly (n=%d < 2 * min_cluster_size=%d)"
            % (n, args.min_cluster_size)
        )
        clusters = [
            {
                "cluster_id": "c0001",
                "members": [
                    {"path": r["path"], "source_hash": r["source_hash"]}
                    for r in records
                ],
                "confidence": round(confidence, 4),
                "centroid_topic_keywords": keywords,
                "low_confidence": confidence < args.low_confidence_threshold,
            }
        ]
        out = {
            "schema_version": "cluster-output/1",
            "embedding_mode": mode,
            "n_records": n,
            "n_clusters": 1,
            "min_cluster_size": args.min_cluster_size,
            "small_corpus": True,
            "small_corpus_message": small_corpus_message,
            "clusters": clusters,
        }
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(out, fh, indent=2, sort_keys=True)
        return 0

    labels = density_cluster(vectors, args.eps, args.min_cluster_size)

    by_label = {}
    for idx, lbl in enumerate(labels):
        by_label.setdefault(lbl, []).append(idx)

    clusters = []
    sorted_label_ids = sorted(k for k in by_label.keys() if k != -1)
    next_id = 1
    for lbl in sorted_label_ids:
        idxs = by_label[lbl]
        members_records = [records[i] for i in idxs]
        members_vectors = [vectors[i] for i in idxs]
        conf = cluster_confidence(members_vectors)
        clusters.append({
            "cluster_id": "c%04d" % next_id,
            "members": [
                {"path": r["path"], "source_hash": r["source_hash"]}
                for r in members_records
            ],
            "confidence": round(conf, 4),
            "centroid_topic_keywords": centroid_topic_keywords(members_records),
            "low_confidence": conf < args.low_confidence_threshold,
        })
        next_id += 1

    if -1 in by_label:
        idxs = by_label[-1]
        unclassified_records = [records[i] for i in idxs]
        clusters.append({
            "cluster_id": "unclassified",
            "members": [
                {"path": r["path"], "source_hash": r["source_hash"]}
                for r in unclassified_records
            ],
            "confidence": 0.0,
            "centroid_topic_keywords":
                centroid_topic_keywords(unclassified_records),
            "low_confidence": True,
        })

    out = {
        "schema_version": "cluster-output/1",
        "embedding_mode": mode,
        "n_records": n,
        "n_clusters": sum(1 for c in clusters if c["cluster_id"] != "unclassified"),
        "min_cluster_size": args.min_cluster_size,
        "small_corpus": False,
        "small_corpus_message": None,
        "clusters": clusters,
    }
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2, sort_keys=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
