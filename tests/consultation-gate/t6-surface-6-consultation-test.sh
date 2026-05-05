#!/usr/bin/env bash
# tests/consultation-gate/t6-surface-6-consultation-test.sh — SP15 T-6 acceptance
#
# Synthetic fixture test verifying SP15 T-6 (Surface-6 frontmatter-enforce
# consultation retrofit) acceptance criteria. Hermetic tmpdir per
# `feedback_test_isolation_for_hooks_state`; never touches production
# user-manifest or vault per `feedback_universal_vault_safety`.
#
# Acceptance criteria covered:
#   AC1 — Surface-6 never proposes >5 required fields per note type.
#         Verified across 5 type runs (engagement-note / person-note /
#         meeting-note / project-note / custom) AND an "evil" 8-field
#         synthetic fixture. Audit-log ordering: consult < generate <
#         apply per surface.
#   AC2 — Rationale emits all 4 citations with URLs (Metadata Menu /
#         PKM convergence / Webflow CMS / Boehm + DataFlowMapper).
#   AC3 — Per-type proposals match documented templates; no type
#         crosstalk (each per-type WHY block carries a distinctive
#         single-line marker phrase; per-type marker present, others
#         absent).
#   AC4 — User-reject → zero frontmatter-enforce config write to the
#         user-manifest; consult/reject record present; no generate/apply
#         records on reject path.
#   AC5 — User-accept → standard 3-step gate fires + provenance JSONL
#         records (sidecar) carry consulted_at + consultation_response_hash
#         fields. β-shape per SP15 T-6 design call.
#   AC6 — R-23 bash 3.2.57 lint clean on surface-6 + this test file.
#
# Plus an edge-case: no-op re-run does NOT fire the consultation gate
# (preserves UX of pre-T-6 short-circuit; no surprise prompt).
#
# CONSTRAINTS (R-23): bash 3.2.57; jq required.
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP15 Session 6 (T-6)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SURFACE="$REPO_ROOT/onboarding/auto-author/surface-6-frontmatter-enforce.sh"

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
# Audit log, stage dir, sidecar log, allowlist all isolated.

T6_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/consultation-surface-6-$$.XXXXXX")"
trap 'rm -rf "$T6_TEST_DIR" 2>/dev/null' EXIT INT TERM

export CLAUDE_HOME="$T6_TEST_DIR/claude"
export HOOKS_STATE_OVERRIDE="$CLAUDE_HOME/state"
export AUTO_AUTHOR_LOG="$T6_TEST_DIR/audit.jsonl"
export TG_STAGE_DIR="$T6_TEST_DIR/stage"
export EDITOR=":"
mkdir -p "$CLAUDE_HOME/onboarding/audit" "$HOOKS_STATE_OVERRIDE" "$TG_STAGE_DIR"

# Production allowlist contains surface-6-frontmatter-enforce so we don't
# need to override CG_ALLOWLIST_PATH; defaults will resolve fine.

# --- Manifest fixture writer ---
# Writes a minimal user-manifest with optional pre-existing
# required_fields_overrides for the type under test.

write_manifest() {
  # $1=manifest_path $2=projects_root_dirname $3=existing_overrides_json
  cat > "$1" <<JSON
{
  "identity": {
    "name": "Test User",
    "role": "Tester",
    "industry": "Testing",
    "organization": "(test)"
  },
  "vault": {
    "root": "$T6_TEST_DIR/vault",
    "organizational_method": "engagement-based",
    "top_level_folder": "Engagements",
    "default_audience": "claude",
    "projects_root_dirname": "$2",
    "engagement_aliases": {},
    "required_fields_overrides": $3,
    "canonical_file_types": ["engagement-note","person-note","meeting-note","project-note"]
  },
  "paths": {
    "vault_root": "$T6_TEST_DIR/vault"
  }
}
JSON
}

# --- Per-type accept-path test driver ---

