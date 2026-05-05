#!/usr/bin/env bash
# tests/consultation-gate/t5-surface-4-consultation-test.sh — SP15 T-5 acceptance
#
# Synthetic fixture test verifying SP15 T-5 (Surface-4 tag-prefixes
# consultation retrofit) acceptance criteria. Hermetic tmpdir per
# `feedback_test_isolation_for_hooks_state`; parallel test vault per
# `feedback_universal_vault_safety` (NEVER touches ~/Documents/Obsidian
# Vault production).
#
# Acceptance criteria covered:
#   AC1 — Surface-4 never proposes >9 top-level prefixes regardless of
#         input. Verified across 4 archetypes (consultant / researcher /
#         operator / custom) AND an "evil" 12-prefix synthetic fixture.
#         Audit-log ordering: consult < generate < apply per surface.
#   AC2 — Rationale emits all 5 citations with URLs (Cowan, Forte,
#         Luhmann, Ahrens, Matrixflows).
#   AC3 — Per-archetype proposals match documented 5-prefix templates;
#         no archetype crosstalk (each archetype's WHY-FOR-YOU marker is
#         present, other archetypes' markers are absent).
#   AC4 — User-reject → zero `_tag_prefixes[]` write to either target
#         (canonical AND mirror unchanged); no generate/apply records
#         on reject path.
#   AC5 — User-accept → standard 3-step gate fires on canonical
#         (vault-schema.json) + provenance JSONL records (sidecar) carry
#         consulted_at + consultation_response_hash fields. Mirror is
#         lockstep with canonical post-accept.
#   AC6 — R-23 bash 3.2.57 lint clean on surface-4 + this test file.
#
# Plus an edge-case: no-op re-run does NOT fire the consultation gate
# (preserves UX of pre-T-5 short-circuit).
#
# CONSTRAINTS (R-23): bash 3.2.57; jq required.
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP15 Session 5 (T-5)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SURFACE="$REPO_ROOT/onboarding/auto-author/surface-4-tag-prefixes.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS — %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL — %s\n' "$1" >&2; }

# --- AC6: R-23 lint pass (cheap; runs first so a syntax break aborts early) ---

for f in \
  "$SURFACE" \
  "$0"; do
  if /bin/bash -n "$f" >/dev/null 2>&1 && bash --posix -n "$f" >/dev/null 2>&1; then
    pass "AC6 R-23 lint clean: $(basename "$f")"
  else
    fail "AC6 R-23 lint FAILED: $f"
    /bin/bash -n "$f" 2>&1 | head -5 >&2
    bash --posix -n "$f" 2>&1 | head -5 >&2
    exit 1
  fi
done

# --- Hermetic test sandbox ---
# CLAUDE_HOME under tmpdir per feedback_test_isolation_for_hooks_state.
# Test vault under tmpdir per feedback_universal_vault_safety. Audit log,
# stage dir, allowlist all isolated.

T5_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/consultation-surface-4-$$.XXXXXX")"
trap 'rm -rf "$T5_TEST_DIR" 2>/dev/null' EXIT INT TERM

export CLAUDE_HOME="$T5_TEST_DIR/claude"
export HOOKS_STATE_OVERRIDE="$CLAUDE_HOME/state"
export AUTO_AUTHOR_LOG="$T5_TEST_DIR/audit.jsonl"
export TG_STAGE_DIR="$T5_TEST_DIR/stage"
export EDITOR=":"
mkdir -p "$CLAUDE_HOME/schemas" "$CLAUDE_HOME/onboarding/audit" \
  "$HOOKS_STATE_OVERRIDE" "$TG_STAGE_DIR" \
  "$T5_TEST_DIR/vault"

# Production allowlist contains surface-4-tag-prefixes so we don't need
# to override CG_ALLOWLIST_PATH; defaults will resolve fine.

# --- Manifest fixture writer ---

write_manifest() {
  # $1=manifest_path $2=archetype $3=prefix_list_json
  cat > "$1" <<JSON
{
  "identity": {
    "name": "Test User",
    "role": "Tester",
    "industry": "Testing",
    "organization": "(test)"
  },
  "vault": {
    "root": "$T5_TEST_DIR/vault",
    "organizational_method": "engagement-based",
    "top_level_folder": "Engagements",
    "default_audience": "claude",
    "tag_prefix_archetype": "$2",
    "tag_prefixes": $3,
    "canonical_file_types": ["meeting-note"]
  },
  "paths": {
    "vault_root": "$T5_TEST_DIR/vault"
  }
}
JSON
}

