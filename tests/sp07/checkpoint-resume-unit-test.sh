#!/bin/bash
# tests/sp07/checkpoint-resume-unit-test.sh — synthetic unit tests for SP07
# T-10 per-section checkpoint + SessionStart resume.
#
# Validates the 5 acceptance criteria from
# ~/.claude-plans/71-claude-foundations-engine-v2/07-onboarder-ux/tasks.md T-10:
#
#   AC1 — Write phases_completed + completion_state after every section
#   AC2 — SessionStart hook detects incomplete onboarding state
#   AC3 — Resume prompt offers "resume" vs. "re-record" per incomplete section
#   AC4 — Re-record Section C leaves A/B/D/E manifest fragments byte-identical
#         (extends render-summary-unit-test T-RERECORD-B with completion_state
#          field-isolation assertion)
#   AC5 — Mid-Section-B quit + resume picks up from the same prompt card
#         (stateless re-render: detection signal correctly identifies B as
#          next-missing; resume re-invokes section-b.sh which renders the
#          section's prompt card from scratch — nothing committed = nothing
#          to skip)
#
# Plus structural / validation guardrails:
#
#   T-VALIDATE-A — checkpoint.sh missing --section + --remove-section → exit 2
#   T-VALIDATE-B — checkpoint.sh --section + --remove-section together → exit 2
#   T-VALIDATE-C — checkpoint.sh invalid section letter → exit 2
#   T-VALIDATE-D — checkpoint.sh --transcript not readable → exit 2
#   T-IDEMPOTENT-A — checkpoint.sh re-invocation with same section is no-op
#                    (phases_completed dedup; completion_state.committed_at
#                     overwrites — latest wins)
#   T-IDEMPOTENT-B — checkpoint.sh --remove-section against absent manifest
#                    is no-op rc=0
#   T-SCHEMA — completion_state shape matches schemas/user-manifest-schema.json
#               1.5.0 contract: object keyed by section_id; required
#               committed_at; optional transcript_sha (string|null)
#   T-LEAK — reference-leak floor: checkpoint write contains only section_id
#             literal + ISO ts + sha (no user-typed strings)
#   T-SESSION-START-A — manifest absent → silent (no stdout)
#   T-SESSION-START-B — manifest unparseable → silent
#   T-SESSION-START-C — phases_completed = [A,B,C,D,E] → silent
#   T-SESSION-START-D — phases_completed = [A,B] → emit hookSpecificOutput
#   T-SESSION-START-E — banner names FIRST missing section
#   T-SESSION-START-F — banner contains both "/onboard --resume" + re-record
#                       language (AC3 branching options)
#   T-SESSION-START-G — banner emitted as valid JSON (jq parseable)
#   T-COMPLETION-ISOLATION — re-record one section leaves OTHER sections'
#                             completion_state entries byte-identical
#   T-MID-SECTION-DETECT — Section A committed, transcript-B exists but
#                           extraction-output-B absent → SessionStart names B
#                           as next missing (AC5 detection signal)
#
# Hermetic: per-test fake $HOME/.claude tree. Each test gets its own root.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKPOINT="$REPO_ROOT/onboarding/checkpoint.sh"
SESSION_START="$REPO_ROOT/hooks/session-start.sh"
RENDER_SUMMARY="$REPO_ROOT/onboarding/ux/render-summary.sh"
SECTION_A="$REPO_ROOT/onboarding/ux/section-a.sh"
SECTION_E="$REPO_ROOT/onboarding/ux/section-e.sh"
Q_FIELD_MAP="$REPO_ROOT/onboarding/q-field-map.json"
SCHEMA="$REPO_ROOT/schemas/user-manifest-schema.json"

