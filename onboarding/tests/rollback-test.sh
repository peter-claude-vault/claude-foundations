#!/usr/bin/env bash
# rollback-test.sh — SP01 T-15 failure-path battery for bootstrap-schemas.sh
#
# Exercises the BLOCK_AND_LOG path with 4 broken-input variants:
#   1. Invalid JSON in extraction-output-B.json
#   2. Valid JSON but missing section_id
#   3. Valid JSON with wrong section_id ("X" instead of "B")
#   4. populated field is a string instead of an object
# Plus recovery validation (engine carries no residual state after failures).
#
# bash 3.2 compatible (R-23). No declare -A / mapfile / readarray.
# jq required on PATH.

set -u

SBX="/tmp/rollback-test-sbx-$$"
SCHEMAS_SRC="${HOME}/.claude/schemas"
ONBOARDING_SRC="${HOME}/.claude/onboarding"

pass=0
fail=0

trap 'rm -rf "$SBX"' EXIT

# ------------------------------------------------------------------ counters

record_pass() {
  pass=$((pass + 1))
  printf '  ok   %s\n' "$1"
}

record_fail() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
  printf '       expected: %s\n' "$2"
  printf '       actual:   %s\n' "$3"
}

assert_eq() {
  if [ "$2" = "$3" ]; then
    record_pass "$1"
  else
    record_fail "$1" "$2" "$3"
  fi
}

# ------------------------------------------------------------------ sandbox

mkdir -p "$SBX/home/.claude/schemas"
mkdir -p "$SBX/home/.claude/onboarding"

cp "$SCHEMAS_SRC/user-manifest-schema.json" "$SBX/home/.claude/schemas/"
cp "$SCHEMAS_SRC/orchestration-schema.json" "$SBX/home/.claude/schemas/"
cp "$SCHEMAS_SRC/vault-schema.json"         "$SBX/home/.claude/schemas/"
cp "$SCHEMAS_SRC/plans-schema.json"         "$SBX/home/.claude/schemas/"
cp "$ONBOARDING_SRC/q-field-map.json"       "$SBX/home/.claude/onboarding/"
cp "$ONBOARDING_SRC/bootstrap-schemas.sh"   "$SBX/home/.claude/onboarding/"
chmod +x "$SBX/home/.claude/onboarding/bootstrap-schemas.sh"

BOOTSTRAP="$SBX/home/.claude/onboarding/bootstrap-schemas.sh"
AUDIT_LOG="$SBX/home/.claude/onboarding/bootstrap-log.jsonl"

# Minimal valid extraction outputs — industry-neutral synthetic content.
# A and E: empty populated (no fields to wire for these sections in this fixture).
# B, C, D: one populated field each to exercise the populate path.
write_valid_inputs() {
  printf '%s' '{"section_id":"A","populated":{},"confidence":{},"source_spans":{}}' \
    > "$SBX/home/.claude/onboarding/extraction-output-A.json"

  cat > "$SBX/home/.claude/onboarding/extraction-output-B.json" <<'BEOF'
{
  "section_id": "B",
  "populated": {
    "U.identity.role": "senior-engineer",
    "U.identity.industry": "technology"
  },
  "confidence": {
    "U.identity.role": 0.95,
    "U.identity.industry": 0.85
  },
  "source_spans": {
    "U.identity.role": "section-b line 12",
    "U.identity.industry": "section-b line 12"
  }
}
BEOF

  cat > "$SBX/home/.claude/onboarding/extraction-output-C.json" <<'CEOF'
{
  "section_id": "C",
  "populated": {
    "U.vault.is_fresh": true
  },
  "confidence": {
    "U.vault.is_fresh": 0.9
  },
  "source_spans": {
    "U.vault.is_fresh": "section-c line 28"
  }
}
CEOF

  cat > "$SBX/home/.claude/onboarding/extraction-output-D.json" <<'DEOF'
{
  "section_id": "D",
  "populated": {
    "U.behavioral.autonomy": "balanced"
  },
  "confidence": {
    "U.behavioral.autonomy": 0.88
  },
  "source_spans": {
    "U.behavioral.autonomy": "section-d line 41"
  }
}
DEOF

  printf '%s' '{"section_id":"E","populated":{},"confidence":{},"source_spans":{}}' \
    > "$SBX/home/.claude/onboarding/extraction-output-E.json"
}

# ------------------------------------------------------------------ helpers

md5_file() {
  md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | cut -d' ' -f1 || echo "MISSING"
}

# Snapshot MD5s of all 4 live targets into SNAP_* variables.
snapshot_md5() {
  SNAP_PLANS="$(md5_file "$SBX/home/.claude/schemas/plans-schema.json")"
  SNAP_USER="$(md5_file "$SBX/home/.claude/user-manifest.json")"
  SNAP_VAULT="$(md5_file "$SBX/home/.claude/schemas/vault-schema.json")"
  SNAP_ORCH="$(md5_file "$SBX/home/.claude/orchestration.json")"
}

