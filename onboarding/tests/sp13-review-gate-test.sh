#!/usr/bin/env bash
# sp13-review-gate-test.sh — SP13 T-7 unit tests
#
# Covers Stage 2 review-gate acceptance criteria (spec L234-241):
#   AC1  SP12 T-1 done-marker absent → review-gate.sh exits 2 with message
#   AC2  review-gate.sh exists; bash -n clean
#   AC3  apply path: writes approved plan; rc=0
#        skip path:  target NOT written; rc=0
#        abort path: target NOT written; rc=1
#   AC4  edit path: editor invoked; user-saved content is what apply writes
#   AC5  audit log appended (≥1 record per gate invocation)
#   AC6  "what happens next" line present at preview surface (UX-quality)
#   AC7  done-marker state/T-7.done written (gated by orchestrator; this
#        suite asserts the producer side: review-gate.sh emits a clean
#        rc + writes the approved plan when 'apply' is chosen)
#
# Plus pre-flight sub-probes:
#   AC0a missing input plan → exit 2
#   AC0b malformed input plan (wrong schema_version) → exit 2
#   AC0c missing gate library → exit 2
#   AC8  schema_version round-trips through edit (post-edit validation
#        re-prompts when the user nukes the schema_version anchor)
#
# Hermetic: $TMPDIR/sp13-t7-test-XXXXXX. No live writes outside tmpdir.
# AUTO_AUTHOR_LOG forced into the tmpdir to keep the foundation-repo's
# real auto-author-log.jsonl untouched. Bash 3.2 compatible (R-23).
#
# Author: Claude Opus 4.7 — Plan 71 SP13 Session 5

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SKILL_DIR="$REPO_ROOT/skills/infer-vault-structure"
REVIEW_SH="$SKILL_DIR/review-gate.sh"
PROPOSE_SH="$SKILL_DIR/propose-taxonomy.sh"
IMPORT_SH="$SKILL_DIR/import-plan.sh"
GATE_LIB="$REPO_ROOT/onboarding/lib/three-step-gate.sh"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/sp13-t7-test-XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

# Force stub LLM mode for the upstream T-5 invocation; isolate audit log.
unset ANTHROPIC_API_KEY
unset VOYAGE_API_KEY
export AUTO_AUTHOR_LOG="$TMPROOT/audit.jsonl"
export TG_STAGE_DIR="$TMPROOT/stage"
mkdir -p "$TG_STAGE_DIR"

pass=0
fail=0
record_pass() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
record_fail() {
  fail=$((fail + 1))
  printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"
}
assert_eq() { if [ "$2" = "$3" ]; then record_pass "$1"; else record_fail "$1" "$2" "$3"; fi; }
assert_grep_file() {
  if grep -qE "$2" "$3" 2>/dev/null; then record_pass "$1"
  else record_fail "$1" "match: $2" "no match in $3"; fi
}
assert_no_file() {
  if [ ! -e "$2" ]; then record_pass "$1"
  else record_fail "$1" "no file at $2" "file present"; fi
}
assert_file_exists() {
  if [ -f "$2" ]; then record_pass "$1"
  else record_fail "$1" "file at $2" "missing"; fi
}

# ---------- AC2 — review-gate.sh exists + bash -n clean ----------
echo "AC2 — review-gate.sh exists + bash -n clean"
if [ -f "$REVIEW_SH" ] && bash -n "$REVIEW_SH" 2>/dev/null; then
  record_pass "review-gate.sh exists + bash -n clean"
else
  record_fail "review-gate.sh" "exists+clean" "missing-or-syntax-error"
  printf "Summary: %s passed / %s failed\n" "$pass" "$fail"
  exit 1
fi

# ---------- Build a synthetic post-T-6 import-plan.md fixture ----------
echo "fixture build — running upstream T-5 stub → T-6 to produce import-plan.md"
FIX="$TMPROOT/fix"
mkdir -p "$FIX"
CLUSTER_JSON="$FIX/cluster-output.json"
IR_JSONL="$FIX/ir.jsonl"
PROPOSE_JSON="$FIX/propose-taxonomy-output.json"
IMPORT_MD="$FIX/import-plan.md"

