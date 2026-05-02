#!/bin/bash
# onboarding/opt-outs/validate-full-opt-out.sh — SP07 T-8 end-to-end
# opt-out audit harness.
#
# OUTPUT CONTRACT (R-43):
#   Per-run hermetic isolation: $TEST_ROOT/.claude/* (no live mutations).
#   Files written inside $TEST_ROOT (atomic tmp+rename owned by callees):
#     - extraction-output-{A,B,C,D,E}.json (section runners)
#     - user-manifest.json + orchestration.json (bootstrap-schemas.sh)
#   Audit log: $TEST_ROOT/validate-full-opt-out.jsonl (single line per run)
#
#   Pre-write validation: each section runner + bootstrap-schemas.sh own
#   their own pre-write validation pipelines (atomic tmp+rename + ajv/jq
#   schema validation). This harness gates on their exit codes + adds two
#   structural assertions on the composed terminal state:
#     - orchestration.jobs == []
#     - $CLAUDE_HOME/Library/LaunchAgents.staging/ has no plist
#
#   Failure mode: BLOCK AND LOG. Any section runner failure, schema
#   validation failure, or terminal-state assertion failure ⇒ exit
#   non-zero with a diagnostic on stderr + a single audit line. Live
#   targets (real $CLAUDE_HOME) are untouched (HOME-isolation enforced).
#
# T-DOGFOOD GATE (per SP07 spec.md T-8):
#   "Full-opt-out MUST pass schema validation — if any opt-out combination
#   produces invalid manifest, block release." This script is the
#   release-gate executable. SP08 enable-daemon flow + T-11 Alex dogfood
#   reference its rc=0 as the structural pass signal.
#
# USAGE:
#   validate-full-opt-out.sh [--test-root DIR] [--keep] [--verbose]
#
#   --test-root DIR   Use DIR as the hermetic root (default: mktemp -d)
#   --keep            Do not rm -rf the test root on exit (forensic)
#   --verbose         Echo each section runner stderr (default: capture)
#
# EXIT CODES:
#   0   full-opt-out terminal state passed all assertions
#   1   schema validation failure (bootstrap-schemas.sh non-zero)
#   2   bad invocation / missing dependency / setup failure
#   3   section runner failure
#   4   terminal-state assertion failure (jobs!=[] or plist staged)
#
# CONSTRAINTS (R-23 + Hard Rule 9):
#   - bash 3.2.57 — no `declare -A`, no `mapfile`/`readarray`, no
#     `${var,,}`. Tilde expansion stripped via `${var:2}` substring
#     slicing (S82 in-flight bug discovery).
#   - jq required on PATH; ajv optional (bootstrap-schemas.sh falls back
#     to jq structural validation).
#   - Reference-leak floor: audit log holds field-path identifiers only
#     (no user-typed strings).

set -u
LC_ALL=C

# --- diagnostic helpers ---
diag() { printf 'validate-full-opt-out FAIL: %s\n' "$1" >&2; }
info() { printf 'validate-full-opt-out: %s\n' "$1" >&2; }

# --- dependency check ---
for tool in jq date mktemp; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    diag "$tool required but not on PATH"
    exit 2
  fi
done

# --- foundation-repo source resolution (Bucket A) ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONBOARDING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ONBOARDING_DIR/.." && pwd)"
SECTION_A_BIN="${SECTION_A_BIN:-$ONBOARDING_DIR/ux/section-a.sh}"
SECTION_B_BIN="${SECTION_B_BIN:-$ONBOARDING_DIR/ux/section-b.sh}"
SECTION_C_BIN="${SECTION_C_BIN:-$ONBOARDING_DIR/ux/section-c.sh}"
SECTION_D_BIN="${SECTION_D_BIN:-$ONBOARDING_DIR/ux/section-d.sh}"
SECTION_E_BIN="${SECTION_E_BIN:-$ONBOARDING_DIR/ux/section-e.sh}"
BOOTSTRAP_BIN="${BOOTSTRAP_BIN:-$ONBOARDING_DIR/bootstrap-schemas.sh}"
Q_FIELD_MAP_SRC="${Q_FIELD_MAP_SRC:-$ONBOARDING_DIR/q-field-map.json}"
SCHEMAS_SRC="${SCHEMAS_SRC:-$REPO_ROOT/schemas}"

