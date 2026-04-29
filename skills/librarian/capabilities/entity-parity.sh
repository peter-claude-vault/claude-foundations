#!/bin/bash
# entity-parity — Cross-surface entity parity check driven by the
# entities registry in ~/.claude/hooks/doc-dependencies.json.
#
# V1 landed 2026-04-21: one entity type (`skill`), 2 mirrors, 5 finding classes.
# V2 landed 2026-04-21: adds `plan` + `memory-file` entity types, `row_kind` +
#   `match_kind` + `optional` + `exclude_basenames` registry fields, generalized
#   instance-ID extraction from canonical template placeholders.
# V3 (deferred): pre-write-guard event-time advisory.
# V4 (deferred): `--apply` with survivorship + session-close Step 2d gate.
#
# Finding classes:
#   entity-parity-canonical-missing-description     canonical lacks description field (skill + memory-file)
#   entity-parity-canonical-missing-status          canonical lacks status field (plan)
#   entity-parity-mirror-missing                    strict (non-optional) mirror file absent
#   entity-parity-mirror-absent-description         strict mirror present, no description field (info)
#   entity-parity-mirror-absent-status              strict mirror present, no status field (info)
#   entity-parity-description-mismatch              exact-match fails on description
#   entity-parity-status-mismatch                   exact-match fails on status
#   entity-parity-index-row-missing                 #row[] mirror has no matching row
#   entity-parity-registry-parse-failed             registry unreadable or entity block missing
#
# Summary-style mirrors (row_kind + presence_only: true) never emit content-mismatch.
# Optional mirrors (optional: true) never emit mirror-missing when absent.
#
# CLI:
#   entity-parity.sh                        # --check default
#   entity-parity.sh --check                # emit findings + persist to manifest
#   entity-parity.sh --scope <dir>          # narrow to one instance directory
#   entity-parity.sh --entity-type <type>   # narrow to skill|plan|memory-file
#   entity-parity.sh --dry-run              # summary counts only
#
# Env overrides (testing):
#   ENTITY_PARITY_DOC_DEPS_OVERRIDE     — registry JSON path
#   ENTITY_PARITY_SKILLS_ROOT_OVERRIDE  — canonical root for skills (default ~/.claude/skills)
#   ENTITY_PARITY_VAULT_ROOT_OVERRIDE   — mirror root (default $VAULT_ROOT)
#   ENTITY_PARITY_PLANS_ROOT_OVERRIDE   — canonical root for plans (default $PLANS_DIR or ~/.claude-plans)
#   ENTITY_PARITY_MEMORY_ROOT_OVERRIDE  — canonical root for memory (default ~/.claude/projects/.../memory)
#   MANIFEST_PATH                       — manifest file (default $VAULT_LOGS/librarian-manifest.json)
#   FINDINGS_OUTPUT                     — sink for finding lines (default stdout)
#
# Bash 3.2 clean per R-23.

set -euo pipefail

if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.claude/hooks/lib/paths.sh"
fi
# shellcheck source=/dev/null
source "$HOME/.claude/skills/librarian/lib/findings.sh"
# shellcheck source=/dev/null
source "$HOME/.claude/skills/librarian/lib/manifest.sh"

SCOPE=""
ENTITY_TYPE_FILTER=""
MODE="check"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)       SCOPE="$2"; shift 2 ;;
    --entity-type) ENTITY_TYPE_FILTER="$2"; shift 2 ;;
    --check)       MODE="check"; shift ;;
    --dry-run)     DRY_RUN="true"; shift ;;
    -h|--help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "entity-parity: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

DOC_DEPS="${ENTITY_PARITY_DOC_DEPS_OVERRIDE:-$HOME/.claude/hooks/doc-dependencies.json}"
VAULT_ROOT_RESOLVED="${ENTITY_PARITY_VAULT_ROOT_OVERRIDE:-$VAULT_ROOT}"

EXISTING_DRIFT="$(manifest_get '.drift_findings.entity_parity' '[]')"

DRIFT_OUT="$(mktemp -t entity-parity-drift.XXXXXX)"
trap 'rm -f "$DRIFT_OUT"' EXIT

