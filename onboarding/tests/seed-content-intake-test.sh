#!/usr/bin/env bash
# seed-content-intake-test.sh — SP13 T-1 unit tests
#
# Covers Stage 1 INGEST entry-point acceptance criteria:
#   AC1  intake.sh + onboard.sh syntactically clean (bash -n)
#   AC2  intake.sh exists at canonical path
#   AC3  directory walk over 10-file fixture -> 10 JSONL records, source_type=file
#   AC4  paste content -> 1 JSONL record, source_type=paste
#   AC5  onboard.sh --seed-content emits "seed content detected: N items" on stdout
#   AC6  AC1+intake-exists implicitly covers done-marker pre-condition
#
# Hermetic: writes only under $TMPDIR/sp13-t1-test-<random>/ per
# feedback_test_isolation_for_hooks_state. No live ~/.claude or vault writes.
#
# Bash 3.2 compatible (R-23).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
INTAKE="$REPO_ROOT/onboarding/seed-content/intake.sh"
ONBOARD="$REPO_ROOT/skills/onboarder/onboard.sh"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/sp13-t1-test-XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0

record_pass() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
record_fail() {
  fail=$((fail + 1))
  printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"
}
assert_eq() {
  if [ "$2" = "$3" ]; then record_pass "$1"; else record_fail "$1" "$2" "$3"; fi
}

# ---------- AC1 — syntax checks ----------
echo "AC1 — syntax checks"
if bash -n "$INTAKE" 2>/dev/null; then
  record_pass "intake.sh bash -n clean"
else
  record_fail "intake.sh bash -n clean" "rc=0" "rc=non-zero"
fi
if bash -n "$ONBOARD" 2>/dev/null; then
  record_pass "onboard.sh bash -n clean"
else
  record_fail "onboard.sh bash -n clean" "rc=0" "rc=non-zero"
fi

# ---------- AC2 — intake.sh exists ----------
echo "AC2 — intake.sh exists"
if [ -f "$INTAKE" ]; then
  record_pass "intake.sh exists at canonical path"
else
  record_fail "intake.sh exists at canonical path" "file" "missing"
fi

# ---------- AC3 — directory walk ----------
echo "AC3 — directory walk over 10-file fixture"
FIXTURE="$TMPROOT/fixture-corpus"
mkdir -p "$FIXTURE"
i=1
while [ $i -le 10 ]; do
  printf 'fixture-content-line-1\nfixture-content-line-2\n' > "$FIXTURE/file-$i.txt"
  i=$((i + 1))
done

DIR_MANIFEST="$TMPROOT/dir-out/intake-manifest.jsonl"
bash "$INTAKE" --source "$FIXTURE" --manifest "$DIR_MANIFEST" 2>/dev/null
dir_count=$(wc -l < "$DIR_MANIFEST" | tr -d ' ')
assert_eq "10 records emitted from directory walk" "10" "$dir_count"

all_valid=1
while IFS= read -r line; do
  echo "$line" | jq -e . >/dev/null 2>&1 || all_valid=0
done < "$DIR_MANIFEST"
assert_eq "all directory records valid JSON" "1" "$all_valid"

file_typed=$(jq -c 'select(.source_type=="file")' "$DIR_MANIFEST" | wc -l | tr -d ' ')
assert_eq "all 10 records source_type=file" "10" "$file_typed"

has_size=$(jq -c 'select(.size_bytes > 0)' "$DIR_MANIFEST" | wc -l | tr -d ' ')
assert_eq "all 10 records have positive size_bytes" "10" "$has_size"

# ---------- AC4 — paste content ----------
echo "AC4 — paste content -> 1 record"
PASTE_MANIFEST="$TMPROOT/paste-out/intake-manifest.jsonl"
bash "$INTAKE" --source "this is a multi-word paste blob with no resolved path" \
               --manifest "$PASTE_MANIFEST" 2>/dev/null
paste_count=$(wc -l < "$PASTE_MANIFEST" | tr -d ' ')
assert_eq "1 record from paste" "1" "$paste_count"

paste_type=$(jq -r '.source_type' "$PASTE_MANIFEST")
assert_eq "paste record source_type=paste" "paste" "$paste_type"

paste_path=$(jq -r '.path' "$PASTE_MANIFEST")
if [ -f "$paste_path" ] && grep -q '^this is a multi-word paste blob' "$paste_path"; then
  record_pass "paste content materialized to disk"
else
  record_fail "paste content materialized to disk" "exists+matches" "missing-or-mismatch"
fi

# ---------- AC5 — onboard.sh emits detection line ----------
echo "AC5 — onboard.sh --seed-content emits detection line"
FAKE_HOME="$TMPROOT/fake-home"
mkdir -p "$FAKE_HOME/.claude/onboarding"
out=$(CLAUDE_HOME="$FAKE_HOME/.claude" \
      INPUTS_DIR="$FAKE_HOME/.claude/onboarding" \
      USER_MANIFEST="$FAKE_HOME/.claude/user-manifest.json" \
      bash "$ONBOARD" --seed-content "$FIXTURE" --dry-run 2>&1) || true

if echo "$out" | grep -qx 'seed content detected: 10 items'; then
  record_pass "stdout emits 'seed content detected: 10 items'"
else
  record_fail "stdout emits 'seed content detected: 10 items'" \
              "seed content detected: 10 items" \
              "$(echo "$out" | grep -i 'seed' | head -1 | sed 's/^/    /')"
fi

# Verify intake actually wrote the manifest into the fake home.
real_manifest="$FAKE_HOME/.claude/onboarding/seed-content/intake-manifest.jsonl"
if [ -f "$real_manifest" ]; then
  real_count=$(wc -l < "$real_manifest" | tr -d ' ')
  assert_eq "manifest written under \$INPUTS_DIR (10 records)" "10" "$real_count"
else
  record_fail "manifest written under \$INPUTS_DIR" "file" "missing"
fi

# ---------- AC6 — bad invocation handling ----------
echo "AC6 — invocation hygiene"
set +e
bash "$INTAKE" --source "anything" 2>/dev/null
rc_no_manifest=$?
set -e
assert_eq "intake.sh rc=2 when --manifest missing" "2" "$rc_no_manifest"

set +e
bash "$INTAKE" --manifest "$TMPROOT/nope.jsonl" 2>/dev/null
rc_no_source=$?
set -e
assert_eq "intake.sh rc=2 when --source missing" "2" "$rc_no_source"

# ---------- summary ----------
echo
total=$((pass + fail))
echo "=========================================="
echo "Total: $total — pass=$pass fail=$fail"
if [ "$fail" -gt 0 ]; then exit 1; else exit 0; fi
