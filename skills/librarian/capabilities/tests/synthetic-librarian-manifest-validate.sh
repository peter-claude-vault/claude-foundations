#!/bin/bash
# Synthetic runtime tests for librarian-manifest-validate.sh — Plan 71 SP04 T-9a.
#
# Closes audit SP04-05 F-1 (SP09 T-7.5 explicit consumer mandate).
# Mirror of T-9 c4 runtime-test pattern; controlled fixtures + env isolation.
#
# 8 cases (per T-9a ACs L320-324 + briefing scope):
#   1. Valid manifest → PASS exit 0, no findings emitted
#   2. Malformed manifest → DENY exit 1 + schema-violation finding + diagnostic
#   3. Missing schema file → graceful skip exit 0 + schema-missing advisory
#   4. --dry-run on malformed → exit 0, no diagnostic written, no finding emitted
#   5. --stdin valid payload → PASS via stdin path
#   6. MANIFEST_VALIDATOR=minimal forced → DENY on malformed (tier=minimal)
#   7. Finding-shape conformance: emitted JSON parses + carries required keys
#      (finding, file, level, tier, error_count, schema)
#   8. Diagnostic log shape: append-only markdown with timestamp + JSON errors
#
# Test isolation: SCHEMAS_DIR + ERROR_LOG_DIR + FINDINGS_OUTPUT all overridden
# per scenario. No writes to $CLAUDE_HOME/logs/librarian-errors/. No writes to
# $HOOKS_STATE. Per R-23 + feedback_test_isolation_for_hooks_state.
#
# Usage: bash synthetic-librarian-manifest-validate.sh
# Exit:  0 on 8/8 pass, 1 otherwise.
#
# Bash 3.2 clean per R-23.

set -uo pipefail

CAP="$(cd "$(dirname "$0")/.." && pwd)/librarian-manifest-validate.sh"
SCHEMAS_DIR_REAL="$(cd "$(dirname "$0")/../../../.." && pwd)/schemas"
TMP="$(mktemp -d -t lmv-runtime-XXXXXX)"
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
# Fixture helpers.
# ---------------------------------------------------------------------------
write_valid_manifest() {
  cat > "$1" <<'JSON'
{
  "schema_version": "1.0.0",
  "inventory": { "by_type": {}, "by_path": {} },
  "xref_graph": {},
  "tags": {},
  "scan_state": { "last_scanned_at": null, "findings_by_capability": {} },
  "drift_findings": {
    "provides_canonicality": {},
    "size_monitoring": {},
    "schema_type_coverage": {},
    "skill_parity": {},
    "entity_parity": {}
  },
  "architect_recommendations": { "last_scanned_log": null, "items": [] },
  "rename_history": {}
}
JSON
}

write_malformed_manifest() {
  cat > "$1" <<'JSON'
{ "schema_version": "9.9.9", "inventory": {} }
JSON
}

# Run the capability with isolated env. $1 = scenario subdir; remaining = capability args.
run_iso() {
  local scenario="$1"; shift
  local root="$TMP/$scenario"
  mkdir -p "$root/log"
  SCHEMAS_DIR="$SCHEMAS_DIR_REAL" \
  ERROR_LOG_DIR="$root/log" \
  FINDINGS_OUTPUT="$root/findings.ndjson" \
  bash "$CAP" "$@" > "$root/stdout.txt" 2>&1
  echo $?
}

# Same as run_iso but with a missing-schema dir to force advisory path.
run_iso_no_schema() {
  local scenario="$1"; shift
  local root="$TMP/$scenario"
  mkdir -p "$root/log"
  SCHEMAS_DIR="$root/no-such-schemas" \
  ERROR_LOG_DIR="$root/log" \
  FINDINGS_OUTPUT="$root/findings.ndjson" \
  bash "$CAP" "$@" > "$root/stdout.txt" 2>&1
  echo $?
}

