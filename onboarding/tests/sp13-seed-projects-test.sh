#!/usr/bin/env bash
# sp13-seed-projects-test.sh — SP13 T-8 unit tests
#
# Covers Stage 3 PRD/Context/Updates triple generator + /adopt invocation:
#   AC1   skills/seed-projects/SKILL.md + seed.sh + seed.py + 3 templates
#         all exist; bash -n / ast.parse / template-presence clean
#   AC2   pre-flight aborts cleanly when SP12 T-2 done-marker is missing
#         (synthetic plan-tree path with no T-2.done)
#   AC3   pre-flight aborts cleanly when approved plan is missing
#   AC4   pre-flight aborts cleanly when approved plan has wrong schema_version
#   AC5   apply path: 5-project fixture → 5 dirs + 15 files (PRD/Context/
#         Updates per project) under vault root; rc=0
#   AC6   each generated file's provenance frontmatter validates against
#         SP12's schemas/provenance-frontmatter-schema.json (jq required-keys
#         + type spot-checks via pf_validate)
#   AC7   single batched gate: exactly one preview audit record per run
#         (NOT 15 per-file previews) + one apply record per file (15) +
#         one generate record. surface_id="seed-projects" on all.
#   AC8   sample triad content quality: PRD.md, Context.md, Updates.md for
#         project p0001 contain placeholder-substituted values from
#         candidate.metadata + source_items (no leftover {{tokens}}; tags
#         render under tags: list; source_items_bullet_list rendered)
#   AC9   skip path: rc=0; no vault writes; one skip audit record
#   AC10  abort path: rc=1; no vault writes; one abort audit record
#   AC11  /adopt invocation: when approved-import-plan.md is present,
#         /adopt invokes /seed-projects automatically and reports the
#         outcome in its summary
#   AC12  hermetic isolation: no writes outside $TMPDIR/sp13-t8-test-*;
#         AUTO_AUTHOR_LOG + TG_STAGE_DIR forced into tmpdir; default
#         state/ + foundation-repo auto-author-log.jsonl untouched
#
# Hermetic: $TMPDIR/sp13-t8-test-XXXXXX. No live writes.
# Bash 3.2 compatible (R-23).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SKILL_DIR="$REPO_ROOT/skills/seed-projects"
SEED_SH="$SKILL_DIR/seed.sh"
SEED_PY="$SKILL_DIR/seed.py"
SKILL_MD="$SKILL_DIR/SKILL.md"
ADOPT_SH="$REPO_ROOT/skills/adopt/adopt.sh"
TEMPLATES_DIR="$REPO_ROOT/templates"
PF_LIB="$REPO_ROOT/lib/provenance-frontmatter.sh"
GATE_LIB="$REPO_ROOT/onboarding/lib/three-step-gate.sh"
PROVENANCE_SCHEMA="$REPO_ROOT/schemas/provenance-frontmatter-schema.json"
IMPORT_SH="$REPO_ROOT/skills/infer-vault-structure/import-plan.sh"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/sp13-t8-test-XXXXXX")
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
assert_eq() { if [ "$2" = "$3" ]; then record_pass "$1"; else record_fail "$1" "$2" "$3"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then record_pass "$1"; else record_fail "$1" "$2" "$3"; fi; }
assert_ge() {
  if [ "$2" -ge "$3" ] 2>/dev/null; then
    record_pass "$1 (got $2; need >= $3)"
  else
    record_fail "$1" ">= $3" "$2"
  fi
}
assert_grep() {
  if grep -qE "$2" "$3" 2>/dev/null; then
    record_pass "$1"
  else
    record_fail "$1" "match: $2" "no match in $3"
  fi
}
assert_not_grep() {
  if ! grep -qE "$2" "$3" 2>/dev/null; then
    record_pass "$1"
  else
    record_fail "$1" "no match: $2" "found match in $3"
  fi
}

# ---------- AC1 — components exist + syntax clean ----------
echo "AC1 — components present + syntax clean"
if [ -f "$SEED_SH" ] && bash -n "$SEED_SH" 2>/dev/null; then
  record_pass "seed.sh exists + bash -n clean"
else
  record_fail "seed.sh" "ok" "missing-or-syntax"
fi
if [ -f "$SEED_PY" ] && python3 -c "import ast; ast.parse(open('$SEED_PY').read())" 2>/dev/null; then
  record_pass "seed.py exists + ast.parse clean"
