#!/usr/bin/env bash
# sp13-explainer-fragments-test.sh — SP13 T-9 unit + integration tests
#
# Covers tag/frontmatter inline explainer at the gate_preview surface:
#
#   AC1   skills/seed-projects/explainer-fragments.sh exists; bash -n clean;
#         sourceable
#   AC2   emit_tag_explainer dispatches per prefix bucket:
#         #project / #engagement/* / #scope/* / #research / #internal /
#         #meeting / #reference / #unclassified all produce non-empty
#         explainer text; unknown tag falls through to generic citation
#         fallback
#   AC3   emit_field_explainer dispatches per known field:
#         type, status, audience, tags, generated_by, generated_from,
#         last_user_edit, title, created all produce non-empty text;
#         unknown field silent-skip (no output, exit 0)
#   AC4   emit_full_block (no stage_root) emits the full union of all known
#         tags + fields, brackets the section with header/footer markers,
#         every line cites docs/personalization-model.md or is structural
#   AC5   emit_full_block (with stage_root) scans staged files for tags +
#         fields actually present and emits explainers ONLY for what's in
#         the tree (anchored to actual generated content per spec L291)
#   AC6   integration: seed.sh end-to-end run with --accept-on-eof emits
#         the explainer block at PREVIEW surface BEFORE the per-file diff
#         bundle (the line "=== Why these tags + frontmatter? ===" appears
#         before the first "--- [1/" diff header on stderr)
#   AC7   integration: explainer block cites docs/personalization-model.md
#         by literal path on stderr
#   AC8   integration: explainer block does NOT contain the literal phrases
#         "universal capability" / "combined capability" /
#         "personal capability" (no rewrite of the SP12 T-11 framing)
#   AC9   integration: per-tag explainers present for #project +
#         #engagement/* + #scope/* on stderr (one entry per prefix bucket
#         even with many concrete tags)
#   AC10  integration: per-frontmatter-field explainers present for type +
#         tags + generated_by + generated_from + last_user_edit on stderr
#   AC11  pre-flight: missing SP12 T-11 done-marker (synthetic plan-tree
#         path with T-2.done but no T-11.done) → seed.sh hard-aborts rc=2
#         with structured stderr; no audit record written
#   AC12  hermetic isolation: AUTO_AUTHOR_LOG + TG_STAGE_DIR forced into
#         tmpdir; all writes contained under $TMPDIR/sp13-t9-test-*;
#         default state/ + foundation-repo auto-author-log.jsonl untouched
#   AC13  regression: T-8's existing 69-AC suite still passes after T-9
#         hook lands (no breakage from the print_batched_preview edit)
#
# Hermetic: $TMPDIR/sp13-t9-test-XXXXXX. No live writes.
# Bash 3.2 compatible (R-23).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SKILL_DIR="$REPO_ROOT/skills/seed-projects"
SEED_SH="$SKILL_DIR/seed.sh"
EXPLAINER_LIB="$SKILL_DIR/explainer-fragments.sh"
TEMPLATES_DIR="$REPO_ROOT/templates"
PF_LIB="$REPO_ROOT/lib/provenance-frontmatter.sh"
GATE_LIB="$REPO_ROOT/onboarding/lib/three-step-gate.sh"
IMPORT_SH="$REPO_ROOT/skills/infer-vault-structure/import-plan.sh"
T8_TEST="$SCRIPT_DIR/sp13-seed-projects-test.sh"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/sp13-t9-test-XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

# Hermetic isolation per feedback_test_isolation_for_hooks_state.
unset ANTHROPIC_API_KEY
unset VOYAGE_API_KEY
export AUTO_AUTHOR_LOG="$TMPROOT/auto-author-log.jsonl"
export TG_STAGE_DIR="$TMPROOT/tg-stage"
mkdir -p "$TG_STAGE_DIR"

