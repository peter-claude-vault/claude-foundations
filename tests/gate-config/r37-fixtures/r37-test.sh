#!/bin/bash
# r37-test.sh — Plan 80/81 SP01 T-18 fixture suite for R-37 G2 enforcement.
#
# Acceptance per spec L406-407 + tasks.md T-18:
#   (1) partial-set rejection — staged ⊊ set → REJECT with explicit missed-paths
#   (2) full-set acceptance — staged ⊇ set → ACCEPT
#   (3) sentinel override — `.allow-r37-partial` + partial set → ACCEPT + audit
#   (4) shadow-mode warn — warn-mode produces same VIOLATION row, exit 0
#
# Plus assertions on audit row schema (rule:R-37, schema_version:1, set_name,
# missed, matched) and glob-pattern handling for sp07's `tests/sp07/*-unit-test.sh`.
#
# Usage: ./r37-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION_REPO="${FOUNDATION_REPO_OVERRIDE:-$HOME/Code/claude-stem}"
HOOK="$FOUNDATION_REPO/git-hooks/pre-commit-r37.sh"
GATE_CONFIG="$FOUNDATION_REPO/schemas/gate-config.json"

[[ ! -x "$HOOK" ]] && { echo "FAIL: hook not executable at $HOOK" >&2; exit 1; }
[[ ! -f "$GATE_CONFIG" ]] && { echo "FAIL: gate-config not found at $GATE_CONFIG" >&2; exit 1; }

PASS=0
FAIL=0

assert() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    # uncomment for verbose: echo "  ✓ $label"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $label" >&2
    echo "    expected: $expected" >&2
    echo "    actual:   $actual" >&2
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $label (missing substring)" >&2
    echo "    needle:   $needle" >&2
    echo "    haystack: $(echo "$haystack" | head -3)" >&2
  fi
}

# === Per-test sandbox =====================================================
make_sandbox() {
  TEST_DIR=$(mktemp -d -t r37-fixture-XXXXXX)
  HOOKS_STATE="$TEST_DIR/hooks-state"
  mkdir -p "$HOOKS_STATE"
  REPO="$TEST_DIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email "test@example.com" >/dev/null
  git -C "$REPO" config user.name  "test" >/dev/null
  AUDIT_LOG="$HOOKS_STATE/gate-decisions.log"
}

cleanup() {
  rm -rf "$TEST_DIR"
}

run_hook() {
  # run_hook <enforcement-mode-or-empty> <staged-files-multiline>
  # Standard env wiring per pre-commit-harness-validated.sh contract.
  local enforcement="$1" staged="$2"
  cd "$REPO"
  HOOKS_STATE_OVERRIDE="$HOOKS_STATE" \
  GATE_CONFIG_PATH="$GATE_CONFIG" \
  FOUNDATION_REPO_OVERRIDE="$FOUNDATION_REPO" \
  PRE_COMMIT_STAGED_OVERRIDE="$staged" \
  R37_ENFORCEMENT_OVERRIDE="$enforcement" \
  "$HOOK"
}

# Ground truth: gate-config's vault-schema-add set has 4 paths
VAULT_SCHEMA_FULL=(
  "schemas/vault-schema.json"
  "hooks/pre-write-guard.sh"
  "hooks/post-write-verify.sh"
  "CLAUDE.md"
)

# ============================================================================
# TEST 1 — partial-set rejection (deny mode)
#   Stage only 2/4 paths from vault-schema-add → expect rc=1 + violation
# ============================================================================
echo "[T1] partial-set rejection (deny mode)"
make_sandbox
STAGED=$'schemas/vault-schema.json\nhooks/pre-write-guard.sh'
out=$(run_hook "deny" "$STAGED" 2>&1)
rc=$?
cleanup

assert "T1.1 rc=1 (rejected)" "$rc" "1"
assert_contains "T1.2 stderr names set" "$out" "vault-schema-add"
assert_contains "T1.3 stderr lists missed paths" "$out" "post-write-verify.sh"
assert_contains "T1.4 stderr lists missed paths (CLAUDE.md)" "$out" "CLAUDE.md"
assert_contains "T1.5 stderr explains R-37 contract" "$out" "lockstep"
assert_contains "T1.6 stderr offers override path" "$out" ".allow-r37-partial"

# ============================================================================
# TEST 2 — full-set acceptance
#   Stage 4/4 paths from vault-schema-add → expect rc=0 + audit "allow" row
# ============================================================================
echo "[T2] full-set acceptance"
# CLAUDE.md is in BOTH vault-schema-add AND enforcement-map-row sets; staging
# enforcement-map.md too prevents an enforcement-map-row partial false-positive
# from co-firing alongside the vault-schema-add full-set acceptance.
make_sandbox
STAGED=$'schemas/vault-schema.json\nhooks/pre-write-guard.sh\nhooks/post-write-verify.sh\nCLAUDE.md\nenforcement-map.md'
out=$(run_hook "deny" "$STAGED" 2>&1)
rc=$?

