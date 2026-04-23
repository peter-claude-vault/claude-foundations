#!/bin/bash
# tests/plist-lint.sh
#
# Plist lint shim. Runs `plutil -lint` when present (macOS), else Python
# plistlib.load fallback (Linux/container). Used by mock-launchctl.sh on
# `bootstrap` to reject malformed plist arguments before the trace emitter
# records them as legitimate bootstraps.
#
# Usage: plist-lint.sh <path-to-plist>
#
# Exit codes:
#   0  plist parseable (XML or binary format)
#   1  plist missing or unreadable
#   2  plist present but malformed
#   3  no lint tool available (plutil absent, python3 absent) — strict fail
#
# R-23: bash 3.2 compat.

set -u

diag() { printf 'plist-lint FAIL: %s\n' "$1" >&2; }

plist="${1:-}"
if [ -z "$plist" ] || [ ! -f "$plist" ] || [ ! -r "$plist" ]; then
  diag "plist missing or unreadable: ${plist:-<unset>}"
  exit 1
fi

# Prefer plutil (macOS native). -s silences success output; non-zero exit
# signals malformed plist.
if command -v plutil >/dev/null 2>&1; then
  if plutil -lint -s "$plist" >/dev/null 2>&1; then
    exit 0
  fi
  diag "plutil -lint rejected ${plist}"
  exit 2
fi

# Fallback: Python plistlib. plistlib.load auto-detects XML vs binary format.
if command -v python3 >/dev/null 2>&1; then
  if python3 - "$plist" <<'PY' 2>/dev/null
import sys, plistlib
try:
    with open(sys.argv[1], "rb") as f:
        plistlib.load(f)
except Exception as e:
    print("plistlib: " + type(e).__name__ + ": " + str(e), file=sys.stderr)
    sys.exit(2)
PY
  then
    exit 0
  fi
  diag "plistlib rejected ${plist}"
  exit 2
fi

diag "no lint tool available (plutil + python3 both missing)"
exit 3
