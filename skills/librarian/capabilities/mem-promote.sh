#!/bin/bash
# mem-promote — Shell prefilter for promoting claude-mem observations to
# auto-memory.
#
# Tier 3 hybrid (peer to memory-hygiene). Shell handles Phase 1 (claude-mem
# query per session scope) + Phase 2 (Jaccard-cluster subject consolidation +
# dedup against current memory/*.md file list); emits NDJSON candidates.
# Claude synthesizes Phase 3 (proposal generation) + Phase 4 (cross-ref
# annotation).
#
# NDJSON schema per `tests/prefilter-contract.md §1` mem-promote:
#   { "capability": "mem-promote",
#     "check": "promotion-candidate",
#     "candidate_id": "<SHA256(capability|check|subject)[:16]>",
#     "subject": "<inferred subject title>",
#     "evidence": {
#       "session_id": "<JSONL session UUID>",
#       "session_end": "<ISO timestamp>",
#       "sessions": [{"session_id","session_end"}, ...],
#       "observations": ["<obs passage 1>", ...],
#       "existing_memory_matches": [{"file": "<memory/...>", "subject_hash": "..."}],
#       "dedup_decision": "novel|variant|duplicate",
#       "pair_confirmed": true|false
#     },
#     "score": 0.0-1.0,
#     "notes": "<one-line hint>" }
#
# Tier: judgment. Output Contract: block-and-log + requires_confirmation.
# Cron block: skip-non-interactive. Exits 0 with a "skipped (non-interactive)"
# log line when invoked outside a TTY session and FOUNDATION_TEST_MODE unset.
#
# CLI:
#   mem-promote.sh --session <path>              # one session JSONL (repeatable)
#   mem-promote.sh --session-glob '<pattern>'    # glob pattern for sessions
#   mem-promote.sh --dry-run                     # summary counts only
#   mem-promote.sh --help                        # usage
#
# Env overrides:
#   MEM_SESSION_PATH         One or more JSONL paths, colon-separated (test mode).
#   MEMORY_DIR               Override session memory dir (else resolved via
#                            lib/paths.sh::resolve_memory_dir — cwd-slug-derived
#                            $CLAUDE_HOME/projects/<slug>/memory).
#   CLAUDE_MEM_DB            (default: $HOME/.claude-mem/claude-mem.db)
#   FINDINGS_OUTPUT          (default: stdout)
#   MEM_PROMOTE_CLUSTER_THRESHOLD  Jaccard threshold for subject clustering (default: 0.5)
#   FOUNDATION_TEST_MODE     Bypass non-interactive guard (test/CI runners).
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

SESSIONS=""
SESSION_GLOB=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SESSIONS="${SESSIONS}:$2"; shift 2 ;;
    --session-glob) SESSION_GLOB="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "mem-promote: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Judgment-tier non-interactive guard. Bypassed by FOUNDATION_TEST_MODE so
# synthetic harnesses can fire the capability without a controlling TTY.
if [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  echo "mem-promote: skipped (non-interactive)" >&2
  exit 0
fi

if [[ -z "$SESSIONS" && -n "${MEM_SESSION_PATH:-}" ]]; then
  SESSIONS="${MEM_SESSION_PATH}"
fi

if [[ -n "$SESSION_GLOB" ]]; then
  for f in $SESSION_GLOB; do
    if [[ -f "$f" ]]; then
      SESSIONS="${SESSIONS}:${f}"
    fi
  done
fi

SESSIONS="${SESSIONS#:}"

if [[ -n "${MEMORY_DIR:-}" ]]; then
  : # caller-set override wins
elif command -v resolve_memory_dir >/dev/null 2>&1; then
  MEMORY_DIR="$(resolve_memory_dir)"
else
  MEMORY_DIR=""
fi
case "$MEMORY_DIR" in
  */) : ;;
  *) MEMORY_DIR="$MEMORY_DIR/" ;;
esac
CLAUDE_MEM_DB="${CLAUDE_MEM_DB:-$HOME/.claude-mem/claude-mem.db}"
CLUSTER_THRESHOLD="${MEM_PROMOTE_CLUSTER_THRESHOLD:-0.5}"

if [[ -z "$SESSIONS" ]]; then
  echo "mem-promote: no sessions specified (use --session, --session-glob, or MEM_SESSION_PATH env)" >&2
  exit 0
fi

if [[ ! -f "$CLAUDE_MEM_DB" ]]; then
  echo "mem-promote: claude-mem DB not found at $CLAUDE_MEM_DB" >&2
  exit 0
fi

