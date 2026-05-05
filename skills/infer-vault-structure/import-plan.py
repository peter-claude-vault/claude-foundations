#!/usr/bin/env python3
"""
import-plan.py — SP13 T-6 Stage 2: render the user-reviewable import plan.

Consumes a T-5 propose-taxonomy-output.json (sp13-t5/1); emits a markdown
file (import-plan.md) carrying the 6 required sections per spec L196-200:
  (a) corpus stats header (frontmatter)
  (b) proposed vault tree (nested bullet list)
  (c) per-project metadata YAML blocks (one per type=project candidate;
      fenced ```yaml inline under each H3 heading)
  (d) per-source-item routing table (markdown table; row count = n_records)
  (e) "doesn't fit" disposition section (non-project candidates)
  (f) "review the unclassified pile" PROMINENT call-out at top when
      unclassified items exist; silent skip when zero (per T-15 UX criterion)

The on-disk markdown is the surface; the LOGICAL wrapper validates against
schemas/import-plan-schema.json (sp13-t6/1). Downstream T-7 review-gate.sh
parses the markdown back into the wrapper for validation + user edits;
schema is permissive on user-editable fields (proposed_path, type,
metadata) so an in-place edit does not break round-trip validation.

Renderer language: pure stdlib python3 (no requests / numpy / pyyaml /
markdown deps). YAML emitter is hand-rolled and covers the limited shapes
this plan needs (scalars + lists + nested dicts + empty containers); the
output round-trips through any YAML 1.1/1.2 parser including pyyaml +
ruamel + go-yaml.

R-23 not relevant (Python). R-43 Output Contract: writes a single markdown
file at --out; non-zero exit on input schema mismatch (2), missing input
(2), or empty render (1).
"""

import argparse
import datetime
import json
import os
import re
import sys


SCHEMA_VERSION = "sp13-t6/1"
EXPECTED_INPUT_SCHEMA = "sp13-t5/1"


YAML_SAFE_BARE = re.compile(r"^[A-Za-z_][A-Za-z0-9_./@#-]*$")


def _quote(value):
    """JSON-style double-quote that preserves Unicode literally (em-dashes,
    smart quotes, etc.) rather than escaping to \\uXXXX. Output stays
    valid YAML + valid JSON."""
    return json.dumps(value, ensure_ascii=False)


def yaml_scalar(value):
    """
    Emit a YAML 1.2-compatible scalar. Quotes strings that would otherwise
    parse as bool/null/number or contain reserved characters; numbers /
    bools / null pass through literally; empty string emits as "".
    Unicode characters are preserved literally for human readability.
    """
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        if isinstance(value, float) and value != value:  # NaN
            return ".nan"
        return repr(value) if isinstance(value, float) else str(value)
    if not isinstance(value, str):
        value = str(value)
    if value == "":
        return '""'
    reserved_words = {"true", "false", "null", "yes", "no", "on", "off", "~"}
    if value.lower() in reserved_words:
        return _quote(value)
    if value[0] in "!&*{}[],#?|>'%@`-:" or value[-1] == ":" or " #" in value:
        return _quote(value)
    if value.lstrip() != value or value.rstrip() != value:
        return _quote(value)
    if "\n" in value or '"' in value:
        return _quote(value)
    if YAML_SAFE_BARE.match(value):
        return value
    if re.match(r"^-?\d+(\.\d+)?$", value) or re.match(r"^-?\.\d+$", value):
        return _quote(value)
    return _quote(value)


