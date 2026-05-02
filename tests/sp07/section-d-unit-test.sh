#!/bin/bash
# tests/sp07/section-d-unit-test.sh — synthetic unit tests for SP07 T-5c
# onboarding/ux/section-d.sh.
#
# Validates the 7 acceptance criteria from
# ~/.claude-plans/71-claude-foundations-engine-v2/07-onboarder-ux/tasks.md T-5
# (T-5c subset — Section D + initial-job-setup hook; T-5a covered Section B,
# T-5b covered Section C + archetype-inference). T-5c CLOSES T-5 fully.
#
#   AC1 — Section D invokes voice-capture or typed-textarea fallback with
#         correct PROMPT_CARD_PATH (mirror T-5a/T-5b)
#   AC2 — Section D runs SP01 extraction prompt with correct schema slice
#         (direct_qs.D-* from q-field-map.json) + 4-placeholder substitution
#   AC3 — Confidence gates applied per field (HIGH ≥0.85 / MID 0.5-0.85 /
#         LOW <0.5 → follow-up field-path recorded in audit) (mirror T-5a/T-5b)
#   AC4 — Opt-out surfaces #7 (hook-advisory) + #8 (checkpoint-relaxed) +
#         #9 (initial-job-skipped) + #10 (tripwires-skipped) routable from
#         within Section D without aborting; --auto-opt-out elects all four
#   AC5 — Schema fragment merged atomically: extraction-output-D.json
#         written via tmp+rename with correct shape (CFF-S77-1 inherited)
#   AC6 — **NEW for T-5c**: initial-job-setup.sh invoked after Section D
#         extraction when --opt-out-initial-job NOT elected; SKIPPED when
#         opt-out elected (and populated.O.jobs forced to [])
#   AC7 — Per-section JSONL audit entry written with confidence_map +
#         source_spans + corrections[] + follow_ups[] + 9-key shape per
#         SKILL.md L141 (mirror T-5a/T-5b)
#
# Plus structural / reference-leak / D-4-default guardrails:
#
#   T-STRUCT-A — extraction-output-D.json conforms to expected envelope
#                (section_id="D", extraction_mode="transcript",
#                 populated/confidence/source_spans/missing_required/conflicts/
#                 follow_up/opt_outs/run_id/timestamp)
#   T-STRUCT-B — JSONL audit has all 9 SKILL.md L141 keys
#   T-STRUCT-C — follow_ups[] contains field-path strings only (no full
#                follow-up text leak; reference-leak floor)
#   T-STRUCT-D — Pass 1 (no EXTRACTION_OUTPUT_OVERRIDE) exits 5 + stages
#                compiled prompt
#   T-STRUCT-E — compiled prompt has all 4 placeholders substituted
#                (no `<<<{transcript}>>>` etc. remaining)
#   T-STRUCT-F — compiled prompt's schema-slice section contains D-1..D-4
#   T-STRUCT-G — missing PROMPT_CARD_PATH → exit 2; missing Section A
#                discovery context → exit 2
#   T-STRUCT-H — voice probe rc=4 falls back to typed-textarea dispatch
#   T-D4-DEFAULT — D-4 notification_style absent in extraction → engine
#                  writes "digest" per q-field-map default_value
#   T-IJS-A    — initial-job-setup invoked with ORCHESTRATION_JSON wrapper
#                containing jobs[0].id + schedule {hour, minute, dow?}
#   T-IJS-B    — --opt-out-initial-job SKIPS the invocation AND writes
#                populated.O.jobs = [] AND drops O.jobs[0].id
#   T-IJS-C    — librarian schedule resolves to hour=6 minute=0 (no dow)
#   T-IJS-D    — architect schedule resolves to hour=6 minute=0 dow=[1]
#
# Hermetic: per-test fake $HOME with mocked Section A discovery context,
# pre-staged or stub-captured transcript, stub voice-capture / typed-
# textarea binaries (via VOICE_CAPTURE_BIN / TYPED_TEXTAREA_BIN env knobs),
# and stub initial-job-setup binary (via INITIAL_JOB_SETUP_BIN env knob).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/onboarding/ux/section-d.sh"
Q_FIELD_MAP="$REPO_ROOT/onboarding/q-field-map.json"
PROMPT_TEMPLATE="$REPO_ROOT/onboarding/extraction-prompts/section-D.md"

if [ ! -x "$SCRIPT" ]; then echo "FAIL: cannot exec $SCRIPT"; exit 2; fi
if [ ! -r "$Q_FIELD_MAP" ]; then echo "FAIL: cannot read $Q_FIELD_MAP"; exit 2; fi
if [ ! -r "$PROMPT_TEMPLATE" ]; then echo "FAIL: cannot read $PROMPT_TEMPLATE"; exit 2; fi

TEST_ROOT="$(mktemp -d -t section-d-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 -- $2"; }

# Common per-test scaffold. Sets up:
#   $1/.claude/onboarding/audit/                 — audit log dir
#   $1/.claude/onboarding/transcripts/           — transcript dir
#   $1/.claude/onboarding/extraction-output-A.json — Section A discovery context
#   $1/prompt-card.txt                           — stub Section D prompt card
setup_test_root() {
  local root="$1"
  mkdir -p "$root/.claude/onboarding/audit" \
           "$root/.claude/onboarding/transcripts"
  cat > "$root/.claude/onboarding/extraction-output-A.json" <<'EOF'
{
  "section_id": "A",
  "extraction_mode": "deterministic",
  "populated": {
    "U.identity.name": "Test Adopter",
    "U.identity.email": "test@example.org",
    "U.system.timezone": "America/New_York",
    "U.paths.vault_root": "/tmp/test-vault",
    "U.tools.messaging": []
  },
  "confidence": {},
  "source_spans": {},
  "missing_required": [],
  "conflicts": [],
  "follow_up": null,
  "run_id": "test-run-A",
  "timestamp": "2026-05-01T00:00:00Z"
}
EOF
  # Stub prompt card. Caller would normally anchor-extract from
  # onboarder-design.md section 6; we pre-stage a minimal proxy here.
  cat > "$root/prompt-card.txt" <<'EOF'
Section D prompt card stub. Four questions about autonomy, first scheduled
job, architect concerns (conditional), and notification style.
EOF
}

