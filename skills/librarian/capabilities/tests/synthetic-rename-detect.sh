#!/bin/bash
# Synthetic tests for capabilities/rename-detect.sh.
#
# Isolated tmp-git harness per scenario. No vault / plans state consulted.
#
# Scenarios:
#   1. Single rename                     — exactly 1 NDJSON record
#   2. Rename chain A→B→C (2 commits)   — exactly 2 records
#   3. Rename + content modify           — emits with lowered similarity
#   4. No renames in window              — empty output, exit 0
#   5. Folder rename cascading N files   — N records emitted

set -u

CAP="$(cd "$(dirname "$0")/.." && pwd)/rename-detect.sh"

if [[ ! -x "$CAP" ]]; then
  echo "FAIL: $CAP not executable" >&2
  exit 1
fi

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

make_repo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email "test@test"
  git -C "$d" config user.name "test"
}

count_records() {
  local out="$1"
  [[ -z "$out" ]] && echo 0 && return 0
  echo "$out" | grep -c '^{'
}

validate_ndjson() {
  local out="$1"
  [[ -z "$out" ]] && return 0
  echo "$out" | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | jq -c . >/dev/null 2>&1 || return 1
  done
}

TMP=$(mktemp -d -t rename-detect-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# ---- Test 1: single rename -------------------------------------------------

echo "== Test 1: single rename =="
T1="$TMP/t1"
make_repo "$T1"
printf 'hello world\nthis is a file that contains enough content to qualify for rename similarity\n' > "$T1/alpha.md"
git -C "$T1" add -A && git -C "$T1" commit -q -m "seed"
git -C "$T1" mv alpha.md beta.md
git -C "$T1" commit -q -m "rename alpha -> beta"

OUT=$("$CAP" --root "$T1" --since "1 year ago" 2>&1)
N=$(count_records "$OUT")
if [[ "$N" -eq 1 ]]; then pass "exactly 1 record"; else fail "expected 1, got $N"; echo "$OUT"; fi

if echo "$OUT" | jq -c . >/dev/null 2>&1; then pass "jq-parseable"; else fail "NDJSON not jq-parseable"; fi

OLD=$(echo "$OUT" | jq -r '.old_path')
NEW=$(echo "$OUT" | jq -r '.new_path')
[[ "$OLD" == "alpha.md" ]] && pass "old_path=alpha.md" || fail "old_path=$OLD"
[[ "$NEW" == "beta.md" ]] && pass "new_path=beta.md" || fail "new_path=$NEW"

# ---- Test 2: rename chain A -> B -> C (2 commits) --------------------------

echo "== Test 2: rename chain across 2 commits =="
T2="$TMP/t2"
make_repo "$T2"
printf 'content with enough substance to trigger rename detection heuristics\nline two\nline three\n' > "$T2/A.md"
git -C "$T2" add -A && git -C "$T2" commit -q -m "seed"
git -C "$T2" mv A.md B.md
git -C "$T2" commit -q -m "A->B"
git -C "$T2" mv B.md C.md
git -C "$T2" commit -q -m "B->C"

OUT=$("$CAP" --root "$T2" --since "1 year ago" 2>&1)
N=$(count_records "$OUT")
if [[ "$N" -eq 2 ]]; then pass "exactly 2 records"; else fail "expected 2, got $N"; echo "$OUT"; fi

# Verify both edges present (A->B and B->C).
if echo "$OUT" | jq -r '.old_path + "->" + .new_path' | grep -qx "A.md->B.md"; then
  pass "edge A->B present"
else fail "edge A->B missing"; fi
if echo "$OUT" | jq -r '.old_path + "->" + .new_path' | grep -qx "B.md->C.md"; then
  pass "edge B->C present"
else fail "edge B->C missing"; fi

# ---- Test 3: rename + content modify --------------------------------------

echo "== Test 3: rename + content modify =="
T3="$TMP/t3"
make_repo "$T3"
printf 'line-01\nline-02\nline-03\nline-04\nline-05\nline-06\nline-07\nline-08\nline-09\nline-10\nline-11\nline-12\nline-13\nline-14\nline-15\nline-16\nline-17\nline-18\nline-19\nline-20\n' > "$T3/orig.md"
git -C "$T3" add -A && git -C "$T3" commit -q -m "seed"
git -C "$T3" mv orig.md moved.md
# Modify ~1 line out of 20 (~95% similar, comfortably above -M90 threshold).
printf 'line-01\nline-02\nline-03\nline-04\nMODIFIED\nline-06\nline-07\nline-08\nline-09\nline-10\nline-11\nline-12\nline-13\nline-14\nline-15\nline-16\nline-17\nline-18\nline-19\nline-20\n' > "$T3/moved.md"
git -C "$T3" add -A && git -C "$T3" commit -q -m "rename+modify"

OUT=$("$CAP" --root "$T3" --since "1 year ago" 2>&1)
N=$(count_records "$OUT")
if [[ "$N" -eq 1 ]]; then pass "exactly 1 record for rename+modify"; else fail "expected 1, got $N"; echo "$OUT"; fi
SIM=$(echo "$OUT" | jq -r '.similarity')
if [[ "$SIM" -ge 90 && "$SIM" -le 100 ]]; then pass "similarity $SIM in [90,100]"; else fail "similarity=$SIM out of range"; fi

# ---- Test 4: no renames in window -----------------------------------------

echo "== Test 4: no renames -> empty output =="
T4="$TMP/t4"
make_repo "$T4"
printf 'just a file\n' > "$T4/only.md"
git -C "$T4" add -A && git -C "$T4" commit -q -m "seed"
OUT=$("$CAP" --root "$T4" --since "1 year ago" 2>&1)
if [[ -z "$OUT" ]]; then pass "empty output"; else fail "expected empty, got: $OUT"; fi

# Separately: non-git directory root — capability should skip silently.
NONGIT="$TMP/nongit"
mkdir -p "$NONGIT"
T4b_OUT=$("$CAP" --root "$NONGIT" --since "1 year ago" 2>&1)
if [[ -z "$T4b_OUT" ]]; then pass "empty output for non-git root"; else fail "expected empty (non-git), got: $T4b_OUT"; fi

# ---- Test 5: folder rename cascading N files ------------------------------

echo "== Test 5: folder rename cascading 3 files =="
T5="$TMP/t5"
make_repo "$T5"
mkdir -p "$T5/old-dir"
for i in 1 2 3; do
  printf 'content file %d with enough body to be rename-detected by git\nline2\nline3\n' "$i" > "$T5/old-dir/file$i.md"
done
git -C "$T5" add -A && git -C "$T5" commit -q -m "seed"
git -C "$T5" mv old-dir new-dir
git -C "$T5" commit -q -m "folder rename"

OUT=$("$CAP" --root "$T5" --since "1 year ago" 2>&1)
N=$(count_records "$OUT")
if [[ "$N" -eq 3 ]]; then pass "3 records (folder rename)"; else fail "expected 3, got $N"; echo "$OUT"; fi

for i in 1 2 3; do
  if echo "$OUT" | jq -r '.old_path + "->" + .new_path' | grep -qx "old-dir/file$i.md->new-dir/file$i.md"; then
    pass "edge file$i.md"
  else fail "edge file$i.md missing"; fi
done

# ---- summary ---------------------------------------------------------------
echo ""
echo "== Summary =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