def yaml_dump(value, indent=0, _is_root=True):
    """
    Recursive YAML dumper for the limited shapes this plan emits.
    Produces block-style output for dicts and lists; inline style for
    empty containers. No anchors / aliases / tags / multi-document.
    """
    pad = "  " * indent
    lines = []
    if isinstance(value, dict):
        if not value:
            return "{}" if not _is_root else "{}\n"
        for k, v in value.items():
            key = yaml_scalar(k) if not (isinstance(k, str) and YAML_SAFE_BARE.match(k)) else k
            if isinstance(v, dict):
                if not v:
                    lines.append(pad + key + ": {}")
                else:
                    lines.append(pad + key + ":")
                    lines.append(yaml_dump(v, indent + 1, _is_root=False))
            elif isinstance(v, list):
                if not v:
                    lines.append(pad + key + ": []")
                else:
                    lines.append(pad + key + ":")
                    lines.append(yaml_dump(v, indent + 1, _is_root=False))
            else:
                lines.append(pad + key + ": " + yaml_scalar(v))
        return "\n".join(lines) + ("\n" if _is_root else "")
    if isinstance(value, list):
        if not value:
            return "[]" if not _is_root else "[]\n"
        for item in value:
            if isinstance(item, dict):
                if not item:
                    lines.append(pad + "- {}")
                else:
                    keys = list(item.keys())
                    first_key = keys[0]
                    first_val = item[first_key]
                    if isinstance(first_val, (dict, list)) and first_val:
                        lines.append(pad + "-")
                        lines.append(yaml_dump(item, indent + 1, _is_root=False))
                    else:
                        first_label = first_key if (isinstance(first_key, str) and YAML_SAFE_BARE.match(first_key)) else yaml_scalar(first_key)
                        if isinstance(first_val, dict):
                            lines.append(pad + "- " + first_label + ": {}")
                        elif isinstance(first_val, list):
                            if not first_val:
                                lines.append(pad + "- " + first_label + ": []")
                            else:
                                lines.append(pad + "- " + first_label + ":")
                                lines.append(yaml_dump(first_val, indent + 2, _is_root=False))
                        else:
                            lines.append(pad + "- " + first_label + ": " + yaml_scalar(first_val))
                        for k in keys[1:]:
                            v = item[k]
                            label = k if (isinstance(k, str) and YAML_SAFE_BARE.match(k)) else yaml_scalar(k)
                            if isinstance(v, dict):
                                if not v:
                                    lines.append(pad + "  " + label + ": {}")
                                else:
                                    lines.append(pad + "  " + label + ":")
                                    lines.append(yaml_dump(v, indent + 2, _is_root=False))
                            elif isinstance(v, list):
                                if not v:
                                    lines.append(pad + "  " + label + ": []")
                                else:
                                    lines.append(pad + "  " + label + ":")
                                    lines.append(yaml_dump(v, indent + 2, _is_root=False))
                            else:
                                lines.append(pad + "  " + label + ": " + yaml_scalar(v))
            elif isinstance(item, list):
                if not item:
                    lines.append(pad + "- []")
                else:
                    lines.append(pad + "-")
                    lines.append(yaml_dump(item, indent + 1, _is_root=False))
            else:
                lines.append(pad + "- " + yaml_scalar(item))
        return "\n".join(lines) + ("\n" if _is_root else "")
    return yaml_scalar(value) + ("\n" if _is_root else "")


def load_propose_taxonomy(path):
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    sv = data.get("schema_version")
    if sv != EXPECTED_INPUT_SCHEMA:
        print(
            "import-plan.py: input schema_version mismatch: expected %r, "
            "got %r" % (EXPECTED_INPUT_SCHEMA, sv),
            file=sys.stderr,
        )
        sys.exit(2)
    return data


def build_vault_tree(candidates):
    """
    Walk candidates by type → top-level folder map → list of subfolder
    labels. Inbox is always present as a leaf folder (the disposition
    target for unclassified items, even when the unclassified pile is
    empty in this run).
    """
    tree = {
        "Engagements": [],
        "References": [],
        "Meetings": [],
        "Inbox": {},
    }
    for cand in candidates:
        if cand["type"] == "project":
            tree["Engagements"].append(cand["label"])
        elif cand["type"] == "reference":
            tree["References"].append(cand["label"])
        elif cand["type"] == "meeting":
            tree["Meetings"].append(cand["label"])
    return tree


def build_unclassified_callout(candidates):
    """
    Detect the unclassified candidate (if any). Render a welcoming +
    options-first call-out per T-15 UX criterion. Silent skip when zero.
    """
    unc = next(
        (c for c in candidates if c["candidate_id"] == "unclassified"),
        None,
    )
    if not unc:
        return {"present": False, "count": 0, "copy": ""}
    n = len(unc.get("source_items", []))
    if n == 0:
        return {"present": False, "count": 0, "copy": ""}
    noun = "item" if n == 1 else "items"
    pronoun = "it" if n == 1 else "them"
    copy = (
        "%d %s did not fit any cluster. Scroll to the "
        "\"Doesn't fit any project\" section below to triage %s — "
        "no item is silently dropped. For each one you can: "
        "route it to Inbox/ (default — your standing inbox processor "
        "will revisit when more context exists), merge it into an "
        "existing candidate by editing its candidate_id, or remove it "
        "from the plan entirely." % (n, noun, pronoun)
    )
    return {"present": True, "count": n, "copy": copy}


