#!/bin/bash
# tests/sp07/render-summary-unit-test.sh — synthetic unit tests for SP07 T-6
# onboarding/ux/render-summary.sh (inline-edit summary screen + correction
# write-back).
#
# Validates the 8 acceptance criteria from
# ~/.claude-plans/71-claude-foundations-engine-v2/07-onboarder-ux/tasks.md T-6:
#
#   AC1 — Renders inline-edit summary from extraction-output-{B,C,D}.json
#         + per-section audit follow_ups[]
#   AC2 — HIGH/MID/LOW visual disposition per confidence_map applied
#   AC3 — Per-field inline edit merges into populated; appends corrections[]
#         field-path to JSONL audit
#   AC4 — One surgical follow-up per LOW required field (resolved by edit
#         in the same pass; no model re-call required at script level —
#         user-typed value IS the re-extracted answer)
#   AC5 — Per-section re-record trigger clears fragment + transcript + audit
#         entry (via re-record-initiated marker); phases_completed[] adjusted
#   AC6 — Opt-out triggers from summary delegate to owning section's surface
#         handler (B/C/D)
#   AC7 — phases_completed[] append on user accept (SKILL.md L119)
#   AC8 — Reference-leak floor: corrections[] holds field-paths only;
#         no user-typed strings in diagnostic fields
#
# Plus structural / validation guardrails:
#
#   T-VALIDATE-A — missing --section → exit 2
#   T-VALIDATE-B — invalid section letter (not B|C|D) → exit 2
#   T-VALIDATE-C — extraction-output-{X}.json missing → exit 2
#   T-VALIDATE-D — extraction-output section_id mismatch → exit 3
#   T-MUTEX     — --auto-accept + --auto-rerecord together → exit 2
#   T-AUDIT-A   — appended audit line carries all 9 SKILL.md L141 keys
#   T-AUDIT-B   — corrections[] field-paths match the auto-edits-file keys
#   T-AUDIT-C   — follow_ups[] carry-through from prior audit line preserved
#   T-CONF-A    — HIGH/MID/LOW classification reflected in summary screen
#                 (HIGH bullet ✓, MID bullet ?, LOW bullet !)
#   T-PHASES-A  — phases_completed[] seeded with skeleton when manifest absent
#   T-PHASES-B  — phases_completed[] dedup on re-accept (idempotent)
#   T-RERECORD-A — re-record path removes section_id from phases_completed[]
#   T-RERECORD-B — re-record one section leaves OTHER sections' fragments
#                  byte-identical (per Hard Rule "section_id never disturbs
#                  other sections")
#   T-OPTOUT-INVALID — unknown opt-out surface → exit 2 (mirror surface enum)
#   T-CONF-COLOR-MARKER — required-low fields render with [REQUIRED] marker
#
# Hermetic: per-test fake $HOME/.claude tree. Each test gets its own root.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/onboarding/ux/render-summary.sh"
Q_FIELD_MAP="$REPO_ROOT/onboarding/q-field-map.json"

if [ ! -x "$SCRIPT" ]; then echo "FAIL: cannot exec $SCRIPT"; exit 2; fi
if [ ! -r "$Q_FIELD_MAP" ]; then echo "FAIL: cannot read $Q_FIELD_MAP"; exit 2; fi

TEST_ROOT="$(mktemp -d -t render-summary-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 -- $2"; }

# --- per-test scaffold ---
# Sets up:
#   $1/.claude/onboarding/                          — INPUTS_DIR
#   $1/.claude/onboarding/audit/                    — audit dir
#   $1/.claude/onboarding/transcripts/              — transcript dir
#   $1/.claude/onboarding/extraction-output-{X}.json — pre-staged extraction
#                                                      via build_extraction_for_section
#   $1/.claude/onboarding/audit/section-{x}.jsonl   — pre-staged initial audit
#                                                      via stage_audit_line
setup_test_root() {
  local root="$1"
  mkdir -p "$root/.claude/onboarding/audit" \
           "$root/.claude/onboarding/transcripts"
}

# Build an extraction-output-{X}.json file with controllable shape.
# $1 = output path; $2 = section_id (B|C|D); $3 = populated JSON; $4 = confidence JSON
build_extraction_for_section() {
  local out="$1" section_id="$2" populated="$3" confidence="$4"
  jq -nc --arg sid "$section_id" \
         --argjson pop "$populated" \
         --argjson conf "$confidence" \
    '{
      section_id: $sid,
      extraction_mode: "transcript",
      populated: $pop,
      confidence: $conf,
      source_spans: {},
      missing_required: [],
      conflicts: [],
      follow_up: null,
      opt_outs: [],
      run_id: "test-section-run",
      timestamp: "2026-05-02T00:00:00Z"
    }' > "$out"
}

