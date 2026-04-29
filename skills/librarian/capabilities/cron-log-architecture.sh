#!/bin/bash
# cron-log-architecture — Detect launchd plist / wrapper dated-log architectural mismatch.
#
# Landed: Plan 63 Sub-plan 02 T-4 (2026-04-21). Extracted from SKILL.md
# L623-671 pseudocode. Enforcement layer for ENFORCEMENT-MAP R-22.
#
# Usage:
#   cron-log-architecture.sh                    # dry-run scan (default)
#   cron-log-architecture.sh --scope all        # plist + allowlist (default)
#   cron-log-architecture.sh --scope plist      # plist scan only
#   cron-log-architecture.sh --scope allowlist  # allowlist summary only
#   cron-log-architecture.sh --allowlist-path <path>
#
# Detects plists whose StandardOutPath/StandardErrorPath is SET while the
# launched wrapper uses a $(date …)-in-LOG_FILE pattern. These two layers
# compete for log output; the plist fix requires launchctl unload/load.
#
# Scope:
#   - Walks $PLIST_DIR/com.*.plist (default ~/Library/LaunchAgents).
#   - Skips plists whose Program is not a script under $CRON_WRAPPERS.
#
# Accepted-exceptions allowlist: $CRON_LOG_EXCEPTIONS (default
# $HOOKS_DIR/cron-log-architecture-exceptions.json). Format:
#   { "com.example.label": "reason" }
# Labels present are downgraded from blocking to info.
#
# Env overrides (testing): PLIST_DIR, CRON_WRAPPERS, CRON_LOG_EXCEPTIONS,
# FINDINGS_OUTPUT.
#
# macOS-only (requires /usr/libexec/PlistBuddy). On non-macOS, exits 0
# with advisory message.
#
# Bash 3.2 clean per R-23.

set -u
set -o pipefail

if [[ -z "${HOOKS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.claude/hooks/lib/paths.sh"
fi
# shellcheck source=/dev/null
source "$HOME/.claude/skills/librarian/lib/findings.sh"

SCOPE="all"
ALLOWLIST_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --allowlist-path) ALLOWLIST_OVERRIDE="$2"; shift 2 ;;
    --dry-run) shift ;;  # No-op — capability is already read-only
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "cron-log-architecture: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# paths.sh unconditionally exports PLIST_DIR / CRON_WRAPPERS → use
# dedicated *_OVERRIDE vars so tests can redirect without paths.sh clobbering.
PLIST_DIR_RES="${PLIST_DIR_OVERRIDE:-${PLIST_DIR:-$HOME/Library/LaunchAgents}}"
CRON_WRAPPERS_RES="${CRON_WRAPPERS_OVERRIDE:-${CRON_WRAPPERS:-$HOME/.claude/orchestrator/cron-wrappers}}"
if [[ -n "$ALLOWLIST_OVERRIDE" ]]; then
  EXCEPTIONS_FILE="$ALLOWLIST_OVERRIDE"
else
  EXCEPTIONS_FILE="${CRON_LOG_EXCEPTIONS:-$HOOKS_DIR/cron-log-architecture-exceptions.json}"
fi

# PlistBuddy presence check (macOS dependency).
PLIST_BUDDY="/usr/libexec/PlistBuddy"
if [[ ! -x "$PLIST_BUDDY" ]]; then
  echo "## Cron Log Architecture (skipped)"
  echo ""
  echo "- $PLIST_BUDDY not found — capability is macOS-only."
  exit 0
fi

if [[ ! -d "$PLIST_DIR_RES" ]]; then
  echo "## Cron Log Architecture (0 mismatches)"
  echo ""
  echo "- plist dir not found: $PLIST_DIR_RES"
  exit 0
fi

# plist_get <plist> <key> — print key or empty if Does Not Exist.
plist_get() {
  local plist="$1" key="$2"
  local val
  val=$("$PLIST_BUDDY" -c "Print :$key" "$plist" 2>&1)
  case "$val" in
    "Print:"*|*"Does Not Exist"*|*"Unexpected Character"*) printf "" ;;
    *) printf '%s' "$val" ;;
  esac
}

# is_allowlisted <label> — print reason or empty. JSON parsing via python3.
is_allowlisted() {
  local label="$1"
  if [[ ! -f "$EXCEPTIONS_FILE" ]]; then
    printf ""
    return 0
  fi
  python3 - "$EXCEPTIONS_FILE" "$label" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        doc = json.load(f)
    label = sys.argv[2]
    reason = doc.get(label, "")
    sys.stdout.write(reason if isinstance(reason, str) else "")
except Exception:
    pass
PY
}

