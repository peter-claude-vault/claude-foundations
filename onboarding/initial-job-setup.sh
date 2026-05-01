#!/bin/bash
# onboarding/initial-job-setup.sh — SP07 T-9 staging-only renderer.
#
# Reads orchestration.jobs[0] (Section D output), renders a dry-run preview
# via SP03's installer/render-launchd.sh, prompts for confirmation, writes
# the plist to $CLAUDE_HOME/Library/LaunchAgents.staging/, emits a terminal
# pointer to SP08's `claude system enable-daemon` for activation. Honors
# opt-out #9 (orchestration.jobs == []) by short-circuiting cleanly.
#
# Hard invariants (SP07 spec L86-102 production-flow rules):
#   - NEVER calls `launchctl bootstrap`. SP08 enable-daemon owns activation.
#   - NEVER writes outside $CLAUDE_HOME — only the staging dir under it.
#   - bash 3.2 compat (R-23). Single-deliverable per R-37.
#
# Env knobs (override defaults; tests + dogfood):
#   AUTO_CONFIRM=1   non-interactive (skip y/n prompt; tests + dogfood)
#   RENDER_LAUNCHD   path to render-launchd.sh
#                    default: $CLAUDE_HOME/installer/render-launchd.sh
#   STAGING_DIR      override staging dir
#                    default: $CLAUDE_HOME/Library/LaunchAgents.staging
#   AUDIT_LOG        override audit JSONL path
#                    default: $CLAUDE_HOME/onboarding/audit/initial-job-setup.jsonl
#
# Exit codes:
#   0  success | opt-out #9 short-circuit | user-declined dry-run
#   2  bad invocation / missing dependency
#   3  orchestration.json read error
#   4  render-launchd.sh failed (dry-run or staging-write)
#   5  audit write failed

set -u

diag() { printf 'initial-job-setup FAIL: %s\n' "$1" >&2; }
info() { printf 'initial-job-setup: %s\n' "$1"; }

# --- source paths.sh (post-install runtime path) ---
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ ! -r "$PATHS_SH" ]; then
  diag "paths.sh not readable at $PATHS_SH"
  exit 2
fi
# shellcheck source=/dev/null
. "$PATHS_SH"

# --- dependency check ---
for tool in jq date; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    diag "$tool required but not on PATH"
    exit 2
  fi
done

# --- resolve runtime paths ---
RENDER_LAUNCHD="${RENDER_LAUNCHD:-$CLAUDE_HOME/installer/render-launchd.sh}"
STAGING_DIR="${STAGING_DIR:-$CLAUDE_HOME/Library/LaunchAgents.staging}"
AUDIT_LOG="${AUDIT_LOG:-$CLAUDE_HOME/onboarding/audit/initial-job-setup.jsonl}"

if [ ! -x "$RENDER_LAUNCHD" ]; then
  diag "render-launchd.sh not executable at $RENDER_LAUNCHD"
  exit 2
fi

audit_dir=$(dirname "$AUDIT_LOG")
if ! mkdir -p "$audit_dir" 2>/dev/null; then
  diag "cannot mkdir -p $audit_dir"
  exit 5
fi

# --- audit helpers (jq for safe field encoding) ---
audit_opt_out() {
  local reason="${1:-}"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if [ -n "$reason" ]; then
    jq -cn --arg ts "$ts" --arg reason "$reason" \
      '{timestamp:$ts, event:"opt_out_9_skip", reason:$reason}' \
      >> "$AUDIT_LOG" || { diag "audit write failed"; exit 5; }
  else
    jq -cn --arg ts "$ts" \
      '{timestamp:$ts, event:"opt_out_9_skip"}' \
      >> "$AUDIT_LOG" || { diag "audit write failed"; exit 5; }
  fi
}

audit_staged() {
  local job="$1" schedule="$2" plist="$3"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -cn --arg ts "$ts" --arg job "$job" --arg schedule "$schedule" --arg plist "$plist" \
    '{timestamp:$ts, event:"staged", job:$job, schedule:$schedule, plist_path:$plist}' \
    >> "$AUDIT_LOG" || { diag "audit write failed"; exit 5; }
}

audit_render_failed() {
  local job="$1" phase="$2"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -cn --arg ts "$ts" --arg job "$job" --arg phase "$phase" \
    '{timestamp:$ts, event:"render_failed", job:$job, phase:$phase}' \
    >> "$AUDIT_LOG" || { diag "audit write failed"; exit 5; }
}

audit_declined() {
  local job="$1"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -cn --arg ts "$ts" --arg job "$job" \
    '{timestamp:$ts, event:"user_declined", job:$job}' \
    >> "$AUDIT_LOG" || { diag "audit write failed"; exit 5; }
}

