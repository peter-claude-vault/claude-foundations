#!/bin/bash
# tests/onboarder/section-e-unit-test.sh — synthetic unit tests for SP07 T-7
# onboarding/ux/section-e.sh.
#
# Validates the 4 acceptance criteria from
# ~/.claude-plans/71-claude-foundations-engine-v2/07-onboarder-ux/tasks.md T-7:
#
#   AC1 — Render 3 checkboxes defaulting OFF
#   AC2 — Accept checkbox selection via arrow/space keys OR typed y/n
#         (programmatic flag for hermetic test: --auto-set / interactive
#          1-3 toggle and y[1-3]/n[1-3] explicit set)
#   AC3 — Write three hook-preference fields to extraction-output-E.json
#         via deterministic shape (bootstrap-schemas.sh consumes populated
#         map at end-of-flow)
#   AC4 — Emit section-E JSONL audit entry with 9-key SKILL.md L141 shape
#
# Plus structural guardrails (R-37 + SKILL.md Hard Rule 9 reference-leak floor):
#
#   T-STRUCT-A — extraction-output-E.json conforms to extraction-prompts/section-E.md
#                shape (section_id="E", extraction_mode="deterministic",
#                empty confidence/source_spans, follow_up=null)
#   T-STRUCT-B — JSONL audit entry has all 9 expected keys per SKILL.md L141
#   T-STRUCT-C — corrections[] carries Q-IDs only (E-1/E-2/E-3) — no user strings
#   T-STRUCT-D — manifest_paths_written reflects all 3 hook_preference keys
#                (always emitted; deterministic — no nullable fields)
#   T-STRUCT-E — quit path (q/Q) exits 130, writes no files
#   T-STRUCT-F — bad --auto-set values exit 2 (not silent acceptance)
#
# Hermetic: per-test fake $HOME with mock $CLAUDE_HOME. No discovery probes
# (Section E is deterministic — no filesystem scan, no MCP enumeration, no
# git config). Bash 3.2 clean (R-23).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/onboarding/ux/section-e.sh"

if [ ! -x "$SCRIPT" ]; then echo "FAIL: cannot exec $SCRIPT"; exit 2; fi

TEST_ROOT="$(mktemp -d -t section-e-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 — $2"; }

# Per-test fake $HOME.
setup_fake_home() {
  local hroot="$1"
  mkdir -p "$hroot/.claude/onboarding/audit"
}

# Common env exports + script invocation.
# $1 = fake home root, remaining args appended to script.
run_script() {
  local hroot="$1"; shift
  HOME="$hroot" \
  CLAUDE_HOME="$hroot/.claude" \
  "$SCRIPT" "$@"
}

# stdin-driven invocation for interactive-path tests.
run_script_stdin() {
  local hroot="$1"; local input="$2"; shift 2
  printf '%s' "$input" | run_script "$hroot" "$@"
}

# ---------- AC1 + AC3 + T-STRUCT-A: --auto-accept default-OFF path ----------
T1_HOME="$TEST_ROOT/t1"
setup_fake_home "$T1_HOME"
T1_OUT="$TEST_ROOT/t1.out"
run_script "$T1_HOME" --auto-accept > "$T1_OUT" 2>&1
T1_RC=$?
T1_EXTRACT="$T1_HOME/.claude/onboarding/extraction-output-E.json"
T1_AUDIT="$T1_HOME/.claude/onboarding/audit/section-e.jsonl"

if [ "$T1_RC" -eq 0 ] && [ -f "$T1_EXTRACT" ] && [ -f "$T1_AUDIT" ]; then
  pass "AC1+AC3 happy path → both files written, rc=0"
else
  fail "AC1+AC3" "rc=$T1_RC, extract=$([ -f "$T1_EXTRACT" ] && echo y || echo n), audit=$([ -f "$T1_AUDIT" ] && echo y || echo n)"
fi

# T-STRUCT-A: extraction-output-E.json conforms to deterministic shape.
if jq -e '.section_id == "E" and .extraction_mode == "deterministic" and (.confidence == {}) and (.source_spans == {}) and (.missing_required == []) and (.conflicts == []) and (.follow_up == null)' "$T1_EXTRACT" >/dev/null 2>&1; then
  pass "T-STRUCT-A extraction-output shape (section-E.md contract)"
else
  fail "T-STRUCT-A" "shape diverges; got: $(cat "$T1_EXTRACT")"
fi