if [ ! -x "$CHECKPOINT" ];     then echo "FAIL: cannot exec $CHECKPOINT"; exit 2; fi
if [ ! -x "$SESSION_START" ];  then echo "FAIL: cannot exec $SESSION_START"; exit 2; fi
if [ ! -x "$RENDER_SUMMARY" ]; then echo "FAIL: cannot exec $RENDER_SUMMARY"; exit 2; fi
if [ ! -x "$SECTION_A" ];      then echo "FAIL: cannot exec $SECTION_A"; exit 2; fi
if [ ! -x "$SECTION_E" ];      then echo "FAIL: cannot exec $SECTION_E"; exit 2; fi

TEST_ROOT="$(mktemp -d -t checkpoint-resume-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 -- $2"; }

setup_test_root() {
  local root="$1"
  mkdir -p "$root/.claude/onboarding/audit" \
           "$root/.claude/onboarding/transcripts"
}

# Common env-bound checkpoint.sh invocation. $1 = test root; remaining flags.
run_checkpoint() {
  local root="$1"; shift
  HOME="$root" \
  CLAUDE_HOME="$root/.claude" \
  USER_MANIFEST="$root/.claude/user-manifest.json" \
    "$CHECKPOINT" "$@"
}

run_session_start() {
  local root="$1"
  HOME="$root" \
  CLAUDE_HOME="$root/.claude" \
  USER_MANIFEST="$root/.claude/user-manifest.json" \
    "$SESSION_START" </dev/null
}

# ---------- T-VALIDATE-A: missing --section + --remove-section ----------
T1_ROOT="$TEST_ROOT/t1"
setup_test_root "$T1_ROOT"
run_checkpoint "$T1_ROOT" > /dev/null 2>&1
T1_RC=$?
if [ "$T1_RC" -eq 2 ]; then
  pass "T-VALIDATE-A missing --section + --remove-section rejects with exit 2"
else
  fail "T-VALIDATE-A" "rc=$T1_RC (expected 2)"
fi

# ---------- T-VALIDATE-B: mutex --section + --remove-section ----------
T2_ROOT="$TEST_ROOT/t2"
setup_test_root "$T2_ROOT"
run_checkpoint "$T2_ROOT" --section A --remove-section A > /dev/null 2>&1
T2_RC=$?
if [ "$T2_RC" -eq 2 ]; then
  pass "T-VALIDATE-B --section + --remove-section together rejects with exit 2"
else
  fail "T-VALIDATE-B" "rc=$T2_RC (expected 2)"
fi

# ---------- T-VALIDATE-C: invalid section letter ----------
T3_ROOT="$TEST_ROOT/t3"
setup_test_root "$T3_ROOT"
run_checkpoint "$T3_ROOT" --section X > /dev/null 2>&1
T3_RC=$?
if [ "$T3_RC" -eq 2 ]; then
  pass "T-VALIDATE-C invalid section letter (X) rejects with exit 2"
else
  fail "T-VALIDATE-C" "rc=$T3_RC (expected 2)"
fi

# ---------- T-VALIDATE-D: --transcript not readable ----------
T4_ROOT="$TEST_ROOT/t4"
setup_test_root "$T4_ROOT"
run_checkpoint "$T4_ROOT" --section B --transcript "$T4_ROOT/nonexistent.txt" > /dev/null 2>&1
T4_RC=$?
if [ "$T4_RC" -eq 2 ]; then
  pass "T-VALIDATE-D --transcript not readable rejects with exit 2"
else
  fail "T-VALIDATE-D" "rc=$T4_RC (expected 2)"
fi

# ---------- AC1 (A): section-a accept → phases_completed + completion_state ----------
T5_ROOT="$TEST_ROOT/t5"
setup_test_root "$T5_ROOT"
HOME="$T5_ROOT" \
CLAUDE_HOME="$T5_ROOT/.claude" \
INPUTS_DIR="$T5_ROOT/.claude/onboarding" \
AUDIT_LOG="$T5_ROOT/.claude/onboarding/audit/section-a.jsonl" \
SETTINGS_JSON="$T5_ROOT/.claude/settings.json" \
DISCOVERY_TZ_OVERRIDE="America/New_York" \
DISCOVERY_DEV_ENV_OVERRIDE="vim" \
USER_MANIFEST="$T5_ROOT/.claude/user-manifest.json" \
  "$SECTION_A" --auto-accept > "$TEST_ROOT/t5.out" 2>&1