# Pre-stage a section-d transcript so the capture step skips. Used by
# tests focusing on Pass 2 logic.
stage_transcript() {
  local root="$1"
  printf 'Synthetic Section D transcript content for tests.\n' \
    > "$root/.claude/onboarding/transcripts/section-d.txt"
}

# Build a stub extraction-output-D JSON file with controllable shape.
# $1 = output path; $2 = job_id ("librarian" | "architect" | ""); when empty
# emit O.jobs:[] (model-side opt-out shape); $3 = confidence map (compact JSON).
# $4 = optional override populated map (full JSON object); when set replaces
# the default Section D populated.
build_extraction_stub() {
  local out="$1" job="$2" conf="$3" populated_override="${4:-}"
  local populated
  if [ -n "$populated_override" ]; then
    populated="$populated_override"
  elif [ -n "$job" ]; then
    populated=$(jq -nc --arg j "$job" '{
      "U.behavioral.autonomy": "balanced",
      "O.jobs[0].id": $j,
      "U.behavioral.hook_preferences.notification_style": "digest"
    }')
  else
    populated='{
      "U.behavioral.autonomy": "balanced",
      "O.jobs": [],
      "U.behavioral.hook_preferences.notification_style": "digest"
    }'
  fi
  jq -nc --argjson pop "$populated" --argjson conf "$conf" '{
    section_id: "D",
    extraction_mode: "transcript",
    populated: $pop,
    confidence: $conf,
    source_spans: {
      "U.behavioral.autonomy": "balanced is fine",
      "O.jobs[0].id": "librarian for daily cleanup"
    },
    missing_required: [],
    conflicts: [],
    follow_up: null
  }' > "$out"
}

# Stub voice-capture / typed-textarea binaries that record their args + write
# a deterministic transcript. Used for AC1 dispatch verification.
build_capture_stubs() {
  local root="$1"
  cat > "$root/stub-voice.sh" <<'STUB'
#!/bin/bash
SECTION_ID="$1"
PROMPT_CARD="$2"
echo "voice|$SECTION_ID|$PROMPT_CARD" >> "$STUB_LOG"
mkdir -p "$TRANSCRIPT_DIR"
printf 'voice-stub-content\n' > "$TRANSCRIPT_DIR/section-d.txt"
printf '%s\n' "$TRANSCRIPT_DIR/section-d.txt"
exit "${STUB_VOICE_RC:-0}"
STUB
  cat > "$root/stub-typed.sh" <<'STUB'
#!/bin/bash
SECTION_ID="$1"
PROMPT_CARD="$2"
echo "typed|$SECTION_ID|$PROMPT_CARD" >> "$STUB_LOG"
mkdir -p "$TRANSCRIPT_DIR"
printf 'typed-stub-content\n' > "$TRANSCRIPT_DIR/section-d.txt"
printf '%s\n' "$TRANSCRIPT_DIR/section-d.txt"
exit 0
STUB
  chmod +x "$root/stub-voice.sh" "$root/stub-typed.sh"
}

# Stub initial-job-setup binary. Records caller's ORCHESTRATION_JSON contents
# + AUTO_CONFIRM env into $STUB_IJS_LOG and $STUB_IJS_INPUT for inspection.
# Tunable via STUB_IJS_RC env knob (default 0).
build_ijs_stub() {
  local root="$1"
  cat > "$root/stub-ijs.sh" <<'STUB'
#!/bin/bash
ORCH="${ORCHESTRATION_JSON:-}"
AC="${AUTO_CONFIRM:-0}"
echo "ijs|orch=$ORCH|auto_confirm=$AC" >> "$STUB_IJS_LOG"
if [ -n "$ORCH" ] && [ -r "$ORCH" ]; then
  cp "$ORCH" "$STUB_IJS_INPUT"
fi
exit "${STUB_IJS_RC:-0}"
STUB
  chmod +x "$root/stub-ijs.sh"
}

# Common env-bound script invocation. $1 = test root; remaining args appended.
# Forwards stub binaries when their env knobs are pre-set by the caller.
run_script() {
  local root="$1"; shift
  HOME="$root" \
  CLAUDE_HOME="$root/.claude" \
  INPUTS_DIR="$root/.claude/onboarding" \
  AUDIT_LOG="$root/.claude/onboarding/audit/section-d.jsonl" \
  TRANSCRIPT_DIR="$root/.claude/onboarding/transcripts" \
  Q_FIELD_MAP="$Q_FIELD_MAP" \
  EXTRACTION_PROMPT_TEMPLATE="$PROMPT_TEMPLATE" \
  PROMPT_CARD_PATH="$root/prompt-card.txt" \
  "$SCRIPT" "$@"
}