count_findings() {
  local name="$1" file="$2"
  grep -c "\"finding\": \"$name\"" "$file" 2>/dev/null | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Case 1: Valid manifest → PASS exit 0, no findings emitted.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/case1-valid"
write_valid_manifest "$TMP/case1-valid/manifest.json"
EXIT=$(run_iso "case1-valid" --file "$TMP/case1-valid/manifest.json")
F_TOTAL=0
[ -f "$TMP/case1-valid/findings.ndjson" ] && F_TOTAL=$(wc -l < "$TMP/case1-valid/findings.ndjson" | tr -d ' ')
if [ "$EXIT" = "0" ] && [ "$F_TOTAL" = "0" ]; then
  assert_pass "case1-valid: PASS exit 0, 0 findings emitted"
else
  assert_fail "case1-valid" "expected exit=0 findings=0, got exit=$EXIT findings=$F_TOTAL: $(cat "$TMP/case1-valid/stdout.txt")"
fi

# ---------------------------------------------------------------------------
# Case 2: Malformed manifest → DENY exit 1 + schema-violation finding + diagnostic.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/case2-malformed"
write_malformed_manifest "$TMP/case2-malformed/manifest.json"
EXIT=$(run_iso "case2-malformed" --file "$TMP/case2-malformed/manifest.json")
N_VIOL=$(count_findings "manifest-validate-schema-violation" "$TMP/case2-malformed/findings.ndjson")
LOG_COUNT=$(ls "$TMP/case2-malformed/log/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$EXIT" = "1" ] && [ "$N_VIOL" = "1" ] && [ "$LOG_COUNT" = "1" ]; then
  assert_pass "case2-malformed: DENY exit 1 + 1 schema-violation finding + 1 diagnostic log"
else
  assert_fail "case2-malformed" "expected exit=1 findings=1 logs=1, got exit=$EXIT findings=$N_VIOL logs=$LOG_COUNT"
fi

# ---------------------------------------------------------------------------
# Case 3: Missing schema → graceful skip exit 0 + schema-missing advisory.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/case3-no-schema"
write_valid_manifest "$TMP/case3-no-schema/manifest.json"
EXIT=$(run_iso_no_schema "case3-no-schema" --file "$TMP/case3-no-schema/manifest.json")
N_MISS=$(count_findings "manifest-validate-schema-missing" "$TMP/case3-no-schema/findings.ndjson")
LOG_COUNT=$(ls "$TMP/case3-no-schema/log/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$EXIT" = "0" ] && [ "$N_MISS" = "1" ] && [ "$LOG_COUNT" = "0" ]; then
  assert_pass "case3-no-schema: graceful skip exit 0 + 1 schema-missing advisory + 0 diagnostics"
else
  assert_fail "case3-no-schema" "expected exit=0 findings=1 logs=0, got exit=$EXIT findings=$N_MISS logs=$LOG_COUNT"
fi

# ---------------------------------------------------------------------------
# Case 4: --dry-run on malformed → exit 0, no diagnostic, no finding emitted.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/case4-dryrun"
write_malformed_manifest "$TMP/case4-dryrun/manifest.json"
EXIT=$(run_iso "case4-dryrun" --file "$TMP/case4-dryrun/manifest.json" --dry-run)
F_TOTAL=0
[ -f "$TMP/case4-dryrun/findings.ndjson" ] && F_TOTAL=$(wc -l < "$TMP/case4-dryrun/findings.ndjson" | tr -d ' ')
LOG_COUNT=$(ls "$TMP/case4-dryrun/log/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$EXIT" = "0" ] && [ "$F_TOTAL" = "0" ] && [ "$LOG_COUNT" = "0" ]; then
  assert_pass "case4-dryrun: --dry-run on malformed exits 0, no findings, no diagnostic"
else
  assert_fail "case4-dryrun" "expected exit=0 findings=0 logs=0, got exit=$EXIT findings=$F_TOTAL logs=$LOG_COUNT"
fi

# ---------------------------------------------------------------------------
# Case 5: --stdin valid payload → PASS.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/case5-stdin"
write_valid_manifest "$TMP/case5-stdin/manifest.json"
SCHEMAS_DIR="$SCHEMAS_DIR_REAL" \
ERROR_LOG_DIR="$TMP/case5-stdin/log" \
FINDINGS_OUTPUT="$TMP/case5-stdin/findings.ndjson" \
bash "$CAP" --stdin < "$TMP/case5-stdin/manifest.json" > "$TMP/case5-stdin/stdout.txt" 2>&1
EXIT=$?
F_TOTAL=0
[ -f "$TMP/case5-stdin/findings.ndjson" ] && F_TOTAL=$(wc -l < "$TMP/case5-stdin/findings.ndjson" | tr -d ' ')
PASS_HDR=$(grep -c "PASS via" "$TMP/case5-stdin/stdout.txt" | tr -d ' ')
if [ "$EXIT" = "0" ] && [ "$F_TOTAL" = "0" ] && [ "$PASS_HDR" = "1" ]; then
  assert_pass "case5-stdin: --stdin valid payload PASS exit 0"
else
  assert_fail "case5-stdin" "expected exit=0 findings=0 pass-hdr=1, got exit=$EXIT findings=$F_TOTAL pass-hdr=$PASS_HDR"
fi

# ---------------------------------------------------------------------------
# Case 6: MANIFEST_VALIDATOR=minimal forced → DENY with tier=minimal carried.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/case6-minimal"
write_malformed_manifest "$TMP/case6-minimal/manifest.json"
SCHEMAS_DIR="$SCHEMAS_DIR_REAL" \
ERROR_LOG_DIR="$TMP/case6-minimal/log" \
FINDINGS_OUTPUT="$TMP/case6-minimal/findings.ndjson" \
MANIFEST_VALIDATOR="minimal" \
bash "$CAP" --file "$TMP/case6-minimal/manifest.json" > "$TMP/case6-minimal/stdout.txt" 2>&1
EXIT=$?
TIER_OK=$(grep -c '"tier": "minimal"' "$TMP/case6-minimal/findings.ndjson" 2>/dev/null | tr -d ' ')
DENY_HDR=$(grep -c "DENY via minimal" "$TMP/case6-minimal/stdout.txt" | tr -d ' ')
if [ "$EXIT" = "1" ] && [ "$TIER_OK" = "1" ] && [ "$DENY_HDR" = "1" ]; then
  assert_pass "case6-tier-minimal: MANIFEST_VALIDATOR=minimal forced, DENY tier=minimal carried"
else
  assert_fail "case6-tier-minimal" "expected exit=1 tier-ok=1 deny-hdr=1, got exit=$EXIT tier-ok=$TIER_OK deny-hdr=$DENY_HDR"
fi

# ---------------------------------------------------------------------------
# Case 7: Finding-shape conformance — emitted JSON parses + carries required keys.
# Reuses case2-malformed findings.ndjson (already DENY'd above with 1 finding).
# ---------------------------------------------------------------------------
SHAPE_OK=$(python3 - "$TMP/case2-malformed/findings.ndjson" <<'PY'
import json, sys
needed = {"finding", "file", "level", "tier", "error_count", "schema"}
ok = True
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            ok = False
            break
        if not isinstance(obj, dict):
            ok = False
            break
        if not needed.issubset(obj.keys()):
            ok = False
            break
print("1" if ok else "0")
PY
)
if [ "$SHAPE_OK" = "1" ]; then
  assert_pass "case7-finding-shape: emitted JSON parses + carries {finding,file,level,tier,error_count,schema}"
else
  assert_fail "case7-finding-shape" "shape conformance failed: $(cat "$TMP/case2-malformed/findings.ndjson")"
fi

# ---------------------------------------------------------------------------
# Case 8: Diagnostic log shape — markdown + ISO timestamp + JSON-error blob.
# Reuses case2-malformed log dir.
# ---------------------------------------------------------------------------
DIAG_FILE=$(ls "$TMP/case2-malformed/log/"*.md 2>/dev/null | head -1)
if [ -z "$DIAG_FILE" ]; then
  assert_fail "case8-diagnostic-shape" "no .md diagnostic in case2-malformed/log/"
else
  HAS_HEADER=$(grep -cE '^## [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z — schema violation$' "$DIAG_FILE" | tr -d ' ')
  HAS_PAYLOAD=$(grep -c '^- payload:' "$DIAG_FILE" | tr -d ' ')
  HAS_TIER=$(grep -c '^- tier:' "$DIAG_FILE" | tr -d ' ')
  HAS_JSON=$(grep -c '^```json$' "$DIAG_FILE" | tr -d ' ')
  if [ "$HAS_HEADER" = "1" ] && [ "$HAS_PAYLOAD" = "1" ] && [ "$HAS_TIER" = "1" ] && [ "$HAS_JSON" = "1" ]; then
    assert_pass "case8-diagnostic-shape: markdown header + ISO ts + payload + tier + JSON blob"
  else
    assert_fail "case8-diagnostic-shape" "header=$HAS_HEADER payload=$HAS_PAYLOAD tier=$HAS_TIER json=$HAS_JSON"
  fi
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