python3 - "$CLUSTER_JSON" "$IR_JSONL" <<'PY'
import json, sys, hashlib

cluster_path, ir_path = sys.argv[1:3]

# Compact 12-item fixture: 2 project clusters + 1 reference + 1 unclassified
project_specs = [
    ("c0001", "alpha", ["alpha", "engagement", "scope"], 4, False),
    ("c0002", "beta", ["beta", "engagement", "milestone"], 4, False),
]
ref_spec = ("c0003", "policy", ["policy", "compliance", "guide"], 3, False)
n_unclassified = 12 - sum(s[3] for s in project_specs) - ref_spec[3]
assert n_unclassified == 1

clusters = []
ir_lines = []

def mk_member(prefix, idx):
    sh = hashlib.sha256(("%s-%d" % (prefix, idx)).encode("utf-8")).hexdigest()[:16]
    path = "/tmp/sp13-fixture-t7/%s-%d.md" % (prefix, idx)
    return {"path": path, "source_hash": sh}

def add_cluster(spec):
    cid, _label, kws, n, low = spec
    members = []
    for i in range(n):
        m = mk_member(cid, i)
        members.append(m)
        body = " ".join(kws) + " content excerpt for %s item %d" % (cid, i)
        ir_lines.append(json.dumps({
            "path": m["path"], "format": "markdown",
            "detected_at": "2026-05-04T18:00:00Z",
            "raw_bytes": len(body.encode("utf-8")),
            "normalized_text": body, "metadata": {},
            "source_hash": m["source_hash"],
        }))
    clusters.append({
        "cluster_id": cid, "members": members,
        "confidence": 0.45 if low else 0.85,
        "centroid_topic_keywords": kws, "low_confidence": low,
    })

for spec in project_specs:
    add_cluster(spec)
add_cluster(ref_spec)

unc_members = []
for i in range(n_unclassified):
    m = mk_member("unc", i)
    unc_members.append(m)
    body = "heterogeneous singleton item %d" % i
    ir_lines.append(json.dumps({
        "path": m["path"], "format": "markdown",
        "detected_at": "2026-05-04T18:00:00Z",
        "raw_bytes": len(body.encode("utf-8")),
        "normalized_text": body, "metadata": {},
        "source_hash": m["source_hash"],
    }))
clusters.append({
    "cluster_id": "unclassified", "members": unc_members,
    "confidence": 0.0, "centroid_topic_keywords": ["heterogeneous"],
    "low_confidence": True,
})

n_records = sum(len(c["members"]) for c in clusters)
n_clusters = sum(1 for c in clusters if c["cluster_id"] != "unclassified")

with open(cluster_path, "w", encoding="utf-8") as fh:
    json.dump({
        "schema_version": "cluster-output/1", "embedding_mode": "stub",
        "n_records": n_records, "n_clusters": n_clusters,
        "min_cluster_size": 3, "small_corpus": False,
        "small_corpus_message": None, "clusters": clusters,
    }, fh, indent=2, sort_keys=True)
with open(ir_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(ir_lines) + "\n")
PY

"$PROPOSE_SH" --cluster-output "$CLUSTER_JSON" --ir "$IR_JSONL" \
  --out "$PROPOSE_JSON" --llm-mode stub >/dev/null 2>"$TMPROOT/propose.stderr"
rc=$?
if [ "$rc" -ne 0 ]; then
  record_fail "fixture build: propose-taxonomy.sh" "rc=0" "rc=$rc"
  sed 's/^/  /' "$TMPROOT/propose.stderr"
  printf "Summary: %s passed / %s failed\n" "$pass" "$fail"
  exit 1
fi

"$IMPORT_SH" --propose-taxonomy "$PROPOSE_JSON" --out "$IMPORT_MD" \
  --generated-at "2026-05-04T18:30:00Z" >/dev/null 2>"$TMPROOT/import.stderr"
rc=$?
if [ "$rc" -ne 0 ]; then
  record_fail "fixture build: import-plan.sh" "rc=0" "rc=$rc"
  sed 's/^/  /' "$TMPROOT/import.stderr"
  printf "Summary: %s passed / %s failed\n" "$pass" "$fail"
  exit 1