python3 - "$SESSIONS" "$MEMORY_DIR" "$CLAUDE_MEM_DB" "$DRY_RUN" "$CLUSTER_THRESHOLD" <<'PY'
import hashlib, json, os, re, sqlite3, sys

sessions_raw = sys.argv[1]
memory_dir = sys.argv[2]
db_path = sys.argv[3]
dry_run = (sys.argv[4] == "true")
try:
    cluster_threshold = float(sys.argv[5])
except ValueError:
    cluster_threshold = 0.5

findings_out = os.environ.get("FINDINGS_OUTPUT", "")
session_paths = [p for p in sessions_raw.split(":") if p]

STOP_WORDS = set(("the a an of to for and or with in on at by from is are was were "
                  "be been being manually auto automatically new old via using "
                  "after before into out as but not so than then also this that these those "
                  "shipped added created built extracted fixed updated changed introduced "
                  "landed implemented resolved initiated wired flipped verified validated "
                  "documented archived marked written decomposed complete completed finished "
                  "done now next all any some each both more less most least same other").split())

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

def tokens_of(text):
    if not text:
        return set()
    t = text.lower()
    t = re.sub(r'[^a-z0-9]+', ' ', t)
    return set(w for w in t.split() if len(w) >= 3 and w not in STOP_WORDS)

def normalize_title(title):
    if not title:
        return ""
    t = title.lower().strip()
    t = re.sub(r'[^a-z0-9]+', ' ', t)
    t = re.sub(r'\s+', ' ', t).strip()
    return t

def subject_hash(title):
    return hashlib.sha256(normalize_title(title).encode("utf-8")).hexdigest()[:16]

def parse_fm_title(path):
    try:
        t = open(path).read()
    except Exception:
        return "", ""
    if not t.startswith("---"):
        return "", ""
    end = t.find("\n---", 3)
    if end == -1:
        return "", ""
    fm_raw = t[3:end]
    name, desc = "", ""
    for line in fm_raw.split("\n"):
        m = re.match(r'^(name|description)\s*:\s*(.*)$', line.strip())
        if m:
            v = m.group(2).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
                v = v[1:-1]
            if m.group(1) == "name":
                name = v
            else:
                desc = v
    return name, desc

existing = []  # list of (filename, title, tokens)
if os.path.isdir(memory_dir):
    for fn in sorted(os.listdir(memory_dir)):
        if not fn.endswith(".md") or fn == "MEMORY.md":
            continue
        full = os.path.join(memory_dir, fn)
        if not os.path.isfile(full):
            continue
        name, desc = parse_fm_title(full)
        if name:
            title = name
        else:
            title = re.sub(r'^(user_|feedback_|project_|reference_)', '', fn[:-3]).replace("_", " ")
        existing.append((fn, title, tokens_of(title + " " + desc)))

# ---------- Load observations ----------
try:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
except Exception as e:
    sys.stderr.write("mem-promote: cannot open claude-mem DB: %s\n" % e)
    sys.exit(0)

def session_id_from_path(p):
    base = os.path.basename(p)
    if base.endswith(".jsonl"):
        base = base[:-6]
    return base

def memory_session_for(content_session_id):
    cur = conn.cursor()
    cur.execute("SELECT memory_session_id, completed_at FROM sdk_sessions WHERE content_session_id=?", (content_session_id,))
    row = cur.fetchone()
    if row:
        return row["memory_session_id"], row["completed_at"] or ""
    return None, ""

def observations_for(mem_sess_id):
    cur = conn.cursor()
    cur.execute("""
        SELECT id, type, title, subtitle, facts, narrative, created_at
          FROM observations
         WHERE memory_session_id=?
         ORDER BY id ASC
    """, (mem_sess_id,))
    return list(cur.fetchall())

all_obs = []  # list of dicts with session + obs
per_session_count = {}

for sp in session_paths:
    csid = session_id_from_path(sp)
    msid, ended = memory_session_for(csid)
    per_session_count[csid] = 0
    if not msid:
        sys.stderr.write("mem-promote: no memory_session mapping for %s (skipping)\n" % csid)
        continue
    obs = observations_for(msid)
    per_session_count[csid] = len(obs)
    for o in obs:
        title = (o["title"] or "").strip()
        if not title:
            continue
        subtitle = (o["subtitle"] or "").strip()
        narrative = (o["narrative"] or "").strip()
        facts = (o["facts"] or "").strip()
        # Token set drawn from title + subtitle for consolidation
        tks = tokens_of(title + " " + subtitle)
        passage = title
        if subtitle:
            passage = "%s — %s" % (passage, subtitle)
        if narrative:
            passage = "%s\n\n%s" % (passage, narrative[:600])
        all_obs.append({
            "session_id": csid,
            "session_end": ended,
            "id": o["id"],
            "type": o["type"],
            "title": title,
            "subtitle": subtitle,
            "narrative_excerpt": narrative[:400],
            "facts_excerpt": facts[:400],
            "created_at": o["created_at"],
            "passage": passage,
            "tokens": tks,
        })

