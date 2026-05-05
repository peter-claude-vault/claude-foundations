#!/usr/bin/env python3
"""
h3_walker.py — shared H3-walker for SP13 approved-import-plan.md consumers.

Promoted from seed.py at SP13 T-10 per T-8 Decision 7 + T-9 close-out
carry-forward. T-10 (inbox-disposition.py) is the second consumer of the
H3 walker pattern; rather than duplicate ~200 lines of YAML parser +
section walker into a third file at T-13 (retrofit), we lift them once
here and let consumers import.

Public API:
    SCHEMA_VERSION_EXPECTED        — constant ("sp13-t6/1").
    CANDIDATE_REQUIRED_FIELDS      — 8-tuple every parsed candidate carries.

    split_frontmatter(text)        — (fm_text, body) split on '---' fences.
    parse_yaml_block(text)         — bounded YAML parser (raises ValueError).
    walk_h3_section(plan_path,
                    section_pattern,
                    allowed_types=None,
                    required_fields=None) — returns [candidate_dict, ...].

Stdlib only — no pyyaml / pydantic / requests. R-23 not relevant (Python).

Design notes:
- The YAML parser handles the bounded shape T-6 emits (scalars + lists +
  nested mappings of depth ≤ 2; no anchors / aliases / multi-doc / flow
  style). It is NOT a general YAML parser; do not feed it arbitrary YAML.
- `walk_h3_section` takes a regex pattern (compiled `re.Pattern` OR a
  string compiled here) so callers can match Unicode-bearing headings
  like "## Doesn’t fit any project — disposition" without literal pasting.
- Section absence with no H3s under it is NOT an error (returns []) —
  callers that require candidates check `len(...) == 0` after calling.
- Schema-version mismatch → exits 2 with stderr ("hard halt"). Same
  contract seed.sh + seed.py held at T-8.

Author: Claude Opus 4.7 — Plan 71 SP13 Session 8 (T-10 promotion).
"""

import os
import re
import sys


SCHEMA_VERSION_EXPECTED = "sp13-t6/1"

CANDIDATE_REQUIRED_FIELDS = (
    "candidate_id", "label", "type", "proposed_path",
    "metadata", "source_items", "confidence", "low_confidence",
)


def err(msg):
    sys.stderr.write("h3_walker: %s\n" % msg)


# ---------------------------------------------------------------------------
# Frontmatter split
# ---------------------------------------------------------------------------

def split_frontmatter(text):
    """Return (frontmatter_body, post_body) split on first two '---' lines.

    If the text does not open with a '---' line, returns (None, text).
    If it opens but does not close, returns (None, text).
    """
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


# ---------------------------------------------------------------------------
# YAML parser (bounded; T-6 emission shape only)
# ---------------------------------------------------------------------------

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
            raise ValueError(
                "h3_walker YAML parser: tabs are not permitted in indentation"
            )
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
                "h3_walker YAML parser: unexpected indent on line %d: %r"
                % (i + 1, line)
            )
        stripped = line.strip()
        if stripped.startswith("- "):
            break
        m = re.match(
            r"^([A-Za-z_][A-Za-z0-9_./@#-]*|\"[^\"]*\"|'[^']*')\s*:\s*(.*)$",
            stripped,
        )
        if not m:
            raise ValueError(
                "h3_walker YAML parser: expected 'key: value' on line %d, got %r"
                % (i + 1, stripped)
            )
        key_raw, rest = m.group(1), m.group(2)
        key = _scalar(key_raw)
        pos[0] = i + 1
        if rest == "":
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
            synthetic = " " * (indent + 2) + rest
            tail = lines[i + 1:]
            new_lines = lines[:i + 1]
            new_lines.append(synthetic)
            new_lines.extend(tail)
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
    try:
        return int(s)
    except ValueError:
        pass
    try:
        return float(s)
    except ValueError:
        pass
    return s