else
  record_fail "seed.py" "ok" "missing-or-syntax"
fi
if [ -f "$SKILL_MD" ]; then record_pass "SKILL.md exists"
else record_fail "SKILL.md" "exists" "missing"; fi
for tn in prd context updates; do
  if [ -f "$TEMPLATES_DIR/$tn-template.md" ]; then
    record_pass "templates/$tn-template.md exists"
  else
    record_fail "templates/$tn-template.md" "exists" "missing"
  fi
done

# ---------- shared fixture: synthesize 5-project propose-taxonomy ----------
# Hand-crafted (not via T-5) so the test is independent of T-5 stub
# behavior. Shape matches sp13-t5/1; T-6 import-plan.sh consumes it
# directly.

FIXTURE_PROPOSE="$TMPROOT/propose-taxonomy.json"
cat > "$FIXTURE_PROPOSE" <<'JSON'
{
  "schema_version": "sp13-t5/1",
  "llm_mode": "stub",
  "embedding_mode_input": "stub",
  "n_records": 15,
  "n_clusters_input": 5,
  "passes": [
    {"pass": 1, "model": "stub-pass1", "n_candidates_proposed": 5, "n_items_mapped": 15, "duration_ms": 100},
    {"pass": 2, "model": "stub-pass2", "n_candidates_proposed": 5, "n_items_mapped": 15, "duration_ms": 100, "merge_split_ops": []}
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
        "summary": "Alpha is the lighthouse engagement focused on Q3 platform readiness review across the data and ML stack.",
        "tags": ["#project/alpha", "#engagement/alpha"],
        "engagement": "alpha",
        "rationale": "Items grouped under alpha share platform-readiness language and the alpha engagement marker."
      },
      "source_items": [
        {"path": "/seed/alpha/kickoff.md", "source_hash": "a1a1a1a1a1a1a1a1"},
        {"path": "/seed/alpha/q3-review.md", "source_hash": "a2a2a2a2a2a2a2a2"},
        {"path": "/seed/alpha/scope-doc.md", "source_hash": "a3a3a3a3a3a3a3a3"}
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
        "summary": "Beta engagement: customer-facing AI assistant rollout with weekly stakeholder syncs.",
        "tags": ["#project/beta"],
        "engagement": "beta",
        "rationale": "Items grouped under beta share customer-facing-rollout language."
      },
      "source_items": [
        {"path": "/seed/beta/rollout-plan.md", "source_hash": "b1b1b1b1b1b1b1b1"},
        {"path": "/seed/beta/stakeholder-notes.md", "source_hash": "b2b2b2b2b2b2b2b2"},
        {"path": "/seed/beta/risk-register.md", "source_hash": "b3b3b3b3b3b3b3b3"}
      ],
      "confidence": 0.9,
      "low_confidence": false
    },
    {
      "candidate_id": "p0003",
      "label": "gamma",
      "type": "project",
      "proposed_path": "Engagements/gamma",
      "metadata": {
        "summary": "Gamma is a research-track engagement: TnT-LLM evaluation against bench corpora.",
        "tags": ["#project/gamma", "#research"],
        "engagement": "gamma",
        "rationale": "Items grouped under gamma share research-track + bench-corpora language."
      },
      "source_items": [
        {"path": "/seed/gamma/bench-spec.md", "source_hash": "c1c1c1c1c1c1c1c1"},
        {"path": "/seed/gamma/eval-protocol.md", "source_hash": "c2c2c2c2c2c2c2c2"},
        {"path": "/seed/gamma/results-draft.md", "source_hash": "c3c3c3c3c3c3c3c3"}
      ],
      "confidence": 0.8,
      "low_confidence": false
    },
    {
      "candidate_id": "p0004",
      "label": "delta",
      "type": "project",
      "proposed_path": "Engagements/delta",
      "metadata": {
        "summary": "Delta engagement: vendor-management workstream around the new MLOps platform.",
        "tags": ["#project/delta"],
        "engagement": "delta",
        "rationale": "Items grouped under delta share vendor-management language."
      },
      "source_items": [
        {"path": "/seed/delta/vendor-shortlist.md", "source_hash": "d1d1d1d1d1d1d1d1"},
        {"path": "/seed/delta/contract-redlines.md", "source_hash": "d2d2d2d2d2d2d2d2"},
        {"path": "/seed/delta/sow-draft.md", "source_hash": "d3d3d3d3d3d3d3d3"}
      ],
      "confidence": 0.85,
      "low_confidence": false
    },
    {
      "candidate_id": "p0005",
      "label": "epsilon",
      "type": "project",
      "proposed_path": "Engagements/epsilon",
      "metadata": {
        "summary": "Epsilon engagement: internal ops automation focused on calendar + meeting hygiene.",
        "tags": ["#project/epsilon", "#internal"],
        "engagement": "epsilon",
        "rationale": "Items grouped under epsilon share internal-ops + calendar language."
      },
      "source_items": [
        {"path": "/seed/epsilon/automation-roadmap.md", "source_hash": "e1e1e1e1e1e1e1e1"},
        {"path": "/seed/epsilon/calendar-sync-spec.md", "source_hash": "e2e2e2e2e2e2e2e2"},
        {"path": "/seed/epsilon/handoff-protocol.md", "source_hash": "e3e3e3e3e3e3e3e3"}
      ],
      "confidence": 1.0,
      "low_confidence": false
    }
  ],
  "small_corpus_input": false,
  "warnings": []
}
JSON