conn.close()

scanned = len(all_obs)

# ---------- Cluster observations by Jaccard(tokens) ≥ threshold (union-find) ----------
def jaccard(a, b):
    if not a or not b:
        return 0.0
    inter = a & b
    uni = a | b
    if not uni:
        return 0.0
    return len(inter) / float(len(uni))

parent = list(range(len(all_obs)))
def find(x):
    while parent[x] != x:
        parent[x] = parent[parent[x]]
        x = parent[x]
    return x
def union(a, b):
    ra, rb = find(a), find(b)
    if ra != rb:
        parent[rb] = ra

# For performance, cap cluster edge-building via blocking on shared high-signal tokens.
# Build inverted index token -> list of obs indices; only compare pairs that share ≥2 tokens
token_index = {}
for i, o in enumerate(all_obs):
    for t in o["tokens"]:
        token_index.setdefault(t, []).append(i)

pairs_checked = set()
for t, idxs in token_index.items():
    if len(idxs) < 2 or len(idxs) > 200:  # skip ultra-common tokens that bloom everything
        continue
    for i in range(len(idxs)):
        for j in range(i+1, len(idxs)):
            a, b = idxs[i], idxs[j]
            if a > b:
                a, b = b, a
            if (a, b) in pairs_checked:
                continue
            pairs_checked.add((a, b))
            if jaccard(all_obs[a]["tokens"], all_obs[b]["tokens"]) >= cluster_threshold:
                union(a, b)

clusters = {}
for i in range(len(all_obs)):
    r = find(i)
    clusters.setdefault(r, []).append(i)

# ---------- For each cluster, build a candidate ----------
candidates_emitted = 0
duplicates = 0
variants = 0
novels = 0
pair_consolidated = 0
within_session_consolidated = 0

cluster_list = sorted(clusters.values(), key=lambda c: all_obs[c[0]]["created_at"] or "")

for cluster_idxs in cluster_list:
    cluster_obs = [all_obs[i] for i in cluster_idxs]
    # Pick representative title: shortest, to avoid runaway
    rep = min(cluster_obs, key=lambda o: len(o["title"]))
    subject = rep["title"]

    # Union of tokens for dedup vs existing memories
    cluster_tokens = set()
    for o in cluster_obs:
        cluster_tokens |= o["tokens"]

    # Find best existing-memory match
    best_match = None
    best_score = 0.0
    for fn, title, etoks in existing:
        if not etoks:
            continue
        sc = jaccard(cluster_tokens, etoks)
        if sc > best_score:
            best_score = sc
            best_match = (fn, title, sc)

    if best_match and best_score >= 0.6:
        dedup = "duplicate"
    elif best_match and best_score >= 0.35:
        dedup = "variant"
    else:
        dedup = "novel"

    if dedup == "duplicate":
        duplicates += 1
    elif dedup == "variant":
        variants += 1
    else:
        novels += 1

    existing_refs = []
    if best_match:
        fn, _, sc = best_match
        existing_refs.append({
            "file": fn,
            "subject_hash": subject_hash(best_match[1]),
            "match_score": round(sc, 2),
        })

    sessions_seen = {}
    for o in cluster_obs:
        sid = o["session_id"]
        if sid not in sessions_seen:
            sessions_seen[sid] = o["session_end"]
    sessions_sorted = sorted(
        [{"session_id": sid, "session_end": se} for sid, se in sessions_seen.items()],
        key=lambda s: s["session_end"] or "",
    )

    is_pair = len(sessions_sorted) > 1
    if is_pair:
        pair_consolidated += 1
    if len(cluster_obs) > 1 and not is_pair:
        within_session_consolidated += 1

    score = {"novel": 0.8, "variant": 0.5, "duplicate": 0.2}[dedup]
    if is_pair:
        score = min(1.0, score + 0.1)
    # Larger clusters (many observations) score higher
    if len(cluster_obs) >= 3:
        score = min(1.0, score + 0.05)

    cid = candidate_id("mem-promote", "promotion-candidate", subject)

    # Sort obs by created_at; cap passages at 6
    obs_sorted = sorted(cluster_obs, key=lambda o: o["created_at"] or "")
    obs_passages = [o["passage"] for o in obs_sorted[:6]]
    obs_meta = [{"id": o["id"], "type": o["type"], "title": o["title"],
                 "created_at": o["created_at"], "session_id": o["session_id"]} for o in obs_sorted[:6]]

    if dedup == "novel":
        notes = "novel promotion candidate"
    elif dedup == "variant":
        notes = "variant of existing memory: %s (jaccard %.2f)" % (best_match[0], best_score)
    else:
        notes = "likely duplicate of: %s (jaccard %.2f)" % (best_match[0], best_score)
    if is_pair:
        notes = notes + " (pair-confirmed across %d sessions, %d observations)" % (len(sessions_sorted), len(cluster_obs))
    elif len(cluster_obs) > 1:
        notes = notes + " (consolidated from %d observations)" % len(cluster_obs)

    primary = sessions_sorted[0]

    evidence = {
        "session_id": primary["session_id"],
        "session_end": primary["session_end"],
        "sessions": sessions_sorted,
        "observations": obs_passages,
        "observations_meta": obs_meta,
        "cluster_size": len(cluster_obs),
        "existing_memory_matches": existing_refs,
        "dedup_decision": dedup,
        "pair_confirmed": is_pair,
    }

    emit({
        "capability": "mem-promote",
        "check": "promotion-candidate",
        "candidate_id": cid,
        "subject": subject,
        "evidence": evidence,
        "score": round(score, 2),
        "notes": notes,
    })
    candidates_emitted += 1

