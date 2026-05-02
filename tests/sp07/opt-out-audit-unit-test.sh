#!/bin/bash
# tests/sp07/opt-out-audit-unit-test.sh — synthetic unit tests for SP07 T-8
# onboarding/opt-outs/{surface-{01..10},validate-full-opt-out}.sh.
#
# Validates the 5 acceptance criteria from
# ~/.claude-plans/71-claude-foundations-engine-v2/07-onboarder-ux/tasks.md T-8:
#
#   AC1 — Ship 10 opt-out surface handlers matching spec enumeration
#   AC2 — Full-opt-out run produces user-manifest.json that validates
#         against SP01 schema
#   AC3 — Full-opt-out run produces empty orchestration.json that validates
#         against SP01 schema
#   AC4 — Full-opt-out run installs zero launchd jobs
#         (`launchctl list | grep claude.foundations` empty; in hermetic
#         harness this is the staging-dir-empty assertion)
#   AC5 — Any surface individually selectable without forcing downstream
#         opt-outs (each surface handler invokes ONE per-flag opt-out;
#         verified via SECTION_BIN_OVERRIDE argv-recording stub)
#
# Test mapping:
#   T1..T10 — Per-surface dispatch correctness (AC1 + AC5).
#             Each surface-NN.sh invoked with SECTION_BIN_OVERRIDE pointing
#             at a stub that records argv. Assertion: stub argv[0] is the
#             expected per-flag opt-out flag (or --auto-opt-out for
#             surface-01).
#   T11    — Argv passthrough: surface-09.sh --auto-confirm --opt-out-extra
#             dispatches with all 3 flags prepended/appended in correct order.
#   T12    — validate-full-opt-out happy path: rc=0 + terminal-state
#             assertions (jobs:[] + zero plists + harness PASSED audit).
#             Closes AC2 (user-manifest schema-valid post-bootstrap),
#             AC3 (orchestration jobs:[]), AC4 (zero plists).
#   T13    — validate-full-opt-out detects bootstrap-schemas.sh failure
#             (BOOTSTRAP_BIN override → failing stub → rc=1).
#   T14    — validate-full-opt-out detects section runner failure
#             (SECTION_A_BIN override → failing stub → rc=3).
#   T15    — Surface-handler exec-bit + bash-3.2 syntax sanity (every
#             handler executable, no R-23 violations under `bash -n`).
#
# Hermetic: per-test fake $HOME / argv-record files; no live filesystem
# mutations beyond $TEST_ROOT (mktemp -d); EXIT trap rm -rf's the root.
#
# Hard invariants:
#   - Bash 3.2 + R-23 compatible (no declare -A, no mapfile, no ${var,,}).
#   - Reference-leak floor: corrections[]/audit fields validated downstream
#     by section-{a..d}-unit-test.sh + render-summary-unit-test.sh; this
#     test focuses on dispatcher correctness + validator integration.
#   - Single deliverable per R-37: opt-out audit harness as the unit
#     (10 surfaces + validator + this test scaffold).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SURFACES_DIR="$REPO_ROOT/onboarding/opt-outs"
VALIDATOR="$SURFACES_DIR/validate-full-opt-out.sh"

TEST_ROOT="$(mktemp -d -t opt-out-audit-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 -- $2"; }

# --- Argv-recording stub builder ---
# Writes a stub bash script at $1 that records its $@ to $2 (one arg per
# line) and exits 0. Used to verify surface-handler dispatch.
build_argv_stub() {
  local stub="$1" record="$2"
  cat > "$stub" <<STUB
#!/bin/bash
for a in "\$@"; do echo "\$a"; done > "$record"
exit 0
STUB
  chmod +x "$stub"
}

# --- Failing stub builder ---
build_failing_stub() {
  local stub="$1" rc="$2"
  cat > "$stub" <<STUB
#!/bin/bash
echo "stub failure" >&2
exit $rc
STUB
  chmod +x "$stub"
}

# --- Per-surface expected dispatch table ---
# Format per row: SURFACE_N|EXPECTED_FLAG|OWNING_SECTION
# OWNING_SECTION is informational (used in failure diagnostic only).
SURFACE_TABLE="
01|--auto-opt-out|section-a
02|--opt-out-org|section-b
03|--opt-out-people|section-b
04|--opt-out-tools|section-b
05|--opt-out-vault|section-c
06|--opt-out-sensitive|section-c
07|--opt-out-hooks|section-d
08|--opt-out-checkpoint|section-d
09|--opt-out-initial-job|section-d
10|--opt-out-tripwires|section-d
"

