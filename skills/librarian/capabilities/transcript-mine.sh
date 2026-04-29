#!/bin/bash
# transcript-mine — Mine meeting transcripts for implicit knowledge signals.
#
# Tier 3 hybrid pattern (peer to memory-hygiene + mem-promote). Shell
# prefilter handles Phase 1 (discover transcripts) + Phase 2 (keyword
# signal extraction); emits NDJSON candidates. Phase 3 (dedup against
# memory/*.md) + Phase 4 (proposal generation) run as Claude synthesis at
# /librarian runtime.
#
# Signal categories (emit NDJSON candidates on stdout):
#   decision      — decided, approved, going with, plan is, Decision:
#                   (decision-keyword set is intentionally generic — 6 patterns;
#                   no user-name-specific phrasing)
#   preference    — prefer, want, always, never, from now on, dislike, avoid
#   action-item   — will do, owner, deadline, by <date>, follow up
#   tool-mention  — Claude, skill, script, cron, hook, librarian, memory
#   correction    — actually, correction, rephrase, take back, instead
#
# NDJSON schema per `tests/prefilter-contract.md §1`.
#
# Tier: judgment. Output Contract: block-and-log + requires_confirmation.
# Cron block: skip-non-interactive. Exits 0 with a "skipped (non-interactive)"
# log line when invoked outside a TTY session and FOUNDATION_TEST_MODE unset.
#
# CLI:
#   transcript-mine.sh                    # emit to $FINDINGS_OUTPUT or stdout
#   transcript-mine.sh --scope <path>     # override TRANSCRIPT_DIR
#   transcript-mine.sh --dry-run          # summary counts only
#   transcript-mine.sh --help             # usage
#
# Env overrides:
#   TRANSCRIPT_DIR          Override transcripts root. When unset, resolved from
#                           user-manifest.vault.transcript_dir; falls back to
#                           $VAULT_ROOT/Meetings/ when manifest field absent.
#   TRANSCRIPT_GLOB         (default: *.md)
#   FINDINGS_OUTPUT         (default: stdout)
#   USER_MANIFEST_PATH      Override user-manifest source path.
#   FOUNDATION_TEST_MODE    Bypass non-interactive guard (test/CI runners).
#
# Bash 3.2 clean per R-23. Argv-based Python heredocs per R-24.

set -euo pipefail

if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
fi
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/lib/findings.sh"
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/lib/manifest.sh"
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/lib/dates.sh"
# shellcheck source=/dev/null
source "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/lib/user-manifest-read.sh"

SCOPE=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "transcript-mine: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Judgment-tier non-interactive guard. Bypassed by FOUNDATION_TEST_MODE so
# synthetic harnesses can fire the capability without a controlling TTY.
if [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  echo "transcript-mine: skipped (non-interactive)" >&2
  exit 0
fi

# TRANSCRIPT_DIR resolution: env override > user-manifest.vault.transcript_dir
# (via lib/user-manifest-read.sh) > $VAULT_ROOT/Meetings/ install-default.
if [[ -z "${TRANSCRIPT_DIR:-}" ]]; then
  TRANSCRIPT_DIR="$(umr_get_string '.vault.transcript_dir')"
  if [[ -z "$TRANSCRIPT_DIR" ]] && [[ -n "${VAULT_ROOT:-}" ]]; then
    TRANSCRIPT_DIR="$VAULT_ROOT/Meetings"
  fi
fi
if [[ -n "$SCOPE" ]]; then
  TRANSCRIPT_DIR="$SCOPE"
fi
case "$TRANSCRIPT_DIR" in
  */) : ;;
  *) TRANSCRIPT_DIR="$TRANSCRIPT_DIR/" ;;
esac

TRANSCRIPT_GLOB="${TRANSCRIPT_GLOB:-*.md}"

if [[ ! -d "$TRANSCRIPT_DIR" ]]; then
  echo "transcript-mine: TRANSCRIPT_DIR does not exist: $TRANSCRIPT_DIR" >&2
  exit 0
fi

python3 - "$TRANSCRIPT_DIR" "$TRANSCRIPT_GLOB" "$DRY_RUN" <<'PY'
import fnmatch, hashlib, json, os, re, sys

transcript_dir = sys.argv[1]
glob_pat = sys.argv[2]
dry_run = (sys.argv[3] == "true")

findings_out = os.environ.get("FINDINGS_OUTPUT", "")