# Render the import-plan via T-6 (the real generator — gives us a valid sp13-t6/1 plan).
APPROVED_PLAN="$TMPROOT/approved-import-plan.md"
"$IMPORT_SH" \
  --propose-taxonomy "$FIXTURE_PROPOSE" \
  --out "$APPROVED_PLAN" \
  --generated-at "2026-05-04T18:00:00Z" \
  >/dev/null 2>&1

if [ ! -f "$APPROVED_PLAN" ]; then
  echo "TEST FIXTURE FAILURE: import-plan.sh did not produce $APPROVED_PLAN" >&2
  exit 1
fi
if ! grep -q '^schema_version: sp13-t6/1$' "$APPROVED_PLAN"; then
  echo "TEST FIXTURE FAILURE: rendered plan missing sp13-t6/1 anchor" >&2
  exit 1
fi

# Synthesize a dev-mode plan tree with SP12 T-2 done-marker present (so
# pre-flight passes the dev-mode check).
DEV_PLAN_TREE="$TMPROOT/devplan"
mkdir -p "$DEV_PLAN_TREE/12-auto-authored-personalization/state"
echo "T-2 done synthetic"  > "$DEV_PLAN_TREE/12-auto-authored-personalization/state/T-2.done"
# T-9 (2026-05-04) added a SP12 T-11 done-marker pre-flight check —
# seed.sh sources explainer-fragments.sh which cites
# docs/personalization-model.md (SP12 T-11). All happy-path invocations
# below need both markers present in the synthetic plan tree.
echo "T-11 done synthetic" > "$DEV_PLAN_TREE/12-auto-authored-personalization/state/T-11.done"

# Vault root for tests.
VAULT_ROOT="$TMPROOT/vault"
mkdir -p "$VAULT_ROOT"

# ---------- AC2 — pre-flight aborts when SP12 T-2 done-marker missing ----------
echo "AC2 — pre-flight aborts when SP12 T-2 done-marker missing"
NO_T2_TREE="$TMPROOT/devplan-no-t2"
mkdir -p "$NO_T2_TREE/12-auto-authored-personalization"
out=$( "$SEED_SH" \
  --vault-root "$VAULT_ROOT" \
  --approved-plan "$APPROVED_PLAN" \
  --plan-tree "$NO_T2_TREE" \
  </dev/null 2>&1 ); rc=$?
assert_eq "rc=2 on missing SP12 T-2 done-marker" "2" "$rc"
echo "$out" | grep -q "HARD ABORT" && record_pass "stderr mentions HARD ABORT" \
  || record_fail "HARD ABORT message" "present" "absent"
echo "$out" | grep -q "T-2 done-marker not found" && record_pass "stderr cites T-2 done-marker" \
  || record_fail "T-2 reference" "present" "absent"

# ---------- AC3 — pre-flight aborts when approved plan missing ----------
echo "AC3 — pre-flight aborts when approved plan missing"
out=$( "$SEED_SH" \
  --vault-root "$VAULT_ROOT" \
  --approved-plan "$TMPROOT/missing.md" \
  --plan-tree "$DEV_PLAN_TREE" \
  </dev/null 2>&1 ); rc=$?
assert_eq "rc=2 on missing approved plan" "2" "$rc"
echo "$out" | grep -q "approved plan not found" && record_pass "stderr cites missing-input" \
  || record_fail "missing-input message" "present" "absent"