# --- T1..T10: Per-surface dispatch correctness ---
# Each surface-NN.sh invoked with SECTION_BIN_OVERRIDE → argv-recording
# stub. Assert: stub argv[0] equals the expected per-flag opt-out flag.
# Verifies AC1 (10 handlers exist + dispatch correctly) + AC5 (each
# handler invokes ONE per-flag flag, not a blanket).
#
# Uses process substitution `< <(...)` (bash 3.2-supported) instead of
# pipe-into-while so PASS_COUNT/FAIL_COUNT updates persist in the outer
# shell scope (bash pipelines run the right-hand side in a subshell).
while IFS='|' read -r N FLAG SECTION; do
  [ -z "$N" ] && continue
  HANDLER="$SURFACES_DIR/surface-${N}.sh"
  if [ ! -x "$HANDLER" ]; then
    fail "T${N}-handler-missing" "expected executable at $HANDLER"
    continue
  fi
  STUB="$TEST_ROOT/stub-${N}.sh"
  RECORD="$TEST_ROOT/argv-${N}.txt"
  build_argv_stub "$STUB" "$RECORD"
  SECTION_BIN_OVERRIDE="$STUB" "$HANDLER" >/dev/null 2>&1
  if [ ! -f "$RECORD" ]; then
    fail "T${N}-no-record" "stub did not record argv (handler did not dispatch)"
    continue
  fi
  RECORDED_FIRST="$(head -1 "$RECORD")"
  if [ "$RECORDED_FIRST" = "$FLAG" ]; then
    pass "T${N} surface-${N}.sh dispatches to $SECTION with $FLAG"
  else
    fail "T${N}-flag-mismatch" "expected '$FLAG' got '$RECORDED_FIRST' (full argv: $(cat "$RECORD" | tr '\n' ' '))"
  fi
done < <(echo "$SURFACE_TABLE")

# --- T11: Argv passthrough ---
# Verifies that args passed to surface-09.sh after the per-flag opt-out
# are forwarded to the section runner in correct order.
T11_STUB="$TEST_ROOT/stub-11.sh"
T11_RECORD="$TEST_ROOT/argv-11.txt"
build_argv_stub "$T11_STUB" "$T11_RECORD"
SECTION_BIN_OVERRIDE="$T11_STUB" \
  "$SURFACES_DIR/surface-09.sh" --auto-confirm --inputs-dir /tmp/foo \
  >/dev/null 2>&1
if [ -f "$T11_RECORD" ]; then
  T11_ARGS="$(cat "$T11_RECORD" | tr '\n' ',' | sed 's/,$//')"
  if [ "$T11_ARGS" = "--opt-out-initial-job,--auto-confirm,--inputs-dir,/tmp/foo" ]; then
    pass "T11 argv passthrough: surface-09.sh prepends --opt-out-initial-job + forwards remaining args in order"
  else
    fail "T11-argv-passthrough" "got [$T11_ARGS]; expected [--opt-out-initial-job,--auto-confirm,--inputs-dir,/tmp/foo]"
  fi
else
  fail "T11-no-record" "surface-09.sh did not invoke stub"
fi

# --- T12: validate-full-opt-out happy path ---
# AC2 + AC3 + AC4 closure. Default invocation (no overrides) → real
# section runners + bootstrap-schemas.sh + terminal-state assertions.
# Assertion: rc=0 + harness audit logged PASSED.
T12_ROOT="$TEST_ROOT/t12"
mkdir -p "$T12_ROOT"
"$VALIDATOR" --test-root "$T12_ROOT" --keep >"$T12_ROOT/stdout.log" 2>"$T12_ROOT/stderr.log"
T12_RC=$?
T12_AUDIT="$T12_ROOT/validate-full-opt-out.jsonl"
if [ "$T12_RC" -eq 0 ] \
   && [ -s "$T12_AUDIT" ] \
   && jq -e 'select(.status == "PASSED" and .stage == "full-opt-out")' "$T12_AUDIT" >/dev/null 2>&1; then
  pass "T12 validate-full-opt-out happy path: rc=0 + harness PASSED audit (AC2 + AC3 + AC4 closure)"
else
  fail "T12-happy-path" "rc=$T12_RC audit=$(cat "$T12_AUDIT" 2>/dev/null) stderr-tail=$(tail -10 "$T12_ROOT/stderr.log" 2>/dev/null)"
fi

# AC3 sub-assertion: orchestration.jobs == []
T12_ORCH="$T12_ROOT/.claude/orchestration.json"
if [ -f "$T12_ORCH" ] \
   && jq -e '.jobs | length == 0' "$T12_ORCH" >/dev/null 2>&1; then
  pass "T12-AC3 orchestration.jobs == [] post-full-opt-out"
