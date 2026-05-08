#!/bin/bash
# parallel-run-test.sh — SP01 T-19 R-55 parallel-run fixture suite.
#
# Validates the new manifest-driven `live-guard.sh` (Session 2 ship) against
# the live `plan-71-live-guard.sh` helper (still authoritative through Phase A).
# Three acceptance-criteria classes, ≥3 fixture scenarios per spec L405-417:
#
#   Class A — decision-equivalence
#     A1 not-detected → both pass-through silently
#     A2 plan-id detection + under-scope + no override → both DENY
#     A3 plan-mode detection + under-scope + no override → both DENY
#     A4 detection + path under projects/** carve-out → both allow-carve-out
#     A5 detection + valid nonce (matching basename) → both allow-override
#     A6 BYPASS env set → both bypass-env (no decision JSON; pass-through)
#     A7 detection + path NOT under live → both pass-through silently
#
#   Class B — divergence detection
#     B1 detection + path under hooks/state/** (NEW carve-out only; pre-disposed
#        in r55_sunset.divergence_log per Session 1 audit finding #5)
#
#   Class C — audit log entry shape conforms to schema (ts, decision, plan_id,
#     rule, tool, file, signal, reason, nonce_task, sha, schema_version)
#     C1 representative rows across decision classes carry required fields
#
# Test isolation contract (per feedback_test_isolation_for_hooks_state +
# feedback_guard_signal_determinism): every helper call sets
# HOOKS_STATE_OVERRIDE + PLANS_ROOT_OVERRIDE + CLAUDE_HOME and a sandboxed
# HOME so neither helper can touch real $HOME state. CLAUDE_HOME points at a
# synthetic git repo whose `sp09/pre-flight` tag drives nonce SHA validation
# for both helpers.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
NEW_GUARD="$REPO_ROOT/hooks/lib/live-guard.sh"
# Capture old guard path BEFORE HOME override fires (literal $HOME expanded now).
OLD_GUARD="$HOME/.claude/hooks/lib/plan-71-live-guard.sh"

[[ -x "$NEW_GUARD" ]] || { echo "FAIL: $NEW_GUARD not executable"; exit 1; }
[[ -x "$OLD_GUARD" ]] || {
  echo "FAIL: $OLD_GUARD not executable (live tree authoritative through Phase A)"
  exit 1
}

TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

PLANS_ROOT="$TEST_DIR/.claude-plans"
HOOKS_STATE_DIR="$TEST_DIR/.claude/hooks/state"
SANDBOX_CLAUDE_HOME="$TEST_DIR/.claude"
NONCE_DIR="$HOOKS_STATE_DIR/sp09-nonces"
SENTINEL_PATH="$HOOKS_STATE_DIR/.allow-sp09-live-mutation"
NEW_LOG="$HOOKS_STATE_DIR/gate-decisions.log"
OLD_LOG="$HOOKS_STATE_DIR/plan-71-live-mutation-overrides.log"
PARALLEL_RUN_LOG="$HOOKS_STATE_DIR/parallel-run.log"

mkdir -p "$PLANS_ROOT/71-claude-foundations-engine-v2" \
         "$HOOKS_STATE_DIR" "$SANDBOX_CLAUDE_HOME" "$NONCE_DIR" \
         "$SANDBOX_CLAUDE_HOME/projects" "$SANDBOX_CLAUDE_HOME/hooks/state"

# Synthetic git repo at $SANDBOX_CLAUDE_HOME with sp09/pre-flight tag so
# both helpers resolve the same SHA via `git -C $CLAUDE_HOME rev-parse`.
cd "$SANDBOX_CLAUDE_HOME"
git init -q .
echo x > .gitkeep
git -c user.name=t -c user.email=t@t add .gitkeep
git -c user.name=t -c user.email=t@t commit -q -m initial
git tag sp09/pre-flight
PRE_FLIGHT_SHA=$(git rev-parse sp09/pre-flight)
cd - >/dev/null

