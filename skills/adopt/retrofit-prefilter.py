#!/usr/bin/env python3
"""
retrofit-prefilter.py — SP13 T-13 retrofit prefilter.

Consumes a propose-taxonomy-output.json (propose-taxonomy/1) plus the source IR JSONL
plus the vault root, and emits two artifacts:

  1. retrofit-filtered-taxonomy.json (propose-taxonomy/1; valid input for import-plan.sh)
       Candidates whose proposed_path is already a scaffolded vault directory
       (i.e., contains PRD.md / Context.md / Updates.md) are DROPPED — Stage 3
       must not re-scaffold these. The dropped candidates surface in the matrix
       as `keep` rows (advisory).

  2. retrofit-matrix.json (sp13-t13/1; consumed by retrofit-collision-matrix.py)
       Full retrofit metadata: per-IR-record action enum, dropped-candidate
       record, idempotency-skip record. The collision-matrix renderer walks
       this file to produce the markdown appendix.

Action enum (Refinement #2 from design review — "respect existing folder
structure as default-keep"):

  scaffold   — type=project, proposed_path NOT already scaffolded → seed.sh
               creates the new folder + PRD/Context/Updates triad.
  keep       — type=project, proposed_path IS already scaffolded → no-op.
  move-to    — type ∈ {reference, meeting} where source_items don't already
               cluster under a coherent existing parent folder. Advisory; the
               user must move files manually post-gate (full auto-move is
               v2.x scope per spec L424).
  inbox      — type=unclassified → route to <vault>/Inbox/ via inbox-disposition.sh
  review     — low_confidence (< 0.5) candidates of any type → user must
               triage. Advisory.

Keep-heuristic for `move-to` vs `keep` on reference/meeting candidates:
  Compute modal parent directory of source_items. If ≥ KEEP_THRESHOLD
  (default 0.8) of items share a single parent dir, mark `keep`. Otherwise
  `move-to`. Threshold tunable via --retrofit-keep-threshold.

Stdlib only — no pyyaml / requests / numpy.

R-43 Output Contract:
  - Files written: retrofit-filtered-taxonomy.json + retrofit-matrix.json
    at $stage_dir.
  - Schema-types: filtered-taxonomy is propose-taxonomy/1 (drop-only filter; same
    shape); matrix is sp13-t13/1 (declared inline in this file's emission).
  - Pre-write validation: input schema_version anchor on propose-taxonomy
    + IR; vault-root must be a directory.
  - Failure mode: BLOCK AND LOG. Bad input → exit 2. No partial writes.

Author: Claude Opus 4.7 — Plan 71 SP13 Session 11 (T-13).
"""

import argparse
import json
import os
import sys
from collections import Counter


SCHEMA_VERSION_TAXONOMY_INPUT = "propose-taxonomy/1"
SCHEMA_VERSION_MATRIX_OUTPUT = "sp13-t13/1"
RETROFIT_VERSION = "v2.1.0"
DEFAULT_KEEP_THRESHOLD = 0.8


def err(msg):
    sys.stderr.write("retrofit-prefilter.py: %s\n" % msg)


def load_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def load_jsonl(path):
    out = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            out.append(json.loads(line))
    return out


def is_already_scaffolded(vault_root, proposed_path):
    """A vault folder is "already scaffolded" iff it exists AND contains
    at least one of PRD.md / Context.md / Updates.md (the seed-projects
    triad markers)."""
    if not proposed_path:
        return False
    folder = os.path.join(vault_root, proposed_path.lstrip("/"))
    if not os.path.isdir(folder):
        return False
    for marker in ("PRD.md", "Context.md", "Updates.md"):
        if os.path.isfile(os.path.join(folder, marker)):
            return True
    return False