# Stage an initial JSONL audit line as section-{x}.sh would have written.
# $1 = audit log path; $2 = section_id; $3 = follow_ups JSON array
stage_audit_line() {
  local audit_log="$1" section_id="$2" follow_ups="$3"
  mkdir -p "$(dirname "$audit_log")"
  jq -nc --arg sid "$section_id" --argjson fu "$follow_ups" \
    '{
      section_id: $sid,
      run_id: "init-run",
      ts: "2026-05-02T00:00:00Z",
      opt_outs: [],
      confidence_map: {},
      source_spans: {},
      corrections: [],
      follow_ups: $fu,
      manifest_paths_written: []
    }' >> "$audit_log"
}

# Common env-bound script invocation. $1 = test root; $2 = section letter (B|C|D);
# remaining args appended as flags.
run_script() {
  local root="$1" section="$2"; shift 2
  HOME="$root" \
  CLAUDE_HOME="$root/.claude" \
  INPUTS_DIR="$root/.claude/onboarding" \
  AUDIT_LOG="$root/.claude/onboarding/audit/section-$(printf '%s' "$section" | tr '[:upper:]' '[:lower:]').jsonl" \
  TRANSCRIPT_DIR="$root/.claude/onboarding/transcripts" \
  Q_FIELD_MAP="$Q_FIELD_MAP" \
  USER_MANIFEST="$root/.claude/user-manifest.json" \
    "$SCRIPT" --section "$section" "$@"
}

# ---------- T-VALIDATE-A: missing --section ----------
T1_ROOT="$TEST_ROOT/t1"
setup_test_root "$T1_ROOT"
HOME="$T1_ROOT" CLAUDE_HOME="$T1_ROOT/.claude" Q_FIELD_MAP="$Q_FIELD_MAP" \
  "$SCRIPT" > /dev/null 2>&1
T1_RC=$?
if [ "$T1_RC" -eq 2 ]; then
  pass "T-VALIDATE-A missing --section rejects with exit 2"
else
  fail "T-VALIDATE-A" "rc=$T1_RC (expected 2)"
fi

# ---------- T-VALIDATE-B: invalid section letter ----------
T2_ROOT="$TEST_ROOT/t2"
setup_test_root "$T2_ROOT"
run_script "$T2_ROOT" "X" > /dev/null 2>&1
T2_RC=$?
if [ "$T2_RC" -eq 2 ]; then
  pass "T-VALIDATE-B invalid section letter (X) rejects with exit 2"
else
  fail "T-VALIDATE-B" "rc=$T2_RC (expected 2)"
fi

# ---------- T-VALIDATE-C: extraction-output missing ----------
T3_ROOT="$TEST_ROOT/t3"
setup_test_root "$T3_ROOT"
run_script "$T3_ROOT" "D" --auto-accept > /dev/null 2>&1
T3_RC=$?
if [ "$T3_RC" -eq 2 ]; then
  pass "T-VALIDATE-C missing extraction-output rejects with exit 2"
else
  fail "T-VALIDATE-C" "rc=$T3_RC (expected 2)"
fi

# ---------- T-VALIDATE-D: section_id mismatch ----------
T4_ROOT="$TEST_ROOT/t4"
setup_test_root "$T4_ROOT"
build_extraction_for_section "$T4_ROOT/.claude/onboarding/extraction-output-D.json" \
  "C" '{"U.behavioral.autonomy":"strict"}' '{"U.behavioral.autonomy":0.9}'
run_script "$T4_ROOT" "D" --auto-accept > /dev/null 2>&1
T4_RC=$?
if [ "$T4_RC" -eq 3 ]; then
  pass "T-VALIDATE-D extraction-output section_id mismatch (C != D) rejects with exit 3"
else
  fail "T-VALIDATE-D" "rc=$T4_RC (expected 3)"
fi

# ---------- T-MUTEX: --auto-accept + --auto-rerecord ----------
T5_ROOT="$TEST_ROOT/t5"
setup_test_root "$T5_ROOT"
run_script "$T5_ROOT" "D" --auto-accept --auto-rerecord > /dev/null 2>&1
T5_RC=$?
if [ "$T5_RC" -eq 2 ]; then
  pass "T-MUTEX --auto-accept + --auto-rerecord together rejects with exit 2"
else
  fail "T-MUTEX" "rc=$T5_RC (expected 2)"
fi

# ---------- AC1 + AC2 + AC7 + T-AUDIT-A: --auto-accept happy path ----------
# Section D with all HIGH-confidence required fields: D-1 (autonomy) + D-2
# (jobs[0].id) + optional D-4. No LOW, no blocking.
T6_ROOT="$TEST_ROOT/t6"
setup_test_root "$T6_ROOT"
build_extraction_for_section "$T6_ROOT/.claude/onboarding/extraction-output-D.json" \
  "D" \
  '{"U.behavioral.autonomy":"balanced","O.jobs[0].id":"librarian","U.behavioral.hook_preferences.notification_style":"digest"}' \
  '{"U.behavioral.autonomy":0.95,"O.jobs[0].id":0.9,"U.behavioral.hook_preferences.notification_style":0.85}'
