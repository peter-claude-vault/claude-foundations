#!/usr/bin/env bash
# onboarding/tests/seed-content/unclassified-pile-ux-test.sh — SP13 T-15 UX validation.
#
# Dedicated UX-validation test for the "review unclassified pile" gate per
# R1 §6 risk #3: the gate UX has to be GOOD not just CORRECT. Verifies:
#   (a) gate fires when unclassified items exist (variant A: ~10; variant
#       B: exactly 1) and renders user-facing copy with the three actions
#       (route-to-Inbox / merge-into-cluster / drop-with-rationale);
#   (b) copy reads grammatically for the n=1 single-item edge case (NOT
#       plural-only "1 items");
#   (c) gate skips silently when zero unclassified items exist (variant
#       C); pipeline proceeds to Stage 3 with no call-out rendered;
#   (d) stdout grep-audit clean — no leaked engagement names, no leaked
#       Peter references, no developer task-ID jargon, no clustering-
#       algorithm jargon in user-facing copy.
#
# Per feedback_test_isolation_for_hooks_state + feedback_universal_vault_safety:
#   - $TMPDIR/sp13-t15-XXXXXX as $CLAUDE_HOME (hermetic; never live ~/.claude/)
#   - parallel test "vault" tmpdir (never ~/Documents/Obsidian Vault/)
#   - HOOKS_STATE_OVERRIDE redirected to tmpdir
#   - ANTHROPIC_API_KEY + VOYAGE_API_KEY unset (forces stub modes; no API)
#   - PLAN_71_GATE_BYPASS unset; PLAN_ID unset
#
# Acceptance gates (paired to T-15 ACs in tasks.md L497-503):
#   AC1 — Variant A (10 unclassifiable): callout fires; user-facing copy
#         explains what unclassified means; route-to-Inbox / merge-into-
#         cluster / drop-with-rationale actions all enumerated.
#   AC2 — Variant B (single unclassifiable): callout fires; copy reads
#         naturally for n=1 (NOT "1 items").
#   AC3 — Variant C (zero unclassifiable): callout does NOT fire (silent
#         skip); pipeline output exists and is consumable by Stage 3.
#   AC4 — Stdout grep-audit clean: no leaked Peter/Tiktinsky/Artefact/
#         engagement-name references; no developer task-ID jargon
#         (T-1..T-15) in user-facing copy; no raw clustering-algorithm
#         jargon (HDBSCAN/embedding-vector/centroid) in user-facing copy.
#   AC5 — Peter feedback file written by caller (state/T-15-peter-feedback.md
#         or N/A marker); this test contributes the evidence stream the
#         caller copies in.
#   AC6 — Done-marker state/T-15.done written by caller on full green.
#
# AC5 + AC6 are caller-side post-conditions. This script emits the per-
# variant rendered import-plan.md + per-probe results.log + grep-audit
# output that the evidence document references; on full green the caller
# writes both files.
#
# Bash 3.2 compatible (R-23). jq + python3 REQUIRED.
#
# Author: Claude Opus 4.7 — Plan 71 SP13 Session 14 (T-15).

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"

# ----- Component paths ------------------------------------------------------

INTAKE_SH="$REPO_ROOT/onboarding/seed-content/intake.sh"
IR_BUILDER_SH="$REPO_ROOT/onboarding/seed-content/ir-builder.sh"
CLUSTER_SH="$REPO_ROOT/skills/infer-vault-structure/cluster.sh"
PROPOSE_SH="$REPO_ROOT/skills/infer-vault-structure/propose-taxonomy.sh"
IMPORT_PLAN_SH="$REPO_ROOT/skills/infer-vault-structure/import-plan.sh"
FIXTURE_PY="$REPO_ROOT/tests/fixtures/sp13-unclassified/corpus.py"

# ----- Hermetic isolation ---------------------------------------------------

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/sp13-t15-XXXXXX")"
KEEP_TMP="${SP13_T15_KEEP_TMP:-}"
if [ -z "$KEEP_TMP" ]; then
  trap 'rm -rf "$TMPROOT"' EXIT INT TERM
else
  trap 'echo "TMPROOT preserved: $TMPROOT" >&2' EXIT INT TERM
fi

unset ANTHROPIC_API_KEY VOYAGE_API_KEY EDITOR PLAN_71_GATE_BYPASS PLAN_ID
export CLAUDE_HOME="$TMPROOT/claude"
export CLAUDE_LOG_DIR="$TMPROOT/claude/logs"
export HOOKS_STATE_OVERRIDE="$TMPROOT/claude/hooks/state"
mkdir -p "$CLAUDE_HOME/hooks/state" "$CLAUDE_HOME/logs" "$CLAUDE_HOME/hooks/lib"

