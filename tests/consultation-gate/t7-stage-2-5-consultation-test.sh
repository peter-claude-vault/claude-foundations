#!/usr/bin/env bash
# tests/consultation-gate/t7-stage-2-5-consultation-test.sh — SP15 T-7 acceptance
#
# Hermetic fixture test verifying SP15 T-7 (SP13 Stage 2.5 — pre-import-plan
# consultation gate) acceptance criteria. Hermetic tmpdir per
# `feedback_test_isolation_for_hooks_state`; never touches production
# `~/.claude/` or `~/Documents/Obsidian Vault` per
# `feedback_universal_vault_safety`.
#
# Acceptance criteria covered (10 ACs; spec required ≥7):
#   AC1 — stage-2-5-consultation.sh exists at skills/infer-vault-structure/;
#         R-23 lint clean (/bin/bash -n + bash --posix -n).
#   AC2 — Pre-condition: missing T-6 import-plan.md → rc=2 + clear error.
#   AC3 — Pre-condition: input plan missing ^schema_version: import-plan/1$
#         → rc=2 (schema mismatch error).
#   AC4 — Pre-condition: missing or schema-mismatched templates config
#         → rc=2.
#   AC5 — Rationale renders with corpus stats (n_records, n_clusters,
#         items_mapped_pct, llm_mode from frontmatter) AND ≥4 mandatory
#         citations (Cowan-4, PARA, Luhmann-11, Hick's Law) with verified
#         URLs.
#   AC6 — User-accept → rc=0; consulted-import-plan.md exists; carries
#         consulted_at (ISO-8601 UTC) + consultation_response_hash
#         (sha256-hex) in frontmatter; ^schema_version: import-plan/1$
#         line preserved.
#   AC7 — User-reject → rc=1; consulted-import-plan.md NOT written;
#         audit log records consult/reject with surface_id =
#         import-plan-consultation.
#   AC8 — Audit-log ordering: consult/accept appears BEFORE generate +
#         apply records for the same surface.
#   AC9 — Real-T-6 round-trip: synthetic propose-taxonomy fixture → real
#         T-6 import-plan.sh → Stage 2.5 (auto-apply) → real SP13 T-7
#         review-gate.sh (--accept-on-eof) → state/approved-import-plan.md
#         written; entire chain succeeds end-to-end.
#   AC10 — Templates config validates against schema under strict
#          Draft-07 jsonschema (consultation-rationale-templates/1).
#
# CONSTRAINTS (R-23): bash 3.2.57; jq + python3 required.
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP15 Session 8 (T-7)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STAGE25="$REPO_ROOT/skills/infer-vault-structure/stage-2-5-consultation.sh"
IMPORT_PLAN_SH="$REPO_ROOT/skills/infer-vault-structure/import-plan.sh"
REVIEW_GATE_SH="$REPO_ROOT/skills/infer-vault-structure/review-gate.sh"
TEMPLATES="$REPO_ROOT/schemas/consultation-rationale-templates.json"
TEMPLATES_SCHEMA="$REPO_ROOT/schemas/consultation-rationale-templates-schema.json"
CG_LIB="$REPO_ROOT/lib/consultation-gate.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS — %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL — %s\n' "$1" >&2; }

# --- AC1: file exists + R-23 lint ---

if [ ! -f "$STAGE25" ]; then
  fail "AC1 stage-2-5-consultation.sh missing at $STAGE25"
  exit 1
fi
pass "AC1 stage-2-5-consultation.sh exists"

for f in "$STAGE25" "$0"; do
  if /bin/bash -n "$f" >/dev/null 2>&1 && bash --posix -n "$f" >/dev/null 2>&1; then
    pass "AC1 R-23 lint clean: $(basename "$f")"
  else
    fail "AC1 R-23 lint FAILED: $f"
    /bin/bash -n "$f" 2>&1 | head -5 >&2
    bash --posix -n "$f" 2>&1 | head -5 >&2
    exit 1
  fi
done