# --- Vault schema fixture writer ---

write_vault_schema() {
  # $1=schema_path $2=existing_prefixes_json
  cat > "$1" <<JSON
{
  "_tag_prefixes": $2,
  "_canonical_file_types": ["meeting-note"]
}
JSON
}

# --- Per-archetype accept-path test driver ---

run_accept_archetype() {
  # $1=archetype_label $2=expected_prefix_count
  local label="$1" expected_count="$2"
  local manifest="$T5_TEST_DIR/manifest-${label}.json"
  local schema="$T5_TEST_DIR/schema-${label}.json"
  local plog="$T5_TEST_DIR/provenance-${label}.jsonl"
  local stderr_capture="$T5_TEST_DIR/stderr-${label}.log"

  write_manifest "$manifest" "$label" '[]'
  write_vault_schema "$schema" '[]'
  : > "$AUTO_AUTHOR_LOG"
  : > "$plog"

  bash "$SURFACE" \
    --user-manifest "$manifest" \
    --vault-schema "$schema" \
    --provenance-log "$plog" \
    --auto-apply \
    > "$stderr_capture.stdout" 2> "$stderr_capture" \
    || {
      fail "[$label] surface-4 invocation rc=$? — see $stderr_capture"
      return 1
    }

  # AC5: canonical (vault-schema) written; mirror (user-manifest) lockstep.
  local got_canonical got_mirror
  got_canonical="$(jq -c '._tag_prefixes' "$schema")"
  got_mirror="$(jq -c '.vault.tag_prefixes' "$manifest")"

  if [ "$got_canonical" != "[]" ] && [ "$got_canonical" != "null" ]; then
    pass "[$label] AC5 — canonical _tag_prefixes written: $got_canonical"
  else
    fail "[$label] AC5 — canonical _tag_prefixes empty: $got_canonical"
  fi
  if [ "$got_canonical" = "$got_mirror" ]; then
    pass "[$label] AC5 — mirror lockstep with canonical"
  else
    fail "[$label] AC5 — mirror diverges (canonical=$got_canonical mirror=$got_mirror)"
  fi

  # AC1: prefix count ≤9.
  local cnt
  cnt="$(printf '%s' "$got_canonical" | jq -r 'length')"
  if [ "$cnt" -le 9 ]; then
    pass "[$label] AC1 — prefix count $cnt ≤ 9 (cap satisfied)"
  else
    fail "[$label] AC1 — prefix count $cnt > 9 (CAP BREACH)"
  fi
  # AC3: prefix count matches the spec-documented per-archetype template.
  if [ "$cnt" = "$expected_count" ]; then
    pass "[$label] AC3 — prefix count matches expected $expected_count"
  else
    fail "[$label] AC3 — prefix count $cnt != expected $expected_count"
  fi

  # AC1 (audit ordering): consult < generate < apply for our surface_id.
  local consult_line generate_line apply_line
  consult_line="$(grep -n '"action":"consult"' "$AUTO_AUTHOR_LOG" | grep '"surface_id":"surface-4-tag-prefixes"' | head -1 | cut -d: -f1)"
  generate_line="$(grep -n '"action":"generate"' "$AUTO_AUTHOR_LOG" | grep '"surface_id":"surface-4-tag-prefixes"' | head -1 | cut -d: -f1)"
  apply_line="$(grep -n '"action":"apply"' "$AUTO_AUTHOR_LOG" | grep '"surface_id":"surface-4-tag-prefixes"' | head -1 | cut -d: -f1)"
  if [ -n "$consult_line" ] && [ -n "$generate_line" ] && [ -n "$apply_line" ] \
    && [ "$consult_line" -lt "$generate_line" ] \
    && [ "$generate_line" -lt "$apply_line" ]; then
    pass "[$label] AC1 — consult($consult_line) < generate($generate_line) < apply($apply_line)"
  else
    fail "[$label] AC1 — audit ordering wrong (consult=$consult_line generate=$generate_line apply=$apply_line)"
  fi

  # AC2: ≥5 PKM/IA citations rendered to stderr.
  local cite_count=0
  grep -q 'Cowan' "$stderr_capture" && cite_count=$((cite_count + 1))
  grep -q 'Forte' "$stderr_capture" && cite_count=$((cite_count + 1))
  grep -q 'Luhmann' "$stderr_capture" && cite_count=$((cite_count + 1))
  grep -q 'Ahrens' "$stderr_capture" && cite_count=$((cite_count + 1))
  grep -q 'Matrixflows' "$stderr_capture" && cite_count=$((cite_count + 1))
  if [ "$cite_count" -ge 5 ]; then
    pass "[$label] AC2 — $cite_count/5 PKM/IA citations rendered"
  else
    fail "[$label] AC2 — only $cite_count citations (need ≥5)"
  fi

  # AC2: citation URLs present (one per source).
  local url_count=0
  grep -q 'cambridge.org/core/journals/behavioral-and-brain-sciences' "$stderr_capture" && url_count=$((url_count + 1))
  grep -q 'fortelabs.com/blog/para' "$stderr_capture" && url_count=$((url_count + 1))
  grep -q 'zettelkasten.de/overview' "$stderr_capture" && url_count=$((url_count + 1))
  grep -q 'soenkeahrens.de' "$stderr_capture" && url_count=$((url_count + 1))
  grep -q 'matrixflows.com/blog/knowledge-base-taxonomy' "$stderr_capture" && url_count=$((url_count + 1))
  if [ "$url_count" -ge 5 ]; then
    pass "[$label] AC2 — $url_count/5 citation URLs present"
  else
    fail "[$label] AC2 — only $url_count/5 citation URLs"
  fi

  # AC3: archetype-specific WHY-FOR-YOU reasoning, no crosstalk. Each
  # archetype's WHY-FOR-YOU body carries a distinctive single-line marker
  # phrase. Crosstalk check verifies the OTHER archetypes' markers are
  # absent. (Markers chosen to NOT appear in the alternatives block.)
  case "$label" in
    consultant)
      if grep -q 'extend across engagement boundaries' "$stderr_capture" \
        && ! grep -q 'topic/ is the primary backbone' "$stderr_capture" \
        && ! grep -q 'incident/ is incident-specific' "$stderr_capture" \
        && ! grep -q 'If your work follows a stronger pattern' "$stderr_capture"; then
        pass "[consultant] AC3 — consultant reasoning present, no crosstalk"
      else
        fail "[consultant] AC3 — archetype crosstalk or missing reasoning"
      fi
      ;;
    researcher)
      if grep -q 'topic/ is the primary backbone' "$stderr_capture" \
        && ! grep -q 'extend across engagement boundaries' "$stderr_capture" \
        && ! grep -q 'incident/ is incident-specific' "$stderr_capture" \
        && ! grep -q 'If your work follows a stronger pattern' "$stderr_capture"; then
        pass "[researcher] AC3 — researcher reasoning present, no crosstalk"
      else
        fail "[researcher] AC3 — archetype crosstalk or missing reasoning"
      fi
      ;;
    operator)
      if grep -q 'incident/ is incident-specific' "$stderr_capture" \
        && ! grep -q 'extend across engagement boundaries' "$stderr_capture" \
        && ! grep -q 'topic/ is the primary backbone' "$stderr_capture" \
        && ! grep -q 'If your work follows a stronger pattern' "$stderr_capture"; then
        pass "[operator] AC3 — operator reasoning present, no crosstalk"
      else
        fail "[operator] AC3 — archetype crosstalk or missing reasoning"
      fi
      ;;
    custom)
      if grep -q 'If your work follows a stronger pattern' "$stderr_capture" \
        && ! grep -q 'extend across engagement boundaries' "$stderr_capture" \
        && ! grep -q 'topic/ is the primary backbone' "$stderr_capture" \
        && ! grep -q 'incident/ is incident-specific' "$stderr_capture"; then
        pass "[custom] AC3 — custom reasoning present, no crosstalk"
      else
        fail "[custom] AC3 — archetype crosstalk or missing reasoning"
      fi
      ;;
  esac

  # AC5: provenance JSONL carries consulted_at + consultation_response_hash.
  local plog_records
  plog_records="$(wc -l < "$plog" | tr -d ' ')"
  if [ "$plog_records" -ge 2 ]; then
    pass "[$label] AC5 — provenance JSONL has $plog_records records (≥2)"
  else
    fail "[$label] AC5 — provenance JSONL has $plog_records records (need ≥2)"
  fi
  if grep -Eq '"consulted_at":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "$plog"; then
    pass "[$label] AC5 — provenance JSONL carries consulted_at (ISO-8601 UTC)"
  else
    fail "[$label] AC5 — consulted_at missing/malformed from provenance JSONL"
  fi
  if grep -Eq '"consultation_response_hash":"[a-f0-9]{64}"' "$plog"; then
    pass "[$label] AC5 — provenance JSONL carries consultation_response_hash (sha256-hex)"
  else
    fail "[$label] AC5 — consultation_response_hash missing/malformed"
  fi
}

