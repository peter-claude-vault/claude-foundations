#!/bin/bash
# tests/sp07/section-b-unit-test.sh — synthetic unit tests for SP07 T-5a
# onboarding/ux/section-b.sh.
#
# Validates the 6 acceptance criteria from
# ~/.claude-plans/71-claude-foundations-engine-v2/07-onboarder-ux/tasks.md T-5
# (T-5a subset — Section B; T-5b/T-5c handle Sections C/D):
#
#   AC1 — Section invokes voice-capture or typed-textarea fallback with
#         correct PROMPT_CARD_PATH
#   AC2 — Section runs SP01 extraction prompt with correct schema slice
#         (direct_qs.B-* from q-field-map.json) + 4-placeholder substitution
#   AC3 — Confidence gates applied per field (HIGH ≥0.85 / MID 0.5-0.85 /
#         LOW <0.5 → follow-up field-path recorded in audit)
#   AC4 — Opt-out surfaces #2 (org), #3 (people), #4 (tools) routable from
#         within Section B without aborting; --auto-opt-out elects all 3
#   AC5 — Schema fragment merged atomically: extraction-output-B.json
#         written via tmp+rename with correct shape
#   AC6 — Per-section JSONL audit entry written with confidence_map +
#         source_spans + corrections[] + follow_ups[] + 9-key shape per
#         SKILL.md L141
#
# Plus structural / reference-leak guardrails:
#
#   T-STRUCT-A — extraction-output-B.json conforms to expected envelope
#                (section_id="B", extraction_mode="transcript",
#                 populated/confidence/source_spans/missing_required/conflicts/
#                 follow_up/opt_outs/run_id/timestamp)
#   T-STRUCT-B — JSONL audit has all 9 SKILL.md L141 keys
#   T-STRUCT-C — follow_ups[] contains field-path strings only (no full
#                follow-up text leak; reference-leak floor)
#   T-STRUCT-D — Pass 1 (no EXTRACTION_OUTPUT_OVERRIDE) exits 5 + stages
#                compiled prompt
#   T-STRUCT-E — compiled prompt has all 4 placeholders substituted
#                (no `<<<{transcript}>>>` etc. remaining)
#   T-STRUCT-F — compiled prompt's schema-slice section contains B-1..B-5
#   T-STRUCT-G — missing PROMPT_CARD_PATH → exit 2; missing Section A
#                discovery context → exit 2
#   T-STRUCT-H — voice probe rc=4 falls back to typed-textarea dispatch
#
# Hermetic: per-test fake $HOME with mocked Section A discovery context,
# pre-staged or stub-captured transcript, and stub voice-capture / typed-
# textarea binaries (via VOICE_CAPTURE_BIN / TYPED_TEXTAREA_BIN env knobs)
# for AC1 dispatch verification.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/onboarding/ux/section-b.sh"
Q_FIELD_MAP="$REPO_ROOT/onboarding/q-field-map.json"
PROMPT_TEMPLATE="$REPO_ROOT/onboarding/extraction-prompts/section-B.md"

if [ ! -x "$SCRIPT" ]; then echo "FAIL: cannot exec $SCRIPT"; exit 2; fi
if [ ! -r "$Q_FIELD_MAP" ]; then echo "FAIL: cannot read $Q_FIELD_MAP"; exit 2; fi
if [ ! -r "$PROMPT_TEMPLATE" ]; then echo "FAIL: cannot read $PROMPT_TEMPLATE"; exit 2; fi

TEST_ROOT="$(mktemp -d -t section-b-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 -- $2"; }

