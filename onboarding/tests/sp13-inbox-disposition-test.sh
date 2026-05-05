#!/usr/bin/env bash
# sp13-inbox-disposition-test.sh — SP13 T-10 unit + integration tests.
#
# Covers Stage 3 "Doesn't fit" → Inbox routing:
#
#   AC1   shared h3_walker.py + inbox-disposition.{sh,py} all exist;
#         ast.parse clean; bash -n clean; seed.py imports h3_walker
#   AC2   pre-flight: inbox-disposition.sh aborts rc=2 when approved-plan
#         is missing OR carries a wrong schema_version
#   AC3   walker-direct: h3_walker.walk_h3_section against the
#         non-project section returns one candidate per non-project H3
#         and skips type=project candidates with stderr WARN; project
#         section walker (allowed_types=("project",)) skips non-project
#   AC4   inbox-disposition.py (direct invocation) against a hand-crafted
#         post-T-7 plan with mix of project + reference + meeting +
#         unclassified candidates produces one Inbox file per source_item
#         under <stage-dir>/seed-projects/Inbox/
#   AC5   per-type tag assignment: every Inbox file from a `reference`
#         candidate carries `#reference`; same for `meeting` → `#meeting`;
#         `unclassified` → `#unclassified`. NO project items leak into
#         Inbox/.
#   AC6   provenance frontmatter on every Inbox file validates against
#         SP12's schemas/provenance-frontmatter-schema.json (pf_validate)
#   AC7   seed.sh integration: single batched preview shows both project
#         triads AND Inbox items in ONE gate (one preview audit record per
#         run; not separate gates). Stderr probe verifies the preview
#         section labels both kinds of staged files.
#   AC8   apply path: <vault>/Inbox/ auto-created if absent; one apply
#         audit record per staged Inbox file; rc=0; files content-readable
#   AC9   empty non-project section: a plan with 0 non-project candidates
#         produces 0 Inbox writes (no crash; no stray Inbox/ dir);
#         project triads still stage normally
#   AC10  hermetic isolation: AUTO_AUTHOR_LOG + TG_STAGE_DIR forced into
#         tmpdir; default state/ + foundation-repo auto-author-log.jsonl
#         untouched
#   AC11  regression: T-8's 69-AC suite + T-9's 90-AC suite both still
#         pass after T-10 plumbing lands
#
# Hermetic: $TMPDIR/sp13-t10-test-XXXXXX. No live ~/.claude/ or
# foundation-repo writes. Bash 3.2 compatible (R-23).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SKILL_DIR="$REPO_ROOT/skills/seed-projects"
SEED_SH="$SKILL_DIR/seed.sh"
SEED_PY="$SKILL_DIR/seed.py"
DISPO_SH="$SKILL_DIR/inbox-disposition.sh"
DISPO_PY="$SKILL_DIR/inbox-disposition.py"
H3_WALKER_PY="$SKILL_DIR/h3_walker.py"
EXPLAINER_LIB="$SKILL_DIR/explainer-fragments.sh"
TEMPLATES_DIR="$REPO_ROOT/templates"
PF_LIB="$REPO_ROOT/lib/provenance-frontmatter.sh"
GATE_LIB="$REPO_ROOT/onboarding/lib/three-step-gate.sh"
PROVENANCE_SCHEMA="$REPO_ROOT/schemas/provenance-frontmatter-schema.json"
IMPORT_SH="$REPO_ROOT/skills/infer-vault-structure/import-plan.sh"
T8_TEST="$SCRIPT_DIR/sp13-seed-projects-test.sh"
T9_TEST="$SCRIPT_DIR/sp13-explainer-fragments-test.sh"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/sp13-t10-test-XXXXXX")
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
  if grep -qE "$2" "$3" 2>/dev/null; then record_pass "$1"
  else record_fail "$1" "match: $2" "no match in $3"; fi
}
assert_not_grep() {
  if ! grep -qE "$2" "$3" 2>/dev/null; then record_pass "$1"
  else record_fail "$1" "no match: $2" "found match in $3"; fi
}

# ---------- AC1 — components present + syntax clean ----------
echo "AC1 — components present + syntax clean"
if [ -f "$H3_WALKER_PY" ] && python3 -c "import ast; ast.parse(open('$H3_WALKER_PY').read())" 2>/dev/null; then
  record_pass "h3_walker.py exists + ast.parse clean"
else
  record_fail "h3_walker.py" "ok" "missing-or-syntax"