# --- AC10: templates config validates against schema (Draft-07) ---

if python3 -c "
import json, sys
try:
    import jsonschema
except ImportError:
    sys.exit(77)
with open('$TEMPLATES_SCHEMA') as f: s = json.load(f)
with open('$TEMPLATES') as f: d = json.load(f)
jsonschema.Draft7Validator.check_schema(s)
jsonschema.validate(instance=d, schema=s)
" 2>/dev/null; then
  pass "AC10 templates config validates against consultation-rationale-templates/1 Draft-07 schema"
else
  rc=$?
  if [ "$rc" = "77" ]; then
    # jq fallback if jsonschema not installed.
    if jq -e '.schema_version == "consultation-rationale-templates/1"' "$TEMPLATES" >/dev/null 2>&1 && \
       jq -e '.templates["import-plan-consultation"].citations | length >= 4' "$TEMPLATES" >/dev/null 2>&1; then
      pass "AC10 templates config validates (jq fallback; jsonschema unavailable)"
    else
      fail "AC10 templates config validation failed (jq fallback)"
      exit 1
    fi
  else
    fail "AC10 templates config does NOT validate against Draft-07 schema"
    exit 1
  fi
fi

# --- Hermetic test sandbox ---

T7_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/consultation-stage-2-5-$$.XXXXXX")"
trap 'rm -rf "$T7_TEST_DIR" 2>/dev/null' EXIT INT TERM

export CLAUDE_HOME="$T7_TEST_DIR/claude"
export HOOKS_STATE_OVERRIDE="$CLAUDE_HOME/state"
export AUTO_AUTHOR_LOG="$T7_TEST_DIR/audit.jsonl"
export TG_STAGE_DIR="$T7_TEST_DIR/stage"
export EDITOR=":"
mkdir -p "$CLAUDE_HOME/onboarding/audit" "$HOOKS_STATE_OVERRIDE" "$TG_STAGE_DIR"

# Production allowlist contains import-plan-consultation; defaults will
# resolve fine. No CG_ALLOWLIST_PATH override needed.

# --- Synthetic import-plan.md fixture ---