# ---------- T-STRUCT-D + T-STRUCT-E + T-STRUCT-F: Pass 1 happy path ----------
T1_ROOT="$TEST_ROOT/t1"
setup_test_root "$T1_ROOT"
build_capture_stubs "$T1_ROOT"
T1_OUT="$TEST_ROOT/t1.out"
STUB_LOG="$T1_ROOT/stub.log" \
TRANSCRIPT_DIR="$T1_ROOT/.claude/onboarding/transcripts" \
VOICE_CAPTURE_BIN="$T1_ROOT/stub-voice.sh" \
TYPED_TEXTAREA_BIN="$T1_ROOT/stub-typed.sh" \
  run_script "$T1_ROOT" > "$T1_OUT" 2>&1
T1_RC=$?
T1_COMPILED="$T1_ROOT/.claude/onboarding/extraction-prompt-D.compiled.txt"

if [ "$T1_RC" -eq 5 ] && [ -f "$T1_COMPILED" ]; then
  pass "T-STRUCT-D Pass 1 exits 5 with compiled prompt staged"
else
  fail "T-STRUCT-D" "rc=$T1_RC, compiled_exists=$([ -f "$T1_COMPILED" ] && echo y || echo n)"
fi

# T-STRUCT-E: compiled prompt has all 4 placeholders substituted (none remain).
if grep -q '<<<{transcript}>>>' "$T1_COMPILED" 2>/dev/null \
   || grep -q '<<<{section_prompt_card}>>>' "$T1_COMPILED" 2>/dev/null \
   || grep -q '<<<{schema_skeleton_slice}>>>' "$T1_COMPILED" 2>/dev/null \
   || grep -q '<<<{discovery_context}>>>' "$T1_COMPILED" 2>/dev/null; then
  fail "T-STRUCT-E" "compiled prompt still contains <<<{...}>>> placeholders"
else
  pass "T-STRUCT-E compiled prompt has all 4 placeholders substituted"
fi

# T-STRUCT-F + AC2: schema slice contains D-1..D-4.
if grep -q '"D-1"' "$T1_COMPILED" 2>/dev/null \
   && grep -q '"D-2"' "$T1_COMPILED" 2>/dev/null \
   && grep -q '"D-3"' "$T1_COMPILED" 2>/dev/null \
   && grep -q '"D-4"' "$T1_COMPILED" 2>/dev/null; then
  pass "T-STRUCT-F + AC2 schema slice carries D-1..D-4 from q-field-map.json"
else
  fail "T-STRUCT-F + AC2" "compiled prompt missing one of D-1..D-4"
fi

# AC2 also verifies discovery context is substituted (Section A's name appears).
if grep -q 'Test Adopter' "$T1_COMPILED" 2>/dev/null; then
  pass "AC2 discovery_context substituted (Section A populated keys present in compiled prompt)"
else
  fail "AC2-discovery-substitution" "Section A name 'Test Adopter' not found in compiled prompt"
fi

# AC1 dispatch: stub voice-capture was called with section-id + prompt-card.
if [ -f "$T1_ROOT/stub.log" ] && grep -q '^voice|D|' "$T1_ROOT/stub.log"; then
  pass "AC1 voice-capture dispatched with SECTION_ID=D + PROMPT_CARD_PATH"
else
  fail "AC1-voice-dispatch" "stub.log did not record voice|D|... entry: $(cat "$T1_ROOT/stub.log" 2>/dev/null)"
fi

# ---------- AC1: --typed-only routes directly to typed-textarea ----------
T2_ROOT="$TEST_ROOT/t2"
setup_test_root "$T2_ROOT"
build_capture_stubs "$T2_ROOT"
STUB_LOG="$T2_ROOT/stub.log" \
TRANSCRIPT_DIR="$T2_ROOT/.claude/onboarding/transcripts" \
VOICE_CAPTURE_BIN="$T2_ROOT/stub-voice.sh" \
TYPED_TEXTAREA_BIN="$T2_ROOT/stub-typed.sh" \
  run_script "$T2_ROOT" --typed-only > /dev/null 2>&1
if [ -f "$T2_ROOT/stub.log" ] \
   && grep -q '^typed|D|' "$T2_ROOT/stub.log" \
   && ! grep -q '^voice|' "$T2_ROOT/stub.log"; then
  pass "AC1 --typed-only dispatches to typed-textarea (skips voice probe)"
else
  fail "AC1-typed-only" "stub.log: $(cat "$T2_ROOT/stub.log" 2>/dev/null)"
fi

# ---------- T-STRUCT-H: voice rc=4 falls back to typed-textarea ----------
T3_ROOT="$TEST_ROOT/t3"
setup_test_root "$T3_ROOT"
build_capture_stubs "$T3_ROOT"
STUB_LOG="$T3_ROOT/stub.log" \
STUB_VOICE_RC=4 \
TRANSCRIPT_DIR="$T3_ROOT/.claude/onboarding/transcripts" \
VOICE_CAPTURE_BIN="$T3_ROOT/stub-voice.sh" \
TYPED_TEXTAREA_BIN="$T3_ROOT/stub-typed.sh" \
  run_script "$T3_ROOT" > /dev/null 2>&1
if grep -q '^voice|' "$T3_ROOT/stub.log" \
   && grep -q '^typed|' "$T3_ROOT/stub.log"; then
  pass "T-STRUCT-H voice rc=4 falls back to typed-textarea dispatch"
else
  fail "T-STRUCT-H" "stub.log: $(cat "$T3_ROOT/stub.log" 2>/dev/null)"
fi