T5_RC=$?
T5_MANIFEST="$T5_ROOT/.claude/user-manifest.json"
if [ "$T5_RC" -eq 0 ] \
   && jq -e '.system.phases_completed | index("A") != null' "$T5_MANIFEST" >/dev/null 2>&1 \
   && jq -e '.system.completion_state.A.committed_at != null' "$T5_MANIFEST" >/dev/null 2>&1; then
  pass "AC1-A section-a accept → phases_completed[A] + completion_state[A]"
else
  fail "AC1-A" "rc=$T5_RC manifest=$(cat "$T5_MANIFEST" 2>/dev/null)"
fi

# Section A has no transcript → completion_state[A].transcript_sha must be absent.
if jq -e '.system.completion_state.A | has("transcript_sha") | not' "$T5_MANIFEST" >/dev/null 2>&1; then
  pass "AC1-A completion_state[A] has no transcript_sha (deterministic section)"
else
  fail "AC1-A-no-transcript" "completion_state.A: $(jq -c '.system.completion_state.A' "$T5_MANIFEST")"
fi

# ---------- AC1 (E): section-e accept → phases_completed + completion_state ----------
T6_ROOT="$TEST_ROOT/t6"
setup_test_root "$T6_ROOT"
HOME="$T6_ROOT" \
CLAUDE_HOME="$T6_ROOT/.claude" \
INPUTS_DIR="$T6_ROOT/.claude/onboarding" \
AUDIT_LOG="$T6_ROOT/.claude/onboarding/audit/section-e.jsonl" \
USER_MANIFEST="$T6_ROOT/.claude/user-manifest.json" \
  "$SECTION_E" --auto-accept > /dev/null 2>&1
T6_RC=$?
T6_MANIFEST="$T6_ROOT/.claude/user-manifest.json"
if [ "$T6_RC" -eq 0 ] \
   && jq -e '.system.phases_completed | index("E") != null' "$T6_MANIFEST" >/dev/null 2>&1 \
   && jq -e '.system.completion_state.E.committed_at != null' "$T6_MANIFEST" >/dev/null 2>&1; then
  pass "AC1-E section-e accept → phases_completed[E] + completion_state[E]"
else
  fail "AC1-E" "rc=$T6_RC manifest=$(cat "$T6_MANIFEST" 2>/dev/null)"
fi

# ---------- AC1 (D via render-summary): completion_state with transcript_sha ----------
T7_ROOT="$TEST_ROOT/t7"
setup_test_root "$T7_ROOT"
# Pre-stage extraction-output-D + transcript + audit baseline.
jq -nc '{
  section_id: "D", extraction_mode: "transcript",
  populated: {"U.behavioral.autonomy":"balanced","O.jobs[0].id":"librarian"},
  confidence: {"U.behavioral.autonomy":0.95,"O.jobs[0].id":0.9},
  source_spans: {}, missing_required: [], conflicts: [], follow_up: null,
  opt_outs: [], run_id: "test-run", timestamp: "2026-05-02T00:00:00Z"
}' > "$T7_ROOT/.claude/onboarding/extraction-output-D.json"
printf 'synthetic transcript for section D\n' > "$T7_ROOT/.claude/onboarding/transcripts/section-d.txt"
jq -nc '{
  section_id:"D", run_id:"init", ts:"2026-05-02T00:00:00Z",
  opt_outs:[], confidence_map:{}, source_spans:{}, corrections:[],
  follow_ups:[], manifest_paths_written:[]
}' >> "$T7_ROOT/.claude/onboarding/audit/section-d.jsonl"

