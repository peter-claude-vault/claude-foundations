#!/usr/bin/env bash
# seedignore-filter-test.sh — SP13 T-2 unit tests
#
# Covers .seedignore scope filter acceptance criteria:
#   AC1  seedignore-filter.sh + intake.sh syntactically clean
#   AC2  10 files + .seedignore excluding 3 patterns -> 7 records in manifest
#   AC3  missing .seedignore -> all 10 records pass through
#   AC4  .seedignore with only comments/blanks -> all records pass through
#   AC5  .seedignore.example exists with sensible defaults
#   AC6  docs/seed-content-pipeline.md exists
#   AC7  directory pattern (trailing /) excludes nested dir contents
#
# Hermetic: $TMPDIR/sp13-t2-test-XXXXXX. No live writes.
# Bash 3.2 compatible (R-23).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
INTAKE="$REPO_ROOT/onboarding/seed-content/intake.sh"
FILTER="$REPO_ROOT/onboarding/seed-content/seedignore-filter.sh"
EXAMPLE="$REPO_ROOT/onboarding/seed-content/.seedignore.example"
DOC="$REPO_ROOT/docs/seed-content-pipeline.md"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/sp13-t2-test-XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
record_pass() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
record_fail() {
  fail=$((fail + 1))
  printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"
}
assert_eq() { if [ "$2" = "$3" ]; then record_pass "$1"; else record_fail "$1" "$2" "$3"; fi; }

# ---------- AC1 — syntax checks ----------
echo "AC1 — syntax checks"
if bash -n "$FILTER" 2>/dev/null; then record_pass "seedignore-filter.sh bash -n clean"
else record_fail "seedignore-filter.sh bash -n clean" "rc=0" "rc=non-zero"; fi
if bash -n "$INTAKE" 2>/dev/null; then record_pass "intake.sh bash -n clean (post-wire)"
else record_fail "intake.sh bash -n clean (post-wire)" "rc=0" "rc=non-zero"; fi

# ---------- AC2 — exclusion of 3 patterns ----------
echo "AC2 — 10 files + .seedignore excluding 3 patterns -> 7 records"
ROOT_A="$TMPROOT/case-a"
mkdir -p "$ROOT_A/secrets" "$ROOT_A/work"
# 10 files total, structured to exercise 3 patterns:
#   2 *.key files (matched by *.key)
#   1 file under secrets/ (matched by secrets/)
#   7 plain .md files (kept)
printf 'k1' > "$ROOT_A/api.key"
printf 'k2' > "$ROOT_A/work/aws.key"
printf 's1' > "$ROOT_A/secrets/dump.txt"
i=1
while [ $i -le 7 ]; do
  printf 'note-%s\n' "$i" > "$ROOT_A/note-$i.md"
  i=$((i + 1))
done
cat > "$ROOT_A/.seedignore" <<'EOF'
# project secrets
*.key
secrets/
.seedignore
EOF

MANIFEST_A="$TMPROOT/case-a-out.jsonl"
bash "$INTAKE" --source "$ROOT_A" --manifest "$MANIFEST_A" 2>/dev/null
count_a=$(wc -l < "$MANIFEST_A" | tr -d ' ')
assert_eq "case-a: 7 records after exclusion" "7" "$count_a"

# Spot-check: no record should reference *.key or secrets/
key_hits=$(jq -r '.path' "$MANIFEST_A" | grep -c '\.key$' || true)
assert_eq "case-a: no .key files in manifest" "0" "$key_hits"
secret_hits=$(jq -r '.path' "$MANIFEST_A" | grep -c '/secrets/' || true)
assert_eq "case-a: no secrets/ files in manifest" "0" "$secret_hits"

# ---------- AC3 — missing .seedignore -> permissive ----------
echo "AC3 — missing .seedignore -> all records pass through"
ROOT_B="$TMPROOT/case-b"
mkdir -p "$ROOT_B"
i=1
while [ $i -le 10 ]; do
  printf 'b-%s' "$i" > "$ROOT_B/file-$i.txt"
  i=$((i + 1))
done
MANIFEST_B="$TMPROOT/case-b-out.jsonl"
bash "$INTAKE" --source "$ROOT_B" --manifest "$MANIFEST_B" 2>/dev/null
count_b=$(wc -l < "$MANIFEST_B" | tr -d ' ')
assert_eq "case-b: 10 records when .seedignore absent" "10" "$count_b"

# ---------- AC4 — empty/comment-only .seedignore -> permissive ----------
echo "AC4 — comments-only .seedignore -> all records pass through"
ROOT_C="$TMPROOT/case-c"
mkdir -p "$ROOT_C"
i=1
while [ $i -le 5 ]; do
  printf 'c-%s' "$i" > "$ROOT_C/file-$i.txt"
  i=$((i + 1))
done
cat > "$ROOT_C/.seedignore" <<'EOF'
# only a comment

# another comment
EOF
MANIFEST_C="$TMPROOT/case-c-out.jsonl"
bash "$INTAKE" --source "$ROOT_C" --manifest "$MANIFEST_C" 2>/dev/null
# .seedignore itself is one of the files -> 6 records
count_c=$(wc -l < "$MANIFEST_C" | tr -d ' ')
assert_eq "case-c: 6 records (5 + .seedignore) when patterns empty" "6" "$count_c"

# ---------- AC5 — .seedignore.example exists ----------
echo "AC5 — .seedignore.example template ships"
if [ -f "$EXAMPLE" ]; then record_pass "example template exists"
else record_fail "example template exists" "file" "missing"; fi
if grep -q '\*\.key' "$EXAMPLE" 2>/dev/null && \
   grep -q '\.git/' "$EXAMPLE" 2>/dev/null && \
   grep -q '\.env' "$EXAMPLE" 2>/dev/null; then
  record_pass "example covers credentials + VCS + env"
else
  record_fail "example covers credentials + VCS + env" "all 3 markers" "missing"
fi

# ---------- AC6 — docs/seed-content-pipeline.md exists ----------
echo "AC6 — pipeline doc ships"
if [ -f "$DOC" ]; then record_pass "docs/seed-content-pipeline.md exists"
else record_fail "docs/seed-content-pipeline.md exists" "file" "missing"; fi

# ---------- AC7 — directory-pattern semantics ----------
echo "AC7 — directory pattern excludes nested files"
ROOT_D="$TMPROOT/case-d"
mkdir -p "$ROOT_D/node_modules/pkg-a" "$ROOT_D/src"
printf 'mod' > "$ROOT_D/node_modules/pkg-a/index.js"
printf 'src' > "$ROOT_D/src/main.go"
printf 'top' > "$ROOT_D/README.md"
cat > "$ROOT_D/.seedignore" <<'EOF'
node_modules/
.seedignore
EOF
MANIFEST_D="$TMPROOT/case-d-out.jsonl"
bash "$INTAKE" --source "$ROOT_D" --manifest "$MANIFEST_D" 2>/dev/null
count_d=$(wc -l < "$MANIFEST_D" | tr -d ' ')
assert_eq "case-d: 2 records (README + main.go)" "2" "$count_d"
mod_hits=$(jq -r '.path' "$MANIFEST_D" | grep -c '/node_modules/' || true)
assert_eq "case-d: no node_modules/ files in manifest" "0" "$mod_hits"

# ---------- summary ----------
echo
total=$((pass + fail))
echo "=========================================="
echo "Total: $total — pass=$pass fail=$fail"
if [ "$fail" -gt 0 ]; then exit 1; else exit 0; fi
