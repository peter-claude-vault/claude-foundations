#!/usr/bin/env python3
"""
retrofit-collision-matrix.py — SP13 T-13 collision matrix renderer.

Consumes a retrofit-matrix.json (retrofit-matrix/1; produced by retrofit-prefilter.py)
plus a target import-plan.md (import-plan/1; produced by import-plan.sh) and
APPENDS a `## Collision matrix` section to the import-plan.md.

The append is additive — the existing T-6 schema_version anchor
(`schema_version: import-plan/1` in YAML frontmatter) is preserved unchanged so
review-gate.sh's pre-flight schema-version grep still passes.

Pagination contract (Refinement #4 from design review): when matrix has
> ROWS_PER_PAGE rows, render with H3 sub-headings:

    ## Collision matrix — N existing files
    ### Page 1 of K — rows 1..50
    | # | existing_path | proposed_action | target | candidate_id | confidence |
    |---|---|---|---|---|---|
    ... 50 rows ...

    ### Page 2 of K — rows 51..100
    ...

The H2 ## Collision matrix heading lands AFTER the existing
"## Doesn't fit any project — disposition" H2 (or after "## Routing table"
if no disposition section), preserving the markdown structure T-6 emits.

Stdlib only — no pyyaml / requests.

R-43 Output Contract:
  - Files written: import-plan.md is overwritten in place via tmp+rename.
  - Schema-types: input matrix is retrofit-matrix/1; input/output plan is import-plan/1.
  - Pre-write validation: schema_version anchors on both inputs; matrix
    schema_version anchor; appended section does not remove existing content.
  - Failure mode: BLOCK AND LOG. Bad input → exit 2. No partial writes.

Author: Claude Opus 4.7 — Plan 71 SP13 Session 11 (T-13).
"""

import argparse
import json
import os
import sys


SCHEMA_VERSION_MATRIX_INPUT = "retrofit-matrix/1"
SCHEMA_VERSION_PLAN_INPUT = "import-plan/1"
ROWS_PER_PAGE = 50


def err(msg):
    sys.stderr.write("retrofit-collision-matrix.py: %s\n" % msg)


def md_escape_cell(s):
    """Escape pipe chars (markdown table cell separator) and collapse newlines."""
    if s is None:
        return ""
    s = str(s).replace("|", "\\|").replace("\n", " ").replace("\r", " ")
    return s


def render_matrix_page(rows, page_num, total_pages, start_idx, end_idx):
    """Render one page of the matrix as a markdown table.

    rows: full list of matrix rows.
    start_idx, end_idx: half-open Python slice [start, end).
    """
    lines = []
    if total_pages > 1:
        lines.append("### Page %d of %d — rows %d..%d" % (
            page_num, total_pages, start_idx + 1, end_idx,
        ))
    lines.append("")
    lines.append("| # | existing_path | proposed_action | target | candidate_id | confidence |")
    lines.append("|---|---|---|---|---|---|")
    for i in range(start_idx, end_idx):
        row = rows[i]
        cells = [
            str(i + 1),
            md_escape_cell(row.get("existing_path", "")),
            md_escape_cell(row.get("proposed_action", "")),
            md_escape_cell(row.get("target", "")),
            md_escape_cell(row.get("candidate_id", "")),
            "%.2f" % float(row.get("confidence", 0.0) or 0.0),
        ]
        lines.append("| " + " | ".join(cells) + " |")
    lines.append("")
    return "\n".join(lines)


def render_matrix_legend(matrix):
    """Render an action-legend block + summary stats. Surfaces the action enum
    so the user can read the matrix without flipping to docs."""
    lines = []
    lines.append("> **Action legend:**")
    lines.append("> - `scaffold` — Stage 3 will create a new project folder + PRD/Context/Updates triad.")
    lines.append("> - `keep` — file already lives in a coherent location; no-op (advisory).")
    lines.append("> - `move-to` — items scatter; advisory move target shown. **Manual move required** (auto-move deferred to v2.x).")
    lines.append("> - `inbox` — Stage 3 will route to `<vault>/Inbox/` via inbox-disposition.sh.")
    lines.append("> - `review` — low-confidence cluster (<0.5) OR unknown disposition; user must triage at the gate.")
    lines.append("> - `idempotency-skip` — file carries `generated_by: retrofit@*` from a prior run; not re-walked.")
    lines.append("")
    lines.append("**Summary:**")
    n_total = matrix.get("n_ir_records", 0)
    n_skipped = matrix.get("n_idempotency_skipped", 0)
    n_dropped = matrix.get("n_candidates_dropped_already_scaffolded", 0)
    lines.append("- IR records walked: %d" % n_total)
    lines.append("- Idempotency-skipped (already retrofitted): %d" % n_skipped)
    lines.append("- Already-scaffolded candidates dropped from Stage 3: %d" % n_dropped)
    lines.append("- Keep-threshold for reference/meeting: %.2f" % matrix.get("keep_threshold", 0.0))
    lines.append("")

    # Action count breakdown.
    rows = matrix.get("matrix_rows", []) or []
    action_counts = {}
    for r in rows:
        a = r.get("proposed_action", "review")
        action_counts[a] = action_counts.get(a, 0) + 1
    if action_counts:
        lines.append("**Action breakdown:**")
        for action in sorted(action_counts.keys()):
            lines.append("- `%s`: %d" % (action, action_counts[action]))
        lines.append("")
    return "\n".join(lines)


