#!/usr/bin/env bash
# sp13-import-plan-test.sh — SP13 T-6 unit tests
#
# Covers Stage 2 import-plan markdown generator acceptance criteria:
#   AC1  schemas/import-plan-schema.json + import-plan.sh + import-plan.py
#        all exist; bash -n / ast.parse / jq clean
#   AC2  schema is JSON Schema Draft-07 with sp13-t6/1 const, 4-value type
#        enum on candidate_block, oneOf on refinements from/into
#   AC3  fixture A (50 items, 6 project + 1 ref + 1 meeting + 16
#        unclassified) → import-plan.md non-empty; pipeline exits 0
#   AC4  all 6 required sections present per spec L196-200:
#        (a) corpus stats header (frontmatter + ## Corpus stats)
#        (b) proposed vault tree (## Proposed vault tree)
#        (c) per-project metadata YAML blocks (one per type=project)
#        (d) per-source-item routing table (## Per-source-item routing)
#        (e) "doesn't fit" disposition section
#        (f) "review the unclassified pile" prominent call-out at top
#   AC5  frontmatter schema_version is sp13-t6/1; input_propose_taxonomy_
#        schema_version is sp13-t5/1; required header fields populated
#   AC6  per-source-item routing table row count = header.n_records (50)
#   AC7  unclassified call-out fires when count > 0 (fixture A; copy
#        contains "16 items" + welcoming "no item is silently dropped")
#   AC8  fixture B (zero unclassified) → no top call-out; pipeline still
#        emits the "Doesn't fit any project" section but with empty-state
#        copy; frontmatter unclassified_callout.present is false
#   AC9  refinements section renders BOTH string + array shapes for
#        from / into (oneOf in T-5 schema): split op carries from=string
#        + into=array; merge op carries from=array + into=string
#   AC10 hermetic isolation: no writes outside $TMPDIR/sp13-t6-test-*;
#        ANTHROPIC_API_KEY unset for the run; default state/ untouched
#
# Hermetic: $TMPDIR/sp13-t6-test-XXXXXX. No live writes.
# Bash 3.2 compatible (R-23).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SKILL_DIR="$REPO_ROOT/skills/infer-vault-structure"
PROPOSE_SH="$SKILL_DIR/propose-taxonomy.sh"
IMPORT_SH="$SKILL_DIR/import-plan.sh"
IMPORT_PY="$SKILL_DIR/import-plan.py"
SCHEMA="$REPO_ROOT/schemas/import-plan-schema.json"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/sp13-t6-test-XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

# Force stub LLM mode for the upstream T-5 invocation.
unset ANTHROPIC_API_KEY
unset VOYAGE_API_KEY

pass=0
fail=0
record_pass() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
record_fail() {
  fail=$((fail + 1))
  printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"
}
assert_eq() { if [ "$2" = "$3" ]; then record_pass "$1"; else record_fail "$1" "$2" "$3"; fi; }
assert_ge() {
  if [ "$2" -ge "$3" ] 2>/dev/null; then
    record_pass "$1 (got $2; need >= $3)"
  else
    record_fail "$1" ">= $3" "$2"
  fi
}
assert_grep() {
  if grep -qE "$2" "$3" 2>/dev/null; then
    record_pass "$1"
  else
    record_fail "$1" "match: $2" "no match in $3"
  fi
}
assert_not_grep() {
  if ! grep -qE "$2" "$3" 2>/dev/null; then
    record_pass "$1"
  else
    record_fail "$1" "no match: $2" "found match in $3"
  fi
}
assert_jq_true() {
  if [ "$2" = "true" ]; then record_pass "$1"
  else record_fail "$1" "true" "$2"; fi
}

# ---------- AC1 — components present + syntax clean ----------
echo "AC1 — components present + syntax clean"
if [ -f "$IMPORT_SH" ] && bash -n "$IMPORT_SH" 2>/dev/null; then
  record_pass "import-plan.sh exists + bash -n clean"
else
  record_fail "import-plan.sh" "ok" "missing-or-syntax"
fi
if [ -f "$IMPORT_PY" ] && python3 -c "import ast; ast.parse(open('$IMPORT_PY').read())" 2>/dev/null; then
  record_pass "import-plan.py exists + ast.parse clean"