for f in "$SECTION_A_BIN" "$SECTION_B_BIN" "$SECTION_C_BIN" \
         "$SECTION_D_BIN" "$SECTION_E_BIN" "$BOOTSTRAP_BIN"; do
  [ -x "$f" ] || { diag "missing or non-exec: $f"; exit 2; }
done
[ -r "$Q_FIELD_MAP_SRC" ] || { diag "q-field-map.json not readable: $Q_FIELD_MAP_SRC"; exit 2; }
[ -d "$SCHEMAS_SRC" ] || { diag "schemas dir not readable: $SCHEMAS_SRC"; exit 2; }

# --- arg parse ---
TEST_ROOT=""
KEEP=0
VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --test-root) TEST_ROOT="$2"; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    --verbose)   VERBOSE=1; shift ;;
    -h|--help)   sed -n '2,55p' "$0"; exit 0 ;;
    *)           diag "unknown arg: $1"; exit 2 ;;
  esac
done

if [ -z "$TEST_ROOT" ]; then
  TEST_ROOT="$(mktemp -d -t validate-full-opt-out-XXXXXX)"
fi

if [ "$KEEP" = "0" ]; then
  trap 'rm -rf "$TEST_ROOT"' EXIT
else
  trap 'info "keeping test root: $TEST_ROOT"' EXIT
fi

# --- hermetic env ---
export HOME="$TEST_ROOT"
export CLAUDE_HOME="$TEST_ROOT/.claude"
INPUTS_DIR="$CLAUDE_HOME/onboarding"
SCHEMAS_DIR="$CLAUDE_HOME/schemas"
AUDIT_DIR="$CLAUDE_HOME/onboarding/audit"
TRANSCRIPT_DIR="$CLAUDE_HOME/onboarding/transcripts"
STAGING_DIR="$CLAUDE_HOME/Library/LaunchAgents.staging"
HARNESS_AUDIT="$TEST_ROOT/validate-full-opt-out.jsonl"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$INPUTS_DIR" "$SCHEMAS_DIR" "$AUDIT_DIR" "$TRANSCRIPT_DIR" || {
  diag "cannot create hermetic directory tree"
  exit 2
}

# Schemas + q-field-map: ship-to-runtime would copy these in; for the
# harness we copy from foundation-repo source (Bucket A path).
cp "$SCHEMAS_SRC/user-manifest-schema.json"    "$SCHEMAS_DIR/user-manifest-schema.json"
cp "$SCHEMAS_SRC/orchestration-schema.json"    "$SCHEMAS_DIR/orchestration-schema.json"
cp "$SCHEMAS_SRC/vault-schema.json"            "$SCHEMAS_DIR/vault-schema.json"
cp "$SCHEMAS_SRC/plans-schema.json"            "$SCHEMAS_DIR/plans-schema.json"
cp "$Q_FIELD_MAP_SRC"                          "$INPUTS_DIR/q-field-map.json"

# Section prompt-card stubs. Sections B/C/D require PROMPT_CARD_PATH but
# in the opt-out path the card content is not extraction-relevant.
PROMPT_CARD_B="$TEST_ROOT/prompt-card-B.txt"
PROMPT_CARD_C="$TEST_ROOT/prompt-card-C.txt"
PROMPT_CARD_D="$TEST_ROOT/prompt-card-D.txt"
printf 'Section B prompt card stub (full-opt-out validation harness).\n' > "$PROMPT_CARD_B"
printf 'Section C prompt card stub (full-opt-out validation harness).\n' > "$PROMPT_CARD_C"
printf 'Section D prompt card stub (full-opt-out validation harness).\n' > "$PROMPT_CARD_D"

# --- harness audit emit (single line) ---
emit_audit() {
  local status="$1" stage="$2" extra_json="${3:-}"
  if [ -z "$extra_json" ]; then extra_json='{}'; fi
  jq -nc \
    --arg ts "$RUN_TS" \
    --arg run_id "$RUN_ID" \
    --arg status "$status" \
    --arg stage "$stage" \
    --argjson extra "$extra_json" \
    '{ts: $ts, run_id: $run_id, status: $status, stage: $stage} + $extra' \
    >> "$HARNESS_AUDIT" 2>/dev/null || true
}

