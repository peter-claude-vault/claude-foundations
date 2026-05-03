#!/bin/bash
# plan-index — Regenerate ~/.claude-plans/_index.md as a status-grouped
# navigation index over every plan root.
#
# Landed: Plan 63 Sub-plan 01 T-1 (2026-04-20). First extraction from the
# librarian SKILL.md inline-pseudocode set. Implements the algorithm
# previously documented at SKILL.md L562–649.
#
# Usage:
#   plan-index.sh                 # regenerate _index.md
#   plan-index.sh --dry-run       # produce content + report counts, no write
#   plan-index.sh --parent <slug> # filter to plans whose parent chain includes <slug>
#
# Exits non-zero on:
#   - walk finds zero plan roots (prevents wiping _index.md on a misread)
#   - group-count sum assertion fails
#   - unknown flag
#
# Bash 3.2 clean. Read-only walk + single atomic file write.
set -euo pipefail

source "$HOME/.claude/hooks/lib/paths.sh"
source "$HOME/.claude/skills/librarian/lib/plan-path.sh"
source "$HOME/.claude/skills/librarian/lib/findings.sh"
source "$HOME/.claude/skills/librarian/lib/manifest.sh"

DRY_RUN=false
PARENT_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --parent)  PARENT_FILTER="$2"; shift 2 ;;
    *) echo "plan-index: unknown flag: $1" >&2; exit 2 ;;
  esac
done

INDEX_PATH="$PLANS_DIR/_index.md"
TMP_PATH="${INDEX_PATH}.tmp.$$"

# Operator-configurable whitelist of plan slugs exempt from the NN- prefix
# conformance audit (legacy master-initiative directories that predate the
# convention). Sourced from user-manifest at .plans.master_initiative_whitelist
# with empty-array fallback. SP10 T-14: replaces the prior hardcoded
# Peter-vault-specific set.
USER_MANIFEST_PATH="${USER_MANIFEST_PATH:-$CLAUDE_HOME/user-manifest.json}"

# The heavy lifting is a single Python invocation that walks $PLANS_DIR,
# classifies each entry per the SKILL.md Process section, sorts, and emits
# the target markdown. Keeping this monolithic reduces per-entry subprocess
# overhead and makes the output deterministic (single sort pass, one clock).
python3 - "$PLANS_DIR" "$INDEX_PATH" "$TMP_PATH" "$DRY_RUN" "$PARENT_FILTER" "$USER_MANIFEST_PATH" <<'PY'
import json, os, re, sys, datetime, pathlib

PLANS_DIR = pathlib.Path(sys.argv[1])
INDEX_PATH = pathlib.Path(sys.argv[2])
TMP_PATH = pathlib.Path(sys.argv[3])
DRY_RUN = sys.argv[4] == "true"
PARENT_FILTER = sys.argv[5] or None
USER_MANIFEST_PATH = pathlib.Path(sys.argv[6]) if len(sys.argv) > 6 else None

def _load_master_initiative_whitelist():
    if not USER_MANIFEST_PATH or not USER_MANIFEST_PATH.is_file():
        return set()
    try:
        with open(USER_MANIFEST_PATH) as f:
            doc = json.load(f)
    except Exception:
        return set()
    raw = (doc.get("plans") or {}).get("master_initiative_whitelist") or []
    return {s for s in raw if isinstance(s, str)}

MASTER_INITIATIVE_WHITELIST = _load_master_initiative_whitelist()

# Exclude-from-walk entries at plan-root depth 1.
EXCLUDE_SLUGS = {"_index.md", "ENFORCEMENT-MAP.md"}

# Status normalization per SKILL.md Process step 2.
ACTIVE_VALUES = {
    "planned", "briefed", "draft", "in-progress", "in_progress",
    "review", "researching", "ready", "active", "approved",
    
    # read behavior for Plans 42 and 54 only. Retire the word once those
    # manifests migrate to `in-progress`. See SKILL.md §Status vocabulary
    # deprecation note.
}
COMPLETE_VALUES = {"complete", "completed", "done", "implemented"}
ONHOLD_VALUES = {"on-hold", "deferred", "paused"}
SUPERSEDED_VALUES = {"superseded", "replaced", "obsolete", "absorbed"}
ABANDONED_VALUES = {"abandoned", "abandoned-with-reason", "tombstoned", "cancelled"}

