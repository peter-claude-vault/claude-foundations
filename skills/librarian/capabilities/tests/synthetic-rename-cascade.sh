#!/bin/bash
# Synthetic tests for capabilities/rename-cascade.sh.
#
# Isolated tmp-scope harness per scenario. Feeds NDJSON via pipe.
#
# Scenarios (T-2 spec):
#   1. Simple wikilink update
#   2. Aliased wikilink update       [[Old|Display]] -> [[New|Display]]
#   3. Frontmatter spec_path: update
#   4. Heading-anchor preservation   [[Old#heading]] -> [[New#heading]]
#   5. No-match no-op                rename with no inbound refs
#   6. Multi-source-file cascade     3 sources reference 1 renamed target

set -u

CAP="$(cd "$(dirname "$0")/.." && pwd)/rename-cascade.sh"
if [[ ! -x "$CAP" ]]; then
  echo "FAIL: $CAP not executable" >&2
  exit 1
fi

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

TMP=$(mktemp -d -t rename-cascade-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Each scenario builds its own vault root + stdin payload.
ndjson_rec() {
  # args: root old_path new_path
  printf '{"root":"%s","old_path":"%s","new_path":"%s","commit_sha":"abc","committed_at":"2026-04-22T00:00:00Z","similarity":100}\n' "$1" "$2" "$3"
}

# ---- Test 1: simple wikilink update ---------------------------------------

echo "== Test 1: simple wikilink update =="
T1="$TMP/t1"; mkdir -p "$T1"
cat > "$T1/source.md" <<EOF
# Source

References [[OldTarget]] once.
EOF
touch "$T1/NewTarget.md"

NDJSON=$(ndjson_rec "$T1" "OldTarget.md" "NewTarget.md")
OUT=$(echo "$NDJSON" | RENAME_CASCADE_SCOPES="$T1" "$CAP" --apply 2>&1)
if grep -q "\[\[NewTarget\]\]" "$T1/source.md"; then pass "wikilink rewritten"; else fail "expected [[NewTarget]]"; cat "$T1/source.md"; fi
if ! grep -q "\[\[OldTarget\]\]" "$T1/source.md"; then pass "old wikilink gone"; else fail "old link persists"; fi
echo "$OUT" | grep -q "rename-cascade-wikilink" && pass "finding emitted" || fail "no finding in: $OUT"

# ---- Test 2: aliased wikilink update --------------------------------------

echo "== Test 2: aliased wikilink update =="
T2="$TMP/t2"; mkdir -p "$T2"
cat > "$T2/src.md" <<EOF
See [[OldTarget|Display Label]] for details.
EOF
NDJSON=$(ndjson_rec "$T2" "OldTarget.md" "NewTarget.md")
echo "$NDJSON" | RENAME_CASCADE_SCOPES="$T2" "$CAP" --apply >/dev/null 2>&1
grep -q "\[\[NewTarget|Display Label\]\]" "$T2/src.md" && pass "alias preserved" || { fail "alias not preserved"; cat "$T2/src.md"; }

# ---- Test 3: frontmatter spec_path: update --------------------------------

echo "== Test 3: frontmatter spec_path update =="
T3="$TMP/t3"; mkdir -p "$T3"
cat > "$T3/meta.md" <<EOF
---
title: Meta
type: log
spec_path: foo/bar/old-spec.md
---

Body.
EOF
NDJSON=$(ndjson_rec "$T3" "foo/bar/old-spec.md" "foo/bar/new-spec.md")
OUT=$(echo "$NDJSON" | RENAME_CASCADE_SCOPES="$T3" "$CAP" --apply --include-frontmatter 2>&1)
grep -q "spec_path: foo/bar/new-spec.md" "$T3/meta.md" && pass "spec_path rewritten" || { fail "spec_path not updated"; cat "$T3/meta.md"; }
echo "$OUT" | grep -q "rename-cascade-frontmatter" && pass "frontmatter finding emitted" || fail "no fm finding"

# ---- Test 4: heading-anchor preservation ----------------------------------

echo "== Test 4: heading anchor preserved =="
T4="$TMP/t4"; mkdir -p "$T4"
cat > "$T4/src.md" <<EOF
Jump to [[OldDoc#Section-A]] and also [[OldDoc#Section-B|section B]].
EOF
NDJSON=$(ndjson_rec "$T4" "OldDoc.md" "NewDoc.md")
echo "$NDJSON" | RENAME_CASCADE_SCOPES="$T4" "$CAP" --apply >/dev/null 2>&1
grep -q "\[\[NewDoc#Section-A\]\]" "$T4/src.md" && pass "anchor A preserved" || { fail "anchor A broken"; cat "$T4/src.md"; }
grep -q "\[\[NewDoc#Section-B|section B\]\]" "$T4/src.md" && pass "anchor+alias B preserved" || fail "anchor+alias B broken"

# ---- Test 5: no-match no-op -----------------------------------------------

echo "== Test 5: no-match no-op =="
T5="$TMP/t5"; mkdir -p "$T5"
cat > "$T5/src.md" <<EOF
Just some text, no wikilinks at all.
Another line.
EOF
BEFORE=$(md5 -q "$T5/src.md")
NDJSON=$(ndjson_rec "$T5" "OldTarget.md" "NewTarget.md")
OUT=$(echo "$NDJSON" | RENAME_CASCADE_SCOPES="$T5" "$CAP" --apply 2>&1)
AFTER=$(md5 -q "$T5/src.md")
[[ "$BEFORE" == "$AFTER" ]] && pass "file unchanged" || fail "file mutated unexpectedly"
echo "$OUT" | grep -q "rename-cascade-noop" && pass "noop finding emitted" || fail "no noop finding in: $OUT"

# ---- Test 6: multi-source cascade -----------------------------------------

echo "== Test 6: 3 sources all reference renamed target =="
T6="$TMP/t6"; mkdir -p "$T6"
for i in 1 2 3; do
  cat > "$T6/src$i.md" <<EOF
Reference $i: [[OldTarget]] and [[OldTarget|alias $i]].
EOF
done
NDJSON=$(ndjson_rec "$T6" "OldTarget.md" "NewTarget.md")
OUT=$(echo "$NDJSON" | RENAME_CASCADE_SCOPES="$T6" "$CAP" --apply 2>&1)
FOUND=0
for i in 1 2 3; do
  grep -q "\[\[NewTarget\]\]" "$T6/src$i.md" && grep -q "\[\[NewTarget|alias $i\]\]" "$T6/src$i.md" && FOUND=$((FOUND + 1))
done
if [[ "$FOUND" -eq 3 ]]; then pass "all 3 sources updated"; else fail "$FOUND/3 sources updated"; fi
# Summary finding reports >=6 proposals (2 per file).
if echo "$OUT" | grep -q '"proposals":'; then pass "summary finding emitted"; else fail "no summary"; fi

# ---- summary --------------------------------------------------------------
echo ""
echo "== Summary =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