# --- Reject-path test driver (AC4) ---

run_reject_path() {
  local label="reject-consultant"
  local manifest="$T5_TEST_DIR/manifest-${label}.json"
  local schema="$T5_TEST_DIR/schema-${label}.json"
  local plog="$T5_TEST_DIR/provenance-${label}.jsonl"
  local stderr_capture="$T5_TEST_DIR/stderr-${label}.log"

  write_manifest "$manifest" "consultant" '[]'
  write_vault_schema "$schema" '[]'
  : > "$AUTO_AUTHOR_LOG"
  : > "$plog"

  printf 'r\n' | bash "$SURFACE" \
    --user-manifest "$manifest" \
    --vault-schema "$schema" \
    --provenance-log "$plog" \
    > "$stderr_capture.stdout" 2> "$stderr_capture"
  local rc=$?

  if [ "$rc" = "1" ]; then
    pass "[$label] surface-4 rc=1 on reject (expected)"
  else
    fail "[$label] surface-4 rc=$rc on reject (expected 1) — see $stderr_capture"
  fi

  # AC4: zero canonical write.
  local got_canonical
  got_canonical="$(jq -c '._tag_prefixes' "$schema")"
  if [ "$got_canonical" = "[]" ]; then
    pass "[$label] AC4 — canonical _tag_prefixes unchanged (still [])"
  else
    fail "[$label] AC4 — canonical was modified on reject path: $got_canonical"
  fi
  # AC4: zero mirror write.
  local got_mirror
  got_mirror="$(jq -c '.vault.tag_prefixes' "$manifest")"
  if [ "$got_mirror" = "[]" ]; then
    pass "[$label] AC4 — mirror unchanged (still [])"
  else
    fail "[$label] AC4 — mirror was modified on reject path: $got_mirror"
  fi
  # AC4: audit log records consult/reject; no generate/apply records.
  if grep -q '"action":"consult"' "$AUTO_AUTHOR_LOG" && grep -q '"response":"reject"' "$AUTO_AUTHOR_LOG"; then
    pass "[$label] AC4 — consult/reject record present"
  else
    fail "[$label] AC4 — no consult/reject record in audit log"
  fi
  if grep '"surface_id":"surface-4-tag-prefixes"' "$AUTO_AUTHOR_LOG" | grep -q '"action":"generate"'; then
    fail "[$label] AC4 — generate record present on reject path (BREACH)"
  else
    pass "[$label] AC4 — no generate record on reject path"
  fi
  if grep '"surface_id":"surface-4-tag-prefixes"' "$AUTO_AUTHOR_LOG" | grep -q '"action":"apply"'; then
    fail "[$label] AC4 — apply record present on reject path (BREACH)"
  else
    pass "[$label] AC4 — no apply record on reject path"
  fi
}

