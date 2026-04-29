#!/bin/bash
# architect-triage — Surface unresolved architect recommendations as System
# Backlog candidates. Dedupe against current Backlog + manifest state.
#
# Landed: Plan 63 Sub-plan 02 T-6 (2026-04-21). Extracted from SKILL.md
# L1296-1378 pseudocode.
#
# Usage:
#   architect-triage.sh              # --check (default, report only)
#   architect-triage.sh --check
#   architect-triage.sh --apply      # write approved Backlog entries (not in this dispatch)
#
# Scope:
#   - Glob: $ARCHITECT_LOGS_GLOB (default "$VAULT_LOGS/architect-*.md").
#     Includes archived logs by adding Archive/Logs/**.
#   - Backlog: $SYSTEM_BACKLOG_PATH (default "$VAULT_ROOT/System Backlog.md").
#   - Manifest: architect_recommendations subtree via manifest_set.
#
# Extracts `[R-NNN]` + title + **Category:**/**Confidence:** fields.
# Dedupe:
#   - Current Backlog: grep R-NNN in Notes column.
#   - Manifest architect_recommendations[].id with status in
#     {deferred, rejected, completed, tracked}.
#
# Env overrides (testing): ARCHITECT_LOGS_GLOB, SYSTEM_BACKLOG_PATH,
# MANIFEST_PATH, FINDINGS_OUTPUT.
# Bash 3.2 clean; heavy logic in Python heredoc (argv-based per T-3 precedent).

set -u
set -o pipefail

if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.claude/hooks/lib/paths.sh"
fi
# shellcheck source=/dev/null
source "$HOME/.claude/skills/librarian/lib/findings.sh"
# shellcheck source=/dev/null
source "$HOME/.claude/skills/librarian/lib/manifest.sh"
# shellcheck source=/dev/null
source "$HOME/.claude/skills/librarian/lib/dates.sh"

MODE="check"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --apply) MODE="apply"; shift ;;
    --dry-run) MODE="check"; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "architect-triage: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

LOGS_GLOB="${ARCHITECT_LOGS_GLOB:-$VAULT_LOGS/architect-*.md}"
BACKLOG_PATH_RES="${SYSTEM_BACKLOG_PATH:-$VAULT_ROOT/System Backlog.md}"

# architect-triage is --check-only by default; --apply guard (never fires in
# this dispatch — main session authorizes Backlog writes).
if [[ "$MODE" == "apply" ]]; then
  echo "architect-triage: --apply is not enabled in this extraction. Run --check." >&2
  exit 4
fi

# Existing manifest state for dedupe.
EXISTING_MANIFEST=$(manifest_get '.architect_recommendations' '{}')
LAST_SCANNED=$(manifest_get '.architect_recommendations.last_scanned_log' '')

# Single Python pass: glob logs, extract recs, dedupe vs backlog+manifest,
# return a summary JSON blob + per-rec lines.
RESULT=$(python3 - "$LOGS_GLOB" "$BACKLOG_PATH_RES" "$EXISTING_MANIFEST" <<'PY'
import glob, json, os, re, sys
from pathlib import Path

logs_glob = sys.argv[1]
backlog_path = sys.argv[2]
try:
    existing = json.loads(sys.argv[3]) if sys.argv[3] else {}
except Exception:
    existing = {}

# Expand glob (support expansion in the env value).
log_files = sorted(glob.glob(os.path.expanduser(logs_glob)))

# Read backlog text for dedupe.
backlog_text = ""
if os.path.isfile(backlog_path):
    try:
        backlog_text = open(backlog_path, errors="replace").read()
    except Exception:
        pass

backlog_rec_ids = set(m.group(0) for m in re.finditer(r"R-\d+", backlog_text))

# Previously-triaged manifest state.
prior_recs = {}
for r in (existing.get("recommendations") or []):
    rid = r.get("id")
    if rid:
        prior_recs[rid] = r

HEAD_RE = re.compile(r"^\*\*\[R-(\d+)\]\s+([^*]+?)\*\*\s*(?:`\[([A-Za-z\-]+)\]`)?", re.M)
CAT_RE = re.compile(r"^\*\*Category:\*\*\s*(.+)$", re.M)
CONF_RE = re.compile(r"^\*\*Confidence:\*\*\s*(.+)$", re.M)

all_recs = []  # {id, title, category, confidence, source_log, line}
seen_ids = set()

# Walk files newest-first (filename is ISO-ish date, sort by name reversed).
for lf in sorted(log_files, reverse=True):
    try:
        text = open(lf, errors="replace").read()
    except Exception:
        continue
    source = os.path.basename(lf)
    for m in HEAD_RE.finditer(text):
        num = m.group(1)
        rid = f"R-{int(num):03d}"
        if rid in seen_ids:
            continue
        seen_ids.add(rid)
        title = m.group(2).strip()
        tag = (m.group(3) or "").strip().lower()
        # Look for **Category:** and **Confidence:** within 15 lines after the heading.
        body_start = m.end()
        body_end = min(len(text), body_start + 2000)
        body = text[body_start:body_end]
        cat_m = CAT_RE.search(body)
        conf_m = CONF_RE.search(body)
        category = (cat_m.group(1).strip() if cat_m else tag or "unknown")
        confidence = (conf_m.group(1).strip() if conf_m else "")
        all_recs.append({
            "id": rid,
            "title": title,
            "category": category,
            "confidence": confidence,
            "source_log": source,
        })

# Categorize: untracked / already_in_backlog / already_in_manifest_tracked / deferred / rejected / completed.
untracked = []
backlog_matches = []
manifest_matches = []

for r in all_recs:
    rid = r["id"]
    in_backlog = rid in backlog_rec_ids
    in_manifest = rid in prior_recs
    if in_manifest:
        status = prior_recs[rid].get("status", "tracked")
        r["status"] = status
        r["in_backlog"] = in_backlog
        manifest_matches.append(r)
    elif in_backlog:
        r["status"] = "in_backlog_untracked"
        r["in_backlog"] = True
        backlog_matches.append(r)
    else:
        r["status"] = "untracked"
        r["in_backlog"] = False
        untracked.append(r)

# Find newest log for last_scanned_log.
last_log = os.path.basename(log_files[-1]) if log_files else ""

out = {
    "logs_scanned": len(log_files),
    "recommendations_found": len(all_recs),
    "untracked": untracked,
    "backlog_matches": backlog_matches,
    "manifest_matches": manifest_matches,
    "last_scanned_log": last_log,
}
print(json.dumps(out))
PY
)

