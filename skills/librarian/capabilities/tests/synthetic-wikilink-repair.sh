#!/bin/bash
# Synthetic tests for wikilink-repair.sh — Plan 67 SP01 T-1 + T-2.
#
# T-1 coverage (3 cases):
#   1. [[ValidTarget\]]       — trailing single-backslash strip → resolve
#   2. [[ValidTarget\\\\]]    — trailing multi-backslash strip → resolve
#   3. [[GenuinelyMissing\]]  — post-strip still missing → emit finding
#
# T-2 coverage (2 cases — regression lock on alias/hash strip behavior):
#   4. [[Target|Display Text]]              — alias-strip, resolves via Target
#   5. [[Target#heading|Display]]           — alias + hash strip, resolves via Target
#
# Why these tests exist (for future refactors):
#   The wikilink target-extraction pipeline has three independent normalizers:
#     a. regex alias strip (line 125: `(?:\|[^\]]+)?`)
#     b. regex hash-fragment strip (line 125: `(?:#[^\]\|]+)?`)
#     c. trailing-backslash strip (added in T-1)
#   Any future refactor that collapses these could silently regress one of
#   three behaviors. Keep all 5 cases green.
#
# Usage: bash synthetic-wikilink-repair.sh
# Exit:  0 on 5/5 pass, 1 otherwise.
#
# Bash 3.2 clean per R-23.

set -uo pipefail

CAP="$(cd "$(dirname "$0")/.." && pwd)/wikilink-repair.sh"
TMP_VAULT="$(mktemp -d -t wikilink-test-XXXXXX)"
TMP_DEP="$TMP_VAULT/doc-dependencies.json"
TMP_FINDINGS="$TMP_VAULT/findings.ndjson"
PASS=0
FAIL=0
TESTS=0

cleanup() { rm -rf "$TMP_VAULT"; }
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Fixture setup: minimal vault with one real target file.
# -----------------------------------------------------------------------------
mkdir -p "$TMP_VAULT/sub"
# Create the "ValidTarget" and "Target" files so resolution succeeds
: > "$TMP_VAULT/ValidTarget.md"
: > "$TMP_VAULT/Target.md"

# Empty doc-dependencies.json (no registry seeds needed — basename lookup uses
# all_md_by_basename from os.walk, not the registry)
cat > "$TMP_DEP" <<'JSON'
{"entries": []}
JSON

# -----------------------------------------------------------------------------
# Helper: run the capability against a source file and inspect findings output.
#   $1 = test name
#   $2 = source file content
#   $3 = expected `should_resolve` (yes|no) — i.e., no broken-wikilink finding emitted
# -----------------------------------------------------------------------------
run_case() {
  local name="$1"
  local content="$2"
  local expect="$3"   # yes | no
  TESTS=$((TESTS + 1))

  printf '%s' "$content" > "$TMP_VAULT/source.md"
  : > "$TMP_FINDINGS"

  VAULT_ROOT="$TMP_VAULT" \
  DOC_DEP_FILE="$TMP_DEP" \
  FINDINGS_OUTPUT="$TMP_FINDINGS" \
  bash "$CAP" --scope "$TMP_VAULT" >/dev/null 2>&1

  # Count broken-wikilink findings for source.md
  local broken_count
  broken_count=$(grep -c '"finding": "broken-wikilink"' "$TMP_FINDINGS" 2>/dev/null)
  [ -z "$broken_count" ] && broken_count=0
  # Normalize any stray whitespace/newlines to a bare integer
  broken_count=$(printf '%s' "$broken_count" | tr -d '[:space:]')

  case "$expect" in
    yes)
      if [ "$broken_count" = "0" ]; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
      else
        printf '  FAIL  %s (expected 0 broken, got %s)\n' "$name" "$broken_count"
        FAIL=$((FAIL + 1))
        cat "$TMP_FINDINGS"
      fi
      ;;
    no)
      if [ "$broken_count" -ge "1" ]; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
      else
        printf '  FAIL  %s (expected >=1 broken, got %s)\n' "$name" "$broken_count"
        FAIL=$((FAIL + 1))
      fi
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------
printf 'synthetic-wikilink-repair.sh — T-1 + T-2\n'

# T-1 Case 1 — trailing single backslash strips, target resolves
run_case "T1.1 trailing single-backslash ([[ValidTarget\\]])" \
  "See [[ValidTarget\\]] for details.\n" \
  "yes"

# T-1 Case 2 — multi-backslash trail, target resolves
run_case "T1.2 trailing multi-backslash ([[ValidTarget\\\\\\\\]])" \
  "See [[ValidTarget\\\\\\\\]] for details.\n" \
  "yes"

# T-1 Case 3 — genuinely missing target, finding emitted after strip
run_case "T1.3 genuinely missing target emits finding" \
  "See [[GenuinelyMissing\\]] for details.\n" \
  "no"

# T-2 Case 4 — aliased target, resolves via pre-pipe portion
run_case "T2.1 aliased form ([[Target|Display Text]])" \
  "See [[Target|Display Text]] for details.\n" \
  "yes"

# T-2 Case 5 — aliased + hash fragment, resolves via pre-pipe/pre-hash portion
run_case "T2.2 aliased + hash-fragment ([[Target#heading|Display]])" \
  "See [[Target#heading|Display]] for details.\n" \
  "yes"

printf '\nResults: %d/%d passed\n' "$PASS" "$TESTS"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
