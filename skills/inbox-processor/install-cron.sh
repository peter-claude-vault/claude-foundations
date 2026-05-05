#!/usr/bin/env bash
# skills/inbox-processor/install-cron.sh — SP13 T-12 cron-registration wrapper.
#
# Reads $CLAUDE_HOME/user-manifest.json's inbox.poll_interval_minutes
# (default 15), computes INBOX_POLL_INTERVAL_SEC = minutes * 60, and invokes
# installer/render-launchd.sh to render templates/launchd/inbox-processor
# .plist.tmpl + (production mode) launchctl-bootstrap the inbox-processor
# launchd job.
#
# Bash 3.2 compatible (R-23). jq REQUIRED. Per spec L390, this is the
# "install.sh wiring update: register cron entry" call-site adopters invoke
# from /adopt or by hand.
#
# Author: Claude Opus 4.7 — Plan 71 SP13 Session 10 (T-12).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
RENDER_LAUNCHD="$REPO_ROOT/installer/render-launchd.sh"

DRY_RUN=0
STAGING_DIR=""
INTERVAL_OVERRIDE=""

usage() {
  cat <<EOF
install-cron.sh — SP13 T-12 inbox-processor cron registration.

Usage:
  install-cron.sh [--dry-run] [--staging-dir PATH] [--interval-minutes N]

Reads \$CLAUDE_HOME/user-manifest.json#/inbox/poll_interval_minutes and
invokes installer/render-launchd.sh to install (or stage) the
inbox-processor launchd job.

Flags:
  --dry-run                Render plist to stdout; no write, no bootstrap.
                           Composable with --staging-dir.
  --staging-dir PATH       Stage rendered plist under PATH instead of
                           ~/Library/LaunchAgents/. Skips launchctl bootstrap.
                           Used by tests + onboarder pre-bootstrap flow.
  --interval-minutes N     Override user-manifest's poll_interval_minutes for
                           this invocation. Range 5..1440. Useful for tests
                           and one-off renders.

Default behavior (no flags): production install. Reads user-manifest, renders
plist, atomic-installs to ~/Library/LaunchAgents/<Label>.plist, launchctl
bootstraps. Bootstrap success is the rc gate.

Env:
  CLAUDE_HOME              REQUIRED. user-manifest.json read from \$CLAUDE_HOME/.
  INBOX_POLL_INTERVAL_SEC  If set BEFORE invocation, takes precedence over
                           user-manifest read (lets caller skip the manifest
                           lookup entirely; useful for sandboxed tests).

Exit codes:
  0   success
  2   bad invocation / missing prereq
  3   user-manifest read error / interval out of range
  4   render-launchd.sh propagated failure
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)             DRY_RUN=1; shift ;;
    --staging-dir)         STAGING_DIR="$2"; shift 2 ;;
    --staging-dir=*)       STAGING_DIR="${1#--staging-dir=}"; shift ;;
    --interval-minutes)    INTERVAL_OVERRIDE="$2"; shift 2 ;;
    --interval-minutes=*)  INTERVAL_OVERRIDE="${1#--interval-minutes=}"; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) printf 'install-cron.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -x "$RENDER_LAUNCHD" ] && [ ! -r "$RENDER_LAUNCHD" ]; then
  printf 'install-cron.sh: render-launchd.sh missing at %s\n' "$RENDER_LAUNCHD" >&2
  exit 2
fi

# --- resolve poll_interval_minutes -------------------------------------------

if [ -n "${INBOX_POLL_INTERVAL_SEC:-}" ]; then
  # Caller pre-set the env var; trust + skip manifest read.
  resolved_sec="$INBOX_POLL_INTERVAL_SEC"
elif [ -n "$INTERVAL_OVERRIDE" ]; then
  # Validate range.
  case "$INTERVAL_OVERRIDE" in
    *[!0-9]*|"")
      printf 'install-cron.sh: --interval-minutes must be a positive integer (got: "%s")\n' "$INTERVAL_OVERRIDE" >&2
      exit 3
      ;;
  esac
  if [ "$INTERVAL_OVERRIDE" -lt 5 ] || [ "$INTERVAL_OVERRIDE" -gt 1440 ]; then
    printf 'install-cron.sh: --interval-minutes must be in [5, 1440] (got: %s)\n' "$INTERVAL_OVERRIDE" >&2
    exit 3
  fi
  resolved_sec=$((INTERVAL_OVERRIDE * 60))
else
  CH="${CLAUDE_HOME:-}"
  if [ -z "$CH" ]; then
    printf 'install-cron.sh: CLAUDE_HOME unset; cannot read user-manifest.json\n' >&2
    exit 2
  fi
  USER_MANIFEST="$CH/user-manifest.json"
  if [ ! -f "$USER_MANIFEST" ]; then
    printf 'install-cron.sh: user-manifest.json missing at %s; using default 15 min\n' "$USER_MANIFEST" >&2
    resolved_min=15
  else
    if ! command -v jq >/dev/null 2>&1; then
      printf 'install-cron.sh: jq required for user-manifest read\n' >&2
      exit 2
    fi
    resolved_min=$(jq -r '.inbox.poll_interval_minutes // 15' "$USER_MANIFEST" 2>/dev/null)
    if [ -z "$resolved_min" ] || [ "$resolved_min" = "null" ]; then
      resolved_min=15
    fi
    case "$resolved_min" in
      *[!0-9]*|"")
        printf 'install-cron.sh: user-manifest inbox.poll_interval_minutes not an integer: "%s"\n' "$resolved_min" >&2
        exit 3
        ;;
    esac
    if [ "$resolved_min" -lt 5 ] || [ "$resolved_min" -gt 1440 ]; then
      printf 'install-cron.sh: user-manifest inbox.poll_interval_minutes out of range [5, 1440]: %s\n' "$resolved_min" >&2
      exit 3
    fi
  fi
  resolved_sec=$((resolved_min * 60))
fi

# --- compose render-launchd args ---------------------------------------------

render_args=()
if [ "$DRY_RUN" = "1" ]; then
  render_args+=(--dry-run)
fi
if [ -n "$STAGING_DIR" ]; then
  render_args+=(--staging-dir "$STAGING_DIR")
fi

export INBOX_POLL_INTERVAL_SEC="$resolved_sec"

printf 'install-cron.sh: invoking render-launchd.sh inbox-processor (interval_sec=%s)\n' "$resolved_sec" >&2
if ! bash "$RENDER_LAUNCHD" "${render_args[@]}" inbox-processor; then
  rc=$?
  printf 'install-cron.sh: render-launchd.sh failed rc=%s\n' "$rc" >&2
  exit 4
fi

exit 0