def build_routing_table(candidates):
    """
    Per-source-item flatten across all candidates. Row count must equal
    n_records (every IR record routes to exactly one candidate; T-5
    guarantees this).
    """
    rows = []
    for cand in candidates:
        for item in cand.get("source_items", []):
            rows.append({
                "source_path": item.get("path", ""),
                "source_hash": item.get("source_hash", ""),
                "candidate_id": cand["candidate_id"],
                "destination": cand.get("proposed_path", "") or "Inbox/",
                "type": cand["type"],
                "confidence": cand.get("confidence", 0.0),
                "low_confidence": cand.get("low_confidence", False),
            })
    return rows


def build_refinements(propose_data):
    """
    Pass-2 + optional pass-3 merge/split/promote/demote ops surface for
    user review at T-7. Renders as a single ```yaml block at the bottom.
    Carry both string + array shapes faithfully (oneOf in T-5 schema).
    """
    refinements = []
    for p in propose_data.get("passes", []):
        for op in p.get("merge_split_ops", []) or []:
            keep = {"op": op.get("op")}
            if "from" in op:
                keep["from"] = op["from"]
            if "into" in op:
                keep["into"] = op["into"]
            if "rationale" in op:
                keep["rationale"] = op["rationale"]
            refinements.append(keep)
    return refinements


def build_wrapper(propose_data, generated_at):
    candidates = propose_data.get("candidates", [])
    project_blocks = []
    non_project = []
    for cand in candidates:
        block = {
            "candidate_id": cand["candidate_id"],
            "label": cand.get("label", ""),
            "type": cand["type"],
            "proposed_path": cand.get("proposed_path", ""),
            "metadata": cand.get("metadata", {}),
            "source_items": cand.get("source_items", []),
            "confidence": cand.get("confidence", 0.0),
            "low_confidence": cand.get("low_confidence", False),
        }
        if cand["type"] == "project":
            project_blocks.append(block)
        else:
            non_project.append(block)

    header = {
        "n_records": propose_data.get("n_records", 0),
        "n_clusters": propose_data.get("n_clusters_input", 0),
        "n_passes": propose_data.get("n_passes", 0),
        "items_mapped_pct": propose_data.get("items_mapped_pct", 0.0),
        "llm_mode": propose_data.get("llm_mode", "stub"),
        "embedding_mode_input": propose_data.get("embedding_mode_input", "stub"),
    }
    warnings = propose_data.get("warnings", [])
    if warnings:
        header["warnings"] = warnings

    return {
        "schema_version": SCHEMA_VERSION,
        "input_propose_taxonomy_schema_version": EXPECTED_INPUT_SCHEMA,
        "generated_at": generated_at,
        "header": header,
        "unclassified_callout": build_unclassified_callout(candidates),
        "vault_tree": build_vault_tree(candidates),
        "project_metadata_blocks": project_blocks,
        "routing_table": build_routing_table(candidates),
        "non_project_dispositions": non_project,
        "refinements": build_refinements(propose_data),
    }


def render_frontmatter(wrapper):
    """
    Top-of-file YAML frontmatter carries the lightweight wrapper fields
    (schema_version, generated_at, header, unclassified_callout,
    vault_tree). Heavy fields (project_metadata_blocks, routing_table,
    non_project_dispositions, refinements) render in the body — split is
    intentional so the on-disk markdown stays human-readable while T-7
    can still reassemble the full wrapper from frontmatter + body.
    """
    fm = {
        "schema_version": wrapper["schema_version"],
        "input_propose_taxonomy_schema_version":
            wrapper["input_propose_taxonomy_schema_version"],
        "generated_at": wrapper["generated_at"],
        "header": wrapper["header"],
        "unclassified_callout": wrapper["unclassified_callout"],
        "vault_tree": wrapper["vault_tree"],
    }
    body = yaml_dump(fm, indent=0).rstrip("\n")
    return "---\n" + body + "\n---\n"


def render_top_callout(callout):
    if not callout["present"]:
        return ""
    return (
        "> ⚠️ **Review the unclassified pile.**\n"
        "> " + callout["copy"].replace("\n", "\n> ") + "\n"
    )


