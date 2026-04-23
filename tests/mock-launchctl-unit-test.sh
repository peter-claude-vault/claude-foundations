#!/bin/bash
# tests/mock-launchctl-unit-test.sh
#
# Unit test for tests/mock-launchctl.sh and tests/plist-lint.sh. Exercises
# all exit code paths (0/3/4/5) plus the ndjson append-only invariant.
# Runs host-side or container-side; isolates state under $DOGFOOD_ROOT.
#
# Invocation: bash tests/mock-launchctl-unit-test.sh
#
# Exit codes:
#   0  all cases behave as expected
#   7  setup error (jq or python3 missing, helper files absent)
#   8  any case misbehaves (diagnostic on stderr)
#
# R-23: bash 3.2 compat.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./dogfood-root-helper.sh
. "${SCRIPT_DIR}/dogfood-root-helper.sh"

MOCK="${SCRIPT_DIR}/mock-launchctl.sh"
LINT="${SCRIPT_DIR}/plist-lint.sh"

for dep in jq python3; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    printf 'unit-test: %s required\n' "$dep" >&2; exit 7
  fi
done
for f in "$MOCK" "$LINT"; do
  [ -x "$f" ] || { printf 'unit-test: %s not executable\n' "$f" >&2; exit 7; }
done

export LAUNCHCTL_TRACE_DIR="${DOGFOOD_ROOT}/results"
TRACE="${LAUNCHCTL_TRACE_DIR}/launchctl-trace.ndjson"

VALID_PLIST="${DOGFOOD_ROOT}/com.claude-foundations.test.plist"
cat > "$VALID_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.claude-foundations.test</string>
    <key>ProgramArguments</key><array><string>/usr/bin/true</string></array>
</dict>
</plist>
PLIST

BAD_PLIST="${DOGFOOD_ROOT}/bad.plist"
printf 'not a plist\n' > "$BAD_PLIST"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; fails=$((fails+1)); }

assert_exit() {
  # $1=label $2=expected_exit $3...=cmd
  label="$1"; expected="$2"; shift 2
  "$@" </dev/null >/dev/null 2>&1
  actual=$?
  if [ "$actual" = "$expected" ]; then
    pass "${label} (exit=${actual})"
  else
    fail "${label}" "expected exit=${expected} got=${actual}"
  fi
}

# AC1 — bootstrap valid: trace + lint + exit 0
assert_exit 'AC1 bootstrap-valid' 0 "$MOCK" bootstrap gui/1000 "$VALID_PLIST"

# AC2 — lifecycle violation: second bootstrap without bootout
assert_exit 'AC2 double-bootstrap' 4 "$MOCK" bootstrap gui/1000 "$VALID_PLIST"

# AC2b — bootout clears state; subsequent bootstrap succeeds
assert_exit 'AC2b bootout-pair'   0 "$MOCK" bootout gui/1000/com.claude-foundations.test
assert_exit 'AC2c rebootstrap'    0 "$MOCK" bootstrap gui/1000 "$VALID_PLIST"

# AC3 — unknown verb
assert_exit 'AC3 unknown-verb'    3 "$MOCK" frobnicate

# Accepted verbs beyond bootstrap/bootout
assert_exit 'accepted print'      0 "$MOCK" print gui/1000
assert_exit 'accepted list'       0 "$MOCK" list
assert_exit 'accepted kickstart'  0 "$MOCK" kickstart gui/1000/com.foo

# AC5 — plist-lint rejects malformed, accepts valid
assert_exit 'AC5 bootstrap-bad-plist' 5 "$MOCK" bootstrap gui/1000 "$BAD_PLIST"
assert_exit 'AC5 lint-valid'          0 bash "$LINT" "$VALID_PLIST"
assert_exit 'AC5 lint-malformed'      2 bash "$LINT" "$BAD_PLIST"
assert_exit 'AC5 lint-missing'        1 bash "$LINT" "${DOGFOOD_ROOT}/nope.plist"

# AC4 — every trace line is valid JSON; file append-only (line count grows
# monotonically; we check >= number of mock invocations).
if [ ! -f "$TRACE" ]; then
  fail 'AC4 trace-exists' "trace file missing: $TRACE"
else
  total=0; bad=0
  while IFS= read -r line; do
    total=$((total+1))
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 || bad=$((bad+1))
  done < "$TRACE"
  if [ "$bad" -eq 0 ] && [ "$total" -ge 8 ]; then
    pass "AC4 trace-ndjson (lines=${total}, all valid JSON)"
  else
    fail 'AC4 trace-ndjson' "total=${total} bad=${bad} (expected >=8 valid lines)"
  fi
fi

# AC4b — append-only: a second bootout should APPEND a line, not truncate.
prev=$(wc -l < "$TRACE" | tr -d ' ')
"$MOCK" bootout gui/1000/com.claude-foundations.test </dev/null >/dev/null 2>&1
after=$(wc -l < "$TRACE" | tr -d ' ')
if [ "$after" -gt "$prev" ]; then
  pass "AC4b append-only (prev=${prev} after=${after})"
else
  fail 'AC4b append-only' "prev=${prev} after=${after}"
fi

printf '\n== Summary ==\n'
if [ "$fails" -gt 0 ]; then
  printf 'fails=%d\n' "$fails" >&2
  exit 8
fi
printf 'all cases PASS\n'
exit 0
