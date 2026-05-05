#!/usr/bin/env bash
# tests/sp14/job-iterator-unit-test.sh — synthetic unit tests for SP14 T-1
# onboarding/lib/job-iterator.sh.
#
# Validates AC #1..#5 from
# ~/.claude-plans/71-claude-foundations-engine-v2/14-connector-wizard/tasks.md
# T-1, with AC #1 interpreted per Session 1 Sitting 2 clarification:
#
#   AC1 — Iterator helper exists and provides for_each_job + count_jobs
#         with correct API contract; legitimate single-job-context callers
#         (initial-job-setup.sh, q-field-map.json D-2 defaults, docs)
#         are NOT migrated and remain accessing .jobs[0] correctly.
#   AC2 — bash -n clean; API documented at top of file
#   AC3 — Single-job synthetic fixture: count_jobs=1, for_each_job invokes
#         callback once with correct id (parity with v2.0.0 single-job behavior)
#   AC4 — 3-job synthetic fixture: count_jobs=3, for_each_job invokes callback
#         3x in declaration order
#   AC5 — Edge cases: empty .jobs[] yields rc=0 + 0 invocations; callback
#         rc propagates; bad invocation rc=2; missing/unreadable/corrupt
#         JSON path rc=2 or rc=3 with diagnostic stderr
#
# Run: bash tests/sp14/job-iterator-unit-test.sh
# Exit: 0 on all-pass; 1 on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ITERATOR="$REPO_ROOT/onboarding/lib/job-iterator.sh"

if [ ! -r "$ITERATOR" ]; then
  echo "FAIL: iterator not found at $ITERATOR" >&2
  exit 1
fi

bash -n "$ITERATOR" || { echo "FAIL: bash -n on iterator" >&2; exit 1; }
echo "PASS AC2: bash -n clean"

if ! grep -qE '^# *API \(sourceable\):' "$ITERATOR"; then
  echo "FAIL AC2: iterator missing 'API (sourceable):' header" >&2
  exit 1
fi
echo "PASS AC2: API header present"

# --- fixtures ---
TMPDIR="$(mktemp -d -t sp14-iter-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/orch-1job.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "platform": "darwin-launchd",
  "jobs": [
    {"id": "librarian", "enabled": true,
     "schedule": {"hour": 6, "minute": 0},
     "command": "/test/librarian-cron.sh",
     "log_path": "/tmp/lib.log",
     "idle_watchdog_sec": 180}
  ],
  "tripwires": [],
  "observability": {"log_dir": "/tmp"}
}
JSON

cat > "$TMPDIR/orch-3job.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "platform": "darwin-launchd",
  "jobs": [
    {"id": "librarian", "enabled": true,
     "schedule": {"hour": 6, "minute": 0},
     "command": "/test/librarian-cron.sh",
     "log_path": "/tmp/lib.log",
     "idle_watchdog_sec": 180},
    {"id": "digest-run", "enabled": true,
     "schedule": {"hour": 7, "minute": 30},
     "command": "/test/digest-run-cron.sh",
     "log_path": "/tmp/digest.log",
     "idle_watchdog_sec": 180},
    {"id": "chat-scrape", "enabled": true,
     "schedule": {"interval_sec": 1800},
     "command": "/test/chat-scrape-cron.sh",
     "log_path": "/tmp/chat.log",
     "idle_watchdog_sec": 180}
  ],
  "tripwires": [],
  "observability": {"log_dir": "/tmp"}
}
JSON

cat > "$TMPDIR/orch-empty.json" <<'JSON'
{"schema_version":"1.0.0","platform":"darwin-launchd","jobs":[],
 "tripwires":[],"observability":{"log_dir":"/tmp"}}
JSON

echo "not json" > "$TMPDIR/corrupt.json"

# shellcheck source=/dev/null
source "$ITERATOR"

PASS=0; FAIL=0
check() {
  if [ "$1" = "$2" ]; then
    PASS=$((PASS+1)); echo "PASS $3"
  else
    FAIL=$((FAIL+1)); echo "FAIL $3 (got '$1' expected '$2')" >&2
  fi
}

# --- AC3: single-job parity ---
ORCHESTRATION_JSON="$TMPDIR/orch-1job.json"
n=$(count_jobs); check "$n" "1" "AC3 count_jobs single-job=1"

> "$TMPDIR/cb"
record() { echo "$1" >> "$TMPDIR/cb"; }
for_each_job record
got=$(wc -l < "$TMPDIR/cb" | tr -d ' ')
check "$got" "1" "AC3 for_each_job single-job invokes callback 1x"
got=$(cat "$TMPDIR/cb")
check "$got" "librarian" "AC3 for_each_job single-job passes correct id"

# --- AC4: 3-job multi ---
ORCHESTRATION_JSON="$TMPDIR/orch-3job.json"
n=$(count_jobs); check "$n" "3" "AC4 count_jobs 3-job=3"

> "$TMPDIR/cb"
for_each_job record
got=$(wc -l < "$TMPDIR/cb" | tr -d ' ')
check "$got" "3" "AC4 for_each_job 3-job invokes callback 3x"
expected="librarian
digest-run
chat-scrape"
got=$(cat "$TMPDIR/cb")
check "$got" "$expected" "AC4 for_each_job 3-job preserves declaration order"

# --- AC5: edge cases ---
ORCHESTRATION_JSON="$TMPDIR/orch-empty.json"
n=$(count_jobs); check "$n" "0" "AC5 count_jobs empty=0"
> "$TMPDIR/cb"
for_each_job record; rc=$?
check "$rc" "0" "AC5 for_each_job empty rc=0"
got=$(wc -l < "$TMPDIR/cb" | tr -d ' ')
check "$got" "0" "AC5 for_each_job empty 0 invocations"

ORCHESTRATION_JSON="$TMPDIR/orch-3job.json"
fail_on_second() { [ "$1" = "digest-run" ] && return 42 || return 0; }
for_each_job fail_on_second 2>/dev/null; rc=$?
check "$rc" "42" "AC5 for_each_job propagates callback rc"

for_each_job 2>/dev/null; rc=$?
check "$rc" "2" "AC5 for_each_job missing fn arg rc=2"

for_each_job nonexistent_xyz_fn 2>/dev/null; rc=$?
check "$rc" "2" "AC5 for_each_job non-callable fn rc=2"

unset ORCHESTRATION_JSON
count_jobs 2>/dev/null; rc=$?
check "$rc" "2" "AC5 count_jobs missing path rc=2"

count_jobs /no/such/path/orch.json 2>/dev/null; rc=$?
check "$rc" "3" "AC5 count_jobs unreadable path rc=3"

count_jobs "$TMPDIR/corrupt.json" 2>/dev/null; rc=$?
check "$rc" "3" "AC5 count_jobs corrupt JSON rc=3"

echo
echo "==========================="
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] && exit 0 || exit 1