# ---------- AC5 + AC7 + T-STRUCT-A + T-STRUCT-B + AC6 + T-IJS-A/C ----------
# Pass 2 happy path with librarian job — initial-job-setup invoked with
# ORCHESTRATION_JSON wrapper carrying jobs[0].id="librarian" + schedule
# {hour:6, minute:0} (no dow for librarian).
T4_ROOT="$TEST_ROOT/t4"
setup_test_root "$T4_ROOT"
stage_transcript "$T4_ROOT"
build_ijs_stub "$T4_ROOT"
T4_STUB="$T4_ROOT/.claude/onboarding/extraction-stub-D.json"
build_extraction_stub "$T4_STUB" "librarian" '{"U.behavioral.autonomy":0.95,"O.jobs[0].id":0.9,"U.behavioral.hook_preferences.notification_style":0.85}'
STUB_IJS_LOG="$T4_ROOT/ijs.log" \
STUB_IJS_INPUT="$T4_ROOT/ijs-input.json" \
STUB_IJS_RC=0 \
INITIAL_JOB_SETUP_BIN="$T4_ROOT/stub-ijs.sh" \
EXTRACTION_OUTPUT_OVERRIDE="$T4_STUB" \
  run_script "$T4_ROOT" --auto-confirm > "$TEST_ROOT/t4.out" 2>&1
T4_RC=$?
T4_FRAG="$T4_ROOT/.claude/onboarding/extraction-output-D.json"
T4_AUDIT="$T4_ROOT/.claude/onboarding/audit/section-d.jsonl"

if [ "$T4_RC" -eq 0 ] && [ -f "$T4_FRAG" ] && [ -f "$T4_AUDIT" ]; then
  pass "AC5 Pass 2 happy path → extraction-output-D + section-d audit written, rc=0"
else
  fail "AC5-pass2" "rc=$T4_RC frag=$([ -f "$T4_FRAG" ] && echo y || echo n) audit=$([ -f "$T4_AUDIT" ] && echo y || echo n); out=$(cat "$TEST_ROOT/t4.out")"
fi

# T-STRUCT-A: extraction-output-D.json envelope shape.
if jq -e '
    .section_id == "D"
    and .extraction_mode == "transcript"
    and (.populated | type == "object")
    and (.confidence | type == "object")
    and (.source_spans | type == "object")
    and (.missing_required | type == "array")
    and (.conflicts | type == "array")
    and has("follow_up")
    and (.opt_outs | type == "array")
    and (.run_id | type == "string")
    and (.timestamp | type == "string")
  ' "$T4_FRAG" >/dev/null 2>&1; then
  pass "T-STRUCT-A extraction-output-D envelope shape conforms"
else
  fail "T-STRUCT-A" "envelope diverges; got: $(jq -c '. | del(.populated, .confidence, .source_spans)' "$T4_FRAG" 2>/dev/null)"
fi

# T-STRUCT-B: JSONL audit has all 9 SKILL.md L141 keys.
if jq -e '
    has("section_id") and has("run_id") and has("ts") and has("opt_outs")
    and has("confidence_map") and has("source_spans") and has("corrections")
    and has("follow_ups") and has("manifest_paths_written")
  ' "$T4_AUDIT" >/dev/null 2>&1; then
  pass "T-STRUCT-B audit JSONL carries all 9 SKILL.md L141 fields"
else
  fail "T-STRUCT-B" "audit missing required keys; got: $(cat "$T4_AUDIT")"
fi

# AC7: confidence_map + source_spans copied through; corrections=[]; opt_outs=[].
if jq -e '
    .section_id == "D"
    and (.confidence_map."U.behavioral.autonomy") == 0.95
    and (.source_spans."U.behavioral.autonomy") == "balanced is fine"
    and .corrections == []
    and .opt_outs == []
  ' "$T4_AUDIT" >/dev/null 2>&1; then
  pass "AC7 audit carries confidence_map + source_spans + corrections=[] + opt_outs=[]"
else
  fail "AC7" "audit shape diverges; got: $(cat "$T4_AUDIT")"
fi

# AC6 + T-IJS-A: initial-job-setup invoked exactly once with ORCHESTRATION_JSON.
if [ -f "$T4_ROOT/ijs.log" ] \
   && grep -q '^ijs|orch=' "$T4_ROOT/ijs.log" \
   && [ "$(grep -c '^ijs|' "$T4_ROOT/ijs.log")" -eq 1 ]; then
  pass "AC6 + T-IJS-A initial-job-setup.sh invoked exactly once with ORCHESTRATION_JSON env"
else
  fail "AC6-T-IJS-A" "ijs.log: $(cat "$T4_ROOT/ijs.log" 2>/dev/null)"
fi

# T-IJS-A wrapper shape: jobs[0].id == "librarian" + schedule.{hour, minute}.
# T-IJS-C: librarian schedule resolves to hour=6 minute=0 NO dow.
if [ -f "$T4_ROOT/ijs-input.json" ] \
   && jq -e '
       (.jobs | length) == 1
       and .jobs[0].id == "librarian"
       and .jobs[0].schedule.hour == 6
       and .jobs[0].schedule.minute == 0
       and (.jobs[0].schedule | has("dow") | not)
     ' "$T4_ROOT/ijs-input.json" >/dev/null 2>&1; then
  pass "T-IJS-A + T-IJS-C ORCHESTRATION_JSON wrapper {jobs:[{id:librarian, schedule:{hour:6,minute:0}}]} (no dow for librarian)"
else
  fail "T-IJS-A-shape" "ijs-input.json: $(cat "$T4_ROOT/ijs-input.json" 2>/dev/null)"
fi

# AUTO_CONFIRM forwarded to initial-job-setup stub.
if grep -q 'auto_confirm=1' "$T4_ROOT/ijs.log" 2>/dev/null; then
  pass "AC6 AUTO_CONFIRM=1 forwarded to initial-job-setup invocation"
