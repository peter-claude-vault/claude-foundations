#!/usr/bin/env bash
# tests/sp09-bootstrap-validation.sh
#
# SP09 T-9.5 — Foundation-repo bootstrap-validation (STRUCTURAL-ONLY).
#
# Per audit redesign (~/.claude-plans/71-claude-foundations-engine-v2/
# _audit-2026-04-29/synthesis-final.md L304-308 + SP-09-audit F-01):
# this script DOES NOT invoke bootstrap-schemas.sh end-to-end (that
# would fail at line 256 — extraction-output-{A..E}.json absent).
# Scope is structural integrity of the re-forked foundation-repo
# distribution source after T-8 (onboarding/ re-fork) + T-9 (6-schema
# re-fork + AR-3 1.2.0 fold-in for user-manifest).
#
# Re-runnable as a regression check; declarative per-check PASS/FAIL;
# exits 0 only if every check passes.
#
# Checks performed:
#   1. bash -n on bootstrap-schemas.sh + archetype-inference.sh
#   2. jq -e on all 6 foundation-repo schemas
#   3. user-manifest-schema.json: system.schema_version.const == "1.2.0"
#   4. user-manifest-schema.json: 14/14 SP06+F-08 fields PRESENT
#   5. archetype-inference.sh dry-run against 3 archetype fixtures
#      (consultant, developer, writer); expect each fixture to be
#      classified as its own archetype with valid JSON output
#
# bash 3.2 compatible (R-23). No dependency on extraction-output-*.json.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-foundations-v2}"
SCHEMAS_DIR="$FOUNDATION_REPO/schemas"
ONBOARDING_DIR="$FOUNDATION_REPO/onboarding"
USER_MANIFEST="$SCHEMAS_DIR/user-manifest-schema.json"

PASS=0
FAIL=0
FAILED_CHECKS=""

emit_pass() {
  printf '  PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

emit_fail() {
  printf '  FAIL: %s\n' "$1"
  FAIL=$((FAIL + 1))
  FAILED_CHECKS="$FAILED_CHECKS\n    - $1"
}

# --- Preconditions -----------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  printf 'sp09-bootstrap-validation: jq not on PATH\n' >&2
  exit 2
fi
if [ ! -d "$FOUNDATION_REPO" ]; then
  printf 'sp09-bootstrap-validation: FOUNDATION_REPO not found: %s\n' "$FOUNDATION_REPO" >&2
  exit 2
fi

printf '=== SP09 T-9.5 bootstrap-validation (structural-only) ===\n'
printf 'FOUNDATION_REPO=%s\n\n' "$FOUNDATION_REPO"

# --- Check 1: bash -n on onboarding scripts ---------------------------
printf '[1] bash -n syntax checks\n'
for script in bootstrap-schemas.sh archetype-inference.sh; do
  if [ ! -f "$ONBOARDING_DIR/$script" ]; then
    emit_fail "onboarding/$script missing"
    continue
  fi
  if bash -n "$ONBOARDING_DIR/$script" 2>/dev/null; then
    emit_pass "bash -n $script"
  else
    emit_fail "bash -n $script (syntax error)"
  fi
done

# --- Check 2: jq -e on 6 foundation-repo schemas ---------------------
printf '\n[2] jq -e schema validity (6 schemas)\n'
for s in vault-schema plans-schema plan-manifest-schema librarian-manifest-schema user-manifest-schema orchestration-schema; do
  schema_file="$SCHEMAS_DIR/${s}.json"
  if [ ! -f "$schema_file" ]; then
    emit_fail "schemas/${s}.json missing"
    continue
  fi
  if jq -e . "$schema_file" >/dev/null 2>&1; then
    emit_pass "jq -e ${s}.json"
  else
    emit_fail "jq -e ${s}.json (invalid JSON)"
  fi
done

# --- Check 3: user-manifest schema_version.const = 1.2.0 -------------
printf '\n[3] user-manifest schema_version.const == 1.2.0\n'
ver=$(jq -r '.properties.system.properties.schema_version.const' "$USER_MANIFEST" 2>/dev/null)
if [ "$ver" = "1.2.0" ]; then
  emit_pass "schema_version.const = 1.2.0"
else
  emit_fail "schema_version.const = '$ver' (expected 1.2.0)"
fi

# --- Check 4: 14/14 SP06+F-08 fields PRESENT in user-manifest --------
printf '\n[4] Per-field jq probe (14 SP06+F-08 fields)\n'
for spec in \
  "vault.root|.properties.vault.properties.root" \
  "vault.context_documents|.properties.vault.properties.context_documents" \
  "backlog.index_path|.properties.backlog.properties.index_path" \
  "backlog.archive_path|.properties.backlog.properties.archive_path" \
  "backlog.progress_dir|.properties.backlog.properties.progress_dir" \
  "backlog.clusters|.properties.backlog.properties.clusters" \
  "dashboard.enabled|.properties.dashboard.properties.enabled" \
  "dashboard.path|.properties.dashboard.properties.path" \
  "paths.hooks_state|.properties.paths.properties.hooks_state" \
  "paths.cron_log_dir|.properties.paths.properties.cron_log_dir" \
  "paths.plans_root|.properties.paths.properties.plans_root" \
  "brief_repos|.properties.brief_repos" \
  "crons.groups|.properties.crons.properties.groups" \
  "system.timezone|.properties.system.properties.timezone"
do
  name="${spec%%|*}"
  path="${spec#*|}"
  if jq -e "$path" "$USER_MANIFEST" >/dev/null 2>&1; then
    emit_pass "field present: $name"
  else
    emit_fail "field missing: $name"
  fi
done

# --- Check 5: archetype-inference.sh dry-run against 3 fixtures -------
printf '\n[5] archetype-inference.sh dry-run (3 archetype fixtures)\n'
KEYWORDS_FILE_OVERRIDE="$ONBOARDING_DIR/archetype-keywords.json"
if [ ! -r "$KEYWORDS_FILE_OVERRIDE" ]; then
  emit_fail "archetype-keywords.json not readable"
else
  for arch in consultant developer writer; do
    fixture="$ONBOARDING_DIR/fixtures/${arch}.json"
    if [ ! -f "$fixture" ]; then
      emit_fail "fixture missing: ${arch}.json"
      continue
    fi
    out=$(KEYWORDS_FILE="$KEYWORDS_FILE_OVERRIDE" bash "$ONBOARDING_DIR/archetype-inference.sh" "$fixture" 2>/dev/null)
    rc=$?
    if [ $rc -ne 0 ]; then
      emit_fail "archetype-inference exit=$rc on $arch.json"
      continue
    fi
    # Validate output is JSON + correct archetype
    if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      emit_fail "archetype-inference produced invalid JSON for $arch.json"
      continue
    fi
    detected=$(printf '%s' "$out" | jq -r '.archetype')
    if [ "$detected" = "$arch" ]; then
      emit_pass "archetype-inference $arch.json -> $detected"
    else
      emit_fail "archetype-inference $arch.json -> $detected (expected $arch)"
    fi
  done
fi

# --- Summary -----------------------------------------------------------
printf '\n=== TOTAL: %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf 'Failed checks:'
  printf '%b\n' "$FAILED_CHECKS"
  exit 1
fi
printf 'ALL CHECKS PASS\n'
exit 0
