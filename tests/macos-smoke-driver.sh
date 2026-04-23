#!/bin/bash
# tests/macos-smoke-driver.sh
#
# SP00 Primitive P4 driver. Runs a caller-supplied command inside
# `sandbox-exec -f tests/dogfood.sb` with HOME forced to $DOGFOOD_ROOT
# so any `~/`-relative write lands inside the sandbox-writable subtree.
#
# Usage:
#   tests/macos-smoke-driver.sh <cmd> [args...]
#
# Contract:
#   - Caller MUST have sourced tests/dogfood-root-helper.sh first
#     (i.e. $DOGFOOD_ROOT must be set + point at an existing writable dir).
#   - Driver pre-flight-lints the .sb profile via
#     `sandbox-exec -f <profile> -D DOGFOOD_ROOT=... /usr/bin/true`;
#     any non-zero exit aborts BEFORE the caller's command is run.
#   - Both sandbox-exec invocations (pre-flight + final) run under a
#     wall-clock timeout (SANDBOX_EXEC_TIMEOUT seconds, default 60).
#     The timeout catches the TCC Full Disk Access prompt case: on a
#     fresh macOS host the first `sandbox-exec` may block forever
#     waiting on a user-visible dialog that never surfaces non-
#     interactively (CI / `claude -p` dispatch). Timeout trips with
#     exit 69 and a diagnostic naming Settings → Privacy → Full Disk
#     Access as the likely fix.
#   - Caller's exit code is propagated verbatim.
#
# First downstream consumer: SP03 T-14 (macOS real-launchd smoke).
# Full consumer API + TCC Full Disk Access interaction notes live in
# docs/isolation-contract.md (T-12 deliverable).
#
# R-23: bash 3.2 compat.

set -u

SANDBOX_EXEC_TIMEOUT="${SANDBOX_EXEC_TIMEOUT:-60}"

# timebox <secs> <cmd> [args...]
# Runs cmd with a wall-clock cap. On timeout, kills TERM (grace 2s) then
# KILL; returns exit 124 (coreutils convention). On success, propagates
# the child exit code. bash 3.2 compat: no `wait -n`, no `timeout`
# binary dependence; `wait $pid; echo $?` is the portable path.
timebox() {
  local secs=$1; shift
  "$@" &
  local child=$!
  ( sleep "$secs" && kill -TERM "$child" 2>/dev/null \
      && sleep 2 && kill -KILL "$child" 2>/dev/null ) &
  local killer=$!
  local rc=0
  wait "$child" 2>/dev/null; rc=$?
  # Kill the watchdog if it didn't fire.
  kill -KILL "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null
  # If the child was killed by SIGTERM from our watchdog, bash reports
  # rc=143 (128 + 15). Normalize to 124 so callers can check cleanly.
  if [ "$rc" = "143" ] || [ "$rc" = "137" ]; then
    return 124
  fi
  return "$rc"
}

# --- Locate profile relative to this script ---------------------------
__DRIVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_PROFILE="${__DRIVER_DIR}/dogfood.sb"

die() {
  printf 'macos-smoke-driver FAIL: %s\n' "$1" >&2
  exit "${2:-1}"
}

# --- Contract checks --------------------------------------------------
[ -n "${DOGFOOD_ROOT:-}" ] || die \
  '$DOGFOOD_ROOT unset — source tests/dogfood-root-helper.sh first' 64

[ -d "$DOGFOOD_ROOT" ] || die \
  "\$DOGFOOD_ROOT=$DOGFOOD_ROOT is not a directory" 64

# Canonicalize: macOS /var → /private/var symlink. sandbox-exec
# canonicalizes paths at enforcement time, so the `-D` param MUST
# match the canonical form or `(subpath (param "DOGFOOD_ROOT"))` never
# fires for writes targeting /var/folders/... paths. T-6's helper sets
# DOGFOOD_ROOT via mktemp which returns /var/folders/... — so the
# uncanonical form gets passed through the contract, and THIS driver
# is the layer that resolves it into a form sandbox-exec will match.
DOGFOOD_ROOT_CANON="$(cd -- "$DOGFOOD_ROOT" && pwd -P)" || die \
  "failed to canonicalize \$DOGFOOD_ROOT=$DOGFOOD_ROOT" 64

[ -f "$SANDBOX_PROFILE" ] || die \
  "sandbox profile not found at $SANDBOX_PROFILE" 66

[ $# -ge 1 ] || die 'no command supplied' 64

# macOS-only (sandbox-exec is a macOS binary)
case "$(uname -s)" in
  Darwin) ;;
  *) die "macos-smoke-driver requires Darwin; got $(uname -s)" 67 ;;
esac

command -v sandbox-exec >/dev/null 2>&1 || die 'sandbox-exec not on PATH' 67

# --- Pre-flight: lint the profile -------------------------------------
# Runs /usr/bin/true through the profile. Catches syntax errors, bad
# param references, and missing primitives BEFORE the caller's cmd
# sees the sandbox. Any non-zero exit (including 134/SIGABRT from an
# overly-tight deny) aborts here, so we never run caller cmd under
# a broken profile.
#
# Wrapped in timebox: a stuck TCC Full Disk Access prompt would
# otherwise hang the pre-flight forever in non-interactive contexts.
timebox "$SANDBOX_EXEC_TIMEOUT" \
  sandbox-exec -f "$SANDBOX_PROFILE" -D DOGFOOD_ROOT="$DOGFOOD_ROOT_CANON" \
     /usr/bin/true >/dev/null 2>&1
lint_rc=$?
if [ "$lint_rc" = "124" ]; then
  die "pre-flight lint TIMED OUT after ${SANDBOX_EXEC_TIMEOUT}s — likely TCC Full Disk Access prompt pending. Open System Settings → Privacy & Security → Full Disk Access, grant the invoking terminal (or sandbox-exec), then retry." 69
elif [ "$lint_rc" != "0" ]; then
  die "pre-flight lint failed for profile $SANDBOX_PROFILE (rc=$lint_rc; syntax error, bad param, or too-tight deny)" 68
fi

# --- Run caller cmd under sandbox -------------------------------------
# HOME override: rewrites ~/ expansions so the caller's writes land
# inside the sandbox-writable subtree. Note: sandbox-exec inherits the
# parent's environment; env-scrubbing is T-3's responsibility (docker
# entrypoint) + T-10's responsibility (runner-shell). Driver does not
# scrub here — that layering stays with the entrypoint gate.
#
# NOTE: prior to T-12 this was `exec sandbox-exec ...` (tail-call
# replacing the driver PID). The timebox wrapper requires a
# fork+wait, so we run the child and propagate its exit verbatim.
# Net observable behavior is unchanged EXCEPT for the timeout path.
HOME="$DOGFOOD_ROOT_CANON" timebox "$SANDBOX_EXEC_TIMEOUT" \
  sandbox-exec \
    -f "$SANDBOX_PROFILE" \
    -D DOGFOOD_ROOT="$DOGFOOD_ROOT_CANON" \
    "$@"
run_rc=$?
if [ "$run_rc" = "124" ]; then
  die "sandbox-exec run TIMED OUT after ${SANDBOX_EXEC_TIMEOUT}s — likely TCC Full Disk Access prompt pending (should have fired in pre-flight; possibly a re-prompt or distinct binary grant). Check Settings → Privacy & Security → Full Disk Access." 69
fi
exit "$run_rc"
