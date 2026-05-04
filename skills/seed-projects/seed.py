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


SCHEMA_VERSION_EXPECTED = "sp13-t6/1"
TEMPLATE_NAMES = ("PRD", "Context", "Updates")
TEMPLATE_FILENAMES = {
    "PRD": "PRD.md",
    "Context": "Context.md",
    "Updates": "Updates.md",
}


def err(msg):
    sys.stderr.write("seed.py: %s\n" % msg)


# ---------------------------------------------------------------------------
# Markdown / YAML parsing
# ---------------------------------------------------------------------------

def split_frontmatter(text):
    """Return (frontmatter_body, post_body) split on first two '---' lines."""
    lines = text.splitlines(keepends=False)
    if not lines or lines[0].rstrip() != "---":
        return None, text
    fm = []
    i = 1
    while i < len(lines):
        if lines[i].rstrip() == "---":
            return "\n".join(fm), "\n".join(lines[i + 1:])
        fm.append(lines[i])
        i += 1
    return None, text


def parse_yaml_block(text):
    """
    Minimal recursive YAML parser for the bounded shapes T-6 emits:
      - scalars (string, int, float, bool, null)
      - lists of scalars
      - lists of objects (- key: value\n  key: value)
      - nested mappings (block style, indented)

    No anchors, aliases, multi-document, or flow style. Quoted strings are
    unquoted; unquoted ints/floats/bools/null become their Python types.

    Returns the parsed structure (dict or list) on success; raises
    ValueError on malformed input.
    """
    raw_lines = text.splitlines()
    # Strip trailing empties for the parser; preserve internal blank lines.
    while raw_lines and raw_lines[-1].strip() == "":
        raw_lines.pop()
    pos = [0]
    return _parse_block(raw_lines, pos, indent=0)


def _line_indent(line):
    """Number of leading spaces (tabs not allowed; mixed-indent rejected)."""
    n = 0
    for ch in line:
        if ch == " ":
            n += 1
        elif ch == "\t":
            raise ValueError("seed.py YAML parser: tabs are not permitted in indentation")
        else:
            break
    return n


def _peek_nonblank(lines, pos):
    """Return next non-blank line index, or len(lines)."""
    i = pos[0]
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    return i


def _parse_block(lines, pos, indent):
    """Parse a block at the given indent level. Returns a dict or list."""
    i = _peek_nonblank(lines, pos)
    pos[0] = i
    if i >= len(lines):
        return None
    line = lines[i]
    line_indent = _line_indent(line)
    if line_indent < indent:
        return None
    stripped = line.strip()
    if stripped.startswith("- "):
        return _parse_list(lines, pos, indent)
    if stripped == "-":
        return _parse_list(lines, pos, indent)
    return _parse_mapping(lines, pos, indent)


def _parse_mapping(lines, pos, indent):
    out = {}
    while True:
        i = _peek_nonblank(lines, pos)
        pos[0] = i
        if i >= len(lines):
            break
        line = lines[i]
        line_indent = _line_indent(line)
        if line_indent < indent:
            break
        if line_indent != indent:
            raise ValueError(
                "seed.py YAML parser: unexpected indent on line %d: %r"
                % (i + 1, line)
            )
        stripped = line.strip()
        if stripped.startswith("- "):
            break
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_./@#-]*|\"[^\"]*\"|'[^']*')\s*:\s*(.*)$",
                     stripped)
        if not m:
            raise ValueError(
                "seed.py YAML parser: expected 'key: value' on line %d, got %r"
                % (i + 1, stripped)
            )
        key_raw, rest = m.group(1), m.group(2)
        key = _scalar(key_raw)
        pos[0] = i + 1
        if rest == "":
            # Block-style nested value follows.
            j = _peek_nonblank(lines, pos)
            if j >= len(lines):
                out[key] = None
                continue
            next_indent = _line_indent(lines[j])
            if next_indent <= indent:
                out[key] = None
                continue
            sub = _parse_block(lines, pos, indent=next_indent)
            out[key] = sub
        else:
            # Inline value.
            if rest in ("{}",):
                out[key] = {}
            elif rest in ("[]",):
                out[key] = []
            else:
                out[key] = _scalar(rest)
    return out