pass=0
fail=0
record_pass() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
record_fail() {
  fail=$((fail + 1))
  printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"
}
assert_eq()  { if [ "$2" = "$3" ];  then record_pass "$1"; else record_fail "$1" "$2" "$3"; fi; }
assert_ne()  { if [ "$2" != "$3" ]; then record_pass "$1"; else record_fail "$1" "$2" "$3"; fi; }
assert_grep() {
  if grep -qE "$2" "$3" 2>/dev/null; then record_pass "$1"
  else record_fail "$1" "match: $2" "no match in $3"; fi
}
assert_not_grep() {
  if ! grep -qE "$2" "$3" 2>/dev/null; then record_pass "$1"
  else record_fail "$1" "no match: $2" "found match in $3"; fi
}
assert_grep_string() {
  # $1=name $2=pattern $3=string
  if printf '%s' "$3" | grep -qE "$2" 2>/dev/null; then record_pass "$1"
  else record_fail "$1" "match: $2" "no match"; fi
}
assert_nonempty_string() {
  if [ -n "$2" ]; then record_pass "$1"; else record_fail "$1" "non-empty" "empty"; fi
}

# ---------- AC1 — lib exists, syntax clean, sourceable ----------
echo "AC1 — lib presence + syntax + sourceable"
if [ -f "$EXPLAINER_LIB" ] && bash -n "$EXPLAINER_LIB" 2>/dev/null; then
  record_pass "explainer-fragments.sh exists + bash -n clean"
else
  record_fail "explainer-fragments.sh" "exists+clean" "missing-or-syntax"
fi
( . "$EXPLAINER_LIB" ) 2>/dev/null
if [ $? -eq 0 ]; then record_pass "explainer-fragments.sh sources cleanly"
else record_fail "source explainer-fragments.sh" "rc=0" "rc=non-zero"; fi

# Source the lib once for direct API tests below.
. "$EXPLAINER_LIB"

# ---------- AC2 — emit_tag_explainer dispatches per prefix ----------
echo "AC2 — emit_tag_explainer dispatch"
for tg in "#project" "#project/alpha" "#engagement/alpha" "#scope/team" \
          "#research" "#internal" "#meeting" "#reference" "#unclassified"; do
  out=$(emit_tag_explainer "$tg")
  assert_nonempty_string "emit_tag_explainer '$tg' produces text" "$out"
  # Every explainer must cite the model doc.
  assert_grep_string "emit_tag_explainer '$tg' cites model doc" \
    'docs/personalization-model.md' "$out"
  # Every explainer must mention the tag itself (anchored to input).
  if printf '%s' "$out" | grep -qF "$tg"; then
    record_pass "emit_tag_explainer '$tg' echoes tag literal"
  else
    record_fail "emit_tag_explainer '$tg' echoes tag literal" "contains $tg" "missing"
  fi
done
# Unknown tag → generic fallback (still cites model doc, still non-empty)
unknown_out=$(emit_tag_explainer "#zzz-novel")
assert_nonempty_string "emit_tag_explainer '#zzz-novel' fallback non-empty" "$unknown_out"
assert_grep_string "emit_tag_explainer '#zzz-novel' cites model doc" \
  'docs/personalization-model.md' "$unknown_out"

# ---------- AC3 — emit_field_explainer dispatches per known field ----------
echo "AC3 — emit_field_explainer dispatch"
for fld in type status audience tags generated_by generated_from \
           last_user_edit title created; do
  out=$(emit_field_explainer "$fld")
  assert_nonempty_string "emit_field_explainer '$fld' produces text" "$out"
  if printf '%s' "$out" | grep -qF "$fld"; then
    record_pass "emit_field_explainer '$fld' echoes field literal"
  else
    record_fail "emit_field_explainer '$fld' echoes field literal" "contains $fld" "missing"
  fi
done
# Unknown field → silent skip (no output, rc=0)
unknown_field_out=$(emit_field_explainer "wibblewobble" 2>&1)
unknown_field_rc=$?
assert_eq "emit_field_explainer unknown field rc=0" "0" "$unknown_field_rc"
assert_eq "emit_field_explainer unknown field empty" "" "$unknown_field_out"

# ---------- AC4 — emit_full_block (no stage_root) full union ----------
echo "AC4 — emit_full_block fallback (no stage_root)"
full_out_file="$TMPROOT/full-block-fallback.txt"
emit_full_block > "$full_out_file"
assert_grep "emit_full_block opens with section header" \
  '=== Why these tags \+ frontmatter\? ===' "$full_out_file"