# AC1: all 3 toggles default OFF (booleans, false).
if jq -e '
    .populated."U.behavioral.hook_preferences.auto_commit_enabled" == false
    and .populated."U.behavioral.hook_preferences.memory_consolidation_enabled" == false
    and .populated."U.behavioral.hook_preferences.multi_session_enabled" == false
  ' "$T1_EXTRACT" >/dev/null 2>&1; then
  pass "AC1 three checkboxes default OFF (all booleans false)"
else
  fail "AC1-defaults" "populated diverges; got: $(jq -c '.populated' "$T1_EXTRACT")"
fi

# AC3: three hook_preference fields ARE booleans, not strings/numbers.
if jq -e '
    (.populated."U.behavioral.hook_preferences.auto_commit_enabled" | type) == "boolean"
    and (.populated."U.behavioral.hook_preferences.memory_consolidation_enabled" | type) == "boolean"
    and (.populated."U.behavioral.hook_preferences.multi_session_enabled" | type) == "boolean"
  ' "$T1_EXTRACT" >/dev/null 2>&1; then
  pass "AC3 hook-preference fields are JSON booleans (not coerced)"
else
  fail "AC3-types" "field types: $(jq -c '.populated | map_values(type)' "$T1_EXTRACT")"
fi

# AC4: audit entry has opt_outs:[], corrections:[] (empty on default path).
if jq -e '.opt_outs == [] and .section_id == "E" and .corrections == [] and .follow_ups == []' "$T1_AUDIT" >/dev/null 2>&1; then
  pass "AC4 audit JSONL on default path (opt_outs[] empty, corrections[] empty)"
else
  fail "AC4-audit-default" "audit shape diverges; got: $(cat "$T1_AUDIT")"
fi

# T-STRUCT-B: audit JSONL has all 9 keys per SKILL.md L141.
if jq -e '
    has("section_id") and has("run_id") and has("ts") and has("opt_outs")
    and has("confidence_map") and has("source_spans") and has("corrections")
    and has("follow_ups") and has("manifest_paths_written")
  ' "$T1_AUDIT" >/dev/null 2>&1; then
  pass "T-STRUCT-B audit JSONL carries all 9 SKILL.md L141 fields"
else
  fail "T-STRUCT-B" "audit missing required keys; got: $(cat "$T1_AUDIT")"
fi

# T-STRUCT-D: manifest_paths_written enumerates all 3 hook_preference keys.
if jq -e '
    (.manifest_paths_written | sort) == ([
      "U.behavioral.hook_preferences.auto_commit_enabled",
      "U.behavioral.hook_preferences.memory_consolidation_enabled",
      "U.behavioral.hook_preferences.multi_session_enabled"
    ] | sort)
  ' "$T1_AUDIT" >/dev/null 2>&1; then
  pass "T-STRUCT-D manifest_paths_written enumerates all 3 hook_preference keys"
else
  fail "T-STRUCT-D" "got: $(jq -c '.manifest_paths_written' "$T1_AUDIT")"
fi

# ---------- AC2 + T-STRUCT-C: --auto-set partial flips ----------
T2_HOME="$TEST_ROOT/t2"
setup_fake_home "$T2_HOME"
run_script "$T2_HOME" --auto-set "E-1=true,E-3=true" > /dev/null 2>&1
T2_RC=$?
T2_EXTRACT="$T2_HOME/.claude/onboarding/extraction-output-E.json"
T2_AUDIT="$T2_HOME/.claude/onboarding/audit/section-e.jsonl"

if [ "$T2_RC" -eq 0 ] \
   && jq -e '
       .populated."U.behavioral.hook_preferences.auto_commit_enabled" == true
       and .populated."U.behavioral.hook_preferences.memory_consolidation_enabled" == false
       and .populated."U.behavioral.hook_preferences.multi_session_enabled" == true
     ' "$T2_EXTRACT" >/dev/null 2>&1; then
  pass "AC2 --auto-set flips E-1 + E-3 ON; E-2 default OFF preserved"
else
  fail "AC2-auto-set" "rc=$T2_RC; populated=$(jq -c '.populated' "$T2_EXTRACT" 2>/dev/null)"
fi

# T-STRUCT-C: corrections[] carries Q-IDs only (no user-typed strings).
if jq -e '
    (.corrections | sort) == (["E-1","E-3"] | sort)
    and (.corrections | all(test("^E-[1-3]$")))
  ' "$T2_AUDIT" >/dev/null 2>&1; then
  pass "T-STRUCT-C corrections[] carries Q-IDs only (reference-leak floor)"
