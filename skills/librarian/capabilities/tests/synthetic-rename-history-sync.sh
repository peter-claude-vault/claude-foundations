#!/bin/bash
# Synthetic test for rename-history-sync.sh (T-3 round-trip).
#
# Scenarios:
#   1. migrate on a registry missing rename_history — field added to every entry
#   2. migrate idempotence — second run makes no changes
#   3. append round-trip — inject NDJSON, verify history row present
#   4. append idempotence — re-inject same NDJSON, no duplicate rows

set -u

CAP="$(cd "$(dirname "$0")/.." && pwd)/rename-history-sync.sh"
[[ -x "$CAP" ]] || { echo "FAIL: $CAP not executable" >&2; exit 1; }

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

TMP=$(mktemp -d -t rhs-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

REG="$TMP/registry.json"
cat > "$REG" <<'EOF'
{
  "version": 2,
  "entries": [
    {"id":"alpha","primary":"Foo/Alpha.md"},
    {"id":"beta","primary":"Foo/Beta.md","mirrors":[{"file":"Bar/BetaMirror.md"}]},
    {"id":"gamma","primary":"Foo/Gamma.md","rename_history":[]}
  ]
}
EOF

echo "== Test 1: migrate adds field where missing =="
OUT=$(DOC_DEP_FILE="$REG" "$CAP" migrate 2>&1)
# 2 entries (alpha, beta) should be updated; gamma already had the field.
echo "$OUT" | grep -q "2 entries updated" && pass "migrate updated alpha+beta" || fail "migrate output: $OUT"
HAS_ALL=$(python3 -c 'import json;d=json.load(open("'"$REG"'"));print(all("rename_history" in e for e in d["entries"]))')
[[ "$HAS_ALL" == "True" ]] && pass "all entries have rename_history" || fail "not all entries migrated"

echo "== Test 2: migrate idempotence =="
OUT2=$(DOC_DEP_FILE="$REG" "$CAP" migrate 2>&1)
echo "$OUT2" | grep -q "0 entries updated" && pass "idempotent re-run" || fail "idempotent run output: $OUT2"

echo "== Test 3: append round-trip =="
NDJSON='{"root":"/tmp","old_path":"Foo/Alpha.md","new_path":"Baz/Alpha.md","commit_sha":"deadbeef","committed_at":"2026-04-22T10:00:00Z","similarity":100}'
OUT3=$(echo "$NDJSON" | DOC_DEP_FILE="$REG" "$CAP" append 2>&1)
echo "$OUT3" | grep -q "1 row" && pass "append count correct" || fail "append output: $OUT3"

ALPHA_ROWS=$(python3 -c 'import json;d=json.load(open("'"$REG"'"));[print(len(e["rename_history"])) for e in d["entries"] if e["id"]=="alpha"]')
[[ "$ALPHA_ROWS" == "1" ]] && pass "alpha has 1 history row" || fail "alpha rows=$ALPHA_ROWS"

FIRST_ROW=$(python3 -c 'import json;d=json.load(open("'"$REG"'"));r=[e["rename_history"] for e in d["entries"] if e["id"]=="alpha"][0];print(r[0]["from"]+":"+r[0]["to"]+":"+r[0]["commit"])')
[[ "$FIRST_ROW" == "Foo/Alpha.md:Baz/Alpha.md:deadbeef" ]] && pass "row fields correct" || fail "row=$FIRST_ROW"

echo "== Test 4: append idempotence =="
OUT4=$(echo "$NDJSON" | DOC_DEP_FILE="$REG" "$CAP" append 2>&1)
echo "$OUT4" | grep -q "0 row" && pass "no duplicate on re-append" || fail "re-append output: $OUT4"
ALPHA_ROWS_2=$(python3 -c 'import json;d=json.load(open("'"$REG"'"));[print(len(e["rename_history"])) for e in d["entries"] if e["id"]=="alpha"]')
[[ "$ALPHA_ROWS_2" == "1" ]] && pass "still 1 row after re-append" || fail "alpha rows after re-append=$ALPHA_ROWS_2"

echo ""
echo "== Summary =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