assert_grep "emit_full_block closes with end marker" \
  '=== end explainer ===' "$full_out_file"
assert_grep "emit_full_block cites model doc by literal path" \
  'docs/personalization-model.md' "$full_out_file"
assert_grep "emit_full_block has Tags subheader" "^### Tags$" "$full_out_file"
assert_grep "emit_full_block has Frontmatter fields subheader" \
  "^### Frontmatter fields$" "$full_out_file"
# Ensures we don't rewrite the SP12 T-11 framing.
assert_not_grep "emit_full_block omits 'universal capability' literal" \
  "universal capability" "$full_out_file"
assert_not_grep "emit_full_block omits 'combined capability' literal" \
  "combined capability" "$full_out_file"
assert_not_grep "emit_full_block omits 'personal capability' literal" \
  "personal capability" "$full_out_file"

# ---------- AC5 — emit_full_block (with stage_root) anchored ----------
echo "AC5 — emit_full_block anchored to stage_root"
mini_stage="$TMPROOT/mini-stage"
mkdir -p "$mini_stage"
# Synthetic staged file with a constrained set of tags + fields.
cat > "$mini_stage/PRD.md" <<'EOF'
---
generated_by: seed-projects@v2.0.0
generated_from: p0001/alpha
last_user_edit: null
title: alpha
type: prd
status: active
audience: self
tags:
  - "#project/alpha"
  - "#engagement/alpha"
---
# alpha
body
EOF
anchored_out_file="$TMPROOT/full-block-anchored.txt"
emit_full_block "$mini_stage" > "$anchored_out_file"
# Should include #project + #engagement (present in stage)
assert_grep "anchored block has #project tag explainer" \
  '`#project' "$anchored_out_file"
assert_grep "anchored block has #engagement/alpha tag explainer" \
  '`#engagement/alpha`' "$anchored_out_file"
# Should include type, generated_by, last_user_edit (present in stage)
assert_grep "anchored block has type field explainer" \
  '`type`' "$anchored_out_file"
assert_grep "anchored block has generated_by explainer" \
  '`generated_by`' "$anchored_out_file"
assert_grep "anchored block has last_user_edit explainer" \
  '`last_user_edit`' "$anchored_out_file"
# Should NOT include #scope (absent from stage) — anchored coverage
assert_not_grep "anchored block omits #scope explainer (absent in stage)" \
  '`#scope/' "$anchored_out_file"
# Should NOT include #research (absent from stage)
assert_not_grep "anchored block omits #research explainer (absent in stage)" \
  '`#research`' "$anchored_out_file"

# ---------- shared fixture for AC6-AC10 + AC11 ----------
# Hand-crafted propose-taxonomy fixture with diverse tags including #scope/*.
FIXTURE_PROPOSE="$TMPROOT/propose-taxonomy.json"
cat > "$FIXTURE_PROPOSE" <<'JSON'
{
  "schema_version": "sp13-t5/1",
  "llm_mode": "stub",
  "embedding_mode_input": "stub",
  "n_records": 6,
  "n_clusters_input": 2,
  "passes": [
    {"pass": 1, "model": "stub-pass1", "n_candidates_proposed": 2, "n_items_mapped": 6, "duration_ms": 100},
    {"pass": 2, "model": "stub-pass2", "n_candidates_proposed": 2, "n_items_mapped": 6, "duration_ms": 100, "merge_split_ops": []}
  ],
  "n_passes": 2,
  "items_mapped_pct": 1.0,
  "candidates": [
    {
      "candidate_id": "p0001",
      "label": "alpha",
      "type": "project",
      "proposed_path": "Engagements/alpha",
      "metadata": {
        "summary": "Alpha engagement: platform readiness review.",
        "tags": ["#project/alpha", "#engagement/alpha", "#scope/platform"],
        "engagement": "alpha",
        "rationale": "Items grouped under alpha share platform-readiness language."
      },
      "source_items": [
        {"path": "/seed/alpha/kickoff.md",  "source_hash": "a1a1a1a1a1a1a1a1"},
        {"path": "/seed/alpha/scope-doc.md","source_hash": "a3a3a3a3a3a3a3a3"}
      ],
      "confidence": 1.0,
      "low_confidence": false
    },
    {
      "candidate_id": "p0002",
      "label": "beta",
      "type": "project",
      "proposed_path": "Engagements/beta",
      "metadata": {
        "summary": "Beta engagement: customer-facing AI assistant rollout.",
        "tags": ["#project/beta", "#engagement/beta", "#scope/customer", "#research"],
        "engagement": "beta",
        "rationale": "Items grouped under beta share customer-facing-rollout language."
      },
      "source_items": [
        {"path": "/seed/beta/notes.md", "source_hash": "b1b1b1b1b1b1b1b1"},
        {"path": "/seed/beta/specs.md", "source_hash": "b2b2b2b2b2b2b2b2"},
        {"path": "/seed/beta/plan.md",  "source_hash": "b3b3b3b3b3b3b3b3"},
        {"path": "/seed/beta/qa.md",    "source_hash": "b4b4b4b4b4b4b4b4"}
      ],
      "confidence": 1.0,
      "low_confidence": false
    }
  ],
  "non_project_candidates": []
}
JSON

