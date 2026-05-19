#!/usr/bin/env bash
# skills/doc-amender/install-watch.sh — launchd WatchPaths registration
# wrapper for doc-amender.
#
# Per Plan 81 SP14 Batch E T-28 (2026-05-19) per writer-pipeline-layering
# L-105..L-107. Operator-locked decision 2026-05-19: doc-amender cadence is
# event-driven on packet-land (NOT cron interval). Fire mechanism is launchd
# WatchPaths directive watching $STAGING_ROOT.
#
# This script composes WATCH_PATHS_ROOT env (default
# ~/.claude/state/vault-staging/; override via --staging-root) and invokes
# installer/render-launchd.sh to render the (deferred) plist template at
# templates/launchd/doc-amender.plist.tmpl + (production mode)
# launchctl-bootstrap the doc-amender launchd job.
#
# *** TEMPLATE DEFERRAL NOTE ***
# templates/launchd/doc-amender.plist.tmpl is DEFERRED to SP15 install
# scaffolding (matches Batch B writer-reconciler plist deferral pattern).
# This script declares the fire-mechanism intent + provides the env contract
# for the SP15 template author. On invocation: render-launchd.sh will FAIL
# with a clear "template missing" error pointing to the SP15 deferral. The
# error is INTENTIONAL — install-watch.sh exists to declare fire-mechanism
# intent only in SP14.
#
# bash 3.2 compatible. Watch-path-only fire mechanism (no interval-based
# launchd configuration).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
RENDER_LAUNCHD="$REPO_ROOT/installer/render-launchd.sh"
TEMPLATE_PATH="$REPO_ROOT/templates/launchd/doc-amender.plist.tmpl"

DEFAULT_STAGING_ROOT="${HOME}/.claude/state/vault-staging"

DRY_RUN=0
STAGING_DIR=""
STAGING_ROOT=""

usage() {
  cat <<EOF
install-watch.sh — doc-amender launchd WatchPaths registration.

Usage:
  install-watch.sh [--dry-run] [--staging-dir PATH] [--staging-root PATH]

Composes WATCH_PATHS_ROOT env (default $DEFAULT_STAGING_ROOT) and invokes
installer/render-launchd.sh to render the doc-amender plist + (production
mode) launchctl bootstrap. Watch-path-only fire mechanism per operator
decision 2026-05-19 (event-driven on packet-land; no interval-based config).

Flags:
  --dry-run                Render plist to stdout; no write, no bootstrap.
                           Composable with --staging-dir.
  --staging-dir PATH       Stage rendered plist under PATH instead of
                           ~/Library/LaunchAgents/. Skips launchctl bootstrap.
                           Used by tests + onboarder pre-bootstrap flow.
  --staging-root PATH      Override default WatchPaths target. Default is
                           \$STAGING_ROOT env (or $DEFAULT_STAGING_ROOT).

Default behavior (no flags): production install. Composes WATCH_PATHS_ROOT,
renders plist via render-launchd.sh doc-amender, atomic-installs to
~/Library/LaunchAgents/<Label>.plist, launchctl bootstraps. Bootstrap
success is the rc gate.

Env:
  WATCH_PATHS_ROOT         Exported for the (deferred SP15) plist template.
                           If --staging-root provided, overrides this.
                           If neither set, defaults to
                           $DEFAULT_STAGING_ROOT.

Exit codes:
  0   success
  2   bad invocation / missing prereq
  3   template missing — DEFERRED to SP15 install scaffolding
  4   render-launchd.sh propagated failure

DEFERRED template note:
  templates/launchd/doc-amender.plist.tmpl is authored under SP15 install
  scaffolding (mirrors Batch B writer-reconciler.plist.tmpl deferral
  pattern). SP14 install-watch.sh declares fire-mechanism intent only.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)              DRY_RUN=1; shift ;;
    --staging-dir)          STAGING_DIR="$2"; shift 2 ;;
    --staging-dir=*)        STAGING_DIR="${1#--staging-dir=}"; shift ;;
    --staging-root)         STAGING_ROOT="$2"; shift 2 ;;
    --staging-root=*)       STAGING_ROOT="${1#--staging-root=}"; shift ;;
    -h|--help)              usage; exit 0 ;;
    *) printf 'install-watch.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- resolve WATCH_PATHS_ROOT ------------------------------------------------
#
# Precedence: --staging-root argv > $STAGING_ROOT env > $WATCH_PATHS_ROOT env
# > built-in default.

if [ -z "$STAGING_ROOT" ]; then
  STAGING_ROOT="${STAGING_ROOT:-}"
fi
if [ -z "$STAGING_ROOT" ]; then
  STAGING_ROOT="${WATCH_PATHS_ROOT:-}"
fi
if [ -z "$STAGING_ROOT" ]; then
  STAGING_ROOT="$DEFAULT_STAGING_ROOT"
fi

# Defensive: warn (non-fatal) if STAGING_ROOT path does not yet exist. The
# plist will still install; launchd creates the WatchPaths watcher lazily on
# first stat success. We DO NOT mkdir here — bootstrapping is install-time
# scaffolding's job (SP15).
if [ ! -d "$STAGING_ROOT" ]; then
  printf 'install-watch.sh: WARN — staging root does not yet exist: %s\n' "$STAGING_ROOT" >&2
  printf 'install-watch.sh: WARN — plist will install but WatchPaths will be inert until staging root materializes\n' >&2
fi

export WATCH_PATHS_ROOT="$STAGING_ROOT"

# --- defensively handle deferred template ------------------------------------
#
# The plist template is DEFERRED to SP15. Surface this clearly BEFORE
# invoking render-launchd.sh so the SP15 author has an unambiguous
# integration point. If render-launchd.sh exists but template doesn't, exit 3
# with a structured error message rather than letting render-launchd.sh
# produce a confusing "file not found" trace.

if [ ! -r "$TEMPLATE_PATH" ]; then
  printf 'install-watch.sh: templates/launchd/doc-amender.plist.tmpl deferred to SP15; install-watch.sh declares fire-mechanism intent only in SP14\n' >&2
  printf 'install-watch.sh: SP15 author integration point:\n' >&2
  printf '  template path: %s\n' "$TEMPLATE_PATH" >&2
  printf '  WATCH_PATHS_ROOT: %s (exported)\n' "$WATCH_PATHS_ROOT" >&2
  printf '  fire mechanism: launchd WatchPaths (event-driven on packet-land)\n' >&2
  printf '  process binary: %s/process.sh\n' "$SCRIPT_DIR" >&2
  exit 3
fi

if [ ! -x "$RENDER_LAUNCHD" ] && [ ! -r "$RENDER_LAUNCHD" ]; then
  printf 'install-watch.sh: render-launchd.sh missing at %s\n' "$RENDER_LAUNCHD" >&2
  exit 2
fi

# --- compose render-launchd args ---------------------------------------------

render_args=""
if [ "$DRY_RUN" = "1" ]; then
  render_args="$render_args --dry-run"
fi
if [ -n "$STAGING_DIR" ]; then
  render_args="$render_args --staging-dir $STAGING_DIR"
fi

printf 'install-watch.sh: invoking render-launchd.sh doc-amender (WATCH_PATHS_ROOT=%s)\n' "$WATCH_PATHS_ROOT" >&2
# shellcheck disable=SC2086
if ! bash "$RENDER_LAUNCHD" $render_args doc-amender; then
  rc=$?
  printf 'install-watch.sh: render-launchd.sh failed rc=%s\n' "$rc" >&2
  exit 4
fi

exit 0