# --- "Evil" 12-prefix cap test (AC1 stress) ---

run_evil_cap() {
  local label="evil-12-prefix"
  local manifest="$T5_TEST_DIR/manifest-${label}.json"
  local schema="$T5_TEST_DIR/schema-${label}.json"
  local plog="$T5_TEST_DIR/provenance-${label}.jsonl"
  local stderr_capture="$T5_TEST_DIR/stderr-${label}.log"

  # Use consultant archetype as base so the rationale renders cleanly,
  # but inject a 12-prefix payload via --evil-prefix-list. The cap MUST
  # fire structurally regardless of the archetype seed.
  write_manifest "$manifest" "consultant" '[]'
  write_vault_schema "$schema" '[]'
  : > "$AUTO_AUTHOR_LOG"
  : > "$plog"

  bash "$SURFACE" \
    --user-manifest "$manifest" \
    --vault-schema "$schema" \
    --provenance-log "$plog" \
    --evil-prefix-list 'a/,b/,c/,d/,e/,f/,g/,h/,i/,j/,k/,l/' \
    --auto-apply \
    > "$stderr_capture.stdout" 2> "$stderr_capture" \
    || {
      fail "[$label] surface-4 invocation rc=$? — see $stderr_capture"
      return 1
    }

  local got_canonical cnt
  got_canonical="$(jq -c '._tag_prefixes' "$schema")"
  cnt="$(printf '%s' "$got_canonical" | jq -r 'length')"
  if [ "$cnt" -le 9 ]; then
    pass "[$label] AC1 — 12-prefix evil fixture capped to $cnt ≤ 9"
  else
    fail "[$label] AC1 — 12-prefix evil fixture not capped (got $cnt) — CAP BREACH"
  fi
  # Mirror should also be capped (lockstep).
  local got_mirror cnt_m
  got_mirror="$(jq -c '.vault.tag_prefixes' "$manifest")"
  cnt_m="$(printf '%s' "$got_mirror" | jq -r 'length')"
  if [ "$cnt_m" -le 9 ]; then
    pass "[$label] AC1 — mirror also capped to $cnt_m ≤ 9"
  else
    fail "[$label] AC1 — mirror not capped (got $cnt_m)"
  fi
}