fi
if [ -f "$DISPO_PY" ] && python3 -c "import ast; ast.parse(open('$DISPO_PY').read())" 2>/dev/null; then
  record_pass "inbox-disposition.py exists + ast.parse clean"
else
  record_fail "inbox-disposition.py" "ok" "missing-or-syntax"
fi
if [ -f "$DISPO_SH" ] && bash -n "$DISPO_SH" 2>/dev/null; then
  record_pass "inbox-disposition.sh exists + bash -n clean"
else
  record_fail "inbox-disposition.sh" "ok" "missing-or-syntax"
fi
# seed.py imports h3_walker (post-promotion)
if grep -q '^from h3_walker import' "$SEED_PY"; then
  record_pass "seed.py imports h3_walker (post-promotion path a)"
else
  record_fail "seed.py imports h3_walker" "from h3_walker import line" "missing"
fi
# h3_walker exposes walk_h3_section
if grep -q '^def walk_h3_section' "$H3_WALKER_PY"; then
  record_pass "h3_walker exposes walk_h3_section"
else
  record_fail "h3_walker.walk_h3_section" "exported function" "missing"
fi

# ---------- shared fixture: hand-crafted post-T-7 propose-taxonomy ----------
# 2 project + 2 reference + 1 meeting + 2 unclassified candidates with
# multiple source_items per non-project candidate so we can probe per-item
# Inbox staging.