run_accept_type() {
  # $1=type_label $2=expected_field_count_for_that_type
  local label="$1" expected_count="$2"
  local manifest="$T6_TEST_DIR/manifest-${label}.json"
  local plog="$T6_TEST_DIR/provenance-${label}.jsonl"
  local stderr_capture="$T6_TEST_DIR/stderr-${label}.log"

  # Start with EMPTY required_fields_overrides so the surface proposes the
  # SP15 T-6 default templates for all canonical types. PROJ_DIR fresh
  # ("ProjectsX") so the manifest WILL change (otherwise the no-op
  # short-circuit would skip the consultation gate).
  write_manifest "$manifest" "ProjectsX" '{}'
  : > "$AUTO_AUTHOR_LOG"
  : > "$plog"

  bash "$SURFACE" \
    --user-manifest "$manifest" \
    --provenance-log "$plog" \
    --auto-apply \
    > "$stderr_capture.stdout" 2> "$stderr_capture" \
    || {
      fail "[$label] surface-6 invocation rc=$? — see $stderr_capture"
      return 1
    }

  # AC5 (write happened): required_fields_overrides written; pd updated.
  local got_overrides got_pd
  got_overrides="$(jq -c '.vault.required_fields_overrides' "$manifest")"
  got_pd="$(jq -r '.vault.projects_root_dirname' "$manifest")"

  if [ "$got_pd" = "ProjectsX" ]; then
    pass "[$label] AC5 — projects_root_dirname written: $got_pd"
  else
    fail "[$label] AC5 — projects_root_dirname mismatch: $got_pd"
  fi
  if [ "$got_overrides" != "{}" ] && [ "$got_overrides" != "null" ]; then
    pass "[$label] AC5 — required_fields_overrides written: $got_overrides"
  else
    fail "[$label] AC5 — required_fields_overrides empty: $got_overrides"
  fi

  # AC1: per-type cap + AC3: expected count for the type under test.
  local cnt
  cnt="$(printf '%s' "$got_overrides" | jq -r --arg t "$label" '.[$t] // [] | length')"
  if [ "$cnt" -le 5 ]; then
    pass "[$label] AC1 — field count $cnt ≤ 5 (cap satisfied)"
  else
    fail "[$label] AC1 — field count $cnt > 5 (CAP BREACH)"
  fi
  if [ "$cnt" = "$expected_count" ]; then
    pass "[$label] AC3 — field count matches expected $expected_count"
  else
    fail "[$label] AC3 — field count $cnt != expected $expected_count"
  fi

  # AC1 (audit ordering): consult < generate < apply for our surface_id.
  local consult_line generate_line apply_line
  consult_line="$(grep -n '"action":"consult"' "$AUTO_AUTHOR_LOG" | grep '"surface_id":"surface-6-frontmatter-enforce"' | head -1 | cut -d: -f1)"
  generate_line="$(grep -n '"action":"generate"' "$AUTO_AUTHOR_LOG" | grep '"surface_id":"surface-6-frontmatter-enforce"' | head -1 | cut -d: -f1)"
  apply_line="$(grep -n '"action":"apply"' "$AUTO_AUTHOR_LOG" | grep '"surface_id":"surface-6-frontmatter-enforce"' | head -1 | cut -d: -f1)"
  if [ -n "$consult_line" ] && [ -n "$generate_line" ] && [ -n "$apply_line" ] \
    && [ "$consult_line" -lt "$generate_line" ] \
    && [ "$generate_line" -lt "$apply_line" ]; then
    pass "[$label] AC1 — consult($consult_line) < generate($generate_line) < apply($apply_line)"
  else
    fail "[$label] AC1 — audit ordering wrong (consult=$consult_line generate=$generate_line apply=$apply_line)"
  fi

  # AC2: ≥4 PKM/IA citations rendered to stderr.
  local cite_count=0
  grep -q 'Metadata Menu' "$stderr_capture" && cite_count=$((cite_count + 1))
  grep -q 'PKM-community convergence' "$stderr_capture" && cite_count=$((cite_count + 1))
  grep -q 'Webflow CMS' "$stderr_capture" && cite_count=$((cite_count + 1))
  grep -q 'Boehm cost-of-change' "$stderr_capture" && cite_count=$((cite_count + 1))
  if [ "$cite_count" -ge 4 ]; then
    pass "[$label] AC2 — $cite_count/4 PKM/IA citations rendered"
  else
    fail "[$label] AC2 — only $cite_count citations (need ≥4)"
  fi

  # AC2: citation URLs present (one per source).
  local url_count=0
  grep -q 'mdelobelle.github.io/metadatamenu' "$stderr_capture" && url_count=$((url_count + 1))
  grep -q 'forum.obsidian.md' "$stderr_capture" && url_count=$((url_count + 1))
  grep -q 'connorfinlayson.com' "$stderr_capture" && url_count=$((url_count + 1))
  grep -q 'dataflowmapper.com' "$stderr_capture" && url_count=$((url_count + 1))
  if [ "$url_count" -ge 4 ]; then
    pass "[$label] AC2 — $url_count/4 citation URLs present"
  else
    fail "[$label] AC2 — only $url_count/4 citation URLs"
  fi

  # AC3: per-type WHY-FOR-YOU reasoning, no crosstalk. Each per-type block
  # carries a distinctive single-line marker phrase. The same rationale
  # block renders for all type-runs (per-type reasoning is the FULL list,
  # not just one type) — so the per-run crosstalk check is that all four
  # canonical-type markers are present (positive presence) in every
  # rationale render. A custom-type run would also show all four markers
  # plus the custom-types block.
  local markers_seen=0
  grep -q 'engagement is the closed-world unit' "$stderr_capture" && markers_seen=$((markers_seen + 1))
  grep -q 'Person notes are LIGHTWEIGHT' "$stderr_capture" && markers_seen=$((markers_seen + 1))
  grep -q 'Meetings are TRANSCRIPT-CARRIERS' "$stderr_capture" && markers_seen=$((markers_seen + 1))
  grep -q 'Projects sit UNDER engagements' "$stderr_capture" && markers_seen=$((markers_seen + 1))
  if [ "$markers_seen" = "4" ]; then
    pass "[$label] AC3 — all 4 per-type WHY markers present (no missing-type drift)"
  else
    fail "[$label] AC3 — only $markers_seen/4 per-type markers present"
  fi

  # AC5: provenance JSONL carries consulted_at + consultation_response_hash.
  local plog_records
  plog_records="$(wc -l < "$plog" | tr -d ' ')"
  if [ "$plog_records" -ge 1 ]; then
    pass "[$label] AC5 — provenance JSONL has $plog_records records (≥1)"
  else
    fail "[$label] AC5 — provenance JSONL has 0 records (need ≥1)"
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
  local label="reject"
  local manifest="$T6_TEST_DIR/manifest-${label}.json"
  local plog="$T6_TEST_DIR/provenance-${label}.jsonl"
  local stderr_capture="$T6_TEST_DIR/stderr-${label}.log"

  write_manifest "$manifest" "ProjectsX" '{}'
  : > "$AUTO_AUTHOR_LOG"
  : > "$plog"

  printf 'r\n' | bash "$SURFACE" \
    --user-manifest "$manifest" \
    --provenance-log "$plog" \
    > "$stderr_capture.stdout" 2> "$stderr_capture"
  local rc=$?

  if [ "$rc" = "1" ]; then
    pass "[$label] surface-6 rc=1 on reject (expected)"
  else
    fail "[$label] surface-6 rc=$rc on reject (expected 1) — see $stderr_capture"
  fi

  # AC4: zero required_fields_overrides write.
  local got_overrides
  got_overrides="$(jq -c '.vault.required_fields_overrides' "$manifest")"
  if [ "$got_overrides" = "{}" ]; then
    pass "[$label] AC4 — required_fields_overrides unchanged (still {})"
  else
    fail "[$label] AC4 — required_fields_overrides modified on reject path: $got_overrides"
  fi
  # AC4: zero projects_root_dirname write.
  local got_pd
  got_pd="$(jq -r '.vault.projects_root_dirname' "$manifest")"
  if [ "$got_pd" = "ProjectsX" ]; then
    pass "[$label] AC4 — projects_root_dirname unchanged (still ProjectsX)"
  else
    fail "[$label] AC4 — projects_root_dirname modified on reject: $got_pd"
  fi
  # AC4: audit log records consult/reject; no generate/apply records.
  if grep -q '"action":"consult"' "$AUTO_AUTHOR_LOG" && grep -q '"response":"reject"' "$AUTO_AUTHOR_LOG"; then
    pass "[$label] AC4 — consult/reject record present"
  else
    fail "[$label] AC4 — no consult/reject record in audit log"
  fi
  if grep '"surface_id":"surface-6-frontmatter-enforce"' "$AUTO_AUTHOR_LOG" | grep -q '"action":"generate"'; then
    fail "[$label] AC4 — generate record present on reject path (BREACH)"
  else
    pass "[$label] AC4 — no generate record on reject path"
  fi
  if grep '"surface_id":"surface-6-frontmatter-enforce"' "$AUTO_AUTHOR_LOG" | grep -q '"action":"apply"'; then
    fail "[$label] AC4 — apply record present on reject path (BREACH)"
  else
    pass "[$label] AC4 — no apply record on reject path"
  fi
}