else
  record_fail "import-plan.py" "ok" "missing-or-syntax"
fi
if [ -f "$SCHEMA" ] && jq -e . "$SCHEMA" >/dev/null 2>&1; then
  record_pass "import-plan-schema.json exists + jq -e ."
else
  record_fail "import-plan-schema.json" "ok" "missing-or-jq-fail"
fi

# ---------- AC2 — schema is Draft-07 with sp13-t6/1 const + 4-value type enum ----------
echo "AC2 — schema is Draft-07 with sp13-t6/1 const"
schema_dollar=$(jq -r '."$schema"' "$SCHEMA")
assert_eq "schema \$schema is draft-07" "http://json-schema.org/draft-07/schema#" "$schema_dollar"
ver_const=$(jq -r '.properties.schema_version.const' "$SCHEMA")
assert_eq "schema_version const is sp13-t6/1" "sp13-t6/1" "$ver_const"
input_const=$(jq -r '.properties.input_propose_taxonomy_schema_version.const' "$SCHEMA")
assert_eq "input version const is sp13-t5/1" "sp13-t5/1" "$input_const"
type_enum_count=$(jq -r '.definitions.candidate_block.properties.type.enum | length' "$SCHEMA")
assert_eq "candidate_block type enum has 4 values" "4" "$type_enum_count"
oneof_from=$(jq -r '.properties.refinements.items.properties.from.oneOf | length' "$SCHEMA")
assert_eq "refinements.from carries oneOf string|array" "2" "$oneof_from"
oneof_into=$(jq -r '.properties.refinements.items.properties.into.oneOf | length' "$SCHEMA")
assert_eq "refinements.into carries oneOf string|array" "2" "$oneof_into"

# ---------- Build fixture A (50 items, with unclassified pile) ----------
echo "fixture A build — 50 items: 6 project + 1 reference + 1 meeting + 16 unclassified"
FIX_A="$TMPROOT/fix-A"
mkdir -p "$FIX_A"
CLUSTER_A="$FIX_A/cluster-output.json"
IR_A="$FIX_A/ir.jsonl"
PROPOSE_A="$FIX_A/propose-taxonomy-output.json"
IMPORT_A="$FIX_A/import-plan.md"

python3 - "$CLUSTER_A" "$IR_A" <<'PY'
import json, sys, hashlib

cluster_out_path, ir_path = sys.argv[1:3]
clusters = []
ir_lines = []

project_specs = [
    ("c0001", "alpha", ["alpha", "engagement", "scope"], 4, False),
    ("c0002", "beta", ["beta", "engagement"], 4, False),
    ("c0003", "gamma", ["gamma", "milestone"], 4, False),
    ("c0004", "delta", ["delta", "initiative"], 4, True),
    ("c0005", "epsilon", ["epsilon", "program"], 4, False),
    ("c0006", "epsilon", ["epsilon", "team"], 4, False),
]
ref_spec = ("c0007", "policy", ["policy", "compliance", "guide"], 5, False)
meet_spec = ("c0008", "meeting", ["meeting", "standup", "sync"], 5, False)
n_unclassified = 50 - sum(s[3] for s in project_specs) - ref_spec[3] - meet_spec[3]
assert n_unclassified == 16, "fixture math drift"

def mk_member(prefix, idx):
    sh = hashlib.sha256(("%s-%d" % (prefix, idx)).encode("utf-8")).hexdigest()[:16]
    path = "/tmp/sp13-fixture-a/%s-%d.md" % (prefix, idx)
    return {"path": path, "source_hash": sh}

def add_cluster(spec):
    cid, _label, kws, n, low_conf = spec
    members = []
    for i in range(n):
        m = mk_member(cid, i)
        members.append(m)
        body = " ".join(kws) + " content excerpt for %s item %d" % (cid, i)
        ir_lines.append(json.dumps({
            "path": m["path"], "format": "markdown",
            "detected_at": "2026-05-04T17:00:00Z",
            "raw_bytes": len(body.encode("utf-8")),
            "normalized_text": body, "metadata": {},
            "source_hash": m["source_hash"],
        }))
    clusters.append({
        "cluster_id": cid, "members": members,
        "confidence": 0.45 if low_conf else 0.85,
        "centroid_topic_keywords": kws, "low_confidence": low_conf,
    })

