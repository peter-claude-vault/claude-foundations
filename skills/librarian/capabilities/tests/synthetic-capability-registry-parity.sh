#!/bin/bash
# Synthetic tests for capability-registry.json — Plan 71 SP04 T-5.
#
# 6 cases (registry-parity AC checks):
#   1. Registry parses as valid JSON
#   2. Registry contains exactly 31 entries (T-5 spec-canonical count)
#   3. Every shipped entry's script field points to a file that exists on disk
#   4. Every spec-only entry carries implementation_status:"spec-only"
#   5. Every judgment-tier entry carries requires_confirmation:true +
#      cron_block:"skip-non-interactive" (dispatcher gate)
#   6. SKILL.md ## Capability: headings are a subset of registry keys
#
# Usage: bash synthetic-capability-registry-parity.sh
# Exit:  0 on 6/6 pass, 1 otherwise.
#
# Bash 3.2 clean per R-23.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGISTRY="$ROOT/capability-registry.json"
SKILL_MD="$ROOT/SKILL.md"
PASS=0
FAIL=0
TESTS=0

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
# Test 1: Registry parses as valid JSON
# -----------------------------------------------------------------------------
if [ ! -f "$REGISTRY" ]; then
  assert_fail "registry-exists" "missing $REGISTRY"
  echo "Tests: $PASS/$TESTS pass, $FAIL fail"
  exit 1
fi

if ! jq empty "$REGISTRY" >/dev/null 2>&1; then
  assert_fail "registry-valid-json" "jq parse failed"
else
  assert_pass "registry-valid-json"
fi

# -----------------------------------------------------------------------------
# Test 2: Exactly 31 entries
# -----------------------------------------------------------------------------
COUNT=$(jq '.capabilities | length' "$REGISTRY")
if [ "$COUNT" = "31" ]; then
  assert_pass "registry-count-31 (got $COUNT)"
else
  assert_fail "registry-count-31" "expected 31, got $COUNT"
fi

# -----------------------------------------------------------------------------
# Test 3: Every shipped entry's script exists on disk
# -----------------------------------------------------------------------------
MISSING_SCRIPTS=""
while IFS=$'\t' read -r name script; do
  if [ ! -f "$ROOT/$script" ]; then
    MISSING_SCRIPTS="$MISSING_SCRIPTS $name:$script"
  fi
done < <(jq -r '.capabilities | to_entries[] | select(.value.implementation_status != "spec-only") | [.key, .value.script] | @tsv' "$REGISTRY")

if [ -z "$MISSING_SCRIPTS" ]; then
  assert_pass "shipped-scripts-exist (27 expected)"
else
  assert_fail "shipped-scripts-exist" "missing:$MISSING_SCRIPTS"
fi

# -----------------------------------------------------------------------------
# Test 4: spec-only entries carry implementation_status correctly
# -----------------------------------------------------------------------------
SPEC_ONLY_COUNT=$(jq '[.capabilities | to_entries[] | select(.value.implementation_status == "spec-only")] | length' "$REGISTRY")
if [ "$SPEC_ONLY_COUNT" = "4" ]; then
  assert_pass "spec-only-count-4 (got $SPEC_ONLY_COUNT)"
else
  assert_fail "spec-only-count-4" "expected 4 spec-only entries, got $SPEC_ONLY_COUNT"
fi

# -----------------------------------------------------------------------------
# Test 5: Judgment-tier dispatcher-gate fields
# -----------------------------------------------------------------------------
BAD_JUDGMENT=""
while IFS=$'\t' read -r name confirm cron; do
  if [ "$confirm" != "true" ] || [ "$cron" != "skip-non-interactive" ]; then
    BAD_JUDGMENT="$BAD_JUDGMENT $name(confirm=$confirm,cron=$cron)"
  fi
done < <(jq -r '.capabilities | to_entries[] | select(.value.tier == "judgment") | [.key, (.value.requires_confirmation|tostring), (.value.cron_block|tostring)] | @tsv' "$REGISTRY")

JUDGMENT_COUNT=$(jq '[.capabilities | to_entries[] | select(.value.tier == "judgment")] | length' "$REGISTRY")
if [ -z "$BAD_JUDGMENT" ] && [ "$JUDGMENT_COUNT" = "4" ]; then
  assert_pass "judgment-dispatcher-gate (4/4 entries: requires_confirmation=true + cron_block=skip-non-interactive)"
else
  assert_fail "judgment-dispatcher-gate" "count=$JUDGMENT_COUNT bad=$BAD_JUDGMENT"
fi

# -----------------------------------------------------------------------------
# Test 6: SKILL.md ## Capability: headings ⊆ registry keys
# -----------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
  assert_fail "skill-md-exists" "missing $SKILL_MD"
else
  REG_KEYS_FILE=$(mktemp -t reg-keys-XXXXXX)
  SKILL_KEYS_FILE=$(mktemp -t skill-keys-XXXXXX)
  trap 'rm -f "$REG_KEYS_FILE" "$SKILL_KEYS_FILE"' EXIT

  jq -r '.capabilities | keys[]' "$REGISTRY" | sort -u > "$REG_KEYS_FILE"
  grep -E "^## Capability: " "$SKILL_MD" | sed 's/^## Capability: //' | sort -u > "$SKILL_KEYS_FILE"

  ORPHAN_HEADINGS=$(comm -23 "$SKILL_KEYS_FILE" "$REG_KEYS_FILE")
  SKILL_COUNT=$(wc -l < "$SKILL_KEYS_FILE" | tr -d ' ')

  if [ -z "$ORPHAN_HEADINGS" ]; then
    assert_pass "skill-md-subset-of-registry ($SKILL_COUNT SKILL.md headings, all in registry)"
  else
    assert_fail "skill-md-subset-of-registry" "orphan headings (in SKILL.md but not registry):$(echo "$ORPHAN_HEADINGS" | tr '\n' ' ')"
  fi
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
