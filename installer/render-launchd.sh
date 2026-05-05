#!/bin/bash
# installer/render-launchd.sh — render a launchd plist from a template against
# orchestration.json, plutil-lint, atomically install to a target dir, and
# (production mode only) launchctl-bootstrap the resolved label.
#
# Usage: render-launchd.sh [--staging-dir <path>] [--dry-run] <job>
#
# Modes (mutually composable):
#   default                Production install. Writes to ~/Library/LaunchAgents/<Label>.plist,
#                          unconditionally `launchctl bootout` then `launchctl bootstrap`.
#                          Used by SP08 `claude system enable-daemon`.
#   --staging-dir <path>   Staging install. Writes to <path>/<Label>.plist, skips
#                          launchctl bootout + bootstrap entirely. Used by SP07 onboarder
#                          T-9 (initial-job-setup) — satisfies SP00 invariant I2 +
#                          SP07 spec L86-102 launchctl bootstrap isolation.
#   --dry-run              Renders + plutil-lints, prints rendered plist to stdout, NO
#                          write/bootstrap. Composable with --staging-dir.
#
# <job> is a template basename (`librarian` | `architect`); must match
# `^[a-z][a-z0-9-]*$` and have a corresponding `templates/launchd/<job>.plist.tmpl`.
# orchestration.json must contain a jobs[] entry with `id == <job>` using the
# StartCalendarInterval schedule branch (hour/minute, optional dow[0]).
#
# LABEL_PREFIX defaults to `com.claude-stem` (matches SP08 G6 namespace
# isolation — labels outside this prefix are refused by uninstall.sh).
#
# Exit codes:
#   0  success
#   2  bad invocation (missing/bad arg, missing template, dependency missing)
#   3  orchestration.json read error (missing file, jobs[].id absent, bad schedule)
#   4  rendered plist failed plutil -lint or atomic mv failed
#   5  rendered Label extraction failed or Label format invalid
#   6  launchctl bootstrap returned non-zero (production mode only)
#
# Dependencies: jq, envsubst (GNU gettext; `brew install gettext`), plutil,
# launchctl (production mode only).
#
# R-23: bash 3.2 compat. R-37 single-deliverable.

set -u

diag() { printf 'render-launchd FAIL: %s\n' "$1" >&2; }
info() { printf 'render-launchd: %s\n' "$1"; }

# --- arg parse ---
staging_dir=""
dry_run=0
job=""

while [ $# -gt 0 ]; do
  case "$1" in
    --staging-dir)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        diag "--staging-dir requires a path argument"
        exit 2
      fi
      staging_dir="$2"
      shift 2
      ;;
    --staging-dir=*)
      staging_dir="${1#--staging-dir=}"
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      diag "unknown flag: $1"
      exit 2
      ;;
    *)
      if [ -n "$job" ]; then
        diag "extra positional arg: $1 (job already set to '$job')"
        exit 2
      fi
      job="$1"
      shift
      ;;
  esac
done

if [ -z "$job" ]; then
  diag "missing <job> arg. Usage: render-launchd.sh [--staging-dir <path>] [--dry-run] <job>"
  exit 2
fi
case "$job" in
  *[!a-z0-9-]*|[!a-z]*|"")
    diag "<job> must match ^[a-z][a-z0-9-]*\$ (got: '$job')"
    exit 2
    ;;
esac

# --- source paths.sh (post-install runtime path) ---
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ ! -r "$PATHS_SH" ]; then
  diag "paths.sh not readable at $PATHS_SH"
  exit 2
fi
# shellcheck source=/dev/null
. "$PATHS_SH"

# --- locate template ---
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$self_dir/.." && pwd)"
TEMPLATE="$repo_root/templates/launchd/$job.plist.tmpl"
if [ ! -r "$TEMPLATE" ]; then
  diag "template not readable: $TEMPLATE"
  exit 2
fi

# --- dependency check ---
for tool in jq plutil; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    diag "$tool required but not found on PATH"
    exit 2
  fi