assert "T2.1 rc=0 (accepted)" "$rc" "0"

# Audit log should carry "allow" rows with reason=r37-full-set-commit (2 expected:
# vault-schema-add + enforcement-map-row both full)
allow_rows=$(grep -c '"reason":"r37-full-set-commit"' "$AUDIT_LOG" 2>/dev/null || echo 0)
assert "T2.2 audit rows reason=r37-full-set-commit (2 sets)" "$allow_rows" "2"

vault_set_present=$(jq -r 'select(.reason == "r37-full-set-commit" and .set_name == "vault-schema-add") | .decision' "$AUDIT_LOG" 2>/dev/null | head -1)
assert "T2.3 vault-schema-add set logged decision=allow" "$vault_set_present" "allow"

emap_set_present=$(jq -r 'select(.reason == "r37-full-set-commit" and .set_name == "enforcement-map-row") | .decision' "$AUDIT_LOG" 2>/dev/null | head -1)
assert "T2.4 enforcement-map-row set logged decision=allow" "$emap_set_present" "allow"

cleanup

# ============================================================================
# TEST 3 — sentinel override
#   Partial set + sentinel `.allow-r37-partial` → rc=0 + audit "sentinel-override"
# ============================================================================
echo "[T3] sentinel override"
make_sandbox
touch "$REPO/.allow-r37-partial"
STAGED=$'schemas/vault-schema.json'
out=$(run_hook "deny" "$STAGED" 2>&1)
rc=$?

assert "T3.1 rc=0 (override)" "$rc" "0"
assert_contains "T3.2 stderr acknowledges sentinel" "$out" ".allow-r37-partial"

override_decision=$(jq -r 'select(.reason | test("sentinel-override")) | .decision' "$AUDIT_LOG" 2>/dev/null)
assert "T3.3 audit row decision=allow" "$override_decision" "allow"

override_reason=$(jq -r 'select(.reason | test("sentinel-override")) | .reason' "$AUDIT_LOG" 2>/dev/null)
assert_contains "T3.4 audit row reason names sentinel" "$override_reason" "sentinel-override-via-.allow-r37-partial"
cleanup

# ============================================================================
# TEST 4 — shadow-mode warn (decision-equivalent to deny but exit 0)
#   Same partial-set input as T1; warn-mode → rc=0 + audit "warn" row with same fields
# ============================================================================
echo "[T4] shadow-mode warn-only equivalence"
make_sandbox
STAGED=$'schemas/vault-schema.json\nhooks/pre-write-guard.sh'
out=$(run_hook "warn" "$STAGED" 2>&1)
rc=$?

assert "T4.1 rc=0 (warn-mode never blocks)" "$rc" "0"
assert_contains "T4.2 stderr still emits findings" "$out" "vault-schema-add"
assert_contains "T4.3 stderr advisory marker present" "$out" "advisory only"

warn_row=$(jq -c 'select(.decision == "warn" and .reason == "r37-partial-set-commit")' "$AUDIT_LOG" 2>/dev/null | head -1)
assert "T4.4 audit row decision=warn present" "$([[ -n $warn_row ]] && echo yes || echo no)" "yes"

# Critical decision-equivalence: warn-mode row carries SAME set_name + missed + matched as a
# deny-mode row would have. We compare against fields directly.
warn_set_name=$(jq -r 'select(.decision == "warn") | .set_name' "$AUDIT_LOG" | head -1)
assert "T4.5 warn row set_name == deny row set_name" "$warn_set_name" "vault-schema-add"

warn_rule=$(jq -r 'select(.decision == "warn") | .rule' "$AUDIT_LOG" | head -1)
assert "T4.6 warn row rule=R-37" "$warn_rule" "R-37"

warn_schema=$(jq -r 'select(.decision == "warn") | .schema_version' "$AUDIT_LOG" | head -1)
assert "T4.7 warn row schema_version=1" "$warn_schema" "1"

warn_missed=$(jq -r 'select(.decision == "warn") | .missed' "$AUDIT_LOG" | head -1)
assert_contains "T4.8 warn row missed includes post-write-verify.sh" "$warn_missed" "post-write-verify.sh"
assert_contains "T4.9 warn row missed includes CLAUDE.md" "$warn_missed" "CLAUDE.md"
cleanup

# ============================================================================
# TEST 5 — glob-pattern handling for sp07's `tests/sp07/*-unit-test.sh`
#   Stage tests/sp07/foo-unit-test.sh + 1 other connector path → partial detected
# ============================================================================
echo "[T5] glob-pattern handling (sp07 set)"
make_sandbox
STAGED=$'schemas/user-manifest-schema.json\ntests/sp07/foo-unit-test.sh'
out=$(run_hook "deny" "$STAGED" 2>&1)
rc=$?

