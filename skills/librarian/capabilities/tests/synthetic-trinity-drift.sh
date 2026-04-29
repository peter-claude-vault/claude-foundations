#!/bin/bash
# Synthetic tests for trinity-drift-detect.sh — Plan 67 SP04 T-1.
#
# 4 cases:
#   1. Alignment — spec=complete + manifest=complete + all tasks=done → 0 findings
#   2. Trinity-task-ledger-lag — manifest=complete but T-1 still not-started → 1 finding
#   3. Spec-manifest-divergence — spec=complete but manifest=planned → 1 finding
#   4. In-flight exclusion — all statuses in-progress → 0 findings
#
# Usage: bash synthetic-trinity-drift.sh
# Exit:  0 on 4/4 pass, 1 otherwise.
#
# Bash 3.2 clean per R-23.

set -uo pipefail

CAP="$(cd "$(dirname "$0")/.." && pwd)/trinity-drift-detect.sh"
TMP_PLANS="$(mktemp -d -t trinity-drift-test-XXXXXX)"
TMP_FINDINGS="$TMP_PLANS/.findings.ndjson"
PASS=0
FAIL=0
TESTS=0

cleanup() { rm -rf "$TMP_PLANS"; }
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------

# Write a plan dir: $1=name, $2=spec-status, $3=manifest-status, $4=tasks-status, $5=T1-status, $6=T2-status
# Pass "SKIP" for T2-status to omit second task.
# Pass "NOTASKS" for tasks-status to skip tasks.md entirely.
make_plan() {
  local name="$1" spec_s="$2" manifest_s="$3" tasks_s="$4" t1_s="$5" t2_s="${6:-SKIP}"
  local dir="$TMP_PLANS/$name"
  mkdir -p "$dir"
  cat > "$dir/spec.md" <<SPEC
---
title: Test spec
type: spec
status: $spec_s
---
# Spec
SPEC
  cat > "$dir/manifest.json" <<MANIFEST
{"slug": "$name", "status": "$manifest_s"}
MANIFEST
  if [ "$tasks_s" = "NOTASKS" ]; then
    return 0
  fi
  {
    printf '%s\n' "---"
    printf '%s\n' "title: Tasks"
    printf '%s\n' "type: tasks"
    printf '%s\n' "status: $tasks_s"
    printf '%s\n' "---"
    printf '\n'
    printf '### T-1: first task\n\n'
    printf '**Status:** %s\n\n' "$t1_s"
    if [ "$t2_s" != "SKIP" ]; then
      printf '### T-2: second task\n\n'
      printf '**Status:** %s\n\n' "$t2_s"
    fi
  } > "$dir/tasks.md"
}

# Count findings for a specific plan dir + drift class
# $1=plan_name, $2=drift_class
count_findings() {
  local plan="$1" cls="$2"
  grep -c "\"file\": \"$plan\".*\"drift_class\": \"$cls\"" "$TMP_FINDINGS" 2>/dev/null | tr -d '[:space:]'
}

# Run the capability and collect findings for a specific plan
# $1=test-name, $2=plan-name, $3=expected-drift-class-or-NONE, $4=expected-count
run_case() {
  local name="$1" plan="$2" expect_class="$3" expect_count="$4"
  TESTS=$((TESTS + 1))

  : > "$TMP_FINDINGS"
  FINDINGS_OUTPUT="$TMP_FINDINGS" \
  PLANS_DIR="$TMP_PLANS" \
  bash "$CAP" --scope "$TMP_PLANS" >/dev/null 2>&1

  local got_count
  if [ "$expect_class" = "NONE" ]; then
    # Expect zero findings for this plan overall
    got_count=$(grep -c "\"file\": \"$plan\"" "$TMP_FINDINGS" 2>/dev/null | tr -d '[:space:]')
    [ -z "$got_count" ] && got_count=0
    if [ "$got_count" = "$expect_count" ]; then
      printf '  PASS  %s\n' "$name"
      PASS=$((PASS + 1))
    else
      printf '  FAIL  %s (expected %s total findings for %s, got %s)\n' "$name" "$expect_count" "$plan" "$got_count"
      FAIL=$((FAIL + 1))
      echo "--- findings ---"
      cat "$TMP_FINDINGS"
      echo "--- end ---"
    fi
  else
    got_count=$(count_findings "$plan" "$expect_class")
    [ -z "$got_count" ] && got_count=0
    if [ "$got_count" = "$expect_count" ]; then
      printf '  PASS  %s\n' "$name"
      PASS=$((PASS + 1))
    else
      printf '  FAIL  %s (expected %s "%s" findings for %s, got %s)\n' "$name" "$expect_count" "$expect_class" "$plan" "$got_count"
      FAIL=$((FAIL + 1))
      echo "--- findings ---"
      cat "$TMP_FINDINGS"
      echo "--- end ---"
    fi
  fi
  # Clean up plan dir so subsequent cases don't see it
  rm -rf "$TMP_PLANS/$plan"
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------
printf 'synthetic-trinity-drift.sh — T-1\n'

# Case 1: Alignment — spec=complete + manifest=complete + all tasks=done → 0 findings
make_plan "01-aligned" "complete" "complete" "complete" "done" "done"
run_case "1. alignment (all complete/done) emits no findings" "01-aligned" "NONE" "0"

# Case 2: Trinity-task-ledger-lag — manifest=complete, T-1=not-started → finding
make_plan "02-ledger-lag" "complete" "complete" "complete" "not-started" "done"
run_case "2. trinity-task-ledger-lag (manifest.complete, T-1.not-started)" "02-ledger-lag" "trinity-task-ledger-lag" "1"

# Case 3: Spec-manifest-divergence — spec=complete, manifest=planned → finding
make_plan "03-spec-divergence" "complete" "planned" "planned" "not-started"
run_case "3. spec-manifest-divergence (spec.complete vs manifest.planned)" "03-spec-divergence" "spec-manifest-divergence" "1"

# Case 4: In-flight exclusion — all statuses in-progress → 0 findings
make_plan "04-inflight" "in-progress" "in-progress" "in-progress" "in-progress" "not-started"
run_case "4. in-flight exclusion (all in-progress + partial tasks)" "04-inflight" "NONE" "0"

printf '\nResults: %d/%d passed\n' "$PASS" "$TESTS"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