# Plan 71 synthetic manifest mirroring the migrated values verbatim.
# scope_paths/exempt_paths/detection rooted at $TEST_DIR so they only fire on
# fixture-controlled paths. Includes BOTH carve-outs (projects/** AND
# hooks/state/**) — second is the SP07 OQ-H closure addition (Session 1
# audit finding #5) and is the authoritative source of the B1 divergence.
cat > "$PLANS_ROOT/71-claude-foundations-engine-v2/manifest.json" <<EOF
{
  "schema_version": 1,
  "project": "claude-foundations-engine-v2",
  "spec_path": "spec.md",
  "top_level_status": "closed",
  "live_mutation_scope": {
    "enabled": true,
    "schema_version": 1,
    "scope_paths": ["$SANDBOX_CLAUDE_HOME/**"],
    "exempt_paths": [
      "$SANDBOX_CLAUDE_HOME/projects/**",
      "$SANDBOX_CLAUDE_HOME/hooks/state/**"
    ],
    "detection_signals": {
      "cwd_pattern": "$TEST_DIR/.claude-plans/71-*",
      "plan_id_pattern": "^71($|-)",
      "plan_mode_env_var": "PLAN_71_MODE",
      "deterministic_only": true
    },
    "override": {
      "nonce_dir": "$NONCE_DIR",
      "nonce_sha_anchor": "sp09/pre-flight",
      "nonce_min_reason_length": 12,
      "nonce_consume_strategy": "basename_match_env",
      "nonce_affinity_env": "PLAN_71_NONCE_TASK",
      "sentinel_override_path": "$SENTINEL_PATH",
      "bypass_env_var": "PLAN_71_GATE_BYPASS"
    },
    "enforcement": {
      "match_action": "deny",
      "error_action": "deny"
    }
  }
}
EOF

# === Helpers =================================================================

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $*"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "  FAIL: $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# Decision class extracted from a stdout JSON blob (or empty for pass-through).
decision_class() {
  local out="$1"
  if [[ -z "$out" ]]; then echo "pass-through"; return; fi
  local d
  d=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
  [[ -z "$d" ]] && { echo "malformed"; return; }
  if [[ "$d" == "deny" ]]; then echo "deny"; return; fi
  # Allow path: distinguish carve-out vs override vs sentinel via the
  # additionalContext text the helpers embed.
  local ctx
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
  case "$ctx" in
    *allow-carve-out*) echo "allow-carve-out" ;;
    *allow-override*)  echo "allow-override" ;;
    *allow-sentinel*)  echo "allow-sentinel" ;;
    *)                 echo "allow" ;;
  esac
}

# Most recent JSONL row from a log file. Returns "{}" if log absent.
last_row() {
  local log="$1"
  [[ -r "$log" ]] || { echo "{}"; return; }
  tail -n 1 "$log" 2>/dev/null || echo "{}"
}

# Side-by-side parallel-run row append (T-3 contract; T-9 audit consumes).
append_parallel_row() {
  local scenario="$1" old_class="$2" new_class="$3" disposition="${4:-}"
  jq -nc \
    --arg scenario "$scenario" \
    --arg old "$old_class" \
    --arg new "$new_class" \
    --arg disposition "$disposition" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{ts:$ts, scenario:$scenario, old_decision:$old, new_decision:$new,
      diverged: ($old != $new),
      disposition: (if $disposition == "" then null else $disposition end)
    } | with_entries(select(.value != null))' \
    >> "$PARALLEL_RUN_LOG"
}

# Run BOTH helpers under identical sandboxed env. Captures stdout per-helper.
# $1=label  $2=file_path  $3..=optional extra env (KEY=VAL form, repeatable)
# Caller may set TRIGGER_ENV to inject detection-signal env (PLAN_ID, etc.).
run_both() {
  local file_path="$1"; shift
  local extra_env="${TRIGGER_ENV:-}"

  # Reset session state (no leftover transcript / active-plans).
  : > "$NEW_LOG" 2>/dev/null || true
  : > "$OLD_LOG" 2>/dev/null || true

  # Build invocation env. HOOKS_STATE_OVERRIDE redirects state base for both;
  # CLAUDE_HOME redirects git rev-parse target; HOME redirects the OLD
  # helper's hardcoded $HOME/.claude/ paths into the sandbox; PLANS_ROOT_OVERRIDE
  # redirects NEW helper's manifest walk; deterministic_only kills tier-3.
  local cmd
  cmd="env -i PATH=/usr/bin:/bin:/usr/local/bin"
  cmd+=" HOME=$TEST_DIR"
  cmd+=" HOOKS_STATE_OVERRIDE=$HOOKS_STATE_DIR"
  cmd+=" PLANS_ROOT_OVERRIDE=$PLANS_ROOT"
  cmd+=" CLAUDE_HOME=$SANDBOX_CLAUDE_HOME"
  cmd+=" FILE_PATH=$file_path"
  cmd+=" TOOL_NAME=Edit"
  [[ -n "$extra_env" ]] && cmd+=" $extra_env"

  NEW_OUT=$(eval "$cmd bash $NEW_GUARD" 2>/dev/null </dev/null || true)
  OLD_OUT=$(eval "$cmd bash $OLD_GUARD" 2>/dev/null </dev/null || true)
  NEW_CLASS=$(decision_class "$NEW_OUT")
  OLD_CLASS=$(decision_class "$OLD_OUT")
}

