#!/bin/bash
# placement-validate — Check that every file is in the correct location per routing rules.
#
# Sources `lib/findings.sh`.
#
# Rules per SKILL.md:
#   1. Vault root allowlist: CLAUDE.md, Vault Architecture.md, Tasks.md,
#      System Backlog.md, System Backlog - Archive.md
#   2. Project folders: only `{Project} - *.md` + `_index.md` + `File-Index.md`
#   3. People files: must be in Engagements/*/People/
#   4. Meeting notes: must be in Meetings/
#   5. Engagement root: 4 standard files + CLAUDE.md + _index.md + File-Index.md
#   6. Reference/ (Tier 1): no engagement-specific files
#   7. Logs/ allowed patterns: dated logs + build-* + ideation-brief-* symlinks
#      (frontmatter-enforce must skip ideation-brief-*.md)
#
# Index File Convention (always allowed):
#   - _index.md at any directory root
#   - File-Index.md at engagement + project roots
#   - Logs/ideation-brief-*.md (symlinks to plan-tree ideation briefs)
#
# CLI:
#   placement-validate.sh                     # emit findings
#   placement-validate.sh --scope <path>      # narrow scope
#   placement-validate.sh --dry-run           # summary counts only
#
# Bash 3.2 clean per R-23.

set -euo pipefail

if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
fi
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/lib/findings.sh"
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/lib/user-manifest-read.sh"

SCOPE=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "placement-validate: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

SCOPE_ROOT="${SCOPE:-$VAULT_ROOT}"

# Read user-extension Logs/ subdirectory whitelist from manifest. Foundation
# ships an empty list; users append the operationally-meaningful subdirectories
# their librarian instances emit into Logs/ (e.g. backlog-progress/, etc.).
LOGS_WHITELIST_SUBDIRS=$(umr_get_array '.vault.logs_whitelist_subdirs' | tr '\n' '|')
export LOGS_WHITELIST_SUBDIRS

python3 - "$SCOPE_ROOT" "$DRY_RUN" <<'PY'
import json, os, re, sys

scope_root, dry_run_s = sys.argv[1:3]
dry_run = (dry_run_s == "true")
findings_out = os.environ.get("FINDINGS_OUTPUT", "")

def emit(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

# Vault root allowlist (canonical 5 per CLAUDE.md) + index-file convention
VAULT_ROOT_ALLOWLIST = {
    "CLAUDE.md", "Vault Architecture.md",
    "System Backlog.md", "System Backlog - Archive.md",
    "_index.md", "File-Index.md",
}

# Engagement-root allowlist — pattern-based
ENGAGEMENT_STANDARD = re.compile(r"^(CLAUDE\.md|_index\.md|File-Index\.md|.+ - (Overview|Updates|Reference|PRD|Context)\.md)$")

# Project-folder allowlist — pattern-based
PROJECT_ALLOWLIST = re.compile(r"^(_index\.md|File-Index\.md|.+ - .+\.md)$")

# Logs/ allowed patterns. Two arms:
#   1. Explicit category prefixes (early-match performance — extend as needed).
#   2. Date-bearing suffix anywhere before .md (catch-all for any well-formed
#      dated log filename).
LOGS_PATTERNS = re.compile(
    r"^(?:"
    r"(digest-|session-|librarian-|build-|ideation-brief-|"
    r"manifest-staleness-|drift-sweep-|tag-coverage-audit-|"
    r"wikilink-repair-|reconcile-|audit-|2026-|2025-|2024-)"
    r"|"
    # Date-bearing suffix anywhere before .md:
    # -YYYY-MM-DD, -YYYYMMDD, -YYYYMMDD-HHMMSS, -YYYY-MM-DDTHH...
    r".+-(?:20\d{2}-\d{2}-\d{2}|20\d{6})(?:[T-]\d[^/]*)?\.md$"
    r")"
)

# Logs/ sub-directories that are whitelisted infrastructure. Sourced from
# manifest.vault.logs_whitelist_subdirs[] (pipe-separated via env). Foundation
# ships empty.
_w = os.environ.get("LOGS_WHITELIST_SUBDIRS", "").rstrip("|")
LOGS_WHITELIST_DIRS = tuple(
    (s if s.endswith("/") else s + "/") for s in _w.split("|") if s
)
LOGS_WHITELIST_BASENAME_PREFIXES = ("_session-",)

# Directories to skip entirely
SKIP_DIRS = ("Archive", ".git", ".claude", ".obsidian", "_test")

findings_count = 0
scanned = 0

for dirpath, dirnames, filenames in os.walk(scope_root):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith('.')]
    rel_dir = os.path.relpath(dirpath, scope_root)

    for fn in filenames:
        if fn.startswith("."):
            continue
        if not (fn.endswith(".md") or fn == "File-Index.md"):
            continue
        scanned += 1
        rel = os.path.join(rel_dir, fn) if rel_dir != "." else fn

        # --- Rule 1: Vault root allowlist
        if rel_dir == ".":
            if fn not in VAULT_ROOT_ALLOWLIST:
                emit({"finding": "placement-violation", "file": rel,
                      "issue": "File at vault root (not in allowlist)",
                      "suggested_location": "Move to appropriate subfolder",
                      "classification": "manual"})
                findings_count += 1
            continue

        # --- Rule 3: People files must be in Engagements/*/People/
        fm_snip = ""
        try:
            fm_snip = open(os.path.join(dirpath, fn)).read(1024)
        except Exception:
            pass
        is_people = bool(re.search(r"^type:\s*people\s*$", fm_snip, re.MULTILINE))
        if is_people and "/People/" not in "/" + rel.replace("\\", "/"):
            emit({"finding": "placement-violation", "file": rel,
                  "issue": "People file outside Engagements/*/People/",
                  "suggested_location": "Engagements/<name>/People/",
                  "classification": "auto-fix"})
            findings_count += 1
            continue

        # --- Rule 4: Meeting notes must be in Meetings/
        is_meeting = bool(re.search(r"^type:\s*meeting-note\s*$", fm_snip, re.MULTILINE))
        if is_meeting and not rel.startswith("Meetings/"):
            emit({"finding": "placement-violation", "file": rel,
                  "issue": "Meeting note outside Meetings/",
                  "suggested_location": "Meetings/",
                  "classification": "auto-fix"})
            findings_count += 1
            continue

        # --- Rule 2: Project folder allowlist — file directly inside Projects/<proj>/
        m_proj = re.match(r"^Engagements/([^/]+)/Projects/([^/]+)/([^/]+)$", rel)
        if m_proj:
            proj_slug = m_proj.group(2)
            basename = m_proj.group(3)
            if not PROJECT_ALLOWLIST.match(basename):
                emit({"finding": "placement-violation", "file": rel,
                      "issue": f"Non-project-scoped file in Projects/{proj_slug}/",
                      "suggested_location": f"Rename to '{proj_slug} - <Topic>.md' or move",
                      "classification": "manual"})
                findings_count += 1
                continue

        # --- Rule 5: Engagement root allowlist
        m_eng = re.match(r"^Engagements/([^/]+)/([^/]+)$", rel)
        if m_eng:
            if not ENGAGEMENT_STANDARD.match(m_eng.group(2)):
                emit({"finding": "placement-violation", "file": rel,
                      "issue": "Non-standard file in engagement root",
                      "suggested_location": "Move to Projects/, Strategic/, Planning/, or rename to {Eng} - * pattern",
                      "classification": "manual"})
                findings_count += 1
                continue

        # --- Rule 7: Logs/ allowed patterns
        if rel_dir == "Logs" or rel_dir.startswith("Logs/"):
            # Allow _index.md, File-Index.md, and patterns above
            if fn in ("_index.md", "File-Index.md"):
                continue
            # Whitelisted sub-directories — legitimate infrastructure.
            sub = rel_dir[len("Logs/"):] + "/" if rel_dir.startswith("Logs/") else ""
            if any(sub.startswith(p) for p in LOGS_WHITELIST_DIRS):
                continue
            # Whitelisted basename prefixes (e.g. _session-* inventory files).
            if any(fn.startswith(p) for p in LOGS_WHITELIST_BASENAME_PREFIXES):
                continue
            if not LOGS_PATTERNS.match(fn):
                emit({"finding": "placement-violation", "file": rel,
                      "issue": "Non-dated / non-pattern file in Logs/",
                      "suggested_location": "Rename to match {log-type}-{date}-*.md pattern or move out of Logs/",
                      "classification": "manual"})
                findings_count += 1
                continue

