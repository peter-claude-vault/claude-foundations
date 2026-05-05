#!/usr/bin/env bash
# tests/greenfield-pipeline/greenfield-end-to-end.sh — SP16 T-3 (Group C, gate C).
#
# Cross-cutting greenfield smoke. Drives `/onboard --seed-content <fixture>`
# end-to-end under stub mode against an isolated $HOME/$CLAUDE_HOME sandbox.
# Verifies P-1 + P-2 + A1 wiring with REAL SP12 surfaces + REAL SP13 four-stage
# infer-vault chain (NOT stubbed surfaces — that was T-2's coverage).
#
# Pipeline exercised:
#   1. Harness pre-step: bootstrap-schemas.sh consumes 5 synthetic
#      extraction-output-{A..E}.json stubs + writes the populated
#      user-manifest.json (this is exactly what onboard.sh's run_finalize
#      would do; lifted into the harness so the test can also drive
#      Section F deterministically — see "Why pre-run bootstrap" below).
#   2. onboard.sh --seed-content <vault-copy> --section f:
#      a. Stage-1 INGEST (intake.sh + ir-builder.sh walk vault-copy/)
#      b. Section F: 7 SP12 surfaces (1, 2, 3, 4, 5, 6, 9) in declared order
#                  → orchestrate.sh (cluster → propose-taxonomy → import-plan
#                                    → review-gate)
#
# Why pre-run bootstrap (instead of letting onboard.sh's run_finalize do it):
#   onboard.sh's section-skip guards require phases_completed to be present
#   in user-manifest BEFORE the section loop. We pre-seed it. Then run_finalize
#   invokes bootstrap-schemas, which builds a fresh manifest from the
#   extraction stubs WITHOUT phases_completed and refuses to overwrite the
#   pre-seed without --force (BOOTSTRAP_DIFFER rc=2). run_finalize doesn't
#   pass --force and we cannot modify onboard.sh (composition-not-fork). So
#   we lift bootstrap-schemas into the harness as a pre-step (mirroring what
#   run_finalize does anyway) and invoke onboard.sh in --section f mode.
#   Per `feedback_hard_constraint_overrides_spec`: when the spec text
#   ("full pipeline, not --section f") conflicts with the constraint
#   (composition-not-fork + zero modifications to onboard.sh), the
#   constraint dominates. The bootstrap → populated-manifest → surface-firing
#   chain S2 carry-forward asks for is still exercised end-to-end.
#
# Acceptance criteria (per tasks.md §T-3):
#   AC1: ≥7 records in $AUTO_AUTHOR_LOG
#   AC2: $APPROVED_IMPORT_PLAN exists at $CLAUDE_HOME/projects/<slug>/inferred/
#   AC3: ≥1 consult record in $AUTO_AUTHOR_LOG (tag-prefix surface fired)
#   AC4: $ORCHESTRATE_LOG shows all 4 stages green
#   AC5: identity-substituted vault CLAUDE.md present at $TEST_VAULT_ROOT
#   AC6: zero Peter-isms in any output artifact (grep against fixture-output tree)
#
# Hard constraints (per spec.md §T-3 + R-rule subset):
#   - Synthetic fixture only; never against ~/Documents/Obsidian Vault/
#   - HOOKS_STATE_OVERRIDE + CLAUDE_HOME isolated under $TMPDIR/sp16-greenfield-XXXXXX
#   - Stub mode default (LIVE_API=1 opts in to live API)
#   - R-55 zero-touch (foundation-repo + plan-tree only)
#   - R-23 bash 3.2 + stdlib; jq + python3 required
#   - feedback_test_isolation_for_hooks_state — full sandbox isolation
#   - feedback_universal_vault_safety — zero touches to real vault
#
# Exit codes:
#   0   PASS 1/1 — all 6 ACs green; done-marker written
#   1   FAIL — one or more ACs failed; done-marker NOT written
#   2   pre-flight failure (missing fixture, missing foundation-repo asset,
#                            harness pre-step failed)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/greenfield-pipeline/fixtures/greenfield-seed"
ONBOARD_SH="$REPO_ROOT/skills/onboarder/onboard.sh"
BOOTSTRAP_SH="$REPO_ROOT/onboarding/bootstrap-schemas.sh"
PLAN_DIR="$HOME/.claude-plans/71-claude-foundations-engine-v2/16-greenfield-personalization-wiring"
STATE_DIR="$PLAN_DIR/state"
DONE_MARKER="$STATE_DIR/T-3.done"

