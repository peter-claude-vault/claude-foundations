#!/bin/bash
# tests/plutil-shim.sh
#
# Linux drop-in replacement for macOS `plutil`. Symlinked into the
# sp00-isolation Docker image at /usr/local/bin/plutil so install.sh +
# installer/render-launchd.sh + installer/bootout-launchd.sh see a
# `plutil` binary without modification.
#
# Supported invocations (the subset used by foundation-repo callers):
#   plutil -lint <file>             — verbose lint (compose plist-lint.sh)
#   plutil -lint -s <file>          — silent lint (suppress diagnostic on success)
#   plutil -extract <key> raw -o - <file>
#                                    — extract a top-level dict key as raw text
#
# Unrecognized invocations fall through to a Python plistlib best-effort
# parse so they don't silently no-op.
#
# Exit codes (mirror Apple's plutil where reasonable):
#   0  success
#   1  invalid arguments / unsupported mode / file unreadable
#   2  plist malformed
#
# R-23: bash 3.2 compat.

set -u

err() { printf 'plutil-shim: %s\n' "$1" >&2; }

if [ $# -lt 1 ]; then
  err "no arguments; expected -lint or -extract"
  exit 1
fi

# --- -lint (with optional -s) ------------------------------------------
if [ "$1" = '-lint' ]; then
  shift
  silent=0
  if [ "${1:-}" = '-s' ]; then
    silent=1
    shift
  fi
  plist="${1:-}"
  if [ -z "$plist" ] || [ ! -f "$plist" ]; then
    err "missing or unreadable plist: ${plist:-<unset>}"
    exit 1
  fi
  # Compose plist-lint.sh (same image, /tests/plist-lint.sh).
  if [ -x /tests/plist-lint.sh ]; then
    if [ "$silent" = '1' ]; then
      /tests/plist-lint.sh "$plist" >/dev/null 2>&1
    else
      /tests/plist-lint.sh "$plist"
    fi
    exit $?
  fi
  # Fallback: python plistlib parse (matches plist-lint.sh's own fallback).
  python3 - "$plist" <<'PY'
import sys, plistlib
try:
    with open(sys.argv[1], 'rb') as f:
        plistlib.load(f)
    print(f"{sys.argv[1]}: OK")
    sys.exit(0)
except Exception as e:
    print(f"{sys.argv[1]}: plist parse error — {e}", file=sys.stderr)
    sys.exit(2)
PY
  exit $?
fi

# --- -extract <key> raw -o <out> <file> --------------------------------
if [ "$1" = '-extract' ]; then
  shift
  key="${1:-}"; shift || true
  fmt="${1:-}"; shift || true
  if [ "$fmt" != 'raw' ]; then
    err "extract: only 'raw' format supported (got '$fmt')"
    exit 1
  fi
  out='-'
  if [ "${1:-}" = '-o' ]; then
    shift
    out="${1:-}"; shift || true
  fi
  plist="${1:-}"
  if [ -z "$plist" ] || [ ! -f "$plist" ]; then
    err "extract: missing or unreadable plist: ${plist:-<unset>}"
    exit 1
  fi
  python3 - "$plist" "$key" "$out" <<'PY'
import sys, plistlib
plist_path, key, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(plist_path, 'rb') as f:
        d = plistlib.load(f)
    if not isinstance(d, dict) or key not in d:
        sys.exit(1)
    val = d[key]
    if isinstance(val, bool):
        rendered = 'true' if val else 'false'
    elif isinstance(val, (int, float, str)):
        rendered = str(val)
    else:
        rendered = repr(val)
    if out_path == '-':
        sys.stdout.write(rendered + '\n')
    else:
        with open(out_path, 'w') as f:
            f.write(rendered + '\n')
    sys.exit(0)
except Exception as e:
    print(f"extract failed: {e}", file=sys.stderr)
    sys.exit(2)
PY
  exit $?
fi

err "unsupported mode: $1"
exit 1