else
  fail "T-STRUCT-C" "corrections=$(jq -c '.corrections' "$T2_AUDIT")"
fi

# ---------- AC2 (interactive): typed 1-3 toggles + Enter accept ----------
T3_HOME="$TEST_ROOT/t3"
setup_fake_home "$T3_HOME"
# Toggle field 2 ON, then Enter.
T3_INPUT='2

'
run_script_stdin "$T3_HOME" "$T3_INPUT" > /dev/null 2>&1
T3_RC=$?
T3_EXTRACT="$T3_HOME/.claude/onboarding/extraction-output-E.json"
T3_AUDIT="$T3_HOME/.claude/onboarding/audit/section-e.jsonl"
if [ "$T3_RC" -eq 0 ] \
   && jq -e '
       .populated."U.behavioral.hook_preferences.auto_commit_enabled" == false
       and .populated."U.behavioral.hook_preferences.memory_consolidation_enabled" == true
       and .populated."U.behavioral.hook_preferences.multi_session_enabled" == false
     ' "$T3_EXTRACT" >/dev/null 2>&1; then
  pass "AC2 interactive numeric toggle (2 → E-2 ON) then Enter-accept"
else
  fail "AC2-interactive-toggle" "rc=$T3_RC; populated=$(jq -c '.populated' "$T3_EXTRACT" 2>/dev/null)"
fi

if jq -e '.corrections == ["E-2"]' "$T3_AUDIT" >/dev/null 2>&1; then
  pass "AC2 interactive toggle records E-2 in corrections[]"
else
  fail "AC2-interactive-corrections" "corrections=$(jq -c '.corrections' "$T3_AUDIT")"
fi

# ---------- AC2 (interactive): explicit y[1-3]/n[1-3] set ----------
T4_HOME="$TEST_ROOT/t4"
setup_fake_home "$T4_HOME"
# y1 (E-1 ON), y3 (E-3 ON), n3 (flip back OFF), Enter.
T4_INPUT='y1
y3
n3

'
run_script_stdin "$T4_HOME" "$T4_INPUT" > /dev/null 2>&1
T4_RC=$?
T4_EXTRACT="$T4_HOME/.claude/onboarding/extraction-output-E.json"
T4_AUDIT="$T4_HOME/.claude/onboarding/audit/section-e.jsonl"
if [ "$T4_RC" -eq 0 ] \
   && jq -e '
       .populated."U.behavioral.hook_preferences.auto_commit_enabled" == true
       and .populated."U.behavioral.hook_preferences.memory_consolidation_enabled" == false
       and .populated."U.behavioral.hook_preferences.multi_session_enabled" == false
     ' "$T4_EXTRACT" >/dev/null 2>&1; then
  pass "AC2 interactive explicit y1 + y3 + n3 → E-1 ON, E-3 OFF (override)"
else
  fail "AC2-interactive-explicit" "rc=$T4_RC; populated=$(jq -c '.populated' "$T4_EXTRACT" 2>/dev/null)"
fi

if jq -e '.corrections == ["E-1"]' "$T4_AUDIT" >/dev/null 2>&1; then
  pass "AC2 explicit set records only currently-true Q-IDs in corrections[]"
else
  fail "AC2-explicit-corrections" "corrections=$(jq -c '.corrections' "$T4_AUDIT")"
fi

# ---------- T-STRUCT-E: quit path ----------
T5_HOME="$TEST_ROOT/t5"
setup_fake_home "$T5_HOME"
printf 'q\n' | run_script "$T5_HOME" > /dev/null 2>&1
T5_RC=$?
T5_EXTRACT="$T5_HOME/.claude/onboarding/extraction-output-E.json"
T5_AUDIT="$T5_HOME/.claude/onboarding/audit/section-e.jsonl"
if [ "$T5_RC" -eq 130 ] && [ ! -f "$T5_EXTRACT" ] && [ ! -f "$T5_AUDIT" ]; then
  pass "T-STRUCT-E quit path → exit 130, no files written"
else
  fail "T-STRUCT-E" "rc=$T5_RC; extract_exists=$([ -f "$T5_EXTRACT" ] && echo y || echo n); audit_exists=$([ -f "$T5_AUDIT" ] && echo y || echo n)"
fi