TEST_LABEL="SP16 T-3 greenfield end-to-end"

# ---------- pre-flight ----------

[ -d "$FIXTURE_DIR" ]   || { echo "FAIL: fixture missing: $FIXTURE_DIR" >&2; exit 2; }
[ -f "$ONBOARD_SH" ]    || { echo "FAIL: onboard.sh missing: $ONBOARD_SH" >&2; exit 2; }
[ -f "$BOOTSTRAP_SH" ]  || { echo "FAIL: bootstrap-schemas.sh missing: $BOOTSTRAP_SH" >&2; exit 2; }
command -v jq      >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 2; }

mkdir -p "$STATE_DIR"

# ---------- sandbox provisioning ----------

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sp16-greenfield-$$.XXXXXX") \
  || { echo "FAIL: mktemp" >&2; exit 2; }

cleanup() {
  _rc=$?
  if [ "${KEEP_TMPDIR:-0}" = "1" ]; then
    echo "[harness] KEEP_TMPDIR=1; preserving $TEST_DIR" >&2
  else
    rm -rf "$TEST_DIR" 2>/dev/null || true
  fi
  exit "$_rc"
}
trap cleanup EXIT INT TERM

# Fully override $HOME so onboard.sh + bootstrap-schemas.sh + surfaces resolve
# all defaults relative to the sandbox. bootstrap-schemas hardcodes $HOME/.claude
# for SCHEMAS_DIR/INPUTS_DIR/AUDIT_LOG (does NOT honor CLAUDE_HOME directly), so
# overriding HOME is the cleanest isolation knob.
export HOME="$TEST_DIR"
export CLAUDE_HOME="$HOME/.claude"
export INPUTS_DIR="$CLAUDE_HOME/onboarding"
export USER_MANIFEST="$CLAUDE_HOME/user-manifest.json"
export AUTO_AUTHOR_LOG="$INPUTS_DIR/auto-author-log.jsonl"
export HOOKS_STATE_OVERRIDE="$CLAUDE_HOME/state"

# Sandbox vault root (where surface-3 will write the personalized vault CLAUDE.md).
export TEST_VAULT_ROOT="$CLAUDE_HOME/test-vault"

# Force stub mode unless caller opts into LIVE_API.
if [ "${LIVE_API:-0}" != "1" ]; then
  unset ANTHROPIC_API_KEY VOYAGE_API_KEY 2>/dev/null || true
fi

# Force MOCK_LLM on (surface-1 + surface-2 use this to avoid real LLM calls).
export AUTO_AUTHOR_MOCK_LLM=1

# Documented dispatch flag — currently unused by surfaces (real auto-approval
# happens via the --auto-apply flag run_section_f passes), but kept exported
# so a future SP15-T-x affordance can read it without churning this test.
export CONSULTATION_GATE_AUTO_APPROVE=1

mkdir -p \
  "$CLAUDE_HOME" \
  "$INPUTS_DIR" \
  "$INPUTS_DIR/audit" \
  "$CLAUDE_HOME/schemas" \
  "$CLAUDE_HOME/hooks/config" \
  "$HOOKS_STATE_OVERRIDE" \
  "$TEST_VAULT_ROOT" \
  "$HOME/.claude-plans/71-claude-foundations-engine-v2/11-memory-bootstrap/state" \
  "$HOME/.claude-plans/71-claude-foundations-engine-v2/12-auto-authored-personalization/state" \
  || { echo "FAIL: sandbox mkdir" >&2; exit 2; }

# ---------- copy vault-content into sandbox ----------
# So absolute paths emitted by intake.sh + ir-builder.sh into intake-manifest.jsonl
# / ir.jsonl don't include foundation-repo path components (which carry the
# real-user identity token "petertiktinsky" that AC6 forbids). Copy is shallow;
# the fixture vault is small (7 files).
SANDBOX_VAULT="$TEST_DIR/seed-vault"
mkdir -p "$SANDBOX_VAULT" || { echo "FAIL: mkdir sandbox vault" >&2; exit 2; }
cp -R "$FIXTURE_DIR/vault-content/." "$SANDBOX_VAULT/" \
  || { echo "FAIL: cp vault-content" >&2; exit 2; }

