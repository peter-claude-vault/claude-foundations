#!/bin/bash
# tests/mock-launchctl.sh
#
# Drop-in mock for Apple's `launchctl` binary, active inside the SP00
# isolation container. The real binary does not exist on Linux; this stub
# stands in so SP03 T-15 (E2E orchestration) and SP07 T-9 (initial-job-setup
# bootstrap) can exercise their launchd code paths deterministically without
# side-effecting host launchd.
#
# Contract:
#   - Every invocation appends one JSON line to /results/launchctl-trace.ndjson
#     recording {ts, verb, argv, stdin, cwd, exit}.
#   - Exits 0 on bootstrap/bootout/print/list/kickstart.
#   - Exits 3 on any other verb (explicit reject; catches typos + undeclared
#     consumers).
#   - Enforces bootstrap/bootout lifecycle pairing per plist-label: a second
#     `bootstrap` of label X without an intervening `bootout` exits 4 with a
#     lifecycle diagnostic.
#   - On `bootstrap`, runs tests/plist-lint.sh on the plist argument. A lint
#     failure exits 5 and does NOT register the label as bootstrapped.
#
# Env gating:
#   - The Dockerfile symlinks /usr/local/bin/launchctl -> this file
#     unconditionally in the SP00 image (MOCK_LAUNCHCTL=1 is an always-on
#     image-level invariant). Downstream code reads MOCK_LAUNCHCTL to know
#     it is in mock mode; the stub itself does not gate on it.
#   - LAUNCHCTL_TRACE_DIR overrides /results for host-side unit tests.
#   - LAUNCHCTL_PLIST_LINT overrides the sibling plist-lint.sh path.
#
# Exit code map:
#   0  verb accepted, trace written
#   3  unknown verb
#   4  lifecycle violation (double-bootstrap without intervening bootout)
#   5  plist-lint rejected the plist argument on bootstrap
#   6  internal error (cannot create trace/state dirs, missing jq, ...)
#
# R-23: bash 3.2 compat.

set -u

TRACE_DIR="${LAUNCHCTL_TRACE_DIR:-/results}"
TRACE_FILE="${TRACE_DIR}/launchctl-trace.ndjson"
STATE_DIR="${TRACE_DIR}/launchctl-state"

# Resolve sibling plist-lint.sh via readlink -f to handle symlinked invocation
# (Dockerfile wires /usr/local/bin/launchctl -> /tests/mock-launchctl.sh).
if [ -n "${LAUNCHCTL_PLIST_LINT:-}" ]; then
  PLIST_LINT="$LAUNCHCTL_PLIST_LINT"
else
  __self="${BASH_SOURCE[0]}"
  if command -v readlink >/dev/null 2>&1; then
    __real=$(readlink -f "$__self" 2>/dev/null || printf '')
    [ -n "$__real" ] && __self="$__real"
  fi
  PLIST_LINT="$(cd "$(dirname "$__self")" && pwd)/plist-lint.sh"
fi

diag() { printf 'mock-launchctl FAIL: %s\n' "$1" >&2; }

if ! command -v jq >/dev/null 2>&1; then
  diag "jq required for trace emission but not found on PATH"
  exit 6
fi

if ! mkdir -p "$TRACE_DIR" "$STATE_DIR" 2>/dev/null; then
  diag "cannot create trace/state dirs under ${TRACE_DIR}"
  exit 6
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
verb="${1:-<empty>}"
cwd="$(pwd)"

# Save argv before any shifts; jq emits it verbatim.
ARGV=( "$@" )

# Capture stdin iff not a tty AND data is already readable. `read -t 0`
# probes without consuming (bash 3.2+ supports this). This prevents hang
# on inherited open stdin that will never produce data (e.g. when the
# caller is itself a script whose parent shell has stdin open but idle).
# Inside `nerdctl run` without -i, stdin is /dev/null and `read -t 0`
# returns non-zero immediately, so stdin_contents stays empty.
stdin_contents=""
if [ ! -t 0 ] && read -t 0 <&0 2>/dev/null; then
  stdin_contents="$(cat 2>/dev/null || true)"
fi

# Extract last argv token (bash 3.2 safe: no negative index, no ${arr[@]: -1}).
last_arg=""
for __a in "${ARGV[@]}"; do last_arg="$__a"; done

# Collapse bootstrap/bootout identity to a label identifier:
#   bootstrap <domain> <plist>    -> basename(plist) without .plist
#   bootout <domain>/<label>      -> final / segment
#   bootout <domain> <plist>      -> basename(plist) without .plist
# The "last-token basename, strip .plist" heuristic handles all three forms.
label_from_last() {
  tok="${1:-}"
  tok="${tok##*/}"
  case "$tok" in
    *.plist) tok="${tok%.plist}" ;;
  esac
  printf '%s' "$tok"
}

emit_trace() {
  # $1 = exit code. Writes one ndjson line to TRACE_FILE. Uses --args so argv
  # is preserved as a JSON array with correct escaping for every code point.
  jq -nc \
    --arg ts       "$ts" \
    --arg verb     "$verb" \
    --arg stdin    "$stdin_contents" \
    --arg cwd      "$cwd" \
    --argjson exit "$1" \
    --args \
    '{ts:$ts, verb:$verb, argv:$ARGS.positional, stdin:$stdin, cwd:$cwd, exit:$exit}' \
    -- "${ARGV[@]}" >> "$TRACE_FILE"
}

case "$verb" in
  bootstrap)
    plist_path="$last_arg"
    if [ -z "$plist_path" ] || [ ! -f "$plist_path" ]; then
      emit_trace 5
      diag "bootstrap: plist path missing or not a file: ${plist_path:-<unset>}"
      exit 5
    fi
    if ! bash "$PLIST_LINT" "$plist_path" >/dev/null 2>&1; then
      emit_trace 5
      diag "bootstrap: plist-lint rejected ${plist_path}"
      exit 5
    fi
    label="$(label_from_last "$plist_path")"
    state_file="${STATE_DIR}/${label}.state"
    if [ -e "$state_file" ]; then
      emit_trace 4
      diag "bootstrap: label '${label}' already bootstrapped without intervening bootout (state: ${state_file})"
      exit 4
    fi
    : > "$state_file"
    emit_trace 0
    exit 0
    ;;
  bootout)
    label="$(label_from_last "$last_arg")"
    state_file="${STATE_DIR}/${label}.state"
    # Idempotent: remove if present, no-op if not (mirrors real launchctl).
    rm -f "$state_file"
    emit_trace 0
    exit 0
    ;;
  print|list|kickstart)
    emit_trace 0
    exit 0
    ;;
  *)
    emit_trace 3
    diag "unknown verb: '${verb}'"
    exit 3
    ;;
esac
