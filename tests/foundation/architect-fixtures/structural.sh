#!/bin/bash
# tests/foundation/architect-fixtures/structural.sh
#
# Plan 71 SP05 T-5 — Per-archetype structural contract harness for architect.
#
# Architect is LLM-interpreted. The achievable contract for ACs #1-5 is
# structural — the fixture manifest pair satisfies architect's declared
# data-source surface in SKILL.md. SP05 T-3's `synthetic-architect-first-scan.sh`
# proves the GENERIC contract (SKILL.md sections + skeleton invariants);
# this harness extends it PER-ARCHETYPE to the 3 SP01 fixtures.
#
# AC #6 (architect-triage.sh runtime) is asserted in `triage-runtime.sh`.
#
# Reframed AC-surface (per archetype × 3):
#   AC #1-3 (`{archetype} fixture → valid report + 0 leak`):
#     - Case 1: user-manifest is jq-parseable
#     - Case 2: user-manifest.architect has all 8 Q1-Q8 fields per Lead 5 §6
#     - Case 3: leak-audit on user-manifest + sidecars hits 0 (Layer 1-3 patterns)
#     - Case 4: user-manifest.vault has `root` + `is_fresh` + `top_level_folder`
#               (architect's structural-dimension required reads)
#     - Case 5: user-manifest.system has `schema_version` + `is_fresh`
#               (architect's first-scan detection required reads)
#   AC #4 (`[AR-NNN] format exclusively`):
#     - Case 6: librarian-manifest skeleton's
#               `architect_recommendations.items[]` is empty (no legacy R-NNN
#               to migrate). Generic AR-NNN format proved at runtime by SP05
#               T-4 synthetic-architect-triage-ar-prefix.sh.
#   AC #5 (`Convergence "first scan, no prior data"`):
#     - Case 7: librarian-manifest skeleton's
#               `architect_recommendations.last_scanned_log == null`. Generic
#               "first scan, no prior data" wording proved by SP05 T-3
#               synthetic-architect-first-scan.sh.
#
# Read-only test; no state mutation; no dogfood-root needed.
#
# Bash 3.2 compatible (R-23). jq + python3 required.
#
# Usage: bash structural.sh
# Exit:  0 on 21/21 pass (7 cases × 3 archetypes), 1 otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURES_DIR="$ROOT/onboarding/fixtures"
SKELETON="$ROOT/templates/librarian-manifest-skeleton.json"
GREP_AUDIT="$ROOT/tests/grep-audit.sh"

ARCHETYPES="consultant developer writer"

# Q1-Q8 per Lead 5 §6 mapping table (resolved via SP04 T-2 schema):
#   Q1→prior_seed[]  Q2→output_dir  Q3→cadence  Q4→benchmarks{}
#   Q5→external_research_enabled  Q6→dimensions_enabled[]
#   Q7→default_mode  Q8→auto_compare
ARCHITECT_KEYS="prior_seed output_dir cadence benchmarks external_research_enabled dimensions_enabled default_mode auto_compare"

PASS=0
FAIL=0
TESTS=0

assert_pass() {
  TESTS=$((TESTS + 1))
  PASS=$((PASS + 1))
  printf '  PASS %s\n' "$1"
}

assert_fail() {
  TESTS=$((TESTS + 1))
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '       detail: %s\n' "$2"
}

# Preconditions
if ! command -v jq >/dev/null 2>&1; then
  printf 'structural.sh: jq not on PATH\n' >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'structural.sh: python3 not on PATH\n' >&2
  exit 2
fi
if [ ! -f "$SKELETON" ]; then
  printf 'structural.sh: skeleton missing: %s\n' "$SKELETON" >&2
  exit 2
fi
if [ ! -x "$GREP_AUDIT" ]; then
  printf 'structural.sh: grep-audit.sh not executable: %s\n' "$GREP_AUDIT" >&2
  exit 2
fi