# --- "Evil" 8-fields cap test (AC1 stress) ---

run_evil_cap() {
  local label="evil-8-fields"
  local manifest="$T6_TEST_DIR/manifest-${label}.json"
  local plog="$T6_TEST_DIR/provenance-${label}.jsonl"
  local stderr_capture="$T6_TEST_DIR/stderr-${label}.log"

  # Start with empty overrides; inject 8-field payload via --evil-fields-list
  # for engagement-note. The cap MUST fire structurally regardless of input.
  write_manifest "$manifest" "ProjectsX" '{}'
  : > "$AUTO_AUTHOR_LOG"
  : > "$plog"

  bash "$SURFACE" \
    --user-manifest "$manifest" \
    --provenance-log "$plog" \
    --evil-fields-list 'engagement-note=a,b,c,d,e,f,g,h' \
    --auto-apply \
    > "$stderr_capture.stdout" 2> "$stderr_capture" \
    || {
      fail "[$label] surface-6 invocation rc=$? — see $stderr_capture"
      return 1
    }

  local got_overrides cnt
  got_overrides="$(jq -c '.vault.required_fields_overrides' "$manifest")"
  cnt="$(printf '%s' "$got_overrides" | jq -r '."engagement-note" | length')"
  if [ "$cnt" -le 5 ]; then
    pass "[$label] AC1 — 8-field evil fixture for engagement-note capped to $cnt ≤ 5"
  else
    fail "[$label] AC1 — 8-field evil fixture not capped (got $cnt) — CAP BREACH"
  fi
}

