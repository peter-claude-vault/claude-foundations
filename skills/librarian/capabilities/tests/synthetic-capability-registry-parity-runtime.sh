#!/bin/bash
# Synthetic runtime tests for capability-registry-parity.sh — Plan 71 SP04 T-9.
#
# DISTINCT from synthetic-capability-registry-parity.sh — that test asserts
# the live registry JSON file shape (count == 32, bijection holds, etc.).
# THIS test exercises the runtime capability against controlled drift fixtures.
#
# 7 cases (per T-9 ACs L283-286):
#   1. Clean fixture — pristine 2-capability registry → 0 findings
#   2. Bijection drift A — drop registry entry, SKILL.md heading remains
#      → registry-parity-bijection-drift, direction=skill-md-without-registry-entry
#   3. Bijection drift B — drop SKILL.md heading, registry entry remains
#      → registry-parity-bijection-drift, direction=registry-entry-without-skill-md-heading
#   4. Missing script — shipped entry's script field points to missing file
#      → registry-parity-script-missing
#   5. Spec-only entry with missing script — must NOT emit (spec-only excluded)
#   6. Schema-version drift — fixture schema_version=2, expected=1
#      → registry-parity-schema-version-drift
#   7. emits_findings:true without writes_manifest_subtree key
#      → registry-parity-emits-missing-subtree-field
#   + Performance assertion: runtime under 5s on live 32-entry registry
#
# Usage: bash synthetic-capability-registry-parity-runtime.sh
# Exit:  0 on 8/8 pass, 1 otherwise.
#
# Bash 3.2 clean per R-23.

set -uo pipefail

CAP="$(cd "$(dirname "$0")/.." && pwd)/capability-registry-parity.sh"
LIVE_REGISTRY="$(cd "$(dirname "$0")/../.." && pwd)/capability-registry.json"
TMP="$(mktemp -d -t cap-registry-parity-runtime-XXXXXX)"
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

# ---------------------------------------------------------------------------
# Fixture builder — minimal librarian/ tree with controllable drift.
# $1 = scenario name (subdir under $TMP)
# Reads stdin: jq filter that mutates a base 2-capability registry.
# ---------------------------------------------------------------------------
make_fixture() {
  local name="$1"
  local root="$TMP/$name"
  mkdir -p "$root/capabilities" "$root/lib"

  # Symlink lib/findings.sh to live one (capability sources it).
  ln -s "$(cd "$(dirname "$0")/../../lib" && pwd)/findings.sh" "$root/lib/findings.sh"

  # Base registry: 2 capabilities (one shipped, one spec-only).
  cat > "$root/capability-registry.json" <<'JSON'
{
  "schema_version": 1,
  "capabilities": {
    "alpha": {
      "tier": "mechanical",
      "cron_block": "none",
      "emits_findings": true,
      "writes_manifest_subtree": null,
      "requires_confirmation": false,
      "implementation_status": "shipped",
      "script": "capabilities/alpha.sh"
    },
    "beta": {
      "tier": "mechanical",
      "cron_block": "none",
      "emits_findings": false,
      "writes_manifest_subtree": null,
      "requires_confirmation": false,
      "implementation_status": "spec-only",
      "script": "capabilities/beta.sh"
    }
  }
}
JSON

  # Apply scenario mutation if filter provided on stdin.
  if [ ! -t 0 ]; then
    local filter
    filter=$(cat)
    if [ -n "$filter" ]; then
      jq "$filter" "$root/capability-registry.json" > "$root/.tmp.json"
      mv "$root/.tmp.json" "$root/capability-registry.json"
    fi
  fi

  # SKILL.md with both headings (matched to base registry).
  cat > "$root/SKILL.md" <<'MD'
# Test SKILL

## Capability: alpha

stub

## Capability: beta

stub
MD

  # Shipped script exists by default; contract-reserved stub MAY exist
  # (the parity test excludes contract-reserved entries, so a missing
  # script for them is FINE).
  echo '#!/bin/bash' > "$root/capabilities/alpha.sh"
  chmod +x "$root/capabilities/alpha.sh"

  echo "$root"
}

# Run the capability against a fixture root + capture findings to a tmp file.
# $1 = fixture root, $2 = output file
# Returns capability exit code.
run_against() {
  local root="$1" output="$2"
  shift 2
  LIBRARIAN_ROOT_OVERRIDE="$root" \
    FINDINGS_OUTPUT="$output" \
    bash "$CAP" "$@" >/dev/null 2>&1
}