assert_md5_unchanged() {
  label="$1"
  assert_eq "$label: plans-schema MD5 unchanged" \
    "$SNAP_PLANS" "$(md5_file "$SBX/home/.claude/schemas/plans-schema.json")"
  assert_eq "$label: user-manifest MD5 unchanged" \
    "$SNAP_USER" "$(md5_file "$SBX/home/.claude/user-manifest.json")"
  assert_eq "$label: vault-schema MD5 unchanged" \
    "$SNAP_VAULT" "$(md5_file "$SBX/home/.claude/schemas/vault-schema.json")"
  assert_eq "$label: orchestration MD5 unchanged" \
    "$SNAP_ORCH" "$(md5_file "$SBX/home/.claude/orchestration.json")"
}

assert_no_residual_files() {
  label="$1"
  residual="$(find "$SBX/home/.claude" \( -name '*.tmp.*' -o -name '*.new' \) 2>/dev/null | grep -v '^$' || true)"
  if [ -z "$residual" ]; then
    record_pass "$label: no residual .tmp/.new files"
  else
    record_fail "$label: no residual .tmp/.new files" "(none)" "$residual"
  fi
}

assert_failed_event_added() {
  label="$1"
  prev_count="$2"
  new_count="$(grep '"BOOTSTRAP_FAILED"' "$AUDIT_LOG" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$new_count" -gt "$prev_count" ]; then
    record_pass "$label: BOOTSTRAP_FAILED event appended (total=$new_count)"
  else
    record_fail "$label: BOOTSTRAP_FAILED event appended" ">$prev_count" "$new_count"
  fi
}

# Run one failure test case. Caller must pre-install the broken extraction-output-B.json.
# Restores valid inputs before returning.
run_failure_case() {
  label="$1"
  prev_fail_count="$(grep '"BOOTSTRAP_FAILED"' "$AUDIT_LOG" 2>/dev/null | wc -l | tr -d ' ')"

  printf '\n=== %s ===\n' "$label"
  rc="$(HOME="$SBX/home" "$BOOTSTRAP" 2>/dev/null; echo $?)"

  assert_eq "$label: exit code 1 (block-and-log)" "1" "$rc"
  assert_failed_event_added "$label" "$prev_fail_count"
  assert_md5_unchanged "$label"
  assert_no_residual_files "$label"

  write_valid_inputs
}

# ------------------------------------------------------------------ baseline

printf '\n=== positive-control baseline ===\n'
write_valid_inputs
baseline_rc="$(HOME="$SBX/home" "$BOOTSTRAP" 2>/dev/null; echo $?)"
assert_eq "baseline: exit 0" "0" "$baseline_rc"
baseline_completed="$(grep '"BOOTSTRAP_COMPLETED"' "$AUDIT_LOG" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "baseline: BOOTSTRAP_COMPLETED in audit log" "1" "$baseline_completed"
snapshot_md5

# ------------------------------------------------------------------ test 1: invalid JSON

printf '{ this is not valid json' > "$SBX/home/.claude/onboarding/extraction-output-B.json"
run_failure_case "test-1 invalid-json-B"

# ------------------------------------------------------------------ test 2: missing section_id

printf '%s' '{"populated":{},"confidence":{},"source_spans":{}}' \
  > "$SBX/home/.claude/onboarding/extraction-output-B.json"
run_failure_case "test-2 missing-section-id"

# ------------------------------------------------------------------ test 3: wrong section_id

printf '%s' '{"section_id":"X","populated":{},"confidence":{},"source_spans":{}}' \
  > "$SBX/home/.claude/onboarding/extraction-output-B.json"
run_failure_case "test-3 wrong-section-id"

# ------------------------------------------------------------------ test 4: populated wrong type

printf '%s' '{"section_id":"B","populated":"not-an-object","confidence":{},"source_spans":{}}' \
  > "$SBX/home/.claude/onboarding/extraction-output-B.json"
run_failure_case "test-4 populated-wrong-type"

# ------------------------------------------------------------------ recovery

printf '\n=== recovery validation ===\n'
write_valid_inputs
recovery_rc="$(HOME="$SBX/home" "$BOOTSTRAP" 2>/dev/null; echo $?)"
assert_eq "recovery: exit 0" "0" "$recovery_rc"
recovery_completed="$(grep '"BOOTSTRAP_COMPLETED"' "$AUDIT_LOG" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "recovery: BOOTSTRAP_COMPLETED in audit log (2nd event)" "2" "$recovery_completed"
total_failed="$(grep '"BOOTSTRAP_FAILED"' "$AUDIT_LOG" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$total_failed" -ge 4 ]; then
  record_pass "recovery: at least 4 BOOTSTRAP_FAILED events accumulated (total=$total_failed)"
else
  record_fail "recovery: at least 4 BOOTSTRAP_FAILED events accumulated" ">=4" "$total_failed"
fi

# ------------------------------------------------------------------ summary

printf '\n'
printf '%s\n' '----------------------------------'
printf 'passed: %s\n' "$pass"
printf 'failed: %s\n' "$fail"
printf '%s\n' '----------------------------------'

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
