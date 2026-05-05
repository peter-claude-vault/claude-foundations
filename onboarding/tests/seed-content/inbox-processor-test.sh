#!/usr/bin/env bash
# onboarding/tests/seed-content/inbox-processor-test.sh — SP13 T-12 hermetic test.
#
# Validates the standing-Inbox processor end-to-end against an isolated
# CLAUDE_HOME under $TMPDIR per feedback_test_isolation_for_hooks_state +
# feedback_universal_vault_safety:
#   - $TMPDIR/inbox-processor-test-XXXXXX as $CLAUDE_HOME
#   - parallel test vault under the same tmpdir
#   - HOOKS_STATE_OVERRIDE used elsewhere (this skill performs zero
#     ~/.claude/ writes; we still snapshot the live G1 override-log to
#     prove no R-55 trips)
#   - ANTHROPIC_API_KEY unset to keep the LLM-fallback tier dormant
#     (we only test format + heuristic + unclassified-frontmatter tiers)
#
# Acceptance gates (paired to T-12 ACs in tasks.md):
#   AC1 — files exist + bash -n lint clean (R-23)
#   AC2 — transcript-shape Inbox/ drop routes via T-11 ingestor →
#         <vault>/Meetings/<YYYY-MM-DD>-<slug>.md
#   AC3 — markdown reference-shape drop routes → <vault>/Reference/<basename>
#   AC4 — markdown project-shape drop stays in Inbox/ with appended
#         processor_classification: project frontmatter
#   AC5 — markdown unclassified drop stays in Inbox/ with
#         processor_classification: unclassified frontmatter
#   AC6 — re-running on same Inbox/ contents is idempotent (state-cache hit;
#         no double-route, no double-frontmatter-append)
#   AC7 — install-cron.sh --dry-run emits a plutil-clean plist with
#         StartInterval == 900 when user-manifest inbox.poll_interval_minutes=15
#   AC8 — install-cron.sh --interval-minutes overrides user-manifest
#   AC9 — install-cron.sh out-of-range minutes (3, 2000) exit 3
#   AC10 — user-manifest schema validates the new inbox.poll_interval_minutes field
#   AC11 — audit log is JSONL with one record per file processed
#   AC12 — R-55 G1 override-log delta is 0 (no live-mutation gate trips)
#
# Bash 3.2 compatible (R-23). jq + python3 + plutil REQUIRED.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
PROCESS_SH="$REPO_ROOT/skills/inbox-processor/process.sh"
INSTALL_CRON="$REPO_ROOT/skills/inbox-processor/install-cron.sh"
SKILL_MD="$REPO_ROOT/skills/inbox-processor/SKILL.md"
PLIST_TMPL="$REPO_ROOT/templates/launchd/inbox-processor.plist.tmpl"
CRON_WRAPPER="$REPO_ROOT/orchestrator/cron-wrappers/inbox-processor-cron.sh"
RENDER_LAUNCHD="$REPO_ROOT/installer/render-launchd.sh"
USER_MANIFEST_SCHEMA="$REPO_ROOT/schemas/user-manifest-schema.json"
INGESTOR="$REPO_ROOT/skills/meeting-note-ingestor/ingest.sh"
PF_LIB="$REPO_ROOT/lib/provenance-frontmatter.sh"
FORMAT_DETECTOR="$REPO_ROOT/onboarding/seed-content/format-detector.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/inbox-processor-test-XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

# Hermetic env. Test isolation per feedback_test_isolation_for_hooks_state.
unset ANTHROPIC_API_KEY VOYAGE_API_KEY
export CLAUDE_HOME="$TMPROOT/claude"
export CLAUDE_LOG_DIR="$TMPROOT/claude/logs"
export HOOKS_STATE_OVERRIDE="$TMPROOT/claude/hooks/state"
mkdir -p "$CLAUDE_HOME/hooks/state" "$CLAUDE_HOME/logs" "$CLAUDE_HOME/hooks/lib"

# Snapshot live R-55 G1 override-log line count (must remain unchanged).
G1_LOG="$HOME/.claude/hooks/state/plan-71-live-mutation-overrides.log"
G1_BASELINE=0
if [ -f "$G1_LOG" ]; then
  G1_BASELINE=$(wc -l < "$G1_LOG" | tr -d ' ')
fi

VAULT="$TMPROOT/vault"
mkdir -p "$VAULT/Inbox"