if dry_run:
    print("placement-validate: scanned=%d findings=%d" % (scanned, findings_count))
PY

# === R-15 promotion: backlog-row-missing ====================================
# Session-close finding: plan-root writes (spec.md/tasks.md/manifest.json) must
# have a corresponding row in System Backlog.md. Scans $PLANS_DIR plan roots
# against the backlog file. Non-blocking finding.
# Scoped to plans that have been touched in last 7d (avoid re-emitting for
# already-closed plans with historical rows missing — future-catch only).
SEVENDAYS=$((7*86400))
PLANS_DIR="${PLANS_DIR:-$HOME/.claude-plans}"
BACKLOG_FILE="${BACKLOG_FILE:-$VAULT_ROOT/System Backlog.md}"

if [[ -d "$PLANS_DIR" ]] && [[ -f "$BACKLOG_FILE" ]]; then
  python3 - "$PLANS_DIR" "$BACKLOG_FILE" "$SEVENDAYS" <<'PY'
import os, sys, re, json, time

plans_dir, backlog_file, sevendays_s = sys.argv[1:4]
sevendays = int(sevendays_s)
now = time.time()
findings_out = os.environ.get("FINDINGS_OUTPUT", "")

def emit(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

try:
    with open(backlog_file) as f:
        backlog = f.read()
except Exception:
    sys.exit(0)

# Also include the archive file — completed plans get moved to
# "System Backlog - Archive.md", and we shouldn't re-flag them just because
# the archive move put their slug out of the live file.
archive_file = backlog_file.replace("System Backlog.md", "System Backlog - Archive.md")
try:
    with open(archive_file) as f:
        backlog += "\n" + f.read()
except Exception:
    pass

# Walk plan roots (top-level directories under PLANS_DIR starting with NN-slug)
pattern = re.compile(r"^\d{2,3}-[a-z0-9-]+$")
for name in sorted(os.listdir(plans_dir)):
    full = os.path.join(plans_dir, name)
    if not os.path.isdir(full):
        continue
    if not pattern.match(name):
        continue
    # Check recency — skip plans whose spec.md mtime is older than 7d
    spec_path = os.path.join(full, "spec.md")
    if not os.path.isfile(spec_path):
        continue
    age = now - os.path.getmtime(spec_path)
    if age > sevendays:
        continue
    # Derive plan slug (strip NN- prefix)
    slug = re.sub(r"^\d+-", "", name)
    # Check backlog for a row mentioning the slug or folder name
    if slug in backlog or name in backlog:
        continue
    emit({"finding": "backlog-row-missing", "file": f"{os.path.basename(plans_dir)}/{name}/",
          "issue": f"Plan '{name}' written within last 7d has no row in System Backlog.md",
          "suggested_location": f"Add row referencing 'plan: {name}/' to System Backlog.md",
          "classification": "manual"})
PY
fi
# === end R-15 promotion ======================================================