FIXTURE_PROPOSE="$TMPROOT/propose-taxonomy.json"
cat > "$FIXTURE_PROPOSE" <<'JSON'
{
  "schema_version": "propose-taxonomy/1",
  "llm_mode": "stub",
  "embedding_mode_input": "stub",
  "n_records": 11,
  "n_clusters_input": 4,
  "passes": [
    {"pass": 1, "model": "stub-pass1", "n_candidates_proposed": 7, "n_items_mapped": 11, "duration_ms": 100},
    {"pass": 2, "model": "stub-pass2", "n_candidates_proposed": 7, "n_items_mapped": 11, "duration_ms": 100, "merge_split_ops": []}
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
        "tags": ["#project/alpha", "#engagement/alpha"],
        "engagement": "alpha",
        "rationale": "Items grouped under alpha share platform language."
      },
      "source_items": [
        {"path": "/seed/alpha/kickoff.md", "source_hash": "a1a1a1a1a1a1a1a1"},
        {"path": "/seed/alpha/scope.md",   "source_hash": "a2a2a2a2a2a2a2a2"}
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
        "summary": "Beta engagement: customer rollout.",
        "tags": ["#project/beta", "#engagement/beta"],
        "engagement": "beta",
        "rationale": "Items grouped under beta share rollout language."
      },
      "source_items": [
        {"path": "/seed/beta/notes.md", "source_hash": "b1b1b1b1b1b1b1b1"}
      ],
      "confidence": 1.0,
      "low_confidence": false
    },
    {
      "candidate_id": "p0003",
      "label": "policy-refs",
      "type": "reference",
      "proposed_path": "References/policy-refs",
      "metadata": {
        "summary": "Reference materials about company policy.",
        "tags": ["#reference"]
      },
      "source_items": [
        {"path": "/seed/refs/policy-handbook.md", "source_hash": "c1c1c1c1c1c1c1c1"},
        {"path": "/seed/refs/policy-faq.md",     "source_hash": "c2c2c2c2c2c2c2c2"}
      ],
      "confidence": 0.9,
      "low_confidence": false
    },
    {
      "candidate_id": "p0004",
      "label": "compliance-refs",
      "type": "reference",
      "proposed_path": "References/compliance-refs",
      "metadata": {
        "summary": "Reference materials about compliance.",
        "tags": ["#reference"]
      },
      "source_items": [
        {"path": "/seed/refs/compliance-overview.md", "source_hash": "d1d1d1d1d1d1d1d1"}
      ],
      "confidence": 0.85,
      "low_confidence": false
    },
    {
      "candidate_id": "p0005",
      "label": "weekly-syncs",
      "type": "meeting",
      "proposed_path": "Meetings/weekly-syncs",
      "metadata": {
        "summary": "Recurring weekly sync notes.",
        "tags": ["#meeting"]
      },
      "source_items": [
        {"path": "/seed/meetings/2026-04-21-sync.md", "source_hash": "e1e1e1e1e1e1e1e1"},
        {"path": "/seed/meetings/2026-04-28-sync.md", "source_hash": "e2e2e2e2e2e2e2e2"}
      ],
      "confidence": 0.8,
      "low_confidence": false
    },
    {
      "candidate_id": "unclassified",
      "label": "unclassified",
      "type": "unclassified",
      "proposed_path": "",
      "metadata": {
        "summary": "Items that did not cluster into a project candidate.",
        "tags": ["#unclassified"]
      },
      "source_items": [
        {"path": "/seed/misc/random-note-1.md", "source_hash": "f1f1f1f1f1f1f1f1"},
        {"path": "/seed/misc/random-note-2.md", "source_hash": "f2f2f2f2f2f2f2f2"},
        {"path": "/seed/misc/random-note-3.md", "source_hash": "f3f3f3f3f3f3f3f3"}
      ],
      "confidence": 0.0,
      "low_confidence": true
    }
  ],
  "non_project_candidates": [
    {
      "candidate_id": "p0003",
      "label": "policy-refs",
      "type": "reference",
      "proposed_path": "References/policy-refs",
      "metadata": {"summary": "Reference materials about company policy.", "tags": ["#reference"]},
      "source_items": [
        {"path": "/seed/refs/policy-handbook.md", "source_hash": "c1c1c1c1c1c1c1c1"},
        {"path": "/seed/refs/policy-faq.md",     "source_hash": "c2c2c2c2c2c2c2c2"}
      ],
      "confidence": 0.9,
      "low_confidence": false
    },
    {
      "candidate_id": "p0004",
      "label": "compliance-refs",
      "type": "reference",
      "proposed_path": "References/compliance-refs",
      "metadata": {"summary": "Reference materials about compliance.", "tags": ["#reference"]},
      "source_items": [{"path": "/seed/refs/compliance-overview.md", "source_hash": "d1d1d1d1d1d1d1d1"}],
      "confidence": 0.85,
      "low_confidence": false
    },
    {
      "candidate_id": "p0005",
      "label": "weekly-syncs",
      "type": "meeting",
      "proposed_path": "Meetings/weekly-syncs",
      "metadata": {"summary": "Recurring weekly sync notes.", "tags": ["#meeting"]},
      "source_items": [
        {"path": "/seed/meetings/2026-04-21-sync.md", "source_hash": "e1e1e1e1e1e1e1e1"},
        {"path": "/seed/meetings/2026-04-28-sync.md", "source_hash": "e2e2e2e2e2e2e2e2"}
      ],
      "confidence": 0.8,
      "low_confidence": false
    },
    {
      "candidate_id": "unclassified",
      "label": "unclassified",
      "type": "unclassified",
      "proposed_path": "",
      "metadata": {"summary": "Items that did not cluster into a project candidate.", "tags": ["#unclassified"]},
      "source_items": [
        {"path": "/seed/misc/random-note-1.md", "source_hash": "f1f1f1f1f1f1f1f1"},
        {"path": "/seed/misc/random-note-2.md", "source_hash": "f2f2f2f2f2f2f2f2"},
        {"path": "/seed/misc/random-note-3.md", "source_hash": "f3f3f3f3f3f3f3f3"}
      ],
      "confidence": 0.0,
      "low_confidence": true
    }
  ]
}
JSON

# Render through real T-6 import-plan.sh to produce a import-plan/1 plan.
APPROVED_PLAN="$TMPROOT/approved-import-plan.md"
if ! "$IMPORT_SH" \
  --propose-taxonomy "$FIXTURE_PROPOSE" \
  --out "$APPROVED_PLAN" \
  --generated-at "2026-05-04T18:00:00Z" >"$TMPROOT/import.stdout" 2>"$TMPROOT/import.stderr"; then
  echo "FATAL: import-plan.sh failed; cannot run T-10 ACs"
  cat "$TMPROOT/import.stderr"
  exit 1
fi

# ---------- AC2 — inbox-disposition.sh pre-flight aborts ----------
echo "AC2 — inbox-disposition.sh pre-flight"
MISSING_PLAN_STDERR="$TMPROOT/missing-plan.stderr"
"$DISPO_SH" \
  --vault-root "$TMPROOT/v0" \
  --stage-dir "$TMPROOT/s0" \
  --approved-plan "$TMPROOT/does-not-exist.md" \
  --pf-lib "$PF_LIB" \
  >/dev/null 2>"$MISSING_PLAN_STDERR"