def render_corpus_stats(header):
    pct = header.get("items_mapped_pct", 0.0)
    pct_pretty = "%.0f%%" % (pct * 100)
    lines = [
        "## Corpus stats",
        "",
        "- **%d source records** ingested." % header["n_records"],
        "- **%d clusters** identified by upstream embedding pass (excluding "
        "the unclassified bucket)." % header["n_clusters"],
        "- **%d LLM passes** ran (mode: `%s`)."
        % (header["n_passes"], header["llm_mode"]),
        "- **%s of items** mapped to a typed candidate; the rest land in the "
        "unclassified pile." % pct_pretty,
        "- Embedding mode: `%s`." % header["embedding_mode_input"],
    ]
    for warning in header.get("warnings", []):
        lines.append("- ⚠️ Warning: " + warning)
    lines.append("")
    return "\n".join(lines)


def render_vault_tree(tree):
    lines = ["## Proposed vault tree", ""]
    for top in ("Engagements", "References", "Meetings"):
        children = tree.get(top, [])
        if not children:
            lines.append("- `%s/` _(empty — no candidates of this type)_" % top)
            continue
        lines.append("- `%s/`" % top)
        for child in children:
            lines.append("  - `%s/`" % child)
    lines.append("- `Inbox/`")
    lines.append("")
    lines.append(
        "> Edit any folder above to re-place the candidate. "
        "Path edits also need to be applied to the candidate's "
        "`proposed_path` field below — keep them consistent."
    )
    lines.append("")
    return "\n".join(lines)


def render_candidate_block(block, level_h):
    """
    H{level_h} per candidate + inline ```yaml fenced block carrying the
    full structured form. Renderer surfaces low_confidence visibly in the
    heading so flagged candidates are not buried (per session prompt
    carry-forward from T-5 design).
    """
    flag = " ⚠️ low confidence" if block.get("low_confidence") else ""
    path = block.get("proposed_path") or "(unrouted)"
    heading = "%s %s — `%s`%s" % (
        "#" * level_h, block["label"], path, flag,
    )
    yaml_body = yaml_dump(block, indent=0).rstrip("\n")
    summary = (block.get("metadata") or {}).get("summary", "")
    rationale = (block.get("metadata") or {}).get("rationale", "")
    parts = [heading, "", "```yaml", yaml_body, "```", ""]
    if summary:
        parts.append(summary)
        parts.append("")
    if rationale:
        parts.append("_Rationale:_ " + rationale)
        parts.append("")
    return "\n".join(parts)


def render_project_section(blocks):
    lines = ["## Project candidates", ""]
    if not blocks:
        lines.append(
            "_No project candidates emerged from this corpus. The unclassified "
            "pile and non-project dispositions below carry every ingested item._"
        )
        lines.append("")
        return "\n".join(lines)
    lines.append(
        "Each project becomes a folder under `Engagements/` with a "
        "PRD/Context/Updates triad scaffolded at Stage 3. Edit any "
        "field in the `yaml` block to refine before approval."
    )
    lines.append("")
    for block in blocks:
        lines.append(render_candidate_block(block, level_h=3))
    return "\n".join(lines)


def render_routing_table(rows):
    lines = ["## Per-source-item routing", ""]
    if not rows:
        lines.append("_No items to route._")
        lines.append("")
        return "\n".join(lines)
    lines.append(
        "One row per source item. Edit `Destination` or `Candidate` to "
        "re-route a single item without changing the whole candidate. "
        "Rows flagged ⚠️ are low-confidence."
    )
    lines.append("")
    lines.append("| # | Source path | Candidate | Destination | Type | Confidence | Flag |")
    lines.append("|---|---|---|---|---|---|---|")
    for idx, row in enumerate(rows, start=1):
        flag = "⚠️" if row.get("low_confidence") else ""
        conf = "%.2f" % row.get("confidence", 0.0)
        lines.append("| %d | `%s` | `%s` | `%s` | %s | %s | %s |" % (
            idx,
            row["source_path"],
            row["candidate_id"],
            row["destination"],
            row["type"],
            conf,
            flag,
        ))
    lines.append("")
    return "\n".join(lines)