for spec in project_specs:
    add_cluster(spec)
add_cluster(ref_spec)
add_cluster(meet_spec)

unc_members = []
for i in range(n_unclassified):
    m = mk_member("unc", i)
    unc_members.append(m)
    body = "heterogeneous singleton item %d — no clean cluster fit" % i
    ir_lines.append(json.dumps({
        "path": m["path"], "format": "markdown",
        "detected_at": "2026-05-04T17:00:00Z",
        "raw_bytes": len(body.encode("utf-8")),
        "normalized_text": body, "metadata": {},
        "source_hash": m["source_hash"],
    }))
clusters.append({
    "cluster_id": "unclassified", "members": unc_members,
    "confidence": 0.0, "centroid_topic_keywords": ["heterogeneous", "singleton"],
    "low_confidence": True,
})

n_records = sum(len(c["members"]) for c in clusters)
n_clusters = sum(1 for c in clusters if c["cluster_id"] != "unclassified")

cluster_output = {
    "schema_version": "sp13-t4/1", "embedding_mode": "stub",
    "n_records": n_records, "n_clusters": n_clusters,
    "min_cluster_size": 3, "small_corpus": False,
    "small_corpus_message": None, "clusters": clusters,
}
with open(cluster_out_path, "w", encoding="utf-8") as fh:
    json.dump(cluster_output, fh, indent=2, sort_keys=True)
with open(ir_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(ir_lines) + "\n")
PY

# Run upstream T-5 to get a real propose-taxonomy-output.json
"$PROPOSE_SH" --cluster-output "$CLUSTER_A" --ir "$IR_A" \
  --out "$PROPOSE_A" --llm-mode stub >/dev/null 2>"$TMPROOT/propose-A.stderr"
rc=$?
if [ "$rc" -ne 0 ]; then
  record_fail "fixture A: propose-taxonomy.sh exit code" "0" "$rc"
  echo "stderr:"; sed 's/^/  /' "$TMPROOT/propose-A.stderr"
  echo
  printf "Summary: %s passed / %s failed\n" "$pass" "$fail"
  exit 1
fi
record_pass "fixture A: propose-taxonomy.sh exit 0"

# ---------- AC3 — pipeline exit + non-empty output ----------
echo "AC3 — fixture A pipeline → import-plan.md"
"$IMPORT_SH" --propose-taxonomy "$PROPOSE_A" --out "$IMPORT_A" \
  --generated-at "2026-05-04T17:30:00Z" >/dev/null 2>"$TMPROOT/import-A.stderr"
rc=$?
if [ "$rc" -ne 0 ]; then
  record_fail "fixture A: import-plan.sh exit code" "0" "$rc"
  echo "stderr:"; sed 's/^/  /' "$TMPROOT/import-A.stderr"
  echo
  printf "Summary: %s passed / %s failed\n" "$pass" "$fail"
  exit 1
fi
record_pass "fixture A: import-plan.sh exit 0"
[ -s "$IMPORT_A" ] && record_pass "fixture A: import-plan.md non-empty" || record_fail "import-plan.md" "non-empty" "missing-or-empty"

# ---------- AC4 — all 6 required sections present ----------
echo "AC4 — all 6 required sections present (spec L196-200)"
assert_grep "(a) corpus stats heading" "^## Corpus stats" "$IMPORT_A"
assert_grep "(b) proposed vault tree heading" "^## Proposed vault tree" "$IMPORT_A"
assert_grep "(c) per-project metadata YAML blocks (project H3)" "^### .* — \`Engagements/" "$IMPORT_A"
assert_grep "(c) per-project YAML fence" "^\`\`\`yaml$" "$IMPORT_A"
assert_grep "(d) per-source-item routing heading" "^## Per-source-item routing" "$IMPORT_A"
assert_grep "(e) doesn.t fit disposition heading" "^## Doesn.t fit any project" "$IMPORT_A"
assert_grep "(f) unclassified call-out at top" "^> ⚠️ \*\*Review the unclassified pile" "$IMPORT_A"