else
  fail "AC6-auto-confirm" "ijs.log: $(cat "$T4_ROOT/ijs.log")"
fi

# ---------- T-IJS-D: architect schedule resolves to hour=6 minute=0 dow=[1] ----------
T5_ROOT="$TEST_ROOT/t5"
setup_test_root "$T5_ROOT"
stage_transcript "$T5_ROOT"
build_ijs_stub "$T5_ROOT"
T5_STUB="$T5_ROOT/.claude/onboarding/extraction-stub-D.json"
build_extraction_stub "$T5_STUB" "architect" '{"U.behavioral.autonomy":0.9,"O.jobs[0].id":0.9}'
STUB_IJS_LOG="$T5_ROOT/ijs.log" \
STUB_IJS_INPUT="$T5_ROOT/ijs-input.json" \
INITIAL_JOB_SETUP_BIN="$T5_ROOT/stub-ijs.sh" \
EXTRACTION_OUTPUT_OVERRIDE="$T5_STUB" \
  run_script "$T5_ROOT" --auto-confirm > /dev/null 2>&1
T5_FRAG="$T5_ROOT/.claude/onboarding/extraction-output-D.json"

if [ -f "$T5_ROOT/ijs-input.json" ] \
   && jq -e '
       .jobs[0].id == "architect"
       and .jobs[0].schedule.hour == 6
       and .jobs[0].schedule.minute == 0
       and (.jobs[0].schedule.dow | type == "array")
       and .jobs[0].schedule.dow[0] == 1
     ' "$T5_ROOT/ijs-input.json" >/dev/null 2>&1; then
  pass "T-IJS-D architect schedule resolves to hour=6 minute=0 dow=[1] (Monday weekly)"
else
  fail "T-IJS-D" "ijs-input.json: $(cat "$T5_ROOT/ijs-input.json" 2>/dev/null)"
fi

# ---------- T-D4-DEFAULT: D-4 absent → engine writes "digest" ----------
# Build extraction stub WITHOUT notification_style; populated lacks D-4.
T6_ROOT="$TEST_ROOT/t6"
setup_test_root "$T6_ROOT"
stage_transcript "$T6_ROOT"
build_ijs_stub "$T6_ROOT"
T6_STUB="$T6_ROOT/.claude/onboarding/extraction-stub-D.json"
T6_POPULATED='{"U.behavioral.autonomy":"strict","O.jobs[0].id":"librarian"}'
build_extraction_stub "$T6_STUB" "" '{"U.behavioral.autonomy":0.9,"O.jobs[0].id":0.9}' "$T6_POPULATED"
STUB_IJS_LOG="$T6_ROOT/ijs.log" \
STUB_IJS_INPUT="$T6_ROOT/ijs-input.json" \
INITIAL_JOB_SETUP_BIN="$T6_ROOT/stub-ijs.sh" \
EXTRACTION_OUTPUT_OVERRIDE="$T6_STUB" \
  run_script "$T6_ROOT" --auto-confirm > /dev/null 2>&1
T6_FRAG="$T6_ROOT/.claude/onboarding/extraction-output-D.json"

if jq -e '.populated."U.behavioral.hook_preferences.notification_style" == "digest"' "$T6_FRAG" >/dev/null 2>&1; then
  pass "T-D4-DEFAULT D-4 notification_style absent → engine writes 'digest'"
else
  fail "T-D4-DEFAULT" "populated: $(jq -c '.populated' "$T6_FRAG")"
fi

# T-D4-DEFAULT does NOT count as opt-out: opt_outs[] stays empty.
if jq -e '.opt_outs == []' "$T6_FRAG" >/dev/null 2>&1; then
  pass "T-D4-DEFAULT applying digest fallback does NOT add to opt_outs[]"
else
  fail "T-D4-DEFAULT-opt-outs" "opt_outs: $(jq -c '.opt_outs' "$T6_FRAG")"
fi

# ---------- AC3 + T-STRUCT-C: confidence-gate categorization ----------
# Stub uses: autonomy 0.9 (HIGH), O.jobs[0].id 0.4 (LOW).
T7_ROOT="$TEST_ROOT/t7"
setup_test_root "$T7_ROOT"
stage_transcript "$T7_ROOT"
build_ijs_stub "$T7_ROOT"
T7_STUB="$T7_ROOT/.claude/onboarding/extraction-stub-D.json"
build_extraction_stub "$T7_STUB" "librarian" '{"U.behavioral.autonomy":0.9,"O.jobs[0].id":0.4,"U.behavioral.hook_preferences.notification_style":0.85}'
STUB_IJS_LOG="$T7_ROOT/ijs.log" \
STUB_IJS_INPUT="$T7_ROOT/ijs-input.json" \
INITIAL_JOB_SETUP_BIN="$T7_ROOT/stub-ijs.sh" \
EXTRACTION_OUTPUT_OVERRIDE="$T7_STUB" \
  run_script "$T7_ROOT" --auto-confirm > /dev/null 2>&1
T7_AUDIT="$T7_ROOT/.claude/onboarding/audit/section-d.jsonl"

if jq -e '
    (.follow_ups | length) >= 1
    and (.follow_ups | map(. == "O.jobs[0].id") | any)
  ' "$T7_AUDIT" >/dev/null 2>&1; then
  pass "AC3 LOW-confidence field 'O.jobs[0].id' (0.4 < 0.5) recorded in follow_ups[]"
else
  fail "AC3-low-confidence" "follow_ups: $(jq -c '.follow_ups' "$T7_AUDIT")"
fi