PASS=0
FAIL=0
RESULTS_LOG="$TMPROOT/results.log"
: > "$RESULTS_LOG"

_log()  { printf '%s\n' "$1" | tee -a "$RESULTS_LOG"; }
_pass() { PASS=$((PASS + 1)); _log "PASS $1"; }
_fail() { FAIL=$((FAIL + 1)); _log "FAIL $1"; }

_assert_file_exists() {
  if [ -f "$2" ]; then _pass "$1 — exists: $2"
  else _fail "$1 — missing: $2"; fi
}
_assert_grep() {
  if grep -qE -- "$2" "$3" 2>/dev/null; then _pass "$1 — match: $2"
  else _fail "$1 — miss: $2 (file: $3)"; fi
}
_assert_no_grep() {
  if grep -qE -- "$2" "$3" 2>/dev/null; then _fail "$1 — leaked: $2 (file: $3)"
  else _pass "$1 — clean: $2"; fi
}
_assert_eq() {
  if [ "$2" = "$3" ]; then _pass "$1 — eq: '$2'"
  else _fail "$1 — expected '$2' got '$3'"; fi
}
_assert_ge() {
  if [ "$2" -ge "$3" ] 2>/dev/null; then _pass "$1 — '$2' >= '$3'"
  else _fail "$1 — got '$2' need >= '$3'"; fi
}

# ----- Pre-flight -----------------------------------------------------------

_log "--- Pre-flight: required components present ---"
for f in "$INTAKE_SH" "$IR_BUILDER_SH" "$CLUSTER_SH" "$PROPOSE_SH" \
         "$IMPORT_PLAN_SH" "$FIXTURE_PY"; do
  _assert_file_exists "preflight: $(basename "$f")" "$f"
done

# ----- Per-variant pipeline driver ------------------------------------------

# _run_pipeline <variant> <CORPUS_DIR> <WORK_DIR>
# Writes import-plan.md + propose.json under WORK_DIR. Stub mode only.
_run_pipeline() {
  local v="$1" corpus="$2" work="$3"
  local rc

  python3 "$FIXTURE_PY" --variant "$v" --out-dir "$corpus" \
    >"$work/fixture.out" 2>"$work/fixture.err"
  rc=$?
  if [ $rc -ne 0 ]; then
    _fail "pipeline:$v fixture builder rc=$rc"
    head -20 "$work/fixture.err" | tee -a "$RESULTS_LOG" >/dev/null
    return 1
  fi

  bash "$INTAKE_SH" --source "$corpus" --manifest "$work/intake.jsonl" \
    >"$work/intake.out" 2>"$work/intake.err"
  rc=$?
  if [ $rc -ne 0 ]; then
    _fail "pipeline:$v intake rc=$rc"
    head -20 "$work/intake.err" | tee -a "$RESULTS_LOG" >/dev/null
    return 1
  fi

  bash "$IR_BUILDER_SH" --manifest "$work/intake.jsonl" \
    --ir "$work/ir.jsonl" --batch-cap 100 \
    >"$work/ir.out" 2>"$work/ir.err"
  rc=$?
  if [ $rc -ne 0 ]; then
    _fail "pipeline:$v ir-builder rc=$rc"
    head -30 "$work/ir.err" | tee -a "$RESULTS_LOG" >/dev/null
    return 1
  fi

  bash "$CLUSTER_SH" --ir "$work/ir.jsonl" --out "$work/cluster.json" \
    --embedding-mode stub \
    >"$work/cluster.out" 2>"$work/cluster.err"
  rc=$?
  if [ $rc -ne 0 ]; then
    _fail "pipeline:$v cluster rc=$rc"
    head -30 "$work/cluster.err" | tee -a "$RESULTS_LOG" >/dev/null
    return 1
  fi

  bash "$PROPOSE_SH" --cluster-output "$work/cluster.json" \
    --ir "$work/ir.jsonl" --out "$work/propose.json" --llm-mode stub \
    >"$work/propose.out" 2>"$work/propose.err"
  rc=$?
  if [ $rc -ne 0 ]; then
    _fail "pipeline:$v propose-taxonomy rc=$rc"
    head -30 "$work/propose.err" | tee -a "$RESULTS_LOG" >/dev/null
    return 1
  fi

  bash "$IMPORT_PLAN_SH" --propose-taxonomy "$work/propose.json" \
    --out "$work/import-plan.md" \
    >"$work/import.out" 2>"$work/import.err"
  rc=$?
  if [ $rc -ne 0 ]; then
    _fail "pipeline:$v import-plan rc=$rc"
    head -30 "$work/import.err" | tee -a "$RESULTS_LOG" >/dev/null
    return 1
  fi

  return 0
}