done
if ! command -v envsubst >/dev/null 2>&1; then
  diag "envsubst required but not found on PATH (install via: brew install gettext)"
  exit 2
fi
# launchctl is only required in production mode; defer that check.

# --- schedule resolution ---
# Sources by job (post-SP14 T-2 generalization):
#   - inbox-processor (SP13 T-12) → INBOX_POLL_INTERVAL_SEC env var only
#     (skips orchestration.json entirely — schedule comes from
#     user-manifest.json#/inbox/poll_interval_minutes consumed by
#     skills/inbox-processor/install-cron.sh)
#   - librarian, architect         → orchestration.json StartCalendarInterval
#     (.schedule.{hour,minute}, plus .schedule.dow[0] for architect Weekday)
#   - digest-run, meeting-processor (SP14 T-2 calendar-shape)
#     → orchestration.json StartCalendarInterval (.schedule.{hour,minute})
#   - chat-scrape, calendar-sync, connector-runtime (SP14 T-2 interval-shape)
#     → orchestration.json StartInterval (.schedule.interval_sec)
#
# The previous "only inbox-processor uses StartInterval" gate (rejecting
# .schedule.interval_sec for all other jobs) was relaxed by SP14 T-2 — the
# orchestration-schema.json oneOf already supports both shapes; render-launchd
# now reads whichever shape orchestration.json declares per-job.
hour=""
minute=""
weekday=""
interval_sec=""

if [ "$job" = "inbox-processor" ]; then
  interval_sec="${INBOX_POLL_INTERVAL_SEC:-}"
  if [ -z "$interval_sec" ]; then
    diag "INBOX_POLL_INTERVAL_SEC env var required for job '$job' (set it via skills/inbox-processor/install-cron.sh)"
    exit 3
  fi
  case "$interval_sec" in
    *[!0-9]*|"")
      diag "INBOX_POLL_INTERVAL_SEC must be a positive integer (got: '$interval_sec')"
      exit 3
      ;;
  esac
  if [ "$interval_sec" -lt 300 ] || [ "$interval_sec" -gt 86400 ]; then
    diag "INBOX_POLL_INTERVAL_SEC must be in [300, 86400] seconds (got: $interval_sec)"
    exit 3
  fi
else
  if [ ! -r "${ORCHESTRATION_JSON:-}" ]; then
    diag "ORCHESTRATION_JSON not readable: ${ORCHESTRATION_JSON:-<unset>}"
    exit 3
  fi

  job_json=$(jq -c --arg id "$job" '.jobs[] | select(.id == $id)' "$ORCHESTRATION_JSON" 2>/dev/null)
  if [ -z "$job_json" ]; then
    diag "orchestration.json has no jobs[] entry with id='$job'"
    exit 3
  fi

  hour=$(printf '%s' "$job_json" | jq -r '.schedule.hour // empty' 2>/dev/null)
  minute=$(printf '%s' "$job_json" | jq -r '.schedule.minute // empty' 2>/dev/null)
  interval_sec_orch=$(printf '%s' "$job_json" | jq -r '.schedule.interval_sec // empty' 2>/dev/null)

  if [ -n "$interval_sec_orch" ]; then
    # Interval-shape branch (SP14 T-2 generalization). Validate range matches
    # the inbox-processor env-var contract for consistency: [300, 86400].
    case "$interval_sec_orch" in
      *[!0-9]*|"")
        diag "orchestration.json job '$job' .schedule.interval_sec must be a positive integer (got: '$interval_sec_orch')"
        exit 3
        ;;
    esac
    if [ "$interval_sec_orch" -lt 300 ] || [ "$interval_sec_orch" -gt 86400 ]; then
      diag "orchestration.json job '$job' .schedule.interval_sec must be in [300, 86400] seconds (got: $interval_sec_orch)"
      exit 3
    fi
    interval_sec="$interval_sec_orch"
  else
    if [ -z "$hour" ] || [ -z "$minute" ]; then
      diag "orchestration.json job '$job' missing schedule.{hour,minute} OR schedule.interval_sec"
      exit 3
    fi
    weekday=$(printf '%s' "$job_json" | jq -r '.schedule.dow[0] // empty' 2>/dev/null)
  fi
