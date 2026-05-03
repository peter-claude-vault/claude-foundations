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
#   AUTO_CONFIRM=1   non-interactive (skip 8-Q interview + y/n staging prompt)
#   AUTO_OVERRIDES   hermetic interview answers; CSV "Q1=v,Q2=v,...,Q8=v"
#                    when set, interview runs reading from CSV (overrides
#                    AUTO_CONFIRM's interview-skip; AUTO_CONFIRM still
#                    auto-confirms staging). Q-keys absent from CSV accept
#                    the pre-filled default.
#   RENDER_LAUNCHD   path to render-launchd.sh
#                    default: $CLAUDE_HOME/installer/render-launchd.sh
#   STAGING_DIR      override staging dir
#                    default: $CLAUDE_HOME/Library/LaunchAgents.staging
#   AUDIT_LOG        override audit JSONL path
#                    default: $CLAUDE_HOME/onboarding/audit/initial-job-setup.jsonl
#   USER_MANIFEST_JSON  optional path to user-manifest.json; if set + readable,
#                    Q3 timezone overrides are written back to U.system.timezone
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

# Reference-leak floor (Hard Rule 9): corrections[] holds field-path strings
# only. No user-typed values flow into audit values.
audit_interview_override() {
  local job="$1" corrections="$2"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -cn --arg ts "$ts" --arg job "$job" --arg c "$corrections" \
    '{timestamp:$ts, event:"interview_override", job:$job, corrections:($c | split(",") | map(select(. != "")))}' \
    >> "$AUDIT_LOG" || { diag "audit write failed"; exit 5; }
}

audit_interview_opt_out() {
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -cn --arg ts "$ts" \
    '{timestamp:$ts, event:"interview_opt_out_9"}' \
    >> "$AUDIT_LOG" || { diag "audit write failed"; exit 5; }
}

# --- 8-Q interview surface (T-9 AC #8) ---
# Implements onboarding/initial-job-setup-flow.md (SP03 T-12 contract):
# 8 user-facing surfacings of D-2 defaults_applied. Modes:
#   AUTO_OVERRIDES set        → CSV-driven (hermetic); per-Q lookup
#   AUTO_CONFIRM=1, no AUTO_OVERRIDES → skip interview entirely
#   else                      → interactive (stdin)

default_for_job() {
  local jid="$1" field="$2"
  case "${jid}__${field}" in
    librarian__hour)          printf '6' ;;
    librarian__minute)        printf '0' ;;
    librarian__budget_usd)    printf '5' ;;
    librarian__model)         printf 'sonnet' ;;
    librarian__skip_weekends) printf 'true' ;;
    librarian__log_path)      printf '%s/logs' "$CLAUDE_HOME" ;;
    architect__hour)          printf '6' ;;
    architect__minute)        printf '0' ;;
    architect__dow)           printf '1' ;;
    architect__budget_usd)    printf '10' ;;
    architect__model)         printf 'opus' ;;
    architect__log_path)      printf '%s/logs' "$CLAUDE_HOME" ;;
  esac
}

auto_override_for() {
  local qkey="$1" overrides="${AUTO_OVERRIDES:-}"
  [ -z "$overrides" ] && return 0
  printf '%s\n' "$overrides" | tr ',' '\n' | awk -F= -v k="$qkey" '$1 == k {sub(/^[^=]+=/, ""); print; exit}'
}

# Mirrors installer/render-launchd.sh:169 (privilege-free, launchd-context-safe).
detect_tz() {
  local tz="${TZ:-$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')}"
  printf '%s' "${tz:-America/New_York}"
}