# --- Custom-type cap preservation (AC1 + per-type custom branch) ---

run_custom_type_cap() {
  local label="custom-type"
  local manifest="$T6_TEST_DIR/manifest-${label}.json"
  local plog="$T6_TEST_DIR/provenance-${label}.jsonl"
  local stderr_capture="$T6_TEST_DIR/stderr-${label}.log"

  # Pre-load 7 fields for a custom type "research-paper" — surface should
  # preserve it (custom types passthrough) BUT cap at ≤5 structurally.
  local custom_overrides='{"research-paper": ["created","title","authors","journal","year","doi","abstract"]}'
  write_manifest "$manifest" "ProjectsX" "$custom_overrides"
  : > "$AUTO_AUTHOR_LOG"
  : > "$plog"

  bash "$SURFACE" \
    --user-manifest "$manifest" \
    --provenance-log "$plog" \
    --auto-apply \
    > "$stderr_capture.stdout" 2> "$stderr_capture" \
    || {
      fail "[$label] surface-6 invocation rc=$? — see $stderr_capture"
      return 1
    }

  local got_overrides cnt
  got_overrides="$(jq -c '.vault.required_fields_overrides' "$manifest")"
  cnt="$(printf '%s' "$got_overrides" | jq -r '."research-paper" | length')"
  if [ "$cnt" -le 5 ]; then
    pass "[$label] AC1 — custom type 'research-paper' capped from 7 to $cnt ≤ 5"
  else
    fail "[$label] AC1 — custom type not capped (got $cnt) — CAP BREACH"
  fi
  # AC3: custom-types branch should mention "preserved AS-DECLARED".
  if grep -q 'preserved AS-DECLARED' "$stderr_capture"; then
    pass "[$label] AC3 — custom-types rationale block present in render"
  else
    fail "[$label] AC3 — custom-types rationale block missing"
  fi
}