def _parse_list(lines, pos, indent):
    out = []
    while True:
        i = _peek_nonblank(lines, pos)
        pos[0] = i
        if i >= len(lines):
            break
        line = lines[i]
        line_indent = _line_indent(line)
        if line_indent < indent:
            break
        stripped = line.strip()
        if not (stripped == "-" or stripped.startswith("- ")):
            break
        if line_indent != indent:
            break
        rest = stripped[1:].lstrip()
        pos[0] = i + 1
        if rest == "":
            j = _peek_nonblank(lines, pos)
            if j >= len(lines):
                out.append(None)
                continue
            sub = _parse_block(lines, pos, indent=_line_indent(lines[j]))
            out.append(sub)
        elif ":" in rest and re.match(
            r"^([A-Za-z_][A-Za-z0-9_./@#-]*|\"[^\"]*\"|'[^']*')\s*:",
            rest,
        ):
            # Inline first key:value of a mapping list-item.
            # Reconstruct so the mapping parser sees `<indent+2>key: value`.
            synthetic = " " * (indent + 2) + rest
            tail = lines[i + 1:]
            new_lines = lines[:i + 1]
            new_lines.append(synthetic)
            new_lines.extend(tail)
            # Replace pos accordingly.
            lines.clear()
            lines.extend(new_lines)
            pos[0] = i + 1
            sub = _parse_mapping(lines, pos, indent=indent + 2)
            out.append(sub)
        else:
            out.append(_scalar(rest))
    return out


def _scalar(raw):
    """Parse a YAML scalar. Strip outer quotes; coerce numbers/bools/null."""
    s = raw.strip()
    if s == "null" or s == "~":
        return None
    if s == "true":
        return True
    if s == "false":
        return False
    if (s.startswith('"') and s.endswith('"')) or \
       (s.startswith("'") and s.endswith("'")):
        return s[1:-1]
    # Integer?
    try:
        return int(s)
    except ValueError:
        pass
    # Float?
    try:
        return float(s)
    except ValueError:
        pass
    return s


# ---------------------------------------------------------------------------
# Approved-plan walker
# ---------------------------------------------------------------------------

CANDIDATE_REQUIRED_FIELDS = (
    "candidate_id", "label", "type", "proposed_path",
    "metadata", "source_items", "confidence", "low_confidence",
)


def parse_approved_plan(path):
    """
    Walk the approved-import-plan.md and return a list of project candidate
    dicts (those with type == "project" only — non-project handling is
    T-10's territory).
    """
    if not os.path.isfile(path):
        err("approved plan not found: %s" % path)
        sys.exit(2)
    with open(path, "r", encoding="utf-8") as fh:
        content = fh.read()

    fm_text, body = split_frontmatter(content)
    if fm_text is None:
        err("approved plan has no YAML frontmatter: %s" % path)
        sys.exit(2)

    # Schema-version anchor check.
    if not re.search(r"^schema_version:\s*sp13-t6/1\s*$", fm_text, re.MULTILINE):
        err("approved plan schema_version mismatch (expected 'sp13-t6/1')")
        sys.exit(2)

    # Walk to '## Project candidates' section, then iterate H3 + ```yaml.
    section_re = re.compile(r"^## Project candidates\s*$", re.MULTILINE)
    next_h2_re = re.compile(r"^## (?!Project candidates)", re.MULTILINE)
    sec_match = section_re.search(body)
    if not sec_match:
        err("approved plan missing '## Project candidates' section")
        sys.exit(2)
    start = sec_match.end()
    next_match = next_h2_re.search(body, pos=start)
    end = next_match.start() if next_match else len(body)
    section = body[start:end]

    # Parse each H3 + inline ```yaml block.
    candidates = []
    h3_re = re.compile(r"^### .*?$", re.MULTILINE)
    h3_starts = [m.start() for m in h3_re.finditer(section)]
    if not h3_starts:
        # Empty-state: 0 project candidates is legal (empty fixture path).
        return []
    h3_starts.append(len(section))
    for k in range(len(h3_starts) - 1):
        block_text = section[h3_starts[k]:h3_starts[k + 1]]
        yaml_match = re.search(
            r"```yaml\s*\n(.*?)\n```",
            block_text,
            re.DOTALL,
        )
        if not yaml_match:
            err("project H3 missing inline ```yaml block at section offset %d"
                % h3_starts[k])
            sys.exit(2)
        try:
            cand = parse_yaml_block(yaml_match.group(1))
        except ValueError as e:
            err("YAML parse error in project block at offset %d: %s"
                % (h3_starts[k], e))
            sys.exit(2)
        if not isinstance(cand, dict):
            err("project block did not parse to a mapping at offset %d"
                % h3_starts[k])
            sys.exit(2)
        for f in CANDIDATE_REQUIRED_FIELDS:
            if f not in cand:
                err("project block missing required field %r at offset %d"
                    % (f, h3_starts[k]))
                sys.exit(2)
        if cand.get("type") != "project":
            # T-8 only handles project candidates; non-project H3s appear
            # under '## Doesn’t fit any project — disposition' and are
            # T-10's territory. But the import-plan author MAY have edited
            # type at T-7; if a non-project sneaked into the project
            # section, skip with stderr note (do not crash).
            err("WARN: non-project candidate %r in '## Project candidates' "
                "section (type=%r); skipping (T-10 owns non-project routing)"
                % (cand.get("candidate_id"), cand.get("type")))
            continue
        candidates.append(cand)
    return candidates


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