PASS=0
FAIL=0
RESULTS_LOG="$TMPROOT/results.log"
: > "$RESULTS_LOG"

_log() { printf '%s\n' "$1" | tee -a "$RESULTS_LOG"; }
_pass() { PASS=$((PASS + 1)); _log "PASS $1"; }
_fail() { FAIL=$((FAIL + 1)); _log "FAIL $1"; }

_assert_file_exists() {
  if [ -f "$2" ]; then _pass "$1 — exists: $2"
  else _fail "$1 — missing: $2"
  fi
}

_assert_grep() {
  # $1 label  $2 needle (regex)  $3 file
  if grep -qE -- "$2" "$3" 2>/dev/null; then _pass "$1 — match: $2"
  else _fail "$1 — miss: $2 (file: $3)"
  fi
}

_assert_no_grep() {
  if grep -qE -- "$2" "$3" 2>/dev/null; then _fail "$1 — unexpected match: $2"
  else _pass "$1 — absent: $2"
  fi
}

_assert_eq() {
  if [ "$2" = "$3" ]; then _pass "$1 — eq: '$2'"
  else _fail "$1 — expected '$2' got '$3'"
  fi
}

# ============================================================================
# AC1 — files exist + bash -n lint clean
# ============================================================================
_log "--- AC1: files exist + R-23 bash -n lint ---"
_assert_file_exists "AC1.1 SKILL.md"        "$SKILL_MD"
_assert_file_exists "AC1.2 process.sh"      "$PROCESS_SH"
_assert_file_exists "AC1.3 install-cron.sh" "$INSTALL_CRON"
_assert_file_exists "AC1.4 plist tmpl"      "$PLIST_TMPL"
_assert_file_exists "AC1.5 cron wrapper"    "$CRON_WRAPPER"
_assert_file_exists "AC1.6 render-launchd"  "$RENDER_LAUNCHD"
_assert_file_exists "AC1.7 schema"          "$USER_MANIFEST_SCHEMA"

for sh in "$PROCESS_SH" "$INSTALL_CRON" "$CRON_WRAPPER"; do
  if bash -n "$sh" 2>/dev/null; then _pass "AC1.8 bash -n: $(basename "$sh")"
  else _fail "AC1.8 bash -n FAILED: $sh"
  fi
done

# ============================================================================
# AC2 — transcript-shape Inbox drop → <vault>/Meetings/
# ============================================================================
_log "--- AC2: transcript-shape routes to Meetings/ ---"
VTT="$VAULT/Inbox/2026-04-21-DDX-Standup.vtt"
cat > "$VTT" <<'EOF'
WEBVTT

NOTE
header note

1
00:00:00.000 --> 00:00:05.000
Peter Tiktinsky: Welcome to the standup.

2
00:00:05.000 --> 00:00:12.000
Ellie Chen: Thanks Peter. Let me cover the BAR dashboard.
EOF

bash "$PROCESS_SH" \
  --vault-root "$VAULT" \
  --audit-log "$CLAUDE_LOG_DIR/audit.jsonl" \
  --state-file "$CLAUDE_HOME/state.json" \
  >"$TMPROOT/ac2.out" 2>"$TMPROOT/ac2.err"
ac2_rc=$?
_assert_eq "AC2.1 process.sh rc" "0" "$ac2_rc"

# Inbox source consumed.
if [ ! -f "$VTT" ]; then _pass "AC2.2 source vtt removed from Inbox/"
else _fail "AC2.2 source vtt still present after route"
fi

