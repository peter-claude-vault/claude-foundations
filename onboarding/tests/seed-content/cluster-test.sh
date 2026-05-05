#!/usr/bin/env bash
# sp13-cluster-test.sh — SP13 T-4 unit tests
#
# Covers Stage 2 entry (embedding cluster) acceptance criteria:
#   AC1  cluster.sh + cluster.py + SKILL.md exist; bash -n / py-compile clean
#   AC2  SKILL.md frontmatter present (name + description); cites
#        docs/personalization-model.md (re-uses framing, never re-declares it)
#   AC3  synthetic 50-item consultant fixture -> >= 3 clusters + an
#        "unclassified" cluster record present
#   AC4  every cluster record carries cluster_id / members / confidence /
#        centroid_topic_keywords (schema shape probe)
#   AC5  small-corpus fixture (10 items below 2 * min_cluster_size when
#        min_cluster_size is forced to 6) returns small_corpus=true with a
#        structured message AND a meaningful single cluster (every item
#        routed) — does NOT silently bucket all 10 as unclassified
#   AC6  unclassified bucket is a first-class cluster record with confidence
#        0.0 and a low_confidence flag
#   AC7  hermetic test isolation: no writes outside $TMPDIR/sp13-t4-test-*;
#        VOYAGE_API_KEY is unset for the run; embedding_mode == "stub"
#
# Hermetic: $TMPDIR/sp13-t4-test-XXXXXX. No live writes.
# Bash 3.2 compatible (R-23).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
SKILL_DIR="$REPO_ROOT/skills/infer-vault-structure"
CLUSTER_SH="$SKILL_DIR/cluster.sh"
CLUSTER_PY="$SKILL_DIR/cluster.py"
SKILL_MD="$SKILL_DIR/SKILL.md"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/sp13-t4-test-XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

# Force stub embeddings even if a host-level VOYAGE_API_KEY happens to be set.
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

# ---------- AC1 — components exist + syntax clean ----------
echo "AC1 — components present + syntax clean"
if [ -f "$CLUSTER_SH" ] && bash -n "$CLUSTER_SH" 2>/dev/null; then
  record_pass "cluster.sh exists + bash -n clean"
else
  record_fail "cluster.sh" "ok" "missing-or-syntax"
fi
if [ -f "$CLUSTER_PY" ] && python3 -c "import ast; ast.parse(open('$CLUSTER_PY').read())" 2>/dev/null; then
  record_pass "cluster.py exists + ast.parse clean"
else
  record_fail "cluster.py" "ok" "missing-or-syntax"
fi
if [ -f "$SKILL_MD" ]; then
  record_pass "SKILL.md exists"
else
  record_fail "SKILL.md" "exists" "missing"
fi

# ---------- AC2 — SKILL.md frontmatter + personalization-model citation ----------
echo "AC2 — SKILL.md provenance + personalization-model citation"
if grep -q '^name: infer-vault-structure' "$SKILL_MD" && grep -q '^description:' "$SKILL_MD"; then
  record_pass "SKILL.md frontmatter (name + description)"
else
  record_fail "SKILL.md frontmatter" "name + description present" "missing"
fi
if grep -q 'docs/personalization-model.md' "$SKILL_MD"; then
  record_pass "SKILL.md cites docs/personalization-model.md"
else
  record_fail "SKILL.md cites docs/personalization-model.md" "citation present" "missing"
fi