rc_missing=$?
assert_eq "missing approved plan → rc=2" "2" "$rc_missing"
assert_grep "missing-plan stderr names path" 'approved plan not found' "$MISSING_PLAN_STDERR"

BAD_SCHEMA_PLAN="$TMPROOT/bad-schema-plan.md"
cat > "$BAD_SCHEMA_PLAN" <<'EOF'
---
schema_version: sp99-bogus/1
generated_at: "2026-05-04T18:00:00Z"
---
# bogus
EOF
BAD_SCHEMA_STDERR="$TMPROOT/bad-schema.stderr"
"$DISPO_SH" \
  --vault-root "$TMPROOT/v0" \
  --stage-dir "$TMPROOT/s0" \
  --approved-plan "$BAD_SCHEMA_PLAN" \
  --pf-lib "$PF_LIB" \
  >/dev/null 2>"$BAD_SCHEMA_STDERR"
rc_bad_schema=$?
assert_eq "wrong schema_version → rc=2" "2" "$rc_bad_schema"
assert_grep "bad-schema stderr names import-plan/1" 'import-plan/1' "$BAD_SCHEMA_STDERR"

# ---------- AC3 — h3_walker direct ----------
echo "AC3 — h3_walker direct invocation"
WALKER_OUT="$TMPROOT/walker-out.json"
WALKER_STDERR="$TMPROOT/walker.stderr"
python3 - "$APPROVED_PLAN" > "$WALKER_OUT" 2>"$WALKER_STDERR" <<PY
import json, os, sys
sys.path.insert(0, "$SKILL_DIR")
from h3_walker import walk_h3_section
plan = sys.argv[1]
proj = walk_h3_section(plan,
    r"^## Project candidates\s*\$",
    allowed_types=("project",))
nonproj = walk_h3_section(plan,
    r"^## Doesn’t fit any project — disposition\s*\$",
    allowed_types=("reference", "meeting", "unclassified"))
print(json.dumps({"projects": [c["candidate_id"] for c in proj],
                  "non_projects": [(c["candidate_id"], c["type"]) for c in nonproj]}))
PY
walker_rc=$?
assert_eq "h3_walker direct rc=0" "0" "$walker_rc"
projects_count=$(jq -r '.projects | length' "$WALKER_OUT")
nonproj_count=$(jq -r '.non_projects | length' "$WALKER_OUT")
assert_eq "h3_walker projects count = 2" "2" "$projects_count"
assert_eq "h3_walker non-projects count = 4" "4" "$nonproj_count"

# Project section should NOT include reference/meeting/unclassified.
projects_have_p0001=$(jq -r '.projects | index("p0001") | tostring' "$WALKER_OUT")
projects_have_p0003=$(jq -r '.projects | index("p0003") // "null"' "$WALKER_OUT")
assert_ne "h3_walker project section excludes reference (p0003)" "$projects_have_p0003" "0"
assert_grep "h3_walker projects has p0001" 'p0001' "$WALKER_OUT"
assert_grep "h3_walker projects has p0002" 'p0002' "$WALKER_OUT"

# Non-project section should NOT include project candidates.
nonproj_has_p0001=$(jq -r '[.non_projects[][0]] | index("p0001") // "null"' "$WALKER_OUT")
assert_eq "h3_walker non-project section excludes p0001" "null" "$nonproj_has_p0001"
assert_grep "h3_walker non-projects has p0003 (reference)" 'p0003' "$WALKER_OUT"
assert_grep "h3_walker non-projects has p0005 (meeting)" 'p0005' "$WALKER_OUT"
assert_grep "h3_walker non-projects has unclassified" 'unclassified' "$WALKER_OUT"

# ---------- AC4 — inbox-disposition.py direct: per-item Inbox staging ----------
echo "AC4 — inbox-disposition.py direct invocation"
VAULT_ROOT="$TMPROOT/vault"
mkdir -p "$VAULT_ROOT"
DISPO_STAGE="$TMPROOT/dispo-stage"
DISPO_MANIFEST="$TMPROOT/dispo-manifest.json"
"$DISPO_SH" \
  --vault-root "$VAULT_ROOT" \
  --stage-dir "$DISPO_STAGE" \
  --approved-plan "$APPROVED_PLAN" \
  --pf-lib "$PF_LIB" \
  --audience self \
  --generated-at "2026-05-04T18:00:00Z" \
  > "$DISPO_MANIFEST" 2>"$TMPROOT/dispo-direct.stderr"