fi

# --- compose render-time env vars ---
USER_HOME="$HOME"
# CLAUDE_HOME + CLAUDE_LOG_DIR sourced via paths.sh.
LABEL_PREFIX="${LABEL_PREFIX:-com.claude-stem}"

# TIMEZONE: $TZ env wins, else parse /etc/localtime symlink (no privilege, no
# command-execution overhead, launchd-context-safe). Final fallback per author's
# EDT default. systemsetup -gettimezone REQUIRES admin per man page even for
# read-only — fails silently under launchd's restricted env.
if [ -n "${TZ:-}" ]; then
  TIMEZONE="$TZ"
else
  TIMEZONE=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
fi
TIMEZONE="${TIMEZONE:-America/New_York}"

# Per-job vars — set all groups to empty so envsubst doesn't leak across renders.
LIBRARIAN_HOUR=""
LIBRARIAN_MINUTE=""
ARCHITECT_HOUR=""
ARCHITECT_MINUTE=""
ARCHITECT_WEEKDAY=""
INBOX_POLL_INTERVAL_SEC_RENDER=""
DIGEST_RUN_HOUR=""
DIGEST_RUN_MINUTE=""
CHAT_SCRAPE_INTERVAL_SEC=""
CALENDAR_SYNC_INTERVAL_SEC=""
MEETING_PROCESSOR_HOUR=""
MEETING_PROCESSOR_MINUTE=""
CONNECTOR_RUNTIME_INTERVAL_SEC=""
CONNECTOR_ID="${CONNECTOR_ID:-}"

