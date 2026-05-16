#!/bin/bash
# SessionStart hook: surface cron errors and tripwire hits from the last 24h.
# Observes two surfaces: (1) $VAULT_LOGS/*cron-error*.md and *-error-*.md files,
# (2) $HOOKS_STATE/tripwire.log ISO-timestamped lines. Writes an additionalContext
# banner via hookSpecificOutput JSON on stdout.
#
# Observability-of-observability: any failure in the main logic writes a
# cron-health-banner-error-YYYYMMDD.md to $VAULT_LOGS. morning-brief and
# librarian session-close both glob *-error-*.md — so the observer's own
# failures are caught by the other two layers.
#
# Freshness: filesystem mtime is NOT reliable on these files (uniform touch
# events from git/archive ops). Parse the embedded YYYYMMDD-HHMMSS timestamp
# from each filename instead.
#
# NEVER fail-hard: final `exit 0` is mandatory. SessionStart hooks that
# non-zero exit can break the user's session.

set -uo pipefail  # NO -e — we handle errors in the top-level trap block

source "$HOME/.claude/hooks/lib/paths.sh"
source "$HOME/.claude/hooks/lib/registry.sh"

THRESHOLD_SECONDS=$((24*3600))
MANIFEST_ADVISORY_SECONDS=$((24*3600))
MANIFEST_BLOCKING_SECONDS=$((48*3600))
RESEARCH_QUEUE_ORPHAN_SECONDS=$((72*3600))
AUTO_COMMIT_WINDOW_SECONDS=$((24*3600))
ERR_LOG="$VAULT_LOGS/cron-health-banner-error-$(date +%Y%m%d).md"
MANIFEST_PATH_LOCAL="${MANIFEST_PATH_LOCAL:-$VAULT_LOGS/librarian-manifest.json}"
RESEARCH_QUEUE_PATH="${RESEARCH_QUEUE_PATH:-$HOOKS_STATE/research-queue.json}"
AUTO_COMMIT_LOG_PATH="${AUTO_COMMIT_LOG_PATH:-$HOOKS_STATE/auto-commit.log}"

# Self-error handler — writes a vault error file so morning-brief + librarian
# pick it up on their next run. NEVER touches stdout (would corrupt JSON).
log_self_error() {
  local exit_code="${1:-?}"
  local stage="${2:-unknown}"
  mkdir -p "$VAULT_LOGS" 2>/dev/null || return 0
  {
    echo "---"
    echo "type: log"
    echo "log-type: cron-health-banner-error"
    echo "date: $(date +%Y-%m-%d 2>/dev/null || echo unknown)"
    echo "---"
    echo ""
    echo "$(date -Iseconds 2>/dev/null || echo unknown) cron-health-banner.sh FAIL stage=${stage} exit=${exit_code}"
  } >> "$ERR_LOG" 2>/dev/null || true
}

# Parse filename-embedded YYYYMMDD-HHMMSS timestamp → epoch seconds.
# Returns 0 on parse failure (treated as "very old", won't match 24h window).
cron_error_epoch() {
  local ts
  ts=$(basename "$1" 2>/dev/null | grep -oE '[0-9]{8}-[0-9]{6}' | head -1)
  [[ -z "$ts" ]] && { echo 0; return; }
  date -j -f "%Y%m%d%H%M%S" "${ts:0:8}${ts:9:6}" +%s 2>/dev/null || echo 0
}

