#!/usr/bin/env bash
# round-trip-test.sh — SP01 T-13 fixture round-trip validation
#
# Acceptance criteria:
#   AC1: Script runs 3 archetypes end-to-end through bootstrap-schemas.sh
#   AC2: Computes field-level fidelity ratio per archetype
#   AC3: All 3 archetypes ≥95% fidelity
#   AC4: archetype-inference.sh returns canonical archetype with
#        confidence ≥0.75 — 100% agreement on the 3 fixtures
#   AC5: Delta report prints diverging field list + cause
#
# Architecture:
#   1. Sandbox HOME at /tmp/round-trip-sbx-$$/home (T-15 isolation pattern).
#   2. Per archetype: deterministic extraction-emulation transforms canonical
#      fixture → extraction-output-{A..E}.json (SP07 implements full LLM
#      extraction at runtime; T-13 uses canonical→populated round-trip to
#      exercise the engine's emission semantics under fidelity scrutiny).
#   3. Run bootstrap-schemas.sh under HOME-override; engine writes user-manifest +
#      orchestration into the sandbox.
#   4. Field-level diff vs canonical fixture across the q-field-map path set;
#      paths the engine semantically omits (D-3 prior_seed when D-2 != architect)
#      are excluded from the denominator.
#   5. Cross-pollinated heuristic check: archetype-inference.sh against
#      transcripts B+C+D wrapped in {section_b, section_c, section_d} envelope.
#
# bash 3.2 compatible (R-23): no `declare -A`, no `mapfile`/`readarray`,
# no `${var,,}`. set -u only (continue past failed assertions to count them).

set -u

SBX="/tmp/round-trip-sbx-$$"
SCHEMAS_SRC="${HOME}/.claude/schemas"
ONBOARDING_SRC="${HOME}/.claude/onboarding"
FIXTURES_SRC="$ONBOARDING_SRC/fixtures"
INFER_BIN="$ONBOARDING_SRC/archetype-inference.sh"
KEYWORDS_LIVE="$ONBOARDING_SRC/archetype-keywords.json"

trap 'rm -rf "$SBX"' EXIT

pass=0
fail=0
delta_report=""
fidelity_results=""
inference_results=""

record_pass() {
  pass=$((pass + 1))
  printf '  ok   %s\n' "$1"
}

record_fail() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
}

# Engine-owned U.* paths derived from q-field-map.json:
#   direct_qs A-1..A-4, B-1..B-5, C-1..C-4, D-1, D-3, D-4
#   checkbox_qs A-CB1..A-CB6
#   section_e_binaries E-1..E-3
# Each entry is the jq-path against user-manifest.json.
USER_PATHS_LIST="\
.identity.name \
.identity.email \
.identity.role \
.identity.organization \
.identity.industry \
.identity.seniority \
.system.timezone \
.paths.vault_root \
.vault.root \
.vault.default_audience \
.vault.organizational_method \
.vault.has_structured_projects \
.vault.is_fresh \
.vault.canonical_file_types \
.projects.active \
.people \
.behavioral.cadence_default \
.behavioral.autonomy \
.behavioral.hook_preferences.notification_style \
.behavioral.hook_preferences.auto_commit_enabled \
.behavioral.hook_preferences.memory_consolidation_enabled \
.behavioral.hook_preferences.multi_session_enabled \
.system.opt_outs \
.architect.prior_seed \
.tools.calendar \
.tools.messaging \
.tools.email \
.tools.transcription \
.tools.tasks \
.tools.dev_env"

# Engine-owned O.jobs[0].* sub-paths. command/log_path are HOME-rooted (engine
# derives at runtime) — out of scope for fidelity comparison.
ORCH_PATHS_LIST="\
.jobs[0].id \
.jobs[0].enabled \
.jobs[0].schedule \
.jobs[0].idle_watchdog_sec \
.jobs[0].single_instance \
.jobs[0].cold_wake_probe"

# --------------------------------------------------------------- preflight
[ -x "$INFER_BIN" ]      || { echo "FAIL: archetype-inference not executable: $INFER_BIN" >&2; exit 2; }
[ -r "$KEYWORDS_LIVE" ]  || { echo "FAIL: archetype-keywords not readable: $KEYWORDS_LIVE" >&2; exit 2; }
[ -d "$FIXTURES_SRC" ]   || { echo "FAIL: fixtures dir missing: $FIXTURES_SRC" >&2; exit 2; }