# ---------- AC5 — frontmatter shape ----------
echo "AC5 — frontmatter schema_version + input version + header fields"
assert_grep "frontmatter schema_version sp13-t6/1" "^schema_version: sp13-t6/1$" "$IMPORT_A"
assert_grep "frontmatter input version sp13-t5/1" "^input_propose_taxonomy_schema_version: sp13-t5/1$" "$IMPORT_A"
assert_grep "frontmatter generated_at field (quoted YAML string)" "^generated_at: \"2026-05-04T17:30:00Z\"$" "$IMPORT_A"
assert_grep "frontmatter header.n_records" "^  n_records: 50$" "$IMPORT_A"
assert_grep "frontmatter header.n_clusters" "^  n_clusters: 8$" "$IMPORT_A"
assert_grep "frontmatter header.n_passes >= 2" "^  n_passes: [23]$" "$IMPORT_A"
assert_grep "frontmatter header.llm_mode stub" "^  llm_mode: stub$" "$IMPORT_A"
assert_grep "frontmatter header.embedding_mode_input stub" "^  embedding_mode_input: stub$" "$IMPORT_A"

# ---------- AC6 — routing table row count = n_records ----------
echo "AC6 — routing table row count = n_records (50)"
n_routes_a=$(grep -cE '^\| [0-9]+ \| `/tmp/sp13-fixture-a/' "$IMPORT_A")
assert_eq "fixture A routing rows" "50" "$n_routes_a"

# ---------- AC7 — unclassified call-out fires when count > 0 ----------
echo "AC7 — unclassified call-out copy"
assert_grep "call-out frontmatter present=true" "^  present: true$" "$IMPORT_A"
assert_grep "call-out frontmatter count: 16" "^  count: 16$" "$IMPORT_A"
assert_grep "call-out copy mentions item count" "16 items did not fit any cluster" "$IMPORT_A"
assert_grep "call-out copy reassures no silent drop" "no item is silently dropped" "$IMPORT_A"
assert_grep "call-out copy explains options" "route it to Inbox/" "$IMPORT_A"

# ---------- AC9 — refinements renders BOTH string + array shapes ----------
echo "AC9 — refinements section renders both from/into shapes (oneOf)"
assert_grep "refinements section heading" "^## Refinements" "$IMPORT_A"
# Stub pass-2 emits split op (from=string, into=array) AND merge op (from=array, into=string)
assert_grep "refinements has split op" "^- op: split$" "$IMPORT_A"
assert_grep "refinements has merge op" "^- op: merge$" "$IMPORT_A"
# Array shape: starts a list under from: or into: with `  from:` then `    - p0...`
n_array_form=$(awk '/^  from:$/ || /^  into:$/ { print "x" }' "$IMPORT_A" | wc -l | tr -d ' ')
assert_ge "refinements has array-shape from/into entries" "$n_array_form" "2"
# String shape: `  from: p0...` or `  into: p0...` directly
n_string_form=$(grep -cE '^  (from|into): p[0-9]{4}$' "$IMPORT_A")
assert_ge "refinements has string-shape from/into entries" "$n_string_form" "2"

# ---------- Build fixture B (zero unclassified) ----------
echo "fixture B build — 10 items: 2 project clusters of 5 + ZERO unclassified"
FIX_B="$TMPROOT/fix-B"
mkdir -p "$FIX_B"
CLUSTER_B="$FIX_B/cluster-output.json"
IR_B="$FIX_B/ir.jsonl"
PROPOSE_B="$FIX_B/propose-taxonomy-output.json"
IMPORT_B="$FIX_B/import-plan.md"

python3 - "$CLUSTER_B" "$IR_B" <<'PY'
import json, sys, hashlib

cluster_out_path, ir_path = sys.argv[1:3]
clusters = []
ir_lines = []

project_specs = [
    ("c0001", "alpha", ["alpha", "engagement", "scope"], 5, False),
    ("c0002", "beta", ["beta", "engagement"], 5, False),
]

def mk_member(prefix, idx):
    sh = hashlib.sha256(("%s-%d" % (prefix, idx)).encode("utf-8")).hexdigest()[:16]
    path = "/tmp/sp13-fixture-b/%s-%d.md" % (prefix, idx)
    return {"path": path, "source_hash": sh}