# ---------- T-STRUCT-F: bad --auto-set values exit 2 ----------
T6_HOME="$TEST_ROOT/t6"
setup_fake_home "$T6_HOME"
run_script "$T6_HOME" --auto-set "E-1=banana" > /dev/null 2>&1
T6_RC=$?
T6_EXTRACT="$T6_HOME/.claude/onboarding/extraction-output-E.json"
if [ "$T6_RC" -eq 2 ] && [ ! -f "$T6_EXTRACT" ]; then
  pass "T-STRUCT-F bad --auto-set value (E-1=banana) exits 2, no files written"
else
  fail "T-STRUCT-F-bad-value" "rc=$T6_RC; extract_exists=$([ -f "$T6_EXTRACT" ] && echo y || echo n)"
fi

T7_HOME="$TEST_ROOT/t7"
setup_fake_home "$T7_HOME"
run_script "$T7_HOME" --auto-set "E-9=true" > /dev/null 2>&1
T7_RC=$?
if [ "$T7_RC" -eq 2 ]; then
  pass "T-STRUCT-F unknown Q-ID (E-9) in --auto-set exits 2"
else
  fail "T-STRUCT-F-unknown-id" "rc=$T7_RC (expected 2)"
fi

# ---------- AC2: --auto-set value aliases (1/yes/on, 0/no/off) ----------
T8_HOME="$TEST_ROOT/t8"
setup_fake_home "$T8_HOME"
run_script "$T8_HOME" --auto-set "E-1=yes,E-2=on,E-3=1" > /dev/null 2>&1
T8_RC=$?
T8_EXTRACT="$T8_HOME/.claude/onboarding/extraction-output-E.json"
if [ "$T8_RC" -eq 0 ] \
   && jq -e '
       .populated."U.behavioral.hook_preferences.auto_commit_enabled" == true
       and .populated."U.behavioral.hook_preferences.memory_consolidation_enabled" == true
       and .populated."U.behavioral.hook_preferences.multi_session_enabled" == true
     ' "$T8_EXTRACT" >/dev/null 2>&1; then
  pass "AC2 --auto-set accepts true-aliases (yes/on/1) → all 3 ON"
else
  fail "AC2-auto-set-aliases" "rc=$T8_RC; populated=$(jq -c '.populated' "$T8_EXTRACT" 2>/dev/null)"
fi

# ---------- AC4 boundary: audit emitted exactly once per run ----------
T9_HOME="$TEST_ROOT/t9"
setup_fake_home "$T9_HOME"
run_script "$T9_HOME" --auto-accept > /dev/null 2>&1
T9_AUDIT="$T9_HOME/.claude/onboarding/audit/section-e.jsonl"
LINE_COUNT="$(wc -l < "$T9_AUDIT" | tr -d ' ')"
if [ "$LINE_COUNT" = "1" ]; then
  pass "AC4-boundary audit JSONL emits exactly one line per run"
else
  fail "AC4-boundary-line-count" "expected 1 line, got $LINE_COUNT"
fi

# Re-run; should append a SECOND line (append-only audit per S80 contract).
run_script "$T9_HOME" --auto-accept > /dev/null 2>&1
LINE_COUNT2="$(wc -l < "$T9_AUDIT" | tr -d ' ')"
if [ "$LINE_COUNT2" = "2" ]; then
  pass "AC4-boundary audit JSONL is append-only across re-runs"
else
  fail "AC4-boundary-append" "expected 2 lines after re-run, got $LINE_COUNT2"
fi

# ---------- T-STRUCT-A boundary: extraction-output is overwritten (atomic), not appended ----------
T10_HOME="$TEST_ROOT/t10"
setup_fake_home "$T10_HOME"
run_script "$T10_HOME" --auto-set "E-1=true" > /dev/null 2>&1
run_script "$T10_HOME" --auto-set "E-2=true" > /dev/null 2>&1
T10_EXTRACT="$T10_HOME/.claude/onboarding/extraction-output-E.json"
# Last write wins: only E-2 should be true.
if jq -e '
    .populated."U.behavioral.hook_preferences.auto_commit_enabled" == false
    and .populated."U.behavioral.hook_preferences.memory_consolidation_enabled" == true
    and .populated."U.behavioral.hook_preferences.multi_session_enabled" == false
  ' "$T10_EXTRACT" >/dev/null 2>&1; then
  pass "T-STRUCT-A-boundary extraction-output is overwritten atomically (last-write-wins)"
else
  fail "T-STRUCT-A-boundary" "populated=$(jq -c '.populated' "$T10_EXTRACT" 2>/dev/null)"
fi

# ---------- summary ----------
echo "=== section-e-unit-test ==="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