stage_audit_line "$T6_ROOT/.claude/onboarding/audit/section-d.jsonl" "D" "[]"
run_script "$T6_ROOT" "D" --auto-accept > "$TEST_ROOT/t6.out" 2>&1
T6_RC=$?
T6_AUDIT="$T6_ROOT/.claude/onboarding/audit/section-d.jsonl"
T6_MANIFEST="$T6_ROOT/.claude/user-manifest.json"

if [ "$T6_RC" -eq 0 ]; then
  pass "AC1 --auto-accept happy path returns rc=0"
else
  fail "AC1-rc" "rc=$T6_RC; out=$(cat "$TEST_ROOT/t6.out")"
fi

# Audit log gained a NEW JSONL line (was 1 line from staging, now 2).
T6_AUDIT_LINES="$(wc -l < "$T6_AUDIT" 2>/dev/null | tr -d ' ')"
if [ "$T6_AUDIT_LINES" = "2" ]; then
  pass "AC1 audit log gained one new JSONL line (was 1, now 2)"
else
  fail "AC1-audit-line-count" "audit lines=$T6_AUDIT_LINES (expected 2)"
fi

# T-AUDIT-A: appended line carries all 9 SKILL.md L141 keys.
if tail -1 "$T6_AUDIT" | jq -e '
    has("section_id") and has("run_id") and has("ts") and has("opt_outs")
    and has("confidence_map") and has("source_spans") and has("corrections")
    and has("follow_ups") and has("manifest_paths_written")
  ' >/dev/null 2>&1; then
  pass "T-AUDIT-A appended audit line carries all 9 SKILL.md L141 fields"
else
  fail "T-AUDIT-A" "audit shape: $(tail -1 "$T6_AUDIT")"
fi

# AC7: phases_completed[] populated with section_id "D".
if jq -e '.system.phases_completed | index("D") != null' "$T6_MANIFEST" >/dev/null 2>&1; then
  pass "AC7 phases_completed[] contains 'D' after --auto-accept"
else
  fail "AC7" "manifest: $(cat "$T6_MANIFEST" 2>/dev/null)"
fi

# ---------- AC2 + T-CONF-A: HIGH/MID/LOW visual disposition ----------
# stderr captures the rendered summary screen.
T7_ROOT="$TEST_ROOT/t7"
setup_test_root "$T7_ROOT"
build_extraction_for_section "$T7_ROOT/.claude/onboarding/extraction-output-D.json" \
  "D" \
  '{"U.behavioral.autonomy":"balanced","O.jobs[0].id":"librarian","U.behavioral.hook_preferences.notification_style":"digest"}' \
  '{"U.behavioral.autonomy":0.95,"O.jobs[0].id":0.7,"U.behavioral.hook_preferences.notification_style":0.3}'
stage_audit_line "$T7_ROOT/.claude/onboarding/audit/section-d.jsonl" "D" "[]"
run_script "$T7_ROOT" "D" --auto-accept > "$TEST_ROOT/t7.out" 2>&1

# Visual disposition markers: ✓ for HIGH, ? for MID, ! for LOW.
if grep -q '✓' "$TEST_ROOT/t7.out" \
   && grep -q '?' "$TEST_ROOT/t7.out" \
   && grep -q '!' "$TEST_ROOT/t7.out"; then
  pass "AC2 + T-CONF-A summary screen renders HIGH ✓ + MID ? + LOW ! markers"
else
  fail "T-CONF-A" "summary screen missing markers; out=$(cat "$TEST_ROOT/t7.out")"
fi

# ---------- AC3 + T-AUDIT-B + AC8: --auto-edits-file correction write-back ----------
T8_ROOT="$TEST_ROOT/t8"
setup_test_root "$T8_ROOT"
build_extraction_for_section "$T8_ROOT/.claude/onboarding/extraction-output-D.json" \
  "D" \
  '{"U.behavioral.autonomy":"unclear","O.jobs[0].id":"librarian"}' \
  '{"U.behavioral.autonomy":0.6,"O.jobs[0].id":0.9}'
stage_audit_line "$T8_ROOT/.claude/onboarding/audit/section-d.jsonl" "D" "[]"
T8_EDITS="$T8_ROOT/.claude/onboarding/edits.json"
printf '{"U.behavioral.autonomy":"strict"}\n' > "$T8_EDITS"
run_script "$T8_ROOT" "D" --auto-edits-file "$T8_EDITS" > "$TEST_ROOT/t8.out" 2>&1
T8_RC=$?
T8_FRAG="$T8_ROOT/.claude/onboarding/extraction-output-D.json"
T8_AUDIT="$T8_ROOT/.claude/onboarding/audit/section-d.jsonl"