# Render through real T-6 import-plan.sh to produce a sp13-t6/1 plan.
APPROVED_PLAN="$TMPROOT/approved-import-plan.md"
if ! "$IMPORT_SH" \
  --propose-taxonomy "$FIXTURE_PROPOSE" \
  --out "$APPROVED_PLAN" \
  --generated-at "2026-05-04T16:00:00Z" >"$TMPROOT/import.stdout" 2>"$TMPROOT/import.stderr"; then
  echo "FATAL: import-plan.sh failed; cannot run integration ACs"
  cat "$TMPROOT/import.stderr"
  exit 1
fi

# Synthetic plan-tree with BOTH SP12 T-2 and T-11 done-markers (happy path).
SYNTH_PLAN_TREE="$TMPROOT/synth-plan-tree"
mkdir -p "$SYNTH_PLAN_TREE/12-auto-authored-personalization/state"
echo "T-2 ok"  > "$SYNTH_PLAN_TREE/12-auto-authored-personalization/state/T-2.done"
echo "T-11 ok" > "$SYNTH_PLAN_TREE/12-auto-authored-personalization/state/T-11.done"

VAULT_ROOT="$TMPROOT/vault"
mkdir -p "$VAULT_ROOT"

# Drive seed.sh with PROMPT_CHOICE=s so we capture preview output without
# applying writes (no vault writes; deterministic skip path).
PREVIEW_STDERR="$TMPROOT/preview.stderr"
SEED_PROJECTS_PROMPT_CHOICE="s" \
  "$SEED_SH" \
    --vault-root "$VAULT_ROOT" \
    --approved-plan "$APPROVED_PLAN" \
    --templates-dir "$TEMPLATES_DIR" \
    --pf-lib "$PF_LIB" \
    --gate-lib "$GATE_LIB" \
    --explainer-lib "$EXPLAINER_LIB" \
    --plan-tree "$SYNTH_PLAN_TREE" \
    --audience self \
  >/dev/null 2>"$PREVIEW_STDERR"
seed_rc=$?
assert_eq "seed.sh skip path rc=0" "0" "$seed_rc"

# ---------- AC6 — explainer fires BEFORE per-file diff bundle ----------
echo "AC6 — explainer block precedes diff bundle"
explainer_line=$(grep -nE '=== Why these tags \+ frontmatter\? ===' "$PREVIEW_STDERR" | head -1 | cut -d: -f1)
first_diff_line=$(grep -nE '^--- \[1/' "$PREVIEW_STDERR" | head -1 | cut -d: -f1)
if [ -n "$explainer_line" ] && [ -n "$first_diff_line" ] && [ "$explainer_line" -lt "$first_diff_line" ]; then
  record_pass "explainer block (line $explainer_line) precedes first diff header (line $first_diff_line)"
else
  record_fail "explainer-before-diff ordering" \
    "explainer < first-diff line numbers" \
    "explainer=$explainer_line first-diff=$first_diff_line"
fi