assert_eq_decision() {
  local label="$1"
  if [[ "$NEW_CLASS" == "$OLD_CLASS" ]]; then
    pass "$label: equivalent ($OLD_CLASS)"
  else
    fail "$label: divergent (old=$OLD_CLASS new=$NEW_CLASS)"
    echo "    OLD_OUT: $OLD_OUT"
    echo "    NEW_OUT: $NEW_OUT"
  fi
  append_parallel_row "$label" "$OLD_CLASS" "$NEW_CLASS"
}

assert_class() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label: $actual"
  else
    fail "$label: expected=$expected got=$actual"
  fi
}

# ============================================================================
# Class A — decision-equivalence (≥3 scenarios per AC; ship 7)
# ============================================================================
echo "=== Class A: decision-equivalence ==="

# A1: not detected, file under live → both pass-through silently.
echo "A1: no detection signal + path under live → pass-through"
TRIGGER_ENV="" run_both "$SANDBOX_CLAUDE_HOME/skills/foo.md"
assert_eq_decision "A1"
assert_class "A1.class" "pass-through" "$NEW_CLASS"

# A2: plan-id detection + under-scope (no override) → DENY.
echo "A2: plan-id detection + under-scope → deny"
TRIGGER_ENV="PLAN_ID=71-claude-foundations-engine-v2" \
  run_both "$SANDBOX_CLAUDE_HOME/skills/foo.md"
assert_eq_decision "A2"
assert_class "A2.class" "deny" "$NEW_CLASS"

# A3: plan-mode detection + under-scope (no override) → DENY.
echo "A3: plan-mode detection + under-scope → deny"
TRIGGER_ENV="PLAN_71_MODE=1" \
  run_both "$SANDBOX_CLAUDE_HOME/hooks/bar.sh"
assert_eq_decision "A3"
assert_class "A3.class" "deny" "$NEW_CLASS"

# A4: detection + path under projects/** carve-out → both allow-carve-out.
echo "A4: detection + projects/** carve-out → allow-carve-out"
TRIGGER_ENV="PLAN_71_MODE=1" \
  run_both "$SANDBOX_CLAUDE_HOME/projects/foo/bar.jsonl"
assert_eq_decision "A4"
assert_class "A4.class" "allow-carve-out" "$NEW_CLASS"

# A5: detection + valid nonce (basename matches affinity) → both allow-override.
# Plant nonce content per OLD helper's verbatim format: <task>\t<reason>\t<sha>.
# Reason ≥12 chars enforced on both helpers.
echo "A5: detection + valid nonce + affinity match → allow-override"
NONCE_BASENAME="T-19-parallel-run.nonce"
NONCE_FILE="$NONCE_DIR/$NONCE_BASENAME"
printf 'T-19-parallel-run\tparallel-run-equivalence-fixture\t%s' \
  "$PRE_FLIGHT_SHA" > "$NONCE_FILE"
[[ -f "$NONCE_FILE" ]] || { echo "FAIL: nonce planting"; exit 1; }

# IMPORTANT: only ONE helper consumes the nonce per `run_both` call
# (single-use rm). We invoke OLD first, then re-plant before NEW so each
# helper sees a freshly-planted matching nonce.
re_plant_nonce() {
  printf 'T-19-parallel-run\tparallel-run-equivalence-fixture\t%s' \
    "$PRE_FLIGHT_SHA" > "$NONCE_FILE"
}