# T-STRUCT-C: follow_ups[] contains field-path strings only (no full text leak).
if jq -e '.follow_ups | all(test("^[UO]\\."))' "$T7_AUDIT" >/dev/null 2>&1; then
  pass "T-STRUCT-C follow_ups[] contains field-path strings only (no full follow-up text)"
else
  fail "T-STRUCT-C" "follow_ups carries non-field-path entries: $(jq -c '.follow_ups' "$T7_AUDIT")"
fi

# AC3 HIGH-confidence fields don't appear in follow_ups.
if jq -e '.follow_ups | (map(. == "U.behavioral.autonomy") | any) | not' "$T7_AUDIT" >/dev/null 2>&1; then
  pass "AC3 HIGH-confidence field 'U.behavioral.autonomy' (0.9 ≥ 0.85) NOT in follow_ups[]"
else
  fail "AC3-high-confidence-leak" "HIGH field appeared in follow_ups: $(jq -c '.follow_ups' "$T7_AUDIT")"
fi

# ---------- AC4: opt-out routing per surface ----------

# Surface #7 (--opt-out-hooks): U.behavioral.hook_preferences.r43_advisory_mode
# = true + opt_outs[hook_advisory]. Initial-job-setup STILL runs (independent
# surface).
T8_ROOT="$TEST_ROOT/t8"
setup_test_root "$T8_ROOT"
stage_transcript "$T8_ROOT"
build_ijs_stub "$T8_ROOT"
T8_STUB="$T8_ROOT/.claude/onboarding/extraction-stub-D.json"
build_extraction_stub "$T8_STUB" "librarian" '{"U.behavioral.autonomy":0.9,"O.jobs[0].id":0.9}'
STUB_IJS_LOG="$T8_ROOT/ijs.log" \
STUB_IJS_INPUT="$T8_ROOT/ijs-input.json" \
INITIAL_JOB_SETUP_BIN="$T8_ROOT/stub-ijs.sh" \
EXTRACTION_OUTPUT_OVERRIDE="$T8_STUB" \
  run_script "$T8_ROOT" --auto-confirm --opt-out-hooks > /dev/null 2>&1
T8_FRAG="$T8_ROOT/.claude/onboarding/extraction-output-D.json"
if jq -e '
    .populated."U.behavioral.hook_preferences.r43_advisory_mode" == true
    and (.opt_outs | index("hook_advisory")) != null
    and .populated."O.jobs[0].id" == "librarian"
  ' "$T8_FRAG" >/dev/null 2>&1; then
  pass "AC4 surface #7 (--opt-out-hooks) → r43_advisory_mode=true + opt_outs[hook_advisory]; job preserved"
else
  fail "AC4-hooks" "frag.populated=$(jq -c '.populated' "$T8_FRAG"); opt_outs=$(jq -c '.opt_outs' "$T8_FRAG")"
fi

# Surface #8 (--opt-out-checkpoint): checkpoint_disable_ok=true +
# opt_outs[checkpoint_relaxed].
T9_ROOT="$TEST_ROOT/t9"
setup_test_root "$T9_ROOT"
stage_transcript "$T9_ROOT"
build_ijs_stub "$T9_ROOT"
T9_STUB="$T9_ROOT/.claude/onboarding/extraction-stub-D.json"
build_extraction_stub "$T9_STUB" "librarian" '{"U.behavioral.autonomy":0.9,"O.jobs[0].id":0.9}'
STUB_IJS_LOG="$T9_ROOT/ijs.log" \
STUB_IJS_INPUT="$T9_ROOT/ijs-input.json" \
INITIAL_JOB_SETUP_BIN="$T9_ROOT/stub-ijs.sh" \
EXTRACTION_OUTPUT_OVERRIDE="$T9_STUB" \
  run_script "$T9_ROOT" --auto-confirm --opt-out-checkpoint > /dev/null 2>&1
T9_FRAG="$T9_ROOT/.claude/onboarding/extraction-output-D.json"
if jq -e '
    .populated."U.behavioral.hook_preferences.checkpoint_disable_ok" == true
    and (.opt_outs | index("checkpoint_relaxed")) != null
  ' "$T9_FRAG" >/dev/null 2>&1; then
  pass "AC4 surface #8 (--opt-out-checkpoint) → checkpoint_disable_ok=true + opt_outs[checkpoint_relaxed]"
else
  fail "AC4-checkpoint" "frag.populated=$(jq -c '.populated' "$T9_FRAG"); opt_outs=$(jq -c '.opt_outs' "$T9_FRAG")"
fi

# Surface #9 (--opt-out-initial-job): O.jobs forced to []; O.jobs[0].id dropped;
# opt_outs[initial_job_skipped]; initial-job-setup NOT invoked. T-IJS-B.
T10_ROOT="$TEST_ROOT/t10"
setup_test_root "$T10_ROOT"
stage_transcript "$T10_ROOT"
build_ijs_stub "$T10_ROOT"
T10_STUB="$T10_ROOT/.claude/onboarding/extraction-stub-D.json"
build_extraction_stub "$T10_STUB" "librarian" '{"U.behavioral.autonomy":0.9,"O.jobs[0].id":0.9}'
STUB_IJS_LOG="$T10_ROOT/ijs.log" \
STUB_IJS_INPUT="$T10_ROOT/ijs-input.json" \
INITIAL_JOB_SETUP_BIN="$T10_ROOT/stub-ijs.sh" \
EXTRACTION_OUTPUT_OVERRIDE="$T10_STUB" \
  run_script "$T10_ROOT" --auto-confirm --opt-out-initial-job > /dev/null 2>&1