# ---------------------------------------------------------------------------
# Section walker
# ---------------------------------------------------------------------------

def walk_h3_section(plan_path, section_pattern, allowed_types=None,
                    required_fields=None):
    """
    Walk an H2 section of an approved import plan and return a list of
    candidate dicts (each H3 + inline ```yaml block).

    plan_path        — path to approved-import-plan.md (validated for
                       schema_version: sp13-t6/1).
    section_pattern  — string OR compiled re.Pattern. The H2 heading line
                       to find. Use raw strings for Unicode-bearing
                       headings ("## Doesn’t fit any project — disposition").
                       The pattern is anchored to line start; the function
                       adds re.MULTILINE.
    allowed_types    — optional iterable of `type` enum values. Candidates
                       whose type is not in this set are skipped with a
                       stderr WARN line. None = accept any type.
    required_fields  — tuple of required candidate fields; defaults to
                       CANDIDATE_REQUIRED_FIELDS.

    Returns: list of dicts (parsed candidate blocks). Empty list when
    section is absent OR section is present but carries no H3 entries.

    Exits 2 on parse errors / schema_version mismatch / unreadable file.
    """
    if not os.path.isfile(plan_path):
        err("approved plan not found: %s" % plan_path)
        sys.exit(2)
    with open(plan_path, "r", encoding="utf-8") as fh:
        content = fh.read()

    fm_text, body = split_frontmatter(content)
    if fm_text is None:
        err("approved plan has no YAML frontmatter: %s" % plan_path)
        sys.exit(2)

    if not re.search(
        r"^schema_version:\s*" + re.escape(SCHEMA_VERSION_EXPECTED) + r"\s*$",
        fm_text,
        re.MULTILINE,
    ):
        err("approved plan schema_version mismatch (expected %r)"
            % SCHEMA_VERSION_EXPECTED)
        sys.exit(2)

    if isinstance(section_pattern, str):
        section_re = re.compile(section_pattern, re.MULTILINE)
    else:
        section_re = section_pattern

    sec_match = section_re.search(body)
    if not sec_match:
        # Section absent — legitimate when the plan has 0 candidates of
        # that disposition (e.g., zero-unclassified fixture for T-10).
        return []

    # Find next H2 (any heading starting "## " at line start) AFTER our
    # section's match end. The next H2 stops the section walk. We use a
    # generic regex rather than reusing the input pattern so multi-section
    # walks compose cleanly.
    next_h2 = re.compile(r"^## ", re.MULTILINE)
    start = sec_match.end()
    next_match = next_h2.search(body, pos=start)
    end = next_match.start() if next_match else len(body)
    section = body[start:end]

    if required_fields is None:
        required_fields = CANDIDATE_REQUIRED_FIELDS
    allowed = set(allowed_types) if allowed_types is not None else None

    candidates = []
    h3_re = re.compile(r"^### .*?$", re.MULTILINE)
    h3_starts = [m.start() for m in h3_re.finditer(section)]
    if not h3_starts:
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
            err("H3 missing inline ```yaml block at section offset %d"
                % h3_starts[k])
            sys.exit(2)
        try:
            cand = parse_yaml_block(yaml_match.group(1))
        except ValueError as e:
            err("YAML parse error in H3 block at offset %d: %s"
                % (h3_starts[k], e))
            sys.exit(2)
        if not isinstance(cand, dict):
            err("H3 block did not parse to a mapping at offset %d"
                % h3_starts[k])
            sys.exit(2)
        for f in required_fields:
            if f not in cand:
                err("H3 block missing required field %r at offset %d"
                    % (f, h3_starts[k]))
                sys.exit(2)
        if allowed is not None and cand.get("type") not in allowed:
            err("WARN: skipping candidate %r with type=%r (not in allowed=%r)"
                % (cand.get("candidate_id"), cand.get("type"), sorted(allowed)))
            continue
        candidates.append(cand)
    return candidates