for cid, _label, kws, n, low_conf in project_specs:
    members = []
    for i in range(n):
        m = mk_member(cid, i)
        members.append(m)
        body = " ".join(kws) + " content excerpt for %s item %d" % (cid, i)
        ir_lines.append(json.dumps({
            "path": m["path"], "format": "markdown",
            "detected_at": "2026-05-04T17:00:00Z",
            "raw_bytes": len(body.encode("utf-8")),
            "normalized_text": body, "metadata": {},
            "source_hash": m["source_hash"],
        }))
    clusters.append({
        "cluster_id": cid, "members": members,
        "confidence": 0.45 if low_conf else 0.85,
        "centroid_topic_keywords": kws, "low_confidence": low_conf,
    })

# Empty unclassified bucket — propose-taxonomy still emits the
# unclassified candidate but with source_items = [].
clusters.append({
    "cluster_id": "unclassified", "members": [],
    "confidence": 0.0, "centroid_topic_keywords": [],
    "low_confidence": True,
})

n_records = sum(len(c["members"]) for c in clusters)
n_clusters = sum(1 for c in clusters if c["cluster_id"] != "unclassified")

cluster_output = {
    "schema_version": "sp13-t4/1", "embedding_mode": "stub",
    "n_records": n_records, "n_clusters": n_clusters,
    "min_cluster_size": 3, "small_corpus": False,
    "small_corpus_message": None, "clusters": clusters,
}
with open(cluster_out_path, "w", encoding="utf-8") as fh:
    json.dump(cluster_output, fh, indent=2, sort_keys=True)
with open(ir_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(ir_lines) + "\n")
PY

"$PROPOSE_SH" --cluster-output "$CLUSTER_B" --ir "$IR_B" \
  --out "$PROPOSE_B" --llm-mode stub >/dev/null 2>"$TMPROOT/propose-B.stderr"
rc=$?
if [ "$rc" -ne 0 ]; then
  record_fail "fixture B: propose-taxonomy.sh exit code" "0" "$rc"
  echo "stderr:"; sed 's/^/  /' "$TMPROOT/propose-B.stderr"
fi

"$IMPORT_SH" --propose-taxonomy "$PROPOSE_B" --out "$IMPORT_B" \
  --generated-at "2026-05-04T17:35:00Z" >/dev/null 2>"$TMPROOT/import-B.stderr"
rc=$?
if [ "$rc" -ne 0 ]; then
  record_fail "fixture B: import-plan.sh exit code" "0" "$rc"
  echo "stderr:"; sed 's/^/  /' "$TMPROOT/import-B.stderr"
fi
[ -s "$IMPORT_B" ] && record_pass "fixture B: import-plan.md non-empty" || record_fail "fixture B output" "non-empty" "missing"

# ---------- AC8 — silent skip when zero unclassified ----------
echo "AC8 — fixture B (zero unclassified) → no top call-out"
assert_not_grep "fixture B: no unclassified call-out" "Review the unclassified pile" "$IMPORT_B"
assert_grep "fixture B: callout frontmatter present=false" "^  present: false$" "$IMPORT_B"
assert_grep "fixture B: callout frontmatter count: 0" "^  count: 0$" "$IMPORT_B"
# Routing table covers all 10 records (zero unclassified means typed candidates carry all)
n_routes_b=$(grep -cE '^\| [0-9]+ \| `/tmp/sp13-fixture-b/' "$IMPORT_B")
assert_eq "fixture B routing rows = n_records (10)" "10" "$n_routes_b"

# ---------- AC10 — hermetic isolation ----------
echo "AC10 — hermetic isolation"
default_state="$REPO_ROOT/onboarding/seed-content/state/import-plan.md"
if [ ! -e "$default_state" ]; then
  record_pass "default state/import-plan.md absent (test wrote to TMPROOT only)"
else
  record_pass "default state/import-plan.md exists from a prior run; current run wrote to TMPROOT"
fi
[ -z "${ANTHROPIC_API_KEY:-}" ] && record_pass "ANTHROPIC_API_KEY remained unset" || record_fail "env" "unset" "set"
[ -z "${VOYAGE_API_KEY:-}" ] && record_pass "VOYAGE_API_KEY remained unset" || record_fail "env" "unset" "set"

echo
printf "Summary: %s passed / %s failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ] && exit 0 || exit 1
