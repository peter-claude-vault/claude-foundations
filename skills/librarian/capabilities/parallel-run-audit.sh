#!/bin/bash
# parallel-run-audit.sh — librarian capability (Plan 80/81 SP01 T-9).
# (Renamed from r55-parallel-run-audit.sh 2026-05-11 — R-55 was Plan-71-specific
# naming; the audit pattern is reusable for any future gate parallel-run phase.)
#
# Reads ~/.claude/hooks/state/parallel-run.log JSONL emitted during Phase A
# bootstrap (T-20 deploy), where the new plan-agnostic live-guard.sh runs
# alongside the old plan-71-live-guard.sh and both decisions are logged
# side-by-side. Surfaces divergences with per-divergence disposition tracking,
# enforces N=3 iteration cap on regenerate-after-investigation rounds, and
# gates Phase A → B advance on zero unjustified divergences.
#
# Validation contract (Approach 2a per Agent 6): old helper binds; divergences
# logged + tracked. bug-new dispositions block Phase B advance until fixed.
# bug-old is desired direction (proves new helper more correct). expected
# covers cases where new helper has new scope or detects differently by design.
#
# Subcommands:
#   summary [<log-path>]
#     Emit JSON summary: {total_decisions, total_divergences,
#       dispositions: {expected, bug-old, bug-new, undisposed}}
#
#   list [--undisposed-only] [<log-path>]
#     Emit JSONL of all divergences or only those without a disposition.
#
#   dispose <run_id> <disposition> [<note>] [--dispositions-path <p>]
#     Record a disposition for a specific divergence. disposition ∈
#     {expected, bug-old, bug-new}. Writes to parallel-run-dispositions.jsonl
#     alongside the log.
#
#   phase-advance-check [<log-path>]
#     Exit 0 IFF zero undisposed AND zero bug-new dispositions. Exit 1
#     otherwise. Used as CI gate for Phase A → B advance.
#
#   iteration-count [<log-path>]
#     Emit current iteration count (number of bug-new dispositions). N=3 cap:
#     if iteration count ≥ 3, surface escalation banner and exit 2 (don't
#     allow further investigation rounds without explicit user override).
#
# JSONL schema for parallel-run.log:
#   {ts, run_id, plan_id, signal, tool, file, old_decision, new_decision,
#    diverged: bool, schema_version: 1}
#
# JSONL schema for parallel-run-dispositions.jsonl:
#   {ts, run_id, disposition, note, schema_version: 1}
#
# Test-isolation env:
#   PARALLEL_RUN_LOG       - explicit log path override
#   PARALLEL_RUN_DISPS     - explicit dispositions file override

set -uo pipefail

DEFAULT_LOG="${HOOKS_STATE_OVERRIDE:-$HOME/.claude/hooks/state}/parallel-run.log"
DEFAULT_DISPS="${HOOKS_STATE_OVERRIDE:-$HOME/.claude/hooks/state}/parallel-run-dispositions.jsonl"

LOG_PATH="${PARALLEL_RUN_LOG:-$DEFAULT_LOG}"
DISPS_PATH="${PARALLEL_RUN_DISPS:-$DEFAULT_DISPS}"

ITERATION_CAP=3

usage() {
  cat <<'EOF'
Usage: parallel-run-audit.sh <subcommand> [args]

Subcommands:
  summary [<log-path>]
  list [--undisposed-only] [<log-path>]
  dispose <run_id> <disposition> [<note>] [--dispositions-path <p>]
  phase-advance-check [<log-path>]
  iteration-count [<log-path>]
EOF
  exit 2
}

