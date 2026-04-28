#!/usr/bin/env bash
# archetype-inference-test.sh — SP01 T-7a unit tests
#
# Covers the 3 named archetype buckets (consultant / developer / writer)
# plus an ambiguous-mixed fixture and an empty-transcript fixture. The
# generalist and academic buckets are exercised implicitly (they should
# NEVER win on the named fixtures — that would indicate leak-through).
#
# Each fixture prints its observed {archetype, confidence, margin,
# score_top} so that T-13's round-trip fixture gate has data to retune
# the confidence divisor (currently 6; see onboarder-design.md §9).
#
# bash 3.2 compatible (R-23).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INFER="$SCRIPT_DIR/../archetype-inference.sh"

if [ ! -x "$INFER" ]; then
  echo "FAIL — inference script not executable: $INFER" >&2
  exit 2
fi

pass=0
fail=0
fail_msgs=""

record_pass() {
  pass=$((pass + 1))
  printf '  ok   %s\n' "$1"
}

record_fail() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
  fail_msgs="${fail_msgs}FAIL: $1
  expected: $2
  actual:   $3
"
}

assert_eq() {
  label="$1"
  expected="$2"
  actual="$3"
  if [ "$expected" = "$actual" ]; then
    record_pass "$label"
  else
    record_fail "$label" "$expected" "$actual"
  fi
}

# Numeric comparison: $1 >= $2 ? (floats via awk)
assert_ge() {
  label="$1"
  actual="$2"
  threshold="$3"
  ok=$(awk -v a="$actual" -v t="$threshold" 'BEGIN { print (a + 0 >= t + 0) ? "1" : "0" }')
  if [ "$ok" = "1" ]; then
    record_pass "$label (got $actual, expected >= $threshold)"
  else
    record_fail "$label" ">= $threshold" "$actual"
  fi
}

# Numeric comparison: $1 < $2 ?
assert_lt() {
  label="$1"
  actual="$2"
  threshold="$3"
  ok=$(awk -v a="$actual" -v t="$threshold" 'BEGIN { print (a + 0 < t + 0) ? "1" : "0" }')
  if [ "$ok" = "1" ]; then
    record_pass "$label (got $actual, expected < $threshold)"
  else
    record_fail "$label" "< $threshold" "$actual"
  fi
}

# Run inference on a transcript JSON passed on stdin.
run_case() {
  name="$1"
  transcript="$2"
  out=$(printf '%s' "$transcript" | "$INFER")
  if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    record_fail "$name — script emitted invalid JSON" "valid JSON" "$out"
    printf '%s' ""
    return
  fi
  printf '%s' "$out"
}

# ------------------------------------------------------------ Fixtures

consultant_fixture='{
  "section_b": {
    "work_description": "I run client engagements — proposals, pitches, stakeholder advisory, and billable workstreams. Executive sponsors and steering committees are the norm, kickoff through rollout.",
    "typical_week": "Scoping calls, partner syncs, and advisory memos."
  },
  "section_c": {
    "deliverable_types": "engagement, proposal, deliverable, scope, rollout"
  }
}'

developer_fixture='{
  "section_b": {
    "work_description": "I ship from a monorepo — pull requests, merges, deploys, CI, releases. Frontend and backend endpoints, a database, library framework, infrastructure.",
    "typical_week": "Branch, commit, review, build."
  }
}'

writer_fixture='{
  "section_b": {
    "work_description": "I publish essays to a newsletter — drafts, outlines, narrative voice. Chapter manuscripts, podcast episodes, audience subscribers.",
    "typical_week": "Byline editor, post outline, draft manuscript."
  }
}'

# Ambiguous: exactly one positive hit per several buckets, no margin.
# Expect fallback to generalist with confidence < 0.5.
ambiguous_fixture='{
  "section_b": {
    "work_description": "I write essays about running a monorepo client project."
  }
}'

empty_fixture='{}'

# --------------------------------------------------------------- Runs

printf '\n=== consultant fixture ===\n'
out=$(run_case "consultant" "$consultant_fixture")
arch=$(printf '%s' "$out" | jq -r .archetype)
conf=$(printf '%s' "$out" | jq -r .confidence)
score=$(printf '%s' "$out" | jq -r .score_top)
margin=$(printf '%s' "$out" | jq -r .margin)
printf '  observed: archetype=%s confidence=%s score_top=%s margin=%s\n' "$arch" "$conf" "$score" "$margin"
assert_eq "consultant — archetype"   "consultant" "$arch"
assert_ge "consultant — confidence"  "$conf"      "0.5"
assert_ge "consultant — margin"      "$margin"    "1"

printf '\n=== developer fixture ===\n'
out=$(run_case "developer" "$developer_fixture")
arch=$(printf '%s' "$out" | jq -r .archetype)
conf=$(printf '%s' "$out" | jq -r .confidence)
score=$(printf '%s' "$out" | jq -r .score_top)
margin=$(printf '%s' "$out" | jq -r .margin)
printf '  observed: archetype=%s confidence=%s score_top=%s margin=%s\n' "$arch" "$conf" "$score" "$margin"
assert_eq "developer — archetype"    "developer"  "$arch"
assert_ge "developer — confidence"   "$conf"      "0.5"
assert_ge "developer — margin"       "$margin"    "1"

printf '\n=== writer fixture ===\n'
out=$(run_case "writer" "$writer_fixture")
arch=$(printf '%s' "$out" | jq -r .archetype)
conf=$(printf '%s' "$out" | jq -r .confidence)
score=$(printf '%s' "$out" | jq -r .score_top)
margin=$(printf '%s' "$out" | jq -r .margin)
printf '  observed: archetype=%s confidence=%s score_top=%s margin=%s\n' "$arch" "$conf" "$score" "$margin"
assert_eq "writer — archetype"       "writer"     "$arch"
assert_ge "writer — confidence"      "$conf"      "0.5"
assert_ge "writer — margin"          "$margin"    "1"

printf '\n=== ambiguous-mixed fixture ===\n'
out=$(run_case "ambiguous" "$ambiguous_fixture")
arch=$(printf '%s' "$out" | jq -r .archetype)
conf=$(printf '%s' "$out" | jq -r .confidence)
score=$(printf '%s' "$out" | jq -r .score_top)
margin=$(printf '%s' "$out" | jq -r .margin)
printf '  observed: archetype=%s confidence=%s score_top=%s margin=%s\n' "$arch" "$conf" "$score" "$margin"
assert_eq "ambiguous — archetype"    "generalist" "$arch"
assert_lt "ambiguous — confidence"   "$conf"      "0.5"

printf '\n=== empty-transcript fixture ===\n'
out=$(run_case "empty" "$empty_fixture")
arch=$(printf '%s' "$out" | jq -r .archetype)
conf=$(printf '%s' "$out" | jq -r .confidence)
score=$(printf '%s' "$out" | jq -r .score_top)
margin=$(printf '%s' "$out" | jq -r .margin)
printf '  observed: archetype=%s confidence=%s score_top=%s margin=%s\n' "$arch" "$conf" "$score" "$margin"
assert_eq "empty — archetype"        "generalist" "$arch"
assert_eq "empty — confidence"       "0.000"      "$conf"
assert_eq "empty — margin"           "0.0"        "$margin"

# ----------------------------------------------------------- Summary

printf '\n----------------------------------\n'
printf 'passed: %s\n' "$pass"
printf 'failed: %s\n' "$fail"

if [ "$fail" -gt 0 ]; then
  printf '\n%s' "$fail_msgs"
  exit 1
fi

exit 0