case "$job" in
  librarian)
    LIBRARIAN_HOUR="$hour"
    LIBRARIAN_MINUTE="$minute"
    allowlist='$USER_HOME $CLAUDE_HOME $CLAUDE_LOG_DIR $TIMEZONE $LABEL_PREFIX $LIBRARIAN_HOUR $LIBRARIAN_MINUTE'
    ;;
  architect)
    ARCHITECT_HOUR="$hour"
    ARCHITECT_MINUTE="$minute"
    if [ -z "$weekday" ]; then
      diag "architect job requires schedule.dow[0] (launchd Weekday); orchestration.json job '$job' has no dow array"
      exit 3
    fi
    ARCHITECT_WEEKDAY="$weekday"
    allowlist='$USER_HOME $CLAUDE_HOME $CLAUDE_LOG_DIR $TIMEZONE $LABEL_PREFIX $ARCHITECT_HOUR $ARCHITECT_MINUTE $ARCHITECT_WEEKDAY'
    ;;
  inbox-processor)
    # SP13 T-12. Schedule is StartInterval-driven via INBOX_POLL_INTERVAL_SEC
    # env var (already validated above as positive integer in [300, 86400]).
    # We re-export under the same name for envsubst (it's already in the env;
    # the explicit reassign + export keeps the allowlist invariant explicit).
    INBOX_POLL_INTERVAL_SEC_RENDER="$interval_sec"
    INBOX_POLL_INTERVAL_SEC="$interval_sec"
    allowlist='$USER_HOME $CLAUDE_HOME $CLAUDE_LOG_DIR $TIMEZONE $LABEL_PREFIX $INBOX_POLL_INTERVAL_SEC'
    ;;
  digest-run)
    # SP14 T-2 calendar-shape. Reads .schedule.{hour,minute} from orchestration.json.
    if [ -z "$hour" ] || [ -z "$minute" ]; then
      diag "digest-run job requires .schedule.{hour,minute}"
      exit 3
    fi
    DIGEST_RUN_HOUR="$hour"
    DIGEST_RUN_MINUTE="$minute"
    allowlist='$USER_HOME $CLAUDE_HOME $CLAUDE_LOG_DIR $TIMEZONE $LABEL_PREFIX $DIGEST_RUN_HOUR $DIGEST_RUN_MINUTE'
    ;;
  meeting-processor)
    # SP14 T-2 calendar-shape. Reads .schedule.{hour,minute} from orchestration.json.
    if [ -z "$hour" ] || [ -z "$minute" ]; then
      diag "meeting-processor job requires .schedule.{hour,minute}"
      exit 3
    fi
    MEETING_PROCESSOR_HOUR="$hour"
    MEETING_PROCESSOR_MINUTE="$minute"
    allowlist='$USER_HOME $CLAUDE_HOME $CLAUDE_LOG_DIR $TIMEZONE $LABEL_PREFIX $MEETING_PROCESSOR_HOUR $MEETING_PROCESSOR_MINUTE'
    ;;
  chat-scrape)
    # SP14 T-2 interval-shape. Reads .schedule.interval_sec from orchestration.json.
    if [ -z "$interval_sec" ]; then
      diag "chat-scrape job requires .schedule.interval_sec"
      exit 3
    fi
    CHAT_SCRAPE_INTERVAL_SEC="$interval_sec"
    allowlist='$USER_HOME $CLAUDE_HOME $CLAUDE_LOG_DIR $TIMEZONE $LABEL_PREFIX $CHAT_SCRAPE_INTERVAL_SEC'
    ;;
  calendar-sync)
    # SP14 T-2 interval-shape. Reads .schedule.interval_sec from orchestration.json.
    if [ -z "$interval_sec" ]; then
      diag "calendar-sync job requires .schedule.interval_sec"
      exit 3
    fi
    CALENDAR_SYNC_INTERVAL_SEC="$interval_sec"
    allowlist='$USER_HOME $CLAUDE_HOME $CLAUDE_LOG_DIR $TIMEZONE $LABEL_PREFIX $CALENDAR_SYNC_INTERVAL_SEC'
    ;;
  connector-runtime)
    # SP14 T-2 interval-shape. Parameterized template — one plist per CONNECTOR_ID.
    # Caller must set CONNECTOR_ID env var to identify the per-connector instance.
    if [ -z "$interval_sec" ]; then
      diag "connector-runtime job requires .schedule.interval_sec"
      exit 3
    fi
    if [ -z "$CONNECTOR_ID" ]; then
      diag "connector-runtime job requires CONNECTOR_ID env var (per-connector instance id; matches connectors[].id in user-manifest.json)"
      exit 3
    fi
    case "$CONNECTOR_ID" in
      *[!a-z0-9-]*|[!a-z]*|"")
        diag "CONNECTOR_ID must match ^[a-z][a-z0-9-]*\$ (got: '$CONNECTOR_ID')"
        exit 3
        ;;
    esac
    CONNECTOR_RUNTIME_INTERVAL_SEC="$interval_sec"
    allowlist='$USER_HOME $CLAUDE_HOME $CLAUDE_LOG_DIR $TIMEZONE $LABEL_PREFIX $CONNECTOR_ID $CONNECTOR_RUNTIME_INTERVAL_SEC'
    ;;
  *)
    diag "no render mapping for job '$job' (templates: librarian, architect, inbox-processor, digest-run, chat-scrape, calendar-sync, meeting-processor, connector-runtime)"
    exit 2
    ;;
esac
export USER_HOME CLAUDE_HOME CLAUDE_LOG_DIR TIMEZONE LABEL_PREFIX
export LIBRARIAN_HOUR LIBRARIAN_MINUTE
export ARCHITECT_HOUR ARCHITECT_MINUTE ARCHITECT_WEEKDAY
export INBOX_POLL_INTERVAL_SEC
export DIGEST_RUN_HOUR DIGEST_RUN_MINUTE
export CHAT_SCRAPE_INTERVAL_SEC CALENDAR_SYNC_INTERVAL_SEC
export MEETING_PROCESSOR_HOUR MEETING_PROCESSOR_MINUTE
export CONNECTOR_RUNTIME_INTERVAL_SEC CONNECTOR_ID

# --- pick target dir ---
if [ -n "$staging_dir" ]; then
  target_dir="$staging_dir"
