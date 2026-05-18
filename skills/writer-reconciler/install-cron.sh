#!/usr/bin/env bash
# skills/writer-reconciler/install-cron.sh — cron-registration wrapper for
# writer-reconciler.
#
# Reads governance/vault-writers-rules.json ::
# reconciler_tick_minutes_default (default 15), computes
# WRITER_RECONCILER_INTERVAL_SEC = minutes * 60, and invokes
# installer/render-launchd.sh to render templates/launchd/writer-reconciler
# .plist.tmpl + (production mode) launchctl-bootstrap the writer-reconciler
# launchd job.
#
# Per Plan 81 SP14 Batch B T-11 (2026-05-18). Renamed + reshaped from
# inbox-processor/install-cron.sh — interval now sources from
# governance/vault-writers-rules.json (pillar 7) rather than
# user-manifest.json#/inbox/poll_interval_minutes. Plist template path
# update (templates/launchd/writer-reconciler.plist.tmpl) is install-time
# concern; SP15 scope.
#
# Bash 3.2 compatible (R-23). jq REQUIRED.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
RENDER_LAUNCHD="$REPO_ROOT/installer/render-launchd.sh"
DEFAULT_RULES_FILE="$REPO_ROOT/governance/vault-writers-rules.json"

DRY_RUN=0
STAGING_DIR=""
INTERVAL_OVERRIDE=""
RULES_FILE="$DEFAULT_RULES_FILE"

usage() {
  cat <<EOF
install-cron.sh — writer-reconciler cron registration.

Usage:
  install-cron.sh [--dry-run] [--staging-dir PATH] [--interval-minutes N]
                  [--rules-file PATH]

Reads governance/vault-writers-rules.json ::
reconciler_tick_minutes_default and invokes installer/render-launchd.sh to
install (or stage) the writer-reconciler launchd job.

Flags:
  --dry-run                Render plist to stdout; no write, no bootstrap.
                           Composable with --staging-dir.
  --staging-dir PATH       Stage rendered plist under PATH instead of
                           ~/Library/LaunchAgents/. Skips launchctl bootstrap.
                           Used by tests + onboarder pre-bootstrap flow.
  --interval-minutes N     Override rules-file's reconciler_tick_minutes_default
                           for this invocation. Range 5..1440.
  --rules-file PATH        Override default rules-file path
                           (default: governance/vault-writers-rules.json).

Default behavior (no flags): production install. Reads pillar 7 rules,
renders plist, atomic-installs to ~/Library/LaunchAgents/<Label>.plist,
launchctl bootstraps. Bootstrap success is the rc gate.

Env:
  WRITER_RECONCILER_INTERVAL_SEC
                           If set BEFORE invocation, takes precedence over
                           rules-file read (lets caller skip the pillar
                           lookup entirely; useful for sandboxed tests).

Exit codes:
  0   success
  2   bad invocation / missing prereq
  3   rules-file read error / interval out of range
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
    --rules-file)          RULES_FILE="$2"; shift 2 ;;
    --rules-file=*)        RULES_FILE="${1#--rules-file=}"; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) printf 'install-cron.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -x "$RENDER_LAUNCHD" ] && [ ! -r "$RENDER_LAUNCHD" ]; then
  printf 'install-cron.sh: render-launchd.sh missing at %s\n' "$RENDER_LAUNCHD" >&2
  exit 2
fi

# --- resolve reconciler_tick_minutes_default ---------------------------------

if [ -n "${WRITER_RECONCILER_INTERVAL_SEC:-}" ]; then
  # Caller pre-set the env var; trust + skip pillar read.
  resolved_sec="$WRITER_RECONCILER_INTERVAL_SEC"
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
  if [ ! -f "$RULES_FILE" ]; then
    printf 'install-cron.sh: rules-file missing at %s; using default 15 min\n' "$RULES_FILE" >&2
    resolved_min=15
  else
    if ! command -v jq >/dev/null 2>&1; then
      printf 'install-cron.sh: jq required for rules-file read\n' >&2
      exit 2
    fi
    resolved_min=$(jq -r '.reconciler_tick_minutes_default // 15' "$RULES_FILE" 2>/dev/null)
    if [ -z "$resolved_min" ] || [ "$resolved_min" = "null" ]; then
      resolved_min=15
    fi
    case "$resolved_min" in
      *[!0-9]*|"")
        printf 'install-cron.sh: rules-file reconciler_tick_minutes_default not an integer: "%s"\n' "$resolved_min" >&2
        exit 3
        ;;
    esac
    if [ "$resolved_min" -lt 5 ] || [ "$resolved_min" -gt 1440 ]; then
      printf 'install-cron.sh: rules-file reconciler_tick_minutes_default out of range [5, 1440]: %s\n' "$resolved_min" >&2
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

export WRITER_RECONCILER_INTERVAL_SEC="$resolved_sec"

printf 'install-cron.sh: invoking render-launchd.sh writer-reconciler (interval_sec=%s)\n' "$resolved_sec" >&2
if ! bash "$RENDER_LAUNCHD" "${render_args[@]}" writer-reconciler; then
  rc=$?
  printf 'install-cron.sh: render-launchd.sh failed rc=%s\n' "$rc" >&2
  exit 4
fi

exit 0