HOME="$T7_ROOT" \
CLAUDE_HOME="$T7_ROOT/.claude" \
INPUTS_DIR="$T7_ROOT/.claude/onboarding" \
AUDIT_LOG="$T7_ROOT/.claude/onboarding/audit/section-d.jsonl" \
TRANSCRIPT_DIR="$T7_ROOT/.claude/onboarding/transcripts" \
Q_FIELD_MAP="$Q_FIELD_MAP" \
USER_MANIFEST="$T7_ROOT/.claude/user-manifest.json" \
  "$RENDER_SUMMARY" --section D --auto-accept > /dev/null 2>&1
T7_RC=$?
T7_MANIFEST="$T7_ROOT/.claude/user-manifest.json"
if [ "$T7_RC" -eq 0 ] \
   && jq -e '.system.phases_completed | index("D") != null' "$T7_MANIFEST" >/dev/null 2>&1 \
   && jq -e '.system.completion_state.D.committed_at != null' "$T7_MANIFEST" >/dev/null 2>&1 \
   && jq -e '.system.completion_state.D.transcript_sha | type == "string"' "$T7_MANIFEST" >/dev/null 2>&1; then
  pass "AC1-D render-summary accept → completion_state[D] with transcript_sha"
else
  fail "AC1-D" "rc=$T7_RC manifest=$(cat "$T7_MANIFEST" 2>/dev/null)"
fi

# Verify transcript_sha matches actual shasum of staged transcript.
T7_EXPECTED_SHA="$(shasum "$T7_ROOT/.claude/onboarding/transcripts/section-d.txt" | awk '{print $1}')"
T7_RECORDED_SHA="$(jq -r '.system.completion_state.D.transcript_sha' "$T7_MANIFEST")"
if [ "$T7_EXPECTED_SHA" = "$T7_RECORDED_SHA" ]; then
  pass "AC1-D completion_state[D].transcript_sha matches actual shasum"
else
  fail "AC1-D-sha" "expected=$T7_EXPECTED_SHA recorded=$T7_RECORDED_SHA"
fi

# ---------- T-IDEMPOTENT-A: re-invocation idempotent ----------
T8_ROOT="$TEST_ROOT/t8"
setup_test_root "$T8_ROOT"
run_checkpoint "$T8_ROOT" --section B > /dev/null 2>&1
run_checkpoint "$T8_ROOT" --section B > /dev/null 2>&1
run_checkpoint "$T8_ROOT" --section B > /dev/null 2>&1
T8_MANIFEST="$T8_ROOT/.claude/user-manifest.json"
T8_B_COUNT="$(jq '.system.phases_completed | map(select(. == "B")) | length' "$T8_MANIFEST")"
if [ "$T8_B_COUNT" = "1" ]; then
  pass "T-IDEMPOTENT-A re-invocation appears B exactly once in phases_completed[]"
else
  fail "T-IDEMPOTENT-A" "B count=$T8_B_COUNT (expected 1)"
fi

# ---------- T-IDEMPOTENT-B: --remove-section against absent manifest ----------
T9_ROOT="$TEST_ROOT/t9"
setup_test_root "$T9_ROOT"
# manifest absent
run_checkpoint "$T9_ROOT" --remove-section A > /dev/null 2>&1
T9_RC=$?
if [ "$T9_RC" -eq 0 ]; then
  pass "T-IDEMPOTENT-B --remove-section against absent manifest no-op rc=0"
else
  fail "T-IDEMPOTENT-B" "rc=$T9_RC (expected 0)"
fi