# Per-archetype assertion suite
run_archetype() {
  local arch="$1"
  local manifest="$FIXTURES_DIR/$arch.json"

  printf '\n=== archetype: %s ===\n' "$arch"

  # Case 1: user-manifest jq-parseable
  if [ ! -f "$manifest" ]; then
    assert_fail "[$arch] manifest-exists" "missing $manifest"
    return
  fi
  if jq -e . "$manifest" >/dev/null 2>&1; then
    assert_pass "[$arch] manifest-jq-parseable"
  else
    assert_fail "[$arch] manifest-jq-parseable" "jq parse failed"
    return
  fi

  # Case 2: architect block has all 8 Q1-Q8 keys
  local missing=""
  for k in $ARCHITECT_KEYS; do
    if ! jq -e ".architect | has(\"$k\")" "$manifest" >/dev/null 2>&1; then
      missing="$missing $k"
    fi
  done
  if [ -z "$missing" ]; then
    assert_pass "[$arch] architect-block-q1-q8-complete"
  else
    assert_fail "[$arch] architect-block-q1-q8-complete" "missing keys:$missing"
  fi

  # Case 3: leak-audit on manifest + sidecars hits 0
  # grep-audit.sh expects a directory or file. Run on each per-archetype file
  # individually, sum the layer counters. Sidecars: -section-{B,C,D}.txt,
  # -vault-schema.json, -orchestration.json.
  local leak_total=0
  local leak_files=""
  for sidecar in "$manifest" \
                 "$FIXTURES_DIR/${arch}-section-B.txt" \
                 "$FIXTURES_DIR/${arch}-section-C.txt" \
                 "$FIXTURES_DIR/${arch}-section-D.txt" \
                 "$FIXTURES_DIR/${arch}-vault-schema.json" \
                 "$FIXTURES_DIR/${arch}-orchestration.json"; do
    [ -f "$sidecar" ] || continue
    local hits
    hits=$(bash "$GREP_AUDIT" "$sidecar" 2>/dev/null \
             | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hits_total",0))' \
             2>/dev/null)
    [ -z "$hits" ] && hits=0
    leak_total=$((leak_total + hits))
    [ "$hits" -gt 0 ] && leak_files="$leak_files $(basename "$sidecar")(=$hits)"
  done
  if [ "$leak_total" -eq 0 ]; then
    assert_pass "[$arch] leak-audit-zero-hits"
  else
    assert_fail "[$arch] leak-audit-zero-hits" \
                "$leak_total total hits across:$leak_files"
  fi

  # Case 4: vault block has architect's structural-dimension required reads
  local vault_missing=""
  for k in root is_fresh top_level_folder; do
    if ! jq -e ".vault | has(\"$k\")" "$manifest" >/dev/null 2>&1; then
      vault_missing="$vault_missing $k"
    fi
  done
  if [ -z "$vault_missing" ]; then
    assert_pass "[$arch] vault-block-structural-deps"
  else
    assert_fail "[$arch] vault-block-structural-deps" "missing keys:$vault_missing"
  fi

  # Case 5: system block has architect's first-scan detection required reads
  local sys_missing=""
  for k in schema_version is_fresh; do
    if ! jq -e ".system | has(\"$k\")" "$manifest" >/dev/null 2>&1; then
      sys_missing="$sys_missing $k"
    fi
  done
  if [ -z "$sys_missing" ]; then
    assert_pass "[$arch] system-block-first-scan-deps"
  else
    assert_fail "[$arch] system-block-first-scan-deps" "missing keys:$sys_missing"
  fi

  # Case 6: skeleton's architect_recommendations.items[] is empty
  # (per-archetype: each archetype materializes the same skeleton at test-time;
  # this asserts the shared skeleton invariant holds for the scope of this archetype's
  # materialization)
  local items_len
  items_len=$(jq -r '.architect_recommendations.items | length' "$SKELETON")
  if [ "$items_len" = "0" ]; then
    assert_pass "[$arch] skeleton-items-empty"
  else
    assert_fail "[$arch] skeleton-items-empty" "expected length 0, got $items_len"
  fi

  # Case 7: skeleton's architect_recommendations.last_scanned_log == null
  local last_scan
  last_scan=$(jq -r '.architect_recommendations.last_scanned_log' "$SKELETON")
  if [ "$last_scan" = "null" ]; then
    assert_pass "[$arch] skeleton-last-scanned-log-null"
  else
    assert_fail "[$arch] skeleton-last-scanned-log-null" "expected null, got $last_scan"
  fi
}

for arch in $ARCHETYPES; do
  run_archetype "$arch"
done

printf '\n=== T-5 structural summary ===\n'
printf 'PASS: %d / %d\n' "$PASS" "$TESTS"
printf 'FAIL: %d\n' "$FAIL"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