def normalize_status(raw):
    if not raw:
        return "Unknown"
    # Strip trailing commentary (everything after ` — ` or ` - `).
    head = re.split(r"\s+[—\-]\s+", raw.strip(), maxsplit=1)[0]
    head = head.split("(", 1)[0].strip()  # strip parenthetical commentary
    # Strip trailing sentence (`"COMPLETE. All phases done."` -> `"COMPLETE"`).
    head = head.split(".", 1)[0].strip()
    # Collapse internal whitespace to a hyphen so "On Hold" ↔ "on-hold"
    # and "In Progress" ↔ "in-progress" match the canonical ladder.
    s = re.sub(r"\s+", "-", head).lower()
    # Exact match first (cheapest + most canonical).
    if s in ACTIVE_VALUES or s.startswith("approved-"):
        return "Active"
    if s in COMPLETE_VALUES:
        return "Complete"
    if s in ONHOLD_VALUES:
        return "On-Hold"
    if s in SUPERSEDED_VALUES or s.startswith("absorbed-by-"):
        return "Superseded"
    if s in ABANDONED_VALUES:
        return "Abandoned"
    # Prefix match for trailing-narrative cases: "superseded-by-chrome-mcp-..."
    # maps to Superseded, "complete-all-phases-done" maps to Complete, etc.
    for v in SUPERSEDED_VALUES:
        if s.startswith(v + "-"):
            return "Superseded"
    for v in ABANDONED_VALUES:
        if s.startswith(v + "-"):
            return "Abandoned"
    for v in COMPLETE_VALUES:
        if s.startswith(v + "-"):
            return "Complete"
    for v in ACTIVE_VALUES:
        if s.startswith(v + "-"):
            return "Active"
    for v in ONHOLD_VALUES:
        if s.startswith(v + "-"):
            return "On-Hold"
    return "Unknown"

def parse_frontmatter(text):
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 4)
    if end == -1:
        return {}
    body = text[4:end]
    fm = {}
    for line in body.splitlines():
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*?)\s*$", line)
        if m:
            fm[m.group(1)] = m.group(2)
    return fm

def read_text(path):
    try:
        return path.read_text(errors="replace")
    except Exception:
        return ""

def extract_status(entry):
    if entry.is_dir():
        mp = entry / "manifest.json"
        if mp.is_file():
            try:
                with open(mp) as f:
                    doc = json.load(f)
                s = doc.get("status")
                if s:
                    return s
            except Exception:
                pass
        for name in ("spec.md", "00-ideation-brief.md", "README.md"):
            sp = entry / name
            if sp.is_file():
                txt = read_text(sp)
                m = re.search(r"^\*\*Status:\*\*\s*([^\n]+?)\s*$", txt, re.M)
                if m:
                    return m.group(1)
                fm = parse_frontmatter(txt)
                if fm.get("status"):
                    return fm["status"]
        return ""
    if entry.is_file() and entry.suffix == ".md":
        txt = read_text(entry)
        m = re.search(r"^\*\*Status:\*\*\s*([^\n]+?)\s*$", txt, re.M)
        if m:
            return m.group(1)
        fm = parse_frontmatter(txt)
        if fm.get("status"):
            return fm["status"]
    return ""

def extract_title(entry):
    if entry.is_dir():
        for name in ("spec.md", "00-ideation-brief.md", "README.md"):
            sp = entry / name
            if sp.is_file():
                txt = read_text(sp)
                m = re.search(r"^#\s+(.+?)\s*$", txt, re.M)
                if m:
                    t = m.group(1).strip()
                    t = re.sub(r"\s*[—\-]\s*(Spec|Plan)\s*$", "", t)
                    return t
        return entry.name
    if entry.is_file():
        txt = read_text(entry)
        m = re.search(r"^#\s+(.+?)\s*$", txt, re.M)
        if m:
            t = m.group(1).strip()
            t = re.sub(r"\s*[—\-]\s*(Spec|Plan)\s*$", "", t)
            return t
    return entry.name

def parent_plan_chain(entry):
    """Walk the parent_plan chain from entry back to a root plan slug.
    Used only when --parent filter is active."""
    chain = []
    slugs_visited = set()
    current = entry
    for _ in range(10):  # defensive cycle limit
        if current.is_dir():
            sp = current / "spec.md"
        else:
            sp = current
        if not sp.is_file():
            break
        fm = parse_frontmatter(read_text(sp))
        pp = fm.get("parent_plan", "").strip()
        if not pp or pp in slugs_visited:
            break
        slugs_visited.add(pp)
        chain.append(pp)
        # Resolve pp → next entry (best-effort: look for NN-<pp> or <pp>)
        candidates = list(PLANS_DIR.glob(f"*-{pp}")) + list(PLANS_DIR.glob(pp)) + [PLANS_DIR / pp]
        found = None
        for c in candidates:
            if c.exists():
                found = c
                break
        if not found:
            break
        current = found
    return chain

entries_by_group = {
    "Active": [],
    "On-Hold": [],
    "Complete": [],
    "Superseded": [],
    "Abandoned": [],
    "Unknown": [],
}
warnings = []
total_counted = 0

