#!/bin/bash
# tests/grep-audit-unit-test.sh
#
# Unit test for tests/grep-audit.sh. Validates that each seeded fixture
# triggers the correct layer and ONLY that layer. Copies fixtures to a
# throwaway $DOGFOOD_ROOT (so the path is outside the default
# /grep-audit-fixtures/ exclusion), runs the audit, parses the JSON
# summary, asserts layer-N=1 and others=0.
#
# Exit codes:
#   0  all fixtures behave as expected
#   8  any fixture misbehaves (diagnostic on stderr)
#   7  setup error (fixture file missing, jq missing, etc.)
#
# R-23: bash 3.2 compat.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./dogfood-root-helper.sh
. "${SCRIPT_DIR}/dogfood-root-helper.sh"

FIXTURES_DIR="${SCRIPT_DIR}/grep-audit-fixtures"
AUDIT="${SCRIPT_DIR}/grep-audit.sh"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'unit-test: python3 required\n' >&2; exit 7
fi

# Parse a named int field from the audit's JSON stdout. Uses python3 to
# avoid a jq hard dep.
json_field() {
  # $1 json  $2 key
  python3 -c '
import json,sys
d=json.loads(sys.argv[1])
print(d.get(sys.argv[2], "MISSING"))
' "$1" "$2"
}

# Run audit with Layer 4 disabled (the fixture temp dir is not a git repo
# anyway; we just want deterministic results).
run_and_assert() {
  local label="$1" fixture_file="$2" expected_layer="$3"

  local tdir="${DOGFOOD_ROOT}/${label}"
  mkdir -p "$tdir"
  cp "$fixture_file" "$tdir/"

  local json
  json=$(GREP_AUDIT_SKIP_LAYER4=1 "$AUDIT" "$tdir" 2>/dev/null || true)
  if [ -z "$json" ]; then
    printf 'unit-test FAIL (%s): no JSON from audit\n' "$label" >&2
    return 1
  fi

  local hit1 hit2 hit3 hit4
  hit1=$(json_field "$json" layer1)
  hit2=$(json_field "$json" layer2)
  hit3=$(json_field "$json" layer3)
  hit4=$(json_field "$json" layer4)

  local expected1=0 expected2=0 expected3=0 expected4=0
  case "$expected_layer" in
    1) expected1=1 ;;
    2) expected2=1 ;;
    3) expected3=1 ;;
    4) expected4=1 ;;
  esac

  if [ "$hit1" = "$expected1" ] && [ "$hit2" = "$expected2" ] \
     && [ "$hit3" = "$expected3" ] && [ "$hit4" = "$expected4" ]; then
    printf 'unit-test PASS (%s): layer %s fired exclusively\n' "$label" "$expected_layer"
    return 0
  else
    printf 'unit-test FAIL (%s): expected layer %s only; got l1=%s l2=%s l3=%s l4=%s\n' \
      "$label" "$expected_layer" "$hit1" "$hit2" "$hit3" "$hit4" >&2
    printf '  json: %s\n' "$json" >&2
    return 1
  fi
}

fails=0

run_and_assert 'layer1' "${FIXTURES_DIR}/fixture-layer1-raw.txt"    1 || fails=$((fails + 1))
run_and_assert 'layer2' "${FIXTURES_DIR}/fixture-layer2-nfkc.txt"   2 || fails=$((fails + 1))
run_and_assert 'layer3' "${FIXTURES_DIR}/fixture-layer3-base64.txt" 3 || fails=$((fails + 1))

# --- Layer 4 test: deliberate ref added in a commit then removed in a later
# commit. Layer 4 must catch the orphaned blob; the live tree must look clean.
#
# NOTE: the hit string is assembled at runtime from two halves so the
# unit-test source file itself contains no literal match for the
# grep-audit patterns. Without this split, every commit that ships
# this file would permanently re-seed a layer-4 hit against the
# repo's own history — the self-verify (T-13) attests {l4:1} as
# baseline only from the fixtures generator, not from this test's source.
__L4_HIT_STR="peter""tiktinsky"
l4_repo="${DOGFOOD_ROOT}/layer4-history"
mkdir -p "$l4_repo"
(
  cd "$l4_repo"
  git init -q -b main
  git config user.email 'test@local'
  git config user.name  'Test'
  printf 'clean content\n' > file.txt
  git add file.txt
  git commit -q -m 'baseline'
  printf 'clean content\nthe person %s appears here briefly\n' "$__L4_HIT_STR" > file.txt
  git add file.txt
  git commit -q -m 'leak'
  printf 'clean content\n' > file.txt
  git add file.txt
  git commit -q -m 'scrub'
)
json=$("$AUDIT" "$l4_repo" 2>/dev/null || true)
hit1=$(json_field "$json" layer1)
hit4=$(json_field "$json" layer4)
if [ "$hit1" = '0' ] && [ "$hit4" = '1' ]; then
  printf 'unit-test PASS (layer4): live tree clean, history hit\n'
else
  printf 'unit-test FAIL (layer4): expected l1=0 l4=1; got l1=%s l4=%s\n' "$hit1" "$hit4" >&2
  printf '  json: %s\n' "$json" >&2
  fails=$((fails + 1))
fi

# --- Path-self-match regression test ---
# Earlier revisions of grep-audit.sh piped Python helper output (which prefixes
# every emitted line with the absolute file path) through a separate
# `grep -f patterns` stage. When invoked with an absolute target inside
# /Users/<name>/, the path prefix itself self-matched the literal pattern
# list, producing false positives on layers 2 and 3. Fix: matching moved
# inside the helpers, scoped to file content only. This test re-exercises
# the failure class.
#
# Setup: a subdir whose NAME matches the literal pattern list, containing a
# file with NFKC-triggering content that is otherwise clean (no Peter
# strings, no base64 leaks). Pre-fix: layer 2 = 1 (false positive from path).
# Post-fix: layer 2 = 0 (content alone is matched).
__SELFMATCH_DIRNAME="peter""tiktinsky-self-match-probe"
selfmatch_dir="${DOGFOOD_ROOT}/${__SELFMATCH_DIRNAME}"
mkdir -p "$selfmatch_dir"
# Innocuous NFKC-triggering content — fullwidth digit '1' (U+FF11) normalizes
# to ASCII '1', triggering Layer 2's "nfkc != line" emit. No Peter strings.
printf 'just innocuous text with a fullwidth one: \xef\xbc\x91\n' > "$selfmatch_dir/clean.txt"
json=$(GREP_AUDIT_SKIP_LAYER4=1 "$AUDIT" "$selfmatch_dir" 2>/dev/null || true)
hit2=$(json_field "$json" layer2)
hit3=$(json_field "$json" layer3)
total=$(json_field "$json" hits_total)
if [ "$hit2" = '0' ] && [ "$hit3" = '0' ] && [ "$total" = '0' ]; then
  printf 'unit-test PASS (path-self-match): clean content under peter-pathed dir → 0 hits\n'
else
  printf 'unit-test FAIL (path-self-match): expected all-zero; got l2=%s l3=%s total=%s\n' \
    "$hit2" "$hit3" "$total" >&2
  printf '  json: %s\n' "$json" >&2
  fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then
  printf 'unit-test: %d failure(s)\n' "$fails" >&2
  exit 8
fi
printf 'unit-test: all 4 layers + path-self-match regression validated\n'
exit 0