export EP_DOC_DEPS="$DOC_DEPS"
export EP_VAULT_ROOT="$VAULT_ROOT_RESOLVED"
export EP_SCOPE="$SCOPE"
export EP_ENTITY_TYPE_FILTER="$ENTITY_TYPE_FILTER"
export EP_MODE="$MODE"
export EP_DRY_RUN="$DRY_RUN"
export EP_EXISTING_DRIFT="$EXISTING_DRIFT"
export EP_DRIFT_OUT="$DRIFT_OUT"
export EP_SKILLS_ROOT="${ENTITY_PARITY_SKILLS_ROOT_OVERRIDE:-}"
export EP_PLANS_ROOT="${ENTITY_PARITY_PLANS_ROOT_OVERRIDE:-}"
export EP_MEMORY_ROOT="${ENTITY_PARITY_MEMORY_ROOT_OVERRIDE:-}"

python3 - <<'PY'
import json, os, re, sys, glob
from datetime import datetime, timezone

doc_deps_path     = os.environ["EP_DOC_DEPS"]
vault_root        = os.environ["EP_VAULT_ROOT"] or ""
scope             = os.environ.get("EP_SCOPE") or ""
entity_filter     = os.environ.get("EP_ENTITY_TYPE_FILTER") or ""
mode              = os.environ["EP_MODE"]
dry_run           = (os.environ["EP_DRY_RUN"] == "true")
drift_out         = os.environ["EP_DRIFT_OUT"]
findings_out      = os.environ.get("FINDINGS_OUTPUT", "")

today_iso = datetime.now(timezone.utc).replace(tzinfo=None).strftime("%Y-%m-%dT%H:%M:%S")

def emit_line(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

findings = []

def emit(finding_class, entity_type, instance_id, invariant_id, mirror_path, severity, **attrs):
    f = {
        "finding": finding_class,
        "entity_type": entity_type,
        "instance_id": instance_id,
        "invariant_id": invariant_id,
        "mirror_path": mirror_path,
        "severity": severity,
    }
    for k, v in attrs.items():
        f[k] = v
    findings.append(f)
    if not dry_run:
        emit_line(f)

# ---------- registry parse ----------
try:
    with open(doc_deps_path, "r") as f:
        registry = json.load(f)
    entities = registry.get("entities") or {}
except Exception as e:
    emit("entity-parity-registry-parse-failed", "<registry>", "<registry>",
         "registry-present", "", "warn",
         reason=f"registry read failed: {type(e).__name__}")
    entities = {}

entity_types = [k for k in entities.keys() if not k.startswith("_")]
if not entity_types:
    emit("entity-parity-registry-parse-failed", "<registry>", "<registry>",
         "entities-present", "", "warn",
         reason="registry has no entity definitions")

if entity_filter:
    entity_types = [t for t in entity_types if t == entity_filter]

# ---------- frontmatter parse ----------
FM_START = re.compile(r"^---\s*$")
FIELD_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*)\s*:\s*(.*?)\s*$")

def parse_frontmatter(path):
    """Return dict of frontmatter fields, or None if no frontmatter."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except Exception:
        return None
    lines = text.splitlines()
    if not lines or not FM_START.match(lines[0]):
        return None
    fields = {}
    for i in range(1, len(lines)):
        if FM_START.match(lines[i]):
            return fields
        m = FIELD_RE.match(lines[i])
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        if len(val) >= 2 and ((val[0] == '"' and val[-1] == '"')
                              or (val[0] == "'" and val[-1] == "'")):
            val = val[1:-1]
        fields[key] = val
    return None  # Frontmatter never closed

def parse_json_field(path, field):
    """Return field value from top-level JSON object, or None if absent."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)
        val = doc.get(field)
        if val is None:
            return None
        return str(val)
    except Exception:
        return None

# ---------- row_kind selectors ----------
def row_wikilink(file_path, key, prefix="Skills"):
    """V1 pattern: `[[Skills/{key}|{key}]]` pipe-table row."""
    if not os.path.isfile(file_path):
        return False
    key_re = re.escape(key)
    prefix_re = re.escape(prefix)
    pat = re.compile(r"^\|[^|]*\[\[" + prefix_re + r"/" + key_re + r"[|\]\\]")
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            for line in f:
                if pat.match(line):
                    return True
    except Exception:
        return False
    return False

