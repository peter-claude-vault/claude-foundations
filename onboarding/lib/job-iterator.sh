#!/usr/bin/env bash
# onboarding/lib/job-iterator.sh — SP14 T-1 (Plan 71 SP14 Session 1)
#
# N-job iteration helpers over orchestration.json `.jobs[]`. Sourced by callers
# that need to act per-declared-job (multi-plist render at install time, wizard
# walk in SP14 T-7..T-11, future autonomous-job orchestration). Bash 3.2 + jq.
#
# OUTPUT CONTRACT (R-43):
#   Files written:    none — pure-read library; callbacks may write
#   Schema-types:     reads orchestration.json conforming to
#                     schemas/orchestration-schema.json (.jobs[].id required)
#   Pre-write validation:
#                     ORCHESTRATION_JSON path exists and is readable; jq
#                     parses it; .jobs is an array
#   Failure mode:     BLOCK AND LOG. Non-zero rc on missing file, jq parse
#                     error, or non-array .jobs. Callbacks raise their own
#                     errors; iterator does NOT swallow callback rc.
#
# SCOPE NOTE (T-1 AC clarification):
#   This library exists for callers that legitimately need to walk N jobs
#   (install-time multi-plist render, connector wizard from SP14 T-7..T-11
#   onward, autonomous orchestration that may run multiple jobs per host).
#
#   Single-job-context code is NOT a hardcode bug. The following access
#   `.jobs[0]` correctly because they operate on the Section D INITIAL job
#   the user picks during onboarding (a single-element slot, by D-2 design):
#     - onboarding/initial-job-setup.sh         (customizes Section D's choice)
#     - onboarding/ux/section-d.sh              (extracts D-2 output)
#     - onboarding/bootstrap-schemas.sh         (validates D-2 mutex contract)
#     - onboarding/opt-outs/validate-full-opt-out.sh
#     - onboarding/q-field-map.json             (D-2 defaults_applied bundle)
#     - onboarding/tests/round-trip-test.sh     (D-2 round-trip fixture)
#     - documentation under onboarding/         (describes the schema)
#
#   T-2 (multi-plist render at install time) and T-7..T-11 (wizard) are the
#   first true multi-job consumers — they source this library.
#
# API (sourceable):
#
#   for_each_job <fn> [orchestration-json-path]
#     Iterates .jobs[] in declaration order. Calls <fn> once per job with the
#     job's `id` as $1. Callers re-query jq for additional fields:
#         for_each_job render_one_job
#         render_one_job() {
#           local job_id="$1"
#           local sched_hour
#           sched_hour=$(jq -r --arg id "$job_id" \
#             '.jobs[] | select(.id == $id) | .schedule.hour' \
#             "$ORCHESTRATION_JSON")
#           # ... act on $job_id + $sched_hour
#         }
#     Iterator does NOT swallow callback rc — first non-zero callback rc
#     causes for_each_job to return that rc immediately.
#     Path arg: defaults to $ORCHESTRATION_JSON env var.
#     Returns: 0 on full-array iteration; 2 on bad invocation; 3 on
#     orchestration.json read error; first non-zero rc from callback.
#
#   count_jobs [orchestration-json-path]
#     Echoes the length of .jobs[] to stdout. Empty array → "0".
#     Path arg: defaults to $ORCHESTRATION_JSON env var.
#     Returns: 0 on success; 3 on orchestration.json read error.
#
# Dependencies: jq, bash 3.2+. R-23 compat (no associative arrays, no
# `read -d ''`, no `mapfile`).

set -u

_ji_diag() { printf 'job-iterator FAIL: %s\n' "$1" >&2; }

_ji_resolve_path() {
  # NB: do NOT name this `path` — in zsh, `path` is tied to `PATH`.
  local _ji_p="${1:-${ORCHESTRATION_JSON:-}}"
  if [ -z "$_ji_p" ]; then
    _ji_diag "no orchestration.json path (pass arg or set ORCHESTRATION_JSON)"
    return 2
  fi
  if [ ! -r "$_ji_p" ]; then
    _ji_diag "orchestration.json not readable: $_ji_p"
    return 3
  fi
  printf '%s' "$_ji_p"
}

count_jobs() {
  # NB: do NOT name a local var `path` — in zsh, `path` is tied to `PATH`.
  local _ji_p
  _ji_p=$(_ji_resolve_path "${1:-}") || return $?
  local n
  n=$(jq -r '.jobs | length' "$_ji_p" 2>/dev/null) || {
    _ji_diag "jq parse failed on: $_ji_p"
    return 3
  }
  if ! printf '%s' "$n" | grep -qE '^[0-9]+$'; then
    _ji_diag ".jobs is not an array (got length: '$n') in $_ji_p"
    return 3
  fi
  printf '%s' "$n"
}

for_each_job() {
  if [ $# -lt 1 ]; then
    _ji_diag "for_each_job requires a callback function name"
    return 2
  fi
  local fn="$1"
  shift
  if ! command -v "$fn" >/dev/null 2>&1; then
    _ji_diag "for_each_job callback not callable: $fn"
    return 2
  fi
  # NB: do NOT name a local var `path` — in zsh, `path` is tied to `PATH`.
  local _ji_p
  _ji_p=$(_ji_resolve_path "${1:-}") || return $?

  # Get .jobs[].id list. R-23: no `mapfile`, no `read -d ''`. Use newline-
  # delimited stream + while-read. Job ids match `^[a-z][a-z0-9-]*$` per
  # orchestration-schema.json so newline is safe.
  local ids
  ids=$(jq -r '.jobs[].id' "$_ji_p" 2>/dev/null) || {
    _ji_diag "jq read of .jobs[].id failed on: $_ji_p"
    return 3
  }

  # Empty .jobs[] → ids is empty string → loop body skipped → rc 0.
  local job_id rc
  printf '%s\n' "$ids" | while IFS= read -r job_id; do
    [ -z "$job_id" ] && continue
    "$fn" "$job_id"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      _ji_diag "callback '$fn' returned rc=$rc on job '$job_id'; aborting iteration"
      exit "$rc"
    fi
  done
  # Subshell rc propagates from `exit` above (or 0 on full iteration).
  return $?
}