def render_non_project_section(blocks):
    lines = ["## Doesn’t fit any project — disposition", ""]
    if not blocks:
        lines.append(
            "_Every item in this corpus mapped to a project candidate — no "
            "reference, meeting, or unclassified dispositions to review._"
        )
        lines.append("")
        return "\n".join(lines)
    lines.append(
        "These candidates are NOT scaffolded as `Engagements/` projects. "
        "Each routes to its declared `proposed_path` instead — a reference "
        "doc folder, a meeting note folder, or `Inbox/` for the "
        "unclassified pile. Edit `type` to promote a candidate into a "
        "project (it will move to **Project candidates** when you re-run "
        "the review gate)."
    )
    lines.append("")
    for block in blocks:
        lines.append(render_candidate_block(block, level_h=3))
    return "\n".join(lines)


def render_refinements(refinements):
    lines = ["## Refinements (pass-2 merge/split)", ""]
    if not refinements:
        lines.append("_No refinement operations surfaced in pass-2._")
        lines.append("")
        return "\n".join(lines)
    lines.append(
        "Operations the LLM flagged during pass-2 (or pass-3) review of "
        "outliers. NOT auto-applied — you decide whether to accept each "
        "one at the review gate. `from` / `into` may be a single id "
        "(string) or a list of ids (array); both shapes round-trip."
    )
    lines.append("")
    lines.append("```yaml")
    lines.append(yaml_dump(refinements, indent=0).rstrip("\n"))
    lines.append("```")
    lines.append("")
    return "\n".join(lines)


def render_intro(unclassified_present):
    lines = [
        "# Import plan — review and edit",
        "",
        "This plan proposes how your seeded content maps onto a vault. "
        "Nothing is written yet — this file is the **single review surface** "
        "where you accept, edit, or reject the proposal before Stage 3 "
        "scaffolds the vault.",
        "",
        "**To approve as-is:** run the review gate (`review-gate.sh`) "
        "with no edits.",
        "**To edit:** open this file in your editor, change the YAML blocks "
        "and the routing table inline, save, then re-run the review gate "
        "— your edits "
        "are what Stage 3 consumes.",
        "**To abort:** exit the gate without applying. No vault writes occur.",
        "",
    ]
    if unclassified_present:
        lines.append(
            "_The call-out at the very top flags items that did not "
            "cluster — please scroll to **Doesn’t fit any project** below "
            "to triage them before approval._"
        )
        lines.append("")
    return "\n".join(lines)


def render_markdown(wrapper):
    parts = [
        render_frontmatter(wrapper),
        "",
        render_top_callout(wrapper["unclassified_callout"]),
        "",
        render_intro(wrapper["unclassified_callout"]["present"]),
        render_corpus_stats(wrapper["header"]),
        render_vault_tree(wrapper["vault_tree"]),
        render_project_section(wrapper["project_metadata_blocks"]),
        render_routing_table(wrapper["routing_table"]),
        render_non_project_section(wrapper["non_project_dispositions"]),
        render_refinements(wrapper["refinements"]),
    ]
    return "\n".join(p for p in parts if p is not None)


def main():
    ap = argparse.ArgumentParser(
        description="SP13 T-6 import-plan.py — render user-reviewable "
                    "import-plan.md from T-5 propose-taxonomy output"
    )
    ap.add_argument("--propose-taxonomy", required=True,
                    help="Path to T-5 propose-taxonomy-output.json (sp13-t5/1)")
    ap.add_argument("--out", required=True,
                    help="Output path for import-plan.md")
    ap.add_argument("--generated-at", default=None,
                    help="Override timestamp (ISO-8601 UTC). Default: now.")
    args = ap.parse_args()

    if not os.path.isfile(args.propose_taxonomy):
        print("import-plan.py: propose-taxonomy input not found: %s"
              % args.propose_taxonomy, file=sys.stderr)
        return 2

    propose_data = load_propose_taxonomy(args.propose_taxonomy)

    generated_at = args.generated_at or (
        datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    )

    wrapper = build_wrapper(propose_data, generated_at)

    rt_count = len(wrapper["routing_table"])
    n_records = wrapper["header"]["n_records"]
    if rt_count != n_records:
        print(
            "import-plan.py: routing_table row count %d != header.n_records %d "
            "— upstream candidates do not cover every IR record"
            % (rt_count, n_records),
            file=sys.stderr,
        )
        return 1

    md = render_markdown(wrapper)
    if not md.strip():
        print("import-plan.py: rendered markdown is empty", file=sys.stderr)
        return 1

    out_dir = os.path.dirname(os.path.abspath(args.out))
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