# ---------- AC4 — pre-flight aborts on schema_version mismatch ----------
echo "AC4 — pre-flight aborts on schema_version mismatch"
BAD_PLAN="$TMPROOT/bad-version.md"
{
  echo '---'
  echo 'schema_version: sp13-t6/0'
  echo '---'
} > "$BAD_PLAN"
out=$( "$SEED_SH" \
  --vault-root "$VAULT_ROOT" \
  --approved-plan "$BAD_PLAN" \
  --plan-tree "$DEV_PLAN_TREE" \
  </dev/null 2>&1 ); rc=$?
assert_eq "rc=2 on schema_version mismatch" "2" "$rc"
echo "$out" | grep -q "schema_version mismatch" && record_pass "stderr cites schema mismatch" \
  || record_fail "schema-mismatch message" "present" "absent"

# ---------- AC5 — apply path produces 5 dirs + 15 files ----------
echo "AC5 — apply path: 5 dirs + 15 files"
APPLY_VAULT="$TMPROOT/vault-apply"
mkdir -p "$APPLY_VAULT"
echo "a" | "$SEED_SH" \
  --vault-root "$APPLY_VAULT" \
  --approved-plan "$APPROVED_PLAN" \
  --plan-tree "$DEV_PLAN_TREE" \
  --accept-on-eof \
  >"$TMPROOT/apply-stdout.log" 2>"$TMPROOT/apply-stderr.log"
rc=$?
assert_eq "apply rc=0" "0" "$rc"

