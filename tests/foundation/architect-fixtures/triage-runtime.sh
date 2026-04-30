#!/bin/bash
# tests/foundation/architect-fixtures/triage-runtime.sh
#
# Plan 71 SP05 T-5 — Per-archetype runtime smoke for architect-triage.sh.
#
# Satisfies AC #6 verbatim ("architect-triage.sh ingests all 3 reports
# without error; populates architect_recommendations.recommendations[] per
# fixture"). architect-triage.sh is a runnable Python heredoc (NOT
# LLM-interpreted), so AC #6 is achievable as runtime.
#
# Pattern: extends `synthetic-architect-triage-ar-prefix.sh` (SP05 T-4
# Test A) per-archetype. Same hermetic env scheme:
#   - Per-archetype scratch dir for materialized skeleton + synthetic report
#   - MANIFEST_PATH + ARCHITECT_LOGS_GLOB + SYSTEM_BACKLOG_PATH + FINDINGS_OUTPUT
#     point at scratch dir (no live-host writes)
#   - HOME unchanged: architect-triage.sh sources lib/findings.sh +
#     lib/manifest.sh + lib/dates.sh from live $HOME/.claude/. Sourcing is
#     read-only — no write coupling. (Same precedent as
#     synthetic-architect-triage-ar-prefix.sh.)
#
# Per archetype, asserts:
#   1. exit 0 (no triage-time error)
#   2. recommendations[] populated to 3 in post-run manifest
#   3. all 3 IDs match `^AR-\d{3}$`
#   4. no `architect-legacy-prefix-skipped` advisory finding (pure-AR-NNN run)
#
# Bash 3.2 compatible (R-23). jq + python3 required. Uses mktemp -d for
# scratch (no $DOGFOOD_ROOT — single-purpose tmp tree, no nested test
# vault structure).
#
# Usage: bash triage-runtime.sh
# Exit:  0 on 12/12 pass (4 cases × 3 archetypes), 1 otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKELETON="$ROOT/templates/librarian-manifest-skeleton.json"
CAP="$ROOT/skills/librarian/capabilities/architect-triage.sh"

ARCHETYPES="consultant developer writer"

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
  printf 'triage-runtime.sh: jq not on PATH\n' >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'triage-runtime.sh: python3 not on PATH\n' >&2
  exit 2
fi
if [ ! -f "$SKELETON" ]; then
  printf 'triage-runtime.sh: skeleton missing: %s\n' "$SKELETON" >&2
  exit 2
fi
if [ ! -f "$CAP" ]; then
  printf 'triage-runtime.sh: architect-triage.sh missing: %s\n' "$CAP" >&2
  exit 2
fi

# Scratch dir + cleanup trap (per-run, not per-archetype — a single tmp tree
# with per-archetype subdirs. trap fires on EXIT INT TERM)
TMP=$(mktemp -d -t arch-fix-runtime-XXXXXX)
cleanup() {
  case "${TMP:-}" in
    /tmp/arch-fix-runtime-*|/var/folders/*/T/arch-fix-runtime-*)
      rm -rf -- "$TMP"
      ;;
    *)
      printf 'triage-runtime.sh WARN: refusing to rm %s (outside /tmp or /var/folders)\n' \
        "${TMP:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT INT TERM

# Generate per-archetype synthetic 3-rec [AR-NNN] report.
# Same shape as synthetic-architect-triage-ar-prefix.sh Test A.
write_synthetic_report() {
  local archetype="$1"
  local out="$2"
  local today
  today=$(date -u +%Y-%m-%d)
  cat > "$out" <<EOF
---
type: architect-report
date: $today
archetype: $archetype
---

## Recommendations

**[AR-001] First Recommendation for $archetype**
**Category:** quick-win
**Confidence:** high

**[AR-002] Second Recommendation for $archetype**
**Category:** structural
**Confidence:** medium

**[AR-003] Third Recommendation for $archetype**
**Category:** exploratory
**Confidence:** low
EOF
}

count_recs() {
  python3 -c "
import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(len(d.get('architect_recommendations', {}).get('recommendations', [])))
except Exception as e:
    print('PARSE_ERR:'+str(e))
" "$1"
}

count_ar_ids() {
  python3 -c "
import json,re,sys
try:
    d = json.load(open(sys.argv[1]))
    recs = d.get('architect_recommendations', {}).get('recommendations', [])
    print(sum(1 for r in recs if re.match(r'^AR-\d{3}\$', r.get('id', ''))))
except Exception as e:
    print('PARSE_ERR:'+str(e))
" "$1"
}

run_archetype() {
  local arch="$1"
  printf '\n=== archetype: %s ===\n' "$arch"

  local scratch="$TMP/$arch"
  mkdir -p "$scratch/logs" "$scratch/manifest"

  # Materialize per-archetype librarian-manifest from skeleton template.
  cp "$SKELETON" "$scratch/manifest/librarian-manifest.json"

  # Synthesize 3-rec [AR-NNN] report.
  write_synthetic_report "$arch" "$scratch/logs/architect-2026-04-30.md"

  # Empty backlog (no dedupe pre-population).
  local backlog="$scratch/System Backlog.md"
  printf '' > "$backlog"

  local findings="$scratch/findings.ndjson"
  local out="$scratch/out.txt"

  # Invoke architect-triage.sh with hermetic env (per-archetype scratch).
  ARCHITECT_LOGS_GLOB="$scratch/logs/architect-*.md" \
  SYSTEM_BACKLOG_PATH="$backlog" \
  MANIFEST_PATH="$scratch/manifest/librarian-manifest.json" \
  FINDINGS_OUTPUT="$findings" \
  bash "$CAP" --check > "$out" 2>&1
  local rc=$?

  # Case 1: exit 0
  if [ "$rc" = "0" ]; then
    assert_pass "[$arch] triage-exit-zero"
  else
    assert_fail "[$arch] triage-exit-zero" "exit=$rc; output: $(cat "$out")"
  fi

  # Case 2: 3 recommendations populated
  local rec_count
  rec_count=$(count_recs "$scratch/manifest/librarian-manifest.json")
  if [ "$rec_count" = "3" ]; then
    assert_pass "[$arch] recommendations-count-3"
  else
    assert_fail "[$arch] recommendations-count-3" "got: $rec_count"
  fi

  # Case 3: all 3 IDs match AR-NNN
  local ar_count
  ar_count=$(count_ar_ids "$scratch/manifest/librarian-manifest.json")
  if [ "$ar_count" = "3" ]; then
    assert_pass "[$arch] all-ids-match-AR-regex"
  else
    assert_fail "[$arch] all-ids-match-AR-regex" "got: $ar_count"
  fi

  # Case 4: no architect-legacy-prefix-skipped advisory (pure-AR-NNN run)
  if [ -f "$findings" ] && grep -q "architect-legacy-prefix-skipped" "$findings"; then
    assert_fail "[$arch] no-spurious-legacy-advisory" "advisory leaked: $(cat "$findings")"
  else
    assert_pass "[$arch] no-spurious-legacy-advisory"
  fi
}

for arch in $ARCHETYPES; do
  run_archetype "$arch"
done

printf '\n=== T-5 triage-runtime summary ===\n'
printf 'PASS: %d / %d\n' "$PASS" "$TESTS"
printf 'FAIL: %d\n' "$FAIL"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