fi
record_pass "fixture build: upstream T-5 + T-6 produced import-plan.md"
[ -s "$IMPORT_MD" ] && record_pass "fixture build: import-plan.md non-empty" \
  || record_fail "import-plan.md" "non-empty" "missing-or-empty"

# Provision a fake plan-tree with SP12 T-1 done-marker present (most tests).
PLAN_TREE_OK="$TMPROOT/plan-tree-ok"
mkdir -p "$PLAN_TREE_OK/12-auto-authored-personalization/state"
printf 'T-1\t2026-05-03T14:55:05Z\tfixture\n' \
  > "$PLAN_TREE_OK/12-auto-authored-personalization/state/T-1.done"

# ---------- AC1 — SP12 T-1 absent triggers HARD ABORT ----------
echo "AC1 — SP12 T-1 done-marker absent → exit 2 (clean halt)"
PLAN_TREE_BAD="$TMPROOT/plan-tree-bad"
mkdir -p "$PLAN_TREE_BAD/12-auto-authored-personalization/state"
# directory exists but T-1.done is absent → HARD ABORT
APPROVED="$TMPROOT/approved-no-sp12.md"
"$REVIEW_SH" --import-plan "$IMPORT_MD" \
  --approved-out "$APPROVED" \
  --gate-lib "$GATE_LIB" \
  --plan-tree "$PLAN_TREE_BAD" \
  --accept-on-eof \
  >/dev/null 2>"$TMPROOT/abort-sp12.stderr"
rc=$?
assert_eq "AC1: rc=2 when SP12 T-1 absent" "2" "$rc"
assert_grep_file "AC1: stderr says 'SP12 T-1 done-marker not found'" \
  "SP12 T-1 done-marker not found" "$TMPROOT/abort-sp12.stderr"
assert_no_file "AC1: approved plan NOT written" "$APPROVED"

# ---------- AC0a — missing input plan → exit 2 ----------
echo "AC0a — missing input plan → exit 2"
APPROVED="$TMPROOT/approved-no-input.md"
"$REVIEW_SH" --import-plan "$TMPROOT/does-not-exist.md" \
  --approved-out "$APPROVED" \
  --gate-lib "$GATE_LIB" \
  --plan-tree "$PLAN_TREE_OK" \
  --accept-on-eof \
  >/dev/null 2>"$TMPROOT/abort-input.stderr"
rc=$?
assert_eq "AC0a: rc=2 when input plan missing" "2" "$rc"
assert_grep_file "AC0a: stderr says 'input plan not found'" \
  "input plan not found" "$TMPROOT/abort-input.stderr"

# ---------- AC0b — malformed input plan (wrong schema_version) → exit 2 ----------
echo "AC0b — input plan schema_version mismatch → exit 2"
BAD_PLAN="$TMPROOT/bad-plan.md"
cat > "$BAD_PLAN" <<EOF
---
schema_version: sp99-bogus/0
---
# Not a real T-6 plan
EOF
APPROVED="$TMPROOT/approved-bad-input.md"
"$REVIEW_SH" --import-plan "$BAD_PLAN" \
  --approved-out "$APPROVED" \
  --gate-lib "$GATE_LIB" \
  --plan-tree "$PLAN_TREE_OK" \
  --accept-on-eof \
  >/dev/null 2>"$TMPROOT/abort-schema.stderr"
rc=$?
assert_eq "AC0b: rc=2 on schema_version mismatch" "2" "$rc"
assert_grep_file "AC0b: stderr says 'schema_version mismatch'" \
  "schema_version mismatch" "$TMPROOT/abort-schema.stderr"

# ---------- AC0c — missing gate library → exit 2 ----------
echo "AC0c — missing gate library → exit 2"
APPROVED="$TMPROOT/approved-no-gate.md"
"$REVIEW_SH" --import-plan "$IMPORT_MD" \
  --approved-out "$APPROVED" \
  --gate-lib "$TMPROOT/no-such-gate-lib.sh" \
  --plan-tree "$PLAN_TREE_OK" \
  --accept-on-eof \
  >/dev/null 2>"$TMPROOT/abort-gate.stderr"