write_synthetic_import_plan() {
  # $1 = output path; $2 = schema_version (default import-plan/1)
  local out="$1"
  local sv="${2:-import-plan/1}"
  cat > "$out" <<EOF
---
schema_version: $sv
input_propose_taxonomy_schema_version: propose-taxonomy/1
generated_at: 2026-05-04T20:00:00Z
header:
  n_records: 50
  n_clusters: 7
  n_passes: 2
  items_mapped_pct: 0.94
  llm_mode: stub
  embedding_mode_input: stub
unclassified_callout: {}
vault_tree:
  - Engagements/Acme
  - References/policies
  - Meetings/2026-Q2
---

## Corpus stats

- **50 source records** ingested.
- **7 clusters** identified by upstream embedding pass (excluding the unclassified bucket).
- **2 LLM passes** ran (mode: \`stub\`).

### Acme — \`Engagements/Acme\`

\`\`\`yaml
candidate_id: p0001
label: Acme
type: project
\`\`\`

| # | path | candidate | label | type | confidence | low_conf |
|---|---|---|---|---|---|---|
| 1 | doc1.md | p0001 | Acme | project | 0.95 | false |
EOF
}

# --- AC2: missing input plan → rc=2 ---

INPUT="$T7_TEST_DIR/state/import-plan.md"
OUT="$T7_TEST_DIR/state/consulted-import-plan.md"
mkdir -p "$T7_TEST_DIR/state"

set +e
"$STAGE25" --import-plan "$T7_TEST_DIR/state/nonexistent.md" --out "$OUT" \
  >"$T7_TEST_DIR/ac2.out" 2>"$T7_TEST_DIR/ac2.err"
rc=$?
set -e
if [ "$rc" = "2" ] && grep -q "input plan not found" "$T7_TEST_DIR/ac2.err"; then
  pass "AC2 missing input plan → rc=2 + clear error"
else
  fail "AC2 missing input plan: rc=$rc, expected 2"
  cat "$T7_TEST_DIR/ac2.err" | head -3 >&2
fi

# --- AC3: schema_version mismatch → rc=2 ---

write_synthetic_import_plan "$INPUT" "bogus-version/9"
set +e
"$STAGE25" --import-plan "$INPUT" --out "$OUT" \
  >"$T7_TEST_DIR/ac3.out" 2>"$T7_TEST_DIR/ac3.err"
rc=$?
set -e
if [ "$rc" = "2" ] && grep -q "schema_version mismatch" "$T7_TEST_DIR/ac3.err"; then
  pass "AC3 input schema_version mismatch → rc=2"
else
  fail "AC3 schema mismatch: rc=$rc"
  cat "$T7_TEST_DIR/ac3.err" | head -3 >&2
fi

# --- AC4: bad templates config → rc=2 ---

# Restore valid input plan; corrupt templates.
write_synthetic_import_plan "$INPUT"

# (a) missing templates file
set +e
"$STAGE25" --import-plan "$INPUT" --out "$OUT" \
  --templates "$T7_TEST_DIR/nonexistent-templates.json" \
  >"$T7_TEST_DIR/ac4a.out" 2>"$T7_TEST_DIR/ac4a.err"
rc_a=$?
set -e
[ "$rc_a" = "2" ] && grep -q "templates config not found" "$T7_TEST_DIR/ac4a.err" \
  && pass "AC4a missing templates → rc=2" \
  || { fail "AC4a missing templates: rc=$rc_a"; cat "$T7_TEST_DIR/ac4a.err" | head -3 >&2; }

# (b) wrong schema_version in templates
BAD_TEMPL="$T7_TEST_DIR/bad-templates.json"
jq '.schema_version = "wrong-version/1"' "$TEMPLATES" > "$BAD_TEMPL"
set +e
"$STAGE25" --import-plan "$INPUT" --out "$OUT" --templates "$BAD_TEMPL" \
  >"$T7_TEST_DIR/ac4b.out" 2>"$T7_TEST_DIR/ac4b.err"
rc_b=$?
set -e
[ "$rc_b" = "2" ] && grep -q "templates schema_version mismatch" "$T7_TEST_DIR/ac4b.err" \
  && pass "AC4b wrong-version templates → rc=2" \
  || { fail "AC4b wrong-version templates: rc=$rc_b"; cat "$T7_TEST_DIR/ac4b.err" | head -3 >&2; }

# (c) templates missing the surface-id entry
NOSID_TEMPL="$T7_TEST_DIR/nosid-templates.json"
jq 'del(.templates["import-plan-consultation"]) | .templates["other-surface"] = {"preamble":"x","tradeoffs":"y","citations":[]}' "$TEMPLATES" > "$NOSID_TEMPL"
set +e
"$STAGE25" --import-plan "$INPUT" --out "$OUT" --templates "$NOSID_TEMPL" \
  >"$T7_TEST_DIR/ac4c.out" 2>"$T7_TEST_DIR/ac4c.err"
rc_c=$?
set -e
[ "$rc_c" = "2" ] && grep -q "no entry for surface-id" "$T7_TEST_DIR/ac4c.err" \
  && pass "AC4c templates missing surface-id → rc=2" \
  || { fail "AC4c templates missing surface-id: rc=$rc_c"; cat "$T7_TEST_DIR/ac4c.err" | head -3 >&2; }

# --- AC5: rationale renders with corpus stats + 4 mandatory citations ---

# Use a fresh hermetic audit log so we can scan it cleanly.
> "$AUTO_AUTHOR_LOG"

# Capture rationale render via accept path (we just want to see the
# rationale block on stderr; the accept also tests AC6/AC8 below).
"$STAGE25" --import-plan "$INPUT" --out "$OUT" --auto-apply \
  >"$T7_TEST_DIR/ac5.out" 2>"$T7_TEST_DIR/ac5.err"
rc=$?

# Corpus stats.
if grep -q "source records ingested: 50" "$T7_TEST_DIR/ac5.err" && \
   grep -q "clusters identified by upstream embedding pass: 7" "$T7_TEST_DIR/ac5.err" && \
   grep -q "items_mapped_pct: 0.94" "$T7_TEST_DIR/ac5.err" && \
   grep -q "LLM passes run: 2 (mode: stub)" "$T7_TEST_DIR/ac5.err"; then
  pass "AC5 corpus stats render correctly (n_records / n_clusters / items_mapped_pct / llm_mode)"
else
  fail "AC5 corpus stats incomplete in render"
  grep -E "(records|clusters|mapped|passes)" "$T7_TEST_DIR/ac5.err" >&2 || true
fi

# Mandatory citations (Cowan-4, PARA-4, Luhmann-11, Hick's Law).
mandatory_citations_ok=1
for needle in \
  "Cowan, N." \
  "Forte, T." \
  "Luhmann" \
  "Hick"; do
  if ! grep -qF "$needle" "$T7_TEST_DIR/ac5.err"; then
    fail "AC5 missing mandatory citation: $needle"
    mandatory_citations_ok=0
  fi
done
[ "$mandatory_citations_ok" = "1" ] && pass "AC5 all 4 mandatory citations present (Cowan/PARA/Luhmann/Hick)"

# At least 4 URLs (one per mandatory citation).
url_count="$(grep -cE "^  URL: https?://" "$T7_TEST_DIR/ac5.err" || true)"
if [ "$url_count" -ge 4 ]; then
  pass "AC5 ≥4 citation URLs present (got $url_count)"
else
  fail "AC5 expected ≥4 citation URLs, got $url_count"
fi

# --- AC6: accept → consulted file with consulted_at + hash; import-plan/1 anchor preserved ---

if [ "$rc" != "0" ]; then
  fail "AC6 accept rc=$rc (expected 0)"
else
  if [ ! -f "$OUT" ]; then
    fail "AC6 consulted-import-plan.md not written"
  else
    # schema_version anchor preserved (downstream T-7 review-gate compatibility).
    if grep -q "^schema_version: import-plan/1$" "$OUT"; then
      pass "AC6 import-plan/1 schema_version anchor preserved in consulted plan"
    else
      fail "AC6 schema_version anchor lost in consulted plan"
    fi
    # consulted_at ISO-8601 UTC.
    if grep -qE "^consulted_at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" "$OUT"; then
      pass "AC6 consulted_at ISO-8601 UTC field present"
    else
      fail "AC6 consulted_at missing/malformed"
      grep "^consulted_at" "$OUT" >&2 || true
    fi
    # consultation_response_hash sha256-hex.
    if grep -qE "^consultation_response_hash: [a-f0-9]{64}$" "$OUT"; then
      pass "AC6 consultation_response_hash sha256-hex field present"
    else
      fail "AC6 consultation_response_hash missing/malformed"
      grep "^consultation_response_hash" "$OUT" >&2 || true
    fi
  fi
fi

# --- AC8: audit-log ordering — consult/accept BEFORE generate + apply ---

# Filter to records for our surface, find line numbers of accept + generate + apply.
consult_line="$(grep -n '"surface_id":"import-plan-consultation"' "$AUTO_AUTHOR_LOG" \
  | grep '"action":"consult"' | grep '"response":"accept"' | head -1 | cut -d: -f1)"
generate_line="$(grep -n '"surface_id":"import-plan-consultation"' "$AUTO_AUTHOR_LOG" \
  | grep '"action":"generate"' | head -1 | cut -d: -f1)"
apply_line="$(grep -n '"surface_id":"import-plan-consultation"' "$AUTO_AUTHOR_LOG" \
  | grep '"action":"apply"' | head -1 | cut -d: -f1)"
if [ -n "$consult_line" ] && [ -n "$generate_line" ] && [ -n "$apply_line" ] && \
   [ "$consult_line" -lt "$generate_line" ] && [ "$generate_line" -lt "$apply_line" ]; then
  pass "AC8 audit ordering: consult(line $consult_line) < generate($generate_line) < apply($apply_line)"
else
  fail "AC8 audit ordering wrong: consult=$consult_line generate=$generate_line apply=$apply_line"
  cat "$AUTO_AUTHOR_LOG" >&2
fi

# --- AC7: reject → rc=1; no consulted file; consult/reject record ---

rm -f "$OUT"
> "$AUTO_AUTHOR_LOG"
set +e
printf 'r\n' | "$STAGE25" --import-plan "$INPUT" --out "$OUT" \
  >"$T7_TEST_DIR/ac7.out" 2>"$T7_TEST_DIR/ac7.err"
rc=$?
set -e
if [ "$rc" = "1" ]; then
  pass "AC7 reject rc=1"
else
  fail "AC7 reject rc=$rc (expected 1)"
fi
if [ ! -f "$OUT" ]; then
  pass "AC7 reject did NOT write consulted plan"
else
  fail "AC7 reject leaked consulted plan to $OUT"
fi
# Audit log carries consult/reject for the surface, NO generate/apply.
if grep -q '"surface_id":"import-plan-consultation"' "$AUTO_AUTHOR_LOG" && \
   grep -q '"action":"consult"' "$AUTO_AUTHOR_LOG" && \
   grep -q '"response":"reject"' "$AUTO_AUTHOR_LOG"; then
  if ! grep -q '"action":"generate"' "$AUTO_AUTHOR_LOG" && \
     ! grep -q '"action":"apply"' "$AUTO_AUTHOR_LOG"; then
    pass "AC7 audit log carries consult/reject + no generate/apply"
  else
    fail "AC7 reject path leaked generate/apply to audit log"
    cat "$AUTO_AUTHOR_LOG" >&2
  fi
else
  fail "AC7 audit log missing consult/reject for surface"
  cat "$AUTO_AUTHOR_LOG" >&2
fi

# --- AC9: real-T-6 round-trip → Stage 2.5 → real review-gate ---

# Step 1: write a synthetic propose-taxonomy-output.json (propose-taxonomy/1).
# Minimal valid instance to exercise T-6 import-plan.py end-to-end.
PT_OUT="$T7_TEST_DIR/state/propose-taxonomy-output.json"
mkdir -p "$T7_TEST_DIR/state"
cat > "$PT_OUT" <<'EOF'
{
  "schema_version": "propose-taxonomy/1",
  "llm_mode": "stub",
  "embedding_mode_input": "stub",
  "n_records": 4,
  "n_clusters_input": 2,
  "passes": [
    {
      "pass": 1,
      "model": "stub",
      "n_candidates_proposed": 2,
      "n_items_mapped": 4,
      "duration_ms": 5
    },
    {
      "pass": 2,
      "model": "stub",
      "n_candidates_proposed": 2,
      "n_items_mapped": 4,
      "duration_ms": 3,
      "merge_split_ops": []
    }
  ],
  "n_passes": 2,
  "items_mapped_pct": 1.0,
  "small_corpus_input": false,
  "candidates": [
    {
      "candidate_id": "p0001",
      "label": "Acme",
      "type": "project",
      "proposed_path": "Engagements/Acme",
      "metadata": {"summary": "Acme work", "tags": ["engagement/acme"]},
      "source_items": [
        {"path": "doc1.md", "source_hash": "sha256-aaaaaaaa"},
        {"path": "doc2.md", "source_hash": "sha256-bbbbbbbb"}
      ],
      "confidence": 0.95,
      "low_confidence": false
    },
    {
      "candidate_id": "p0002",
      "label": "policies",
      "type": "reference",
      "proposed_path": "References/policies",
      "metadata": {"summary": "policy refs"},
      "source_items": [
        {"path": "policy1.md", "source_hash": "sha256-cccccccc"},
        {"path": "policy2.md", "source_hash": "sha256-dddddddd"}
      ],
      "confidence": 0.88,
      "low_confidence": false
    }
  ]
}
EOF

# Step 2: run real T-6 import-plan.sh.
T6_OUT="$T7_TEST_DIR/state/import-plan.md"
"$IMPORT_PLAN_SH" --propose-taxonomy "$PT_OUT" --out "$T6_OUT" \
  --generated-at "2026-05-04T22:30:00Z" >"$T7_TEST_DIR/t6.out" 2>"$T7_TEST_DIR/t6.err"
t6_rc=$?
if [ "$t6_rc" = "0" ] && [ -s "$T6_OUT" ] && grep -q "^schema_version: import-plan/1$" "$T6_OUT"; then
  pass "AC9.1 real T-6 import-plan.sh produced import-plan/1 plan"
else
  fail "AC9.1 T-6 invocation failed: rc=$t6_rc"
  head -10 "$T6_OUT" >&2 2>/dev/null || true
  cat "$T7_TEST_DIR/t6.err" >&2 || true
  exit 1
fi

# Step 3: run Stage 2.5 (auto-apply) against real T-6 output.
T25_OUT="$T7_TEST_DIR/state/consulted-import-plan.md"
> "$AUTO_AUTHOR_LOG"
"$STAGE25" --import-plan "$T6_OUT" --out "$T25_OUT" --auto-apply \
  >"$T7_TEST_DIR/t25.out" 2>"$T7_TEST_DIR/t25.err"
t25_rc=$?
if [ "$t25_rc" = "0" ] && [ -s "$T25_OUT" ] && \
   grep -q "^schema_version: import-plan/1$" "$T25_OUT" && \
   grep -qE "^consulted_at: [0-9]{4}-" "$T25_OUT" && \
   grep -qE "^consultation_response_hash: [a-f0-9]{64}$" "$T25_OUT"; then
  pass "AC9.2 Stage 2.5 consumed real-T-6 output + emitted consulted plan with provenance"
else
  fail "AC9.2 Stage 2.5 invocation failed: rc=$t25_rc"
  head -25 "$T25_OUT" >&2 2>/dev/null || true
  cat "$T7_TEST_DIR/t25.err" | tail -10 >&2 || true
  exit 1
fi

# Step 4: real SP13 T-7 review-gate.sh consumes the consulted plan.
APPROVED_OUT="$T7_TEST_DIR/state/approved-import-plan.md"
"$REVIEW_GATE_SH" \
  --import-plan "$T25_OUT" \
  --approved-out "$APPROVED_OUT" \
  --gate-lib "$REPO_ROOT/onboarding/lib/three-step-gate.sh" \
  --accept-on-eof \
  >"$T7_TEST_DIR/rg.out" 2>"$T7_TEST_DIR/rg.err" </dev/null
rg_rc=$?
if [ "$rg_rc" = "0" ] && [ -s "$APPROVED_OUT" ] && \
   grep -q "^schema_version: import-plan/1$" "$APPROVED_OUT" && \
   grep -qE "^consulted_at: " "$APPROVED_OUT" && \
   grep -qE "^consultation_response_hash: " "$APPROVED_OUT"; then
  pass "AC9.3 real review-gate.sh consumed consulted plan + emitted approved-import-plan.md preserving provenance"
else
  fail "AC9.3 review-gate.sh failed: rc=$rg_rc"
  head -30 "$APPROVED_OUT" >&2 2>/dev/null || true
  tail -15 "$T7_TEST_DIR/rg.err" >&2 || true
  exit 1
fi

# --- summary ---

printf '\n=== SP15 T-7 acceptance summary ===\n'
printf 'PASS: %d\n' "$PASS_COUNT"
printf 'FAIL: %d\n' "$FAIL_COUNT"
if [ "$FAIL_COUNT" = "0" ]; then
  printf 'OVERALL: GREEN\n'
  exit 0
else
  printf 'OVERALL: RED\n'
  exit 1
fi
