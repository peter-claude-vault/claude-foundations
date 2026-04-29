#!/bin/bash
# Plan 71 SP09 T-12.7 fixture — sanctioned-schema-drift-detect synthetic tests.
#
# Test 1: all 3 schemas matched → PASS no findings (exit 0)
# Test 2: 1 schema diverged → DENY with finding text (exit 1, "DRIFT:" line)

set -euo pipefail

CAPABILITY="$HOME/Code/claude-foundations-v2/skills/librarian/capabilities/sanctioned-schema-drift-detect.sh"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "PASS: $desc (expected=$expected got=$actual)"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc (expected=$expected got=$actual)"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q -- "$needle"; then
    PASS=$((PASS + 1))
    echo "PASS: $desc (matched: $needle)"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc (needle not found: $needle; got: $haystack)"
  fi
}

[[ -x "$CAPABILITY" ]] || { echo "FAIL: capability not executable: $CAPABILITY"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/foundation/schemas" "$TMP/live/schemas"

for s in vault-schema plans-schema plan-manifest-schema; do
  printf '{"$id":"%s","version":"1.0.0"}\n' "$s" > "$TMP/foundation/schemas/$s.json"
  cp "$TMP/foundation/schemas/$s.json" "$TMP/live/schemas/$s.json"
done

# === Test 1: all 3 schemas matched → PASS no findings ===
set +e
out1=$(FOUNDATION_REPO="$TMP/foundation" LIVE_SCHEMAS="$TMP/live/schemas" "$CAPABILITY" 2>&1)
ec1=$?
set -e
assert_eq "all 3 matched → exit 0" "0" "$ec1"
assert_contains "PASS marker present" "PASS:" "$out1"

# === Test 2: 1 schema diverged → DENY with finding text ===
printf '{"$id":"vault-schema","version":"2.0.0-DIVERGED"}\n' > "$TMP/live/schemas/vault-schema.json"
set +e
out2=$(FOUNDATION_REPO="$TMP/foundation" LIVE_SCHEMAS="$TMP/live/schemas" "$CAPABILITY" 2>&1)
ec2=$?
set -e
assert_eq "1 diverged → exit 1" "1" "$ec2"
assert_contains "DRIFT marker present" "DRIFT: vault-schema" "$out2"
assert_contains "finding count = 1" "1 finding" "$out2"

# === Test 3 (bonus, --json mode): 1 diverged → JSON envelope ===
set +e
out3=$(FOUNDATION_REPO="$TMP/foundation" LIVE_SCHEMAS="$TMP/live/schemas" "$CAPABILITY" --json 2>&1)
ec3=$?
set -e
assert_eq "json mode 1 diverged → exit 1" "1" "$ec3"
if echo "$out3" | jq -e '.drift_count == 1 and (.findings | length) == 1' >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  echo "PASS: json envelope shape (drift_count=1, findings.length=1)"
else
  FAIL=$((FAIL + 1))
  echo "FAIL: json envelope shape (got: $out3)"
fi

echo "---"
echo "RESULT: $PASS pass / $FAIL fail"
[[ $FAIL -eq 0 ]]