MISMATCH=0
DOWNGRADED=0
COMPLIANT=0

# Accumulate output lines (Bash 3.2: use string, newline-appended).
REPORT_LINES=""

if [[ "$SCOPE" == "allowlist" ]]; then
  if [[ -f "$EXCEPTIONS_FILE" ]]; then
    echo "## Cron Log Architecture Allowlist"
    echo ""
    python3 - "$EXCEPTIONS_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        doc = json.load(f)
    for label, reason in doc.items():
        print(f"- {label}: {reason}")
except Exception as e:
    print(f"- (error reading allowlist: {e})")
PY
  else
    echo "## Cron Log Architecture Allowlist"
    echo ""
    echo "- (no allowlist file at $EXCEPTIONS_FILE)"
  fi
  exit 0
fi

# Walk plists.
shopt -s nullglob
for plist in "$PLIST_DIR_RES"/com.*.plist; do
  [[ -f "$plist" ]] || continue

  label=$(plist_get "$plist" "Label")
  [[ -z "$label" ]] && continue

  # ProgramArguments — PlistBuddy Array print is multi-line; join with newlines.
  pa=$("$PLIST_BUDDY" -c "Print :ProgramArguments" "$plist" 2>/dev/null || true)
  # Try Program key (string form) as fallback.
  program=""
  if [[ -n "$pa" ]]; then
    # Strip Array wrapper; pull lines; find first path that references CRON_WRAPPERS.
    while IFS= read -r line; do
      case "$line" in
        *"$CRON_WRAPPERS_RES"*|*"/cron-wrappers/"*)
          # Trim leading whitespace.
          program="${line#"${line%%[![:space:]]*}"}"
          break
          ;;
      esac
    done <<< "$pa"
  fi
  if [[ -z "$program" ]]; then
    program=$(plist_get "$plist" "Program")
  fi

  # Skip plists not under CRON_WRAPPERS (not spine-remediation managed).
  case "$program" in
    "$CRON_WRAPPERS_RES"/*) ;;
    *) continue ;;
  esac

  if [[ ! -f "$program" ]]; then
    # Referenced wrapper missing; skip to avoid false positive.
    continue
  fi

  # Wrapper dated-log pattern check.
  if ! grep -qE 'LOG_FILE=.*\$\(date' "$program" 2>/dev/null; then
    # Wrapper doesn't use dated pattern — no mismatch possible.
    COMPLIANT=$((COMPLIANT + 1))
    continue
  fi

  stdout_path=$(plist_get "$plist" "StandardOutPath")
  stderr_path=$(plist_get "$plist" "StandardErrorPath")

  if [[ -z "$stdout_path" ]] && [[ -z "$stderr_path" ]]; then
    # Plist doesn't redirect — compliant.
    COMPLIANT=$((COMPLIANT + 1))
    continue
  fi

  # Mismatch detected — check allowlist.
  reason=$(is_allowlisted "$label")
  if [[ -n "$reason" ]]; then
    DOWNGRADED=$((DOWNGRADED + 1))
    emit_finding "cron-log-architecture-mismatch" "$label" \
      "plist" "$plist" \
      "wrapper" "$program" \
      "StdOut" "${stdout_path:-(unset)}" \
      "StdErr" "${stderr_path:-(unset)}" \
      "level" "info" \
      "allowlisted_reason" "$reason"
    REPORT_LINES="${REPORT_LINES}- $label (ALLOWLISTED — $reason)"$'\n'
  else
    MISMATCH=$((MISMATCH + 1))
    emit_finding "cron-log-architecture-mismatch" "$label" \
      "plist" "$plist" \
      "wrapper" "$program" \
      "StdOut" "${stdout_path:-(unset)}" \
      "StdErr" "${stderr_path:-(unset)}" \
      "level" "error"
    REPORT_LINES="${REPORT_LINES}- $label — StdOut=${stdout_path:-(unset)} StdErr=${stderr_path:-(unset)} wrapper=$program"$'\n'
  fi
done
shopt -u nullglob

printf "## Cron Log Architecture (%d mismatches, %d allowlisted, %d compliant)\n\n" \
  "$MISMATCH" "$DOWNGRADED" "$COMPLIANT"
if [[ -n "$REPORT_LINES" ]]; then
  printf '%s' "$REPORT_LINES"
else
  echo "- No mismatches detected."
fi