main() {
  local now error_count=0 latest_err_epoch=0 latest_err_file="" latest_err_cron=""
  local tripwire_count=0 latest_trip_line=""
  local manifest_age=0 manifest_severity="" manifest_age_str=""
  local research_orphan_count=0 research_orphan_oldest_age=0 research_orphan_oldest_project=""
  local autocommit_failure_count=0 autocommit_latest_ts=""

  now=$(date +%s)

  # Surface 1: vault cron error files.
  # Globs overlap (a "*cron-error*.md" also matches "*-error-*.md"), so
  # dedupe via sort -u before counting. macOS bash 3.2 has no assoc arrays.
  shopt -s nullglob
  local all_files=()
  for f in "$VAULT_LOGS"/*cron-error*.md "$VAULT_LOGS"/*-error-*.md; do
    [[ -f "$f" ]] && all_files+=("$f")
  done
  local uniq_files=()
  if (( ${#all_files[@]} > 0 )); then
    while IFS= read -r f; do
      uniq_files+=("$f")
    done < <(printf '%s\n' "${all_files[@]}" | sort -u)
  fi
  # Bash 3.2 + `set -u` trips on ${arr[@]} when arr is empty. Guard the loop
  # so the error-file pass silently no-ops when no cron-error files exist.
  if (( ${#uniq_files[@]} > 0 )); then
    for f in "${uniq_files[@]}"; do
      [[ -f "$f" ]] || continue
      local epoch age
      epoch=$(cron_error_epoch "$f")
      age=$(( now - epoch ))
      if (( epoch > 0 && age >= 0 && age <= THRESHOLD_SECONDS )); then
        error_count=$(( error_count + 1 ))
        if (( epoch > latest_err_epoch )); then
          latest_err_epoch=$epoch
          latest_err_file="$f"
          latest_err_cron=$(basename "$f" | sed -E 's/-error-[0-9]{8}-[0-9]{6}\.md$//')
        fi
      fi
    done
  fi
  shopt -u nullglob

  # Surface 2: tripwire.log (ISO-prefix line scan, not file mtime)
  if [[ -f "$HOOKS_STATE/tripwire.log" ]]; then
    local cutoff_iso
    cutoff_iso=$(date -j -v-24H +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "")
    if [[ -n "$cutoff_iso" ]]; then
      while IFS= read -r line; do
        local line_iso
        line_iso=$(echo "$line" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}')
        [[ -z "$line_iso" ]] && continue
        if [[ "$line_iso" > "$cutoff_iso" ]] && echo "$line" | grep -q "TRIPWIRE:"; then
          tripwire_count=$(( tripwire_count + 1 ))
          latest_trip_line="$line"
        fi
      done < "$HOOKS_STATE/tripwire.log"
    fi
  fi

  # Surface 3: librarian-manifest.json staleness (R-43 advisory).
  # 24h → advisory, 48h → blocking-severity advisory (still Tier 1, no session block).
  if [[ -f "$MANIFEST_PATH_LOCAL" ]]; then
    local manifest_mtime
    manifest_mtime=$(stat -f '%m' "$MANIFEST_PATH_LOCAL" 2>/dev/null || echo 0)
    if (( manifest_mtime > 0 )); then
      manifest_age=$(( now - manifest_mtime ))
      if (( manifest_age >= MANIFEST_BLOCKING_SECONDS )); then
        manifest_severity="blocking"
        manifest_age_str="$(( manifest_age / 3600 ))h"
      elif (( manifest_age >= MANIFEST_ADVISORY_SECONDS )); then
        manifest_severity="advisory"
        manifest_age_str="$(( manifest_age / 3600 ))h"
      fi
    fi
  fi

  # Surface 4: research-queue.json orphans (R-44 advisory, 72h threshold).
  if [[ -f "$RESEARCH_QUEUE_PATH" ]] && command -v jq >/dev/null 2>&1; then
    # Iterate pending entries; jq's // empty keeps us safe on missing keys.
    local rq_line rq_age rq_project
    while IFS=$'\t' read -r rq_age rq_project; do
      [[ -z "$rq_age" ]] && continue
      if (( rq_age >= RESEARCH_QUEUE_ORPHAN_SECONDS )); then
        research_orphan_count=$(( research_orphan_count + 1 ))
        if (( rq_age > research_orphan_oldest_age )); then
          research_orphan_oldest_age=$rq_age
          research_orphan_oldest_project=$rq_project
        fi
      fi
    done < <(jq -r --argjson now "$now" '
      .queue[]?
      | select(.status == "pending")
      | select((.queued_at // null) != null)
      | ((.queued_at | fromdateiso8601? // 0) as $q
         | ($now - $q) as $age
         | [$age, (.project // "(unnamed)")] | @tsv)
    ' "$RESEARCH_QUEUE_PATH" 2>/dev/null || true)
  fi

  # Surface 5: auto-commit silent-failure tripwire (R-49 advisory, 24h window).
  # Plan 64 Sub-plan 05 T-3 (2026-04-21). Scans auto-commit.log for lines
  # containing "Hook cancelled" or "SessionEnd hook failed" — SessionEnd
  # auto-commit-surfaces.sh death-rattle indicators. Non-blocking advisory.
  if [[ -f "$AUTO_COMMIT_LOG_PATH" ]]; then
    local cutoff_autocommit_iso
    cutoff_autocommit_iso=$(date -j -v-24H +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "")
    if [[ -n "$cutoff_autocommit_iso" ]]; then
      local ac_line ac_iso
      while IFS= read -r ac_line; do
        # lines look like: 2026-04-14T10:32:39-04:00 auto-commit-surfaces start...
        ac_iso=$(echo "$ac_line" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}')
        [[ -z "$ac_iso" ]] && continue
        if [[ "$ac_iso" > "$cutoff_autocommit_iso" ]]; then
          if echo "$ac_line" | grep -qE 'Hook cancelled|SessionEnd hook failed'; then
            autocommit_failure_count=$(( autocommit_failure_count + 1 ))
            autocommit_latest_ts="$ac_iso"
          fi
        fi
      done < "$AUTO_COMMIT_LOG_PATH"
    fi
  fi

  # Silent when clean across all five surfaces.
  if (( error_count == 0 && tripwire_count == 0 && research_orphan_count == 0 \
        && autocommit_failure_count == 0 )) \
     && [[ -z "$manifest_severity" ]]; then
    return 0
  fi

  # Emit banner via hookSpecificOutput.additionalContext
  local latest_err_ts="" latest_err_rel=""
  if (( latest_err_epoch > 0 )); then
    latest_err_ts=$(date -r "$latest_err_epoch" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "")
    latest_err_rel="${latest_err_file#$HOME/}"
  fi
  [[ -z "$latest_trip_line" ]] && latest_trip_line="(none)"
  [[ -z "$latest_err_ts" ]] && latest_err_ts="(none)"
  [[ -z "$latest_err_cron" ]] && latest_err_cron="(none)"
  [[ -z "$latest_err_rel" ]] && latest_err_rel="(none)"

  # Escape for JSON (backslash, doublequote, newline)
  local banner_text
  printf -v banner_text '⚠ CRON HEALTH (last 24h): %d cron errors, %d tripwire hits\n  Latest error: %s %s → %s\n  Latest tripwire: %s\n  Run /morning-brief for full health section.' \
    "$error_count" "$tripwire_count" "$latest_err_ts" "$latest_err_cron" "$latest_err_rel" "$latest_trip_line"

  # R-43 append: librarian-manifest staleness advisory.
  if [[ -n "$manifest_severity" ]]; then
    local manifest_line
    printf -v manifest_line '\n⚠ MANIFEST STALENESS [%s]: librarian-manifest.json is %s old (threshold: %s→advisory, %s→blocking). Consider running `/librarian full`.' \
      "$manifest_severity" "$manifest_age_str" \
      "$((MANIFEST_ADVISORY_SECONDS / 3600))h" "$((MANIFEST_BLOCKING_SECONDS / 3600))h"
    banner_text="${banner_text}${manifest_line}"
  fi

  # R-44 append: research-queue orphan advisory.
  if (( research_orphan_count > 0 )); then
    local queue_line
    printf -v queue_line '\n⚠ RESEARCH QUEUE ORPHANS: %d pending entries older than %sh. Oldest: "%s" (%sh). Review %s.' \
      "$research_orphan_count" "$((RESEARCH_QUEUE_ORPHAN_SECONDS / 3600))" \
      "$research_orphan_oldest_project" "$((research_orphan_oldest_age / 3600))" \
      "$RESEARCH_QUEUE_PATH"
    banner_text="${banner_text}${queue_line}"
  fi

  # R-49 append: auto-commit silent-failure advisory.
  if (( autocommit_failure_count > 0 )); then
    local autocommit_line
    printf -v autocommit_line '\n⚠ AUTO-COMMIT FAILURES (last 24h): %d occurrence(s) of "Hook cancelled" / "SessionEnd hook failed" in %s. Latest: %s. SessionEnd auto-commit-surfaces.sh may be silently dropping commits — investigate.' \
      "$autocommit_failure_count" "$AUTO_COMMIT_LOG_PATH" "$autocommit_latest_ts"
    banner_text="${banner_text}${autocommit_line}"
  fi

  format_output "SessionStart" "$banner_text" || true
}

# Top-level try/catch: main() runs, any failure lands in log_self_error.
# Always exit 0 so SessionStart never breaks. Capture rc before the `if`
# branch consumes it.
main
rc=$?
if (( rc != 0 )); then
  log_self_error "$rc" "main"
fi

exit 0