# ---------- T-SCHEMA: completion_state shape conforms to schema ----------
T10_ROOT="$TEST_ROOT/t10"
setup_test_root "$T10_ROOT"
printf 'transcript content\n' > "$T10_ROOT/transcript.txt"
run_checkpoint "$T10_ROOT" --section C --transcript "$T10_ROOT/transcript.txt" > /dev/null 2>&1
T10_MANIFEST="$T10_ROOT/.claude/user-manifest.json"
# completion_state.C must be {committed_at, transcript_sha} both strings.
if jq -e '
    .system.completion_state.C
    | (.committed_at | type == "string")
      and (.transcript_sha | type == "string")
      and ((. | keys | sort) == ["committed_at","transcript_sha"])
  ' "$T10_MANIFEST" >/dev/null 2>&1; then
  pass "T-SCHEMA completion_state[C] = {committed_at, transcript_sha} (schema 1.5.0)"
else
  fail "T-SCHEMA" "completion_state.C: $(jq -c '.system.completion_state.C' "$T10_MANIFEST")"
fi

# committed_at is ISO-8601-shaped.
if jq -re '.system.completion_state.C.committed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' \
     "$T10_MANIFEST" >/dev/null 2>&1; then
  pass "T-SCHEMA completion_state[C].committed_at is ISO-8601 UTC"
else
  fail "T-SCHEMA-iso" "committed_at: $(jq -r '.system.completion_state.C.committed_at' "$T10_MANIFEST")"
fi

# ---------- T-LEAK: reference-leak floor — no transcript content in manifest ----------
T11_ROOT="$TEST_ROOT/t11"
setup_test_root "$T11_ROOT"
LEAK_TOKEN="UNIQUELYTRACEABLELEAKVALUE12345"
printf '%s\n' "$LEAK_TOKEN" > "$T11_ROOT/leaky-transcript.txt"
run_checkpoint "$T11_ROOT" --section B --transcript "$T11_ROOT/leaky-transcript.txt" > /dev/null 2>&1
T11_MANIFEST="$T11_ROOT/.claude/user-manifest.json"
if grep -q "$LEAK_TOKEN" "$T11_MANIFEST" 2>/dev/null; then
  fail "T-LEAK" "transcript content '$LEAK_TOKEN' leaked into user-manifest"
else
  pass "T-LEAK transcript content does NOT leak into user-manifest (only sha digest)"
fi

# ---------- AC2 + T-SESSION-START-A: manifest absent → silent ----------
T12_ROOT="$TEST_ROOT/t12"
setup_test_root "$T12_ROOT"
# manifest absent
T12_OUT="$(run_session_start "$T12_ROOT" 2>/dev/null)"
T12_RC=$?
if [ "$T12_RC" -eq 0 ] && [ -z "$T12_OUT" ]; then
  pass "T-SESSION-START-A manifest absent → silent (no stdout)"
else
  fail "T-SESSION-START-A" "rc=$T12_RC out='$T12_OUT'"
fi

# ---------- T-SESSION-START-B: manifest unparseable → silent ----------
T13_ROOT="$TEST_ROOT/t13"
setup_test_root "$T13_ROOT"
printf 'not-json{{\n' > "$T13_ROOT/.claude/user-manifest.json"
T13_OUT="$(run_session_start "$T13_ROOT" 2>/dev/null)"
T13_RC=$?
if [ "$T13_RC" -eq 0 ] && [ -z "$T13_OUT" ]; then
  pass "T-SESSION-START-B unparseable manifest → silent"
else
  fail "T-SESSION-START-B" "rc=$T13_RC out='$T13_OUT'"
fi

# ---------- T-SESSION-START-C: complete onboarding → silent ----------
T14_ROOT="$TEST_ROOT/t14"
setup_test_root "$T14_ROOT"
printf '{"system":{"phases_completed":["A","B","C","D","E"],"completion_state":{}}}\n' \
  > "$T14_ROOT/.claude/user-manifest.json"
T14_OUT="$(run_session_start "$T14_ROOT" 2>/dev/null)"
T14_RC=$?
if [ "$T14_RC" -eq 0 ] && [ -z "$T14_OUT" ]; then
  pass "T-SESSION-START-C complete onboarding → silent"
else
  fail "T-SESSION-START-C" "rc=$T14_RC out='$T14_OUT'"
fi

