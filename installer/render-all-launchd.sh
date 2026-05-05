#!/usr/bin/env bash
# installer/render-all-launchd.sh — SP14 T-2 (Plan 71 SP14 Session 1).
#
# Renders one launchd plist per declared `.jobs[]` entry in orchestration.json.
# Sources `onboarding/lib/job-iterator.sh` for `for_each_job`, then invokes
# `installer/render-launchd.sh` per job (which atomically writes the plist
# into `--staging-dir <path>` or `~/Library/LaunchAgents` in production mode).
#
# Usage: render-all-launchd.sh [--staging-dir <path>] [--dry-run]
#
# Modes:
#   default              Production install: each rendered plist atomically
#                        moves into ~/Library/LaunchAgents and bootstraps
#                        via launchctl (per render-launchd.sh's prod flow).
#   --staging-dir <path> Staging install: each rendered plist lands in <path>;
#                        no launchctl bootstrap (synthetic-test friendly).
#   --dry-run            For each job, render+plutil-lint and emit to stdout;
#                        no plists written, no bootstrap.
#
# Reads $ORCHESTRATION_JSON (env var; required) — the per-user job manifest
# produced by onboarding Section D + the SP14 connector wizard. Iterates
# `.jobs[]` in declaration order; skips any job lacking a corresponding
# template (`templates/launchd/<job-id>.plist.tmpl`); emits one summary line
# per attempted render.
#
# Exit codes:
#   0  all declared jobs rendered successfully (or zero declared)
#   2  bad invocation (missing/bad arg)
#   3  $ORCHESTRATION_JSON unreadable or jq parse failure
#   4  one or more per-job renders failed; check stderr for detail
#
# Dependencies: jq, bash 3.2+, render-launchd.sh, job-iterator.sh.
# R-23 (bash 3.2 compat). R-37 single-deliverable.

set -u

_diag() { printf 'render-all-launchd FAIL: %s\n' "$1" >&2; }
_info() { printf 'render-all-launchd: %s\n' "$1"; }

# --- arg parse ---
staging_arg=""
dry_run_arg=""

while [ $# -gt 0 ]; do
  case "$1" in
    --staging-dir)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        _diag "--staging-dir requires a path argument"
        exit 2
      fi
      staging_arg="--staging-dir $2"
      shift 2
      ;;
    --staging-dir=*)
      staging_arg="--staging-dir ${1#--staging-dir=}"
      shift
      ;;
    --dry-run)
      dry_run_arg="--dry-run"
      shift
      ;;
    -*)
      _diag "unknown flag: $1"
      exit 2
      ;;
    *)
      _diag "unexpected positional arg: $1"
      exit 2
      ;;
  esac
done

# --- locate dependencies ---
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$self_dir/.." && pwd)"
ITERATOR="$repo_root/onboarding/lib/job-iterator.sh"
RENDER="$self_dir/render-launchd.sh"

if [ ! -r "$ITERATOR" ]; then
  _diag "job-iterator.sh not readable at $ITERATOR"
  exit 2
fi
if [ ! -r "$RENDER" ]; then
  _diag "render-launchd.sh not readable at $RENDER"
  exit 2
fi

# --- check orchestration.json ---
if [ -z "${ORCHESTRATION_JSON:-}" ]; then
  _diag "ORCHESTRATION_JSON env var required"
  exit 3
fi
if [ ! -r "$ORCHESTRATION_JSON" ]; then
  _diag "ORCHESTRATION_JSON not readable: $ORCHESTRATION_JSON"
  exit 3
fi

# --- source iterator ---
# shellcheck source=/dev/null
. "$ITERATOR"

# --- render callback ---
# Tracks failures via a tmp file (subshell won't share var with parent).
_failure_log="$(mktemp -t render-all-failures-XXXXXX)"
# shellcheck disable=SC2064
trap "rm -f '$_failure_log'" EXIT

_render_one() {
  local job_id="$1"
  local template="$repo_root/templates/launchd/$job_id.plist.tmpl"

  if [ ! -r "$template" ]; then
    _info "skipping job '$job_id' — no template at templates/launchd/$job_id.plist.tmpl"
    return 0
  fi

  # connector-runtime is a parameterized template; per-connector iteration is
  # T-3 / wizard scope. Skip silently here — the wizard renders it directly
  # with CONNECTOR_ID set.
  if [ "$job_id" = "connector-runtime" ]; then
    _info "skipping job '$job_id' — parameterized template; rendered per-connector by SP14 wizard"
    return 0
  fi

  _info "rendering job '$job_id' → $RENDER $staging_arg $dry_run_arg $job_id"
  # NB: $staging_arg + $dry_run_arg are intentionally word-split.
  # shellcheck disable=SC2086
  if ! bash "$RENDER" $staging_arg $dry_run_arg "$job_id"; then
    echo "$job_id" >> "$_failure_log"
    _diag "render of job '$job_id' failed (continuing with remaining jobs)"
  fi
  return 0  # never abort iteration on per-job failure
}

# --- iterate ---
_info "rendering plists for $(count_jobs) declared jobs in $ORCHESTRATION_JSON"
for_each_job _render_one || {
  _diag "for_each_job returned non-zero — iteration aborted"
  exit 4
}

# --- summarize ---
fail_count=$(wc -l < "$_failure_log" | tr -d ' ')
if [ "$fail_count" -gt 0 ]; then
  _diag "$fail_count job(s) failed to render; failed ids:"
  cat "$_failure_log" >&2
  exit 4
fi

_info "all declared jobs rendered successfully"
exit 0
