#!/bin/bash
# tests/runner-shell.sh
#
# SP00 Primitive — Universal test entrypoint for every sub-plan. Every test
# case in the Claude Foundations Engine v2 dogfood pipeline is expected to
# be invoked via this script; direct `nerdctl run ... bash` / `docker run
# ... bash` shells bypassing runner-shell are out-of-contract and T-12
# adds a grep-audit rule catching them.
#
# Responsibilities:
#   1. Pre-flight the 3 structural invariants via tests/readiness-gate.sh
#      (T-1). Any failure aborts the run with exit 2. This also doubles as
#      AC5 "reject invocation outside container" — running this script on
#      the macOS host fails the gate because /Users exists, $HOME is not
#      /home/tester, uid is not 1000.
#   2. Discover `*.sh` test cases in the cases directory (default
#      /tests/synthetic-cases) in lexicographic order. Each case is a plain
#      bash script whose exit code maps to status:
#        exit 0    → pass       (assertion passed)
#        exit 1    → fail-soft  (assertion failed; test ran)
#        exit ≥ 2  → fail-hard  (infrastructure failure; test did not run
#                                 to completion OR reported infra fault)
#   3. Run each case with stdout + stderr merged to /results/<case>.log.
#      Per-case timings captured in milliseconds.
#   4. Emit /results/summary.json — a single machine-parseable document
#      consumed by sub-plan test gates + T-13 self-verify.
#   5. Aggregate exit code = max of per-case exit codes (so an 0/0/0/1/1/2/3
#      harness exits 3). A fail-hard in any case surfaces as a fail-hard
#      aggregate, which is exactly what the ladder-of-test-gates wants.
#
# Usage:
#   tests/runner-shell.sh                      # default /tests/synthetic-cases
#   tests/runner-shell.sh /tests/sp01-cases    # explicit cases dir
#   tests/runner-shell.sh /tests/sp01-cases /custom/results
#
# Exit codes (max-of-cases AGGREGATE, with runner-infra overrides):
#   0          all cases pass
#   1          at least one case fail-soft, nothing fail-hard
#   2..N       highest fail-hard code observed among cases
#   64         usage error (cases dir missing, not a directory)
#   65         /results target not writable (runner infra fault)
#
# Pre-flight-gate exit override: if readiness-gate fails, exit 2 verbatim
# (matches readiness-gate's own exit 2) WITHOUT emitting summary.json.
# Callers that want a structured failure record should check the
# readiness-gate exit before invoking runner-shell.
#
# Exfil (AC4): runner-shell DOES NOT perform exfil. After the run,
# /results/ is a self-contained tree (logs + summary.json) that the caller
# copies off via tests/runner-exfil.sh <target>. Keeping transport out of
# the runner preserves a single code path for in-container execution and
# avoids coupling the runner to SSH key availability.
#
# R-23: bash 3.2 compat (no associative arrays, no `local -A`, no
# `[[ ... =~ ... ]]` — use `case` or grep). Tested container-side under
# Ubuntu 24.04's `/bin/bash` (5.2+).

set -u

# ------------------------------------------------------------------------
# Locate peer scripts relative to this one.
# ------------------------------------------------------------------------
__RUNNER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
READINESS_GATE="${__RUNNER_DIR}/readiness-gate.sh"

# ------------------------------------------------------------------------
# Args.
# ------------------------------------------------------------------------
CASES_DIR="${1:-${__RUNNER_DIR}/synthetic-cases}"
RESULTS_DIR="${2:-/results}"

runner_err() {
  printf 'runner-shell: %s\n' "$1" >&2
}

# ------------------------------------------------------------------------
# Pre-flight 1: readiness-gate.
# ------------------------------------------------------------------------
if [ ! -x "$READINESS_GATE" ]; then
  runner_err "readiness-gate missing or not executable: $READINESS_GATE"
  exit 2
fi
if ! "$READINESS_GATE"; then
  runner_err "readiness-gate FAILED — refusing to run cases"
  runner_err "  (this also fires when runner-shell is invoked on the macOS host)"
  exit 2
fi

# ------------------------------------------------------------------------
# Pre-flight 2: cases dir + results dir.
# ------------------------------------------------------------------------
if [ ! -d "$CASES_DIR" ]; then
  runner_err "cases dir not found: $CASES_DIR"
  exit 64
fi

if [ ! -d "$RESULTS_DIR" ]; then
  if ! mkdir -p "$RESULTS_DIR" 2>/dev/null; then
    runner_err "/results dir not writable and mkdir failed: $RESULTS_DIR"
    exit 65
  fi
fi
if [ ! -w "$RESULTS_DIR" ]; then
  runner_err "results dir not writable: $RESULTS_DIR"
  exit 65
fi