# Routed file present under Meetings/.
routed_count=$(find "$VAULT/Meetings" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$routed_count" -ge 1 ]; then _pass "AC2.3 Meetings/ has routed note (n=$routed_count)"
else _fail "AC2.3 Meetings/ has no routed note"
fi

# Routed file carries meeting-note-ingestor provenance (the inbox-processor
# delegated transcript classification to meeting-note-ingestor, so the
# generated_by is the ingestor's surface_id).
routed_file=$(find "$VAULT/Meetings" -name '*.md' -type f 2>/dev/null | head -1)
if [ -n "$routed_file" ]; then
  _assert_grep "AC2.4 routed file has meeting-note-ingestor provenance" 'generated_by:[[:space:]]*meeting-note-ingestor' "$routed_file"
  _assert_grep "AC2.5 routed file has source_format vtt"                 'source_format:[[:space:]]*otter-vtt' "$routed_file"
fi

# ============================================================================
# AC3 — reference-shape Inbox drop → <vault>/Reference/
# ============================================================================
_log "--- AC3: reference-shape routes to Reference/ ---"
REF="$VAULT/Inbox/README.md"
cat > "$REF" <<'EOF'
# README

Reference document for the project. Meant to be in vault Reference/.

#reference
EOF

bash "$PROCESS_SH" \
  --vault-root "$VAULT" \
  --audit-log "$CLAUDE_LOG_DIR/audit.jsonl" \
  --state-file "$CLAUDE_HOME/state.json" \
  >"$TMPROOT/ac3.out" 2>"$TMPROOT/ac3.err"
_assert_eq "AC3.1 process.sh rc" "0" "$?"
if [ ! -f "$REF" ]; then _pass "AC3.2 source README.md removed from Inbox/"
else _fail "AC3.2 source README.md still present after route"
fi
ref_count=$(find "$VAULT/Reference" -name 'README*' -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$ref_count" -ge 1 ]; then _pass "AC3.3 Reference/ has routed file"
else _fail "AC3.3 Reference/ has no routed file"
fi
ref_file=$(find "$VAULT/Reference" -name 'README*' -type f 2>/dev/null | head -1)
if [ -n "$ref_file" ]; then
  _assert_grep "AC3.4 ref file has provenance frontmatter" 'generated_by:[[:space:]]*inbox-processor' "$ref_file"
  _assert_grep "AC3.5 ref file has disposition: reference"  'disposition:[[:space:]]*reference' "$ref_file"
fi

# ============================================================================
# AC4 — project-shape stays in Inbox/ with frontmatter hint
# ============================================================================
_log "--- AC4: project-shape stays in Inbox/ with frontmatter hint ---"
PROJ="$VAULT/Inbox/ddx-bar-redesign.md"
cat > "$PROJ" <<'EOF'
---
type: project
title: DDX BAR Dashboard Redesign
---

#engagement/cdmo-ddx

## Background

Project notes start here.
EOF

bash "$PROCESS_SH" \
  --vault-root "$VAULT" \
  --audit-log "$CLAUDE_LOG_DIR/audit.jsonl" \
  --state-file "$CLAUDE_HOME/state.json" \
  >"$TMPROOT/ac4.out" 2>"$TMPROOT/ac4.err"
_assert_eq "AC4.1 process.sh rc" "0" "$?"
if [ -f "$PROJ" ]; then _pass "AC4.2 project file remains in Inbox/"
else _fail "AC4.2 project file disappeared from Inbox/"
fi
if [ -f "$PROJ" ]; then
  _assert_grep "AC4.3 project file has processor_classification: project" 'processor_classification:[[:space:]]*project' "$PROJ"
  _assert_grep "AC4.4 project file has processor_attempted_at"             'processor_attempted_at:' "$PROJ"
fi

# ============================================================================
# AC5 — unclassified stays in Inbox/ with frontmatter
# ============================================================================
_log "--- AC5: unclassified stays in Inbox/ with frontmatter ---"
UNK="$VAULT/Inbox/random-thoughts.md"
cat > "$UNK" <<'EOF'
just some random text without any project or reference markers.

a few unstructured paragraphs about miscellaneous things.
EOF

bash "$PROCESS_SH" \
  --vault-root "$VAULT" \
  --audit-log "$CLAUDE_LOG_DIR/audit.jsonl" \
  --state-file "$CLAUDE_HOME/state.json" \
  >"$TMPROOT/ac5.out" 2>"$TMPROOT/ac5.err"
_assert_eq "AC5.1 process.sh rc" "0" "$?"
if [ -f "$UNK" ]; then _pass "AC5.2 unclassified file remains in Inbox/"
else _fail "AC5.2 unclassified file disappeared"
fi
if [ -f "$UNK" ]; then
  _assert_grep "AC5.3 has processor_classification: unclassified" 'processor_classification:[[:space:]]*unclassified' "$UNK"
fi

# ============================================================================
# AC6 — idempotency: re-run does not double-route or double-append
# ============================================================================
_log "--- AC6: idempotency on re-run ---"
proj_attempts_before=$(grep -c 'processor_attempted_at:' "$PROJ" 2>/dev/null || echo 0)
unk_attempts_before=$(grep -c 'processor_attempted_at:' "$UNK" 2>/dev/null || echo 0)
ref_count_before=$(find "$VAULT/Reference" -type f 2>/dev/null | wc -l | tr -d ' ')
meet_count_before=$(find "$VAULT/Meetings" -type f 2>/dev/null | wc -l | tr -d ' ')

bash "$PROCESS_SH" \
  --vault-root "$VAULT" \
  --audit-log "$CLAUDE_LOG_DIR/audit.jsonl" \
  --state-file "$CLAUDE_HOME/state.json" \
  >"$TMPROOT/ac6.out" 2>"$TMPROOT/ac6.err"
_assert_eq "AC6.1 second-run rc" "0" "$?"

proj_attempts_after=$(grep -c 'processor_attempted_at:' "$PROJ" 2>/dev/null || echo 0)
unk_attempts_after=$(grep -c 'processor_attempted_at:' "$UNK" 2>/dev/null || echo 0)
ref_count_after=$(find "$VAULT/Reference" -type f 2>/dev/null | wc -l | tr -d ' ')
meet_count_after=$(find "$VAULT/Meetings" -type f 2>/dev/null | wc -l | tr -d ' ')

_assert_eq "AC6.2 project frontmatter not duplicated" "$proj_attempts_before" "$proj_attempts_after"
_assert_eq "AC6.3 unclassified frontmatter not duplicated" "$unk_attempts_before" "$unk_attempts_after"
_assert_eq "AC6.4 Reference/ count stable" "$ref_count_before" "$ref_count_after"
_assert_eq "AC6.5 Meetings/ count stable" "$meet_count_before" "$meet_count_after"

# ============================================================================
# AC7 — install-cron --dry-run with user-manifest interval=15 → StartInterval 900
# ============================================================================
_log "--- AC7: install-cron --dry-run respects user-manifest ---"
cat > "$CLAUDE_HOME/user-manifest.json" <<EOF
{
  "identity": {"name": null},
  "paths": {"vault_root": "$VAULT"},
  "tools": {},
  "vault": {"root": "$VAULT", "is_fresh": false},
  "projects": {},
  "people": [],
  "behavioral": {},
  "backlog": {},
  "architect": {},
  "system": {"schema_version": "1.5.0"},
  "inbox": {"poll_interval_minutes": 15}
}
EOF

# render-launchd needs paths.sh resolvable. Stub it.
cat > "$CLAUDE_HOME/hooks/lib/paths.sh" <<EOF
export CLAUDE_HOME="$CLAUDE_HOME"
export CLAUDE_LOG_DIR="$CLAUDE_LOG_DIR"
export ORCHESTRATION_JSON="$CLAUDE_HOME/orchestration.json"
EOF

bash "$INSTALL_CRON" --dry-run >"$TMPROOT/ac7.plist" 2>"$TMPROOT/ac7.err"
ac7_rc=$?
_assert_eq "AC7.1 install-cron --dry-run rc" "0" "$ac7_rc"
_assert_grep "AC7.2 plist has StartInterval"   '<key>StartInterval</key>' "$TMPROOT/ac7.plist"
_assert_grep "AC7.3 plist has 900-second interval" '<integer>900</integer>' "$TMPROOT/ac7.plist"
_assert_grep "AC7.4 plist label is com.claude-stem.inbox-processor" '<string>com\.claude-stem\.inbox-processor</string>' "$TMPROOT/ac7.plist"

# Validate via plutil
if plutil -lint -s "$TMPROOT/ac7.plist" >/dev/null 2>&1; then _pass "AC7.5 plutil -lint clean"
else _fail "AC7.5 plutil -lint failed"
fi

# ============================================================================
# AC8 — install-cron --interval-minutes overrides user-manifest
# ============================================================================
_log "--- AC8: --interval-minutes override ---"
bash "$INSTALL_CRON" --dry-run --interval-minutes 30 >"$TMPROOT/ac8.plist" 2>"$TMPROOT/ac8.err"
_assert_eq "AC8.1 rc" "0" "$?"
_assert_grep "AC8.2 plist has 1800-second interval" '<integer>1800</integer>' "$TMPROOT/ac8.plist"

# ============================================================================
# AC9 — out-of-range minutes exit 3
# ============================================================================
_log "--- AC9: out-of-range minutes exit 3 ---"
bash "$INSTALL_CRON" --dry-run --interval-minutes 3 >/dev/null 2>"$TMPROOT/ac9a.err"
_assert_eq "AC9.1 minutes=3 (below 5) rc" "3" "$?"
bash "$INSTALL_CRON" --dry-run --interval-minutes 2000 >/dev/null 2>"$TMPROOT/ac9b.err"
_assert_eq "AC9.2 minutes=2000 (above 1440) rc" "3" "$?"

# ============================================================================
# AC10 — schema validates inbox.poll_interval_minutes
# ============================================================================
_log "--- AC10: schema validation ---"
python3 - "$USER_MANIFEST_SCHEMA" "$CLAUDE_HOME/user-manifest.json" <<'PY' 2>"$TMPROOT/ac10.err"
import json, sys
try:
    import jsonschema
except ImportError:
    print("SKIP: jsonschema not installed")
    sys.exit(0)
schema = json.load(open(sys.argv[1]))
inst = json.load(open(sys.argv[2]))
jsonschema.Draft7Validator.check_schema(schema)
v = jsonschema.Draft7Validator(schema)
errs = sorted(v.iter_errors(inst), key=lambda e: e.path)
if errs:
    for e in errs:
        print("VALIDATION-ERR:", e.message, "path:", list(e.path))
    sys.exit(1)
print("validation-ok")
PY
ac10_rc=$?
_assert_eq "AC10.1 schema validation rc" "0" "$ac10_rc"

# Out-of-range value should fail validation.
cat > "$TMPROOT/bad-manifest.json" <<EOF
{
  "identity": {}, "paths": {}, "tools": {}, "vault": {},
  "projects": {}, "people": [], "behavioral": {}, "backlog": {},
  "architect": {}, "system": {"schema_version": "1.5.0"},
  "inbox": {"poll_interval_minutes": 2}
}
EOF
python3 - "$USER_MANIFEST_SCHEMA" "$TMPROOT/bad-manifest.json" <<'PY' 2>"$TMPROOT/ac10b.err"
import json, sys
try:
    import jsonschema
except ImportError:
    print("SKIP: jsonschema not installed")
    sys.exit(2)
schema = json.load(open(sys.argv[1]))
inst = json.load(open(sys.argv[2]))
v = jsonschema.Draft7Validator(schema)
errs = list(v.iter_errors(inst))
if errs:
    sys.exit(1)
print("unexpected-pass")
sys.exit(0)
PY
rc_bad=$?
case "$rc_bad" in
  1) _pass "AC10.2 minutes=2 (below 5) fails validation" ;;
  2) _pass "AC10.2 SKIP — jsonschema not installed" ;;
  *) _fail "AC10.2 minutes=2 unexpectedly passed validation (rc=$rc_bad)" ;;