else
  target_dir="$USER_HOME/Library/LaunchAgents"
fi

# --- render to ephemeral tmp + plutil-lint ---
# Render under $TMPDIR for dry-run (no write to target). For real install,
# render adjacent to final and atomic-mv (same-FS rename(2) guarantee).
tmp_dir="${TMPDIR:-/tmp}"
ephemeral_tmp="$tmp_dir/render-launchd.$job.$$.plist"
trap 'rm -f "$ephemeral_tmp"' EXIT

if ! envsubst "$allowlist" < "$TEMPLATE" > "$ephemeral_tmp" 2>/dev/null; then
  diag "envsubst failed on $TEMPLATE"
  exit 4
fi

if ! plutil -lint -s "$ephemeral_tmp" >/dev/null 2>&1; then
  diag "plutil -lint rejected rendered plist (template: $TEMPLATE)"
  plutil -lint "$ephemeral_tmp" >&2 || true
  exit 4
fi

# --- extract Label + sanity-check format ---
label=$(plutil -extract Label raw -o - "$ephemeral_tmp" 2>/dev/null)
if [ -z "$label" ]; then
  diag "could not extract Label from rendered plist"
  exit 5
fi
case "$label" in
  *[!A-Za-z0-9.-]*|[!A-Za-z]*|"")
    diag "rendered Label has invalid format: '$label' (must match ^[A-Za-z][A-Za-z0-9.-]*\$)"
    exit 5
    ;;
esac

# --- dry-run: emit rendered plist to stdout, no write, no bootstrap ---
if [ "$dry_run" -eq 1 ]; then
  cat "$ephemeral_tmp"
  info "dry-run: would write to $target_dir/$label.plist (label: $label)" >&2
  exit 0
fi

# --- real install: atomic mv into target dir ---
if ! mkdir -p "$target_dir" 2>/dev/null; then
  diag "cannot mkdir -p $target_dir"
  exit 4
fi

final_plist="$target_dir/$label.plist"
final_tmp="$final_plist.tmp.$$"
trap 'rm -f "$ephemeral_tmp" "$final_tmp"' EXIT

# Move ephemeral into target dir as .tmp first (cross-FS-safe), then rename
# atomically over final_plist (same-FS rename(2) is POSIX-atomic).
if ! mv -f "$ephemeral_tmp" "$final_tmp" 2>/dev/null; then
  diag "could not move ephemeral tmp into target dir: $tmp_dir → $target_dir"
  exit 4
fi
if ! mv -f "$final_tmp" "$final_plist" 2>/dev/null; then
  diag "atomic mv failed: $final_tmp → $final_plist"
  exit 4
fi
trap - EXIT

info "rendered $TEMPLATE → $final_plist (label: $label)"

# --- staging mode: skip launchctl entirely (SP07 production-flow rule) ---
if [ -n "$staging_dir" ]; then
  info "staging mode: skipping launchctl bootout + bootstrap"
  exit 0
fi

# --- production mode: bootout (idempotent, swallow rc) + bootstrap (rc gate) ---
if ! command -v launchctl >/dev/null 2>&1; then
  diag "launchctl required for production mode but not found on PATH"
  exit 2
fi

uid=$(id -u)
domain="gui/$uid"

# Unconditional bootout — symmetric with uninstall.sh, simpler invariant.
# Real launchctl returns non-zero (e.g. 113 ENOENT, 3, 36, 37, 5 — varies
# across macOS releases) if the label is not loaded. Swallow bootout rc by
# design; bootstrap rc is the failure gate. kickstart -k is INSUFFICIENT —
# it operates on the in-memory definition, not the on-disk plist, so plist
# content changes (schedule, env vars) would be silently ignored.
launchctl bootout "$domain/$label" >/dev/null 2>&1 || true

if ! launchctl bootstrap "$domain" "$final_plist"; then
  diag "launchctl bootstrap $domain $final_plist returned non-zero"
  exit 6
fi

info "launchctl bootstrapped $label under $domain"
exit 0
