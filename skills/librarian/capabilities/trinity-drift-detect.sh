#!/bin/bash
# trinity-drift-detect — Detect disagreement between spec.md / manifest.json /
# tasks.md / per-task T-N statuses across plan-root and sub-plan-root directories.
#
# Landed: Plan 67 Sub-plan 04 T-1 (2026-04-22). Addresses the drift class caught
# by the 2026-04-21 validation audit: sub-plan spec/manifest declared
# `status: complete`, but tasks.md ledger lagged with `not-started`/`in-progress`
# per-task statuses, masking incomplete work as complete.
#
# Walk scope:
#   Depth 2: ~/.claude-plans/<plan>/{spec.md,manifest.json,tasks.md}
#   Depth 3: ~/.claude-plans/<plan>/<subplan>/{spec.md,manifest.json,tasks.md}
#
# For every directory containing BOTH spec.md and manifest.json, compare:
#   - spec.md frontmatter status:
#   - manifest.json .status
#   - tasks.md frontmatter status:
#   - tasks.md per-task **Status:** values (T-1, T-2, ...)
#
# Emission rules (NDJSON via emit_event):
#   - spec.status != manifest.status → drift_class=spec-manifest-divergence
#   - manifest.status=complete AND any T-N.status != done → drift_class=trinity-task-ledger-lag
#   - spec.status=complete AND tasks.status=planned → drift_class=header-trinity-divergence
#   - Tolerated non-drift (no emission):
#       * All-in-progress (mid-execution valid state)
#       * manifest/spec/tasks all agree (aligned)
#       * manifest.complete but no tasks.md present (flat plan)
#
# Finding payload:
#   {"finding":"trinity-status-drift","file":"<plan-rel>","drift_class":"<class>",
#    "spec_status":"...","manifest_status":"...","tasks_status":"...",
#    "task_ledger":[{"id":"T-1","status":"not-started"}, ...],
#    "detected_at":"<ISO8601>"}
#
# Parse failure fallback: emit drift_class=parse-failure; continue walk.
#
# CLI:
#   trinity-drift-detect.sh                # emit findings to $FINDINGS_OUTPUT or stdout
#   trinity-drift-detect.sh --scope <path> # limit walk root
#   trinity-drift-detect.sh --dry-run      # summary counts, no emission
#   trinity-drift-detect.sh --help
#
# Bash 3.2 clean per R-23. No declare -A, no =~, no ${var,,}.

set -euo pipefail

if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.claude/hooks/lib/paths.sh"
fi
# shellcheck source=/dev/null
source "$HOME/.claude/skills/librarian/lib/findings.sh"

SCOPE=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "trinity-drift-detect: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

PLANS_SCOPE="${SCOPE:-$PLANS_DIR}"

if [[ ! -d "$PLANS_SCOPE" ]]; then
  echo "trinity-drift-detect: scope not a directory: $PLANS_SCOPE" >&2
  exit 2
fi

python3 - "$PLANS_SCOPE" "$DRY_RUN" <<'PY'
import json, os, re, sys
from datetime import datetime

plans_scope, dry_run_s = sys.argv[1:3]
dry_run = (dry_run_s == "true")
findings_out = os.environ.get("FINDINGS_OUTPUT", "")
iso_now = datetime.now().isoformat(timespec="seconds")

def emit(payload):
    if dry_run:
        return
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

# --- parsers -----------------------------------------------------------------

def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return None

def parse_fm_status(path):
    """Parse frontmatter status: field value. Returns ('', None) on missing file
    or no frontmatter. Returns ('<value>', None) on success. Returns ('', 'parse-failure')
    on malformed frontmatter."""
    t = read_text(path)
    if t is None:
        return "", None
    if not t.startswith("---"):
        return "", None
    end = t.find("\n---", 3)
    if end == -1:
        return "", "parse-failure"
    fm_raw = t[3:end].strip()
    for line in fm_raw.split("\n"):
        m = re.match(r"^status\s*:\s*(.*?)\s*$", line)
        if m:
            v = m.group(1).strip().strip('"').strip("'")
            return v, None
    return "", None

def parse_manifest_status(path):
    """Returns ('<status>', None) or ('', 'parse-failure'). Empty if field missing."""
    t = read_text(path)
    if t is None:
        return "", None
    try:
        d = json.loads(t)
    except Exception:
        return "", "parse-failure"
    if not isinstance(d, dict):
        return "", "parse-failure"
    v = d.get("status", "")
    if not isinstance(v, str):
        return "", None
    return v, None

TASK_HEADING = re.compile(r"^###\s+(T-\d+)\s*:", re.MULTILINE)
STATUS_LINE = re.compile(r"^\*\*Status:\*\*\s*(.+?)\s*$", re.MULTILINE)

def parse_task_ledger(path):
    """Walk ### T-N: sections; collect status from **Status:** line within each section.
    Returns (list_of_{id,status}, err_or_None)."""
    t = read_text(path)
    if t is None:
        return [], None
    # Skip frontmatter for scan
    body = t
    if t.startswith("---"):
        end = t.find("\n---", 3)
        if end == -1:
            return [], "parse-failure"
        body = t[end+4:]
    # Find all task headings with their offsets, then slice sections
    headings = [(m.group(1), m.start()) for m in TASK_HEADING.finditer(body)]
    out = []
    for i, (tid, offset) in enumerate(headings):
        end = headings[i+1][1] if i+1 < len(headings) else len(body)
        section = body[offset:end]
        sm = STATUS_LINE.search(section)
        status = ""
        if sm:
            raw = sm.group(1).strip()
            # Strip italic/markdown emphasis markers, trim
            raw = raw.strip("*").strip("_").strip()
            # Normalize "done (2026-04-21 — ...)" trailing annotations to just the head token
            m2 = re.match(r"([A-Za-z-]+)", raw)
            status = m2.group(1) if m2 else raw
        out.append({"id": tid, "status": status})
    return out, None