run_or_fail() {
  local stage="$1"; shift
  local logfile="$TEST_ROOT/${stage}.log"
  if [ "$VERBOSE" = "1" ]; then
    "$@" 2>&1 | tee "$logfile"
    local rc=${PIPESTATUS[0]}
  else
    "$@" >"$logfile" 2>&1
    local rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    diag "$stage failed (rc=$rc); see $logfile"
    if [ "$VERBOSE" = "0" ]; then
      sed -n '1,40p' "$logfile" >&2 2>/dev/null || true
    fi
    emit_audit "FAILED" "$stage" "$(jq -nc --arg rc "$rc" '{rc: ($rc|tonumber)}')"
    exit 3
  fi
  return 0
}

# --- Section A: deterministic-section opt-out path; writes extraction-output-A.json ---
run_or_fail "section-a" \
  env HOME="$HOME" CLAUDE_HOME="$CLAUDE_HOME" \
      INPUTS_DIR="$INPUTS_DIR" \
      AUDIT_LOG="$AUDIT_DIR/section-a.jsonl" \
      TRANSCRIPT_DIR="$TRANSCRIPT_DIR" \
      Q_FIELD_MAP="$INPUTS_DIR/q-field-map.json" \
    "$SECTION_A_BIN" --auto-opt-out

[ -f "$INPUTS_DIR/extraction-output-A.json" ] \
  || { diag "extraction-output-A.json not produced"; exit 3; }

# --- Section B/C/D hermetic stubs ---
# Each is a minimal valid extraction-output-{B,C,D}.json that the
# section's --auto-opt-out path mutates in place. Confidence map is
# arbitrary (≥0.85 keeps fields out of follow-up); populated keys per
# the section's expected schema slice (q-field-map.json direct_qs.{B,C,D}-*).
build_b_stub() {
  jq -nc '{
    section_id: "B",
    extraction_mode: "transcript",
    populated: {
      "U.identity.role": "consultant",
      "U.identity.organization": "Stub Org",
      "U.projects.active": ["stub-project"],
      "U.people": [{"name":"Stub Person","role":"colleague","cadence":"weekly"}],
      "U.behavioral.cadence_default": "weekly"
    },
    confidence: {
      "U.identity.role": 0.9,
      "U.identity.organization": 0.9,
      "U.projects.active": 0.9,
      "U.people": 0.9,
      "U.behavioral.cadence_default": 0.9
    },
    source_spans: {},
    missing_required: [],
    conflicts: [],
    follow_up: null
  }'
}

build_c_stub() {
  jq -nc '{
    section_id: "C",
    extraction_mode: "transcript",
    populated: {
      "U.vault.organizational_method": "engagement-based",
      "U.vault.has_structured_projects": true,
      "U.vault.is_fresh": false,
      "U.vault.canonical_file_types": ["md","json"]
    },
    confidence: {
      "U.vault.organizational_method": 0.9,
      "U.vault.has_structured_projects": 0.9,
      "U.vault.is_fresh": 0.9,
      "U.vault.canonical_file_types": 0.9
    },
    source_spans: {},
    missing_required: [],
    conflicts: [],
    follow_up: null
  }'
}

build_d_stub() {
  jq -nc '{
    section_id: "D",
    extraction_mode: "transcript",
    populated: {
      "U.behavioral.autonomy": "balanced",
      "O.jobs[0].id": "librarian",
      "U.behavioral.hook_preferences.notification_style": "digest"
    },
    confidence: {
      "U.behavioral.autonomy": 0.9,
      "O.jobs[0].id": 0.9
    },
    source_spans: {},
    missing_required: [],
    conflicts: [],
    follow_up: null
  }'
}

# Pre-stage transcripts so capture step is skipped (idempotent re-entry).
printf 'Stub Section B transcript (full-opt-out harness).\n' \
  > "$TRANSCRIPT_DIR/section-b.txt"