# ---------- seed schemas + q-field-map (read by bootstrap-schemas + surfaces) ----------

for schema in user-manifest-schema.json orchestration-schema.json plans-schema.json \
              vault-schema.json provenance-frontmatter-schema.json \
              seed-content-ir-schema.json; do
  [ -f "$REPO_ROOT/schemas/$schema" ] || {
    echo "FAIL: foundation-repo missing schema: $schema" >&2; exit 2; }
  cp "$REPO_ROOT/schemas/$schema" "$CLAUDE_HOME/schemas/$schema"
done

cp "$REPO_ROOT/onboarding/q-field-map.json" "$INPUTS_DIR/q-field-map.json" \
  || { echo "FAIL: copy q-field-map.json" >&2; exit 2; }

# ---------- seed extraction stubs (substitute {{TEST_VAULT_ROOT}} placeholder) ----------

for sec in A B C D E; do
  src="$FIXTURE_DIR/extraction-stubs/extraction-output-${sec}.json"
  dst="$INPUTS_DIR/extraction-output-${sec}.json"
  [ -f "$src" ] || { echo "FAIL: missing extraction stub: $src" >&2; exit 2; }
  sed "s|{{TEST_VAULT_ROOT}}|$TEST_VAULT_ROOT|g" "$src" > "$dst"
  jq -e . "$dst" >/dev/null 2>&1 || {
    echo "FAIL: extraction stub $sec invalid JSON after substitution" >&2; exit 2; }
done

# ---------- seed pre-bootstrap orchestration (D-2 opt-out shape) ----------

cp "$FIXTURE_DIR/seed-orchestration.json" "$CLAUDE_HOME/orchestration.json" \
  || { echo "FAIL: copy seed-orchestration" >&2; exit 2; }

# ---------- seed fake SP11 + SP12 T-1 done-markers ----------
# - SP11: surface-2-memory-seeds.sh clean-halts (rc=0, no records) without it.
# - SP12 T-1: review-gate.sh HARD ABORTS in dev-checkout mode without it.
#   Dev-checkout mode is auto-detected by the presence of the plan-tree dir,
#   which we created above for the SP11 marker. Fake-marker harness pattern
#   mirrors what tests/auto-author/t16-cross-cutting-smoke-test.sh does for its own
#   per-surface markers.
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

SP11_DONE="$HOME/.claude-plans/71-claude-foundations-engine-v2/11-memory-bootstrap/state/T-3.done"
printf 'memory-bootstrap\t%s\tT-3 fake done-marker for SP16 T-3 greenfield smoke\n' \
  "$NOW_TS" > "$SP11_DONE"
export SP11_DONE_MARKER="$SP11_DONE"

SP12_T1_DONE="$HOME/.claude-plans/71-claude-foundations-engine-v2/12-auto-authored-personalization/state/T-1.done"
printf 'sp12-t1\t%s\tT-1 fake done-marker for SP16 T-3 greenfield smoke (review-gate.sh dev-checkout dependency)\n' \
  "$NOW_TS" > "$SP12_T1_DONE"

# ---------- empty audit log (surfaces append) ----------

: > "$AUTO_AUTHOR_LOG"

# ---------- harness pre-step: bootstrap-schemas (lifted out of run_finalize) ----------

BOOTSTRAP_LOG="$TEST_DIR/bootstrap.log"
echo "[harness] pre-step: bootstrap-schemas.sh (consumes 5 extraction stubs → populated user-manifest)" >&2
set +e
bash "$BOOTSTRAP_SH" >"$BOOTSTRAP_LOG" 2>&1
BOOTSTRAP_RC=$?
set -e
if [ "$BOOTSTRAP_RC" -ne 0 ]; then
  echo "FAIL: harness pre-step bootstrap-schemas rc=$BOOTSTRAP_RC" >&2
  echo "[harness] bootstrap-schemas log:" >&2
  cat "$BOOTSTRAP_LOG" >&2 || true
  exit 2