# --- No-op re-run edge case (UX preservation) ---

run_noop_rerun() {
  local label="noop-rerun"
  local manifest="$T5_TEST_DIR/manifest-${label}.json"
  local schema="$T5_TEST_DIR/schema-${label}.json"
  local plog="$T5_TEST_DIR/provenance-${label}.jsonl"
  local stderr_capture="$T5_TEST_DIR/stderr-${label}.log"
  # Pre-fill both targets with the consultant 5-prefix template (sorted
  # to match jq unique's lexicographic output).
  local prefilled='["engagement/","person/","project/","scope/","topic/"]'

  write_manifest "$manifest" "consultant" "$prefilled"
  write_vault_schema "$schema" "$prefilled"
  : > "$AUTO_AUTHOR_LOG"
  : > "$plog"

  # No --auto-apply needed — pre-flight short-circuit returns 0 without
  # firing the consultation gate.
  bash "$SURFACE" \
    --user-manifest "$manifest" \
    --vault-schema "$schema" \
    --provenance-log "$plog" \
    > "$stderr_capture.stdout" 2> "$stderr_capture"
  local rc=$?

  if [ "$rc" = "0" ]; then
    pass "[$label] no-op re-run rc=0"
  else
    fail "[$label] no-op re-run rc=$rc (expected 0)"
  fi
  # No consultation gate fires on no-op (UX preservation).
  if grep '"surface_id":"surface-4-tag-prefixes"' "$AUTO_AUTHOR_LOG" | grep -q '"action":"consult"'; then
    fail "[$label] no-op fired consultation gate (UX regression)"
  else
    pass "[$label] no-op did NOT fire consultation gate"
  fi
  # Both targets unchanged.
  local got_canonical got_mirror
  got_canonical="$(jq -c '._tag_prefixes' "$schema")"
  got_mirror="$(jq -c '.vault.tag_prefixes' "$manifest")"
  if [ "$got_canonical" = "$prefilled" ] && [ "$got_mirror" = "$prefilled" ]; then
    pass "[$label] both targets unchanged on no-op"
  else
    fail "[$label] targets changed on no-op (canonical=$got_canonical mirror=$got_mirror)"
  fi
}

# --- Drive ---

printf '\n=== SP15 T-5 acceptance test ===\n'
printf 'sandbox: %s\n' "$T5_TEST_DIR"
printf 'audit:   %s\n\n' "$AUTO_AUTHOR_LOG"

# 4 archetypes × {AC1 audit ordering + cap, AC2 citations + URLs, AC3
# archetype reasoning + no crosstalk, AC5 canonical + mirror writes +
# provenance fields}.
run_accept_archetype "consultant" 5
run_accept_archetype "researcher" 5
run_accept_archetype "operator"   5
run_accept_archetype "custom"     4

# Reject path × AC4 (rc=1, both targets unchanged, no generate/apply).
run_reject_path

# AC1 stress: 12-prefix evil fixture must collapse to ≤9.
run_evil_cap

# Edge case: no-op re-run preserves pre-T-5 short-circuit UX.
run_noop_rerun

# --- Summary ---

printf '\n=== summary ===\n'
printf 'PASS: %s\n' "$PASS_COUNT"
printf 'FAIL: %s\n' "$FAIL_COUNT"
if [ "$FAIL_COUNT" = "0" ]; then
  printf 'OVERALL: GREEN\n'
  exit 0
else
  printf 'OVERALL: RED\n' >&2
  exit 1
fi