rc=$?
assert_eq "AC0c: rc=2 when gate library missing" "2" "$rc"
assert_grep_file "AC0c: stderr says 'gate library not found'" \
  "gate library not found" "$TMPROOT/abort-gate.stderr"

# ---------- AC3a — apply path: writes approved plan; rc=0 ----------
echo "AC3a — apply: writes approved plan; rc=0"
APPROVED="$TMPROOT/approved-apply.md"
> "$AUTO_AUTHOR_LOG"  # truncate audit log so AC5 records are scoped to this run
REVIEW_GATE_PROMPT_CHOICE=a "$REVIEW_SH" \
  --import-plan "$IMPORT_MD" \
  --approved-out "$APPROVED" \
  --gate-lib "$GATE_LIB" \
  --plan-tree "$PLAN_TREE_OK" \
  --accept-on-eof \
  >"$TMPROOT/apply.stdout" 2>"$TMPROOT/apply.stderr"
rc=$?
assert_eq "AC3a: rc=0 on apply" "0" "$rc"
assert_file_exists "AC3a: approved plan written" "$APPROVED"
# Approved content should match input plan byte-for-byte (no edits made)
if cmp -s "$IMPORT_MD" "$APPROVED"; then
  record_pass "AC3a: approved plan content matches input (no edits)"
else
  record_fail "AC3a: approved content matches input" "byte-equal" "differ"
fi

# ---------- AC6 — "what happens next" line present at preview surface ----------
echo "AC6 — 'what happens next' UX line present at preview"
assert_grep_file "AC6: stderr contains 'what happens next' header" \
  "=== what happens next ===" "$TMPROOT/apply.stderr"
assert_grep_file "AC6: stderr explains apply consequence" \
  "approved plan to" "$TMPROOT/apply.stderr"
assert_grep_file "AC6: stderr explains skip semantics" \
  "exit Stage 2 cleanly" "$TMPROOT/apply.stderr"
assert_grep_file "AC6: stderr explains abort semantics" \
  "non-zero rc" "$TMPROOT/apply.stderr"
assert_grep_file "AC6: stderr explains edit semantics" \
  "open .*EDITOR.*on the staged plan" "$TMPROOT/apply.stderr"
# Carry-forward from T-5 design: split-flagged candidate copy
assert_grep_file "AC6: stderr surfaces split-flag copy carry-forward" \
  "split-flagged" "$TMPROOT/apply.stderr"

# ---------- AC5 — audit log entries (generate + preview + apply) ----------
echo "AC5 — audit log appended (≥1 record per gate invocation)"
records=$(wc -l < "$AUTO_AUTHOR_LOG" | tr -d ' ')
# Expect at least: generate (1) + preview (1) + apply (1) = 3
if [ "$records" -ge 3 ] 2>/dev/null; then
  record_pass "AC5: audit log has $records records (>=3)"
else
  record_fail "AC5: audit log records" ">=3" "$records"
fi
# Each surface_id should be "seed-import-plan"
sid_count=$(grep -c '"surface_id":"seed-import-plan"' "$AUTO_AUTHOR_LOG" 2>/dev/null || true)
[ "${sid_count:-0}" -ge 3 ] 2>/dev/null \
  && record_pass "AC5: surface_id=seed-import-plan on >=3 records ($sid_count)" \
  || record_fail "AC5: surface_id count" ">=3" "${sid_count:-0}"
# Generate, preview, apply actions all present
for action in generate preview apply; do
  if grep -q "\"action\":\"$action\"" "$AUTO_AUTHOR_LOG"; then
    record_pass "AC5: audit has action=$action"
  else
    record_fail "AC5: audit action=$action" "present" "missing"
  fi
done

# ---------- AC3b — skip path: target NOT written; rc=0 ----------
echo "AC3b — skip: target NOT written; rc=0"
APPROVED="$TMPROOT/approved-skip.md"
> "$AUTO_AUTHOR_LOG"
REVIEW_GATE_PROMPT_CHOICE=s "$REVIEW_SH" \
  --import-plan "$IMPORT_MD" \
  --approved-out "$APPROVED" \
  --gate-lib "$GATE_LIB" \
  --plan-tree "$PLAN_TREE_OK" \
  --accept-on-eof \
  >/dev/null 2>"$TMPROOT/skip.stderr"