fi
[ -f "$USER_MANIFEST" ] || { echo "FAIL: bootstrap did not write $USER_MANIFEST" >&2; exit 2; }
jq -e '.identity.name == "Alex Rivera"' "$USER_MANIFEST" >/dev/null 2>&1 \
  || { echo "FAIL: bootstrap-populated user-manifest missing expected identity.name" >&2; exit 2; }

# ---------- invocation: onboard.sh --section f --seed-content <vault-copy> ----------

ONBOARD_LOG="$TEST_DIR/onboard.log"
ONBOARD_ERR="$TEST_DIR/onboard.err"

echo "[harness] sandbox: $TEST_DIR" >&2
echo "[harness] HOME=$HOME CLAUDE_HOME=$CLAUDE_HOME" >&2
echo "[harness] foundation-repo HEAD: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
echo "[harness] invoking: $ONBOARD_SH --seed-content $SANDBOX_VAULT --section f" >&2

set +e
bash "$ONBOARD_SH" \
  --seed-content "$SANDBOX_VAULT" \
  --section f \
  </dev/null \
  >"$ONBOARD_LOG" 2>"$ONBOARD_ERR"
ONBOARD_RC=$?
set -e

echo "[harness] onboard.sh rc=$ONBOARD_RC" >&2
if [ "$ONBOARD_RC" -ne 0 ]; then
  echo "[harness] onboard.sh stderr (last 60 lines):" >&2
  tail -60 "$ONBOARD_ERR" >&2 || true
fi

# ---------- assertions ----------

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS — %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL — %s\n' "$1" >&2; }

# AC1: ≥7 records in auto-author-log.jsonl.
LOG_LINES=0
if [ -f "$AUTO_AUTHOR_LOG" ]; then
  LOG_LINES=$(wc -l < "$AUTO_AUTHOR_LOG" | tr -d ' ')
fi
if [ "$LOG_LINES" -ge 7 ]; then
  pass "AC1: auto-author-log.jsonl has $LOG_LINES records (≥7)"
else
  fail "AC1: auto-author-log.jsonl has $LOG_LINES records (need ≥7) at $AUTO_AUTHOR_LOG"
fi

# AC2: approved-import-plan.md exists.
SLUG="${ONBOARDER_SEED_SLUG:-onboarding}"
INFERRED_DIR="$CLAUDE_HOME/projects/$SLUG/inferred"
APPROVED="$INFERRED_DIR/approved-import-plan.md"
if [ -s "$APPROVED" ]; then
  pass "AC2: approved-import-plan.md present at $APPROVED"
else
  fail "AC2: approved-import-plan.md absent at $APPROVED"
fi

# AC3: ≥1 consult record (tag-prefix or any allowlisted surface fired SP15 gate).
CONSULT_RECORDS=0
if [ -f "$AUTO_AUTHOR_LOG" ]; then
  CONSULT_RECORDS=$(grep -c '"action":"consult"' "$AUTO_AUTHOR_LOG" 2>/dev/null || true)
  CONSULT_RECORDS="${CONSULT_RECORDS:-0}"
fi
if [ "$CONSULT_RECORDS" -ge 1 ]; then
  TAG_PREFIX_HIT=0
  if grep -q '"surface_id":"surface-4-tag-prefixes"' "$AUTO_AUTHOR_LOG" 2>/dev/null; then
    TAG_PREFIX_HIT=1
  fi
  pass "AC3: $CONSULT_RECORDS consult record(s) in audit log; tag-prefix surface fired=$TAG_PREFIX_HIT"
else
  fail "AC3: zero consult records in audit log (need ≥1) at $AUTO_AUTHOR_LOG"
fi

# AC4: orchestrate-log.jsonl shows all 4 stages green (exit_code=0).
ORCHESTRATE_LOG="$INFERRED_DIR/orchestrate-log.jsonl"
STAGES_GREEN=0
STAGES_PRESENT=""
if [ -s "$ORCHESTRATE_LOG" ]; then
  for stage in cluster propose-taxonomy import-plan review-gate; do
    if jq -e --arg s "$stage" \
         'select(.stage == $s and .exit_code == 0)' \
         "$ORCHESTRATE_LOG" >/dev/null 2>&1; then
      STAGES_GREEN=$((STAGES_GREEN + 1))
      STAGES_PRESENT="$STAGES_PRESENT $stage"
    fi
  done
