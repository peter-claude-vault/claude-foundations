#!/usr/bin/env bash
# synthetic-architect-first-scan.sh — Plan 71 SP05 T-3.
#
# Structural contract test for architect SKILL.md first-scan-safe branch +
# Dimension 7 try/skip pattern. Architect is LLM-interpreted (not a runnable
# script), so this test verifies the SKILL.md contract surface and the
# librarian-manifest-skeleton empty-state shape that first-scan depends on.
#
# 8 cases:
#   1. SKILL.md exists at expected path
#   2. SKILL.md declares ## First-Scan Behavior section
#   3. SKILL.md documents --compare null-handling (last_scanned_log == null)
#   4. SKILL.md documents Adaptive-mode Dim 1 + 6 Cool-tier on first scan
#   5. SKILL.md introduces NO --first-scan CLI flag (per spec recommendation)
#   6. SKILL.md Dimension 7 has try/skip wrapper + never-cascade-fail clause
#   7. librarian-manifest-skeleton has last_scanned_log == null
#   8. librarian-manifest-skeleton has items == []
#
# Read-only test; no state mutation, no test-isolation concern beyond
# read-source paths.
#
# Usage: bash synthetic-architect-first-scan.sh
# Exit:  0 on 8/8 pass, 1 otherwise.
#
# Bash 3.2 compatible (R-23).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/architect/SKILL.md"
SKELETON="$ROOT/templates/librarian-manifest-skeleton.json"

PASS=0
FAIL=0
TESTS=0

assert_pass() {
  TESTS=$((TESTS + 1))
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}

assert_fail() {
  TESTS=$((TESTS + 1))
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '       detail: %s\n' "$2"
}

# -----------------------------------------------------------------------------
# Case 1: SKILL.md exists
# -----------------------------------------------------------------------------
if [ -f "$SKILL" ]; then
  assert_pass "skill-md-exists ($SKILL)"
else
  assert_fail "skill-md-exists" "missing $SKILL"
  printf '\nTests: %d/%d pass, %d fail\n' "$PASS" "$TESTS" "$FAIL"
  exit 1
fi

# -----------------------------------------------------------------------------
# Case 2: ## First-Scan Behavior section present
# -----------------------------------------------------------------------------
if grep -qE '^## First-Scan Behavior$' "$SKILL"; then
  assert_pass "first-scan-behavior-section"
else
  assert_fail "first-scan-behavior-section" "missing '## First-Scan Behavior' heading in $SKILL"
fi

# -----------------------------------------------------------------------------
# Case 3: --compare null-handling documented
# (look for both --compare and last_scanned_log == null in proximity)
# -----------------------------------------------------------------------------
if grep -qE '\-\-compare' "$SKILL" && grep -qE 'last_scanned_log == null' "$SKILL"; then
  assert_pass "compare-null-handling-documented"
else
  assert_fail "compare-null-handling-documented" \
    "missing --compare or 'last_scanned_log == null' reference in $SKILL"
fi

# -----------------------------------------------------------------------------
# Case 4: Adaptive-mode Dim 1 + 6 Cool-tier on first scan documented
# -----------------------------------------------------------------------------
if grep -qE 'Dimensions? 1.*(and|\+).*6.*Cool' "$SKILL" \
   || ( grep -qE 'Dimension 1' "$SKILL" \
        && grep -qE 'Dimension 6' "$SKILL" \
        && grep -qE 'Cool' "$SKILL" \
        && grep -qE 'first[ -]scan' "$SKILL" ); then
  assert_pass "adaptive-dim1-dim6-cool-tier-first-scan"
else
  assert_fail "adaptive-dim1-dim6-cool-tier-first-scan" \
    "missing Adaptive Dim 1 + 6 Cool-tier first-scan documentation in $SKILL"
fi

# -----------------------------------------------------------------------------
# Case 5: NO --first-scan CLI flag introduced.
# Positive-assertion-of-negation: SKILL.md must explicitly state no flag.
# Forbids any other mention of `--first-scan` outside the negation phrase.
# -----------------------------------------------------------------------------
NEG_HITS=$(grep -cE 'No `--first-scan` flag' "$SKILL")
ALL_HITS=$(grep -cE '\-\-first-scan' "$SKILL")
if [ "$NEG_HITS" -ge 1 ] && [ "$ALL_HITS" -le "$NEG_HITS" ]; then
  assert_pass "no-first-scan-flag"
else
  assert_fail "no-first-scan-flag" \
    "expected exactly the negation phrase, got NEG=$NEG_HITS ALL=$ALL_HITS in $SKILL"
fi

# -----------------------------------------------------------------------------
# Case 6: Dimension 7 try/skip wrapper + never-cascade-fail clause
# -----------------------------------------------------------------------------
if grep -qE 'Try/skip' "$SKILL" \
   && grep -qE 'External research unavailable' "$SKILL" \
   && grep -qE 'cascade-fail' "$SKILL"; then
  assert_pass "dim-7-try-skip-pattern"
else
  assert_fail "dim-7-try-skip-pattern" \
    "missing Try/skip wrapper or never-cascade-fail clause for Dim 7 in $SKILL"
fi

# -----------------------------------------------------------------------------
# Case 7: librarian-manifest-skeleton last_scanned_log == null
# -----------------------------------------------------------------------------
if [ ! -f "$SKELETON" ]; then
  assert_fail "skeleton-last-scanned-log-null" "missing $SKELETON"
elif command -v jq >/dev/null 2>&1; then
  V=$(jq -r '.architect_recommendations.last_scanned_log' "$SKELETON" 2>/dev/null)
  if [ "$V" = "null" ]; then
    assert_pass "skeleton-last-scanned-log-null"
  else
    assert_fail "skeleton-last-scanned-log-null" \
      "expected null, got: $V"
  fi
else
  assert_fail "skeleton-last-scanned-log-null" "jq not available"
fi

# -----------------------------------------------------------------------------
# Case 8: librarian-manifest-skeleton items == []
# -----------------------------------------------------------------------------
if [ ! -f "$SKELETON" ]; then
  assert_fail "skeleton-items-empty" "missing $SKELETON"
elif command -v jq >/dev/null 2>&1; then
  N=$(jq -r '.architect_recommendations.items | length' "$SKELETON" 2>/dev/null)
  if [ "$N" = "0" ]; then
    assert_pass "skeleton-items-empty"
  else
    assert_fail "skeleton-items-empty" \
      "expected empty array (length 0), got length: $N"
  fi
else
  assert_fail "skeleton-items-empty" "jq not available"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf '\nTests: %d/%d pass, %d fail\n' "$PASS" "$TESTS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