rc=$?
assert_eq "AC3b: rc=0 on skip" "0" "$rc"
assert_no_file "AC3b: approved plan NOT written on skip" "$APPROVED"
if grep -q '"action":"skip"' "$AUTO_AUTHOR_LOG"; then
  record_pass "AC3b: audit has action=skip"
else
  record_fail "AC3b: audit action=skip" "present" "missing"
fi

# ---------- AC3c — abort path: target NOT written; rc=1 ----------
echo "AC3c — abort: target NOT written; rc=1"
APPROVED="$TMPROOT/approved-abort.md"
> "$AUTO_AUTHOR_LOG"
REVIEW_GATE_PROMPT_CHOICE=b "$REVIEW_SH" \
  --import-plan "$IMPORT_MD" \
  --approved-out "$APPROVED" \
  --gate-lib "$GATE_LIB" \
  --plan-tree "$PLAN_TREE_OK" \
  --accept-on-eof \
  >/dev/null 2>"$TMPROOT/abort-user.stderr"
rc=$?
assert_eq "AC3c: rc=1 on abort" "1" "$rc"
assert_no_file "AC3c: approved plan NOT written on abort" "$APPROVED"
if grep -q '"action":"abort"' "$AUTO_AUTHOR_LOG"; then
  record_pass "AC3c: audit has action=abort"
else
  record_fail "AC3c: audit action=abort" "present" "missing"
fi

# ---------- AC4 — edit path: editor invoked; user-saved content is what apply writes ----------
echo "AC4 — edit: editor invoked; user-saved content is what apply writes"
# Build a fake editor that adds a user-edit marker line before the closing
# frontmatter delimiter. Deterministic mutation; preserves schema_version.
FAKE_EDITOR="$TMPROOT/fake-editor.sh"
cat > "$FAKE_EDITOR" <<'EDITOR'
#!/usr/bin/env bash
# Fake editor for SP13 T-7 hermetic test. Inserts a marker line into the
# YAML frontmatter (before the closing '---') and exits 0. Preserves
# schema_version anchor so post-edit validation passes.
set -u
target="$1"
tmp="${target}.fake-edit.tmp"
awk '
  BEGIN { fm_seen = 0; inserted = 0 }
  /^---$/ {
    if (fm_seen == 0) { fm_seen = 1; print; next }
    if (fm_seen == 1 && inserted == 0) {
      print "# user-edit-marker: T-7 hermetic test mutation"
      inserted = 1
    }
    print; next
  }
  { print }
' "$target" > "$tmp"
mv "$tmp" "$target"
EDITOR
chmod +x "$FAKE_EDITOR"

# Pre-seed the prompt: user picks 'e' first, fake editor mutates the staged
# file, then the loop re-prompts and ACCEPT_ON_EOF kicks in (default-apply).
APPROVED="$TMPROOT/approved-edit.md"
> "$AUTO_AUTHOR_LOG"
EDITOR="$FAKE_EDITOR" REVIEW_GATE_PROMPT_CHOICE=e "$REVIEW_SH" \
  --import-plan "$IMPORT_MD" \
  --approved-out "$APPROVED" \
  --gate-lib "$GATE_LIB" \
  --plan-tree "$PLAN_TREE_OK" \
  --accept-on-eof \
  </dev/null \
  >/dev/null 2>"$TMPROOT/edit.stderr"
rc=$?
assert_eq "AC4: rc=0 on edit-then-apply (default)" "0" "$rc"
assert_file_exists "AC4: approved plan written after edit" "$APPROVED"
# The user-edit marker the fake editor injected MUST be in the approved plan
assert_grep_file "AC4: approved plan carries user-edit marker" \
  "user-edit-marker: T-7 hermetic test mutation" "$APPROVED"
# Edit-diff UX: stderr should show "your edits" diff block
assert_grep_file "AC4: stderr shows 'your edits' diff block" \
  "=== your edits .vs original generated plan." "$TMPROOT/edit.stderr"
# schema_version anchor must round-trip
assert_grep_file "AC4: approved plan retains import-plan/1 schema_version" \
  "^schema_version: import-plan/1$" "$APPROVED"