for arch in consultant developer writer; do
  for sect in B C D; do
    [ -r "$FIXTURES_SRC/${arch}-section-${sect}.txt" ] || \
      { echo "FAIL: fixture transcript missing: ${arch}-section-${sect}.txt" >&2; exit 2; }
  done
  [ -r "$FIXTURES_SRC/${arch}.json" ]              || { echo "FAIL: missing ${arch}.json" >&2; exit 2; }
  [ -r "$FIXTURES_SRC/${arch}-orchestration.json" ] || { echo "FAIL: missing ${arch}-orchestration.json" >&2; exit 2; }
done

# --------------------------------------------------------------- sandbox
mkdir -p "$SBX/home/.claude/schemas"
mkdir -p "$SBX/home/.claude/onboarding"

cp "$SCHEMAS_SRC/user-manifest-schema.json" "$SBX/home/.claude/schemas/"
cp "$SCHEMAS_SRC/orchestration-schema.json" "$SBX/home/.claude/schemas/"
cp "$SCHEMAS_SRC/vault-schema.json"         "$SBX/home/.claude/schemas/"
cp "$SCHEMAS_SRC/plans-schema.json"         "$SBX/home/.claude/schemas/"
cp "$ONBOARDING_SRC/q-field-map.json"       "$SBX/home/.claude/onboarding/"
cp "$ONBOARDING_SRC/bootstrap-schemas.sh"   "$SBX/home/.claude/onboarding/"
chmod +x "$SBX/home/.claude/onboarding/bootstrap-schemas.sh"

BOOTSTRAP="$SBX/home/.claude/onboarding/bootstrap-schemas.sh"
SBX_ONB="$SBX/home/.claude/onboarding"
USER_OUT="$SBX/home/.claude/user-manifest.json"
ORCH_OUT="$SBX/home/.claude/orchestration.json"