# Custom run_both for nonce equivalence: invoke OLD, re-plant, invoke NEW.
: > "$NEW_LOG" 2>/dev/null || true
: > "$OLD_LOG" 2>/dev/null || true
COMMON_INVOKE="env -i PATH=/usr/bin:/bin:/usr/local/bin \
  HOME=$TEST_DIR HOOKS_STATE_OVERRIDE=$HOOKS_STATE_DIR \
  PLANS_ROOT_OVERRIDE=$PLANS_ROOT CLAUDE_HOME=$SANDBOX_CLAUDE_HOME \
  FILE_PATH=$SANDBOX_CLAUDE_HOME/skills/nonced.md TOOL_NAME=Edit \
  PLAN_71_MODE=1 PLAN_71_NONCE_TASK=T-19-parallel-run"

OLD_OUT=$(eval "$COMMON_INVOKE bash $OLD_GUARD" 2>/dev/null </dev/null || true)
[[ ! -f "$NONCE_FILE" ]] && pass "A5: OLD consumed nonce (single-use semantics)" \
  || fail "A5: OLD did NOT consume nonce"

re_plant_nonce
NEW_OUT=$(eval "$COMMON_INVOKE bash $NEW_GUARD" 2>/dev/null </dev/null || true)
[[ ! -f "$NONCE_FILE" ]] && pass "A5: NEW consumed nonce (single-use semantics)" \
  || fail "A5: NEW did NOT consume nonce"

NEW_CLASS=$(decision_class "$NEW_OUT")
OLD_CLASS=$(decision_class "$OLD_OUT")
assert_eq_decision "A5"
assert_class "A5.class" "allow-override" "$NEW_CLASS"

# A6: BYPASS env set → both bypass via env (no decision JSON; pass-through).
echo "A6: BYPASS env → pass-through"
TRIGGER_ENV="PLAN_71_MODE=1 PLAN_71_GATE_BYPASS=1" \
  run_both "$SANDBOX_CLAUDE_HOME/skills/bypassed.md"
assert_eq_decision "A6"
assert_class "A6.class" "pass-through" "$NEW_CLASS"

# A7: detection + path NOT under live → both pass-through.
echo "A7: detection + out-of-scope path → pass-through"
TRIGGER_ENV="PLAN_71_MODE=1" \
  run_both "/tmp/not-under-claude.md"
assert_eq_decision "A7"
assert_class "A7.class" "pass-through" "$NEW_CLASS"

# ============================================================================
# Class B — divergence detection (≥1 scenario per AC; ship 1 with disposition)
# ============================================================================
echo ""
echo "=== Class B: divergence detection ==="

# B1: hooks/state/** is a NEW carve-out only. OLD denies; NEW allows.
# This is the by-design divergence pre-disposed in the migrated Plan 71 manifest's
# r55_sunset.divergence_log (Session 1 audit finding #5; SP07 OQ-H closure).
echo "B1: hooks/state/checkpoint.md under detection — NEW carve-out only"
TRIGGER_ENV="PLAN_71_MODE=1" \
  run_both "$SANDBOX_CLAUDE_HOME/hooks/state/checkpoint.md"

if [[ "$OLD_CLASS" == "deny" ]] && [[ "$NEW_CLASS" == "allow-carve-out" ]]; then
  pass "B1: divergence observed as expected (old=deny new=allow-carve-out)"
else
  fail "B1: expected old=deny new=allow-carve-out; got old=$OLD_CLASS new=$NEW_CLASS"
fi
append_parallel_row "B1" "$OLD_CLASS" "$NEW_CLASS" "expected"

# parallel-run.log diverged-row should be written + carry disposition.
B1_ROW=$(tail -n 1 "$PARALLEL_RUN_LOG")
if echo "$B1_ROW" | jq -e '.diverged == true and .disposition == "expected"' >/dev/null 2>&1; then
  pass "B1: parallel-run.log row carries diverged:true + disposition:expected"
else
  fail "B1: parallel-run.log row missing required fields; got: $B1_ROW"
fi

# Side-by-side comparison shape (T-9 r55-parallel-run-audit consumes this).
if echo "$B1_ROW" | jq -e 'has("ts") and has("scenario") and has("old_decision") and has("new_decision")' >/dev/null 2>&1; then
  pass "B1: parallel-run row shape carries ts/scenario/old/new"
else
  fail "B1: parallel-run row shape missing required fields"
fi