# ---------- AC8 — schema_version drift in edit re-prompts (validation gate) ----------
echo "AC8 — post-edit validation: nuked schema_version re-prompts (does NOT silently apply)"
# Build a destructive fake editor that nukes the schema_version line.
DESTRUCTIVE_EDITOR="$TMPROOT/destructive-editor.sh"
cat > "$DESTRUCTIVE_EDITOR" <<'EDITOR'
#!/usr/bin/env bash
set -u
target="$1"
tmp="${target}.destructive-edit.tmp"
sed 's/^schema_version: import-plan\/1$/schema_version: nuked-by-test/' "$target" > "$tmp"
mv "$tmp" "$target"
EDITOR
chmod +x "$DESTRUCTIVE_EDITOR"

APPROVED="$TMPROOT/approved-destructive.md"
> "$AUTO_AUTHOR_LOG"
# Sequence: PROMPT_CHOICE=e fires once → destructive editor nukes
# schema_version → loop re-prompts → reads 'a' from stdin → schema
# validation fires (STAGED PLAN VALIDATION FAILED) → re-prompt → reads
# EOF (no --accept-on-eof) → halts with rc=1, no target write.
EDITOR="$DESTRUCTIVE_EDITOR" REVIEW_GATE_PROMPT_CHOICE=e "$REVIEW_SH" \
  --import-plan "$IMPORT_MD" \
  --approved-out "$APPROVED" \
  --gate-lib "$GATE_LIB" \
  --plan-tree "$PLAN_TREE_OK" \
  >/dev/null 2>"$TMPROOT/destructive.stderr" \
  <<EOF
a
EOF
rc=$?
assert_eq "AC8: rc=1 (EOF halt) when post-edit validation fails" "1" "$rc"
assert_no_file "AC8: approved plan NOT written when schema_version nuked" "$APPROVED"
assert_grep_file "AC8: stderr surfaces 'STAGED PLAN VALIDATION FAILED'" \
  "STAGED PLAN VALIDATION FAILED" "$TMPROOT/destructive.stderr"

# ---------- AC9 — production-mode skip: PLAN_TREE absent → SP12 check skipped ----------
echo "AC9 — production-mode (no plan tree): SP12 check is no-op"
APPROVED="$TMPROOT/approved-prod.md"
> "$AUTO_AUTHOR_LOG"
REVIEW_GATE_PROMPT_CHOICE=s "$REVIEW_SH" \
  --import-plan "$IMPORT_MD" \
  --approved-out "$APPROVED" \
  --gate-lib "$GATE_LIB" \
  --plan-tree "$TMPROOT/no-plan-tree-here" \
  --accept-on-eof \
  >/dev/null 2>"$TMPROOT/prod.stderr"
rc=$?
assert_eq "AC9: rc=0 in production-mode (no plan tree, skip)" "0" "$rc"
# stderr should NOT contain the SP12 hard-abort message
if ! grep -q "SP12 T-1 done-marker not found" "$TMPROOT/prod.stderr"; then
  record_pass "AC9: SP12 check skipped when plan tree dir absent"
else
  record_fail "AC9: SP12 check skip" "no message" "message present"
fi

# ---------- AC10 — hermetic isolation: no writes outside tmpdir ----------
echo "AC10 — hermetic isolation"
# Default approved-out should NOT exist on the foundation-repo
default_approved="$REPO_ROOT/onboarding/seed-content/state/approved-import-plan.md"
if [ ! -f "$default_approved" ]; then
  record_pass "AC10: default approved-out not created on foundation-repo (test wrote to tmp)"
else
  record_fail "AC10: foundation-repo state/" "untouched" "default approved-out exists"
fi
# Audit log should be inside tmpdir
case "$AUTO_AUTHOR_LOG" in
  "$TMPROOT/"*) record_pass "AC10: audit log inside tmpdir" ;;
  *) record_fail "AC10: audit log path" "in $TMPROOT" "$AUTO_AUTHOR_LOG" ;;
esac

echo
printf "Summary: %s passed / %s failed\n" "$pass" "$fail"
if [ "$fail" -ne 0 ]; then exit 1; fi
exit 0
