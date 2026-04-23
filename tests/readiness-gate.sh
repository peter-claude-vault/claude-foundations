#!/bin/bash
# tests/readiness-gate.sh
#
# Asserts the 3 structural invariants that prove a Claude Foundations SP00
# test container booted inside the isolation harness. This is the ONLY
# approved pre-flight for tests/runner-shell.sh (SP00 T-10) — no test case
# runs without it passing.
#
# Invariants (I1..I10 are security invariants in spec; these 3 are the
# runtime-detectable subset that runner-shell gates on):
#
#   I_HOME   $HOME resolves to /home/tester
#   I_USERS  /Users is ENOENT (host macOS filesystem unreachable)
#   I_UID    current uid == 1000 AND owner of $HOME is uid 1000
#
# Exit codes:
#   0  all invariants pass
#   2  any invariant fail — stderr names the failing invariant
#
# R-23: bash 3.2 compat.

set -u

EXPECTED_HOME='/home/tester'
EXPECTED_UID='1000'

diag() {
  printf 'readiness-gate FAIL: %s\n' "$1" >&2
}

# --- I_HOME ---
if [ "${HOME:-}" != "$EXPECTED_HOME" ]; then
  diag "I_HOME expected=${EXPECTED_HOME} actual=${HOME:-<unset>}"
  exit 2
fi

# --- I_USERS ---
if [ -e /Users ]; then
  diag "I_USERS /Users exists on container rootfs — Lima mount leak or Docker Desktop substitution"
  exit 2
fi
# Defensive: /Volumes is a macOS-only path and must also be absent.
if [ -e /Volumes ]; then
  diag "I_USERS /Volumes exists on container rootfs — macOS host path leak"
  exit 2
fi

# --- I_UID ---
current_uid=$(id -u 2>/dev/null || printf '')
if [ "$current_uid" != "$EXPECTED_UID" ]; then
  diag "I_UID expected=${EXPECTED_UID} actual=${current_uid:-<unknown>} (id -u)"
  exit 2
fi

# $HOME owner must also be uid 1000 (defeats `sudo -H` + passwd entry drift).
# stat -c is Linux/BusyBox; macOS stat uses -f. Runtime target is Linux, but
# fall back gracefully if stat -c is unavailable rather than fail-open.
if command -v stat >/dev/null 2>&1; then
  home_uid=$(stat -c '%u' "$HOME" 2>/dev/null || printf '')
  if [ -n "$home_uid" ] && [ "$home_uid" != "$EXPECTED_UID" ]; then
    diag "I_UID-HOME \$HOME (${HOME}) owner uid=${home_uid} expected=${EXPECTED_UID}"
    exit 2
  fi
fi

# --- Optional: /etc/passwd sanity — tester line present with uid 1000 ---
# This catches the degenerate case where someone manually deleted the tester
# entry (T-12 synthetic tampered-container test).
if [ -r /etc/passwd ]; then
  if ! grep -qE '^tester:[^:]*:1000:' /etc/passwd; then
    diag "I_UID /etc/passwd missing 'tester:*:1000:*' line — container tamper detected"
    exit 2
  fi
fi

exit 0