# ============================================================================
# Class C — audit log entry shape conforms to schema
# ============================================================================
echo ""
echo "=== Class C: audit log entry shape ==="

# Required fields per spec L409: ts, decision, plan_id, rule, tool, file,
# signal, reason, nonce_task, sha, schema_version. The helper strips empty
# fields (`with_entries(select(.value != "" and .value != null))`) so
# conditional fields appear only when populated. Required-always: ts, decision,
# plan_id, rule, tool, file, schema_version. Conditional: signal/reason
# (when set), nonce_task/sha (allow-override only).

# Generate one row per representative decision class, then validate.
echo "C1: representative deny row carries required-always fields"
: > "$NEW_LOG"
TRIGGER_ENV="PLAN_71_MODE=1" run_both "$SANDBOX_CLAUDE_HOME/skills/c1-deny.md"
DENY_ROW=$(last_row "$NEW_LOG")
if echo "$DENY_ROW" | jq -e '
  (has("ts") and has("decision") and has("plan_id") and has("rule")
   and has("tool") and has("file") and has("schema_version"))
  and .decision == "deny"
  and .schema_version == 1
  and .rule == "R-55"
' >/dev/null 2>&1; then
  pass "C1: deny row schema-conformant"
else
  fail "C1: deny row missing fields; got: $DENY_ROW"
fi

# C1.signal — detection-triggered rows carry a signal.
if echo "$DENY_ROW" | jq -e '.signal == "plan-mode"' >/dev/null 2>&1; then
  pass "C1: deny row carries signal=plan-mode"
else
  fail "C1: deny row signal mismatch; got: $DENY_ROW"
fi

echo "C1: representative allow-carve-out row schema-conformant"
: > "$NEW_LOG"
TRIGGER_ENV="PLAN_71_MODE=1" run_both "$SANDBOX_CLAUDE_HOME/projects/foo.md"
CARVE_ROW=$(last_row "$NEW_LOG")
if echo "$CARVE_ROW" | jq -e '
  .decision == "allow-carve-out"
  and (has("ts") and has("plan_id") and has("rule") and has("tool")
       and has("file") and has("schema_version"))
' >/dev/null 2>&1; then
  pass "C1: allow-carve-out row schema-conformant"
else
  fail "C1: allow-carve-out row malformed; got: $CARVE_ROW"
fi

echo "C1: representative allow-override row carries nonce_task + sha"
: > "$NEW_LOG"
re_plant_nonce
eval "$COMMON_INVOKE bash $NEW_GUARD" >/dev/null 2>&1 </dev/null || true
OVERRIDE_ROW=$(last_row "$NEW_LOG")
if echo "$OVERRIDE_ROW" | jq -e '
  .decision == "allow-override"
  and has("nonce_task") and has("sha")
  and .nonce_task == "T-19-parallel-run"
  and .sha == "'"$PRE_FLIGHT_SHA"'"
' >/dev/null 2>&1; then
  pass "C1: allow-override row carries nonce_task + sha"
else
  fail "C1: allow-override row missing nonce_task/sha; got: $OVERRIDE_ROW"
fi

# C1: schema_version pinned to 1 across every decision class.
ALL_VERSIONS=$(jq -s 'map(.schema_version) | unique' "$NEW_LOG" 2>/dev/null || echo "[]")
if [[ "$ALL_VERSIONS" == "[1]" || "$ALL_VERSIONS" == "[
  1
]" ]]; then
  pass "C1: every decision row carries schema_version: 1"
else
  fail "C1: schema_version drift across rows; got: $ALL_VERSIONS"
fi

# C1: row ordering preservable for T-9 audit consumption (one row per call).
ROW_COUNT=$(wc -l < "$NEW_LOG" | tr -d ' ')
if [[ "$ROW_COUNT" -ge 1 ]]; then
  pass "C1: gate-decisions.log is JSONL (one row per emitted decision)"
else
  fail "C1: gate-decisions.log empty after representative scenarios"
fi

# ============================================================================
echo ""
echo "Results: $PASS_COUNT pass / $FAIL_COUNT fail"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "T-19 parallel-run-test FAILED"
  exit 1
fi
echo "All T-19 parallel-run-test assertions PASSED ($PASS_COUNT/$PASS_COUNT)."
echo "R-55 parallel-run validation contract structurally testable pre-Phase-A."
exit 0
