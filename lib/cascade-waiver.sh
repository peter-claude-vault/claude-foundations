# cascade-waiver.sh — Canonical writer for $HOOKS_STATE/cascade-waivers.json.
#
# Single forward-looking writer for cascade-rule waivers. Every agent / skill /
# hook that files a waiver must source this file and call `cascade_waiver_write`.
# Reads tolerate four historical drift shapes for back-compat; writes always
# emit the canonical sessions.<id>.waivers[] form documented below.
#
# Usage:
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/cascade-waiver.sh"
#   cascade_waiver_write <entry_id> <reason>
#
#   Optional env: CLAUDE_SESSION_ID (preferred). If unset, caller may set
#   CASCADE_WAIVER_SESSION_ID for a deterministic label (e.g. a slug naming
#   the originating task). If neither is set, helper falls back to
#   "unknown-$(date +%s)".
#
# Shape contract (CANONICAL — all future writes use this shape):
#
#   {
#     "sessions": {
#       "<session-id>": {
#         "waivers": [
#           { "entry_id": "<registered-dep-id>",
#             "reason": "<free-text justification>",
#             "ts": "<YYYY-MM-DDTHH:MM:SS±HH:MM>" },
#           ...
#         ]
#       }
#     }
#   }
#
# Reads tolerate the 4 historical drift shapes on ingest — this helper only
# normalizes on write: if the session-id lands in any non-canonical shape,
# it is MOVED to sessions.<id>.waivers[] as part of the append.
#
# Bash 3.2 clean per R-23. Atomic writes via temp-file + mv.

# Idempotent paths.sh source guard.
if [[ -z "${HOOKS_STATE:-}" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
fi

CASCADE_WAIVER_PATH="${CASCADE_WAIVER_PATH:-$HOOKS_STATE/cascade-waivers.json}"

# cascade_waiver_write <entry_id> <reason>
# Appends one waiver in canonical shape under the resolved session id.
# Prints the resolved session id to stdout on success.
cascade_waiver_write() {
  local entry_id="$1"
  local reason="$2"
  if [[ -z "$entry_id" ]] || [[ -z "$reason" ]]; then
    echo "cascade_waiver_write: entry_id and reason required" >&2
    return 1
  fi
  local sid="${CLAUDE_SESSION_ID:-${CASCADE_WAIVER_SESSION_ID:-unknown-$(date +%s)}}"
  local ts
  ts=$(date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\(..\)$/:\1/')
  local tmp="${CASCADE_WAIVER_PATH}.tmp.$$"
  python3 - "$CASCADE_WAIVER_PATH" "$sid" "$entry_id" "$reason" "$ts" "$tmp" <<'PY'
import json, os, sys
path, sid, eid, reason, ts, tmp = sys.argv[1:7]
try:
    with open(path) as f:
        doc = json.load(f)
except Exception:
    doc = {}

waiver = {"entry_id": eid, "reason": reason, "ts": ts}

# Resolve the current entries list for this session, normalizing any of the
# 4 historical drift shapes to the canonical sessions.<sid>.waivers[] form.
entries = None

# (a) canonical: sessions.<sid>.waivers[]
if isinstance(doc.get("sessions"), dict):
    slot = doc["sessions"].get(sid)
    if isinstance(slot, dict) and isinstance(slot.get("waivers"), list):
        entries = slot["waivers"]
    elif isinstance(slot, list):
        # drift-A (sessions.<sid> is bare array) — migrate in place.
        entries = [e for e in slot if isinstance(e, dict)]
        doc["sessions"][sid] = {"waivers": entries}
else:
    doc["sessions"] = {}

# (b) top-level drift shapes (b–f): pull them into sessions.<sid>.
if sid in doc and sid not in doc["sessions"]:
    legacy = doc.pop(sid)
    if isinstance(legacy, dict) and isinstance(legacy.get("waivers"), list):
        entries = [e for e in legacy["waivers"] if isinstance(e, dict)]
    elif isinstance(legacy, list):
        entries = []
        for item in legacy:
            if isinstance(item, dict):
                if "waivers" in item and isinstance(item["waivers"], list):
                    entries.extend(e for e in item["waivers"] if isinstance(e, dict))
                else:
                    entries.append(item)
    doc["sessions"][sid] = {"waivers": entries or []}

if entries is None:
    doc["sessions"][sid] = {"waivers": []}
    entries = doc["sessions"][sid]["waivers"]

entries.append(waiver)

with open(tmp, "w") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
os.replace(tmp, path)
PY
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "cascade_waiver_write: python write failed (rc=$rc)" >&2
    return $rc
  fi
  echo "$sid"
}
