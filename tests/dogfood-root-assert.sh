#!/bin/bash
# tests/dogfood-root-assert.sh
#
# Verifies $DOGFOOD_ROOT (set by tests/dogfood-root-helper.sh) is:
#   - set and non-empty
#   - an existing directory
#   - empty (no residual files from a prior test run)
#   - writable by current uid
#
# Exit 0 on pass, 3 with diagnostic on any fail.
#
# R-23: bash 3.2 compat.

set -u

diag() {
  printf 'dogfood-root-assert FAIL: %s\n' "$1" >&2
}

if [ -z "${DOGFOOD_ROOT:-}" ]; then
  diag "DOGFOOD_ROOT unset — helper not sourced?"
  exit 3
fi

if [ ! -d "$DOGFOOD_ROOT" ]; then
  diag "DOGFOOD_ROOT=${DOGFOOD_ROOT} is not a directory"
  exit 3
fi

# Empty check. `ls -A` lists dotfiles too, exclude . and ..
residue=$(ls -A "$DOGFOOD_ROOT" 2>/dev/null | head -5)
if [ -n "$residue" ]; then
  diag "DOGFOOD_ROOT=${DOGFOOD_ROOT} not empty: ${residue}"
  exit 3
fi

# Writability — try a probe file; clean it up immediately.
probe="${DOGFOOD_ROOT}/.writable-probe-$$"
if ! ( : > "$probe" ) 2>/dev/null; then
  diag "DOGFOOD_ROOT=${DOGFOOD_ROOT} not writable by uid=$(id -u 2>/dev/null)"
  exit 3
fi
rm -f -- "$probe"

exit 0