if [ "$T8_RC" -eq 0 ]; then
  pass "AC3 --auto-edits-file accept rc=0"
else
  fail "AC3-rc" "rc=$T8_RC; out=$(cat "$TEST_ROOT/t8.out")"
fi

# Populated map updated with edit value.
if jq -e '.populated."U.behavioral.autonomy" == "strict"' "$T8_FRAG" >/dev/null 2>&1; then
  pass "AC3 populated map updated with edit value (autonomy='strict')"
else
  fail "AC3-populated" "populated: $(jq -c '.populated' "$T8_FRAG")"
fi

# Confidence bumped to 1.0 for edited path.
if jq -e '.confidence."U.behavioral.autonomy" == 1.0' "$T8_FRAG" >/dev/null 2>&1; then
  pass "AC3 confidence bumped to 1.0 for user-typed correction"
else
  fail "AC3-confidence" "confidence: $(jq -c '.confidence' "$T8_FRAG")"
fi

# T-AUDIT-B: corrections[] in new audit line contains the edited field-path.
if tail -1 "$T8_AUDIT" | jq -e '.corrections | index("U.behavioral.autonomy") != null' >/dev/null 2>&1; then
  pass "T-AUDIT-B corrections[] contains edited field-path 'U.behavioral.autonomy'"
else
  fail "T-AUDIT-B" "audit corrections: $(tail -1 "$T8_AUDIT" | jq -c '.corrections')"
fi

# AC8 reference-leak floor: corrections[] is field-path strings only — no
# leak of the user-typed VALUE ("strict") into corrections[].
if tail -1 "$T8_AUDIT" | jq -e '.corrections | all(test("^[UO]\\."))' >/dev/null 2>&1; then
  pass "AC8 corrections[] contains field-path strings only (reference-leak floor)"
else
  fail "AC8" "corrections leak: $(tail -1 "$T8_AUDIT" | jq -c '.corrections')"
fi

# AC8 corollary: the user-typed value 'strict' MUST NOT appear anywhere in
# the audit line as a leak. It belongs in extraction-output's populated map only.
if tail -1 "$T8_AUDIT" | grep -q '"strict"'; then
  fail "AC8-leak-string" "user-typed string 'strict' leaked into audit line: $(tail -1 "$T8_AUDIT")"
else
  pass "AC8 user-typed value 'strict' does NOT appear in audit JSONL line"
fi

# ---------- AC4 + T-CONF-COLOR-MARKER: surgical follow-up resolves blocking required ----------
# Setup a Section D where O.jobs[0].id (REQUIRED via D-2) is LOW (0.3) and
# autonomy (REQUIRED via D-1) is HIGH. Auto-edits-file resolves the LOW field.
T9_ROOT="$TEST_ROOT/t9"
setup_test_root "$T9_ROOT"
build_extraction_for_section "$T9_ROOT/.claude/onboarding/extraction-output-D.json" \
  "D" \
  '{"U.behavioral.autonomy":"strict","O.jobs[0].id":"unclear"}' \
  '{"U.behavioral.autonomy":0.95,"O.jobs[0].id":0.3}'
stage_audit_line "$T9_ROOT/.claude/onboarding/audit/section-d.jsonl" "D" '["O.jobs[0].id"]'
T9_EDITS="$T9_ROOT/.claude/onboarding/edits.json"
printf '{"O.jobs[0].id":"librarian"}\n' > "$T9_EDITS"
run_script "$T9_ROOT" "D" --auto-edits-file "$T9_EDITS" > "$TEST_ROOT/t9.out" 2>&1
T9_RC=$?
T9_FRAG="$T9_ROOT/.claude/onboarding/extraction-output-D.json"
T9_MANIFEST="$T9_ROOT/.claude/user-manifest.json"

if [ "$T9_RC" -eq 0 ]; then
  pass "AC4 surgical follow-up via inline edit resolves LOW required field; rc=0"
else
  fail "AC4-rc" "rc=$T9_RC; out=$(cat "$TEST_ROOT/t9.out")"
fi

# Edited value present in populated.
if jq -e '.populated."O.jobs[0].id" == "librarian"' "$T9_FRAG" >/dev/null 2>&1; then
  pass "AC4 LOW required field edited value committed to populated"
else
  fail "AC4-populated" "populated: $(jq -c '.populated' "$T9_FRAG")"
fi