# Generate a synthetic 50-item consultant-flavored IR fixture.
build_ir_50() {
  local out="$1"
  : > "$out"
  local i
  # Cluster A (12 items): "sprint review" / agile / delivery cadence
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    text="sprint review delivery cadence agile retrospective velocity team commit"
    printf '{"path":"/tmp/sp13-fix/sprint-%02d.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":120,"normalized_text":"%s extra-%d","metadata":{},"source_hash":"deadbeefdeadbe%02d"}\n' \
      "$i" "$text" "$i" "$i" >> "$out"
  done
  # Cluster B (10 items): client engagement / stakeholder / proposal
  for i in 1 2 3 4 5 6 7 8 9 10; do
    text="client engagement stakeholder proposal scope contract pricing kickoff"
    printf '{"path":"/tmp/sp13-fix/engagement-%02d.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":120,"normalized_text":"%s extra-%d","metadata":{},"source_hash":"cafebabecafeba%02d"}\n' \
      "$i" "$text" "$i" "$i" >> "$out"
  done
  # Cluster C (8 items): data pipeline / etl / warehouse
  for i in 1 2 3 4 5 6 7 8; do
    text="data pipeline etl warehouse ingestion airflow snowflake dbt transformation"
    printf '{"path":"/tmp/sp13-fix/pipeline-%02d.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":120,"normalized_text":"%s extra-%d","metadata":{},"source_hash":"f00dbabef00d%02dba"}\n' \
      "$i" "$text" "$i" "$i" >> "$out"
  done
  # Cluster D (6 items): governance / compliance / audit
  for i in 1 2 3 4 5 6; do
    text="governance compliance audit policy regulatory framework documentation control"
    printf '{"path":"/tmp/sp13-fix/governance-%02d.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":120,"normalized_text":"%s extra-%d","metadata":{},"source_hash":"99887766554433%02d"}\n' \
      "$i" "$text" "$i" "$i" >> "$out"
  done
  # Heterogeneous singletons (14 items) — should land in unclassified bucket
  printf '{"path":"/tmp/sp13-fix/odd-001.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"recipe banana bread baking flour butter sugar oven","metadata":{},"source_hash":"1111111111111111"}\n' >> "$out"
  printf '{"path":"/tmp/sp13-fix/odd-002.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"running marathon training pace shoes mileage","metadata":{},"source_hash":"2222222222222222"}\n' >> "$out"
  printf '{"path":"/tmp/sp13-fix/odd-003.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"guitar chord progression strumming amplifier pedal","metadata":{},"source_hash":"3333333333333333"}\n' >> "$out"
  printf '{"path":"/tmp/sp13-fix/odd-004.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"garden tomato basil compost watering soil","metadata":{},"source_hash":"4444444444444444"}\n' >> "$out"
  printf '{"path":"/tmp/sp13-fix/odd-005.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"chess opening sicilian defense knight bishop tactic","metadata":{},"source_hash":"5555555555555555"}\n' >> "$out"
  printf '{"path":"/tmp/sp13-fix/odd-006.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"astronomy telescope nebula galaxy dark matter cosmology","metadata":{},"source_hash":"6666666666666666"}\n' >> "$out"
  printf '{"path":"/tmp/sp13-fix/odd-007.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"poetry stanza rhyme metaphor sonnet villanelle haiku","metadata":{},"source_hash":"7777777777777777"}\n' >> "$out"
  printf '{"path":"/tmp/sp13-fix/odd-008.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"woodworking lathe chisel sandpaper varnish dovetail joinery","metadata":{},"source_hash":"8888888888888888"}\n' >> "$out"
  printf '{"path":"/tmp/sp13-fix/odd-009.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"sailing wind tack jib genoa beam reach knots","metadata":{},"source_hash":"9999999999999999"}\n' >> "$out"
  printf '{"path":"/tmp/sp13-fix/odd-010.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"painting watercolor brush palette canvas mixing pigment","metadata":{},"source_hash":"aaaaaaaaaaaaaaaa"}\n' >> "$out"
  printf '{"path":"/tmp/sp13-fix/odd-011.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"birdwatching binoculars warbler migration nesting plumage","metadata":{},"source_hash":"bbbbbbbbbbbbbbbb"}\n' >> "$out"
  printf '{"path":"/tmp/sp13-fix/odd-012.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"cooking pasta carbonara guanciale pecorino egg yolk","metadata":{},"source_hash":"cccccccccccccccc"}\n' >> "$out"
  printf '{"path":"/tmp/sp13-fix/odd-013.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"photography aperture shutter iso depth of field bokeh","metadata":{},"source_hash":"dddddddddddddddd"}\n' >> "$out"
  printf '{"path":"/tmp/sp13-fix/odd-014.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":50,"normalized_text":"hiking trail summit elevation switchback trekking pole","metadata":{},"source_hash":"eeeeeeeeeeeeeeee"}\n' >> "$out"
}