[[ $# -lt 1 ]] && usage

SUBCMD="$1"; shift

# === Helper: emit divergences (one JSON row per line) =====================
# Joins log rows with their disposition (if any) by run_id.
emit_divergences() {
  local log="$1" disps="$2" undisposed_only="${3:-0}"

  if [[ ! -r "$log" ]]; then
    return 0
  fi

  # Build dispositions index: {run_id: {disposition, note}}
  local disps_index='{}'
  if [[ -r "$disps" ]]; then
    disps_index=$(jq -s -c \
      'reduce .[] as $d ({}; .[$d.run_id] = {disposition: $d.disposition, note: ($d.note // "")})' \
      "$disps" 2>/dev/null || echo '{}')
  fi

  jq -c --argjson disps "$disps_index" '
    select(.diverged == true)
    | . + {disposition: ($disps[.run_id].disposition // null),
           disposition_note: ($disps[.run_id].note // null)}
  ' "$log" 2>/dev/null
}

# === Subcommand: summary ==================================================
cmd_summary() {
  local log="${1:-$LOG_PATH}"
  local disps="$DISPS_PATH"

  if [[ ! -r "$log" ]]; then
    jq -n --arg log "$log" '{
      log_path: $log, log_present: false,
      total_decisions: 0, total_divergences: 0,
      dispositions: {expected: 0, "bug-old": 0, "bug-new": 0, undisposed: 0}
    }'
    return 0
  fi

  local total_decisions
  total_decisions=$(wc -l < "$log" | tr -d ' ')

  local diverged_rows
  diverged_rows=$(emit_divergences "$log" "$disps" 0)

  local total_divergences=0
  local n_expected=0 n_bug_old=0 n_bug_new=0 n_undisposed=0

  if [[ -n "$diverged_rows" ]]; then
    total_divergences=$(echo "$diverged_rows" | grep -c . || echo 0)
    n_expected=$(echo "$diverged_rows" | jq -s '[.[] | select(.disposition == "expected")] | length')
    n_bug_old=$(echo "$diverged_rows" | jq -s '[.[] | select(.disposition == "bug-old")] | length')
    n_bug_new=$(echo "$diverged_rows" | jq -s '[.[] | select(.disposition == "bug-new")] | length')
    n_undisposed=$(echo "$diverged_rows" | jq -s '[.[] | select(.disposition == null)] | length')
  fi

  jq -n \
    --arg log "$log" \
    --argjson td "$total_decisions" \
    --argjson tdv "$total_divergences" \
    --argjson e "$n_expected" \
    --argjson bo "$n_bug_old" \
    --argjson bn "$n_bug_new" \
    --argjson u "$n_undisposed" \
    '{
      log_path: $log, log_present: true,
      total_decisions: $td, total_divergences: $tdv,
      dispositions: {expected: $e, "bug-old": $bo, "bug-new": $bn, undisposed: $u}
    }'
}

# === Subcommand: list =====================================================
cmd_list() {
  local undisposed_only=0
  local log="$LOG_PATH"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --undisposed-only) undisposed_only=1; shift ;;
      *) log="$1"; shift ;;
    esac
  done

  local rows
  rows=$(emit_divergences "$log" "$DISPS_PATH" "$undisposed_only")
  if [[ "$undisposed_only" == "1" ]]; then
    echo "$rows" | jq -c 'select(.disposition == null)'
  else
    echo "$rows"
  fi
}

# === Subcommand: dispose ==================================================
cmd_dispose() {
  local run_id="" disposition="" note=""
  local disps_path="$DISPS_PATH"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dispositions-path) disps_path="$2"; shift 2 ;;
      *)
        if [[ -z "$run_id" ]]; then run_id="$1"
        elif [[ -z "$disposition" ]]; then disposition="$1"
        else note="${note:+$note }$1"
        fi
        shift ;;
    esac
  done

  [[ -z "$run_id" || -z "$disposition" ]] && {
    echo "dispose: <run_id> <disposition> required" >&2
    return 2
  }

  case "$disposition" in
    expected|bug-old|bug-new) ;;
    *) echo "dispose: disposition must be one of {expected, bug-old, bug-new}" >&2; return 2 ;;
  esac

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  mkdir -p "$(dirname "$disps_path")" 2>/dev/null || true

  jq -nc \
    --arg ts "$ts" \
    --arg run_id "$run_id" \
    --arg disposition "$disposition" \
    --arg note "$note" \
    --argjson schema_version 1 \
    '{ts: $ts, run_id: $run_id, disposition: $disposition,
      note: $note, schema_version: $schema_version}' \
    >> "$disps_path"

  echo "dispose: $run_id → $disposition"
}

# === Subcommand: phase-advance-check ======================================
# Exit 0 IFF zero undisposed AND zero bug-new dispositions across the log.
cmd_phase_advance_check() {
  local log="${1:-$LOG_PATH}"
  local sum
  sum=$(cmd_summary "$log")

  local undisposed bug_new
  undisposed=$(echo "$sum" | jq -r '.dispositions.undisposed')
  bug_new=$(echo "$sum" | jq -r '.dispositions["bug-new"]')

  if [[ "$undisposed" == "0" && "$bug_new" == "0" ]]; then
    echo "phase-advance-check: PASS (undisposed=0, bug-new=0)"
    return 0
  fi
  echo "phase-advance-check: BLOCKED (undisposed=$undisposed, bug-new=$bug_new)" >&2
  return 1
}

# === Subcommand: iteration-count ==========================================
# Emit current iteration count (number of bug-new dispositions). N=3 cap:
# at ≥3, exit 2 (escalation banner; don't allow further investigation
# rounds without explicit user override).
cmd_iteration_count() {
  local log="${1:-$LOG_PATH}"
  local sum
  sum=$(cmd_summary "$log")
  local bug_new
  bug_new=$(echo "$sum" | jq -r '.dispositions["bug-new"]')

  if [[ "$bug_new" -ge "$ITERATION_CAP" ]]; then
    cat <<EOF >&2
[parallel-run-audit] ITERATION CAP REACHED
  bug-new disposition count: $bug_new (cap: $ITERATION_CAP)
  Further investigation rounds require explicit user override.
  Phase A → B advance is structurally blocked.
EOF
    echo "$bug_new"
    return 2
  fi
  echo "$bug_new"
  return 0
}

# === Dispatch =============================================================
case "$SUBCMD" in
  summary)               cmd_summary "$@" ;;
  list)                  cmd_list "$@" ;;
  dispose)               cmd_dispose "$@" ;;
  phase-advance-check)   cmd_phase_advance_check "$@" ;;
  iteration-count)       cmd_iteration_count "$@" ;;
  *)                     usage ;;
esac