# ------------------------------------------------------------------------
# Enumerate cases (lexicographic).
# ------------------------------------------------------------------------
# Avoid set -e + pipefail traps: bash 3.2 globs on a no-match pattern expand
# literally, so we test for the literal-glob outcome and treat it as "no
# cases found" rather than an infra fault.
case_count=0
case_names=""
for f in "$CASES_DIR"/*.sh; do
  [ -e "$f" ] || continue
  case_count=$((case_count + 1))
  case_names="${case_names}${f}"$'\n'
done
if [ "$case_count" -eq 0 ]; then
  runner_err "no *.sh cases found in $CASES_DIR"
  exit 64
fi

# ------------------------------------------------------------------------
# Helpers.
# ------------------------------------------------------------------------
# ISO-8601 UTC with millisecond precision (GNU date vs BSD date both
# accept %N under GNU coreutils in container; graceful fallback to second
# precision if %N is not supported — rare enough to be defensive).
iso_now() {
  d=$(date -u +'%Y-%m-%dT%H:%M:%S.%3NZ' 2>/dev/null || true)
  case "$d" in
    *'%3N'*|'') date -u +'%Y-%m-%dT%H:%M:%SZ' ;;
    *) printf '%s' "$d" ;;
  esac
}

# Epoch milliseconds, for duration math. GNU date supports %3N; BSD
# fallback drops to seconds * 1000.
epoch_ms() {
  e=$(date -u +'%s%3N' 2>/dev/null || true)
  case "$e" in
    *'%3N'*|'') printf '%s' "$(( $(date -u +%s) * 1000 ))" ;;
    *) printf '%s' "$e" ;;
  esac
}

# Map exit -> status.
status_for_exit() {
  case "$1" in
    0) printf 'pass' ;;
    1) printf 'fail-soft' ;;
    *) printf 'fail-hard' ;;
  esac
}

# JSON string escape (bash 3.2 safe — only escapes the handful of
# characters that appear in a file path or a short diagnostic).
json_escape() {
  # \, ", then control chars below 0x20 -> hex escapes.
  # Case names are test filenames under our control; no need for full
  # RFC 8259 coverage.
  s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//	/\\t}
  printf '%s' "$s"
}

# ------------------------------------------------------------------------
# Run cases.
# ------------------------------------------------------------------------
run_start=$(iso_now)
run_start_ms=$(epoch_ms)

# Aggregate trackers. We accumulate case JSON fragments into a single
# string to assemble summary.json in one write at the end.
aggregate_exit=0
pass_count=0
fail_soft_count=0
fail_hard_count=0
cases_json=""
first=1

# Iterate; read-from-string pattern avoids subshell losing state (R-23).
IFS=$'\n'
for case_path in $case_names; do
  [ -n "$case_path" ] || continue
  case_name=$(basename "$case_path")
  case_log="${RESULTS_DIR}/${case_name}.log"

  printf 'runner-shell: >>> %s\n' "$case_name"

  case_start=$(iso_now)
  case_start_ms=$(epoch_ms)

  # Run in a clean subshell so per-case `set -e` / `trap` / `cd` / env
  # mutations do not bleed into runner-shell state. stdout + stderr
  # merged to the per-case log.
  ( bash "$case_path" ) >"$case_log" 2>&1
  case_exit=$?

  case_end=$(iso_now)
  case_end_ms=$(epoch_ms)
  case_duration_ms=$(( case_end_ms - case_start_ms ))

  case_status=$(status_for_exit "$case_exit")

  case "$case_status" in
    pass)       pass_count=$((pass_count + 1)) ;;
    fail-soft)  fail_soft_count=$((fail_soft_count + 1)) ;;
    fail-hard)  fail_hard_count=$((fail_hard_count + 1)) ;;
  esac
  [ "$case_exit" -gt "$aggregate_exit" ] && aggregate_exit="$case_exit"

  # Per-case JSON fragment (hand-assembled; no jq dependency for write).
  esc_name=$(json_escape "$case_name")
  esc_log=$(json_escape "$case_log")
  comma=','
  [ "$first" = '1' ] && { comma=''; first=0; }
  cases_json="${cases_json}${comma}
    {
      \"name\": \"${esc_name}\",
      \"path\": \"$(json_escape "$case_path")\",
      \"log\": \"${esc_log}\",
      \"exit\": ${case_exit},
      \"status\": \"${case_status}\",
      \"start_time\": \"${case_start}\",
      \"end_time\": \"${case_end}\",
      \"duration_ms\": ${case_duration_ms}
    }"

  printf 'runner-shell: <<< %s exit=%d status=%s (%dms)\n' \
    "$case_name" "$case_exit" "$case_status" "$case_duration_ms"
done
unset IFS

run_end=$(iso_now)
run_end_ms=$(epoch_ms)
run_duration_ms=$(( run_end_ms - run_start_ms ))

# ------------------------------------------------------------------------
# Emit summary.json.
# ------------------------------------------------------------------------
SUMMARY_JSON="${RESULTS_DIR}/summary.json"
{
  printf '{\n'
  printf '  "runner_shell_version": "1",\n'
  printf '  "cases_dir": "%s",\n' "$(json_escape "$CASES_DIR")"
  printf '  "results_dir": "%s",\n' "$(json_escape "$RESULTS_DIR")"
  printf '  "start_time": "%s",\n' "$run_start"
  printf '  "end_time": "%s",\n' "$run_end"
  printf '  "duration_ms": %d,\n' "$run_duration_ms"
  printf '  "case_count": %d,\n' "$case_count"
  printf '  "pass_count": %d,\n' "$pass_count"
  printf '  "fail_soft_count": %d,\n' "$fail_soft_count"
  printf '  "fail_hard_count": %d,\n' "$fail_hard_count"
  printf '  "aggregate_exit": %d,\n' "$aggregate_exit"
  printf '  "cases": [%s\n  ]\n' "$cases_json"
  printf '}\n'
} > "$SUMMARY_JSON"

printf 'runner-shell: summary.json written: %s\n' "$SUMMARY_JSON"
printf 'runner-shell: aggregate exit=%d (pass=%d soft=%d hard=%d / %d)\n' \
  "$aggregate_exit" "$pass_count" "$fail_soft_count" "$fail_hard_count" \
  "$case_count"

exit "$aggregate_exit"