# phases_completed updated (block-and-log did NOT fire).
if jq -e '.system.phases_completed | index("D") != null' "$T9_MANIFEST" >/dev/null 2>&1; then
  pass "AC4 phases_completed updated after surgical follow-up resolved required field"
else
  fail "AC4-phases" "manifest: $(cat "$T9_MANIFEST")"
fi

# T-CONF-COLOR-MARKER: stderr summary should have included [REQUIRED] marker
# for the LOW O.jobs[0].id row.
if grep -q 'O.jobs\[0\].id.*\[REQUIRED\]' "$TEST_ROOT/t9.out"; then
  pass "T-CONF-COLOR-MARKER LOW required field rendered with [REQUIRED] marker"
else
  fail "T-CONF-COLOR-MARKER" "summary missing [REQUIRED] marker; out=$(cat "$TEST_ROOT/t9.out")"
fi

# ---------- T-BLOCK-A: required field LOW + no edit → block-and-log ----------
T10_ROOT="$TEST_ROOT/t10"
setup_test_root "$T10_ROOT"
build_extraction_for_section "$T10_ROOT/.claude/onboarding/extraction-output-D.json" \
  "D" \
  '{"U.behavioral.autonomy":"strict","O.jobs[0].id":"unclear"}' \
  '{"U.behavioral.autonomy":0.95,"O.jobs[0].id":0.3}'
stage_audit_line "$T10_ROOT/.claude/onboarding/audit/section-d.jsonl" "D" '["O.jobs[0].id"]'
run_script "$T10_ROOT" "D" --auto-accept > "$TEST_ROOT/t10.out" 2>&1
T10_RC=$?
T10_MANIFEST="$T10_ROOT/.claude/user-manifest.json"

if [ "$T10_RC" -eq 3 ]; then
  pass "T-BLOCK-A required field LOW + no edit → block-and-log rc=3"
else
  fail "T-BLOCK-A" "rc=$T10_RC (expected 3); out=$(cat "$TEST_ROOT/t10.out")"
fi

# phases_completed must NOT have D appended (block-and-log invariant).
if [ ! -f "$T10_MANIFEST" ] \
   || jq -e '.system.phases_completed | index("D") == null' "$T10_MANIFEST" >/dev/null 2>&1; then
  pass "T-BLOCK-A block-and-log: phases_completed[] NOT updated"
else
  fail "T-BLOCK-A-phases" "manifest leaked D: $(cat "$T10_MANIFEST")"
fi

# Block-and-log diagnostic message visible.
if grep -q 'block-and-log' "$TEST_ROOT/t10.out"; then
  pass "T-BLOCK-A block-and-log diagnostic emitted to stderr"
else
  fail "T-BLOCK-A-diag" "missing block-and-log diagnostic; out=$(cat "$TEST_ROOT/t10.out")"
fi

# ---------- AC5 + T-RERECORD-A: --auto-rerecord clears state ----------
T11_ROOT="$TEST_ROOT/t11"
setup_test_root "$T11_ROOT"
build_extraction_for_section "$T11_ROOT/.claude/onboarding/extraction-output-D.json" \
  "D" \
  '{"U.behavioral.autonomy":"balanced","O.jobs[0].id":"librarian"}' \
  '{"U.behavioral.autonomy":0.95,"O.jobs[0].id":0.9}'
stage_audit_line "$T11_ROOT/.claude/onboarding/audit/section-d.jsonl" "D" "[]"
printf 'pre-existing transcript\n' > "$T11_ROOT/.claude/onboarding/transcripts/section-d.txt"
# Pre-populate phases_completed with D so we can verify removal.
mkdir -p "$T11_ROOT/.claude"
printf '{"system":{"phases_completed":["A","B","C","D"]}}\n' > "$T11_ROOT/.claude/user-manifest.json"

run_script "$T11_ROOT" "D" --auto-rerecord > "$TEST_ROOT/t11.out" 2>&1
T11_RC=$?
T11_FRAG="$T11_ROOT/.claude/onboarding/extraction-output-D.json"
T11_TRANSCRIPT="$T11_ROOT/.claude/onboarding/transcripts/section-d.txt"
T11_MANIFEST="$T11_ROOT/.claude/user-manifest.json"
T11_AUDIT="$T11_ROOT/.claude/onboarding/audit/section-d.jsonl"

if [ "$T11_RC" -eq 0 ]; then
  pass "AC5 --auto-rerecord rc=0"
else
  fail "AC5-rc" "rc=$T11_RC; out=$(cat "$TEST_ROOT/t11.out")"
fi

# Fragment + transcript deleted.
if [ ! -f "$T11_FRAG" ] && [ ! -f "$T11_TRANSCRIPT" ]; then
  pass "AC5 re-record cleared extraction-output + transcript"