def row_backlog(file_path, slug):
    """V2 pattern: pipe-table row containing `plan: {slug}` backtick-pointer.
    Accepts observed variations: `plan: {slug}`, `plan: {slug}/`, `plan: {slug}.md`."""
    if not os.path.isfile(file_path):
        return False
    slug_re = re.escape(slug)
    # Match `plan: slug` or `plan: slug/` or `plan: slug.md` inside backticks
    pat = re.compile(r"`plan:\s+" + slug_re + r"(/|\.md)?`")
    # Line must also be a pipe-table row
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("|") and pat.search(line):
                    return True
    except Exception:
        return False
    return False

def row_memory_index(file_path, filename):
    """V2 pattern: list-line `- [<filename>](memory/<filename>) — ...`."""
    if not os.path.isfile(file_path):
        return False
    fn_re = re.escape(filename)
    pat = re.compile(r"^-\s+\[[^\]]*\]\(memory/" + fn_re + r"\)")
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            for line in f:
                if pat.match(line):
                    return True
    except Exception:
        return False
    return False

def resolve_row(file_path, key, row_kind):
    # Default: wikilink-row (V1 behavior; retained for backward-compat when
    # a mirror declares a #row[{key}] path without an explicit row_kind).
    if not row_kind or row_kind == "wikilink-row":
        return row_wikilink(file_path, key, prefix="Skills")
    if row_kind == "backlog-row":
        return row_backlog(file_path, key)
    if row_kind == "memory-index-line":
        return row_memory_index(file_path, key)
    return False

# ---------- path expansion + instance enumeration ----------
ROOT_OVERRIDES = {
    "~/.claude/skills/":                      os.environ.get("EP_SKILLS_ROOT") or "",
    "~/.claude-plans/":                       os.environ.get("EP_PLANS_ROOT") or "",
}
# Memory-dir override is registered at runtime when EP_MEMORY_ROOT is set,
# since the canonical memory path is user-specific (resolved by the
# memory-dir resolver shipped with SP04 T-4 / SP01 T-10).
_memory_override = os.environ.get("EP_MEMORY_ROOT") or ""
if _memory_override:
    ROOT_OVERRIDES[_memory_override.rstrip("/") + "/"] = _memory_override

def apply_root_override(path_str):
    """If the path matches a known canonical root and that root has a test
    override, rewrite the prefix to the override. Otherwise return unchanged."""
    for prefix, override in ROOT_OVERRIDES.items():
        if override and path_str.startswith(prefix):
            return override.rstrip("/") + "/" + path_str[len(prefix):]
    return path_str

def expand(template, placeholder_map):
    out = template
    for ph_name, ph_val in placeholder_map.items():
        out = out.replace("{" + ph_name + "}", ph_val)
    out = apply_root_override(out)
    if out.startswith("~/"):
        out = os.path.expanduser(out)
    elif not out.startswith("/"):
        out = os.path.join(vault_root, out) if vault_root else out
    return out

def extract_instance_id(canonical_template, resolved_path):
    """Positional extractor: find the placeholder segment's position from the
    end of the template, and take the segment at the same position from the
    resolved path. Works regardless of absolute path prefix (no anchoring to
    `~/.claude/skills/...`), so test env overrides and production paths use
    the same code path.

    Returns (placeholder_name, instance_id) or (None, None) if extraction fails.
    """
    parts_tpl  = canonical_template.split("/")
    parts_path = resolved_path.split("/")

    placeholder_name = None
    placeholder_idx_from_end = None
    for i, seg in enumerate(parts_tpl):
        m = re.fullmatch(r"\{([A-Za-z_][A-Za-z0-9_]*)\}", seg)
        if m:
            placeholder_name = m.group(1)
            placeholder_idx_from_end = len(parts_tpl) - 1 - i
            break

    if placeholder_name is None:
        return None, None

    idx = len(parts_path) - 1 - placeholder_idx_from_end
    if idx < 0 or idx >= len(parts_path):
        return None, None
    return placeholder_name, parts_path[idx]