# --------------------------------------------------------------- emulator
# Deterministic extraction-emulation: canonical fixture → extraction-output
# JSON files. Key shape mirrors q-field-map.json.targets[*].path. SP07 will
# implement full LLM extraction; T-13's gate is whether the engine's emission
# semantics reproduce the canonical state from a faithful extraction surface.
emit_extraction_outputs() {
  archetype="$1"
  fix_user="$FIXTURES_SRC/${archetype}.json"
  fix_orch="$FIXTURES_SRC/${archetype}-orchestration.json"

  jq --slurpfile u "$fix_user" -n '
    {
      section_id: "A",
      populated: {
        "U.identity.name":       $u[0].identity.name,
        "U.identity.email":      $u[0].identity.email,
        "U.system.timezone":     $u[0].system.timezone,
        "U.paths.vault_root":    $u[0].paths.vault_root,
        "U.vault.root":          $u[0].vault.root,
        "U.tools.calendar":      $u[0].tools.calendar,
        "U.tools.messaging[]":   $u[0].tools.messaging,
        "U.tools.email":         $u[0].tools.email,
        "U.tools.transcription": $u[0].tools.transcription,
        "U.tools.tasks":         $u[0].tools.tasks,
        "U.tools.dev_env":       $u[0].tools.dev_env
      },
      confidence: {},
      source_spans: {}
    }' > "$SBX_ONB/extraction-output-A.json"

  jq --slurpfile u "$fix_user" -n '
    {
      section_id: "B",
      populated: {
        "U.identity.role":            $u[0].identity.role,
        "U.identity.organization":    $u[0].identity.organization,
        "U.identity.industry":        $u[0].identity.industry,
        "U.identity.seniority":       $u[0].identity.seniority,
        "U.projects.active[]":        $u[0].projects.active,
        "U.people[]":                 $u[0].people,
        "U.behavioral.cadence_default": $u[0].behavioral.cadence_default,
        "U.vault.default_audience":     $u[0].vault.default_audience
      },
      confidence: {},
      source_spans: {}
    }' > "$SBX_ONB/extraction-output-B.json"

  if [ "$archetype" = "consultant" ]; then
    c3_opt_in=true
  else
    c3_opt_in=false
  fi
  jq --slurpfile u "$fix_user" --argjson c3 "$c3_opt_in" -n '
    {
      section_id: "C",
      populated: {
        "U.vault.organizational_method":   $u[0].vault.organizational_method,
        "U.vault.has_structured_projects": $u[0].vault.has_structured_projects,
        "U.vault.is_fresh":                $u[0].vault.is_fresh,
        "U.system.opt_outs[]":             $c3,
        "U.vault.canonical_file_types[]":  $u[0].vault.canonical_file_types
      },
      confidence: {},
      source_spans: {}
    }' > "$SBX_ONB/extraction-output-C.json"

  d2_job=$(jq -r '.jobs[0].id // ""' "$fix_orch")
  if [ -z "$d2_job" ]; then
    jq --slurpfile u "$fix_user" -n '
      {
        section_id: "D",
        populated: {
          "U.behavioral.autonomy": $u[0].behavioral.autonomy,
          "O.jobs":                [],
          "U.behavioral.hook_preferences.notification_style": $u[0].behavioral.hook_preferences.notification_style
        },
        confidence: {},
        source_spans: {}
      }' > "$SBX_ONB/extraction-output-D.json"
  elif [ "$d2_job" = "architect" ]; then
    jq --slurpfile u "$fix_user" -n '
      {
        section_id: "D",
        populated: {
          "U.behavioral.autonomy":  $u[0].behavioral.autonomy,
          "O.jobs[0].id":           "architect",
          "U.architect.prior_seed": $u[0].architect.prior_seed,
          "U.behavioral.hook_preferences.notification_style": $u[0].behavioral.hook_preferences.notification_style
        },
        confidence: {},
        source_spans: {}
      }' > "$SBX_ONB/extraction-output-D.json"
  else
    jq --slurpfile u "$fix_user" --arg jid "$d2_job" -n '
      {
        section_id: "D",
        populated: {
          "U.behavioral.autonomy": $u[0].behavioral.autonomy,
          "O.jobs[0].id":          $jid,
          "U.behavioral.hook_preferences.notification_style": $u[0].behavioral.hook_preferences.notification_style
        },
        confidence: {},
        source_spans: {}
      }' > "$SBX_ONB/extraction-output-D.json"
  fi

  jq --slurpfile u "$fix_user" -n '
    {
      section_id: "E",
      populated: {
        "U.behavioral.hook_preferences.auto_commit_enabled":          $u[0].behavioral.hook_preferences.auto_commit_enabled,
        "U.behavioral.hook_preferences.memory_consolidation_enabled": $u[0].behavioral.hook_preferences.memory_consolidation_enabled,
        "U.behavioral.hook_preferences.multi_session_enabled":        $u[0].behavioral.hook_preferences.multi_session_enabled
      },
      confidence: {},
      source_spans: {}
    }' > "$SBX_ONB/extraction-output-E.json"
}