def find_insertion_point(plan_text):
    """Find the byte offset to insert the collision matrix section.

    Insert AFTER the last existing H2 section so the matrix lands at end of
    body. Returns (insertion_offset, trailing_newlines_count) — the caller
    splices: plan_text[:offset] + matrix_section + plan_text[offset:].

    Strategy: find the last '\n## ' occurrence; from there walk to the
    next '\n## ' (start of next H2 — there shouldn't be one) or EOF.
    Matrix lands at EOF in practice.
    """
    # Find all H2 starts. H2 = '\n## ' (or start-of-file '## '), stripped of
    # any leading anchor (SP15 might insert before the body — but the H2s
    # we want to land after are post-frontmatter).
    if not plan_text.endswith("\n"):
        plan_text += "\n"
    # Insert at end of file. Append cleanly.
    return (len(plan_text), plan_text)


def render_collision_section(matrix):
    """Render the full `## Collision matrix` section (H2 + legend + paginated tables)."""
    rows = matrix.get("matrix_rows", []) or []
    n = len(rows)
    parts = []
    parts.append("## Collision matrix — %d existing files" % n)
    parts.append("")
    parts.append(render_matrix_legend(matrix))

    if n == 0:
        parts.append("_(empty matrix — no IR records walked)_")
        parts.append("")
        return "\n".join(parts)

    total_pages = (n + ROWS_PER_PAGE - 1) // ROWS_PER_PAGE
    for page_num in range(1, total_pages + 1):
        start_idx = (page_num - 1) * ROWS_PER_PAGE
        end_idx = min(start_idx + ROWS_PER_PAGE, n)
        parts.append(render_matrix_page(rows, page_num, total_pages,
                                        start_idx, end_idx))
        parts.append("")  # blank line between pages

    return "\n".join(parts)


def main():
    ap = argparse.ArgumentParser(
        description="SP13 T-13 retrofit collision matrix renderer.",
    )
    ap.add_argument("--matrix", required=True,
                    help="Path to retrofit-matrix.json (retrofit-matrix/1).")
    ap.add_argument("--import-plan", required=True,
                    help="Path to import-plan.md (import-plan/1; appended in place).")
    args = ap.parse_args()

    if not os.path.isfile(args.matrix):
        err("matrix not found: %s" % args.matrix)
        sys.exit(2)
    if not os.path.isfile(args.import_plan):
        err("import-plan not found: %s" % args.import_plan)
        sys.exit(2)

    matrix = json.load(open(args.matrix, "r", encoding="utf-8"))
    sv = matrix.get("schema_version")
    if sv != SCHEMA_VERSION_MATRIX_INPUT:
        err("matrix schema_version mismatch: expected %r, got %r"
            % (SCHEMA_VERSION_MATRIX_INPUT, sv))
        sys.exit(2)

    with open(args.import_plan, "r", encoding="utf-8") as fh:
        plan_text = fh.read()

    # Validate the plan carries the import-plan/1 anchor in YAML frontmatter.
    # Permissive grep — match any line "schema_version: import-plan/1" anywhere
    # in the first 50 lines (frontmatter region).
    head = "\n".join(plan_text.splitlines()[:50])
    if SCHEMA_VERSION_PLAN_INPUT not in head:
        err("import-plan does not carry expected schema_version %r in head"
            % SCHEMA_VERSION_PLAN_INPUT)
        sys.exit(2)

    # Reject double-append: if `## Collision matrix` already present, fail
    # rather than append again. retrofit.sh is responsible for re-running
    # cleanly (idempotency by overwriting the input plan from import-plan.sh
    # before calling this renderer).
    if "\n## Collision matrix" in plan_text or plan_text.startswith("## Collision matrix"):
        err("import-plan already contains a Collision matrix section; "
            "refuse to double-append")
        sys.exit(2)

    matrix_section = render_collision_section(matrix)

    # Append matrix to plan text (with separator).
    if not plan_text.endswith("\n"):
        plan_text += "\n"
    augmented = plan_text + "\n" + matrix_section
    if not augmented.endswith("\n"):
        augmented += "\n"

    tmp = args.import_plan + ".retrofit.tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(augmented)
    os.rename(tmp, args.import_plan)

    n_rows = len(matrix.get("matrix_rows", []) or [])
    n_pages = (n_rows + ROWS_PER_PAGE - 1) // ROWS_PER_PAGE if n_rows else 0
    sys.stderr.write(
        "retrofit-collision-matrix.py: appended matrix (%d rows, %d page%s) "
        "to %s\n" % (n_rows, n_pages, "" if n_pages == 1 else "s",
                     args.import_plan)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