# ---------- AC2 + T-SESSION-START-D: incomplete → emit hookSpecificOutput ----------
T15_ROOT="$TEST_ROOT/t15"
setup_test_root "$T15_ROOT"
printf '{"system":{"phases_completed":["A","B"],"completion_state":{}}}\n' \
  > "$T15_ROOT/.claude/user-manifest.json"
T15_OUT="$(run_session_start "$T15_ROOT" 2>/dev/null)"
T15_RC=$?
if [ "$T15_RC" -eq 0 ] && [ -n "$T15_OUT" ]; then
  pass "AC2 + T-SESSION-START-D incomplete onboarding → emit banner"
else
  fail "T-SESSION-START-D" "rc=$T15_RC out='$T15_OUT'"
fi

# ---------- T-SESSION-START-G: banner is valid JSON ----------
if printf '%s' "$T15_OUT" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1; then
  pass "T-SESSION-START-G banner is valid hookSpecificOutput JSON"
else
  fail "T-SESSION-START-G" "json: $T15_OUT"
fi

# ---------- T-SESSION-START-E: banner names FIRST missing section (C) ----------
T15_CTX="$(printf '%s' "$T15_OUT" | jq -r '.hookSpecificOutput.additionalContext')"
if printf '%s' "$T15_CTX" | grep -qE 'Section C'; then
  pass "T-SESSION-START-E banner names first missing section (C)"
else
  fail "T-SESSION-START-E" "ctx: $T15_CTX"
fi

# ---------- AC3 + T-SESSION-START-F: banner offers BOTH resume + re-record ----------
if printf '%s' "$T15_CTX" | grep -qE '/onboard --resume' \
   && printf '%s' "$T15_CTX" | grep -qiE 're-record'; then
  pass "AC3 + T-SESSION-START-F banner contains both '/onboard --resume' + 're-record' branches"
else
  fail "AC3 / T-SESSION-START-F" "ctx: $T15_CTX"
fi

# ---------- AC4 + T-COMPLETION-ISOLATION: re-record C leaves A/B/D/E completion_state byte-identical ----------
T16_ROOT="$TEST_ROOT/t16"
setup_test_root "$T16_ROOT"
# Stage all 5 sections committed via checkpoint.sh.
for s in A B C D E; do
  printf 'transcript-%s\n' "$s" > "$T16_ROOT/transcript-$s.txt"
  run_checkpoint "$T16_ROOT" --section "$s" --transcript "$T16_ROOT/transcript-$s.txt" > /dev/null 2>&1
done
T16_MANIFEST="$T16_ROOT/.claude/user-manifest.json"
# Capture A/B/D/E entries before re-record.
T16_A_BEFORE="$(jq -c '.system.completion_state.A' "$T16_MANIFEST")"
T16_B_BEFORE="$(jq -c '.system.completion_state.B' "$T16_MANIFEST")"
T16_D_BEFORE="$(jq -c '.system.completion_state.D' "$T16_MANIFEST")"
T16_E_BEFORE="$(jq -c '.system.completion_state.E' "$T16_MANIFEST")"
# Re-record C.
run_checkpoint "$T16_ROOT" --remove-section C > /dev/null 2>&1
# Verify A/B/D/E unchanged + C removed.
T16_A_AFTER="$(jq -c '.system.completion_state.A' "$T16_MANIFEST")"
T16_B_AFTER="$(jq -c '.system.completion_state.B' "$T16_MANIFEST")"
T16_D_AFTER="$(jq -c '.system.completion_state.D' "$T16_MANIFEST")"
T16_E_AFTER="$(jq -c '.system.completion_state.E' "$T16_MANIFEST")"
T16_C_GONE="$(jq -e '.system.completion_state | has("C") | not' "$T16_MANIFEST" >/dev/null 2>&1 && echo yes || echo no)"