def enumerate_instances(entity_type, entity):
    """Return list of (primary_placeholder_name, placeholder_map, canonical_path)."""
    enumerator    = entity.get("instance_enumerator", "")
    canonical_tpl = entity.get("canonical", "")
    excludes      = set(entity.get("exclude_basenames") or [])

    if not enumerator.startswith("glob:"):
        return []

    pattern = enumerator[len("glob:"):]
    pattern = apply_root_override(pattern)
    if pattern.startswith("~/"):
        pattern = os.path.expanduser(pattern)

    paths = sorted(glob.glob(pattern))

    instances = []
    for p in paths:
        if os.path.basename(p) in excludes:
            continue
        primary, instance_id = extract_instance_id(canonical_tpl, p)
        if not primary or not instance_id:
            continue
        ph_map = {primary: instance_id}
        instances.append((primary, ph_map, p))
    return instances

# ---------- mirror evaluation ----------
def resolve_mirror_path(mirror_path_tpl, ph_map):
    """Strip any #row[] suffix; expand placeholders; return base file path and
    the suffix (or empty string)."""
    if "#row[" in mirror_path_tpl:
        base_tpl, suffix = mirror_path_tpl.split("#row[", 1)
        return expand(base_tpl, ph_map), True
    return expand(mirror_path_tpl, ph_map), False

def trunc(s, n=200):
    if s is None:
        return ""
    return s if len(s) <= n else s[: n - 1] + "…"

# ---------- main walk ----------
scanned = 0

for entity_type in entity_types:
    entity = entities[entity_type]
    canonical_tpl   = entity.get("canonical", "")
    canonical_field = entity.get("canonical_field", "description")
    mirrors         = entity.get("mirrors") or []

    instances = enumerate_instances(entity_type, entity)

    if scope:
        scope_abs = os.path.abspath(os.path.expanduser(scope))
        narrowed = []
        for primary, ph_map, canonical_path in instances:
            cdir = os.path.abspath(os.path.dirname(canonical_path))
            cfile = os.path.abspath(canonical_path)
            if scope_abs == cdir or scope_abs == cfile:
                narrowed.append((primary, ph_map, canonical_path))
        instances = narrowed

    for primary, ph_map, canonical_path in instances:
        scanned += 1
        instance_id = ph_map.get(primary, os.path.basename(canonical_path))

        # Canonical field read
        canonical_fields = parse_frontmatter(canonical_path) or {}
        canonical_value = canonical_fields.get(canonical_field)

        if canonical_value is None:
            emit(f"entity-parity-canonical-missing-{canonical_field}",
                 entity_type, instance_id, f"canonical-has-{canonical_field}",
                 canonical_path.replace(os.path.expanduser("~"), "~"),
                 "warn")

        for mirror in mirrors:
            mpath_tpl   = mirror.get("path", "")
            strict      = bool(mirror.get("strict", False))
            presence    = bool(mirror.get("presence_only", False))
            optional    = bool(mirror.get("optional", False))
            row_kind    = mirror.get("row_kind", "")
            match_kind  = mirror.get("match_kind", "frontmatter")
            fields      = mirror.get("fields") or []

            # Row-selector mirrors use the `#row[...]` suffix
            if "#row[" in mpath_tpl:
                base_path, _ = resolve_mirror_path(mpath_tpl, ph_map)
                found = resolve_row(base_path, instance_id, row_kind)
                rendered_path = mpath_tpl
                for ph_name, ph_val in ph_map.items():
                    rendered_path = rendered_path.replace("{" + ph_name + "}", ph_val)
                if not found:
                    emit("entity-parity-index-row-missing",
                         entity_type, instance_id, "index-row-present",
                         rendered_path, "warn",
                         expected_path=base_path.replace(os.path.expanduser("~"), "~"),
                         row_kind=row_kind)
                continue

            # File-based mirrors
            mpath = expand(mpath_tpl, ph_map)
            rendered_path = mpath_tpl
            for ph_name, ph_val in ph_map.items():
                rendered_path = rendered_path.replace("{" + ph_name + "}", ph_val)

            if not os.path.isfile(mpath):
                if strict and not optional:
                    emit("entity-parity-mirror-missing",
                         entity_type, instance_id, "mirror-exists",
                         rendered_path, "warn",
                         expected_path=mpath.replace(os.path.expanduser("~"), "~"))
                # Optional + absent = silent
                continue

            if presence:
                continue  # Presence-only mirror; nothing else to check

            # Strict content-match
            if strict:
                for field in fields:
                    if match_kind == "json-field":
                        mirror_value = parse_json_field(mpath, field)
                    else:  # frontmatter
                        mf = parse_frontmatter(mpath) or {}
                        mirror_value = mf.get(field)

                    if mirror_value is None:
                        emit(f"entity-parity-mirror-absent-{field}",
                             entity_type, instance_id, f"mirror-has-{field}",
                             rendered_path, "info")
                        continue
                    if canonical_value is None:
                        continue
                    # Only compare on the primary canonical field; other fields
                    # declared in `fields[]` are checked for presence only.
                    if field == canonical_field and canonical_value != mirror_value:
                        emit(f"entity-parity-{field}-mismatch",
                             entity_type, instance_id, f"{field}-exact-match",
                             rendered_path, "warn",
                             canonical_value=trunc(canonical_value),
                             mirror_value=trunc(mirror_value))