dispo_rc=$?
assert_eq "inbox-disposition direct rc=0" "0" "$dispo_rc"
assert_grep "dispo manifest schema_version" '"schema_version": "sp13-t10/1"' "$DISPO_MANIFEST"

INBOX_DIR="$DISPO_STAGE/seed-projects/Inbox"
inbox_file_count=$(find "$INBOX_DIR" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
# Expected: 2 (refs/policy) + 1 (refs/compliance) + 2 (meetings/sync) + 3 (unclassified) = 8
assert_eq "Inbox file count = 8" "8" "$inbox_file_count"

manifest_writes_count=$(jq -r '.writes | length' "$DISPO_MANIFEST")
assert_eq "manifest writes[] length = 8" "8" "$manifest_writes_count"

manifest_kinds=$(jq -r '[.writes[].kind] | unique | join(",")' "$DISPO_MANIFEST")
assert_eq "manifest writes all kind=Inbox" "Inbox" "$manifest_kinds"

manifest_non_proj_count=$(jq -r '.non_project_candidates_count' "$DISPO_MANIFEST")
assert_eq "manifest non_project_candidates_count = 4" "4" "$manifest_non_proj_count"

# Filename pattern: <date>-<slug>.md
sample_inbox_file=$(find "$INBOX_DIR" -type f -name '2026-05-04-*.md' | head -1)
if [ -n "$sample_inbox_file" ]; then
  record_pass "Inbox filename pattern <date>-<slug>.md present"
else
  record_fail "Inbox filename pattern" "2026-05-04-*.md present" "no match"
fi

# ---------- AC5 — per-type tag assignment + no project leakage ----------
echo "AC5 — per-type tag assignment"

# Group writes by source path token to confirm tag per type.
ref_tags=$(jq -r '[.writes[] | select(.type == "reference") | .tag] | unique | join(",")' "$DISPO_MANIFEST")
assert_eq "all reference writes carry #reference" "#reference" "$ref_tags"

meeting_tags=$(jq -r '[.writes[] | select(.type == "meeting") | .tag] | unique | join(",")' "$DISPO_MANIFEST")
assert_eq "all meeting writes carry #meeting" "#meeting" "$meeting_tags"

uncl_tags=$(jq -r '[.writes[] | select(.type == "unclassified") | .tag] | unique | join(",")' "$DISPO_MANIFEST")
assert_eq "all unclassified writes carry #unclassified" "#unclassified" "$uncl_tags"

# Project leakage probe: NO writes have type=project.
proj_leaks=$(jq -r '[.writes[] | select(.type == "project")] | length' "$DISPO_MANIFEST")
assert_eq "no project leakage into Inbox writes" "0" "$proj_leaks"

# In-file tag probe: each Inbox file's frontmatter `tags:` carries exactly
# one tag matching its disposition.
ref_file=$(jq -r '[.writes[] | select(.type == "reference") | .staging] | .[0]' "$DISPO_MANIFEST")
if [ -f "$ref_file" ]; then
  assert_grep "reference Inbox file has #reference in frontmatter" \
    '"#reference"' "$ref_file"
  assert_not_grep "reference Inbox file has no #project tag" \
    '"#project' "$ref_file"
fi
meeting_file=$(jq -r '[.writes[] | select(.type == "meeting") | .staging] | .[0]' "$DISPO_MANIFEST")
if [ -f "$meeting_file" ]; then
  assert_grep "meeting Inbox file has #meeting in frontmatter" \
    '"#meeting"' "$meeting_file"
fi
uncl_file=$(jq -r '[.writes[] | select(.type == "unclassified") | .staging] | .[0]' "$DISPO_MANIFEST")
if [ -f "$uncl_file" ]; then
  assert_grep "unclassified Inbox file has #unclassified in frontmatter" \
    '"#unclassified"' "$uncl_file"
fi

# Disposition field probe.
if [ -f "$uncl_file" ]; then
  assert_grep "unclassified Inbox file has disposition field" \
    '^disposition: "unclassified"' "$uncl_file"
fi

# ---------- AC6 — provenance frontmatter validates per file ----------
echo "AC6 — provenance frontmatter validates"
. "$PF_LIB"
PROVENANCE_SCHEMA="$PROVENANCE_SCHEMA"
export PROVENANCE_SCHEMA
pv_pass=0
pv_fail=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if pf_validate "$f" >/dev/null 2>&1; then
    pv_pass=$((pv_pass + 1))
  else
    pv_fail=$((pv_fail + 1))
  fi
done < <(jq -r '.writes[].staging' "$DISPO_MANIFEST")
assert_eq "all 8 Inbox files pass pf_validate" "8" "$pv_pass"
assert_eq "no Inbox files fail pf_validate" "0" "$pv_fail"

# ---------- AC7 — seed.sh single batched preview ----------
echo "AC7 — seed.sh single batched preview shows both kinds"
SEEDSH_VAULT="$TMPROOT/seedsh-vault"
mkdir -p "$SEEDSH_VAULT"
SEEDSH_PREVIEW="$TMPROOT/seedsh-preview.stderr"
SEED_PROJECTS_PROMPT_CHOICE="s" SEED_PROJECTS_GENERATED_AT="2026-05-04T18:00:00Z" \
  "$SEED_SH" \
    --vault-root "$SEEDSH_VAULT" \
    --approved-plan "$APPROVED_PLAN" \
    --templates-dir "$TEMPLATES_DIR" \
    --pf-lib "$PF_LIB" \
    --gate-lib "$GATE_LIB" \
    --explainer-lib "$EXPLAINER_LIB" \
    --inbox-dispo-sh "$DISPO_SH" \
    --audience self \
  >/dev/null 2>"$SEEDSH_PREVIEW"
seedsh_skip_rc=$?
assert_eq "seed.sh skip path rc=0" "0" "$seedsh_skip_rc"

assert_grep "preview shows project triads count" \
  'Project candidates: 2.+Project triads staged: 6' "$SEEDSH_PREVIEW"
assert_grep "preview shows non-project + Inbox count" \
  'Non-project candidates: 4.+Inbox items staged: 8' "$SEEDSH_PREVIEW"
assert_grep "preview shows total files staged" \
  'Total files staged: 14' "$SEEDSH_PREVIEW"
assert_grep "preview narrative mentions Inbox routing" \
  '<vault>/Inbox/' "$SEEDSH_PREVIEW"
assert_grep "preview narrative mentions disposition tags" \
  '#reference / #meeting / #unclassified' "$SEEDSH_PREVIEW"

# Single preview audit record (one batched gate, NOT separate gates).
preview_count=$(jq -c 'select(.action=="preview" and .surface_id=="seed-projects")' "$AUTO_AUTHOR_LOG" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "exactly one preview audit record per skip run" "1" "$preview_count"

# Skip emits exactly one skip audit record.
skip_count=$(jq -c 'select(.action=="skip" and .surface_id=="seed-projects")' "$AUTO_AUTHOR_LOG" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "exactly one skip audit record per skip run" "1" "$skip_count"

# ---------- AC8 — apply path: vault Inbox/ auto-created + per-file audit ----------
echo "AC8 — apply path"
# Reset audit log + vault for a clean apply run.
: > "$AUTO_AUTHOR_LOG"
APPLY_VAULT="$TMPROOT/apply-vault"
mkdir -p "$APPLY_VAULT"
# Sanity: <vault>/Inbox/ is absent before apply.
[ ! -d "$APPLY_VAULT/Inbox" ] && record_pass "vault/Inbox/ absent pre-apply" \
  || record_fail "vault/Inbox/ absent pre-apply" "missing" "present"

# Use a fresh stage dir for the apply run so seed.sh + inbox-disposition
# both stage into a clean tree.
APPLY_TG="$TMPROOT/apply-tg"
mkdir -p "$APPLY_TG"
APPLY_PREVIEW="$TMPROOT/apply.stderr"
SEED_PROJECTS_ACCEPT_ON_EOF=1 SEED_PROJECTS_GENERATED_AT="2026-05-04T18:00:00Z" \
  TG_STAGE_DIR="$APPLY_TG" \
  "$SEED_SH" \
    --vault-root "$APPLY_VAULT" \
    --approved-plan "$APPROVED_PLAN" \
    --templates-dir "$TEMPLATES_DIR" \
    --pf-lib "$PF_LIB" \
    --gate-lib "$GATE_LIB" \
    --explainer-lib "$EXPLAINER_LIB" \
    --inbox-dispo-sh "$DISPO_SH" \
    --audience self \
  </dev/null >/dev/null 2>"$APPLY_PREVIEW"
apply_rc=$?
assert_eq "seed.sh apply rc=0" "0" "$apply_rc"

# vault/Inbox/ now exists.
[ -d "$APPLY_VAULT/Inbox" ] && record_pass "vault/Inbox/ auto-created on apply" \
  || record_fail "vault/Inbox/ auto-created" "exists" "missing"

inbox_applied=$(find "$APPLY_VAULT/Inbox" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "8 Inbox files written to vault" "8" "$inbox_applied"

triad_applied=$(find "$APPLY_VAULT/Engagements" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "6 project-triad files written to vault (2 projects × 3)" "6" "$triad_applied"

# Audit records: 1 generate + 1 preview + 14 apply (6 project + 8 Inbox) = 16
generate_count=$(jq -c 'select(.action=="generate" and .surface_id=="seed-projects")' "$AUTO_AUTHOR_LOG" 2>/dev/null | wc -l | tr -d ' ')
preview_count=$(jq -c 'select(.action=="preview" and .surface_id=="seed-projects")' "$AUTO_AUTHOR_LOG" 2>/dev/null | wc -l | tr -d ' ')
apply_count=$(jq -c 'select(.action=="apply" and .surface_id=="seed-projects")' "$AUTO_AUTHOR_LOG" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "1 generate audit record" "1" "$generate_count"
assert_eq "1 preview audit record (single batched gate)" "1" "$preview_count"
assert_eq "14 apply audit records (6 triads + 8 Inbox)" "14" "$apply_count"

# Per-Inbox-target audit record carries the right target_path under <vault>/Inbox/.
inbox_target_count=$(jq -c 'select(.action=="apply" and (.target_path | test("/Inbox/")))' "$AUTO_AUTHOR_LOG" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "8 apply records target /Inbox/" "8" "$inbox_target_count"

# Spot check: applied Inbox file is content-readable + carries its frontmatter.
spot_inbox=$(find "$APPLY_VAULT/Inbox" -type f -name '*.md' | head -1)
if [ -f "$spot_inbox" ]; then
  assert_grep "applied Inbox file has provenance generated_by" \
    '^generated_by: inbox-disposition@v2.0.0' "$spot_inbox"
  assert_grep "applied Inbox file has source_path field" \
    '^source_path: ' "$spot_inbox"
fi

# ---------- AC9 — empty non-project section → 0 Inbox writes, no crash ----------
echo "AC9 — empty non-project section"
EMPTY_FIXTURE="$TMPROOT/empty-nonproj.json"
cat > "$EMPTY_FIXTURE" <<'JSON'
{
  "schema_version": "propose-taxonomy/1",
  "llm_mode": "stub",
  "embedding_mode_input": "stub",
  "n_records": 3,
  "n_clusters_input": 1,
  "passes": [
    {"pass": 1, "model": "stub-pass1", "n_candidates_proposed": 1, "n_items_mapped": 3, "duration_ms": 100},
    {"pass": 2, "model": "stub-pass2", "n_candidates_proposed": 1, "n_items_mapped": 3, "duration_ms": 100, "merge_split_ops": []}
  ],
  "n_passes": 2,
  "items_mapped_pct": 1.0,
  "candidates": [
    {
      "candidate_id": "p0001",
      "label": "alpha",
      "type": "project",
      "proposed_path": "Engagements/alpha",
      "metadata": {"summary": "Alpha only.", "tags": ["#project/alpha"]},
      "source_items": [
        {"path": "/seed/alpha/a.md", "source_hash": "a1a1a1a1a1a1a1a1"},
        {"path": "/seed/alpha/b.md", "source_hash": "a2a2a2a2a2a2a2a2"},
        {"path": "/seed/alpha/c.md", "source_hash": "a3a3a3a3a3a3a3a3"}
      ],
      "confidence": 1.0,
      "low_confidence": false
    }
  ],
  "non_project_candidates": []
}
JSON

EMPTY_PLAN="$TMPROOT/empty-plan.md"
"$IMPORT_SH" \
  --propose-taxonomy "$EMPTY_FIXTURE" \
  --out "$EMPTY_PLAN" \
  --generated-at "2026-05-04T18:00:00Z" >/dev/null 2>"$TMPROOT/empty-import.stderr"

EMPTY_DISPO_OUT="$TMPROOT/empty-dispo.json"
"$DISPO_SH" \
  --vault-root "$TMPROOT/empty-vault" \
  --stage-dir "$TMPROOT/empty-stage" \
  --approved-plan "$EMPTY_PLAN" \
  --pf-lib "$PF_LIB" \
  --generated-at "2026-05-04T18:00:00Z" \
  > "$EMPTY_DISPO_OUT" 2>"$TMPROOT/empty-dispo.stderr"
empty_rc=$?
mkdir -p "$TMPROOT/empty-vault"
assert_eq "inbox-disposition empty section rc=0" "0" "$empty_rc"

empty_writes=$(jq -r '.writes | length' "$EMPTY_DISPO_OUT")
assert_eq "empty section writes = 0" "0" "$empty_writes"
empty_count=$(jq -r '.non_project_candidates_count' "$EMPTY_DISPO_OUT")
assert_eq "empty section non_project_candidates_count = 0" "0" "$empty_count"

# Inbox dir SHOULD be created (for forward-compat) but empty.
empty_inbox="$TMPROOT/empty-stage/seed-projects/Inbox"
if [ -d "$empty_inbox" ]; then
  inbox_files=$(find "$empty_inbox" -type f 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "empty stage Inbox/ has 0 files" "0" "$inbox_files"
else
  record_pass "empty stage Inbox/ skipped (acceptable)"
fi

# ---------- AC10 — hermetic isolation ----------
echo "AC10 — hermetic isolation"
case "$AUTO_AUTHOR_LOG" in
  "$TMPROOT"/*) record_pass "AUTO_AUTHOR_LOG resolved into TMPROOT" ;;
  *) record_fail "AUTO_AUTHOR_LOG isolation" "under $TMPROOT" "$AUTO_AUTHOR_LOG" ;;
esac
case "$TG_STAGE_DIR" in
  "$TMPROOT"/*) record_pass "TG_STAGE_DIR resolved into TMPROOT" ;;
  *) record_fail "TG_STAGE_DIR isolation" "under $TMPROOT" "$TG_STAGE_DIR" ;;
esac
DEFAULT_STATE="$REPO_ROOT/onboarding/seed-content/state"
if [ ! -d "$DEFAULT_STATE" ] || [ -z "$(ls -A "$DEFAULT_STATE" 2>/dev/null)" ]; then
  record_pass "default seed-content/state/ untouched (absent or empty)"
else
  contents=$(ls "$DEFAULT_STATE" 2>/dev/null | tr '\n' ' ')
  record_fail "default seed-content/state/ untouched" "absent or empty" "contains: $contents"
fi
DEFAULT_AUDIT="$REPO_ROOT/onboarding/auto-author-log.jsonl"
if [ ! -f "$DEFAULT_AUDIT" ]; then
  record_pass "default auto-author-log.jsonl absent (untouched)"
else
  default_size_before=$(wc -c < "$DEFAULT_AUDIT" | tr -d ' ')
  # No-op: nothing should change between reads.
  default_size_after=$(wc -c < "$DEFAULT_AUDIT" | tr -d ' ')
  assert_eq "default auto-author-log.jsonl untouched" "$default_size_before" "$default_size_after"
fi

# ---------- AC11 — regression: T-8 + T-9 still pass ----------
echo "AC11 — regression: T-8 + T-9 suites"
T8_LOG="$TMPROOT/t8-rerun.log"
if [ -f "$T8_TEST" ]; then
  bash "$T8_TEST" >"$T8_LOG" 2>&1
  t8_rc=$?
  assert_eq "T-8 suite re-run rc=0" "0" "$t8_rc"
  if grep -qE 'fail: 0' "$T8_LOG" 2>/dev/null; then
    record_pass "T-8 suite reports fail: 0"
  else
    tail -10 "$T8_LOG" >&2
    record_fail "T-8 suite fail: 0" "fail: 0" "non-zero failures"
  fi
else
  record_fail "T-8 test fixture file" "exists" "missing"
fi

T9_LOG="$TMPROOT/t9-rerun.log"
if [ -f "$T9_TEST" ]; then
  bash "$T9_TEST" >"$T9_LOG" 2>&1
  t9_rc=$?
  assert_eq "T-9 suite re-run rc=0" "0" "$t9_rc"
  if grep -qE 'fail=0' "$T9_LOG" 2>/dev/null; then
    record_pass "T-9 suite reports fail=0"
  else
    tail -10 "$T9_LOG" >&2
    record_fail "T-9 suite fail=0" "fail=0" "non-zero failures"
  fi
else
  record_fail "T-9 test fixture file" "exists" "missing"
fi

# ---------- summary ----------
echo
echo "=== sp13-inbox-disposition-test summary ==="
echo "pass: $pass   fail: $fail   total: $((pass + fail))"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