printf 'Stub Section C transcript (full-opt-out harness).\n' \
  > "$TRANSCRIPT_DIR/section-c.txt"
printf 'Stub Section D transcript (full-opt-out harness).\n' \
  > "$TRANSCRIPT_DIR/section-d.txt"

# Pre-stage extraction stubs.
B_STUB="$INPUTS_DIR/extraction-stub-B.json"
C_STUB="$INPUTS_DIR/extraction-stub-C.json"
D_STUB="$INPUTS_DIR/extraction-stub-D.json"
build_b_stub > "$B_STUB"
build_c_stub > "$C_STUB"
build_d_stub > "$D_STUB"

# Stub initial-job-setup.sh: must exist (referenced by section-d.sh) but
# should NEVER be invoked when --opt-out-initial-job is elected. Records
# any invocation to a tripwire file; the assertion below verifies absence.
IJS_TRIPWIRE="$TEST_ROOT/ijs-tripwire.log"
IJS_STUB="$TEST_ROOT/stub-ijs.sh"
cat > "$IJS_STUB" <<STUB
#!/bin/bash
echo "ijs invoked (full-opt-out should never trigger this)" >> "$IJS_TRIPWIRE"
exit 0
STUB
chmod +x "$IJS_STUB"

# --- Section B: --auto-opt-out blanket (#2 + #3 + #4) ---
run_or_fail "section-b" \
  env HOME="$HOME" CLAUDE_HOME="$CLAUDE_HOME" \
      INPUTS_DIR="$INPUTS_DIR" \
      AUDIT_LOG="$AUDIT_DIR/section-b.jsonl" \
      TRANSCRIPT_DIR="$TRANSCRIPT_DIR" \
      Q_FIELD_MAP="$INPUTS_DIR/q-field-map.json" \
      EXTRACTION_OUTPUT_OVERRIDE="$B_STUB" \
      PROMPT_CARD_PATH="$PROMPT_CARD_B" \
    "$SECTION_B_BIN" --auto-confirm --auto-opt-out

# --- Section C: --auto-opt-out blanket (#5 + #6) ---
run_or_fail "section-c" \
  env HOME="$HOME" CLAUDE_HOME="$CLAUDE_HOME" \
      INPUTS_DIR="$INPUTS_DIR" \
      AUDIT_LOG="$AUDIT_DIR/section-c.jsonl" \
      TRANSCRIPT_DIR="$TRANSCRIPT_DIR" \
      Q_FIELD_MAP="$INPUTS_DIR/q-field-map.json" \
      EXTRACTION_OUTPUT_OVERRIDE="$C_STUB" \
      PROMPT_CARD_PATH="$PROMPT_CARD_C" \
    "$SECTION_C_BIN" --auto-confirm --auto-opt-out

# --- Section D: --auto-opt-out blanket (#7 + #8 + #9 + #10) ---
# --opt-out-initial-job is among the elected (via --auto-opt-out blanket);
# initial-job-setup.sh MUST NOT be invoked. The IJS tripwire below
# verifies this.
run_or_fail "section-d" \
  env HOME="$HOME" CLAUDE_HOME="$CLAUDE_HOME" \
      INPUTS_DIR="$INPUTS_DIR" \
      AUDIT_LOG="$AUDIT_DIR/section-d.jsonl" \
      TRANSCRIPT_DIR="$TRANSCRIPT_DIR" \
      Q_FIELD_MAP="$INPUTS_DIR/q-field-map.json" \
      EXTRACTION_OUTPUT_OVERRIDE="$D_STUB" \
      PROMPT_CARD_PATH="$PROMPT_CARD_D" \
      INITIAL_JOB_SETUP_BIN="$IJS_STUB" \
    "$SECTION_D_BIN" --auto-confirm --auto-opt-out

# --- Section E: deterministic; --auto-accept (no opt-outs in E) ---
run_or_fail "section-e" \
  env HOME="$HOME" CLAUDE_HOME="$CLAUDE_HOME" \
      INPUTS_DIR="$INPUTS_DIR" \
      AUDIT_LOG="$AUDIT_DIR/section-e.jsonl" \
    "$SECTION_E_BIN" --auto-accept