def modal_parent_ratio(source_items, vault_root):
    """Return (parent_dir, ratio) for the modal parent directory of
    source_items relative to vault_root. parent_dir is a vault-relative
    string (or "" for vault root). ratio is fraction of items sharing
    that parent. Empty source_items → ("", 0.0)."""
    if not source_items:
        return ("", 0.0)
    parents = []
    for it in source_items:
        if not isinstance(it, dict):
            continue
        path = it.get("path", "")
        if not path:
            continue
        # Make path vault-relative if possible.
        try:
            rel = os.path.relpath(path, vault_root)
        except ValueError:
            rel = path
        parent = os.path.dirname(rel)
        # Normalize "" (vault root) and "." consistently.
        if parent == ".":
            parent = ""
        parents.append(parent)
    if not parents:
        return ("", 0.0)
    counter = Counter(parents)
    modal_parent, modal_count = counter.most_common(1)[0]
    ratio = modal_count / float(len(parents))
    return (modal_parent, ratio)


def classify_candidate(cand, vault_root, keep_threshold):
    """Compute the retrofit-action for a candidate. Returns a dict with
    keys {action, modal_parent, modal_ratio, already_scaffolded, reason}.

    Action enum: scaffold | keep | move-to | inbox | review.
    """
    cand_type = cand.get("type", "unclassified")
    proposed_path = cand.get("proposed_path", "")
    low_confidence = bool(cand.get("low_confidence", False))
    confidence = cand.get("confidence", 0.0)
    source_items = cand.get("source_items", []) or []

    modal_parent, modal_ratio = modal_parent_ratio(source_items, vault_root)
    already_scaffolded = is_already_scaffolded(vault_root, proposed_path)

    # Low-confidence first — gates everything else (matches spec risk #1).
    if low_confidence:
        return {
            "action": "review",
            "modal_parent": modal_parent,
            "modal_ratio": modal_ratio,
            "already_scaffolded": already_scaffolded,
            "reason": "confidence %.2f < 0.5; user must triage" % confidence,
        }

    if cand_type == "project":
        if already_scaffolded:
            return {
                "action": "keep",
                "modal_parent": modal_parent,
                "modal_ratio": modal_ratio,
                "already_scaffolded": True,
                "reason": (
                    "%s already contains PRD/Context/Updates; "
                    "no re-scaffold" % proposed_path
                ),
            }
        return {
            "action": "scaffold",
            "modal_parent": modal_parent,
            "modal_ratio": modal_ratio,
            "already_scaffolded": False,
            "reason": (
                "new project candidate; Stage 3 will scaffold "
                "%s" % proposed_path
            ),
        }

    if cand_type == "unclassified":
        return {
            "action": "inbox",
            "modal_parent": modal_parent,
            "modal_ratio": modal_ratio,
            "already_scaffolded": False,
            "reason": "type=unclassified; route to <vault>/Inbox/",
        }

    if cand_type in ("reference", "meeting"):
        # Refinement #2: respect existing folder structure as default-keep.
        # If items already cluster under a coherent existing parent, leave
        # them alone. Only suggest move-to when items scatter or live in
        # ad-hoc locations.
        if modal_parent and modal_ratio >= keep_threshold:
            # Items are already coherent. Are they under a sensible folder?
            # We accept ANY coherent existing parent, not just the
            # type-canonical one (References/ or Meetings/) — user-defined
            # taxonomy is respected.
            return {
                "action": "keep",
                "modal_parent": modal_parent,
                "modal_ratio": modal_ratio,
                "already_scaffolded": False,
                "reason": (
                    "%.0f%% of items already under '%s'; respect "
                    "existing structure" % (modal_ratio * 100, modal_parent)
                ),
            }
        return {
            "action": "move-to",
            "modal_parent": modal_parent,
            "modal_ratio": modal_ratio,
            "already_scaffolded": False,
            "reason": (
                "items scatter (modal '%s' at %.0f%% < %.0f%% threshold); "
                "advisory move to %s" % (
                    modal_parent or "(vault root)",
                    modal_ratio * 100,
                    keep_threshold * 100,
                    proposed_path,
                )
            ),
        }

    # Fallthrough — unknown type. Defensive.
    return {
        "action": "review",
        "modal_parent": modal_parent,
        "modal_ratio": modal_ratio,
        "already_scaffolded": already_scaffolded,
        "reason": "unknown type %r; user must triage" % cand_type,
    }


