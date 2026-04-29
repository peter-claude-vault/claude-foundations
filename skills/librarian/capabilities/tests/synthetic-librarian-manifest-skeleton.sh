#!/bin/bash
# Synthetic regression test for librarian-manifest-skeleton.json — Plan 71 SP04 T-5a.
#
# Asserts the shipped install-time skeleton validates against
# librarian-manifest-schema.json via the T-9a librarian-manifest-validate
# capability. Catches drift between schema and skeleton if either changes
# without lockstep update — the matched-pair invariant T-5a + T-9a establish.
#
# 4 cases:
#   1. Skeleton file exists at expected install-source path
#   2. Skeleton parses as valid JSON
#   3. T-9a validator returns PASS via tier-3 minimal (validates required[])
#   4. Skeleton has all 8 schema-mandated top-level keys present
#      (regression guard: a key drop would break SP08 T-1 install)
#
# Usage: bash synthetic-librarian-manifest-skeleton.sh
# Exit:  0 on 4/4 pass, 1 otherwise.
#
# Bash 3.2 clean per R-23.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SKELETON="$ROOT/templates/librarian-manifest-skeleton.json"
SCHEMA="$ROOT/schemas/librarian-manifest-schema.json"
VALIDATOR="$ROOT/skills/librarian/capabilities/librarian-manifest-validate.sh"
TMP="$(mktemp -d -t lms-XXXXXX)"
PASS=0
FAIL=0
TESTS=0

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

assert_pass() {
  TESTS=$((TESTS + 1))
  PASS=$((PASS + 1))
  echo "PASS: $1"
}

assert_fail() {
  TESTS=$((TESTS + 1))
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
  [ -n "${2:-}" ] && echo "  detail: $2"
}

# -----------------------------------------------------------------------------
# Test 1: Skeleton file exists at expected install-source path
# -----------------------------------------------------------------------------
if [ -f "$SKELETON" ]; then
  assert_pass "skeleton-exists ($SKELETON)"
else
  assert_fail "skeleton-exists" "missing $SKELETON"
  echo "Tests: $PASS/$TESTS pass, $FAIL fail"
  exit 1
fi

# -----------------------------------------------------------------------------
# Test 2: Valid JSON
# -----------------------------------------------------------------------------
if jq empty "$SKELETON" >/dev/null 2>&1; then
  assert_pass "skeleton-valid-json"
else
  assert_fail "skeleton-valid-json" "jq parse failed"
fi

# -----------------------------------------------------------------------------
# Test 3: T-9a validator returns PASS (tier-3 minimal — no external deps).
# Isolated env: SCHEMAS_DIR override + ERROR_LOG_DIR contained in $TMP.
# -----------------------------------------------------------------------------
SCHEMAS_DIR="$ROOT/schemas" \
ERROR_LOG_DIR="$TMP/log" \
FINDINGS_OUTPUT="$TMP/findings.ndjson" \
MANIFEST_VALIDATOR="minimal" \
bash "$VALIDATOR" --file "$SKELETON" > "$TMP/stdout.txt" 2>&1
EXIT=$?
F_TOTAL=0
[ -f "$TMP/findings.ndjson" ] && F_TOTAL=$(wc -l < "$TMP/findings.ndjson" | tr -d ' ')
PASS_HDR=$(grep -c "PASS via" "$TMP/stdout.txt" | tr -d ' ')
if [ "$EXIT" = "0" ] && [ "$F_TOTAL" = "0" ] && [ "$PASS_HDR" = "1" ]; then
  assert_pass "skeleton-validates-via-t9a-minimal (exit 0, 0 findings)"
else
  assert_fail "skeleton-validates-via-t9a-minimal" "exit=$EXIT findings=$F_TOTAL pass-hdr=$PASS_HDR; output: $(cat "$TMP/stdout.txt")"
fi

# -----------------------------------------------------------------------------
# Test 4: All 8 schema-mandated top-level keys present (regression guard).
# Schema required[]: schema_version, inventory, xref_graph, tags,
# scan_state, drift_findings, architect_recommendations, rename_history.
# -----------------------------------------------------------------------------
MISSING=""
for key in schema_version inventory xref_graph tags scan_state drift_findings architect_recommendations rename_history; do
  if ! jq -e --arg k "$key" 'has($k)' "$SKELETON" >/dev/null 2>&1; then
    MISSING="$MISSING $key"
  fi
done
if [ -z "$MISSING" ]; then
  assert_pass "skeleton-all-8-toplevel-keys-present"
else
  assert_fail "skeleton-all-8-toplevel-keys-present" "missing:$MISSING"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "Tests: $PASS/$TESTS pass, $FAIL fail"
if [ "$FAIL" = "0" ]; then
  exit 0
fi
exit 1