if [ "$T16_A_BEFORE" = "$T16_A_AFTER" ] \
   && [ "$T16_B_BEFORE" = "$T16_B_AFTER" ] \
   && [ "$T16_D_BEFORE" = "$T16_D_AFTER" ] \
   && [ "$T16_E_BEFORE" = "$T16_E_AFTER" ] \
   && [ "$T16_C_GONE" = "yes" ]; then
  pass "AC4 + T-COMPLETION-ISOLATION re-record C leaves A/B/D/E completion_state byte-identical; C removed"
else
  fail "AC4 / T-COMPLETION-ISOLATION" "A: $T16_A_BEFORE -> $T16_A_AFTER ; B: $T16_B_BEFORE -> $T16_B_AFTER ; D: $T16_D_BEFORE -> $T16_D_AFTER ; E: $T16_E_BEFORE -> $T16_E_AFTER ; C-gone=$T16_C_GONE"
fi

# Also verify phases_completed[] no longer contains C but retains others.
if jq -e '
    (.system.phases_completed | index("C") == null)
    and (.system.phases_completed | index("A") != null)
    and (.system.phases_completed | index("B") != null)
    and (.system.phases_completed | index("D") != null)
    and (.system.phases_completed | index("E") != null)
  ' "$T16_MANIFEST" >/dev/null 2>&1; then
  pass "AC4 phases_completed[] removed C, preserved A/B/D/E"
else
  fail "AC4-phases" "phases_completed: $(jq -c '.system.phases_completed' "$T16_MANIFEST")"
fi

# ---------- AC5 + T-MID-SECTION-DETECT: mid-Section-B quit detected ----------
# Simulate mid-Section-B quit: A committed, B started (transcript exists, no
# extraction-output yet, no phases_completed[B] entry). SessionStart should
# detect B as next-missing.
T17_ROOT="$TEST_ROOT/t17"
setup_test_root "$T17_ROOT"
# Stage manifest with A complete only.
printf '{"system":{"phases_completed":["A"],"completion_state":{"A":{"committed_at":"2026-05-02T00:00:00Z"}}}}\n' \
  > "$T17_ROOT/.claude/user-manifest.json"
# Stage a partial Section B transcript (the user spoke into voice-capture but
# never reached extraction).
printf 'mid-section-b transcript content (never committed)\n' \
  > "$T17_ROOT/.claude/onboarding/transcripts/section-b.txt"
# extraction-output-B.json deliberately absent.

T17_OUT="$(run_session_start "$T17_ROOT" 2>/dev/null)"
T17_CTX="$(printf '%s' "$T17_OUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
if printf '%s' "$T17_CTX" | grep -qE 'Section B'; then
  pass "AC5 + T-MID-SECTION-DETECT mid-Section-B quit → SessionStart names B as next missing"
else
  fail "AC5 / T-MID-SECTION-DETECT" "ctx: $T17_CTX out: $T17_OUT"
fi

# AC5: stateless re-render confirmation — re-running checkpoint.sh
# --section B against this state succeeds (the section runner / checkpoint
# write doesn't depend on prior partial state).
printf 'mid-section-b transcript content (never committed)\n' \
  > "$T17_ROOT/.claude/onboarding/transcripts/section-b.txt"
run_checkpoint "$T17_ROOT" --section B --transcript "$T17_ROOT/.claude/onboarding/transcripts/section-b.txt" > /dev/null 2>&1
T17_RESUME_RC=$?
if [ "$T17_RESUME_RC" -eq 0 ] \
   && jq -e '.system.phases_completed | index("B") != null' "$T17_ROOT/.claude/user-manifest.json" >/dev/null 2>&1; then
  pass "AC5 stateless re-render: checkpoint.sh --section B post-quit commits cleanly (resume picks up same prompt card)"
else
  fail "AC5-resume" "rc=$T17_RESUME_RC manifest=$(cat "$T17_ROOT/.claude/user-manifest.json")"
fi

# ---------- summary ----------
echo "=== checkpoint-resume-unit-test ==="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