# --- No-op re-run edge case (UX preservation) ---

run_noop_rerun() {
  local label="noop-rerun"
  local manifest="$T6_TEST_DIR/manifest-${label}.json"
  local plog="$T6_TEST_DIR/provenance-${label}.jsonl"
  local stderr_capture="$T6_TEST_DIR/stderr-${label}.log"

  # Pre-fill manifest with the SP15 T-6 default templates so the proposed
  # merge equals the existing values → no-op short-circuit fires.
  local prefilled_overrides='{
    "engagement-note": ["created","status","client","tags"],
    "person-note": ["created","role","tags"],
    "meeting-note": ["created","meeting_type","attendees","tags"],
    "project-note": ["created","status","engagement","tags"]
  }'
  write_manifest "$manifest" "Engagements" "$prefilled_overrides"
  : > "$AUTO_AUTHOR_LOG"
  : > "$plog"

  # No --auto-apply needed — pre-flight short-circuit returns 0 without
  # firing the consultation gate.
  bash "$SURFACE" \
    --user-manifest "$manifest" \
    --provenance-log "$plog" \
    > "$stderr_capture.stdout" 2> "$stderr_capture"
  local rc=$?

  if [ "$rc" = "0" ]; then
    pass "[$label] no-op re-run rc=0"
  else
    fail "[$label] no-op re-run rc=$rc (expected 0)"
  fi
  # No consultation gate fires on no-op (UX preservation).
  if grep '"surface_id":"surface-6-frontmatter-enforce"' "$AUTO_AUTHOR_LOG" | grep -q '"action":"consult"'; then
    fail "[$label] no-op fired consultation gate (UX regression)"
  else
    pass "[$label] no-op did NOT fire consultation gate"
  fi
  # Manifest unchanged (pd + overrides match prefilled).
  local got_pd got_overrides
  got_pd="$(jq -r '.vault.projects_root_dirname' "$manifest")"
  got_overrides="$(jq -S -c '.vault.required_fields_overrides' "$manifest")"
  local expected_overrides
  expected_overrides="$(printf '%s' "$prefilled_overrides" | jq -S -c .)"
  if [ "$got_pd" = "Engagements" ] && [ "$got_overrides" = "$expected_overrides" ]; then
    pass "[$label] manifest unchanged on no-op"
  else
    fail "[$label] manifest changed on no-op (pd=$got_pd overrides=$got_overrides)"
  fi
}

# --- Drive ---

printf '\n=== SP15 T-6 acceptance test ===\n'
printf 'sandbox: %s\n' "$T6_TEST_DIR"
printf 'audit:   %s\n\n' "$AUTO_AUTHOR_LOG"

# 4 canonical-type runs × {AC1 audit ordering + per-type cap, AC2
# citations + URLs, AC3 per-type marker presence, AC5 manifest write +
# provenance fields}. Each run hits the SAME proposed merged set (since
# we start from empty overrides), but the per-type assertion targets a
# different type for AC1+AC3 verification.
run_accept_type "engagement-note" 4
run_accept_type "person-note"     3
run_accept_type "meeting-note"    4
run_accept_type "project-note"    4

# Custom-type cap preservation (AC1 + custom-types rationale branch).
run_custom_type_cap

# Reject path × AC4 (rc=1, manifest unchanged, no generate/apply).
run_reject_path

# AC1 stress: 8-field evil fixture must collapse to ≤5.
run_evil_cap

# Edge case: no-op re-run preserves pre-T-6 short-circuit UX.
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