# --- normalization ------------------------------------------------------------

def norm(s):
    return (s or "").strip().lower()

COMPLETE_SET = {"complete", "completed", "done", "implemented"}
PENDING_SET = {"not-started", "not started", "pending", "planned", "todo"}
INFLIGHT_SET = {"in-progress", "in progress", "active", "wip"}

def is_complete(s):
    return norm(s) in COMPLETE_SET

def is_pending(s):
    return norm(s) in PENDING_SET

def is_inflight(s):
    return norm(s) in INFLIGHT_SET

# --- walk ---------------------------------------------------------------------

counts = {
    "spec-manifest-divergence": 0,
    "trinity-task-ledger-lag": 0,
    "header-trinity-divergence": 0,
    "parse-failure": 0,
}
inspected = 0

def inspect_dir(dirpath):
    global inspected
    spec_p = os.path.join(dirpath, "spec.md")
    manifest_p = os.path.join(dirpath, "manifest.json")
    tasks_p = os.path.join(dirpath, "tasks.md")
    if not (os.path.isfile(spec_p) and os.path.isfile(manifest_p)):
        return
    inspected += 1
    rel = os.path.relpath(dirpath, plans_scope)

    spec_s, spec_err = parse_fm_status(spec_p)
    manifest_s, manifest_err = parse_manifest_status(manifest_p)
    has_tasks = os.path.isfile(tasks_p)
    tasks_s, tasks_err = parse_fm_status(tasks_p) if has_tasks else ("", None)
    ledger, ledger_err = parse_task_ledger(tasks_p) if has_tasks else ([], None)

    errs = [e for e in (spec_err, manifest_err, tasks_err, ledger_err) if e]
    if errs:
        emit({
            "finding": "trinity-status-drift",
            "file": rel,
            "drift_class": "parse-failure",
            "spec_status": spec_s,
            "manifest_status": manifest_s,
            "tasks_status": tasks_s,
            "task_ledger": ledger,
            "parse_errors": errs,
            "detected_at": iso_now,
        })
        counts["parse-failure"] += 1
        return

    # Rule: spec.status != manifest.status (normalized)
    if norm(spec_s) and norm(manifest_s) and norm(spec_s) != norm(manifest_s):
        # Tolerate complete/done synonyms
        if not (is_complete(spec_s) and is_complete(manifest_s)):
            emit({
                "finding": "trinity-status-drift",
                "file": rel,
                "drift_class": "spec-manifest-divergence",
                "spec_status": spec_s,
                "manifest_status": manifest_s,
                "tasks_status": tasks_s,
                "task_ledger": ledger,
                "detected_at": iso_now,
            })
            counts["spec-manifest-divergence"] += 1

    # Rule: manifest.complete AND any T-N.status != done → lag
    if is_complete(manifest_s) and has_tasks:
        lagging = [x for x in ledger if not is_complete(x["status"])]
        if lagging:
            emit({
                "finding": "trinity-status-drift",
                "file": rel,
                "drift_class": "trinity-task-ledger-lag",
                "spec_status": spec_s,
                "manifest_status": manifest_s,
                "tasks_status": tasks_s,
                "task_ledger": ledger,
                "lagging_tasks": lagging,
                "detected_at": iso_now,
            })
            counts["trinity-task-ledger-lag"] += 1

    # Rule: spec.complete but tasks.planned (in-flight exclusion handled here)
    if is_complete(spec_s) and has_tasks and is_pending(tasks_s):
        # Only emit if we haven't already emitted a lag finding for this dir
        # (keep signals independent — both can be true but header-divergence
        # is a distinct symptom of the same root cause)
        emit({
            "finding": "trinity-status-drift",
            "file": rel,
            "drift_class": "header-trinity-divergence",
            "spec_status": spec_s,
            "manifest_status": manifest_s,
            "tasks_status": tasks_s,
            "task_ledger": ledger,
            "detected_at": iso_now,
        })
        counts["header-trinity-divergence"] += 1

# Walk depth 2 (plan-root) and depth 3 (sub-plan-root)
try:
    for entry in sorted(os.listdir(plans_scope)):
        if entry.startswith("."):
            continue
        if entry.startswith("_"):
            continue
        plan_dir = os.path.join(plans_scope, entry)
        if not os.path.isdir(plan_dir):
            continue
        # Depth 2
        inspect_dir(plan_dir)
        # Depth 3 (sub-plans)
        for sub in sorted(os.listdir(plan_dir)):
            if sub.startswith(".") or sub.startswith("_"):
                continue
            sub_dir = os.path.join(plan_dir, sub)
            if not os.path.isdir(sub_dir):
                continue
            if sub in ("tests", "_orchestrator"):
                continue
            inspect_dir(sub_dir)
except FileNotFoundError:
    pass

if dry_run:
    total = sum(counts.values())
    print("trinity-drift-detect: inspected=%d total=%d counts=%s" % (inspected, total, dict(counts)))

PY
