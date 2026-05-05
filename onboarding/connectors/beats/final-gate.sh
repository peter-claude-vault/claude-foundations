#!/usr/bin/env bash
# onboarding/connectors/beats/final-gate.sh — SP14 T-11 (Plan 71 SP14
# Session 3b).
#
# Mandatory final wizard step: render every cron/launchd entry that will be
# created. One row per declared O.jobs[] (via T-1 iterator) + one row per
# connectors[] entry with non-"manual" schedule. Single confirm prompt;
# refusing aborts cleanly without writing manifest, installing plists, or
# merging settings.json.
#
# OUTPUT CONTRACT (R-43):
#   Files written: none — pure read + summary + confirm prompt
#   Schema-types: not applicable
#   Pre-write validation: not applicable (this IS the validation gate)
#   Failure mode: BLOCK AND LOG. rc=2 user-aborted (distinct from rc=1 error)
#                 per T-11 AC #3.
#
# Usage:
#   bash final-gate.sh [--manifest <path>] [--orchestration <path>]
#                      [--input accept|abort] [--accept-on-empty-stdin]
#
# Flags:
#   --orchestration <p>     orchestration.json path (default: $CLAUDE_HOME/...)
#   --input accept|abort    Non-interactive: synthetic test mode
#   --accept-on-empty-stdin EOF on stdin = accept (test convenience)
#
# Exit codes:
#   0  user accepted (wizard proceeds)
#   1  hard error (e.g., manifest unreadable)
#   2  user aborted (clean refusal — distinct from error)

set -u

_diag() { printf 'final-gate FAIL: %s\n' "$1" >&2; }
_info() { printf 'final-gate: %s\n' "$1"; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
ITERATOR="$REPO_ROOT/onboarding/lib/job-iterator.sh"
USER_MANIFEST="${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json"
ORCHESTRATION="${ORCHESTRATION_JSON:-${CLAUDE_HOME:-$HOME/.claude}/orchestration.json}"

manifest_arg=""
orch_arg=""
input_choice=""
accept_eof=0

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) [ $# -lt 2 ] && { _diag "--manifest requires path"; exit 1; }; manifest_arg="$2"; shift 2 ;;
    --orchestration) [ $# -lt 2 ] && { _diag "--orchestration requires path"; exit 1; }; orch_arg="$2"; shift 2 ;;
    --input) [ $# -lt 2 ] && { _diag "--input requires accept|abort"; exit 1; }; input_choice="$2"; shift 2 ;;
    --accept-on-empty-stdin) accept_eof=1; shift ;;
    -*) _diag "unknown flag: $1"; exit 1 ;;
    *) _diag "unexpected positional: $1"; exit 1 ;;
  esac
done

[ -n "$manifest_arg" ] && USER_MANIFEST="$manifest_arg"
[ -n "$orch_arg" ] && ORCHESTRATION="$orch_arg"

# --- enumerate orchestration.json jobs[] (via T-1 iterator if present) ---
job_rows=""
if [ -r "$ORCHESTRATION" ]; then
  # Read job rows: id + schedule-summary
  job_rows=$(jq -r '.jobs[] | [
    .id,
    "launchd",
    (.schedule | if .interval_sec then "interval " + (.interval_sec|tostring) + "s"
                 elif .hour then "daily " + (.hour|tostring) + ":" + (.minute|tostring|("0"+.)[-2:])
                 else "—" end)
  ] | @tsv' "$ORCHESTRATION" 2>/dev/null)
fi

# --- enumerate connectors[] non-manual scheduled entries ---
conn_rows=""
if [ -r "$USER_MANIFEST" ]; then
  conn_rows=$(jq -r '
    (.connectors // [])
    | map(select(.schedule and .schedule != "manual"))
    | .[]
    | [.id, "connector-runtime", .schedule, (.target_vault_path // "—"), (.processor_skill // "—")]
    | @tsv
  ' "$USER_MANIFEST" 2>/dev/null)
fi

# --- render summary ---
printf '\nConnector Wizard — Final Gate (5 of 5)\n' >&2
printf 'These cron/launchd entries WILL be created when you confirm:\n\n' >&2

job_count=0
if [ -n "$job_rows" ]; then
  printf '  %-25s | %-18s | %s\n' "id" "type" "schedule" >&2
  printf '  %-25s-+-%-18s-+-%s\n' "-------------------------" "------------------" "----------------" >&2
  printf '%s\n' "$job_rows" | while IFS=$'\t' read -r id type sched; do
    [ -z "$id" ] && continue
    printf '  %-25s | %-18s | %s\n' "$id" "$type" "$sched" >&2
  done
  job_count=$(printf '%s\n' "$job_rows" | grep -c .)
fi

conn_count=0
if [ -n "$conn_rows" ]; then
  printf '%s\n' "$conn_rows" | while IFS=$'\t' read -r id type sched tvp ps; do
    [ -z "$id" ] && continue
    printf '  %-25s | %-18s | %s  →  %s (%s)\n' "$id" "$type" "$sched" "$tvp" "$ps" >&2
  done
  conn_count=$(printf '%s\n' "$conn_rows" | grep -c .)
fi

# Recompute counts at parent shell level (subshell counts above are lost)
job_count=$(printf '%s\n' "$job_rows" | grep -c . 2>/dev/null || true)
conn_count=$(printf '%s\n' "$conn_rows" | grep -c . 2>/dev/null || true)
total=$((job_count + conn_count))

printf '\n  Total: %s entries (%s jobs + %s connectors)\n' "$total" "$job_count" "$conn_count" >&2

if [ "$total" = "0" ]; then
  _info "no entries to schedule; final gate is a no-op"
  exit 0
fi

# --- prompt for confirm ---
choice=""
if [ -n "$input_choice" ]; then
  choice="$input_choice"
else
  printf '\nProceed? [accept/abort]: ' >&2
  if IFS= read -r typed; then
    choice="$typed"
  elif [ "$accept_eof" -eq 1 ]; then
    choice="accept"
  else
    _diag "EOF on stdin without selection"
    exit 1
  fi
fi

case "$choice" in
  accept|yes|y) _info "user accepted — wizard proceeds to apply"; exit 0 ;;
  abort|no|n) _info "user aborted at final gate — no plists installed, no manifest writes, no settings.json mutations"; exit 2 ;;
  *) _diag "unknown choice '$choice' — treating as abort"; exit 2 ;;
esac