def main():
    ap = argparse.ArgumentParser(
        description="SP13 T-13 retrofit prefilter — drops already-scaffolded "
                    "candidates and annotates remaining candidates with "
                    "retrofit-action metadata for matrix rendering.",
    )
    ap.add_argument("--propose-taxonomy", required=True,
                    help="Path to T-5 propose-taxonomy-output.json (propose-taxonomy/1).")
    ap.add_argument("--ir", required=True,
                    help="Path to T-3 IR JSONL.")
    ap.add_argument("--vault-root", required=True,
                    help="Vault root (existing files live under here).")
    ap.add_argument("--filtered-taxonomy-out", required=True,
                    help="Output path for filtered taxonomy "
                         "(propose-taxonomy/1; consumed by import-plan.sh).")
    ap.add_argument("--matrix-out", required=True,
                    help="Output path for retrofit matrix metadata "
                         "(sp13-t13/1; consumed by retrofit-collision-matrix).")
    ap.add_argument("--idempotency-skip-list", default="",
                    help="Optional path to a newline-separated list of files "
                         "that retrofit.sh skipped at intake time because they "
                         "already carry generated_by: retrofit@*. Surfaced in "
                         "the matrix as `idempotency-skip` rows.")
    ap.add_argument("--retrofit-keep-threshold", type=float,
                    default=DEFAULT_KEEP_THRESHOLD,
                    help="Modal-parent-dir ratio above which reference/meeting "
                         "candidates are treated as `keep` rather than "
                         "`move-to`. Default 0.8.")
    args = ap.parse_args()

    if not os.path.isdir(args.vault_root):
        err("vault-root not a directory: %s" % args.vault_root)
        sys.exit(2)

    taxonomy = load_json(args.propose_taxonomy)
    sv = taxonomy.get("schema_version")
    if sv != SCHEMA_VERSION_TAXONOMY_INPUT:
        err("propose-taxonomy schema_version mismatch: expected %r, got %r"
            % (SCHEMA_VERSION_TAXONOMY_INPUT, sv))
        sys.exit(2)

    if not os.path.isfile(args.ir):
        err("IR file not found: %s" % args.ir)
        sys.exit(2)
    ir_records = load_jsonl(args.ir)

    # Build path -> IR-record index for quick lookup at matrix render.
    ir_index = {rec.get("path", ""): rec for rec in ir_records if rec.get("path")}

    # Idempotency-skip list (optional; retrofit.sh provides).
    idempotency_skip = []
    if args.idempotency_skip_list:
        if os.path.isfile(args.idempotency_skip_list):
            with open(args.idempotency_skip_list, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if line:
                        idempotency_skip.append(line)

    # Classify every candidate.
    candidates = taxonomy.get("candidates", []) or []
    classifications = {}
    for cand in candidates:
        cid = cand.get("candidate_id", "unknown")
        classifications[cid] = classify_candidate(
            cand, args.vault_root, args.retrofit_keep_threshold,
        )

    # Compose filtered taxonomy: keep all candidates EXCEPT type=project
    # candidates whose action == "keep" (already scaffolded). Those are not
    # passed to import-plan.sh because seed.sh shouldn't re-scaffold them;
    # they DO appear in the matrix as `keep` rows.
    filtered_candidates = []
    dropped_candidates_for_matrix = []
    for cand in candidates:
        cid = cand.get("candidate_id", "unknown")
        cls = classifications[cid]
        if cls["action"] == "keep" and cand.get("type") == "project":
            dropped_candidates_for_matrix.append({
                "candidate_id": cid,
                "label": cand.get("label", ""),
                "type": cand.get("type", ""),
                "proposed_path": cand.get("proposed_path", ""),
                "source_items": cand.get("source_items", []) or [],
                "classification": cls,
                "drop_reason": "already-scaffolded",
            })
            continue
        filtered_candidates.append(cand)

    filtered_taxonomy = dict(taxonomy)  # shallow copy
    filtered_taxonomy["candidates"] = filtered_candidates
    # Preserve schema_version anchor (propose-taxonomy/1) — filtered output is still a
    # valid propose-taxonomy/1 instance (we only dropped items from a list with
    # minItems 0).

    # Build per-IR-record matrix rows. Every IR record is one matrix row.
    # For each IR record, find which candidate owns it (search source_items
    # across ALL classifications, including dropped ones).
    matrix_rows = []
    for rec in ir_records:
        path = rec.get("path", "")
        record_hash = rec.get("source_hash", "")
        owner = None
        for cand in candidates:
            for it in cand.get("source_items", []) or []:
                if isinstance(it, dict) and it.get("path") == path:
                    owner = cand
                    break
            if owner:
                break
        if owner is None:
            # Orphan — defensive (shouldn't happen; T-5 routes every record).
            matrix_rows.append({
                "existing_path": path,
                "source_hash": record_hash,
                "format": rec.get("format", ""),
                "candidate_id": "(orphan)",
                "candidate_label": "",
                "type": "",
                "proposed_action": "review",
                "target": "",
                "confidence": 0.0,
                "low_confidence": True,
                "modal_parent": "",
                "modal_ratio": 0.0,
                "rationale": "no candidate owns this record",
            })
            continue
        cid = owner.get("candidate_id", "unknown")
        cls = classifications.get(cid, {})
        matrix_rows.append({
            "existing_path": path,
            "source_hash": record_hash,
            "format": rec.get("format", ""),
            "candidate_id": cid,
            "candidate_label": owner.get("label", ""),
            "type": owner.get("type", ""),
            "proposed_action": cls.get("action", "review"),
            "target": owner.get("proposed_path", ""),
            "confidence": owner.get("confidence", 0.0),
            "low_confidence": bool(owner.get("low_confidence", False)),
            "modal_parent": cls.get("modal_parent", ""),
            "modal_ratio": cls.get("modal_ratio", 0.0),
            "rationale": cls.get("reason", ""),
        })

    # Append idempotency-skip rows (files retrofit.sh excluded at intake).
    for path in idempotency_skip:
        matrix_rows.append({
            "existing_path": path,
            "source_hash": "",
            "format": "",
            "candidate_id": "(skipped)",
            "candidate_label": "",
            "type": "",
            "proposed_action": "idempotency-skip",
            "target": "",
            "confidence": 0.0,
            "low_confidence": False,
            "modal_parent": "",
            "modal_ratio": 0.0,
            "rationale": (
                "carries generated_by: retrofit@*; previously retrofitted"
            ),
        })

    matrix = {
        "schema_version": SCHEMA_VERSION_MATRIX_OUTPUT,
        "retrofit_version": RETROFIT_VERSION,
        "vault_root": args.vault_root,
        "n_ir_records": len(ir_records),
        "n_candidates_input": len(candidates),
        "n_candidates_kept": len(filtered_candidates),
        "n_candidates_dropped_already_scaffolded": len(dropped_candidates_for_matrix),
        "n_idempotency_skipped": len(idempotency_skip),
        "keep_threshold": args.retrofit_keep_threshold,
        "matrix_rows": matrix_rows,
        "dropped_candidates": dropped_candidates_for_matrix,
        "candidate_classifications": [
            {
                "candidate_id": cid,
                "action": cls.get("action"),
                "modal_parent": cls.get("modal_parent"),
                "modal_ratio": cls.get("modal_ratio"),
                "already_scaffolded": cls.get("already_scaffolded"),
                "reason": cls.get("reason"),
            }
            for cid, cls in classifications.items()
        ],
    }

    # Atomic writes.
    tmp_filtered = args.filtered_taxonomy_out + ".tmp.%d" % os.getpid()
    with open(tmp_filtered, "w", encoding="utf-8") as fh:
        json.dump(filtered_taxonomy, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.rename(tmp_filtered, args.filtered_taxonomy_out)

    tmp_matrix = args.matrix_out + ".tmp.%d" % os.getpid()
    with open(tmp_matrix, "w", encoding="utf-8") as fh:
        json.dump(matrix, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.rename(tmp_matrix, args.matrix_out)

    # Quiet on success; emit summary on stderr.
    sys.stderr.write(
        "retrofit-prefilter.py: %d IR records; %d candidates "
        "(%d kept, %d already-scaffolded dropped); %d idempotency-skipped\n"
        % (
            len(ir_records),
            len(candidates),
            len(filtered_candidates),
            len(dropped_candidates_for_matrix),
            len(idempotency_skip),
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