# ---------- persistent-ID reconciliation ----------
def reconcile(existing_list, new_findings, match_keys, id_prefix):
    existing_by_key = {}
    max_n = 0
    for row in existing_list or []:
        if not isinstance(row, dict):
            continue
        key = tuple((row.get(k) or "") for k in match_keys)
        existing_by_key[key] = row
        rid = row.get("id") or ""
        m = re.match(r"^" + re.escape(id_prefix) + r"-(\d+)$", rid)
        if m:
            n = int(m.group(1))
            if n > max_n:
                max_n = n
    merged = []
    for f in new_findings:
        key = tuple((f.get(k) or "") for k in match_keys)
        if key in existing_by_key:
            prior = existing_by_key[key]
            out = dict(f)
            out["id"] = prior.get("id") or f"{id_prefix}-{max_n+1:03d}"
            out["first_seen"] = prior.get("first_seen") or today_iso
            out["last_seen"] = today_iso
            if not prior.get("id"):
                max_n += 1
        else:
            max_n += 1
            out = dict(f)
            out["id"] = f"{id_prefix}-{max_n:03d}"
            out["first_seen"] = today_iso
            out["last_seen"] = today_iso
        merged.append(out)
    return merged

try:
    existing_drift = json.loads(os.environ.get("EP_EXISTING_DRIFT") or "[]")
    if not isinstance(existing_drift, list):
        existing_drift = []
except Exception:
    existing_drift = []

match_keys = ("entity_type", "instance_id", "invariant_id", "mirror_path")
merged = reconcile(existing_drift, findings, match_keys, "EP")

with open(drift_out, "w") as f:
    json.dump(merged, f)

# ---------- summary / dry-run ----------
by_class = {}
by_entity = {}
for f in findings:
    by_class[f["finding"]] = by_class.get(f["finding"], 0) + 1
    by_entity[f["entity_type"]] = by_entity.get(f["entity_type"], 0) + 1

if dry_run:
    parts = [f"scanned={scanned}", f"findings={len(findings)}"]
    for k in sorted(by_entity):
        parts.append(f"{k}={by_entity[k]}")
    for k in sorted(by_class):
        parts.append(f"{k}={by_class[k]}")
    sys.stdout.write("entity-parity: " + " ".join(parts) + "\n")
else:
    summary = {
        "summary": "entity-parity",
        "scanned": scanned,
        "findings": len(findings),
        "by_class": by_class,
        "by_entity": by_entity,
        "mode": mode,
    }
    emit_line(summary)
PY

if [[ -s "$DRIFT_OUT" ]] && [[ -n "${MANIFEST_PATH:-}" ]] && [[ -f "$MANIFEST_PATH" ]]; then
  manifest_set '.drift_findings.entity_parity' "$(cat "$DRIFT_OUT")"
fi