# Common per-test scaffold. Sets up:
#   $1/.claude/onboarding/audit/                 — audit log dir
#   $1/.claude/onboarding/transcripts/           — transcript dir
#   $1/.claude/onboarding/extraction-output-A.json — Section A discovery context
#   $1/prompt-card.txt                           — stub Section B prompt card
# Returns nothing; test reads paths via convention.
setup_test_root() {
  local root="$1"
  mkdir -p "$root/.claude/onboarding/audit" \
           "$root/.claude/onboarding/transcripts"
  # Stub Section A discovery context. Conforms to extraction-prompts/section-A.md
  # deterministic shape (matches what section-a.sh actually emits).
  cat > "$root/.claude/onboarding/extraction-output-A.json" <<'EOF'
{
  "section_id": "A",
  "extraction_mode": "deterministic",
  "populated": {
    "U.identity.name": "Test Adopter",
    "U.identity.email": "test@example.org",
    "U.system.timezone": "America/New_York",
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
  # onboarder-design.md section 4; we pre-stage a minimal proxy here.
  cat > "$root/prompt-card.txt" <<'EOF'
Section B prompt card stub. Five questions about role, projects, people,
cadence, audience.
EOF
}

# Pre-stage a transcript file so the capture step skips. Used by tests that
# focus on Pass 2 logic.
stage_transcript() {
  local root="$1"
  printf 'Synthetic transcript content for tests.\n' \
    > "$root/.claude/onboarding/transcripts/section-b.txt"
}

# Build a stub extraction-output-B JSON file with controllable shape.
# $1 = output path, $2 = confidence map (compact JSON), $3 = optional
# additional jq filter applied to base.
build_extraction_stub() {
  local out="$1" conf="$2"
  jq -nc --argjson conf "$conf" '{
    section_id: "B",
    extraction_mode: "transcript",
    populated: {
      "U.identity.role": "consultant",
      "U.identity.organization": "Acme",
      "U.projects.active": [{"name": "alpha", "status": "active"}],
      "U.people": [{"name": "Riley", "role": "manager", "relationship": "report"}],
      "U.behavioral.cadence_default": "weekly"
    },
    confidence: $conf,
    source_spans: {
      "U.identity.role": "I am a consultant",
      "U.identity.organization": "at Acme"
    },
    missing_required: [],
    conflicts: [],
    follow_up: null
  }' > "$out"
}

# Stub voice-capture / typed-textarea binaries that record their args + write
# a deterministic transcript. Used for AC1 dispatch verification.
build_stubs() {
  local root="$1"
  cat > "$root/stub-voice.sh" <<'STUB'
#!/bin/bash
SECTION_ID="$1"
PROMPT_CARD="$2"
echo "voice|$SECTION_ID|$PROMPT_CARD" >> "$STUB_LOG"
mkdir -p "$TRANSCRIPT_DIR"
printf 'voice-stub-content\n' > "$TRANSCRIPT_DIR/section-b.txt"
printf '%s\n' "$TRANSCRIPT_DIR/section-b.txt"
exit "${STUB_VOICE_RC:-0}"
STUB
  cat > "$root/stub-typed.sh" <<'STUB'
#!/bin/bash
SECTION_ID="$1"
PROMPT_CARD="$2"
echo "typed|$SECTION_ID|$PROMPT_CARD" >> "$STUB_LOG"
mkdir -p "$TRANSCRIPT_DIR"
printf 'typed-stub-content\n' > "$TRANSCRIPT_DIR/section-b.txt"
printf '%s\n' "$TRANSCRIPT_DIR/section-b.txt"
exit 0
STUB
  chmod +x "$root/stub-voice.sh" "$root/stub-typed.sh"
}

# Common env-bound script invocation. $1 = test root; remaining args appended.
run_script() {
  local root="$1"; shift
  HOME="$root" \
  CLAUDE_HOME="$root/.claude" \
  INPUTS_DIR="$root/.claude/onboarding" \
  AUDIT_LOG="$root/.claude/onboarding/audit/section-b.jsonl" \
  TRANSCRIPT_DIR="$root/.claude/onboarding/transcripts" \
  Q_FIELD_MAP="$Q_FIELD_MAP" \
  EXTRACTION_PROMPT_TEMPLATE="$PROMPT_TEMPLATE" \
  PROMPT_CARD_PATH="$root/prompt-card.txt" \
  "$SCRIPT" "$@"
}

# ---------- T-STRUCT-D + T-STRUCT-E + T-STRUCT-F: Pass 1 happy path ----------
T1_ROOT="$TEST_ROOT/t1"
setup_test_root "$T1_ROOT"
build_stubs "$T1_ROOT"
T1_OUT="$TEST_ROOT/t1.out"
STUB_LOG="$T1_ROOT/stub.log" \
TRANSCRIPT_DIR="$T1_ROOT/.claude/onboarding/transcripts" \
VOICE_CAPTURE_BIN="$T1_ROOT/stub-voice.sh" \
TYPED_TEXTAREA_BIN="$T1_ROOT/stub-typed.sh" \
  run_script "$T1_ROOT" > "$T1_OUT" 2>&1
T1_RC=$?
T1_COMPILED="$T1_ROOT/.claude/onboarding/extraction-prompt-B.compiled.txt"

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

# T-STRUCT-F + AC2: schema slice contains B-1..B-5.
if grep -q '"B-1"' "$T1_COMPILED" 2>/dev/null \
   && grep -q '"B-2"' "$T1_COMPILED" 2>/dev/null \
   && grep -q '"B-3"' "$T1_COMPILED" 2>/dev/null \
   && grep -q '"B-4"' "$T1_COMPILED" 2>/dev/null \
   && grep -q '"B-5"' "$T1_COMPILED" 2>/dev/null; then
  pass "T-STRUCT-F + AC2 schema slice carries B-1..B-5 from q-field-map.json"
else
  fail "T-STRUCT-F + AC2" "compiled prompt missing one of B-1..B-5"
fi

# AC2 also verifies discovery context is substituted (Section A's name appears).
if grep -q 'Test Adopter' "$T1_COMPILED" 2>/dev/null; then
  pass "AC2 discovery_context substituted (Section A populated keys present in compiled prompt)"
else
  fail "AC2-discovery-substitution" "Section A name 'Test Adopter' not found in compiled prompt"
fi

# AC1 dispatch: stub voice-capture was called with section-id + prompt-card.
if [ -f "$T1_ROOT/stub.log" ] && grep -q '^voice|B|' "$T1_ROOT/stub.log"; then
  pass "AC1 voice-capture dispatched with SECTION_ID=B + PROMPT_CARD_PATH"
else
  fail "AC1-voice-dispatch" "stub.log did not record voice|B|... entry: $(cat "$T1_ROOT/stub.log" 2>/dev/null)"
fi

# ---------- AC1: --typed-only routes directly to typed-textarea ----------
T2_ROOT="$TEST_ROOT/t2"
setup_test_root "$T2_ROOT"
build_stubs "$T2_ROOT"
STUB_LOG="$T2_ROOT/stub.log" \
TRANSCRIPT_DIR="$T2_ROOT/.claude/onboarding/transcripts" \
VOICE_CAPTURE_BIN="$T2_ROOT/stub-voice.sh" \
TYPED_TEXTAREA_BIN="$T2_ROOT/stub-typed.sh" \
  run_script "$T2_ROOT" --typed-only > /dev/null 2>&1
if [ -f "$T2_ROOT/stub.log" ] \
   && grep -q '^typed|B|' "$T2_ROOT/stub.log" \
   && ! grep -q '^voice|' "$T2_ROOT/stub.log"; then
  pass "AC1 --typed-only dispatches to typed-textarea (skips voice probe)"
else
  fail "AC1-typed-only" "stub.log: $(cat "$T2_ROOT/stub.log" 2>/dev/null)"
fi

# ---------- T-STRUCT-H: voice rc=4 falls back to typed-textarea ----------
T3_ROOT="$TEST_ROOT/t3"
setup_test_root "$T3_ROOT"
build_stubs "$T3_ROOT"
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

# ---------- AC5 + AC6 + T-STRUCT-A + T-STRUCT-B: Pass 2 happy path ----------
T4_ROOT="$TEST_ROOT/t4"
setup_test_root "$T4_ROOT"
stage_transcript "$T4_ROOT"
T4_STUB="$T4_ROOT/.claude/onboarding/extraction-stub-B.json"
build_extraction_stub "$T4_STUB" '{"U.identity.role":0.95,"U.identity.organization":0.7,"U.projects.active":0.9,"U.people":0.4,"U.behavioral.cadence_default":0.85}'
EXTRACTION_OUTPUT_OVERRIDE="$T4_STUB" \
  run_script "$T4_ROOT" > "$TEST_ROOT/t4.out" 2>&1
T4_RC=$?
T4_FRAG="$T4_ROOT/.claude/onboarding/extraction-output-B.json"
T4_AUDIT="$T4_ROOT/.claude/onboarding/audit/section-b.jsonl"

if [ "$T4_RC" -eq 0 ] && [ -f "$T4_FRAG" ] && [ -f "$T4_AUDIT" ]; then
  pass "AC5 Pass 2 happy path → extraction-output-B.json + audit written, rc=0"
else
  fail "AC5-pass2" "rc=$T4_RC frag=$([ -f "$T4_FRAG" ] && echo y || echo n) audit=$([ -f "$T4_AUDIT" ] && echo y || echo n)"
fi

# T-STRUCT-A: extraction-output-B.json envelope shape.
if jq -e '
    .section_id == "B"
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
  pass "T-STRUCT-A extraction-output-B envelope shape conforms"
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

# AC6: confidence_map + source_spans copied through; corrections=[] in T-5a.
if jq -e '
    .section_id == "B"
    and (.confidence_map."U.identity.role") == 0.95
    and (.source_spans."U.identity.role") == "I am a consultant"
    and .corrections == []
    and .opt_outs == []
  ' "$T4_AUDIT" >/dev/null 2>&1; then
  pass "AC6 audit carries confidence_map + source_spans + corrections=[] + opt_outs=[]"
else
  fail "AC6" "audit shape diverges; got: $(cat "$T4_AUDIT")"
fi

# ---------- AC3 + T-STRUCT-C: confidence-gate categorization ----------
# Stub uses: role 0.95 (HIGH), org 0.7 (MID), projects 0.9 (HIGH),
# people 0.4 (LOW), cadence 0.85 (HIGH). LOW field-paths land in follow_ups[].
if jq -e '
    (.follow_ups | length) >= 1
    and (.follow_ups | map(. == "U.people") | any)
  ' "$T4_AUDIT" >/dev/null 2>&1; then
  pass "AC3 LOW-confidence field 'U.people' (0.4 < 0.5) recorded in follow_ups[]"
else
  fail "AC3-low-confidence" "follow_ups: $(jq -c '.follow_ups' "$T4_AUDIT")"
fi

# T-STRUCT-C: follow_ups[] contains field-path strings only (no full text leak).
if jq -e '.follow_ups | all(test("^[UO]\\."))' "$T4_AUDIT" >/dev/null 2>&1; then
  pass "T-STRUCT-C follow_ups[] contains field-path strings only (no full follow-up text)"
else
  fail "T-STRUCT-C" "follow_ups carries non-field-path entries: $(jq -c '.follow_ups' "$T4_AUDIT")"
fi

# AC3 HIGH-confidence fields don't appear in follow_ups.
if jq -e '.follow_ups | (map(. == "U.identity.role") | any) | not' "$T4_AUDIT" >/dev/null 2>&1; then
  pass "AC3 HIGH-confidence field 'U.identity.role' (0.95 ≥ 0.85) NOT in follow_ups[]"
else
  fail "AC3-high-confidence-leak" "HIGH field appeared in follow_ups: $(jq -c '.follow_ups' "$T4_AUDIT")"
fi

# ---------- AC4: opt-out routing per surface ----------

# Surface #2 (org): --opt-out-org → populated.U.identity.organization=null +
# opt_outs[organization_skipped].
T5_ROOT="$TEST_ROOT/t5"
setup_test_root "$T5_ROOT"
stage_transcript "$T5_ROOT"
T5_STUB="$T5_ROOT/.claude/onboarding/extraction-stub-B.json"
build_extraction_stub "$T5_STUB" '{"U.identity.role":0.9,"U.identity.organization":0.9,"U.projects.active":0.9,"U.people":0.9,"U.behavioral.cadence_default":0.9}'
EXTRACTION_OUTPUT_OVERRIDE="$T5_STUB" \
  run_script "$T5_ROOT" --opt-out-org > /dev/null 2>&1
T5_FRAG="$T5_ROOT/.claude/onboarding/extraction-output-B.json"
T5_AUDIT="$T5_ROOT/.claude/onboarding/audit/section-b.jsonl"
if jq -e '
    .populated."U.identity.organization" == null
    and (.opt_outs | index("organization_skipped")) != null
    and (.populated."U.people" | length) > 0
  ' "$T5_FRAG" >/dev/null 2>&1 \
  && jq -e '.opt_outs == ["organization_skipped"]' "$T5_AUDIT" >/dev/null 2>&1; then
  pass "AC4 surface #2 (--opt-out-org) → org=null + opt_outs[organization_skipped]; people unchanged"
else
  fail "AC4-org" "frag.populated=$(jq -c '.populated' "$T5_FRAG"); audit.opt_outs=$(jq -c '.opt_outs' "$T5_AUDIT")"
fi

# Surface #3 (people): --opt-out-people → populated.U.people=[] +
# opt_outs[people_skipped].
T6_ROOT="$TEST_ROOT/t6"
setup_test_root "$T6_ROOT"
stage_transcript "$T6_ROOT"
T6_STUB="$T6_ROOT/.claude/onboarding/extraction-stub-B.json"
build_extraction_stub "$T6_STUB" '{"U.identity.role":0.9,"U.identity.organization":0.9,"U.projects.active":0.9,"U.people":0.9,"U.behavioral.cadence_default":0.9}'
EXTRACTION_OUTPUT_OVERRIDE="$T6_STUB" \
  run_script "$T6_ROOT" --opt-out-people > /dev/null 2>&1
T6_FRAG="$T6_ROOT/.claude/onboarding/extraction-output-B.json"
T6_AUDIT="$T6_ROOT/.claude/onboarding/audit/section-b.jsonl"
if jq -e '
    .populated."U.people" == []
    and (.opt_outs | index("people_skipped")) != null
    and .populated."U.identity.organization" == "Acme"
  ' "$T6_FRAG" >/dev/null 2>&1 \
  && jq -e '.opt_outs == ["people_skipped"]' "$T6_AUDIT" >/dev/null 2>&1; then
  pass "AC4 surface #3 (--opt-out-people) → people=[] + opt_outs[people_skipped]; org unchanged"
else
  fail "AC4-people" "frag.populated=$(jq -c '.populated' "$T6_FRAG"); audit.opt_outs=$(jq -c '.opt_outs' "$T6_AUDIT")"
fi

# Surface #4 (tools): --opt-out-tools → opt_outs[tools_skipped] (no populated
# mutation; B doesn't own U.tools.* schema paths).
T7_ROOT="$TEST_ROOT/t7"
setup_test_root "$T7_ROOT"
stage_transcript "$T7_ROOT"
T7_STUB="$T7_ROOT/.claude/onboarding/extraction-stub-B.json"
build_extraction_stub "$T7_STUB" '{"U.identity.role":0.9}'
EXTRACTION_OUTPUT_OVERRIDE="$T7_STUB" \
  run_script "$T7_ROOT" --opt-out-tools > /dev/null 2>&1
T7_FRAG="$T7_ROOT/.claude/onboarding/extraction-output-B.json"
if jq -e '
    (.opt_outs | index("tools_skipped")) != null
    and .populated."U.identity.role" == "consultant"
  ' "$T7_FRAG" >/dev/null 2>&1; then
  pass "AC4 surface #4 (--opt-out-tools) → opt_outs[tools_skipped]; populated unmutated"
else
  fail "AC4-tools" "frag=$(jq -c '. | {opt_outs, populated}' "$T7_FRAG")"
fi

# Blanket --auto-opt-out elects all 3.
T8_ROOT="$TEST_ROOT/t8"
setup_test_root "$T8_ROOT"
stage_transcript "$T8_ROOT"
T8_STUB="$T8_ROOT/.claude/onboarding/extraction-stub-B.json"
build_extraction_stub "$T8_STUB" '{"U.identity.role":0.9,"U.identity.organization":0.9,"U.projects.active":0.9,"U.people":0.9,"U.behavioral.cadence_default":0.9}'
EXTRACTION_OUTPUT_OVERRIDE="$T8_STUB" \
  run_script "$T8_ROOT" --auto-opt-out > /dev/null 2>&1
T8_FRAG="$T8_ROOT/.claude/onboarding/extraction-output-B.json"
if jq -e '
    .populated."U.identity.organization" == null
    and .populated."U.people" == []
    and (.opt_outs | sort) == ["organization_skipped", "people_skipped", "tools_skipped"]
  ' "$T8_FRAG" >/dev/null 2>&1; then
  pass "AC4 --auto-opt-out elects all 3 surfaces (#2 + #3 + #4); section commits without aborting"
else
  fail "AC4-blanket" "frag=$(jq -c '. | {opt_outs, populated}' "$T8_FRAG")"
fi

# ---------- T-STRUCT-G: input-validation rejects ----------

# Missing PROMPT_CARD_PATH → exit 2.
T9_ROOT="$TEST_ROOT/t9"
setup_test_root "$T9_ROOT"
HOME="$T9_ROOT" \
CLAUDE_HOME="$T9_ROOT/.claude" \
INPUTS_DIR="$T9_ROOT/.claude/onboarding" \
AUDIT_LOG="$T9_ROOT/.claude/onboarding/audit/section-b.jsonl" \
TRANSCRIPT_DIR="$T9_ROOT/.claude/onboarding/transcripts" \
Q_FIELD_MAP="$Q_FIELD_MAP" \
EXTRACTION_PROMPT_TEMPLATE="$PROMPT_TEMPLATE" \
PROMPT_CARD_PATH="" \
  "$SCRIPT" > /dev/null 2>&1
T9_RC=$?
if [ "$T9_RC" -eq 2 ]; then
  pass "T-STRUCT-G missing PROMPT_CARD_PATH rejects with exit 2"
else
  fail "T-STRUCT-G-prompt" "rc=$T9_RC (expected 2)"
fi

# Missing Section A discovery context → exit 2.
T10_ROOT="$TEST_ROOT/t10"
setup_test_root "$T10_ROOT"
rm -f "$T10_ROOT/.claude/onboarding/extraction-output-A.json"
run_script "$T10_ROOT" > /dev/null 2>&1
T10_RC=$?
if [ "$T10_RC" -eq 2 ]; then
  pass "T-STRUCT-G missing Section A discovery context rejects with exit 2"
else
  fail "T-STRUCT-G-discovery" "rc=$T10_RC (expected 2)"
fi

# ---------- AC2 + T-STRUCT-A: extraction-output 'B' section_id locked ----------
T11_ROOT="$TEST_ROOT/t11"
setup_test_root "$T11_ROOT"
stage_transcript "$T11_ROOT"
T11_STUB="$T11_ROOT/.claude/onboarding/extraction-stub-bad.json"
# Wrong section_id should be rejected.
jq -nc '{section_id: "C", extraction_mode: "transcript", populated: {}, confidence: {}, source_spans: {}, missing_required: [], conflicts: [], follow_up: null}' > "$T11_STUB"
EXTRACTION_OUTPUT_OVERRIDE="$T11_STUB" \
  run_script "$T11_ROOT" > /dev/null 2>&1
T11_RC=$?
if [ "$T11_RC" -eq 3 ]; then
  pass "T-STRUCT-A section_id mismatch (C != B) rejects with exit 3"
else
  fail "T-STRUCT-A-section-id" "rc=$T11_RC (expected 3)"
fi

# ---------- AC5 manifest_paths_written reflects committed populated keys ----------
if jq -e '
    (.manifest_paths_written | sort) == ([
      "U.behavioral.cadence_default",
      "U.identity.organization",
      "U.identity.role",
      "U.people",
      "U.projects.active"
    ] | sort)
  ' "$T4_AUDIT" >/dev/null 2>&1; then
  pass "AC5 manifest_paths_written reflects all 5 committed populated keys"
else
  fail "AC5-manifest-paths" "manifest_paths=$(jq -c '.manifest_paths_written' "$T4_AUDIT")"
fi

# ---------- summary ----------
echo "=== section-b-unit-test ==="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
