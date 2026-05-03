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
# LABEL_PREFIX defaults to `com.claude-foundations` (matches SP08 G6 namespace
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

# --- orchestration.json read ---
if [ ! -r "${ORCHESTRATION_JSON:-}" ]; then
  diag "ORCHESTRATION_JSON not readable: ${ORCHESTRATION_JSON:-<unset>}"
  exit 3
fi

job_json=$(jq -c --arg id "$job" '.jobs[] | select(.id == $id)' "$ORCHESTRATION_JSON" 2>/dev/null)
if [ -z "$job_json" ]; then
  diag "orchestration.json has no jobs[] entry with id='$job'"
  exit 3
fi

# Schedule branch: hour/minute (StartCalendarInterval) only. interval_sec
# (StartInterval) is forward-compat work for a future StartInterval template.
hour=$(printf '%s' "$job_json" | jq -r '.schedule.hour // empty' 2>/dev/null)
minute=$(printf '%s' "$job_json" | jq -r '.schedule.minute // empty' 2>/dev/null)
interval_sec=$(printf '%s' "$job_json" | jq -r '.schedule.interval_sec // empty' 2>/dev/null)

if [ -n "$interval_sec" ]; then
  diag "orchestration.json job '$job' uses schedule.interval_sec; default templates only support hour/minute (StartCalendarInterval). interval_sec is forward-compat work for a future StartInterval template."
  exit 3
fi
if [ -z "$hour" ] || [ -z "$minute" ]; then
  diag "orchestration.json job '$job' missing schedule.hour or schedule.minute"
  exit 3
fi
weekday=$(printf '%s' "$job_json" | jq -r '.schedule.dow[0] // empty' 2>/dev/null)

# --- compose render-time env vars ---
USER_HOME="$HOME"
# CLAUDE_HOME + CLAUDE_LOG_DIR sourced via paths.sh.
LABEL_PREFIX="${LABEL_PREFIX:-com.claude-foundations}"

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

# Per-job vars — set both pairs to empty so envsubst doesn't leak across renders.
LIBRARIAN_HOUR=""
LIBRARIAN_MINUTE=""
ARCHITECT_HOUR=""
ARCHITECT_MINUTE=""
ARCHITECT_WEEKDAY=""

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
  *)
    diag "no render mapping for job '$job' (templates: librarian, architect)"
    exit 2
    ;;
esac
export USER_HOME CLAUDE_HOME CLAUDE_LOG_DIR TIMEZONE LABEL_PREFIX
export LIBRARIAN_HOUR LIBRARIAN_MINUTE
export ARCHITECT_HOUR ARCHITECT_MINUTE ARCHITECT_WEEKDAY

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