T10_FRAG="$T10_ROOT/.claude/onboarding/extraction-output-D.json"
if jq -e '
    .populated."O.jobs" == []
    and (.populated | has("O.jobs[0].id") | not)
    and (.opt_outs | index("initial_job_skipped")) != null
  ' "$T10_FRAG" >/dev/null 2>&1; then
  pass "AC4 + T-IJS-B surface #9 (--opt-out-initial-job) → O.jobs:[] + drop O.jobs[0].id + opt_outs[initial_job_skipped]"
else
  fail "AC4-T-IJS-B-shape" "frag.populated=$(jq -c '.populated' "$T10_FRAG"); opt_outs=$(jq -c '.opt_outs' "$T10_FRAG")"
fi
# T-IJS-B: stub initial-job-setup binary was NOT invoked.
if [ ! -s "$T10_ROOT/ijs.log" ]; then
  pass "T-IJS-B --opt-out-initial-job SKIPS initial-job-setup invocation (ijs.log empty)"
else
  fail "T-IJS-B-skip" "ijs.log non-empty: $(cat "$T10_ROOT/ijs.log")"
fi

# Surface #10 (--opt-out-tripwires): tripwires_skipped=true +
# opt_outs[tripwires_skipped].
T11_ROOT="$TEST_ROOT/t11"
setup_test_root "$T11_ROOT"
stage_transcript "$T11_ROOT"
build_ijs_stub "$T11_ROOT"
T11_STUB="$T11_ROOT/.claude/onboarding/extraction-stub-D.json"
build_extraction_stub "$T11_STUB" "librarian" '{"U.behavioral.autonomy":0.9,"O.jobs[0].id":0.9}'
STUB_IJS_LOG="$T11_ROOT/ijs.log" \
STUB_IJS_INPUT="$T11_ROOT/ijs-input.json" \
INITIAL_JOB_SETUP_BIN="$T11_ROOT/stub-ijs.sh" \
EXTRACTION_OUTPUT_OVERRIDE="$T11_STUB" \
  run_script "$T11_ROOT" --auto-confirm --opt-out-tripwires > /dev/null 2>&1
T11_FRAG="$T11_ROOT/.claude/onboarding/extraction-output-D.json"
if jq -e '
    .populated."U.behavioral.hook_preferences.tripwires_skipped" == true
    and (.opt_outs | index("tripwires_skipped")) != null
  ' "$T11_FRAG" >/dev/null 2>&1; then
  pass "AC4 surface #10 (--opt-out-tripwires) → tripwires_skipped=true + opt_outs[tripwires_skipped]"
else
  fail "AC4-tripwires" "frag.populated=$(jq -c '.populated' "$T11_FRAG"); opt_outs=$(jq -c '.opt_outs' "$T11_FRAG")"
fi

# Blanket --auto-opt-out elects ALL FOUR surfaces. Confirms the section
# commits without aborting; initial-job-setup is NOT invoked (since #9
# was implicitly elected).
T12_ROOT="$TEST_ROOT/t12"
setup_test_root "$T12_ROOT"
stage_transcript "$T12_ROOT"
build_ijs_stub "$T12_ROOT"
T12_STUB="$T12_ROOT/.claude/onboarding/extraction-stub-D.json"
build_extraction_stub "$T12_STUB" "librarian" '{"U.behavioral.autonomy":0.9,"O.jobs[0].id":0.9}'
STUB_IJS_LOG="$T12_ROOT/ijs.log" \
STUB_IJS_INPUT="$T12_ROOT/ijs-input.json" \
INITIAL_JOB_SETUP_BIN="$T12_ROOT/stub-ijs.sh" \
EXTRACTION_OUTPUT_OVERRIDE="$T12_STUB" \
  run_script "$T12_ROOT" --auto-confirm --auto-opt-out > /dev/null 2>&1
T12_RC=$?
T12_FRAG="$T12_ROOT/.claude/onboarding/extraction-output-D.json"
if [ "$T12_RC" -eq 0 ] \
   && jq -e '
       .populated."U.behavioral.hook_preferences.r43_advisory_mode" == true
       and .populated."U.behavioral.hook_preferences.checkpoint_disable_ok" == true
       and .populated."O.jobs" == []
       and .populated."U.behavioral.hook_preferences.tripwires_skipped" == true
       and (.opt_outs | sort) == ["checkpoint_relaxed","hook_advisory","initial_job_skipped","tripwires_skipped"]
     ' "$T12_FRAG" >/dev/null 2>&1 \
   && [ ! -s "$T12_ROOT/ijs.log" ]; then
  pass "AC4 --auto-opt-out elects all four surfaces (#7 #8 #9 #10); section commits without aborting; initial-job-setup skipped"
else
  fail "AC4-blanket" "rc=$T12_RC frag=$(jq -c '. | {opt_outs, populated}' "$T12_FRAG"); ijs.log=$(cat "$T12_ROOT/ijs.log" 2>/dev/null)"
fi

# Model-side opt-out: extraction emitted O.jobs:[] (no flag); initial-job-setup
# SKIPPED naturally (no job_id present).
T13_ROOT="$TEST_ROOT/t13"
setup_test_root "$T13_ROOT"
stage_transcript "$T13_ROOT"
build_ijs_stub "$T13_ROOT"
T13_STUB="$T13_ROOT/.claude/onboarding/extraction-stub-D.json"
build_extraction_stub "$T13_STUB" "" '{"U.behavioral.autonomy":0.9}'
STUB_IJS_LOG="$T13_ROOT/ijs.log" \
STUB_IJS_INPUT="$T13_ROOT/ijs-input.json" \
INITIAL_JOB_SETUP_BIN="$T13_ROOT/stub-ijs.sh" \
EXTRACTION_OUTPUT_OVERRIDE="$T13_STUB" \
  run_script "$T13_ROOT" --auto-confirm > /dev/null 2>&1