esac

# ============================================================================
# AC11 — audit log is JSONL with one record per file
# ============================================================================
_log "--- AC11: audit log JSONL ---"
audit="$CLAUDE_LOG_DIR/audit.jsonl"
if [ -f "$audit" ]; then
  _pass "AC11.1 audit log exists"
  if jq -c '.' "$audit" >/dev/null 2>&1; then _pass "AC11.2 audit log JSONL parses"
  else _fail "AC11.2 audit log JSONL parse failed"
  fi
  total=$(wc -l < "$audit" | tr -d ' ')
  if [ "$total" -ge 4 ]; then _pass "AC11.3 audit log has ≥4 records (got $total)"
  else _fail "AC11.3 audit log has only $total records (expected ≥4 from AC2/3/4/5 + AC6 cache hits)"
  fi
  # Required fields per record.
  if jq -e 'select(.classification == null or .file == null or .ts == null or .tier == null) | true' "$audit" >/dev/null 2>&1; then
    _fail "AC11.4 audit log has records missing required fields"
  else
    _pass "AC11.4 every audit record has ts+file+classification+tier"
  fi
  # state-cache tier should appear in the second-run records.
  if grep -q '"tier":"state-cache"' "$audit"; then _pass "AC11.5 second-run produced state-cache hits"
  else _fail "AC11.5 no state-cache tier records (idempotency dedup not firing)"
  fi
else
  _fail "AC11.1 audit log not written"
fi

# ============================================================================
# AC12 — R-55 G1 override-log delta is 0
# ============================================================================
_log "--- AC12: R-55 G1 override-log invariant ---"
G1_AFTER=0
if [ -f "$G1_LOG" ]; then
  G1_AFTER=$(wc -l < "$G1_LOG" | tr -d ' ')
fi
_assert_eq "AC12.1 G1 override-log delta == 0" "$G1_BASELINE" "$G1_AFTER"

# ============================================================================
# Summary
# ============================================================================
_log "================================================================"
_log "RESULTS: PASS=$PASS FAIL=$FAIL"
_log "================================================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
