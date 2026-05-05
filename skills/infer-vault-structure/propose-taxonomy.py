#!/usr/bin/env python3
"""
propose-taxonomy.py — SP13 T-5 Stage 2: LLM-proposed taxonomy with TnT-LLM
iterative refinement.

Consumes a T-4 cluster-output.json (sp13-t4/1) plus its source Stage 1 IR
JSONL; emits a propose-taxonomy-output.json validating against
schemas/propose-taxonomy-schema.json (sp13-t5/1).

Pass orchestration (TnT-LLM, spec L162):
  Pass 1  (haiku 4.5, default): initial taxonomy proposal — one candidate
          per input cluster, classified as project | reference | meeting,
          plus a single 'unclassified' candidate for the noise bucket.
  Pass 2  (sonnet 4.6, default): re-pass over outliers — low-confidence
          clusters + the unclassified pile — proposing merge/split/promote
          operations and emitting a revised taxonomy.
  Pass 3  (sonnet, OPTIONAL): only fires when items_mapped_pct < 0.80 after
          pass 2, focused on the residual unclassified pile.

LLM modes (mirrors T-4's --embedding-mode pattern):
  stub  (default when ANTHROPIC_API_KEY is unset): deterministic taxonomy
        derived from cluster keywords. Reproducible. Used by the hermetic
        test fixture and adopters without API access.
  live  (auto-selected when ANTHROPIC_API_KEY is set): invokes Anthropic's
        /v1/messages endpoint via stdlib urllib.request — no requests dep.
  auto  (default): live when ANTHROPIC_API_KEY is set, else stub.

Confidence calibration (spec L170 design question 4):
  HEURISTIC, NOT LLM SELF-REPORTED. For each candidate, find the dominant
  origin cluster among source_items and compute count_dominant / total.
  Self-reported LLM confidence is untrusted per literature consensus.

R-23: stdlib only. No requests, numpy, pydantic. Bash 3.2 not relevant
(Python). Output is JSON Schema Draft-07 conformant (sp13-t5/1).
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request


ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages"
ANTHROPIC_API_VERSION = "2023-06-01"

DEFAULT_MODEL_PASS1 = "claude-haiku-4-5-20251001"
DEFAULT_MODEL_PASS2 = "claude-sonnet-4-6"
DEFAULT_LOW_MAPPED_THRESHOLD = 0.80

SCHEMA_VERSION = "sp13-t5/1"

# Keyword heuristics for stub-mode type classification. Order matters —
# meeting/reference checks fire before project default, so a cluster about
# "weekly status meetings on policy" routes to meeting (the most specific
# disposition wins). Live-mode prompts make the same priority explicit.
MEETING_KEYWORDS = {
    "meeting", "meetings", "call", "calls", "sync", "syncs", "standup",
    "review", "reviews", "kickoff", "1on1", "one-on-one", "retrospective",
    "retro", "agenda", "minutes", "notes", "transcript", "attendees",
}
REFERENCE_KEYWORDS = {
    "policy", "policies", "reference", "guide", "guides", "how-to", "howto",
    "documentation", "doc", "docs", "manual", "spec", "specification",
    "rfc", "playbook", "runbook", "faq", "glossary", "checklist",
}


def load_cluster_output(path):
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if data.get("schema_version") != "sp13-t4/1":
        print(
            "propose-taxonomy.py: cluster-output schema_version mismatch: "
            "expected sp13-t4/1, got %r" % data.get("schema_version"),
            file=sys.stderr,
        )
        sys.exit(2)
    return data


def load_ir(path):
    by_hash = {}
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            by_hash[rec["source_hash"]] = rec
    return by_hash


def slugify(text, max_len=40):
    """Lowercase, hyphen-joined token slug. Used for stub labels + paths."""
    s = re.sub(r"[^a-zA-Z0-9]+", "-", text.lower()).strip("-")
    return s[:max_len] or "candidate"


def classify_keywords_stub(keywords):
    """
    Stub-mode type classification from a cluster's centroid keywords.
    Most-specific wins: meeting > reference > project.
    """
    kset = {k.lower() for k in keywords}
    if kset & MEETING_KEYWORDS:
        return "meeting"
    if kset & REFERENCE_KEYWORDS:
        return "reference"
    return "project"


def proposed_path_for(ctype, label):
    """
    Vault-relative path heuristic. Mirrors common consultant-vault layouts;
    user can edit at the T-7 review gate.
    """
    if ctype == "project":
        return "Engagements/" + label
    if ctype == "reference":
        return "References/" + label
    if ctype == "meeting":
        return "Meetings/" + label
    return ""  # unclassified


def stub_pass1(cluster_output):
    """
    Deterministic pass-1 proposal from cluster keywords. One candidate per
    typed cluster + one 'unclassified' candidate carrying every member of
    the upstream unclassified bucket.
    """
    candidates = []
    next_id = 1
    unclassified_items = []

    for cluster in cluster_output["clusters"]:
        cid = cluster["cluster_id"]
        members = cluster["members"]
        if cid == "unclassified":
            unclassified_items.extend(members)
            continue
        keywords = cluster.get("centroid_topic_keywords", [])
        ctype = classify_keywords_stub(keywords)
        label = slugify(keywords[0] if keywords else cid)
        candidates.append({
            "candidate_id": "p%04d" % next_id,
            "label": label,
            "type": ctype,
            "proposed_path": proposed_path_for(ctype, label),
            "metadata": {
                "summary": "stub-derived candidate from cluster %s "
                           "(keywords=%s)" % (cid, ",".join(keywords[:3])),
                "tags": ["#" + ctype + "/" + label],
                "rationale": "stub keyword heuristic: %s" % ctype,
            },
            "source_items": list(members),
            "_origin_clusters": [cid] * len(members),
        })
        next_id += 1

    candidates.append({
        "candidate_id": "unclassified",
        "label": "unclassified-pile",
        "type": "unclassified",
        "proposed_path": "",
        "metadata": {
            "summary": "items the upstream cluster step could not bucket; "
                       "the review gate surfaces these for user disposition",
            "tags": ["#unclassified"],
            "rationale": "noise bucket from sp13-t4/1 cluster output",
        },
        "source_items": unclassified_items,
        "_origin_clusters": ["unclassified"] * len(unclassified_items),
    })
    return candidates


def stub_pass2(candidates, cluster_output):
    """
    Deterministic pass-2 refinement. Surfaces merge/split operations on
    low-confidence clusters and overlapping-keyword candidate pairs. Stub
    mode does NOT actually mutate the candidate set — pass-2 is a probe
    surface for the test fixture and a stand-in for the live LLM's
    revision call.
    """
    ops = []

    low_conf_cluster_ids = {
        c["cluster_id"] for c in cluster_output["clusters"]
        if c.get("low_confidence") and c["cluster_id"] != "unclassified"
    }
    for cand in candidates:
        if cand["type"] == "unclassified":
            continue
        origin_set = set(cand.get("_origin_clusters", []))
        if origin_set & low_conf_cluster_ids:
            ops.append({
                "op": "split",
                "from": cand["candidate_id"],
                "into": [cand["candidate_id"]],
                "rationale": "low-confidence origin cluster — surfaced for "
                             "user merge/split at the review gate",
            })

    by_label_token = {}
    for cand in candidates:
        if cand["type"] == "unclassified":
            continue
        token = cand["label"].split("-")[0]
        by_label_token.setdefault(token, []).append(cand["candidate_id"])
    for token, ids in by_label_token.items():
        if len(ids) >= 2:
            ops.append({
                "op": "merge",
                "from": ids,
                "into": ids[0],
                "rationale": "overlapping label token %r — candidate for "
                             "user-confirmed merge at the review gate" % token,
            })

    return ops


def anthropic_messages(api_key, model, system, user, max_tokens=4096):
    """
    Stdlib Anthropic Messages API call. Returns the first content text
    block as a string. Raises urllib.error.URLError on transport failure
    and RuntimeError on shape failure.
    """
    payload = json.dumps({
        "model": model,
        "max_tokens": max_tokens,
        "system": system,
        "messages": [{"role": "user", "content": user}],
    }).encode("utf-8")
    req = urllib.request.Request(
        ANTHROPIC_ENDPOINT,
        data=payload,
        headers={
            "x-api-key": api_key,
            "anthropic-version": ANTHROPIC_API_VERSION,
            "content-type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    blocks = body.get("content", [])
    for block in blocks:
        if block.get("type") == "text":
            return block.get("text", "")
    raise RuntimeError("anthropic response carried no text content block")


def parse_llm_json(text):
    """
    Extract the first balanced top-level JSON object from a possibly-fenced
    LLM response. Tolerates ```json fences, leading/trailing commentary.
    """
    fence = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if fence:
        return json.loads(fence.group(1))
    start = text.find("{")
    if start < 0:
        raise RuntimeError("llm response carried no json object")
    depth = 0
    in_str = False
    esc = False
    for idx in range(start, len(text)):
        ch = text[idx]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return json.loads(text[start:idx + 1])
    raise RuntimeError("llm response had unbalanced json")


def cluster_summary_for_prompt(cluster_output, ir_by_hash, sample_chars=240):
    """
    Compact representation of upstream clusters for LLM prompts — keywords +
    a small text excerpt per cluster. Bounded to keep prompt cost stable.
    """
    summaries = []
    for cluster in cluster_output["clusters"]:
        sample = ""
        for m in cluster["members"][:2]:
            rec = ir_by_hash.get(m.get("source_hash"))
            if rec:
                sample += rec.get("normalized_text", "")[:sample_chars] + "\n---\n"
        summaries.append({
            "cluster_id": cluster["cluster_id"],
            "n_members": len(cluster["members"]),
            "keywords": cluster.get("centroid_topic_keywords", []),
            "low_confidence": cluster.get("low_confidence", False),
            "sample": sample.strip(),
        })
    return summaries


def live_pass1(cluster_output, ir_by_hash, api_key, model):
    """
    Live-mode pass-1: ask the LLM to propose one candidate per input
    cluster. Unclassified bucket is preserved verbatim as a single
    candidate (LLM is not asked to re-cluster the noise pile in pass 1 —
    that's pass 2's job).
    """
    summaries = cluster_summary_for_prompt(cluster_output, ir_by_hash)
    typed_clusters = [s for s in summaries if s["cluster_id"] != "unclassified"]

    system = (
        "You are proposing a vault folder taxonomy from a set of "
        "embedding-clustered content excerpts. For each cluster, propose "
        "exactly one candidate folder. Classify candidates as one of: "
        "project (active body of work with a goal and timeline), "
        "reference (policy / guide / runbook / spec — durable knowledge), "
        "meeting (transcripts, minutes, recurring sync notes). When in "
        "doubt between project and reference, prefer project. Return "
        "ONLY a JSON object — no prose, no fences."
    )
    user = (
        "Clusters to label:\n" + json.dumps(typed_clusters, indent=2) +
        "\n\nReturn JSON of shape:\n"
        '{"candidates": [{"cluster_id": "<input cluster_id>", '
        '"label": "<short slug>", "type": "project|reference|meeting", '
        '"proposed_path": "<vault-relative path like Engagements/<name>>", '
        '"summary": "<1 sentence>", "rationale": "<why this type>"}]}'
    )
    text = anthropic_messages(api_key, model, system, user)
    parsed = parse_llm_json(text)

    proposed = {p["cluster_id"]: p for p in parsed.get("candidates", [])}
    candidates = []
    next_id = 1
    unclassified_items = []
    for cluster in cluster_output["clusters"]:
        cid = cluster["cluster_id"]
        members = cluster["members"]
        if cid == "unclassified":
            unclassified_items.extend(members)
            continue
        prop = proposed.get(cid)
        if not prop:
            label = slugify(
                (cluster.get("centroid_topic_keywords") or [cid])[0]
            )
            ctype = "project"
            ppath = proposed_path_for(ctype, label)
            summary = "live-pass-1 fallback (model omitted cluster %s)" % cid
            rationale = "fallback default"
        else:
            label = slugify(prop.get("label") or cid)
            ctype = prop.get("type", "project")
            if ctype not in ("project", "reference", "meeting"):
                ctype = "project"
            ppath = prop.get("proposed_path") or proposed_path_for(ctype, label)
            summary = prop.get("summary", "")
            rationale = prop.get("rationale", "")
        candidates.append({
            "candidate_id": "p%04d" % next_id,
            "label": label,
            "type": ctype,
            "proposed_path": ppath,
            "metadata": {
                "summary": summary,
                "tags": ["#" + ctype + "/" + label],
                "rationale": rationale,
            },
            "source_items": list(members),
            "_origin_clusters": [cid] * len(members),
        })
        next_id += 1

    candidates.append({
        "candidate_id": "unclassified",
        "label": "unclassified-pile",
        "type": "unclassified",
        "proposed_path": "",
        "metadata": {
            "summary": "items the upstream cluster step could not bucket; "
                       "the review gate surfaces these for user disposition",
            "tags": ["#unclassified"],
            "rationale": "noise bucket from sp13-t4/1 cluster output",
        },
        "source_items": unclassified_items,
        "_origin_clusters": ["unclassified"] * len(unclassified_items),
    })
    return candidates


def live_pass2(candidates, cluster_output, ir_by_hash, api_key, model):
    """
    Live-mode pass-2: TnT-LLM iterative refinement. Re-passes over outliers
    (low-confidence clusters + unclassified pile) and asks for explicit
    merge/split/promote ops + revised types. Returns ops list ONLY; does
    not mutate candidates structurally (caller logs ops; merge/split is
    surfaced to user at T-7 review gate, not auto-applied — keeps the
    user-in-the-loop guarantee per spec L127).
    """
    summaries = cluster_summary_for_prompt(cluster_output, ir_by_hash)
    low_conf = [s for s in summaries
                if s.get("low_confidence") and s["cluster_id"] != "unclassified"]
    unclassified = [s for s in summaries if s["cluster_id"] == "unclassified"]

    if not low_conf and (not unclassified or unclassified[0]["n_members"] == 0):
        return [{
            "op": "promote",
            "from": "(none)",
            "into": "(none)",
            "rationale": "no low-confidence clusters and no unclassified items — "
                         "pass-1 taxonomy stands without merge/split",
        }]

    cand_summary = [
        {
            "candidate_id": c["candidate_id"],
            "label": c["label"],
            "type": c["type"],
            "n_source_items": len(c["source_items"]),
        }
        for c in candidates
    ]

    system = (
        "You are reviewing a draft vault taxonomy and proposing refinement "
        "operations. The input is: (a) the draft candidates from pass 1, "
        "(b) low-confidence clusters that may need split or reassignment, "
        "(c) the unclassified pile that may contain hidden projects or "
        "reference material. Propose operations of type merge / split / "
        "promote (where promote means: pull items out of unclassified into "
        "a new typed candidate). Be conservative — humans review at T-7. "
        "Return ONLY a JSON object — no prose, no fences."
    )
    user = (
        "Draft candidates:\n" + json.dumps(cand_summary, indent=2) +
        "\n\nLow-confidence clusters:\n" + json.dumps(low_conf, indent=2) +
        "\n\nUnclassified pile:\n" + json.dumps(unclassified, indent=2) +
        "\n\nReturn JSON of shape:\n"
        '{"ops": [{"op": "merge|split|promote", '
        '"from": "<id or [ids]>", "into": "<id or [ids]>", '
        '"rationale": "<short reason>"}]}'
    )
    try:
        text = anthropic_messages(api_key, model, system, user)
        parsed = parse_llm_json(text)
    except Exception as e:
        return [{
            "op": "promote",
            "from": "(error)",
            "into": "(error)",
            "rationale": "pass-2 live call failed: %s" % e,
        }]
    ops = parsed.get("ops", [])
    if not ops:
        ops = [{
            "op": "promote",
            "from": "(none)",
            "into": "(none)",
            "rationale": "model proposed no refinement ops",
        }]
    return ops


def compute_confidence(candidates):
    """
    Heuristic confidence per candidate (spec L170 design question 4):
    fraction of source_items whose origin cluster is the dominant cluster.
    Independent of LLM self-report. Unclassified pile gets 0.0.
    """
    for cand in candidates:
        if cand["type"] == "unclassified":
            cand["confidence"] = 0.0
            cand["low_confidence"] = True
            cand.pop("_origin_clusters", None)
            continue
        origins = cand.get("_origin_clusters", [])
        if not origins:
            cand["confidence"] = 0.0
            cand["low_confidence"] = True
        else:
            counts = {}
            for o in origins:
                counts[o] = counts.get(o, 0) + 1
            dominant = max(counts.values())
            conf = dominant / len(origins)
            cand["confidence"] = round(conf, 4)
            cand["low_confidence"] = conf < 0.5
        cand.pop("_origin_clusters", None)


def items_mapped_pct(candidates, n_records):
    if n_records <= 0:
        return 0.0
    typed = sum(
        len(c["source_items"]) for c in candidates
        if c["type"] != "unclassified"
    )
    return round(typed / n_records, 4)


def main():
    ap = argparse.ArgumentParser(
        description="SP13 T-5 propose-taxonomy.py — LLM-proposed taxonomy "
                    "with TnT-LLM iterative refinement"
    )
    ap.add_argument("--cluster-output", required=True,
                    help="Path to T-4 cluster-output.json (sp13-t4/1)")
    ap.add_argument("--ir", required=True,
                    help="Path to Stage 1 IR JSONL (used for sample text in "
                         "live LLM prompts; required even in stub mode for "
                         "schema-shape parity)")
    ap.add_argument("--out", required=True,
                    help="Path for propose-taxonomy-output.json")
    ap.add_argument("--llm-mode", choices=["stub", "live", "auto"],
                    default="auto",
                    help="auto: live if ANTHROPIC_API_KEY set, else stub")
    ap.add_argument("--model-pass1", default=DEFAULT_MODEL_PASS1)
    ap.add_argument("--model-pass2", default=DEFAULT_MODEL_PASS2)
    ap.add_argument("--max-passes", type=int, default=3, choices=[2, 3])
    ap.add_argument("--low-mapped-threshold", type=float,
                    default=DEFAULT_LOW_MAPPED_THRESHOLD)
    args = ap.parse_args()

    cluster_output = load_cluster_output(args.cluster_output)
    ir_by_hash = load_ir(args.ir)

    mode = args.llm_mode
    if mode == "auto":
        mode = "live" if os.environ.get("ANTHROPIC_API_KEY") else "stub"

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if mode == "live" and not api_key:
        print("propose-taxonomy.py: --llm-mode live requires "
              "ANTHROPIC_API_KEY", file=sys.stderr)
        return 2

    passes = []
    warnings = []

    t0 = time.time()
    if mode == "stub":
        candidates = stub_pass1(cluster_output)
        pass1_model = "stub"
    else:
        try:
            candidates = live_pass1(
                cluster_output, ir_by_hash, api_key, args.model_pass1
            )
            pass1_model = args.model_pass1
        except (urllib.error.URLError, RuntimeError) as e:
            print("propose-taxonomy.py: pass-1 live call failed: %s" % e,
                  file=sys.stderr)
            return 3
    pass1_dur = int((time.time() - t0) * 1000)
    n_typed_p1 = sum(1 for c in candidates if c["type"] != "unclassified")
    n_mapped_p1 = sum(
        len(c["source_items"]) for c in candidates
        if c["type"] != "unclassified"
    )
    passes.append({
        "pass": 1,
        "model": pass1_model,
        "n_candidates_proposed": n_typed_p1,
        "n_items_mapped": n_mapped_p1,
        "duration_ms": pass1_dur,
    })

    t1 = time.time()
    if mode == "stub":
        ops = stub_pass2(candidates, cluster_output)
        pass2_model = "stub"
    else:
        ops = live_pass2(
            candidates, cluster_output, ir_by_hash, api_key, args.model_pass2
        )
        pass2_model = args.model_pass2
    pass2_dur = int((time.time() - t1) * 1000)
    passes.append({
        "pass": 2,
        "model": pass2_model,
        "n_candidates_proposed": n_typed_p1,
        "n_items_mapped": n_mapped_p1,
        "duration_ms": pass2_dur,
        "merge_split_ops": ops,
    })

    pct = items_mapped_pct(candidates, cluster_output["n_records"])
    if pct < args.low_mapped_threshold and args.max_passes >= 3:
        warnings.append(
            "items_mapped_pct %.2f < threshold %.2f — pass-3 triggered "
            "(focused on residual unclassified pile)"
            % (pct, args.low_mapped_threshold)
        )
        t2 = time.time()
        if mode == "stub":
            pass3_ops = [{
                "op": "promote",
                "from": "unclassified",
                "into": "(none)",
                "rationale": "stub pass-3: no structural promotion in stub "
                             "mode; live runs would attempt residual recovery",
            }]
            pass3_model = "stub"
        else:
            pass3_ops = live_pass2(
                candidates, cluster_output, ir_by_hash, api_key,
                args.model_pass2
            )
            pass3_model = args.model_pass2
        pass3_dur = int((time.time() - t2) * 1000)
        passes.append({
            "pass": 3,
            "model": pass3_model,
            "n_candidates_proposed": n_typed_p1,
            "n_items_mapped": n_mapped_p1,
            "duration_ms": pass3_dur,
            "merge_split_ops": pass3_ops,
        })

    compute_confidence(candidates)

    out = {
        "schema_version": SCHEMA_VERSION,
        "llm_mode": mode,
        "embedding_mode_input": cluster_output.get("embedding_mode", "stub"),
        "n_records": cluster_output.get("n_records", 0),
        "n_clusters_input": cluster_output.get("n_clusters", 0),
        "passes": passes,
        "n_passes": len(passes),
        "items_mapped_pct": pct,
        "candidates": candidates,
        "small_corpus_input": cluster_output.get("small_corpus", False),
        "warnings": warnings,
    }
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2, sort_keys=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