# ---------- AC7 — explainer cites docs/personalization-model.md ----------
echo "AC7 — explainer cites docs/personalization-model.md on stderr"
assert_grep "preview stderr cites docs/personalization-model.md" \
  'docs/personalization-model.md' "$PREVIEW_STDERR"

# ---------- AC8 — explainer does NOT rewrite SP12 framing ----------
echo "AC8 — explainer omits 'X capability' literals"
# Carve out the explainer block (between header and end marker) and probe it.
EXPLAINER_BLOCK="$TMPROOT/explainer-block.txt"
awk '
  /=== Why these tags \+ frontmatter\? ===/ { in_block=1 }
  in_block { print }
  /=== end explainer ===/ { in_block=0 }
' "$PREVIEW_STDERR" > "$EXPLAINER_BLOCK"
assert_not_grep "explainer block omits 'universal capability'" \
  "universal capability" "$EXPLAINER_BLOCK"
assert_not_grep "explainer block omits 'combined capability'" \
  "combined capability" "$EXPLAINER_BLOCK"
assert_not_grep "explainer block omits 'personal capability'" \
  "personal capability" "$EXPLAINER_BLOCK"

# ---------- AC9 — per-tag explainers for #project + #engagement/* + #scope/* ----------
echo "AC9 — per-tag prefix coverage on stderr"
assert_grep "explainer covers #project prefix" \
  '`#project' "$EXPLAINER_BLOCK"
assert_grep "explainer covers #engagement/* prefix" \
  '`#engagement/' "$EXPLAINER_BLOCK"
assert_grep "explainer covers #scope/* prefix" \
  '`#scope/' "$EXPLAINER_BLOCK"
# Prefix-bucket dedup: should explain #project ONCE even though multiple
# #project/<name> tags exist across staged files. Count the dispatch headers.
project_count=$(grep -cE '^- `#project[/`]' "$EXPLAINER_BLOCK" || true)
engagement_count=$(grep -cE '^- `#engagement/' "$EXPLAINER_BLOCK" || true)
if [ "$project_count" = "1" ]; then
  record_pass "explainer dedupes #project prefix (count=1)"
else
  record_fail "explainer dedupes #project prefix" "1" "$project_count"
fi
if [ "$engagement_count" = "1" ]; then
  record_pass "explainer dedupes #engagement/* prefix (count=1)"
else
  record_fail "explainer dedupes #engagement/* prefix" "1" "$engagement_count"
fi

# ---------- AC10 — per-frontmatter-field coverage on stderr ----------
echo "AC10 — per-frontmatter-field coverage on stderr"
assert_grep "explainer covers type field"           '`type`'           "$EXPLAINER_BLOCK"
assert_grep "explainer covers tags field"           '`tags`'           "$EXPLAINER_BLOCK"
assert_grep "explainer covers generated_by field"   '`generated_by`'   "$EXPLAINER_BLOCK"
assert_grep "explainer covers generated_from field" '`generated_from`' "$EXPLAINER_BLOCK"
assert_grep "explainer covers last_user_edit field" '`last_user_edit`' "$EXPLAINER_BLOCK"

# ---------- AC11 — pre-flight aborts on missing SP12 T-11 done-marker ----------
echo "AC11 — missing SP12 T-11 → hard abort"
NO_T11_PLAN_TREE="$TMPROOT/no-t11-plan-tree"
mkdir -p "$NO_T11_PLAN_TREE/12-auto-authored-personalization/state"
echo "T-2 ok" > "$NO_T11_PLAN_TREE/12-auto-authored-personalization/state/T-2.done"
# (deliberately NO T-11.done)
NO_T11_VAULT="$TMPROOT/no-t11-vault"
mkdir -p "$NO_T11_VAULT"
ABORT_STDERR="$TMPROOT/no-t11.stderr"
"$SEED_SH" \
  --vault-root "$NO_T11_VAULT" \
  --approved-plan "$APPROVED_PLAN" \
  --templates-dir "$TEMPLATES_DIR" \
  --pf-lib "$PF_LIB" \
  --gate-lib "$GATE_LIB" \
  --explainer-lib "$EXPLAINER_LIB" \
  --plan-tree "$NO_T11_PLAN_TREE" \
  --audience self \
  >/dev/null 2>"$ABORT_STDERR"