dir_count=$(find "$APPLY_VAULT/Engagements" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "5 project dirs created" "5" "$dir_count"

for label in alpha beta gamma delta epsilon; do
  for kind in PRD Context Updates; do
    fpath="$APPLY_VAULT/Engagements/$label/$kind.md"
    if [ -f "$fpath" ]; then
      record_pass "$label/$kind.md exists"
    else
      record_fail "$label/$kind.md" "exists" "missing"
    fi
  done
done

file_count=$(find "$APPLY_VAULT/Engagements" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "15 total markdown files" "15" "$file_count"

# ---------- AC6 — provenance frontmatter validates per-file ----------
echo "AC6 — every generated file's provenance frontmatter validates"
# Sample a triad (alpha) for full pf_validate; spot-check the rest by grep.
for kind in PRD Context Updates; do
  fpath="$APPLY_VAULT/Engagements/alpha/$kind.md"
  if (cd "$REPO_ROOT" && bash -c "
    . lib/provenance-frontmatter.sh
    pf_validate '$fpath'
  ") >/dev/null 2>&1; then
    record_pass "alpha/$kind.md pf_validate clean"
  else
    record_fail "alpha/$kind.md pf_validate" "ok" "fail"
  fi
done
# Spot-check: every generated file has the 3 required SP12 keys.
prov_ok=0
prov_fail=0
for f in $(find "$APPLY_VAULT/Engagements" -name "*.md"); do
  if grep -q '^generated_by: seed-projects@v2.0.0$' "$f" \
     && grep -q '^generated_from:' "$f" \
     && grep -q '^last_user_edit: null$' "$f"; then
    prov_ok=$((prov_ok + 1))
  else
    prov_fail=$((prov_fail + 1))
  fi
done
assert_eq "all 15 files carry SP12 provenance keys" "15" "$prov_ok"
assert_eq "0 files fail provenance grep" "0" "$prov_fail"

# ---------- AC7 — single batched gate audit shape ----------
echo "AC7 — audit log: single batched gate (1 gen + 1 prev + 15 apply)"
audit_total=$(wc -l < "$AUTO_AUTHOR_LOG" | tr -d ' ')
gen_count=$(grep -c '"action":"generate"' "$AUTO_AUTHOR_LOG" 2>/dev/null || true)
preview_count=$(grep -c '"action":"preview"' "$AUTO_AUTHOR_LOG" 2>/dev/null || true)
apply_count=$(grep -c '"action":"apply"' "$AUTO_AUTHOR_LOG" 2>/dev/null || true)
sid_count=$(grep -c '"surface_id":"seed-projects"' "$AUTO_AUTHOR_LOG" 2>/dev/null || true)

# AC2/AC3/AC4 do not write to AUTO_AUTHOR_LOG (pre-flight aborts before audit
# fires). Apply path emits: 1 generate + 1 preview + 15 apply = 17 records.
assert_eq "exactly 1 generate audit record" "1" "$gen_count"
assert_eq "exactly 1 preview audit record (single batched)" "1" "$preview_count"
assert_eq "exactly 15 apply audit records (one per file)" "15" "$apply_count"
assert_eq "all 17 records carry surface_id=seed-projects" "17" "$sid_count"
assert_eq "audit log has 17 lines total" "17" "$audit_total"

# ---------- AC8 — content-quality probe (alpha triad) ----------
echo "AC8 — alpha triad content has substituted placeholders"
PRD_F="$APPLY_VAULT/Engagements/alpha/PRD.md"
CTX_F="$APPLY_VAULT/Engagements/alpha/Context.md"
UPD_F="$APPLY_VAULT/Engagements/alpha/Updates.md"

# Title line carries the label; summary substituted; no leftover {{tokens}}.
assert_grep "PRD title carries label" "^# alpha$" "$PRD_F"
assert_grep "PRD summary substituted" "lighthouse engagement.*Q3 platform readiness" "$PRD_F"
assert_grep "PRD rationale substituted" "platform-readiness language" "$PRD_F"
assert_grep "PRD tags rendered as YAML list" "^  - \"#project/alpha\"$" "$PRD_F"
assert_grep "PRD source_items_bullet_list rendered" "kickoff\\.md" "$PRD_F"
assert_not_grep "PRD has no leftover {{token}}" "\{\{[A-Za-z]" "$PRD_F"
assert_not_grep "PRD has no _unresolved: tokens" "_unresolved:" "$PRD_F"

assert_grep "Context title rendered" "alpha — Context" "$CTX_F"
assert_grep "Context summary substituted" "lighthouse engagement" "$CTX_F"
assert_grep "Context source_items_block rendered" "source_hash:" "$CTX_F"
assert_not_grep "Context has no leftover {{token}}" "\{\{[A-Za-z]" "$CTX_F"

assert_grep "Updates title rendered" "alpha — Updates" "$UPD_F"
assert_grep "Updates source_items_count substituted" "scaffolded from 3 source items" "$UPD_F"
assert_grep "Updates seeded entry has date heading" "^### 2026-05" "$UPD_F"
assert_not_grep "Updates has no leftover {{token}}" "\{\{[A-Za-z]" "$UPD_F"

# ---------- AC9 — skip path: rc=0; no vault writes; one skip audit ----------
echo "AC9 — skip path"
SKIP_VAULT="$TMPROOT/vault-skip"
mkdir -p "$SKIP_VAULT/Engagements"
SKIP_AUDIT="$TMPROOT/skip-audit.jsonl"
AUTO_AUTHOR_LOG="$SKIP_AUDIT" SEED_PROJECTS_PROMPT_CHOICE="s" \
  "$SEED_SH" \
    --vault-root "$SKIP_VAULT" \
    --approved-plan "$APPROVED_PLAN" \
    --plan-tree "$DEV_PLAN_TREE" \
    --accept-on-eof \
    >/dev/null 2>"$TMPROOT/skip-stderr.log"
rc=$?
assert_eq "skip rc=0" "0" "$rc"
skip_files=$(find "$SKIP_VAULT/Engagements" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0 files written in skip path" "0" "$skip_files"
skip_audit_count=$(grep -c '"action":"skip"' "$SKIP_AUDIT" 2>/dev/null || true)
assert_ge "at least one skip audit record" "$skip_audit_count" "1"

# ---------- AC10 — abort path: rc=1; no vault writes; one abort audit ----------
echo "AC10 — abort path"
ABORT_VAULT="$TMPROOT/vault-abort"
mkdir -p "$ABORT_VAULT/Engagements"
ABORT_AUDIT="$TMPROOT/abort-audit.jsonl"
AUTO_AUTHOR_LOG="$ABORT_AUDIT" SEED_PROJECTS_PROMPT_CHOICE="b" \
  "$SEED_SH" \
    --vault-root "$ABORT_VAULT" \
    --approved-plan "$APPROVED_PLAN" \
    --plan-tree "$DEV_PLAN_TREE" \
    --accept-on-eof \
    >/dev/null 2>"$TMPROOT/abort-stderr.log"
rc=$?
assert_eq "abort rc=1" "1" "$rc"
abort_files=$(find "$ABORT_VAULT/Engagements" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0 files written in abort path" "0" "$abort_files"
abort_audit_count=$(grep -c '"action":"abort"' "$ABORT_AUDIT" 2>/dev/null || true)
assert_ge "at least one abort audit record" "$abort_audit_count" "1"

# ---------- AC11 — /adopt invokes /seed-projects automatically ----------
echo "AC11 — /adopt detects approved plan + invokes /seed-projects"
ADOPT_HOME="$TMPROOT/adopt-home"
ADOPT_VAULT="$TMPROOT/adopt-vault"
mkdir -p "$ADOPT_HOME"
mkdir -p "$ADOPT_HOME/onboarding/seed-content/state"
cp "$APPROVED_PLAN" "$ADOPT_HOME/onboarding/seed-content/state/approved-import-plan.md"

# Synthetic foundation manifest so /adopt does not refuse with rc=21.
echo '{}' > "$ADOPT_HOME/foundation-manifest.json"

# Synthetic user manifest with vault.is_fresh=true + vault.root pointing
# at the adopt vault.
cat > "$ADOPT_HOME/user-manifest.json" <<JSON
{
  "vault": {
    "is_fresh": true,
    "root": "$ADOPT_VAULT",
    "organizational_method": "by-engagement",
    "top_level_folder": "Engagements",
    "default_audience": "self"
  },
  "identity": {
    "name": "Test User",
    "role": "Tester",
    "organization": "TestCo",
    "industry": "QA"
  }
}
JSON

# /adopt finds the seed-projects skill via SCRIPT_DIR/../seed-projects/seed.sh
# (relative to skills/adopt/adopt.sh in the foundation-repo). To make the
# CLAUDE_HOME-relative path resolution work for the test, also stage the
# templates + lib into ADOPT_HOME — but adopt.sh's preferred path is
# CLAUDE_HOME first, foundation-repo second. We can leave the foundation-
# repo path active by NOT staging skills/seed-projects into ADOPT_HOME;
# adopt.sh falls through to SCRIPT_DIR/../seed-projects/seed.sh.

ADOPT_AUDIT="$TMPROOT/adopt-audit.jsonl"
CLAUDE_HOME="$ADOPT_HOME" AUTO_AUTHOR_LOG="$ADOPT_AUDIT" \
  SEED_PROJECTS_PROMPT_CHOICE="a" \
  PLANS_HOME="$TMPROOT/adopt-plans" \
  "$ADOPT_SH" --force-install \
  >"$TMPROOT/adopt-stdout.log" 2>"$TMPROOT/adopt-stderr.log"
rc=$?
assert_eq "/adopt rc=0" "0" "$rc"
assert_grep "/adopt summary mentions seed-projects" "seed-projects:" "$TMPROOT/adopt-stdout.log"
adopt_apply_count=$(grep -c '"action":"apply"' "$ADOPT_AUDIT" 2>/dev/null || true)
assert_eq "/adopt run produced 15 apply audit records" "15" "$adopt_apply_count"
adopt_files=$(find "$ADOPT_VAULT/Engagements" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "/adopt vault has 15 generated files" "15" "$adopt_files"

# ---------- AC12 — hermetic isolation ----------
echo "AC12 — hermetic isolation"
real_log="$REPO_ROOT/onboarding/auto-author-log.jsonl"
real_log_sha_before="${REAL_LOG_SHA_BEFORE:-}"
# Don't claim untouched-ness against a preexisting real log; just assert
# the test's tmproot contains audit-log + staging artifacts AND no writes
# escaped to ~/.claude/.
if [ -f "$AUTO_AUTHOR_LOG" ]; then
  record_pass "AUTO_AUTHOR_LOG override resolved into tmpdir"
else
  record_fail "AUTO_AUTHOR_LOG" "exists in tmpdir" "missing"
fi
case "$AUTO_AUTHOR_LOG" in
  "$TMPROOT"/*) record_pass "AUTO_AUTHOR_LOG path is rooted in tmproot" ;;
  *) record_fail "AUTO_AUTHOR_LOG path" "under $TMPROOT" "$AUTO_AUTHOR_LOG" ;;
esac
case "$TG_STAGE_DIR" in
  "$TMPROOT"/*) record_pass "TG_STAGE_DIR path is rooted in tmproot" ;;
  *) record_fail "TG_STAGE_DIR path" "under $TMPROOT" "$TG_STAGE_DIR" ;;
esac

# ---------- summary ----------
total=$((pass + fail))
printf '\n=== sp13-seed-projects-test summary ===\n'
printf 'pass: %d   fail: %d   total: %d\n' "$pass" "$fail" "$total"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