else
  fail "AC5-clear" "frag=$([ -f "$T11_FRAG" ] && echo y || echo n) transcript=$([ -f "$T11_TRANSCRIPT" ] && echo y || echo n)"
fi

# T-RERECORD-A: phases_completed lost D but kept others.
if jq -e '
    (.system.phases_completed | index("D") == null)
    and (.system.phases_completed | index("A") != null)
    and (.system.phases_completed | index("B") != null)
    and (.system.phases_completed | index("C") != null)
  ' "$T11_MANIFEST" >/dev/null 2>&1; then
  pass "T-RERECORD-A phases_completed[] removed D, preserved A/B/C"
else
  fail "T-RERECORD-A" "manifest: $(cat "$T11_MANIFEST")"
fi

# Re-record marker appended to JSONL audit log (append-only history).
if tail -1 "$T11_AUDIT" | jq -e '.event == "re-record-initiated"' >/dev/null 2>&1; then
  pass "AC5 re-record audit marker appended (append-only history preserved)"
else
  fail "AC5-marker" "audit tail: $(tail -1 "$T11_AUDIT")"
fi

# ---------- T-RERECORD-B: re-record D leaves OTHER sections' fragments byte-identical ----------
T12_ROOT="$TEST_ROOT/t12"
setup_test_root "$T12_ROOT"
build_extraction_for_section "$T12_ROOT/.claude/onboarding/extraction-output-B.json" \
  "B" '{"U.identity.role":"engineer"}' '{"U.identity.role":0.9}'
build_extraction_for_section "$T12_ROOT/.claude/onboarding/extraction-output-C.json" \
  "C" '{"U.vault.is_fresh":true,"U.vault.canonical_file_types[]":["meetings"]}' \
  '{"U.vault.is_fresh":0.9,"U.vault.canonical_file_types[]":0.9}'
build_extraction_for_section "$T12_ROOT/.claude/onboarding/extraction-output-D.json" \
  "D" '{"U.behavioral.autonomy":"balanced","O.jobs[0].id":"librarian"}' \
  '{"U.behavioral.autonomy":0.95,"O.jobs[0].id":0.9}'
stage_audit_line "$T12_ROOT/.claude/onboarding/audit/section-d.jsonl" "D" "[]"
T12_B_HASH_BEFORE="$(shasum "$T12_ROOT/.claude/onboarding/extraction-output-B.json" | awk '{print $1}')"
T12_C_HASH_BEFORE="$(shasum "$T12_ROOT/.claude/onboarding/extraction-output-C.json" | awk '{print $1}')"

run_script "$T12_ROOT" "D" --auto-rerecord > /dev/null 2>&1

T12_B_HASH_AFTER="$(shasum "$T12_ROOT/.claude/onboarding/extraction-output-B.json" | awk '{print $1}')"
T12_C_HASH_AFTER="$(shasum "$T12_ROOT/.claude/onboarding/extraction-output-C.json" | awk '{print $1}')"

if [ "$T12_B_HASH_BEFORE" = "$T12_B_HASH_AFTER" ] && [ "$T12_C_HASH_BEFORE" = "$T12_C_HASH_AFTER" ]; then
  pass "T-RERECORD-B re-record D leaves Sections B + C byte-identical"
else
  fail "T-RERECORD-B" "B before=$T12_B_HASH_BEFORE after=$T12_B_HASH_AFTER; C before=$T12_C_HASH_BEFORE after=$T12_C_HASH_AFTER"
fi

# ---------- AC6: opt-out delegation marker ----------
T13_ROOT="$TEST_ROOT/t13"
setup_test_root "$T13_ROOT"
build_extraction_for_section "$T13_ROOT/.claude/onboarding/extraction-output-D.json" \
  "D" '{"U.behavioral.autonomy":"balanced"}' '{"U.behavioral.autonomy":0.9}'

T13_FRAG_HASH_BEFORE="$(shasum "$T13_ROOT/.claude/onboarding/extraction-output-D.json" | awk '{print $1}')"
run_script "$T13_ROOT" "D" --auto-opt-out hook_advisory > "$TEST_ROOT/t13.out" 2>&1
T13_RC=$?
T13_AUDIT="$T13_ROOT/.claude/onboarding/audit/section-d.jsonl"
T13_FRAG_HASH_AFTER="$(shasum "$T13_ROOT/.claude/onboarding/extraction-output-D.json" | awk '{print $1}')"

if [ "$T13_RC" -eq 0 ]; then
  pass "AC6 --auto-opt-out hook_advisory rc=0"
else
  fail "AC6-rc" "rc=$T13_RC; out=$(cat "$TEST_ROOT/t13.out")"
fi

# Audit log has delegation marker.
if tail -1 "$T13_AUDIT" 2>/dev/null | jq -e '.event == "opt-out-delegated"' >/dev/null 2>&1; then
  pass "AC6 opt-out delegation marker appended to audit log"