# ---------- AC3 — synthetic 50-item fixture -> >= 3 clusters + unclassified ----------
echo "AC3 — 50-item consultant fixture clustering"
IR50="$TMPROOT/ir-50.jsonl"
OUT50="$TMPROOT/cluster-50.json"
build_ir_50 "$IR50"
n_in=$(wc -l < "$IR50" | tr -d ' ')
assert_eq "fixture has 50 records" "50" "$n_in"

if bash "$CLUSTER_SH" --ir "$IR50" --out "$OUT50" --min-cluster-size 3 --eps 0.6 --embedding-mode stub 2>"$TMPROOT/run50.err"; then
  record_pass "cluster.sh exits 0 on 50-item fixture"
else
  record_fail "cluster.sh exits 0 on 50-item fixture" "rc=0" "rc=$? (stderr: $(cat "$TMPROOT/run50.err"))"
fi
if [ -s "$OUT50" ]; then
  record_pass "cluster-output.json non-empty"
else
  record_fail "cluster-output.json non-empty" "non-empty" "missing-or-empty"
fi

n_clusters=$(jq -r '.n_clusters' "$OUT50" 2>/dev/null)
assert_ge "n_clusters >= 3" "${n_clusters:-0}" 3

has_unclassified=$(jq -r '[.clusters[] | select(.cluster_id == "unclassified")] | length' "$OUT50" 2>/dev/null)
assert_eq "unclassified bucket present" "1" "${has_unclassified:-0}"

embedding_mode=$(jq -r '.embedding_mode' "$OUT50" 2>/dev/null)
assert_eq "embedding_mode == stub (no api key)" "stub" "${embedding_mode:-?}"

n_records=$(jq -r '.n_records' "$OUT50" 2>/dev/null)
assert_eq "n_records == 50" "50" "${n_records:-?}"