# ----- Variant A — high unclassified (gate fires; 3 actions present) --------

_log "--- AC1: Variant A — gate fires + actions enumerated ---"
CORPUS_A="$TMPROOT/corpus-a"
WORK_A="$TMPROOT/work-a"
mkdir -p "$CORPUS_A" "$WORK_A"

if _run_pipeline a "$CORPUS_A" "$WORK_A"; then
  _pass "AC1.0 variant-a pipeline ran cleanly"
else
  _fail "AC1.0 variant-a pipeline failed; downstream ACs skipped"
fi

PLAN_A="$WORK_A/import-plan.md"
_assert_file_exists "AC1.1 variant-a import-plan.md exists" "$PLAN_A"

# Confirm the prominent top call-out is rendered.
_assert_grep "AC1.2 variant-a call-out rendered (prominent top anchor)" \
  '^> ⚠️ \*\*Review the unclassified pile' "$PLAN_A"

# Confirm the body explains what 'unclassified' means in user-facing terms.
_assert_grep "AC1.3 variant-a copy explains items did not fit any cluster" \
  'did not fit any cluster' "$PLAN_A"
_assert_grep "AC1.4 variant-a copy promises no item silently dropped" \
  'no item is silently dropped' "$PLAN_A"
_assert_grep "AC1.5 variant-a copy invites scroll-to-triage" \
  '[Ss]croll to' "$PLAN_A"

# AC1: three documented actions enumerated.
# Spec L498: route-to-Inbox / merge-into-cluster / drop-with-rationale.
# Code-rendered copy: "route it to Inbox/" / "merge it into an existing
# candidate by editing its candidate_id" / "remove it from the plan entirely".
_assert_grep "AC1.6 action: route-to-Inbox enumerated" \
  '[Rr]oute it to .?Inbox' "$PLAN_A"
_assert_grep "AC1.7 action: merge-into-cluster enumerated" \
  '[Mm]erge it into an existing candidate' "$PLAN_A"
_assert_grep "AC1.8 action: drop-from-plan enumerated" \
  '[Rr]emove it from the plan' "$PLAN_A"

# Confirm propose-taxonomy actually carried 10 unclassified items through.
n_unc_a=$(jq '[.candidates[] | select(.candidate_id=="unclassified") | .source_items[]] | length' \
  "$WORK_A/propose.json" 2>/dev/null || echo 0)
_assert_eq "AC1.9 variant-a unclassified count = 10" "10" "$n_unc_a"

# Confirm n_projects ≥ 2 so we have a real gate to surface against (not
# a degenerate empty-vault case).
n_proj_a=$(jq '[.candidates[] | select(.type=="project")] | length' \
  "$WORK_A/propose.json" 2>/dev/null || echo 0)
_assert_ge "AC1.10 variant-a project candidates >= 2" "$n_proj_a" "2"

# ----- Variant B — single unclassified (gate fires; n=1 reads naturally) ----

_log "--- AC2: Variant B — single-item case reads grammatically ---"
CORPUS_B="$TMPROOT/corpus-b"
WORK_B="$TMPROOT/work-b"
mkdir -p "$CORPUS_B" "$WORK_B"

if _run_pipeline b "$CORPUS_B" "$WORK_B"; then
  _pass "AC2.0 variant-b pipeline ran cleanly"
else
  _fail "AC2.0 variant-b pipeline failed; downstream ACs skipped"
fi

PLAN_B="$WORK_B/import-plan.md"
_assert_file_exists "AC2.1 variant-b import-plan.md exists" "$PLAN_B"
_assert_grep "AC2.2 variant-b call-out fires for n=1" \
  '^> ⚠️ \*\*Review the unclassified pile' "$PLAN_B"

# Critical AC2 probe: NOT "1 items" (broken plural-only).
_assert_no_grep "AC2.3 variant-b copy is NOT plural-only ('1 items')" \
  '\b1 items\b' "$PLAN_B"

# Positive form: the n=1 copy must read as "1 item" (singular).
_assert_grep "AC2.4 variant-b copy reads naturally ('1 item')" \
  '\b1 item\b' "$PLAN_B"

# Confirm propose-taxonomy actually carried exactly 1 unclassified item.
n_unc_b=$(jq '[.candidates[] | select(.candidate_id=="unclassified") | .source_items[]] | length' \
  "$WORK_B/propose.json" 2>/dev/null || echo 0)
_assert_eq "AC2.5 variant-b unclassified count = 1" "1" "$n_unc_b"

# ----- Variant C — zero unclassified (gate skips silently) ------------------