# Count findings of a given finding-name in the output file.
count_findings() {
  local name="$1" file="$2"
  grep -c "\"finding\": \"$name\"" "$file" 2>/dev/null | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Test 1: Clean fixture — 0 findings
# ---------------------------------------------------------------------------
ROOT=$(echo "" | make_fixture "case1-clean")
OUT="$TMP/case1.ndjson"
> "$OUT"
run_against "$ROOT" "$OUT"
TOTAL=$(wc -l < "$OUT" | tr -d ' ')
if [ "$TOTAL" = "0" ]; then
  assert_pass "case1-clean: 0 findings on pristine fixture"
else
  assert_fail "case1-clean" "expected 0 findings, got $TOTAL: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test 2: Bijection drift A — drop registry entry, SKILL.md heading remains
# ---------------------------------------------------------------------------
ROOT=$(echo 'del(.capabilities.beta)' | make_fixture "case2-bijection-a")
OUT="$TMP/case2.ndjson"
> "$OUT"
run_against "$ROOT" "$OUT"
N=$(count_findings "registry-parity-bijection-drift" "$OUT")
DIR_OK=$(grep -c '"direction": "skill-md-without-registry-entry"' "$OUT" 2>/dev/null | tr -d '[:space:]')
if [ "$N" = "1" ] && [ "$DIR_OK" = "1" ]; then
  assert_pass "case2-bijection-a: 1 bijection-drift (direction=skill-md-without-registry-entry)"
else
  assert_fail "case2-bijection-a" "expected 1 bijection-drift skill-md-without-registry-entry, got count=$N dir_ok=$DIR_OK: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test 3: Bijection drift B — drop SKILL.md heading, registry entry remains
# ---------------------------------------------------------------------------
ROOT=$(echo "" | make_fixture "case3-bijection-b")
# Strip beta heading + body.
{
  echo "# Test SKILL"
  echo ""
  echo "## Capability: alpha"
  echo ""
  echo "stub"
} > "$ROOT/SKILL.md"
OUT="$TMP/case3.ndjson"
> "$OUT"
run_against "$ROOT" "$OUT"
N=$(count_findings "registry-parity-bijection-drift" "$OUT")
DIR_OK=$(grep -c '"direction": "registry-entry-without-skill-md-heading"' "$OUT" 2>/dev/null | tr -d '[:space:]')
# beta is spec-only so no script-missing; only the 1 bijection finding expected.
if [ "$N" = "1" ] && [ "$DIR_OK" = "1" ]; then
  assert_pass "case3-bijection-b: 1 bijection-drift (direction=registry-entry-without-skill-md-heading)"
else
  assert_fail "case3-bijection-b" "expected 1 bijection-drift registry-entry-without-skill-md-heading, got count=$N dir_ok=$DIR_OK: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test 4: Missing script on shipped entry → emits script-missing
# ---------------------------------------------------------------------------
ROOT=$(echo "" | make_fixture "case4-missing-script")
rm -f "$ROOT/capabilities/alpha.sh"
OUT="$TMP/case4.ndjson"
> "$OUT"
run_against "$ROOT" "$OUT"
N=$(count_findings "registry-parity-script-missing" "$OUT")
NAME_OK=$(grep -c '"file": "alpha"' "$OUT" 2>/dev/null | tr -d '[:space:]')
if [ "$N" = "1" ] && [ "$NAME_OK" = "1" ]; then
  assert_pass "case4-missing-script: 1 script-missing on alpha"
else
  assert_fail "case4-missing-script" "expected 1 script-missing on alpha, got count=$N name_ok=$NAME_OK: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test 5: Spec-only entry with missing script → MUST NOT emit
# ---------------------------------------------------------------------------
ROOT=$(echo "" | make_fixture "case5-spec-only-excluded")
# beta.sh deliberately not created; beta is spec-only, so should be excluded.
OUT="$TMP/case5.ndjson"
> "$OUT"
run_against "$ROOT" "$OUT"
N=$(count_findings "registry-parity-script-missing" "$OUT")
if [ "$N" = "0" ]; then
  assert_pass "case5-spec-only-excluded: 0 script-missing (spec-only entries excluded per AC)"
else
  assert_fail "case5-spec-only-excluded" "expected 0 script-missing, got $N: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test 6: schema_version drift
# ---------------------------------------------------------------------------
ROOT=$(echo '.schema_version = 99' | make_fixture "case6-schema-version")
OUT="$TMP/case6.ndjson"
> "$OUT"
run_against "$ROOT" "$OUT"
N=$(count_findings "registry-parity-schema-version-drift" "$OUT")
if [ "$N" = "1" ]; then
  assert_pass "case6-schema-version: 1 schema-version-drift (expected=1 actual=99)"
else
  assert_fail "case6-schema-version" "expected 1 schema-version-drift, got $N: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test 7: emits_findings:true without writes_manifest_subtree key
# ---------------------------------------------------------------------------
ROOT=$(echo 'del(.capabilities.alpha.writes_manifest_subtree)' | make_fixture "case7-emits-no-subtree")
OUT="$TMP/case7.ndjson"
> "$OUT"
run_against "$ROOT" "$OUT"
N=$(count_findings "registry-parity-emits-missing-subtree-field" "$OUT")
NAME_OK=$(grep -c '"file": "alpha"' "$OUT" 2>/dev/null | tr -d '[:space:]')
if [ "$N" = "1" ] && [ "$NAME_OK" = "1" ]; then
  assert_pass "case7-emits-no-subtree: 1 emits-missing-subtree-field on alpha"
else
  assert_fail "case7-emits-no-subtree" "expected 1 emits-missing-subtree-field on alpha, got count=$N name_ok=$NAME_OK: $(cat "$OUT")"
fi

# ---------------------------------------------------------------------------
# Test 8: Performance — runs under 5s on live 32-entry registry
# ---------------------------------------------------------------------------
START=$(date +%s)
bash "$CAP" >/dev/null 2>&1
END=$(date +%s)
ELAPSED=$((END - START))
if [ "$ELAPSED" -lt "5" ]; then
  assert_pass "case8-perf: live registry scan in ${ELAPSED}s (<5s)"
else
  assert_fail "case8-perf" "live registry scan took ${ELAPSED}s (>=5s)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Tests: $PASS/$TESTS pass, $FAIL fail"
if [ "$FAIL" = "0" ]; then
  exit 0
fi
exit 1
