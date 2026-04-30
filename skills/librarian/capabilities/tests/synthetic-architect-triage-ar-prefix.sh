#!/bin/bash
# Synthetic test for architect-triage.sh [AR-NNN] migration.
# Lockstep proof: SP04 T-10 + SP05 T-4 (foundation-engine-v2).
#
# Positive: log with 3 [AR-NNN] entries -> 3 items in
#   manifest.architect_recommendations.recommendations[]; all IDs match AR-NNN.
# Negative: log with 1 legacy [R-001] entry -> 0 items + per-source advisory
#   finding "architect-legacy-prefix-skipped" emitted.
#
# Bash 3.2 clean per R-23. Isolated tmp scope per case.

set -uo pipefail

CAP="$(cd "$(dirname "$0")/.." && pwd)/architect-triage.sh"
if [[ ! -f "$CAP" ]]; then
  echo "FAIL: $CAP missing" >&2
  exit 1
fi

PASS=0; FAIL=0; TESTS=0
TMP=$(mktemp -d -t arch-triage-ar-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

assert_pass() { TESTS=$((TESTS+1)); PASS=$((PASS+1)); echo "PASS: $1"; }
assert_fail() {
  TESTS=$((TESTS+1)); FAIL=$((FAIL+1))
  echo "FAIL: $1"
  [ -n "${2:-}" ] && echo "  detail: $2"
}

count_recs() {
  python3 -c "
import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(len(d.get('architect_recommendations', {}).get('recommendations', [])))
except Exception:
    print('PARSE_ERR')
" "$1"
}

count_ar_ids() {
  python3 -c "
import json,re,sys
try:
    d = json.load(open(sys.argv[1]))
    recs = d.get('architect_recommendations', {}).get('recommendations', [])
    print(sum(1 for r in recs if re.match(r'^AR-\d{3}\$', r.get('id', ''))))
except Exception:
    print('PARSE_ERR')
" "$1"
}

# ---------------------------------------------------------------------------
# Test A — Positive: 3 [AR-NNN] entries triaged into manifest items[]
# ---------------------------------------------------------------------------
echo "== Test A: positive 3 [AR-NNN] entries =="

LOGDIR_A="$TMP/logs-a"; mkdir -p "$LOGDIR_A"
cat > "$LOGDIR_A/architect-2026-04-29.md" <<'EOF'
---
type: architect-report
date: 2026-04-29
---

## Recommendations

**[AR-001] First Recommendation**
**Category:** quick-win
**Confidence:** high

**[AR-002] Second Recommendation**
**Category:** structural
**Confidence:** medium

**[AR-003] Third Recommendation**
**Category:** exploratory
**Confidence:** low
EOF

mkdir -p "$TMP/m-a"
echo '{}' > "$TMP/m-a/librarian-manifest.json"

ARCHITECT_LOGS_GLOB="$LOGDIR_A/architect-*.md" \
SYSTEM_BACKLOG_PATH="$TMP/no-backlog.md" \
MANIFEST_PATH="$TMP/m-a/librarian-manifest.json" \
FINDINGS_OUTPUT="$TMP/findings-a.ndjson" \
bash "$CAP" --check > "$TMP/out-a.txt" 2>&1
EXIT_A=$?

if [ "$EXIT_A" = "0" ]; then
  assert_pass "positive-exit-zero"
else
  assert_fail "positive-exit-zero" "exit=$EXIT_A; output: $(cat "$TMP/out-a.txt")"
fi

REC_A=$(count_recs "$TMP/m-a/librarian-manifest.json")
if [ "$REC_A" = "3" ]; then
  assert_pass "positive-3-items-in-manifest"
else
  assert_fail "positive-3-items-in-manifest" "got: $REC_A"
fi

ID_AR_A=$(count_ar_ids "$TMP/m-a/librarian-manifest.json")
if [ "$ID_AR_A" = "3" ]; then
  assert_pass "positive-3-ids-match-AR-regex"
else
  assert_fail "positive-3-ids-match-AR-regex" "got: $ID_AR_A"
fi

# Positive case must NOT emit any legacy-skipped advisory.
if [ -f "$TMP/findings-a.ndjson" ] && grep -q "architect-legacy-prefix-skipped" "$TMP/findings-a.ndjson"; then
  assert_fail "positive-no-spurious-legacy-advisory" "advisory leaked into pure-AR-NNN run"
else
  assert_pass "positive-no-spurious-legacy-advisory"
fi

# ---------------------------------------------------------------------------
# Test B — Negative: legacy [R-001] entry skipped + advisory emitted
# ---------------------------------------------------------------------------
echo "== Test B: negative legacy [R-001] entry =="

LOGDIR_B="$TMP/logs-b"; mkdir -p "$LOGDIR_B"
cat > "$LOGDIR_B/architect-2026-04-15.md" <<'EOF'
---
type: architect-report
date: 2026-04-15
---

## Recommendations

**[R-001] Legacy Recommendation**
**Category:** quick-win
**Confidence:** high
EOF

mkdir -p "$TMP/m-b"
echo '{}' > "$TMP/m-b/librarian-manifest.json"

ARCHITECT_LOGS_GLOB="$LOGDIR_B/architect-*.md" \
SYSTEM_BACKLOG_PATH="$TMP/no-backlog.md" \
MANIFEST_PATH="$TMP/m-b/librarian-manifest.json" \
FINDINGS_OUTPUT="$TMP/findings-b.ndjson" \
bash "$CAP" --check > "$TMP/out-b.txt" 2>&1
EXIT_B=$?

if [ "$EXIT_B" = "0" ]; then
  assert_pass "negative-exit-zero"
else
  assert_fail "negative-exit-zero" "exit=$EXIT_B; output: $(cat "$TMP/out-b.txt")"
fi

REC_B=$(count_recs "$TMP/m-b/librarian-manifest.json")
if [ "$REC_B" = "0" ]; then
  assert_pass "negative-0-items-in-manifest"
else
  assert_fail "negative-0-items-in-manifest" "got: $REC_B"
fi

# Advisory line emitted, names the source file, count=1
if [ -f "$TMP/findings-b.ndjson" ] && grep -q "architect-legacy-prefix-skipped" "$TMP/findings-b.ndjson"; then
  assert_pass "negative-advisory-finding-emitted"
else
  assert_fail "negative-advisory-finding-emitted" "findings: $(cat "$TMP/findings-b.ndjson" 2>/dev/null || echo missing)"
fi

if [ -f "$TMP/findings-b.ndjson" ] && grep -q '"count": 1' "$TMP/findings-b.ndjson"; then
  assert_pass "negative-advisory-count-equals-1"
else
  assert_fail "negative-advisory-count-equals-1" "findings: $(cat "$TMP/findings-b.ndjson" 2>/dev/null)"
fi

if [ -f "$TMP/findings-b.ndjson" ] && grep -q '"file": "architect-2026-04-15.md"' "$TMP/findings-b.ndjson"; then
  assert_pass "negative-advisory-names-source-file"
else
  assert_fail "negative-advisory-names-source-file"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Tests: $PASS/$TESTS pass, $FAIL fail"
[ "$FAIL" = "0" ] && exit 0 || exit 1
