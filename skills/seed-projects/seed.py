#!/usr/bin/env python3
"""
seed.py — SP13 T-8 Stage 3 GENERATE-WITH-GATE: stage PRD/Context/Updates triads.

Consumes a T-7 user-approved import plan (state/approved-import-plan.md;
schema_version: sp13-t6/1) and stages a tree of project-folder triads under
$STAGE_DIR/seed-projects/<project-label>/{PRD.md, Context.md, Updates.md}.

The bash wrapper (seed.sh) then:
  1. shows a single batched preview against any pre-existing target files,
  2. prompts the user [a/e/s/b] ONCE,
  3. on apply: walks the staged tree and atomically cp+mv each file into
     the vault.

Output side: seed.py emits a manifest JSON on stdout enumerating every
staged file + its target path; the wrapper consumes the manifest to
drive the apply step.

Stdlib only — no pyyaml / jinja2 / requests / numpy / pydantic.

R-23 not relevant (Python). R-43 Output Contract:
  - Files written: 15 staged files (5 projects × {PRD/Context/Updates})
    under --stage-dir; manifest JSON to stdout.
  - Schema-types: input is sp13-t6/1; output staged files carry SP12
    provenance frontmatter (validated by pf_validate post-stage).
  - Pre-write validation: schema_version anchor on input;
    every parsed candidate carries the 8 required fields per
    schemas/import-plan-schema.json#/definitions/candidate_block.
  - Failure mode: BLOCK AND LOG. Missing input → exit 2. Schema
    mismatch → exit 2. Malformed candidate block → exit 2 with stderr
    pointing at the H3 line number. No files staged on partial parse.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys

# H3 walker promoted to shared lib at SP13 T-10 (Session 8) per T-8
# Decision 7 + T-9 close-out carry-forward. Both seed.py and T-10's
# inbox-disposition.py import from this module; the YAML parser, frontmatter
# splitter, schema-version validation, and section walker live in one place.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from h3_walker import (  # noqa: E402
    SCHEMA_VERSION_EXPECTED,
    walk_h3_section,
)


TEMPLATE_NAMES = ("PRD", "Context", "Updates")
TEMPLATE_FILENAMES = {
    "PRD": "PRD.md",
    "Context": "Context.md",
    "Updates": "Updates.md",
}


def err(msg):
    sys.stderr.write("seed.py: %s\n" % msg)


def parse_approved_plan(path):
    """
    Walk the approved-import-plan.md and return a list of project candidate
    dicts (type == "project" only — non-project handling is T-10's territory).

    Thin wrapper around `h3_walker.walk_h3_section` pinned to the
    "## Project candidates" section + project type filter. Maintains
    parity with the pre-T-10 contract (same signature, same return shape,
    same exit-2-on-parse-error semantics) so seed.py call sites are
    unchanged after the H3 walker promotion.
    """
    return walk_h3_section(
        plan_path=path,
        section_pattern=r"^## Project candidates\s*$",
        allowed_types=("project",),
    )


# ---------------------------------------------------------------------------
# Template rendering
# ---------------------------------------------------------------------------

def render_provenance_frontmatter(pf_emit_bin, surface_id, generated_from):
    """Shell out to lib/provenance-frontmatter.sh::pf_emit. Returns the
    fenced YAML block as bytes-ish text (without trailing newline)."""
    cmd = [
        "bash", "-c",
        ". %s && pf_emit %s %s"
        % (_shquote(pf_emit_bin), _shquote(surface_id),
           _shquote(generated_from)),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        err("pf_emit failed for surface %s / from %s: %s"
            % (surface_id, generated_from, proc.stderr.strip()))
        sys.exit(2)
    return proc.stdout.rstrip("\n")


def _shquote(s):
    """Single-quote a shell argument for bash -c."""
    return "'" + s.replace("'", "'\"'\"'") + "'"


PLACEHOLDER_RE = re.compile(r"\{\{\s*([A-Za-z0-9_.]+)\s*\}\}")


def render_template(template_text, substitutions):
    """Mustache-style {{var}} substitution; supports nested `{{a.b.c}}` via
    dotted lookup against `substitutions` mapping. Unresolved tokens are
    replaced with `_unresolved:<token>_` (visible to the user; do NOT
    silently drop)."""
    def _sub(m):
        key = m.group(1)
        try:
            value = _walk_dotted(substitutions, key)
        except KeyError:
            return "_unresolved:%s_" % key
        if isinstance(value, str):
            return value
        if value is None:
            return ""
        if isinstance(value, (int, float, bool)):
            return str(value)
        # list / dict left over — render as JSON one-liner; caller should
        # have provided a stringified version.
        return json.dumps(value, ensure_ascii=False)
    return PLACEHOLDER_RE.sub(_sub, template_text)


def _walk_dotted(d, key):
    parts = key.split(".")
    cur = d
    for p in parts:
        if isinstance(cur, dict) and p in cur:
            cur = cur[p]
        else:
            raise KeyError(key)
    return cur


def build_substitutions(candidate, generated_at, audience):
    """Compose the {{var}} namespace for one candidate's templates."""
    label = candidate.get("label", "")
    metadata = candidate.get("metadata") or {}
    source_items = candidate.get("source_items") or []
    n_sources = len(source_items)

    # Tags: emit a YAML list block ('  - "#tag"' lines under tags:).
    tags = metadata.get("tags") or []
    if not isinstance(tags, list):
        tags = []
    tags_lines = []
    for t in tags:
        # YAML-quote tags that start with '#' (reserved leading char).
        tags_lines.append('  - "%s"' % str(t))
    if not tags_lines:
        tags_lines.append('  - "#project"')
    tags_yaml_list = "\n".join(tags_lines)

    # Source-items bullet list.
    bullet_lines = []
    for it in source_items:
        path = (it or {}).get("path", "") if isinstance(it, dict) else ""
        bullet_lines.append("- `%s`" % path)
    if not bullet_lines:
        bullet_lines.append("- _(no source items)_")
    source_items_bullet_list = "\n".join(bullet_lines)

    # Source-items block (Context.md): bullet + indented source_hash.
    block_lines = []
    for it in source_items:
        if not isinstance(it, dict):
            continue
        path = it.get("path", "")
        source_hash = it.get("source_hash", "")
        block_lines.append("- `%s`" % path)
        if source_hash:
            block_lines.append(
                "  - source_hash: `%s`" % source_hash
            )
        block_lines.append(
            "  - _(content excerpt available in onboarding intake; this "
            "scaffolded note is the provenance pointer)_"
        )
    if not block_lines:
        block_lines.append("- _(no source items)_")
    source_items_block = "\n".join(block_lines)

    return {
        "candidate": {
            "label": label,
            "candidate_id": candidate.get("candidate_id", ""),
            "type": candidate.get("type", ""),
            "proposed_path": candidate.get("proposed_path", ""),
            "metadata": {
                "summary": metadata.get("summary", "_(no summary surfaced)_"),
                "rationale": metadata.get("rationale", "_(no rationale surfaced)_"),
                "engagement": metadata.get("engagement", ""),
            },
        },
        "tags_yaml_list": tags_yaml_list,
        "source_items_bullet_list": source_items_bullet_list,
        "source_items_block": source_items_block,
        "source_items_count": str(n_sources),
        "generated_at": generated_at,
        "generated_at_date": generated_at.split("T")[0],
        "audience": audience,
    }


def stage_one_candidate(
    candidate, stage_root, vault_root, templates_dir,
    pf_lib, generated_at, audience,
):
    """Render the 3 files for one candidate into the stage tree.
    Returns a list of {staging, target} dicts (3 entries)."""
    label = candidate.get("label", "")
    proposed = candidate.get("proposed_path", "") or ("Engagements/" + label)
    if proposed.startswith("/"):
        proposed = proposed.lstrip("/")
    target_dir = os.path.join(vault_root, proposed)
    stage_dir = os.path.join(stage_root, proposed)
    os.makedirs(stage_dir, exist_ok=True)

    surface_id = "seed-projects@v2.0.0"
    generated_from = candidate.get("candidate_id", "unknown") + "/" + label

    pf_block = render_provenance_frontmatter(pf_lib, surface_id, generated_from)

    # Templates carry a `{{provenance_frontmatter}}` token at the very top
    # that begins with the upper '---'; the template's literal '\n---\n'
    # closes the user-facing frontmatter (after the type-specific fields).
    # We emit pf_block as the upper-half of the frontmatter (it includes
    # both '---' fences); to splice cleanly we render the template with
    # provenance_frontmatter set to pf_block MINUS the trailing '---'
    # line, so the template's own type-specific fields land between
    # provenance fields and the closing fence.
    pf_lines = pf_block.splitlines()
    if not pf_lines or pf_lines[0].strip() != "---" or pf_lines[-1].strip() != "---":
        err("pf_emit returned malformed block (no fenced wrapper)")
        sys.exit(2)
    pf_inner = "\n".join(pf_lines[:-1])  # drop trailing '---' fence

    subs = build_substitutions(candidate, generated_at, audience)
    subs["provenance_frontmatter"] = pf_inner

    triad = []
    for tname in TEMPLATE_NAMES:
        tpath = os.path.join(templates_dir, "%s-template.md" % tname.lower())
        if not os.path.isfile(tpath):
            err("missing template: %s" % tpath)
            sys.exit(2)
        with open(tpath, "r", encoding="utf-8") as tfh:
            tpl = tfh.read()
        rendered = render_template(tpl, subs)
        out_name = TEMPLATE_FILENAMES[tname]
        out_stage = os.path.join(stage_dir, out_name)
        out_target = os.path.join(target_dir, out_name)
        with open(out_stage, "w", encoding="utf-8") as ofh:
            ofh.write(rendered)
        triad.append({
            "staging": out_stage,
            "target": out_target,
            "candidate_id": candidate.get("candidate_id", ""),
            "label": label,
            "kind": tname,
        })
    return triad


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="SP13 T-8 seed.py — stage PRD/Context/Updates triads "
                    "from an approved import plan",
    )
    ap.add_argument("--approved-plan", required=True,
                    help="Path to T-7 approved-import-plan.md (sp13-t6/1).")
    ap.add_argument("--vault-root", required=True,
                    help="Vault root path (project folders land under here).")
    ap.add_argument("--stage-dir", required=True,
                    help="Staging dir; project folders + triads land under here.")
    ap.add_argument("--templates-dir", required=True,
                    help="Foundation-repo templates/ dir holding "
                         "prd-template.md / context-template.md / "
                         "updates-template.md.")
    ap.add_argument("--pf-lib", required=True,
                    help="Path to lib/provenance-frontmatter.sh (SP12 T-2).")
    ap.add_argument("--audience", default="self",
                    help="Default audience for generated frontmatter.")
    ap.add_argument("--generated-at", default=None,
                    help="Override timestamp (ISO-8601 UTC). Default: now.")
    args = ap.parse_args()

    candidates = parse_approved_plan(args.approved_plan)

    generated_at = args.generated_at or (
        datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    )

    # Clean staging root: $stage_dir/seed-projects/.
    stage_root = os.path.join(args.stage_dir, "seed-projects")
    if os.path.isdir(stage_root):
        # Idempotent: rm -rf via os.walk to avoid pulling shutil's tree-only
        # surface area.
        for root, dirs, files in os.walk(stage_root, topdown=False):
            for f in files:
                try:
                    os.remove(os.path.join(root, f))
                except OSError:
                    pass
            for d in dirs:
                try:
                    os.rmdir(os.path.join(root, d))
                except OSError:
                    pass
    os.makedirs(stage_root, exist_ok=True)

    manifest_writes = []
    for cand in candidates:
        triad = stage_one_candidate(
            candidate=cand,
            stage_root=stage_root,
            vault_root=args.vault_root,
            templates_dir=args.templates_dir,
            pf_lib=args.pf_lib,
            generated_at=generated_at,
            audience=args.audience,
        )
        manifest_writes.extend(triad)

    manifest = {
        "schema_version": "sp13-t8/1",
        "surface_id": "seed-projects",
        "approved_plan_input": args.approved_plan,
        "vault_root": args.vault_root,
        "stage_root": stage_root,
        "templates_dir": args.templates_dir,
        "generated_at": generated_at,
        "candidates_count": len(candidates),
        "writes": manifest_writes,
    }
    sys.stdout.write(json.dumps(manifest, indent=2, ensure_ascii=False))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