else
  fail "AC6-marker" "audit: $(tail -1 "$T13_AUDIT" 2>/dev/null)"
fi

# Extraction-output untouched (delegation, not modification).
if [ "$T13_FRAG_HASH_BEFORE" = "$T13_FRAG_HASH_AFTER" ]; then
  pass "AC6 opt-out delegation does NOT modify extraction-output (delegated to section runner)"
else
  fail "AC6-frag-mod" "frag hash changed: before=$T13_FRAG_HASH_BEFORE after=$T13_FRAG_HASH_AFTER"
fi

# Stderr emits delegation guidance for caller.
if grep -q 'Re-invoke section-d.sh' "$TEST_ROOT/t13.out"; then
  pass "AC6 delegation guidance points caller at section-d.sh re-invocation"
else
  fail "AC6-guidance" "delegation message missing; out=$(cat "$TEST_ROOT/t13.out")"
fi

# ---------- T-OPTOUT-INVALID: unknown surface ----------
T14_ROOT="$TEST_ROOT/t14"
setup_test_root "$T14_ROOT"
build_extraction_for_section "$T14_ROOT/.claude/onboarding/extraction-output-D.json" \
  "D" '{"U.behavioral.autonomy":"balanced"}' '{"U.behavioral.autonomy":0.9}'
run_script "$T14_ROOT" "D" --auto-opt-out invalid_surface > /dev/null 2>&1
T14_RC=$?
if [ "$T14_RC" -eq 2 ]; then
  pass "T-OPTOUT-INVALID unknown surface name rejects with exit 2"
else
  fail "T-OPTOUT-INVALID" "rc=$T14_RC (expected 2)"
fi

# ---------- T-PHASES-A: skeleton seeded when manifest absent ----------
T15_ROOT="$TEST_ROOT/t15"
setup_test_root "$T15_ROOT"
build_extraction_for_section "$T15_ROOT/.claude/onboarding/extraction-output-D.json" \
  "D" '{"U.behavioral.autonomy":"balanced","O.jobs[0].id":"librarian"}' \
  '{"U.behavioral.autonomy":0.95,"O.jobs[0].id":0.9}'
stage_audit_line "$T15_ROOT/.claude/onboarding/audit/section-d.jsonl" "D" "[]"
# user-manifest.json deliberately absent.
[ -f "$T15_ROOT/.claude/user-manifest.json" ] && rm -f "$T15_ROOT/.claude/user-manifest.json"

run_script "$T15_ROOT" "D" --auto-accept > /dev/null 2>&1
T15_MANIFEST="$T15_ROOT/.claude/user-manifest.json"
if jq -e '.system.phases_completed | index("D") != null' "$T15_MANIFEST" >/dev/null 2>&1; then
  pass "T-PHASES-A skeleton seeded when user-manifest absent; phases_completed[D] present"
else
  fail "T-PHASES-A" "manifest: $(cat "$T15_MANIFEST" 2>/dev/null)"
fi

# ---------- T-PHASES-B: idempotent dedup on re-accept ----------
T16_ROOT="$TEST_ROOT/t16"
setup_test_root "$T16_ROOT"
build_extraction_for_section "$T16_ROOT/.claude/onboarding/extraction-output-D.json" \
  "D" '{"U.behavioral.autonomy":"balanced","O.jobs[0].id":"librarian"}' \
  '{"U.behavioral.autonomy":0.95,"O.jobs[0].id":0.9}'
stage_audit_line "$T16_ROOT/.claude/onboarding/audit/section-d.jsonl" "D" "[]"
run_script "$T16_ROOT" "D" --auto-accept > /dev/null 2>&1
run_script "$T16_ROOT" "D" --auto-accept > /dev/null 2>&1
T16_MANIFEST="$T16_ROOT/.claude/user-manifest.json"

if jq -e '(.system.phases_completed | map(select(. == "D")) | length) == 1' "$T16_MANIFEST" >/dev/null 2>&1; then
  pass "T-PHASES-B re-accept is idempotent: D appears exactly once in phases_completed[]"
else
  fail "T-PHASES-B" "manifest: $(cat "$T16_MANIFEST")"
fi

# ---------- T-AUDIT-C: follow_ups[] carry-through preserved ----------
T17_ROOT="$TEST_ROOT/t17"
setup_test_root "$T17_ROOT"
build_extraction_for_section "$T17_ROOT/.claude/onboarding/extraction-output-D.json" \
  "D" \
  '{"U.behavioral.autonomy":"strict","O.jobs[0].id":"librarian","U.behavioral.hook_preferences.notification_style":"digest"}' \
  '{"U.behavioral.autonomy":0.95,"O.jobs[0].id":0.9,"U.behavioral.hook_preferences.notification_style":0.3}'