T13_FRAG="$T13_ROOT/.claude/onboarding/extraction-output-D.json"
if jq -e '.populated."O.jobs" == []' "$T13_FRAG" >/dev/null 2>&1 \
   && [ ! -s "$T13_ROOT/ijs.log" ]; then
  pass "T-IJS-B (model-side) extraction-emitted O.jobs:[] → initial-job-setup naturally skipped"
else
  fail "T-IJS-B-model" "frag.populated=$(jq -c '.populated' "$T13_FRAG"); ijs.log=$(cat "$T13_ROOT/ijs.log")"
fi

# ---------- T-STRUCT-G: input-validation rejects ----------

# Missing PROMPT_CARD_PATH → exit 2.
T14_ROOT="$TEST_ROOT/t14"
setup_test_root "$T14_ROOT"
HOME="$T14_ROOT" \
CLAUDE_HOME="$T14_ROOT/.claude" \
INPUTS_DIR="$T14_ROOT/.claude/onboarding" \
AUDIT_LOG="$T14_ROOT/.claude/onboarding/audit/section-d.jsonl" \
TRANSCRIPT_DIR="$T14_ROOT/.claude/onboarding/transcripts" \
Q_FIELD_MAP="$Q_FIELD_MAP" \
EXTRACTION_PROMPT_TEMPLATE="$PROMPT_TEMPLATE" \
PROMPT_CARD_PATH="" \
  "$SCRIPT" > /dev/null 2>&1
T14_RC=$?
if [ "$T14_RC" -eq 2 ]; then
  pass "T-STRUCT-G missing PROMPT_CARD_PATH rejects with exit 2"
else
  fail "T-STRUCT-G-prompt" "rc=$T14_RC (expected 2)"
fi

# Missing Section A discovery context → exit 2.
T15_ROOT="$TEST_ROOT/t15"
setup_test_root "$T15_ROOT"
rm -f "$T15_ROOT/.claude/onboarding/extraction-output-A.json"
run_script "$T15_ROOT" > /dev/null 2>&1
T15_RC=$?
if [ "$T15_RC" -eq 2 ]; then
  pass "T-STRUCT-G missing Section A discovery context rejects with exit 2"
else
  fail "T-STRUCT-G-discovery" "rc=$T15_RC (expected 2)"
fi

# ---------- AC2 + T-STRUCT-A: extraction-output 'D' section_id locked ----------
T16_ROOT="$TEST_ROOT/t16"
setup_test_root "$T16_ROOT"
stage_transcript "$T16_ROOT"
T16_STUB="$T16_ROOT/.claude/onboarding/extraction-stub-bad.json"
# Wrong section_id should be rejected.
jq -nc '{section_id: "C", extraction_mode: "transcript", populated: {}, confidence: {}, source_spans: {}, missing_required: [], conflicts: [], follow_up: null}' > "$T16_STUB"
EXTRACTION_OUTPUT_OVERRIDE="$T16_STUB" \
  run_script "$T16_ROOT" > /dev/null 2>&1
T16_RC=$?
if [ "$T16_RC" -eq 3 ]; then
  pass "T-STRUCT-A section_id mismatch (C != D) rejects with exit 3"
else
  fail "T-STRUCT-A-section-id" "rc=$T16_RC (expected 3)"
fi

# ---------- initial-job-setup failure surfaces as section-d rc=3 ----------
T17_ROOT="$TEST_ROOT/t17"
setup_test_root "$T17_ROOT"
stage_transcript "$T17_ROOT"
build_ijs_stub "$T17_ROOT"
T17_STUB="$T17_ROOT/.claude/onboarding/extraction-stub-D.json"
build_extraction_stub "$T17_STUB" "librarian" '{"U.behavioral.autonomy":0.9,"O.jobs[0].id":0.9}'
STUB_IJS_LOG="$T17_ROOT/ijs.log" \
STUB_IJS_INPUT="$T17_ROOT/ijs-input.json" \
STUB_IJS_RC=4 \
INITIAL_JOB_SETUP_BIN="$T17_ROOT/stub-ijs.sh" \
EXTRACTION_OUTPUT_OVERRIDE="$T17_STUB" \
  run_script "$T17_ROOT" --auto-confirm > /dev/null 2>&1
T17_RC=$?
if [ "$T17_RC" -eq 3 ]; then
  pass "initial-job-setup rc=4 surfaces as section-d rc=3 (write/invocation error class)"
else
  fail "ijs-failure-surface" "rc=$T17_RC (expected 3)"
fi

# ---------- AC5 manifest_paths_written reflects committed populated keys ----------
# Includes D-4 default applied (notification_style='digest' was already in the
# stub for T4) — manifest_paths should reflect the 3 keys present after Pass 2.
if jq -e '
    (.manifest_paths_written | sort) == ([
      "O.jobs[0].id",
      "U.behavioral.autonomy",
      "U.behavioral.hook_preferences.notification_style"
    ] | sort)
  ' "$T4_AUDIT" >/dev/null 2>&1; then
  pass "AC5 manifest_paths_written reflects 3 populated keys (autonomy + jobs[0].id + notification_style)"
else
  fail "AC5-manifest-paths" "manifest_paths=$(jq -c '.manifest_paths_written' "$T4_AUDIT")"
fi

# ---------- summary ----------
echo "=== section-d-unit-test ==="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