# Emit findings for untracked + build manifest subtree.
python3 - "$RESULT" <<'PY' > /tmp/architect-triage-emit.$$
import json, sys, os
doc = json.loads(sys.argv[1])
findings_out = os.environ.get("FINDINGS_OUTPUT", "")
# Emit per-untracked finding.
def emit(rec, level="info"):
    line = json.dumps({
        "finding": "architect-recommendation-untracked",
        "file": rec["source_log"],
        "id": rec["id"],
        "title": rec["title"],
        "category": rec["category"],
        "level": level,
    })
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        print(line)
for rec in doc["untracked"]:
    emit(rec, "info")
PY
rm -f /tmp/architect-triage-emit.$$

# Build + persist manifest subtree.
SUMMARY=$(python3 - "$RESULT" <<'PY'
import json, sys, datetime
doc = json.loads(sys.argv[1])
subtree = {
    "last_scan": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"),
    "last_scanned_log": doc["last_scanned_log"],
    "logs_scanned": doc["logs_scanned"],
    "recommendations": (
        [{"id": r["id"], "title": r["title"], "source_log": r["source_log"],
          "category": r["category"], "status": r["status"],
          "backlog_entry": r.get("in_backlog", False),
          "last_checked": datetime.date.today().isoformat()}
         for r in (doc["untracked"] + doc["backlog_matches"] + doc["manifest_matches"])]
    ),
}
print(len(doc["untracked"]))
print(len(doc["backlog_matches"]))
print(len(doc["manifest_matches"]))
print(doc["logs_scanned"])
print(doc["recommendations_found"])
print(json.dumps(subtree))
PY
)
UNTRACKED_N=$(echo "$SUMMARY" | sed -n '1p')
BACKLOG_N=$(echo "$SUMMARY" | sed -n '2p')
MANIFEST_N=$(echo "$SUMMARY" | sed -n '3p')
LOGS_N=$(echo "$SUMMARY" | sed -n '4p')
TOTAL_N=$(echo "$SUMMARY" | sed -n '5p')
SUBTREE=$(echo "$SUMMARY" | sed -n '6p')

manifest_set '.architect_recommendations' "$SUBTREE"

# Report.
printf "## Architect Triage (%d logs scanned, %d recommendations found)\n\n" \
  "$LOGS_N" "$TOTAL_N"
printf -- "- Untracked (surface for Backlog): %d\n" "$UNTRACKED_N"
printf -- "- Already in Backlog (tracked via row): %d\n" "$BACKLOG_N"
printf -- "- Tracked in manifest (prior triage): %d\n" "$MANIFEST_N"

if [[ "$UNTRACKED_N" -gt 0 ]]; then
  printf "\n### Untracked Recommendations\n\n"
  python3 - "$RESULT" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
print("| ID | Title | Category | Source Log |")
print("|---|---|---|---|")
for r in doc["untracked"]:
    print(f"| {r['id']} | {r['title'][:80]} | {r['category']} | {r['source_log']} |")
PY
fi