# --- bootstrap-schemas.sh: composes user-manifest.json + orchestration.json ---
# Schema-validation gate: if bootstrap-schemas.sh exits 0, every output
# has passed its pre-write validator (ajv when on PATH, jq fallback).
# Failure here means schema validation rejected the full-opt-out terminal
# state — block release.
BOOTSTRAP_LOG="$TEST_ROOT/bootstrap-schemas.log"
"$BOOTSTRAP_BIN" \
  --inputs-dir "$INPUTS_DIR" \
  --schemas-dir "$SCHEMAS_DIR" \
  --audit-log "$AUDIT_DIR/bootstrap-log.jsonl" \
  --force \
  >"$BOOTSTRAP_LOG" 2>&1
BOOTSTRAP_RC=$?
if [ "$BOOTSTRAP_RC" -ne 0 ]; then
  diag "bootstrap-schemas.sh failed (rc=$BOOTSTRAP_RC); schema validation gate"
  sed -n '1,60p' "$BOOTSTRAP_LOG" >&2 2>/dev/null || true
  emit_audit "FAILED" "bootstrap-schemas" \
    "$(jq -nc --arg rc "$BOOTSTRAP_RC" '{rc: ($rc|tonumber)}')"
  exit 1
fi

USER_MANIFEST="$CLAUDE_HOME/user-manifest.json"
ORCHESTRATION="$CLAUDE_HOME/orchestration.json"
[ -f "$USER_MANIFEST" ] \
  || { diag "user-manifest.json not produced"; exit 1; }
[ -f "$ORCHESTRATION" ] \
  || { diag "orchestration.json not produced"; exit 1; }

# --- Terminal-state assertion #1: orchestration.jobs == [] ---
# Per SP07 spec.md T-8 AC #3 ("Full-opt-out run produces empty
# orchestration.json that validates against SP01 schema").
JOBS_LEN="$(jq '.jobs | length' "$ORCHESTRATION" 2>/dev/null)"
if [ "$JOBS_LEN" != "0" ]; then
  diag "orchestration.jobs is non-empty (length=$JOBS_LEN); full-opt-out should produce empty jobs[]"
  jq '.jobs' "$ORCHESTRATION" >&2 2>/dev/null || true
  emit_audit "FAILED" "assert-jobs-empty" \
    "$(jq -nc --arg n "$JOBS_LEN" '{jobs_length: ($n|tonumber)}')"
  exit 4
fi

# --- Terminal-state assertion #2: no plist staged ---
# Per SP07 spec.md T-8 AC #4 ("Full-opt-out run installs zero launchd
# jobs"). In hermetic harness this manifests as zero plist files in
# the staging directory (initial-job-setup.sh skipped via opt-out #9).
PLIST_COUNT=0
if [ -d "$STAGING_DIR" ]; then
  PLIST_COUNT="$(find "$STAGING_DIR" -maxdepth 1 -name '*.plist' -type f 2>/dev/null | wc -l | tr -d ' ')"
fi
if [ "$PLIST_COUNT" != "0" ]; then
  diag "plist files staged in $STAGING_DIR (count=$PLIST_COUNT); full-opt-out should stage zero"
  ls -la "$STAGING_DIR" >&2 2>/dev/null || true
  emit_audit "FAILED" "assert-zero-plist" \
    "$(jq -nc --arg n "$PLIST_COUNT" '{plist_count: ($n|tonumber)}')"
  exit 4
fi

# --- Terminal-state assertion #3: IJS tripwire ---
# Section D's --opt-out-initial-job (elected via --auto-opt-out) MUST
# skip initial-job-setup.sh entirely. Tripwire log absence confirms.
if [ -s "$IJS_TRIPWIRE" ]; then
  diag "initial-job-setup.sh was invoked under full-opt-out (#9 elected); should be skipped"
  cat "$IJS_TRIPWIRE" >&2 2>/dev/null || true
  emit_audit "FAILED" "assert-ijs-skipped" '{}'
  exit 4
fi

# --- success ---
emit_audit "PASSED" "full-opt-out" '{}'
info "full-opt-out validation PASSED (test-root: $TEST_ROOT)"
exit 0
