#!/bin/bash
# tests/bypass-audit.sh [target-dir]
#
# Isolation-contract bypass detector (SP00 T-12 deliverable).
#
# The isolation harness has exactly ONE approved test entrypoint:
# `tests/runner-shell.sh` (which runs `tests/readiness-gate.sh` as its
# first action). Any script or workflow that invokes a container
# runtime (nerdctl / docker / podman / ctr) with a raw shell (`bash`,
# `sh`, `/bin/bash`, `/bin/sh`) as the final argv is bypassing the
# contract — the readiness gate never fires, the sub-plan's test cases
# are replaced by an interactive shell, and I_HOME / I_USERS / I_UID
# invariants go un-asserted for that run.
#
# This script greps every `.sh` / `.yml` / `.yaml` under $TARGET for
# that pattern. It treats a hit as a CI blocker.
#
# Deliberate non-hits (all of which the rule correctly ignores):
#   - Comment lines (start with `#`) in any shell/yaml file.
#   - Lines that also mention `runner-shell` (the sanctioned invocation
#     pattern is `nerdctl run <image> tests/runner-shell.sh`, which must
#     remain legal).
#   - Markdown documentation under docs/ (scope is execution surface,
#     not prose); the --include filter drops markdown.
#   - `nerdctl build` / `docker build` lines (image-build secret-mount
#     patterns from docs/burner-key-runbook.md live in Dockerfiles,
#     not in `run` invocations).
#
# Exit codes:
#   0  clean (no bypass hits)
#   1  any hit (diagnostic on stderr)
#   7  setup error (target not a directory)
#
# Invocation:
#   tests/bypass-audit.sh            # scan repo root
#   tests/bypass-audit.sh path/to    # scan subdir
#
# First consumer: .github/workflows/grep-audit.yml (T-12 CI wiring).
# R-23: bash 3.2 compat.

set -u

TARGET="${1:-.}"

err() { printf 'bypass-audit: %s\n' "$1" >&2; }

[ -d "$TARGET" ] || { err "target not a directory: $TARGET"; exit 7; }

# Exclusion regex: same spirit as grep-audit.sh — .git + fixtures must
# not be audited, and this script itself mentions the patterns in
# docstrings. The bypass-audit-unit-test seeds its own synthetic
# bypass lines inline via heredocs (no separate fixtures dir), so
# that file is also excluded.
#
# NOTE: patterns are matched against `grep -rIn` output of the form
# `path:lineno:content`, so filename self-excludes end in `:` (the
# path→lineno separator), not `$` (end-of-line would require content
# to be empty and never matches).
EXCLUDE_RE='/\.git/|/node_modules/|/grep-audit-fixtures/|/bypass-audit\.sh:|/bypass-audit-unit-test\.sh:|/bypass-audit-fixtures/'

# Phase 1: find raw `(runtime) run` lines in shell/yaml.
candidates=$(
  grep -rIn -E "(nerdctl|docker|podman|ctr)[[:space:]]+run[[:space:]]" \
    --include='*.sh' --include='*.yml' --include='*.yaml' \
    "$TARGET" 2>/dev/null \
  | grep -vE "$EXCLUDE_RE" \
  || true
)

[ -n "$candidates" ] || {
  printf '{"target":"%s","hits":0}\n' "$TARGET"
  exit 0
}

# Phase 2: among candidates, filter to the bypass class:
#   - line DOES end in `bash`, `sh`, `/bin/bash`, `/bin/sh` (optionally
#     followed by trailing whitespace), OR contains `-c '...'` bash/sh
#     forms
#   - line is NOT a comment (# prefix after leading whitespace)
#   - line does NOT also reference `runner-shell`
#
# Pattern is applied to the grep output's "path:lineno:content" form;
# the content is whatever trails the second colon. sed the prefix off
# for match purposes, keep the original line for reporting.
hits=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # Extract content (strip path:lineno: prefix).
  content=${line#*:}
  content=${content#*:}
  # Trim leading whitespace for comment check.
  trimmed=${content#"${content%%[![:space:]]*}"}
  case "$trimmed" in
    '#'*) continue ;;
  esac
  # Skip if the line mentions runner-shell.
  case "$content" in
    *runner-shell*) continue ;;
  esac
  # Look for shell-as-final-argv or shell -c at end.
  # Use a single regex; bash 3.2 =~ is fine in the interpreter running
  # this script (macOS 3.2 / Linux 5.x both OK).
  if printf '%s' "$content" | grep -qE '(^|[[:space:]])(/bin/)?(bash|sh)([[:space:]]+-[cil]+)?[[:space:]]*$'; then
    hits="${hits}${line}"$'\n'
    continue
  fi
  # Also catch `bash -c '...'` / `sh -c "..."` at the tail (explicit
  # command-string invocation pattern).
  if printf '%s' "$content" | grep -qE '(^|[[:space:]])(/bin/)?(bash|sh)[[:space:]]+-[cil]+[[:space:]]+["'\'']'; then
    hits="${hits}${line}"$'\n'
    continue
  fi
done <<< "$candidates"

if [ -n "$hits" ]; then
  printf '=== bypass-audit HITS — direct container-runtime shells (skip readiness-gate) ===\n' >&2
  printf '%s' "$hits" >&2
  printf '\n' >&2
  printf 'Route test invocations through tests/runner-shell.sh; see docs/isolation-contract.md.\n' >&2
  hit_count=$(printf '%s' "$hits" | grep -c '^..*$' || true)
  printf '{"target":"%s","hits":%d}\n' "$TARGET" "$hit_count"
  exit 1
fi

printf '{"target":"%s","hits":0}\n' "$TARGET"
exit 0