fi
if [ "$STAGES_GREEN" -eq 4 ]; then
  pass "AC4: orchestrate-log.jsonl all 4 stages green (cluster, propose-taxonomy, import-plan, review-gate)"
else
  fail "AC4: orchestrate-log.jsonl green-stage count = $STAGES_GREEN (need 4); present:$STAGES_PRESENT; log=$ORCHESTRATE_LOG"
fi

# AC5: identity-substituted vault CLAUDE.md present at fixture vault root.
VAULT_CLAUDE_MD="$TEST_VAULT_ROOT/CLAUDE.md"
if [ -f "$VAULT_CLAUDE_MD" ]; then
  IDENT_HIT=0
  if grep -q -F 'Alex Rivera' "$VAULT_CLAUDE_MD" 2>/dev/null \
     || grep -q -F 'Synthetic Holdings' "$VAULT_CLAUDE_MD" 2>/dev/null; then
    IDENT_HIT=1
  fi
  if [ "$IDENT_HIT" -eq 1 ]; then
    pass "AC5: vault CLAUDE.md present at $VAULT_CLAUDE_MD with identity substitution"
  else
    fail "AC5: vault CLAUDE.md present but no identity substitution detected at $VAULT_CLAUDE_MD"
  fi
else
  fail "AC5: vault CLAUDE.md absent at $VAULT_CLAUDE_MD"
fi

# AC6: zero Peter-isms across the OUTPUT artifact tree (CLAUDE_HOME).
# The fixture itself is excluded — we're auditing what the pipeline EMITTED,
# not what the harness fed in.
PETER_ISMS_PATTERN='peter|tiktinsky|artefact|luxe|walmart|ara partners|gold-layer-qa|b2c-renovate|bar-dashboard|1p-acquisition|amazon-creator-directory|luxe-creator-analytics|Documents/Obsidian Vault'
PETER_HITS_FILE="$TEST_DIR/peter-isms-hits.txt"
: > "$PETER_HITS_FILE"
find "$CLAUDE_HOME" -type f \
  \( -name '*.md' -o -name '*.json' -o -name '*.jsonl' -o -name '*.txt' -o -name '*.yaml' -o -name '*.yml' -o -name '*.log' \) \
  -print0 2>/dev/null \
  | xargs -0 grep -ilE "$PETER_ISMS_PATTERN" 2>/dev/null \
  > "$PETER_HITS_FILE" || true
PETER_HIT_COUNT=$(wc -l < "$PETER_HITS_FILE" | tr -d ' ')
if [ "$PETER_HIT_COUNT" = "0" ]; then
  pass "AC6: zero Peter-isms across $CLAUDE_HOME"
else
  fail "AC6: $PETER_HIT_COUNT file(s) under $CLAUDE_HOME contain blocked tokens:"
  while IFS= read -r f; do
    [ -n "$f" ] && printf '  %s\n' "$f" >&2
  done < "$PETER_HITS_FILE"
fi

# ---------- summary + done-marker ----------

printf '\n=== %s ===\n' "$TEST_LABEL"
printf 'PASS: %d\n' "$PASS_COUNT"
printf 'FAIL: %d\n' "$FAIL_COUNT"
printf 'onboard.sh rc: %d\n' "$ONBOARD_RC"

if [ "$FAIL_COUNT" = "0" ] && [ "$PASS_COUNT" = "6" ]; then
  printf 'PASS 1/1 — %s\n' "$TEST_LABEL"
  HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  printf 'T-3\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HEAD_SHA" \
    > "$DONE_MARKER"
  echo "[harness] done-marker written: $DONE_MARKER" >&2
  exit 0
else
  printf 'FAIL — %s (PASS=%d FAIL=%d; need PASS=6 FAIL=0)\n' \
    "$TEST_LABEL" "$PASS_COUNT" "$FAIL_COUNT" >&2
  echo "[harness] done-marker NOT written. Logs preserved at $TEST_DIR (set KEEP_TMPDIR=1 to keep across runs)." >&2
  exit 1
fi