# Stage with a non-required LOW field already in follow_ups (D-4 notification_style is NOT required).
stage_audit_line "$T17_ROOT/.claude/onboarding/audit/section-d.jsonl" "D" \
  '["U.behavioral.hook_preferences.notification_style"]'

run_script "$T17_ROOT" "D" --auto-accept > /dev/null 2>&1
T17_AUDIT="$T17_ROOT/.claude/onboarding/audit/section-d.jsonl"

# Last line should carry the same follow_ups[] from the prior line (notification_style is non-required, so non-blocking).
if tail -1 "$T17_AUDIT" | jq -e '
    .follow_ups | index("U.behavioral.hook_preferences.notification_style") != null
  ' >/dev/null 2>&1; then
  pass "T-AUDIT-C follow_ups[] carry-through from prior audit line preserved"
else
  fail "T-AUDIT-C" "audit follow_ups: $(tail -1 "$T17_AUDIT" | jq -c '.follow_ups')"
fi

# ---------- AC1 + Section B & C: cross-section coverage ----------
# Section B: required B-1 (role), B-2 (projects), B-3 (people).
T18_ROOT="$TEST_ROOT/t18"
setup_test_root "$T18_ROOT"
build_extraction_for_section "$T18_ROOT/.claude/onboarding/extraction-output-B.json" \
  "B" \
  '{"U.identity.role":"data scientist","U.projects.active[]":[{"name":"alpha","status":"active"}],"U.people[]":[{"name":"j","role":"PM","relationship":"client"}]}' \
  '{"U.identity.role":0.9,"U.projects.active[]":0.85,"U.people[]":0.85}'
stage_audit_line "$T18_ROOT/.claude/onboarding/audit/section-b.jsonl" "B" "[]"
run_script "$T18_ROOT" "B" --auto-accept > /dev/null 2>&1
T18_RC=$?
T18_MANIFEST="$T18_ROOT/.claude/user-manifest.json"

if [ "$T18_RC" -eq 0 ] \
   && jq -e '.system.phases_completed | index("B") != null' "$T18_MANIFEST" >/dev/null 2>&1; then
  pass "AC1 Section B happy path → phases_completed[B] appended"
else
  fail "AC1-B" "rc=$T18_RC manifest=$(cat "$T18_MANIFEST" 2>/dev/null)"
fi

# Section C: required C-2 (is_fresh), C-4 (canonical_file_types).
T19_ROOT="$TEST_ROOT/t19"
setup_test_root "$T19_ROOT"
build_extraction_for_section "$T19_ROOT/.claude/onboarding/extraction-output-C.json" \
  "C" \
  '{"U.vault.is_fresh":false,"U.vault.canonical_file_types[]":["meetings","projects"]}' \
  '{"U.vault.is_fresh":0.95,"U.vault.canonical_file_types[]":0.9}'
stage_audit_line "$T19_ROOT/.claude/onboarding/audit/section-c.jsonl" "C" "[]"
run_script "$T19_ROOT" "C" --auto-accept > /dev/null 2>&1
T19_RC=$?
T19_MANIFEST="$T19_ROOT/.claude/user-manifest.json"

if [ "$T19_RC" -eq 0 ] \
   && jq -e '.system.phases_completed | index("C") != null' "$T19_MANIFEST" >/dev/null 2>&1; then
  pass "AC1 Section C happy path → phases_completed[C] appended"
else
  fail "AC1-C" "rc=$T19_RC manifest=$(cat "$T19_MANIFEST" 2>/dev/null)"
fi

# ---------- AC2: HIGH-only buckets (no MID, no LOW) renders correctly ----------
T20_ROOT="$TEST_ROOT/t20"
setup_test_root "$T20_ROOT"
build_extraction_for_section "$T20_ROOT/.claude/onboarding/extraction-output-D.json" \
  "D" \
  '{"U.behavioral.autonomy":"strict","O.jobs[0].id":"librarian"}' \
  '{"U.behavioral.autonomy":0.95,"O.jobs[0].id":0.9}'
stage_audit_line "$T20_ROOT/.claude/onboarding/audit/section-d.jsonl" "D" "[]"
run_script "$T20_ROOT" "D" --auto-accept > "$TEST_ROOT/t20.out" 2>&1

# Should still render the screen (with empty MID and LOW sections).
if grep -q 'High-confidence' "$TEST_ROOT/t20.out" \
   && grep -q '✓' "$TEST_ROOT/t20.out"; then
  pass "AC2 HIGH-only extraction renders screen with HIGH bullets"
else
  fail "AC2-high-only" "out=$(cat "$TEST_ROOT/t20.out")"
fi

# ---------- summary ----------
echo "=== render-summary-unit-test ==="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