def emit(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

def candidate_id(capability, check, subject):
    h = hashlib.sha256(("%s|%s|%s" % (capability, check, subject)).encode("utf-8")).hexdigest()
    return h[:16]

# ---------- Signal keyword table ----------
# Word-boundary regex per category. Tuned to produce near-zero on
# placeholder/status-check transcripts (Gate A adversarial condition).
# Decision-keyword set: 6 generic patterns (no user-name phrasing).
CATEGORIES = [
    ("decision", [
        r"\bdecided\b", r"\bapproved\b", r"\bgoing with\b",
        r"\bthe plan is\b", r"\blet's go\b",
        r"(?m)^\s*\*\*Decision:\*\*",
    ]),
    ("preference", [
        r"\bprefer(?:s|red|ring)?\b",
        r"\bfrom now on\b", r"\bI like\b", r"\bdislike[sd]?\b",
        r"\bavoid\b",
        r"\balways\b", r"\bnever\b",
    ]),
    ("action-item", [
        r"\bwill do\b", r"\bwill (?:follow up|send|share|draft|review)\b",
        r"\bfollow[- ]up\b",
        r"\bdeadline\b", r"\bowner\b",
        r"\bby (?:\d{4}-\d{2}-\d{2}|[A-Z][a-z]+day|next week|EOD|EOW|end of)\b",
    ]),
    ("tool-mention", [
        r"\bClaude\b", r"\bskill\b", r"\bscript\b",
        r"\bcron\b", r"\bhook\b", r"\blibrarian\b", r"\bmemory\b",
    ]),
    ("correction", [
        r"\bactually\b", r"\bcorrection\b",
        r"\brephrase\b", r"\btake (?:that|it) back\b",
        r"\binstead\b",
    ]),
]

compiled = []
for cat, pats in CATEGORIES:
    for p in pats:
        compiled.append((cat, p, re.compile(p, re.IGNORECASE)))

# ---------- File discovery ----------
try:
    names = sorted(os.listdir(transcript_dir))
except Exception as e:
    sys.stderr.write("transcript-mine: cannot list %s: %s\n" % (transcript_dir, e))
    sys.exit(0)

transcripts = []
for fn in names:
    if not fnmatch.fnmatch(fn, glob_pat):
        continue
    full = os.path.join(transcript_dir, fn)
    # skip symlinks
    if os.path.islink(full):
        continue
    if not os.path.isfile(full):
        continue
    # skip archives
    lower = fn.lower()
    if "archive" in lower:
        continue
    transcripts.append((fn, full))

DATE_RX = re.compile(r'(\d{4}-\d{2}-\d{2})')

counts = {cat: 0 for cat, _ in CATEGORIES}
total = 0
files_scanned = 0

for fn, full in transcripts:
    try:
        with open(full, "r", encoding="utf-8") as f:
            raw = f.read()
    except Exception:
        continue
    files_scanned += 1

    # Strip YAML frontmatter so keyword hits do not fire on metadata.
    body = raw
    if raw.startswith("---"):
        end = raw.find("\n---", 3)
        if end != -1:
            body = raw[end+4:]
            fm_lines = raw[:end+4].count("\n") + 1
        else:
            fm_lines = 0
    else:
        fm_lines = 0

    lines = body.split("\n")

    # meeting_date from filename prefix else empty
    md = DATE_RX.search(fn)
    meeting_date = md.group(1) if md else ""

    # Dedup within-file so the same line does not fire twice per category.
    line_fired = {}

    for idx, line in enumerate(lines):
        if not line.strip():
            continue
        # Skip markdown table separator rows.
        if re.match(r'^\s*\|?[\s\-:|]+\|?\s*$', line):
            continue
        for cat, pat, rx in compiled:
            m = rx.search(line)
            if not m:
                continue
            key = (idx, cat)
            if key in line_fired:
                continue
            line_fired[key] = True
            # 2 lines of context before + after
            start = max(0, idx - 2)
            end_i = min(len(lines), idx + 3)
            passage = "\n".join(lines[start:end_i]).strip()
            abs_line = fm_lines + idx + 1
            keyword = m.group(0)
            subject = "%s:L%d" % (fn, abs_line)
            cid = candidate_id("transcript-mine", cat, subject)
            # Score: coarse density — baseline 0.6 for exact keyword match;
            # bump to 0.9 for **Decision:** leaders, 0.75 for action-items in tables.
            score = 0.6
            if cat == "decision" and "**Decision" in line:
                score = 0.9
            if cat == "action-item" and "| " in line:
                score = 0.75
            emit({
                "capability": "transcript-mine",
                "check": cat,
                "candidate_id": cid,
                "subject": subject,
                "evidence": {
                    "transcript_path": fn,
                    "meeting_date": meeting_date,
                    "passage": passage,
                    "line_number": abs_line,
                    "signal_category": cat,
                    "keyword_hit": keyword,
                },
                "score": score,
                "notes": "%s signal %r at L%d" % (cat, keyword, abs_line),
            })
            counts[cat] += 1
            total += 1

if dry_run:
    print("transcript-mine: files=%d total=%d counts=%s" % (files_scanned, total, dict(counts)))

PY