_log "--- AC3: Variant C — silent skip when unclassified count = 0 ---"
CORPUS_C="$TMPROOT/corpus-c"
WORK_C="$TMPROOT/work-c"
mkdir -p "$CORPUS_C" "$WORK_C"

if _run_pipeline c "$CORPUS_C" "$WORK_C"; then
  _pass "AC3.0 variant-c pipeline ran cleanly"
else
  _fail "AC3.0 variant-c pipeline failed; downstream ACs skipped"
fi

PLAN_C="$WORK_C/import-plan.md"
_assert_file_exists "AC3.1 variant-c import-plan.md exists" "$PLAN_C"

# AC3 critical: NO call-out anchor anywhere when unclassified count = 0.
_assert_no_grep "AC3.2 variant-c call-out does NOT fire (silent skip)" \
  '> ⚠️ \*\*Review the unclassified pile' "$PLAN_C"

# AC3 critical: rendered intro must NOT include the "scroll to triage"
# carve-out either (rendered only when unclassified_present=True).
_assert_no_grep "AC3.3 variant-c intro skips 'flags items that did not cluster'" \
  'flags items that did not cluster' "$PLAN_C"

# But the plan still renders a usable structure for Stage 3 consumption.
_assert_grep "AC3.4 variant-c plan still renders project candidates section" \
  '## Project candidates' "$PLAN_C"
_assert_grep "AC3.5 variant-c plan still renders proposed vault tree" \
  'roposed vault tree' "$PLAN_C"
_assert_grep "AC3.6 variant-c plan still renders schema_version anchor" \
  '^schema_version: import-plan/1$' "$PLAN_C"

# Confirm 0 unclassified items in propose-taxonomy.
n_unc_c=$(jq '[.candidates[] | select(.candidate_id=="unclassified") | .source_items[]] | length' \
  "$WORK_C/propose.json" 2>/dev/null || echo 0)
_assert_eq "AC3.7 variant-c unclassified count = 0" "0" "$n_unc_c"

# ----- AC4 — Grep-audit denylist scan across all 3 variants -----------------

# Surfaces audited: only the user-facing portions of the rendered import-
# plan.md. Excluded: routing-table column with absolute fixture paths
# (those are not user-facing copy — they are runtime IR-record source
# paths). Approach: extract user-facing copy slices and audit those.

_log "--- AC4: Grep-audit denylist (user-facing copy only) ---"

# Extract user-facing copy slices: top callout + render_intro + corpus stats
# + render_non_project_section. Exclude the routing-table rows (abs paths).
# The `awk` filter keeps lines from line 1 through "Per-source-item routing"
# heading (exclusive) and from "Doesn't fit any project" through end.
_extract_user_copy() {
  local src="$1"
  awk '
    /^## Per-source-item routing/ { skip=1 }
    /^## Doesn.t fit any project/ { skip=0 }
    skip != 1 { print }
  ' "$src"
}

for V in a b c; do
  case "$V" in
    a) PLAN="$PLAN_A" ;;
    b) PLAN="$PLAN_B" ;;
    c) PLAN="$PLAN_C" ;;
  esac
  COPY="$TMPROOT/user-copy-$V.txt"
  _extract_user_copy "$PLAN" >"$COPY"
  _assert_file_exists "AC4.0.$V user-facing-copy slice extracted" "$COPY"

  # Personal/engagement leaks — must never appear in adopter-facing copy.
  for term in 'Peter' 'Tiktinsky' 'Artefact' "L'Oreal" "L'Oréal" 'CDMO' 'Walmart' 'DDX'; do
    _assert_no_grep "AC4.1.$V no personal leak: $term" "$term" "$COPY"
  done

  # Developer task-ID jargon: T-N where N is a digit. SP13 has T-1..T-15.
  # Adopters do not know what T-7 / T-8 / T-12 mean.
  _assert_no_grep "AC4.2.$V no SP13 task-ID leak (T-N)" \
    '\bT-[0-9]+\b' "$COPY"

  # Clustering-algorithm jargon — these are correct algorithm terms but
  # belong in code comments, not user-facing copy.
  for term in 'HDBSCAN' 'TF-IDF' 'centroid_topic_keywords' 'embedding vector'; do
    _assert_no_grep "AC4.3.$V no algorithm jargon: $term" "$term" "$COPY"
  done
done

# ----- Final summary --------------------------------------------------------

_log ""
_log "================================================================="
_log "SP13 T-15 UX validation results"
_log "  Pass: $PASS"
_log "  Fail: $FAIL"
_log "  TMPROOT: $TMPROOT"
_log "================================================================="

if [ "$FAIL" -gt 0 ]; then
  _log "FAIL — see results.log + per-variant import-plan.md under TMPROOT"
  exit 1
fi
_log "PASS — all probes green"
exit 0
