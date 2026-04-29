#!/bin/bash
# Synthetic tests for Plan 67 SP02 T-5: parent_plan slug cascade.
#
# Scenarios:
#   1. Plan-dir rename (67-old/ -> 67-new/): every child parent_plan: old
#      flips to parent_plan: new.
#   2. Non-plan-dir rename (e.g. vault Archive/): parent_plan: fields in
#      scanned files are NOT touched (scope-guard).

set -u

CAP="$(cd "$(dirname "$0")/.." && pwd)/rename-cascade.sh"
[[ -x "$CAP" ]] || { echo "FAIL: $CAP not executable" >&2; exit 1; }

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

TMP=$(mktemp -d -t parent-plan-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# ---- Test 1: plan-dir rename cascades parent_plan -------------------------
echo "== Test 1: plan-dir rename -> parent_plan slug flip =="
PLANS1="$TMP/plans"
mkdir -p "$PLANS1/67-new-slug/01-subplan"
cat > "$PLANS1/67-new-slug/spec.md" <<EOF
---
title: Root spec
type: spec
parent_plan: old-slug
---
# Plan
EOF
cat > "$PLANS1/67-new-slug/01-subplan/spec.md" <<EOF
---
title: SP01
type: spec
parent_plan: old-slug
---
# SP01
EOF
cat > "$PLANS1/67-new-slug/01-subplan/tasks.md" <<EOF
---
title: SP01 tasks
type: tasks
parent_plan: old-slug
---
EOF

# Feed a directory-level rename NDJSON. rename-detect emits one edge per
# file, so simulate that: top spec, subplan spec, subplan tasks.
ND=$(mktemp -t nd.XXXXXX)
cat > "$ND" <<EOF
{"root":"$PLANS1","old_path":"67-old-slug/spec.md","new_path":"67-new-slug/spec.md","commit_sha":"cafe","committed_at":"2026-04-22T00:00:00Z","similarity":100}
{"root":"$PLANS1","old_path":"67-old-slug/01-subplan/spec.md","new_path":"67-new-slug/01-subplan/spec.md","commit_sha":"cafe","committed_at":"2026-04-22T00:00:00Z","similarity":100}
{"root":"$PLANS1","old_path":"67-old-slug/01-subplan/tasks.md","new_path":"67-new-slug/01-subplan/tasks.md","commit_sha":"cafe","committed_at":"2026-04-22T00:00:00Z","similarity":100}
EOF

OUT=$(PLANS_DIR="$PLANS1" RENAME_CASCADE_SCOPES="$PLANS1" "$CAP" --apply --include-frontmatter < "$ND" 2>&1)

for f in "$PLANS1/67-new-slug/spec.md" "$PLANS1/67-new-slug/01-subplan/spec.md" "$PLANS1/67-new-slug/01-subplan/tasks.md"; do
  if grep -q "parent_plan: new-slug" "$f" 2>/dev/null; then
    pass "$(basename "$(dirname "$f")")/$(basename "$f") flipped"
  else
    fail "not flipped: $f"
    cat "$f"
  fi
done

# ---- Test 2: non-plan-dir rename must NOT touch parent_plan --------------
echo "== Test 2: non-plan-dir scope-guard =="
VAULT2="$TMP/vault"
PLANS2="$TMP/plans2"
mkdir -p "$VAULT2/Logs" "$PLANS2"
cat > "$VAULT2/Logs/child.md" <<EOF
---
title: Child
type: log
parent_plan: some-plan
---
Body.
EOF

ND2=$(mktemp -t nd2.XXXXXX)
cat > "$ND2" <<EOF
{"root":"$VAULT2","old_path":"Logs/old.md","new_path":"Archive/Logs/old.md","commit_sha":"face","committed_at":"2026-04-22T00:00:00Z","similarity":100}
EOF

PLANS_DIR="$PLANS2" RENAME_CASCADE_SCOPES="$VAULT2" "$CAP" --apply --include-frontmatter < "$ND2" >/dev/null 2>&1

if grep -q "parent_plan: some-plan" "$VAULT2/Logs/child.md"; then
  pass "parent_plan unchanged (scope-guarded)"
else
  fail "parent_plan was incorrectly mutated"
  cat "$VAULT2/Logs/child.md"
fi

echo ""
echo "== Summary =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