# --- read orchestration.json ---
if [ ! -r "${ORCHESTRATION_JSON:-}" ]; then
  diag "ORCHESTRATION_JSON not readable: ${ORCHESTRATION_JSON:-<unset>}"
  exit 3
fi

jobs_count=$(jq -r '.jobs | length' "$ORCHESTRATION_JSON" 2>/dev/null)
case "$jobs_count" in
  ''|*[!0-9]*)
    diag "orchestration.json .jobs is not an array (got: '$jobs_count')"
    exit 3
    ;;
esac

# --- opt-out #9: empty jobs[] → skip module entirely ---
if [ "$jobs_count" -eq 0 ]; then
  audit_opt_out
  info "Opt-out elected: no autonomous job configured. Run \`claude onboard rerun\` to add one later."
  exit 0
fi

# --- read jobs[0] ---
job_id=$(jq -r '.jobs[0].id // empty' "$ORCHESTRATION_JSON" 2>/dev/null)
case "$job_id" in
  librarian|architect)
    : # supported
    ;;
  none|"")
    # Defensive: opt-out should have reduced jobs[] to []; treat 'none' as opt-out.
    audit_opt_out "jobs[0].id=$job_id"
    info "Opt-out elected: no autonomous job configured."
    exit 0
    ;;
  *)
    diag "jobs[0].id must be librarian|architect|none (got: '$job_id')"
    exit 3
    ;;
esac

# --- format human-readable schedule ---
sched_hour=$(jq -r '.jobs[0].schedule.hour // empty' "$ORCHESTRATION_JSON")
sched_minute=$(jq -r '.jobs[0].schedule.minute // empty' "$ORCHESTRATION_JSON")
sched_dow=$(jq -r '.jobs[0].schedule.dow[0] // empty' "$ORCHESTRATION_JSON")

if [ -z "$sched_hour" ] || [ -z "$sched_minute" ]; then
  diag "jobs[0].schedule missing hour or minute"
  exit 3
fi

dow_name() {
  case "$1" in
    0) printf 'Sunday' ;;
    1) printf 'Monday' ;;
    2) printf 'Tuesday' ;;
    3) printf 'Wednesday' ;;
    4) printf 'Thursday' ;;
    5) printf 'Friday' ;;
    6) printf 'Saturday' ;;
    *) printf 'day-%s' "$1" ;;
  esac
}

if [ "$job_id" = "architect" ] && [ -n "$sched_dow" ]; then
  schedule_human=$(printf 'weekly %s at %02d:%02d' "$(dow_name "$sched_dow")" "$sched_hour" "$sched_minute")
else
  schedule_human=$(printf 'daily at %02d:%02d' "$sched_hour" "$sched_minute")
fi

# --- expected staged plist path (deterministic from job + LABEL_PREFIX) ---
LABEL_PREFIX_LOCAL="${LABEL_PREFIX:-com.claude-foundations}"
case "$job_id" in
  librarian) label_full="${LABEL_PREFIX_LOCAL}.librarian-scan" ;;
  architect) label_full="${LABEL_PREFIX_LOCAL}.architect-analysis" ;;
esac
expected_plist="$STAGING_DIR/${label_full}.plist"

# --- dry-run preview ---
info ""
info "Job:      $job_id"
info "Schedule: $schedule_human"
info "Staging:  $STAGING_DIR/"
info ""
info "Rendered plist preview:"
info "----------"
if ! "$RENDER_LAUNCHD" --dry-run --staging-dir "$STAGING_DIR" "$job_id"; then
  diag "render-launchd dry-run failed for job '$job_id'"
  audit_render_failed "$job_id" "dry-run"
  exit 4
fi
info "----------"
info ""

# --- confirm + stage ---
if [ "${AUTO_CONFIRM:-0}" != "1" ]; then
  printf 'Stage this plist to %s ? [Y/n] ' "$STAGING_DIR" >&2
  read -r reply
  case "$reply" in
    n|N|no|NO|No)
      audit_declined "$job_id"
      info "Staging declined. No plist written."
      exit 0
      ;;
  esac
fi

if ! mkdir -p "$STAGING_DIR" 2>/dev/null; then
  diag "cannot mkdir -p $STAGING_DIR"
  exit 4
fi

if ! "$RENDER_LAUNCHD" --staging-dir "$STAGING_DIR" "$job_id"; then
  diag "render-launchd staging-write failed for job '$job_id'"
  audit_render_failed "$job_id" "staging-write"
  exit 4
fi

if [ ! -f "$expected_plist" ]; then
  diag "expected staged plist not found at $expected_plist"
  audit_render_failed "$job_id" "post-write-verify"
  exit 4
fi

audit_staged "$job_id" "$schedule_human" "$expected_plist"

info ""
info "Plist staged at: $expected_plist"
info ""
info "Onboarding complete. Run \`claude system enable-daemon\` to activate librarian+architect launchd jobs."
exit 0