# ---------- AC4 — schema shape probe ----------
echo "AC4 — cluster record schema"
shape_ok=$(jq -r '
  [.clusters[]
    | (has("cluster_id") and has("members") and has("confidence")
       and has("centroid_topic_keywords") and has("low_confidence"))]
  | all
' "$OUT50" 2>/dev/null)
assert_eq "every cluster has required fields" "true" "${shape_ok:-?}"

confidence_in_range=$(jq -r '
  [.clusters[].confidence | (. >= 0 and . <= 1)] | all
' "$OUT50" 2>/dev/null)
assert_eq "every confidence in [0.0, 1.0]" "true" "${confidence_in_range:-?}"

members_have_path_hash=$(jq -r '
  [.clusters[].members[] | (has("path") and has("source_hash"))] | all
' "$OUT50" 2>/dev/null)
assert_eq "every member has path + source_hash" "true" "${members_have_path_hash:-?}"

# Every IR record should appear in exactly ONE cluster (incl. unclassified).
total_members=$(jq -r '[.clusters[].members[]] | length' "$OUT50")
assert_eq "every IR record routed to a cluster" "50" "${total_members:-?}"

# ---------- AC5 — small-corpus path ----------
echo "AC5 — small-corpus mode"
IR_SMALL="$TMPROOT/ir-small.jsonl"
OUT_SMALL="$TMPROOT/cluster-small.json"
: > "$IR_SMALL"
i=0
while [ "$i" -lt 10 ]; do
  i=$((i + 1))
  printf '{"path":"/tmp/sp13-small-%02d.md","format":"markdown","detected_at":"2026-05-04T00:00:00Z","raw_bytes":40,"normalized_text":"item %d about widgets gadgets gizmos thingamajigs","metadata":{},"source_hash":"deadbeef00000%02d"}\n' \
    "$i" "$i" "$i" >> "$IR_SMALL"
done

# min_cluster_size 6 -> n=10 < 2*6=12 -> small_corpus path triggers.
if bash "$CLUSTER_SH" --ir "$IR_SMALL" --out "$OUT_SMALL" --min-cluster-size 6 --embedding-mode stub 2>"$TMPROOT/run-small.err"; then
  record_pass "cluster.sh exits 0 on small fixture"
else
  record_fail "cluster.sh exits 0 on small fixture" "rc=0" "rc=$?"
fi

small=$(jq -r '.small_corpus' "$OUT_SMALL" 2>/dev/null)
assert_eq "small_corpus == true" "true" "${small:-?}"
msg=$(jq -r '.small_corpus_message' "$OUT_SMALL" 2>/dev/null)
if [ -n "$msg" ] && [ "$msg" != "null" ]; then
  record_pass "small_corpus_message is non-null structured string"
else
  record_fail "small_corpus_message non-null" "non-null string" "${msg:-null}"
fi

n_small_clusters=$(jq -r '.clusters | length' "$OUT_SMALL")
assert_eq "small-corpus path returns single cluster (not silent unclassified)" "1" "${n_small_clusters:-?}"
small_cid=$(jq -r '.clusters[0].cluster_id' "$OUT_SMALL")
if [ "$small_cid" != "unclassified" ]; then
  record_pass "small-corpus cluster is NOT 'unclassified' (no silent floor)"
else
  record_fail "small-corpus cluster id" "non-unclassified" "$small_cid"
fi
small_members=$(jq -r '.clusters[0].members | length' "$OUT_SMALL")
assert_eq "small-corpus single cluster carries all 10 members" "10" "${small_members:-?}"

# ---------- AC6 — unclassified bucket properties ----------
echo "AC6 — unclassified bucket properties"
unc_conf=$(jq -r '.clusters[] | select(.cluster_id == "unclassified") | .confidence' "$OUT50")
case "$unc_conf" in
  0|0.0|0.00|0.0000) record_pass "unclassified confidence == 0.0 (got $unc_conf)" ;;
  *) record_fail "unclassified confidence == 0.0" "0 or 0.0" "$unc_conf" ;;
esac
unc_lc=$(jq -r '.clusters[] | select(.cluster_id == "unclassified") | .low_confidence' "$OUT50")
assert_eq "unclassified low_confidence == true" "true" "${unc_lc:-?}"
unc_n=$(jq -r '.clusters[] | select(.cluster_id == "unclassified") | (.members | length)' "$OUT50")
assert_ge "unclassified bucket has > 0 members (heterogeneous singletons)" "${unc_n:-0}" 1

# ---------- AC7 — hermetic isolation ----------
echo "AC7 — hermetic isolation"
# Output paths must be under $TMPROOT; the default --out should NOT have been
# touched (we passed explicit --out flags). Spot-check the default state dir:
DEFAULT_STATE_DIR="$REPO_ROOT/onboarding/seed-content/state"
if [ ! -d "$DEFAULT_STATE_DIR" ] || [ -z "$(ls -A "$DEFAULT_STATE_DIR" 2>/dev/null || true)" ]; then
  record_pass "default state dir untouched (no leak from test)"
else
  # Allow if dir exists but is empty post-test cleanup. Block if foreign artifacts.
  bad=$(ls -A "$DEFAULT_STATE_DIR" 2>/dev/null | head -1)
  if [ -z "$bad" ]; then
    record_pass "default state dir empty"
  else
    record_fail "default state dir untouched" "empty-or-absent" "contains $bad"
  fi
fi
# Confirm VOYAGE_API_KEY remained unset throughout.
if [ -z "${VOYAGE_API_KEY:-}" ]; then
  record_pass "VOYAGE_API_KEY unset for run (stub forced)"
else
  record_fail "VOYAGE_API_KEY unset" "unset" "set"
fi

echo
echo "summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