# ---------- Pair-aware overlap findings ----------
# When multiple sessions are scanned, surface subject-space echoes across sessions
# that did NOT consolidate into a single cluster but share >=0.3 Jaccard on the
# union of token sets. This is the Gate A safety net per `tests/prefilter-
# contract.md` for the mem-promote adversarial pair.
pair_overlaps_emitted = 0
if len(session_paths) > 1:
    session_clusters = {}  # session_id -> [(subject, tokens)]
    for cluster_idxs in cluster_list:
        cluster_obs = [all_obs[i] for i in cluster_idxs]
        sids_in_cluster = set(o["session_id"] for o in cluster_obs)
        if len(sids_in_cluster) > 1:
            continue  # cross-session already consolidated
        only_sid = next(iter(sids_in_cluster))
        rep_title = min((o["title"] for o in cluster_obs), key=len)
        # Use rep-title tokens (not full cluster union) to avoid bloom across a cluster
        rep_toks = tokens_of(rep_title)
        session_clusters.setdefault(only_sid, []).append((rep_title, rep_toks))

    seen_overlap_subjects = set()
    session_ids = sorted(session_clusters.keys())
    for i in range(len(session_ids)):
        for j in range(i+1, len(session_ids)):
            sa, sb = session_ids[i], session_ids[j]
            for ta, toks_a in session_clusters.get(sa, []):
                for tb, toks_b in session_clusters.get(sb, []):
                    if not toks_a or not toks_b:
                        continue
                    inter = toks_a & toks_b
                    uni = toks_a | toks_b
                    if not uni:
                        continue
                    j_score = len(inter) / float(len(uni))
                    if j_score < 0.3 or len(inter) < 2:
                        continue
                    pair_subject = "|".join(sorted([ta, tb]))
                    if pair_subject in seen_overlap_subjects:
                        continue
                    seen_overlap_subjects.add(pair_subject)
                    pcid = candidate_id("mem-promote", "pair-overlap", pair_subject)
                    emit({
                        "capability": "mem-promote",
                        "check": "pair-overlap",
                        "candidate_id": pcid,
                        "subject": pair_subject,
                        "evidence": {
                            "session_a": sa,
                            "session_b": sb,
                            "subject_a": ta,
                            "subject_b": tb,
                            "shared_tokens": sorted(list(inter)),
                            "jaccard": round(j_score, 2),
                            "drift_class": "pair-overlap",
                        },
                        "score": round(0.4 + min(0.4, j_score), 2),
                        "notes": "cross-session subject echo: shared tokens %s (jaccard %.2f) - claude should evaluate whether to merge or keep separate" % (sorted(list(inter))[:5], j_score),
                    })
                    pair_overlaps_emitted += 1

if dry_run:
    print("mem-promote: sessions=%d scanned_obs=%d clusters=%d candidates=%d novel=%d variant=%d duplicate=%d pair_consolidated=%d within_session_consolidated=%d pair_overlaps=%d per_session=%s" % (
        len(session_paths), scanned, len(clusters), candidates_emitted,
        novels, variants, duplicates, pair_consolidated, within_session_consolidated,
        pair_overlaps_emitted, dict(per_session_count)
    ))
PY