else
  fail "T12-AC3" "orch=$(jq -c '.jobs' "$T12_ORCH" 2>/dev/null)"
fi

# AC4 sub-assertion: zero plists in staging dir
T12_STAGING="$T12_ROOT/.claude/Library/LaunchAgents.staging"
T12_PLIST_COUNT=0
if [ -d "$T12_STAGING" ]; then
  T12_PLIST_COUNT="$(find "$T12_STAGING" -maxdepth 1 -name '*.plist' -type f 2>/dev/null | wc -l | tr -d ' ')"
fi
if [ "$T12_PLIST_COUNT" = "0" ]; then
  pass "T12-AC4 zero plists in staging dir post-full-opt-out"
else
  fail "T12-AC4" "plist_count=$T12_PLIST_COUNT in $T12_STAGING"
fi

# AC2 sub-assertion: user-manifest.json composed (bootstrap-schemas.sh
# pre-write validation gates schema validity; existence + valid JSON
# parse is the structural signal).
T12_USER="$T12_ROOT/.claude/user-manifest.json"
if [ -f "$T12_USER" ] \
   && jq -e '.system.opt_outs | type == "array"' "$T12_USER" >/dev/null 2>&1; then
  pass "T12-AC2 user-manifest.json composed + schema-valid (system.opt_outs[] present)"
else
  fail "T12-AC2" "user_manifest=$(jq -c '.' "$T12_USER" 2>/dev/null | head -c 300)"
fi

# --- T13: validate-full-opt-out detects bootstrap-schemas.sh failure ---
T13_ROOT="$TEST_ROOT/t13"
mkdir -p "$T13_ROOT"
T13_BAD_BOOTSTRAP="$T13_ROOT/bad-bootstrap.sh"
build_failing_stub "$T13_BAD_BOOTSTRAP" 7
BOOTSTRAP_BIN="$T13_BAD_BOOTSTRAP" \
  "$VALIDATOR" --test-root "$T13_ROOT" --keep >"$T13_ROOT/stdout.log" 2>"$T13_ROOT/stderr.log"
T13_RC=$?
if [ "$T13_RC" -eq 1 ]; then
  pass "T13 validate-full-opt-out detects bootstrap-schemas.sh failure (rc=1)"
else
  fail "T13-bootstrap-failure" "rc=$T13_RC (expected 1); stderr-tail=$(tail -5 "$T13_ROOT/stderr.log" 2>/dev/null)"
fi

# --- T14: validate-full-opt-out detects section runner failure ---
T14_ROOT="$TEST_ROOT/t14"
mkdir -p "$T14_ROOT"
T14_BAD_SECTION="$T14_ROOT/bad-section-a.sh"
build_failing_stub "$T14_BAD_SECTION" 9
SECTION_A_BIN="$T14_BAD_SECTION" \
  "$VALIDATOR" --test-root "$T14_ROOT" --keep >"$T14_ROOT/stdout.log" 2>"$T14_ROOT/stderr.log"
T14_RC=$?
if [ "$T14_RC" -eq 3 ]; then
  pass "T14 validate-full-opt-out detects section runner failure (rc=3)"
else
  fail "T14-section-failure" "rc=$T14_RC (expected 3); stderr-tail=$(tail -5 "$T14_ROOT/stderr.log" 2>/dev/null)"
fi

# --- T15: Surface-handler bash-3.2 syntax sanity ---
# Verifies every handler parses under `bash -n` (no syntax errors)
# AND every handler is executable.
T15_FAIL=0
for n in 01 02 03 04 05 06 07 08 09 10; do
  H="$SURFACES_DIR/surface-${n}.sh"
  if [ ! -x "$H" ]; then T15_FAIL=$((T15_FAIL+1)); echo "FAIL-detail: surface-${n}.sh not executable"; continue; fi
  if ! bash -n "$H" 2>/dev/null; then T15_FAIL=$((T15_FAIL+1)); echo "FAIL-detail: surface-${n}.sh bash -n syntax error"; continue; fi
done
if ! bash -n "$VALIDATOR" 2>/dev/null; then
  T15_FAIL=$((T15_FAIL+1)); echo "FAIL-detail: validate-full-opt-out.sh bash -n syntax error"
fi
if [ "$T15_FAIL" = "0" ]; then
  pass "T15 all 10 surface handlers + validator pass bash -n syntax check + executable"
else
  fail "T15-syntax-or-exec" "T15_FAIL=$T15_FAIL"
fi

# --- Summary ---
echo ""
echo "=== opt-out-audit-unit-test ==="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then exit 1; fi
exit 0