assert "T5.1 rc=1 (rejected partial connector set)" "$rc" "1"
assert_contains "T5.2 stderr names connector-schema-add" "$out" "connector-schema-add"
assert_contains "T5.3 missed includes connectors-runtime-schema" "$out" "connectors-runtime-schema.json"
assert_contains "T5.4 missed includes beat-5-brief" "$out" "beat-5-brief.sh"

# Verify glob actually matched the staged tests/sp07/ path (the matched array
# should record the *pattern*, not the staged path — but the matched_str
# should not be empty)
sp07_matched=$(jq -r 'select(.set_name == "connector-schema-add" and .decision != "allow") | .matched' "$AUDIT_LOG" | head -1)
assert_contains "T5.5 audit matched includes sp07 glob pattern" "$sp07_matched" "tests/sp07"
cleanup

# ============================================================================
# TEST 6 — non-triggering staged set (untouched coupled set)
#   Stage files outside ALL coupled sets → rc=0 + no partial findings
# ============================================================================
echo "[T6] non-triggering staged set"
make_sandbox
STAGED=$'README.md\nrandom-other-file.txt'
out=$(run_hook "deny" "$STAGED" 2>&1)
rc=$?

assert "T6.1 rc=0 (no coupled set triggered)" "$rc" "0"

partial_rows=$(grep -c '"reason":"r37-partial-set-commit"' "$AUDIT_LOG" 2>/dev/null || echo 0)
assert "T6.2 no partial-set audit rows" "$partial_rows" "0"
cleanup

# ============================================================================
# TEST 7 — config-driven disable
#   R37_ENFORCEMENT_OVERRIDE=dryrun + partial set → rc=0 + warn-row written
# ============================================================================
echo "[T7] dryrun mode"
make_sandbox
STAGED=$'schemas/vault-schema.json\nhooks/pre-write-guard.sh'
out=$(run_hook "dryrun" "$STAGED" 2>&1)
rc=$?

assert "T7.1 rc=0 (dryrun never blocks)" "$rc" "0"
assert_contains "T7.2 stderr advisory marker present" "$out" "advisory only"

dryrun_row=$(jq -c 'select(.decision == "warn" and .reason == "r37-partial-set-commit")' "$AUDIT_LOG" | head -1)
assert "T7.3 dryrun emits warn row (decoupled from match_action)" "$([[ -n $dryrun_row ]] && echo yes || echo no)" "yes"
cleanup

# ============================================================================
# TEST 8 — JSONL discipline (one row per emitted decision)
#   Run through scenario producing 1 "warn" + 1 "allow" row → 2 lines
#   Setup: stage full vault-schema-add (allow) AND partial connector-schema-add (warn)
# ============================================================================
echo "[T8] JSONL discipline"
make_sandbox
STAGED=$'schemas/vault-schema.json\nhooks/pre-write-guard.sh\nhooks/post-write-verify.sh\nCLAUDE.md\nschemas/user-manifest-schema.json'
out=$(run_hook "warn" "$STAGED" 2>&1)
rc=$?

assert "T8.1 rc=0 (warn mode)" "$rc" "0"

total_rows=$(wc -l < "$AUDIT_LOG" | tr -d ' ')
# Expect: vault-schema-add (allow full-set) + connector-schema-add (warn partial) + maybe enforcement-map-row touched if README.md or CLAUDE.md hit it.
# enforcement-map-row paths are [enforcement-map.md, CLAUDE.md] — CLAUDE.md staged → 1/2 = partial.
# So expect 3 rows: full-allow + partial-warn + partial-warn.
assert "T8.2 audit rows match emitted decisions (3 expected)" "$total_rows" "3"

# Each row valid JSON
parse_failures=0
while IFS= read -r row; do
  jq -e . <<< "$row" >/dev/null 2>&1 || parse_failures=$((parse_failures + 1))
done < "$AUDIT_LOG"
assert "T8.3 every audit row is valid JSON" "$parse_failures" "0"

# Every row has rule=R-37 and schema_version=1
rule_distinct=$(jq -sc 'map(.rule) | unique' "$AUDIT_LOG" 2>/dev/null)
assert "T8.4 every row carries rule=R-37" "$rule_distinct" '["R-37"]'

schema_distinct=$(jq -sc 'map(.schema_version) | unique' "$AUDIT_LOG" 2>/dev/null)
assert "T8.5 every row carries schema_version=1" "$schema_distinct" '[1]'
cleanup

# ============================================================================
# Summary
# ============================================================================
TOTAL=$((PASS + FAIL))
echo ""
echo "=========================================="
echo "R-37 fixture suite (T-18): $PASS/$TOTAL PASS"
echo "=========================================="
if (( FAIL > 0 )); then
  echo "FAIL count: $FAIL" >&2
  exit 1
fi
echo "PASS"
exit 0