abort_rc=$?
assert_eq "missing T-11.done → seed.sh rc=2" "2" "$abort_rc"
assert_grep "abort stderr names SP12 T-11 done-marker" \
  'SP12 T-11 done-marker not found' "$ABORT_STDERR"

# ---------- AC12 — hermetic isolation ----------
echo "AC12 — hermetic isolation"
case "$AUTO_AUTHOR_LOG" in
  "$TMPROOT"/*) record_pass "AUTO_AUTHOR_LOG resolved into TMPROOT" ;;
  *) record_fail "AUTO_AUTHOR_LOG isolation" "under $TMPROOT" "$AUTO_AUTHOR_LOG" ;;
esac
case "$TG_STAGE_DIR" in
  "$TMPROOT"/*) record_pass "TG_STAGE_DIR resolved into TMPROOT" ;;
  *) record_fail "TG_STAGE_DIR isolation" "under $TMPROOT" "$TG_STAGE_DIR" ;;
esac
# Default state dir in repo must remain untouched.
DEFAULT_STATE="$REPO_ROOT/onboarding/seed-content/state"
if [ ! -d "$DEFAULT_STATE" ] || [ -z "$(ls -A "$DEFAULT_STATE" 2>/dev/null)" ]; then
  record_pass "default state/ dir untouched (absent or empty)"
else
  contents=$(ls "$DEFAULT_STATE" 2>/dev/null | tr '\n' ' ')
  record_fail "default state/ untouched" "absent or empty" "contains: $contents"
fi
# Default audit log untouched.
DEFAULT_AUDIT="$REPO_ROOT/onboarding/auto-author-log.jsonl"
if [ -f "$DEFAULT_AUDIT" ]; then
  default_size_before=$(wc -c < "$DEFAULT_AUDIT" | tr -d ' ')
  # Re-run a no-op skip to verify size doesn't change
  SEED_PROJECTS_PROMPT_CHOICE="s" \
    "$SEED_SH" \
      --vault-root "$VAULT_ROOT" \
      --approved-plan "$APPROVED_PLAN" \
      --templates-dir "$TEMPLATES_DIR" \
      --pf-lib "$PF_LIB" \
      --gate-lib "$GATE_LIB" \
      --explainer-lib "$EXPLAINER_LIB" \
      --plan-tree "$SYNTH_PLAN_TREE" \
      --audience self \
    >/dev/null 2>/dev/null
  default_size_after=$(wc -c < "$DEFAULT_AUDIT" | tr -d ' ')
  assert_eq "default auto-author-log.jsonl untouched" "$default_size_before" "$default_size_after"
else
  record_pass "default auto-author-log.jsonl absent (untouched)"
fi

# ---------- AC13 — regression: T-8 suite still passes ----------
echo "AC13 — T-8 regression (sp13-seed-projects-test.sh)"
T8_LOG="$TMPROOT/t8-rerun.log"
if [ -f "$T8_TEST" ]; then
  bash "$T8_TEST" >"$T8_LOG" 2>&1
  t8_rc=$?
  assert_eq "T-8 test suite re-run rc=0" "0" "$t8_rc"
  # Final summary should include "all green" or "fail=0".
  if grep -qE 'fail=0' "$T8_LOG" 2>/dev/null || \
     grep -qE 'PASS.*all' "$T8_LOG" 2>/dev/null || \
     grep -qE 'OK.*pass' "$T8_LOG" 2>/dev/null; then
    record_pass "T-8 test suite reports clean exit"
  elif [ "$t8_rc" = "0" ]; then
    record_pass "T-8 test suite rc=0 (no fail summary line; rc is the truth)"
  else
    tail -20 "$T8_LOG" >&2
    record_fail "T-8 test suite clean" "rc=0 + no FAIL lines" "rc=$t8_rc"
  fi
else
  record_fail "T-8 test fixture file" "exists at $T8_TEST" "missing"
fi

# ---------- summary ----------
echo
echo "=== SP13 T-9 explainer-fragments tests ==="
echo "  pass=$pass  fail=$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