valid_time()   { printf '%s' "$1" | grep -E '^([01]?[0-9]|2[0-3]):[0-5][0-9]$' >/dev/null 2>&1; }
valid_tz()     { case "$1" in */*) return 0 ;; *) return 1 ;; esac; }
valid_dow()    { case "$1" in [0-6]) return 0 ;; *) return 1 ;; esac; }
valid_path()   { case "$1" in /*|"~/"*) return 0 ;; *) return 1 ;; esac; }
valid_budget() { printf '%s' "$1" | grep -E '^[0-9]+(\.[0-9]+)?$' >/dev/null 2>&1; }
valid_model()  { case "$1" in sonnet|opus|haiku) return 0 ;; *) return 1 ;; esac; }
valid_yesno()  { case "$1" in y|yes|Y|YES|n|no|N|NO) return 0 ;; *) return 1 ;; esac; }

yesno_to_bool() { case "$1" in y|yes|Y|YES) printf 'true' ;; *) printf 'false' ;; esac; }

expand_path() {
  # Bash 3.2: ${var#~/} undergoes tilde expansion in the pattern (~ → $HOME)
  # before matching, so the strip silently fails. Use substring slicing.
  case "$1" in
    "~/"*) printf '%s/%s' "$HOME" "${1:2}" ;;
    *)     printf '%s' "$1" ;;
  esac
}

# Atomic orchestration.json replacement from stdin.
write_orch_atomic() {
  local tmp="$ORCHESTRATION_JSON.tmp.$$"
  cat > "$tmp" || { diag "orchestration tmp write failed"; exit 5; }
  mv "$tmp" "$ORCHESTRATION_JSON" || { diag "orchestration mv failed"; exit 5; }
}

# Q reader. When AUTO_OVERRIDES is set, hermetic mode: the override is the
# only input source — Q-keys absent from CSV silently accept the default
# (no stdin read, no prompt rendered). Otherwise interactive: render prompt
# on stderr, read from stdin, fall back to default on EOF.
ask_q() {
  local qkey="$1" prompt="$2" deflt="$3" override answer
  override="$(auto_override_for "$qkey")"
  if [ -n "$override" ]; then
    printf '%s' "$override"
    return 0
  fi
  if [ -n "${AUTO_OVERRIDES:-}" ]; then
    printf '%s' "$deflt"
    return 0
  fi
  printf '\n%s\n[default: %s] > ' "$prompt" "$deflt" >&2
  if ! IFS= read -r answer; then
    printf '%s' "$deflt"
    return 0
  fi
  if [ -z "$answer" ]; then
    printf '%s' "$deflt"
  else
    printf '%s' "$answer"
  fi
}

# Globals updated: job_id, orchestration.json (atomic), RESOLVED_TZ.
# May exit 0 (Q1=none short-circuit).
run_interview_8q() {
  RESOLVED_TZ="$(detect_tz)"
  if [ "${AUTO_CONFIRM:-0}" = "1" ] && [ -z "${AUTO_OVERRIDES:-}" ]; then
    return 0
  fi

  local corrections="" ans_q1 new_id cur_id
  cur_id="$job_id"

  ans_q1="$(ask_q Q1 "Which autonomous job should we set up first?
  1. librarian — daily vault hygiene + memory consolidation (~6:00 AM, ~\$5/run, sonnet)
  2. architect — weekly system audit + recommendations (Mondays 6:00 AM, ~\$10/run, opus)
  3. none      — skip; no scheduled job is set up." "$cur_id")"
  case "$ans_q1" in
    1|librarian) new_id="librarian" ;;
    2|architect) new_id="architect" ;;
    3|none)
      jq '.jobs = []' "$ORCHESTRATION_JSON" | write_orch_atomic
      audit_interview_opt_out
      info "Opt-out elected via interview: no autonomous job configured."
      exit 0
      ;;
    *) diag "Q1 invalid: '$ans_q1' (expected librarian|architect|none)"; exit 3 ;;
  esac

  if [ "$new_id" != "$cur_id" ]; then
    # Replace jobs[0] with re-derived per-job defaults for new_id.
    local def_budget def_model def_log
    def_budget="$(default_for_job "$new_id" budget_usd)"
    def_model="$(default_for_job "$new_id" model)"
    def_log="$(default_for_job "$new_id" log_path)"
    if [ "$new_id" = "architect" ]; then
      jq --arg id "$new_id" --arg model "$def_model" --arg log "$def_log" --argjson budget "$def_budget" \
         '.jobs[0] = {id:$id, enabled:true, schedule:{hour:6, minute:0, dow:[1]}, command:.jobs[0].command, log_path:$log, idle_watchdog_sec:180, budget_usd:$budget, model:$model}' \
         "$ORCHESTRATION_JSON" | write_orch_atomic
    else
      jq --arg id "$new_id" --arg model "$def_model" --arg log "$def_log" --argjson budget "$def_budget" \
         '.jobs[0] = {id:$id, enabled:true, schedule:{hour:6, minute:0}, command:.jobs[0].command, log_path:$log, idle_watchdog_sec:180, budget_usd:$budget, model:$model, skip_weekends:true}' \
         "$ORCHESTRATION_JSON" | write_orch_atomic
    fi
    job_id="$new_id"
    corrections="O.jobs[0].id"
  fi

  local cur_hour cur_minute cur_dow cur_log_path cur_budget cur_model cur_skipw
  cur_hour=$(jq -r '.jobs[0].schedule.hour' "$ORCHESTRATION_JSON")
  cur_minute=$(jq -r '.jobs[0].schedule.minute' "$ORCHESTRATION_JSON")
  cur_dow=$(jq -r '.jobs[0].schedule.dow[0] // empty' "$ORCHESTRATION_JSON")
  cur_log_path=$(jq -r '.jobs[0].log_path // empty' "$ORCHESTRATION_JSON")
  cur_budget=$(jq -r '.jobs[0].budget_usd // empty' "$ORCHESTRATION_JSON")
  cur_model=$(jq -r '.jobs[0].model // empty' "$ORCHESTRATION_JSON")
  cur_skipw=$(jq -r '.jobs[0].skip_weekends // empty' "$ORCHESTRATION_JSON")

  # Validate-on-change: only validate user-provided overrides (Q-key supplied
  # via AUTO_OVERRIDES, or interactive answer differing from default). If the
  # user accepted the default verbatim, the value flows through unchanged —
  # upstream owns default-validity (Section D / schema validation).

  local cur_time ans_q2
  cur_time=$(printf '%02d:%02d' "$cur_hour" "$cur_minute")
  ans_q2="$(ask_q Q2 "What time should the job fire? (24-hour HH:MM)" "$cur_time")"
  if [ "$ans_q2" != "$cur_time" ]; then
    if ! valid_time "$ans_q2"; then diag "Q2 invalid time: '$ans_q2'"; exit 3; fi
    local nh nm
    nh="${ans_q2%%:*}"; nm="${ans_q2##*:}"
    nh=$((10#$nh)); nm=$((10#$nm))
    jq --argjson h "$nh" --argjson m "$nm" \
       '.jobs[0].schedule.hour = $h | .jobs[0].schedule.minute = $m' \
       "$ORCHESTRATION_JSON" | write_orch_atomic
    corrections="${corrections:+$corrections,}O.jobs[0].schedule.hour,O.jobs[0].schedule.minute"
  fi

  local ans_q3
  ans_q3="$(ask_q Q3 "Confirm your timezone (IANA Continent/City)" "$RESOLVED_TZ")"
  if [ "$ans_q3" != "$RESOLVED_TZ" ]; then
    if ! valid_tz "$ans_q3"; then diag "Q3 invalid TZ: '$ans_q3' (must be Continent/City)"; exit 3; fi
    RESOLVED_TZ="$ans_q3"
    corrections="${corrections:+$corrections,}U.system.timezone"
    if [ -n "${USER_MANIFEST_JSON:-}" ] && [ -r "${USER_MANIFEST_JSON}" ]; then
      local utmp="$USER_MANIFEST_JSON.tmp.$$"
      jq --arg tz "$ans_q3" '.system.timezone = $tz' "$USER_MANIFEST_JSON" > "$utmp" \
        && mv "$utmp" "$USER_MANIFEST_JSON"
    fi
  fi

  if [ "$job_id" = "architect" ]; then
    local cur_dow_disp ans_q4
    cur_dow_disp="${cur_dow:-1}"
    ans_q4="$(ask_q Q4 "Which day of the week? (Sun=0 Mon=1 Tue=2 Wed=3 Thu=4 Fri=5 Sat=6)" "$cur_dow_disp")"
    if [ "$ans_q4" != "$cur_dow_disp" ]; then
      if ! valid_dow "$ans_q4"; then diag "Q4 invalid dow: '$ans_q4' (expected 0-6)"; exit 3; fi
      jq --argjson d "$ans_q4" '.jobs[0].schedule.dow = [$d]' "$ORCHESTRATION_JSON" | write_orch_atomic
      corrections="${corrections:+$corrections,}O.jobs[0].schedule.dow"
    fi
  fi

  local cur_log_disp ans_q5 exp_q5
  cur_log_disp="${cur_log_path:-$CLAUDE_HOME/logs}"
  ans_q5="$(ask_q Q5 "Where should cron logs be written?" "$cur_log_disp")"
  if [ "$ans_q5" != "$cur_log_disp" ]; then
    if ! valid_path "$ans_q5"; then diag "Q5 invalid path: '$ans_q5' (must be absolute or ~/...)"; exit 3; fi
    exp_q5="$(expand_path "$ans_q5")"
    jq --arg p "$exp_q5" '.jobs[0].log_path = $p' "$ORCHESTRATION_JSON" | write_orch_atomic
    corrections="${corrections:+$corrections,}O.jobs[0].log_path"
  fi

  local def_budget cur_budget_disp ans_q6
  def_budget="$(default_for_job "$job_id" budget_usd)"
  cur_budget_disp="${cur_budget:-$def_budget}"
  ans_q6="$(ask_q Q6 "Per-call budget cap (USD)?" "$cur_budget_disp")"
  if [ "$ans_q6" != "$cur_budget_disp" ]; then
    if ! valid_budget "$ans_q6"; then diag "Q6 invalid budget: '$ans_q6' (must be numeric ≥0)"; exit 3; fi
    jq --argjson b "$ans_q6" '.jobs[0].budget_usd = $b' "$ORCHESTRATION_JSON" | write_orch_atomic
    corrections="${corrections:+$corrections,}O.jobs[0].budget_usd"
  fi

  local def_model cur_model_disp ans_q7
  def_model="$(default_for_job "$job_id" model)"
  cur_model_disp="${cur_model:-$def_model}"
  ans_q7="$(ask_q Q7 "Which Claude model? (sonnet|opus|haiku)" "$cur_model_disp")"
  if [ "$ans_q7" != "$cur_model_disp" ]; then
    if ! valid_model "$ans_q7"; then diag "Q7 invalid model: '$ans_q7' (expected sonnet|opus|haiku)"; exit 3; fi
    jq --arg m "$ans_q7" '.jobs[0].model = $m' "$ORCHESTRATION_JSON" | write_orch_atomic
    corrections="${corrections:+$corrections,}O.jobs[0].model"
  fi

  if [ "$job_id" = "librarian" ]; then
    local cur_skipw_disp cur_skipw_yn ans_q8 new_skipw
    cur_skipw_disp="${cur_skipw:-true}"
    if [ "$cur_skipw_disp" = "true" ]; then cur_skipw_yn="yes"; else cur_skipw_yn="no"; fi
    ans_q8="$(ask_q Q8 "Skip weekend runs (Saturday + Sunday)?" "$cur_skipw_yn")"
    if [ "$ans_q8" != "$cur_skipw_yn" ]; then
      if ! valid_yesno "$ans_q8"; then diag "Q8 invalid: '$ans_q8' (expected yes|no)"; exit 3; fi
      new_skipw="$(yesno_to_bool "$ans_q8")"
      if [ "$new_skipw" != "$cur_skipw_disp" ]; then
        jq --argjson sw "$new_skipw" '.jobs[0].skip_weekends = $sw' "$ORCHESTRATION_JSON" | write_orch_atomic
        corrections="${corrections:+$corrections,}O.jobs[0].skip_weekends"
      fi
    fi
  fi

  if [ -n "$corrections" ]; then
    audit_interview_override "$job_id" "$corrections"
  fi
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

# --- 8-Q interview surface (T-9 AC #8) ---
# May mutate orchestration.json and global job_id; may exit 0 (Q1=none).
# Sets RESOLVED_TZ for downstream render-launchd.sh export.
run_interview_8q
export TZ="$RESOLVED_TZ"

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
LABEL_PREFIX_LOCAL="${LABEL_PREFIX:-com.claude-stem}"
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
info ""
info "What just happened, and why? See docs/personalization-model.md for the universal/combined/personal classification of every artifact onboarding wrote, plus instructions for auditing any generated file via its provenance frontmatter."
exit 0