if not PLANS_DIR.is_dir():
    print(f"plan-index: $PLANS_DIR not found: {PLANS_DIR}", file=sys.stderr)
    sys.exit(1)

for entry in sorted(PLANS_DIR.iterdir()):
    slug = entry.name
    # Dotfiles + underscore-prefixed scaffold entries are not plans.
    if slug.startswith("_") or slug.startswith("."):
        continue
    if slug in EXCLUDE_SLUGS:
        continue

    # Prefix-conformance audit (Session 22 Module 22-I). Emits finding but
    # classification continues — slug still appears in index.
    if slug not in MASTER_INITIATIVE_WHITELIST:
        if not re.match(r"^\d+-", slug):
            print(json.dumps({
                "finding": "plan-prefix-missing",
                "file": slug,
                "category": "plan-naming-drift",
                "resolution_hint": "rename via `git mv {slug} NN-{slug}` where NN is the next-available prefix"
            }))

    # Orchestrator-artifact exclusion (Session 22).
    if entry.is_dir():
        mp = entry / "manifest.json"
        if mp.is_file():
            try:
                with open(mp) as f:
                    mdoc = json.load(f)
                spec_path = mdoc.get("spec_path", "") or ""
                if spec_path and not (spec_path == "spec.md" or str(entry) in spec_path):
                    # spec_path points outside this directory → autonomous-
                    # orchestration exhaust; skip.
                    continue
            except Exception:
                pass

    # --parent filter (optional).
    if PARENT_FILTER:
        chain = parent_plan_chain(entry)
        if PARENT_FILTER not in chain:
            continue

    raw_status = extract_status(entry)
    group = normalize_status(raw_status)
    title = extract_title(entry)

    if entry.is_dir():
        line = f"- [{slug}](./{slug}/) — {title}"
    else:
        line = f"- [{slug}](./{slug}) — {title}"

    entries_by_group[group].append((slug, line))
    total_counted += 1
    if group == "Unknown":
        warnings.append(slug)

# Sort within each group by slug (numeric-prefix natural sort).
def slug_sort_key(item):
    s = item[0]
    m = re.match(r"^(\d+)-(.*)$", s)
    if m:
        return (0, int(m.group(1)), m.group(2))
    return (1, 0, s)

for g in entries_by_group:
    entries_by_group[g].sort(key=slug_sort_key)

# Group-count sum assertion (Process step 6).
group_sum = sum(len(v) for v in entries_by_group.values())
if group_sum != total_counted:
    print(f"plan-index: group-count assertion failed — sum={group_sum} total={total_counted}",
          file=sys.stderr)
    sys.exit(3)

if total_counted == 0:
    print("plan-index: walk found 0 plan roots; aborting to prevent _index.md wipe",
          file=sys.stderr)
    sys.exit(4)

# Compose target _index.md.
now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
out = []
out.append("# Plan Index")
out.append("")
out.append("_Auto-generated by `librarian plan-index`. Do not hand-edit — changes will be overwritten on the next `librarian full` run._")
out.append("")
out.append(f"**Total plans:** {total_counted}")
out.append(f"**Last regenerated:** {now}")
out.append("")
for group_name in ("Active", "On-Hold", "Complete", "Superseded", "Abandoned", "Unknown"):
    items = entries_by_group[group_name]
    out.append(f"## {group_name} ({len(items)})")
    out.append("")
    if group_name == "Unknown":
        out.append("_Plans missing a detectable status. Fix by adding a `**Status:**` header or `manifest.json`._")
        out.append("")
    if group_name == "Abandoned":
        out.append("_Tombstoned plans — considered and decided not to build. Retained as portfolio memory._")
        out.append("")
    if items:
        for _, line in items:
            out.append(line)
    out.append("")

content = "\n".join(out).rstrip() + "\n"

# Report & write.
print(json.dumps({
    "plan_index_run": {
        "total": total_counted,
        "active": len(entries_by_group["Active"]),
        "on_hold": len(entries_by_group["On-Hold"]),
        "complete": len(entries_by_group["Complete"]),
        "superseded": len(entries_by_group["Superseded"]),
        "abandoned": len(entries_by_group["Abandoned"]),
        "unknown": len(entries_by_group["Unknown"]),
        "unknown_slugs": warnings,
        "dry_run": DRY_RUN,
        "parent_filter": PARENT_FILTER or None,
    }
}))

if not DRY_RUN:
    TMP_PATH.write_text(content)
    os.replace(TMP_PATH, INDEX_PATH)
else:
    # Print the composed content to stderr so diffing is easy without
    # polluting the findings stream on stdout.
    sys.stderr.write(content)

PY