# --------------------------------------------------------------- round-trip
run_archetype_round_trip() {
  archetype="$1"
  fix_user="$FIXTURES_SRC/${archetype}.json"
  fix_orch="$FIXTURES_SRC/${archetype}-orchestration.json"

  rm -f "$USER_OUT" "$ORCH_OUT"
  emit_extraction_outputs "$archetype"

  if ! HOME="$SBX/home" "$BOOTSTRAP" --force >/dev/null 2>&1; then
    record_fail "AC1 $archetype: engine exited non-zero"
    return
  fi

  if [ ! -f "$USER_OUT" ] || [ ! -f "$ORCH_OUT" ]; then
    record_fail "AC1 $archetype: engine outputs missing post-run"
    return
  fi
  record_pass "AC1 $archetype: end-to-end run completed"

  d2_job=$(jq -r '.jobs[0].id // ""' "$fix_orch")
  matched=0
  total=0

  for path in $USER_PATHS_LIST; do
    if [ "$path" = ".architect.prior_seed" ] && [ "$d2_job" != "architect" ]; then
      continue
    fi
    total=$((total + 1))
    fix_val=$(jq -c "$path" "$fix_user" 2>/dev/null)
    eng_val=$(jq -c "$path" "$USER_OUT" 2>/dev/null)
    if [ "$fix_val" = "$eng_val" ]; then
      matched=$((matched + 1))
    else
      delta_report="${delta_report}
  $archetype U$path
    expected: $fix_val
    actual:   $eng_val
    cause:    fixture-vs-engine-divergence"
    fi
  done

  for path in $ORCH_PATHS_LIST; do
    total=$((total + 1))
    fix_val=$(jq -c "$path" "$fix_orch" 2>/dev/null)
    eng_val=$(jq -c "$path" "$ORCH_OUT" 2>/dev/null)
    if [ "$fix_val" = "$eng_val" ]; then
      matched=$((matched + 1))
    else
      delta_report="${delta_report}
  $archetype O$path
    expected: $fix_val
    actual:   $eng_val
    cause:    fixture-vs-engine-divergence"
    fi
  done

  ratio=$(awk -v m="$matched" -v t="$total" 'BEGIN { printf "%.1f", (m / t) * 100 }')
  fidelity_results="${fidelity_results}  ${archetype}: ${matched}/${total} = ${ratio}%
"

  record_pass "AC2 $archetype: fidelity computed (${matched}/${total} = ${ratio}%)"

  pass95=$(awk -v r="$ratio" 'BEGIN { print (r + 0 >= 95.0) ? "1" : "0" }')
  if [ "$pass95" = "1" ]; then
    record_pass "AC3 $archetype: fidelity ≥95% ($ratio%)"
  else
    record_fail "AC3 $archetype: fidelity below 95% ($ratio%)"
  fi
}

# --------------------------------------------------------------- inference
run_archetype_inference_check() {
  archetype="$1"
  b_txt=$(cat "$FIXTURES_SRC/${archetype}-section-B.txt")
  c_txt=$(cat "$FIXTURES_SRC/${archetype}-section-C.txt")
  d_txt=$(cat "$FIXTURES_SRC/${archetype}-section-D.txt")

  envelope=$(jq -n --arg b "$b_txt" --arg c "$c_txt" --arg d "$d_txt" \
    '{section_b: $b, section_c: $c, section_d: $d}')

  out=$(printf '%s' "$envelope" | KEYWORDS_FILE="$KEYWORDS_LIVE" "$INFER_BIN")
  if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    record_fail "AC4 $archetype: archetype-inference emitted non-JSON"
    return
  fi

  detected=$(printf '%s' "$out" | jq -r .archetype)
  conf=$(printf '%s' "$out" | jq -r .confidence)
  inference_results="${inference_results}  ${archetype}: detected=${detected} confidence=${conf}
"

  if [ "$detected" != "$archetype" ]; then
    record_fail "AC4 $archetype: detected=$detected (expected $archetype)"
    return
  fi
  ok=$(awk -v c="$conf" 'BEGIN { print (c + 0 >= 0.75) ? "1" : "0" }')
  if [ "$ok" = "1" ]; then
    record_pass "AC4 $archetype: detected=$archetype confidence=$conf ≥0.75"
  else
    record_fail "AC4 $archetype: confidence=$conf below 0.75"
  fi
}

# --------------------------------------------------------------- main

printf '\n=== AC1+AC2+AC3 round-trip fidelity (3 archetypes) ===\n'
for arch in consultant developer writer; do
  run_archetype_round_trip "$arch"
done

printf '\n=== AC4 archetype-inference heuristic agreement ===\n'
for arch in consultant developer writer; do
  run_archetype_inference_check "$arch"
done

printf '\n=== AC5 delta report ===\n'
if [ -z "$delta_report" ]; then
  printf '  (no diverging fields)\n'
  record_pass "AC5 delta report: zero divergences"
else
  printf '%s\n' "$delta_report"
  delta_count=$(printf '%s' "$delta_report" | grep -cE '^  [a-z]+ [UO]\.' || true)
  record_pass "AC5 delta report emitted (${delta_count} diverging field(s); see above)"
fi

printf '\n----------------------------------\n'
printf 'fidelity:\n%s' "$fidelity_results"
printf 'inference:\n%s' "$inference_results"
printf 'passed: %s\n' "$pass"
printf 'failed: %s\n' "$fail"
printf '%s\n' '----------------------------------'

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
