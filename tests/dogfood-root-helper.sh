#!/bin/bash
# tests/dogfood-root-helper.sh
#
# MUST BE SOURCED (not executed). Sourcing in a subshell establishes
# $DOGFOOD_ROOT as a fresh mktemp -d and installs a trap that removes
# it on EXIT/INT/TERM. The caller's exit unwinds into the trap, so the
# filesystem is clean when control returns.
#
# Primitive P9 in SP00's primitive inventory. First downstream consumer:
# SP01 T-10 (bootstrap round-trip); second SP02 T-10d (manifest-missing
# graceful-degrade without touching any path outside $DOGFOOD_ROOT).
#
# Usage:
#   . tests/dogfood-root-helper.sh
#   echo "$DOGFOOD_ROOT"   # /tmp/foundation-test-XXXXX or /var/folders/...
#   # subshell exit -> trap fires -> dir removed
#
# R-23: bash 3.2 compat.

# Refuse exec-mode. BASH_SOURCE[0]==$0 means `./dogfood-root-helper.sh`;
# sourcing keeps $0 as the parent shell name but $BASH_SOURCE[0] as the
# helper path. If equal, caller exec'd us — trap would never fire on
# caller exit, leaving litter.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  printf 'dogfood-root-helper.sh FAIL: must be sourced, not executed\n' >&2
  printf '  usage: . tests/dogfood-root-helper.sh\n' >&2
  exit 64
fi

# mktemp -t on macOS uses the argument as a prefix template appended to
# $TMPDIR/. On Linux it needs XXXXX; both accept the -d -t form. Use the
# POSIX-portable "-d -t PREFIX" variant (macOS and GNU both honor).
DOGFOOD_ROOT="$(mktemp -d -t foundation-test.XXXXXXXX)"
if [ -z "${DOGFOOD_ROOT:-}" ] || [ ! -d "$DOGFOOD_ROOT" ]; then
  printf 'dogfood-root-helper.sh FAIL: mktemp -d returned empty/invalid path\n' >&2
  return 65 2>/dev/null || exit 65
fi
export DOGFOOD_ROOT

# Trap cleanup. Running under `set -e`? trap still fires. The sub-shell
# that sourced this helper inherits the trap.
__dogfood_root_cleanup() {
  # Guard: only remove if still under /tmp/ or /var/folders/ (macOS). Anywhere
  # else is a sign the variable was overwritten — do not rm -rf arbitrary paths.
  case "${DOGFOOD_ROOT:-}" in
    /tmp/foundation-test.*|/var/folders/*/T/foundation-test.*)
      rm -rf -- "$DOGFOOD_ROOT"
      ;;
    *)
      printf 'dogfood-root-helper.sh WARN: refusing to rm %s (outside /tmp/ or /var/folders/)\n' \
        "${DOGFOOD_ROOT:-<unset>}" >&2
      ;;
  esac
}
trap __dogfood_root_cleanup EXIT INT TERM
