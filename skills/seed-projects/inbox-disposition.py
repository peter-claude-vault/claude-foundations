#!/usr/bin/env python3
"""
inbox-disposition.py — SP13 T-10 Stage 3 GENERATE-WITH-GATE: route non-project
candidates from a user-approved import plan to vault Inbox/.

Consumes the same approved-import-plan.md (import-plan/1) that T-8 (seed.py)
consumes; walks the "## Doesn’t fit any project — disposition" H2 section
via the shared h3_walker module; for each non-project candidate (type in
{reference, meeting, unclassified}) iterates its source_items and stages
one date-stamped Inbox file per source item under
$STAGE_DIR/seed-projects/Inbox/.

Each staged Inbox file carries:
  - SP12 provenance frontmatter (via shell-out to lib/provenance-frontmatter.sh::pf_emit)
  - disposition: <type>          (reference / meeting / unclassified)
  - source_path                  (echoed from candidate source_items[].path)
  - source_hash                  (echoed from candidate source_items[].source_hash)
  - title                        (derived from source basename)
  - candidate_id, label          (provenance back-ref to taxonomy)
  - tags:                        single tag matching the disposition
                                 (#reference / #meeting / #unclassified)
  - body: source-file content if readable at staging time; otherwise a
    structured pointer-only placeholder with basename + hash (T-12
    standing inbox processor will pick up classification from the
    pointer fields).

The bash wrapper (inbox-disposition.sh, called from seed.sh) consumes the
manifest emitted on stdout to extend seed.sh's existing batched-gate
flow — Inbox writes surface in the SAME single user-review preview as
project triads (per spec L335).

Stdlib only — no pyyaml / requests / numpy.

R-43 Output Contract:
  - Files written: N staged files (one per source_item across all
    non-project candidates) under $STAGE_DIR/seed-projects/Inbox/;
    manifest JSON to stdout.
  - Schema-types: input is import-plan/1; output staged files carry SP12
    provenance frontmatter (validated by pf_validate post-stage).
  - Pre-write validation: schema_version anchor on input;
    h3_walker enforces every candidate has the 8 required fields;
    type filter rejects project candidates with stderr WARN.
  - Failure mode: BLOCK AND LOG. Missing input → exit 2. Schema
    mismatch → exit 2. Malformed candidate block → exit 2 with
    stderr pointing at the H3 line offset. No files staged on
    partial parse.

Author: Claude Opus 4.7 — Plan 71 SP13 Session 8 (T-10).
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys

# Shared H3 walker promoted at T-10 per T-8 Decision 7 carry-forward.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from h3_walker import walk_h3_section  # noqa: E402


NON_PROJECT_TYPES = ("reference", "meeting", "unclassified")
NON_PROJECT_SECTION_PATTERN = (
    r"^## Doesn’t fit any project — disposition\s*$"
)


def err(msg):
    sys.stderr.write("inbox-disposition.py: %s\n" % msg)


# ---------------------------------------------------------------------------
# Filename slug
# ---------------------------------------------------------------------------

_SLUG_RE = re.compile(r"[^a-z0-9]+")


def slugify(name):
    """Lowercase + collapse non-alphanumerics to single hyphens; trim."""
    s = name.lower().strip()
    s = _SLUG_RE.sub("-", s)
    s = s.strip("-")
    return s or "untitled"


def filename_for(date_stamp, source_path, suffix=None):
    """Compose <date>-<slug-of-basename>.md (with optional -<suffix>)."""
    base = os.path.basename(source_path) if source_path else ""
    # Strip extension for slug purposes (we always emit .md regardless of
    # source extension — Inbox files are markdown notes, not raw assets).
    stem, _ = os.path.splitext(base)
    slug = slugify(stem) if stem else "untitled"
    if suffix is not None:
        return "%s-%s-%s.md" % (date_stamp, slug, suffix)
    return "%s-%s.md" % (date_stamp, slug)


# ---------------------------------------------------------------------------
# Body sourcing
# ---------------------------------------------------------------------------

# Cap source-file inlining at a reasonable size so a stray multi-MB log file
# doesn't blow up an Inbox note. T-12 will re-walk the source if needed.
SOURCE_INLINE_BYTE_CAP = 256 * 1024


def read_source_body(source_path):
    """Return (body_text, sourced) where sourced is True iff we successfully
    read the source file as text. On any failure (missing file, binary,
    too large, decode error) returns a structured placeholder + False."""
    if not source_path:
        return ("_(no source path recorded)_", False)
    if not os.path.isfile(source_path):
        return (
            "_(source file not accessible at staging time: `%s`)_" % source_path,
            False,
        )
    try:
        size = os.path.getsize(source_path)
    except OSError:
        size = -1
    if size > SOURCE_INLINE_BYTE_CAP:
        return (
            "_(source file too large to inline at staging time: %d bytes; "
            "T-12 inbox-processor will re-walk and classify)_" % size,
            False,
        )
    try:
        with open(source_path, "r", encoding="utf-8") as fh:
            return (fh.read(), True)
    except (OSError, UnicodeDecodeError):
        return (
            "_(source file not text-readable at staging time: `%s`)_"
            % source_path,
            False,
        )


# ---------------------------------------------------------------------------
# Provenance frontmatter (shell-out to pf_emit per file)
# ---------------------------------------------------------------------------

def render_provenance_frontmatter(pf_lib, surface_id, generated_from):
    """Shell out to lib/provenance-frontmatter.sh::pf_emit. Returns the
    fenced YAML block as text without trailing newline."""
    cmd = [
        "bash", "-c",
        ". %s && pf_emit %s %s"
        % (_shquote(pf_lib), _shquote(surface_id),
           _shquote(generated_from)),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        err("pf_emit failed for surface %s / from %s: %s"
            % (surface_id, generated_from, proc.stderr.strip()))
        sys.exit(2)
    return proc.stdout.rstrip("\n")


def _shquote(s):
    return "'" + s.replace("'", "'\"'\"'") + "'"


# ---------------------------------------------------------------------------
# Per-item Inbox file rendering
# ---------------------------------------------------------------------------

def yaml_quote(s):
    """Defensive double-quoting for YAML scalar safety. Same posture as
    T-6's import-plan.py emitter — strings starting with a digit, a
    reserved leading char, or containing reserved YAML words get
    double-quoted."""
    if s is None:
        return '""'
    s = str(s)
    if s == "":
        return '""'
    # Always quote — Inbox-disposition.py emits bounded scalars, never
    # multi-line; double-quoting is universally safe and avoids the
    # YAML-1.1 implicit-timestamp + reserved-word footguns.
    escaped = s.replace("\\", "\\\\").replace('"', '\\"')
    return '"' + escaped + '"'


def render_inbox_file(stage_path, candidate, source_item, pf_lib,
                      generated_at, audience):
    """Render one Inbox file at stage_path. Returns dict of metadata."""
    cand_id = candidate.get("candidate_id", "unknown")
    cand_label = candidate.get("label", "")
    cand_type = candidate.get("type", "unclassified")
    source_path = source_item.get("path", "") if isinstance(source_item, dict) else ""
    source_hash = source_item.get("source_hash", "") if isinstance(source_item, dict) else ""

    # Provenance frontmatter (SP12 contract — three required fields wrapped
    # in '---' fences). Strip the trailing '---' so we can append our own
    # disposition fields between provenance and the closing fence.
    surface_id = "inbox-disposition@v2.0.0"
    generated_from = "%s/%s" % (cand_id, cand_label or cand_type)
    pf_block = render_provenance_frontmatter(pf_lib, surface_id, generated_from)
    pf_lines = pf_block.splitlines()
    if not pf_lines or pf_lines[0].strip() != "---" or pf_lines[-1].strip() != "---":
        err("pf_emit returned malformed block (no fenced wrapper)")
        sys.exit(2)
    pf_inner_lines = pf_lines[:-1]  # keep opening '---' + provenance fields

    # Title from source basename (stem); fallback to candidate_id.
    base = os.path.basename(source_path) if source_path else ""
    stem = os.path.splitext(base)[0] if base else ""
    title = stem if stem else cand_id

    # Tag is single — exactly one #<type> per Inbox file. Anchored to the
    # candidate's type, NOT a heuristic over the body content.
    tag = "#" + cand_type

    # Body sourcing.
    body_text, sourced = read_source_body(source_path)

    # Compose disposition fields in YAML-safe form.
    disposition_lines = [
        "type: %s" % yaml_quote("inbox-note"),
        "disposition: %s" % yaml_quote(cand_type),
        "title: %s" % yaml_quote(title),
        "audience: %s" % yaml_quote(audience),
        "candidate_id: %s" % yaml_quote(cand_id),
        "candidate_label: %s" % yaml_quote(cand_label),
        "source_path: %s" % yaml_quote(source_path),
        "source_hash: %s" % yaml_quote(source_hash),
        "source_inlined: %s" % ("true" if sourced else "false"),
        "created: %s" % yaml_quote(generated_at),
        "tags:",
        "  - %s" % yaml_quote(tag),
    ]

    # Compose final file: provenance frontmatter (open + fields, no close)
    # + disposition fields + closing '---' + body.
    parts = []
    parts.extend(pf_inner_lines)
    parts.extend(disposition_lines)
    parts.append("---")
    parts.append("")
    if body_text:
        parts.append("# " + (title or "Inbox note"))
        parts.append("")
        parts.append(body_text.rstrip("\n"))
    else:
        parts.append("# " + (title or "Inbox note"))
        parts.append("")
        parts.append("_(empty source body)_")
    parts.append("")
    rendered = "\n".join(parts)

    with open(stage_path, "w", encoding="utf-8") as ofh:
        ofh.write(rendered)

    return {
        "candidate_id": cand_id,
        "label": cand_label,
        "type": cand_type,
        "source_path": source_path,
        "source_hash": source_hash,
        "tag": tag,
        "title": title,
        "source_inlined": sourced,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="SP13 T-10 inbox-disposition.py — stage Inbox files "
                    "from non-project candidates in an approved import plan",
    )
    ap.add_argument("--approved-plan", required=True,
                    help="Path to T-7 approved-import-plan.md (import-plan/1).")
    ap.add_argument("--vault-root", required=True,
                    help="Vault root path (Inbox files target <vault>/Inbox/).")
    ap.add_argument("--stage-dir", required=True,
                    help="Staging dir; Inbox files land at "
                         "<stage-dir>/seed-projects/Inbox/.")
    ap.add_argument("--pf-lib", required=True,
                    help="Path to lib/provenance-frontmatter.sh (SP12 T-2).")
    ap.add_argument("--audience", default="self",
                    help="Default audience for generated frontmatter.")
    ap.add_argument("--generated-at", default=None,
                    help="Override timestamp (ISO-8601 UTC). Default: now.")
    args = ap.parse_args()

    generated_at = args.generated_at or (
        datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    )
    # Date stamp for filename: derive from generated_at to keep tests
    # reproducible when the env override is set.
    date_stamp = generated_at.split("T")[0]

    # Walk the non-project section. h3_walker logs WARN + skips any
    # type=project that snuck in via T-7 user edit.
    candidates = walk_h3_section(
        plan_path=args.approved_plan,
        section_pattern=NON_PROJECT_SECTION_PATTERN,
        allowed_types=NON_PROJECT_TYPES,
    )

    # Stage root: $stage_dir/seed-projects/Inbox/.
    # Use the same parent staging tree T-8 (seed.py) populates so the
    # explainer (T-9) and gate preview (seed.sh) see one unified tree.
    parent_stage = os.path.join(args.stage_dir, "seed-projects")
    inbox_stage = os.path.join(parent_stage, "Inbox")
    os.makedirs(inbox_stage, exist_ok=True)

    # Idempotent clean: remove any prior Inbox stage contents (do NOT touch
    # sibling project triads — those are seed.py's territory).
    for entry in os.listdir(inbox_stage):
        p = os.path.join(inbox_stage, entry)
        try:
            if os.path.isfile(p):
                os.remove(p)
        except OSError:
            pass

    manifest_writes = []
    seen_filenames = {}  # base -> count, for collision suffixing
    for cand in candidates:
        cand_type = cand.get("type")
        if cand_type not in NON_PROJECT_TYPES:
            # h3_walker WARN-skipped type=project upstream; defensive
            # double-check here for any other unexpected enum.
            err("WARN: skipping candidate %r with unexpected type=%r"
                % (cand.get("candidate_id"), cand_type))
            continue

        source_items = cand.get("source_items") or []
        if not source_items:
            # Candidate carries no source_items (e.g., empty unclassified
            # pile). Synthesize ONE placeholder Inbox note keyed off the
            # candidate label — the user surfaced this candidate
            # explicitly at T-7, so dropping it would be silent loss.
            source_items = [{
                "path": "",
                "source_hash": "",
            }]

        for source_item in source_items:
            source_path = source_item.get("path", "") if isinstance(
                source_item, dict) else ""
            base_filename = filename_for(date_stamp, source_path or cand.get("label", ""))
            # Collision suffix: <date>-<slug>.md → <date>-<slug>-1.md, -2.md, ...
            if base_filename in seen_filenames:
                seen_filenames[base_filename] += 1
                final_filename = filename_for(
                    date_stamp,
                    source_path or cand.get("label", ""),
                    suffix=str(seen_filenames[base_filename]),
                )
            else:
                seen_filenames[base_filename] = 0
                final_filename = base_filename

            stage_path = os.path.join(inbox_stage, final_filename)
            target_path = os.path.join(args.vault_root, "Inbox", final_filename)

            meta = render_inbox_file(
                stage_path=stage_path,
                candidate=cand,
                source_item=source_item,
                pf_lib=args.pf_lib,
                generated_at=generated_at,
                audience=args.audience,
            )
            manifest_writes.append({
                "staging": stage_path,
                "target": target_path,
                "candidate_id": meta["candidate_id"],
                "label": meta["label"],
                "kind": "Inbox",
                "type": meta["type"],
                "tag": meta["tag"],
                "source_path": meta["source_path"],
                "source_hash": meta["source_hash"],
                "source_inlined": meta["source_inlined"],
            })

    manifest = {
        "schema_version": "inbox-disposition/1",
        "surface_id": "inbox-disposition",
        "approved_plan_input": args.approved_plan,
        "vault_root": args.vault_root,
        "stage_root": parent_stage,
        "inbox_stage_root": inbox_stage,
        "generated_at": generated_at,
        "non_project_candidates_count": len(candidates),
        "writes": manifest_writes,
    }
    sys.stdout.write(json.dumps(manifest, indent=2, ensure_ascii=False))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
