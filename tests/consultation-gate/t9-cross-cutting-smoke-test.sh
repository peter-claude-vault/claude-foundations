#!/usr/bin/env bash
# tests/consultation-gate/t9-cross-cutting-smoke-test.sh — SP15 T-9 cross-cutting smoke
#
# End-to-end SP15 smoke test. Orchestrates the per-surface hermetic acceptance
# tests (t4 / t5 / t6 / t7) in-band and adds the cross-cutting probes (P1, P2,
# P3, P9, P10, P11) that no per-surface test covers. Per
# state/T-9-build-decision.md (Session 9, 2026-05-04).
#
# Hermetic per `feedback_test_isolation_for_hooks_state` — CLAUDE_HOME and
# HOOKS_STATE_OVERRIDE redirected to a tmpdir under $TMPDIR. Never touches
# `~/Documents/Obsidian Vault` per `feedback_universal_vault_safety` — child
# tests stand up their own test vaults under their own tmpdirs; this
# orchestrator's own probes don't write to any vault.
#
# 11 PROBES (per spec L88-97):
#   P1  — lib/consultation-gate.sh loads under R-23 /bin/bash 3.2.57.
#   P2  — Allowlist enforcement: non-allowlisted surface → rc=2 + audit
#         consult-blocked entry.
#   P3  — Provenance additivity (narrower per-surface diff): pf_emit without
#         consultation flags emits no consulted_at / consultation_response_hash
#         lines for surfaces 1, 2, 5, 9.
#   P4  — Surface-3 accept (consult ordered before generate; consulted_at +
#         consultation_response_hash on output) → invoke t4 test.
#   P5  — Surface-3 reject (zero vault write + reject audit entry) → covered
#         by t4 test reject sub-case.
#   P6  — Surface-4 ≤9 caps + 5 citations across 4 archetypes + evil-12
#         blocked → invoke t5 test.
#   P7  — Surface-6 ≤5 caps across 4 canonical types + evil-8 blocked →
#         invoke t6 test.
#   P8  — SP13 Stage 2.5 accept + reject + missing-input rc=2 + AC9
#         round-trip → invoke t7 test.
#   P9  — Audit log carries consult action with required-field shape
#         (verified by child tests; orchestrator confirms P4..P8 green
#         which transitively covers P9).
#   P10 — R-55 audit: zero ~/.claude/ writes; G1 deny-log delta == 0.
#   P11 — T-8 cut outcome: state/T-8.cut + state/T-8-cut-decision.md
#         present; SP15 manifest T-8 status: cut; tasks.md T-8 cut header.
#
# CONSTRAINTS (R-23): bash 3.2.57; jq + python3 required.
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP15 Session 9 (T-9)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLAN_TREE_ROOT="${HOME}/.claude-plans/71-claude-foundations-engine-v2/15-collaborative-personalization-gates"

CG_LIB="$REPO_ROOT/lib/consultation-gate.sh"
PF_LIB="$REPO_ROOT/lib/provenance-frontmatter.sh"
T4_TEST="$REPO_ROOT/tests/consultation-gate/t4-surface-3-consultation-test.sh"
T5_TEST="$REPO_ROOT/tests/consultation-gate/t5-surface-4-consultation-test.sh"
T6_TEST="$REPO_ROOT/tests/consultation-gate/t6-surface-6-consultation-test.sh"
T7_TEST="$REPO_ROOT/tests/consultation-gate/t7-stage-2-5-consultation-test.sh"

PROBE_PASS=0
PROBE_FAIL=0
pass_probe() { PROBE_PASS=$((PROBE_PASS + 1)); printf 'PASS — %s\n' "$1"; }
fail_probe() { PROBE_FAIL=$((PROBE_FAIL + 1)); printf 'FAIL — %s\n' "$1" >&2; }

# Capture each child test's last-line summary for the final report.
T4_RESULT=""
T5_RESULT=""
T6_RESULT=""
T7_RESULT=""

# --- Hermetic test sandbox (orchestrator-local probes) ---

T9_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/consultation-cross-cutting-$$.XXXXXX")"
trap 'rm -rf "$T9_TEST_DIR" 2>/dev/null' EXIT INT TERM

export CLAUDE_HOME="$T9_TEST_DIR/claude"
export HOOKS_STATE_OVERRIDE="$CLAUDE_HOME/state"
export AUTO_AUTHOR_LOG="$T9_TEST_DIR/audit.jsonl"
export TG_STAGE_DIR="$T9_TEST_DIR/stage"
export EDITOR=":"
mkdir -p "$CLAUDE_HOME" "$HOOKS_STATE_OVERRIDE" "$TG_STAGE_DIR"

# --- P10 baseline: snapshot R-55 G1 override-log line count BEFORE any work ---

R55_LOG="${HOME}/.claude/hooks/state/plan-71-live-mutation-overrides.log"
if [ -f "$R55_LOG" ]; then
  R55_BASELINE=$(wc -l < "$R55_LOG" | tr -d ' ')
else
  R55_BASELINE=0
fi

# --- P1: lib/consultation-gate.sh loads under R-23 /bin/bash 3.2.57 ---

if [ ! -f "$CG_LIB" ]; then
  fail_probe "P1 lib/consultation-gate.sh missing at $CG_LIB"
  exit 1
fi

if /bin/bash -n "$CG_LIB" >/dev/null 2>&1 && bash --posix -n "$CG_LIB" >/dev/null 2>&1; then
  # Source check — confirm it loads without runtime error.
  if (
    set +u
    # shellcheck disable=SC1090
    . "$CG_LIB" >/dev/null 2>&1
  ); then
    pass_probe "P1 lib/consultation-gate.sh R-23 lint clean + sources cleanly under bash 3.2.57"
  else
    fail_probe "P1 lib/consultation-gate.sh source-time runtime error"
    exit 1
  fi
else
  fail_probe "P1 lib/consultation-gate.sh R-23 lint FAILED"
  /bin/bash -n "$CG_LIB" 2>&1 | head -5 >&2
  bash --posix -n "$CG_LIB" 2>&1 | head -5 >&2
  exit 1
fi

# Same lint pass on the orchestrator itself.
if /bin/bash -n "$0" >/dev/null 2>&1 && bash --posix -n "$0" >/dev/null 2>&1; then
  pass_probe "P1 orchestrator R-23 lint clean ($(basename "$0"))"
else
  fail_probe "P1 orchestrator R-23 lint FAILED ($(basename "$0"))"
  /bin/bash -n "$0" 2>&1 | head -5 >&2
  exit 1
fi

# --- P2: allowlist enforcement — non-allowlisted surface → rc=2 + audit consult-blocked ---

# Hermetic allowlist that does NOT contain 'not-on-allowlist'.
P2_ALLOWLIST="$T9_TEST_DIR/p2-allowlist"
cat > "$P2_ALLOWLIST" <<'AL'
# P2 hermetic allowlist (orchestrator)
self-test
AL
P2_AUDIT="$T9_TEST_DIR/p2-audit.jsonl"
P2_STAGE="$T9_TEST_DIR/p2-stage"
mkdir -p "$P2_STAGE"

# Run the probe in a subshell so we can capture rc + audit without polluting
# the orchestrator's own env.
P2_RC=0
(
  set +u
  export CG_ALLOWLIST_PATH="$P2_ALLOWLIST"
  export AUTO_AUTHOR_LOG="$P2_AUDIT"
  export TG_STAGE_DIR="$P2_STAGE"
  export CG_TARGET_PATH="$T9_TEST_DIR/p2-target.txt"
  # shellcheck disable=SC1090
  . "$CG_LIB"
  # Mock rfn + gfn — neither should be invoked since the allowlist gate fires
  # FIRST (per consultation-gate.sh L96-105 + handoff Session 2 design call).
  p2_rfn() { printf 'mock rationale\n'; }
  p2_gfn() { printf 'mock generator output\n'; }
  consultation_propose 'not-on-allowlist' p2_rfn p2_gfn
) >/dev/null 2>&1
P2_RC=$?

if [ "$P2_RC" -eq 2 ]; then
  pass_probe "P2 non-allowlisted surface returns rc=2 (got rc=$P2_RC)"
else
  fail_probe "P2 non-allowlisted surface returns rc=$P2_RC (expected rc=2)"
fi

if [ -f "$P2_AUDIT" ]; then
  if jq -e 'select(.action == "consult-blocked" and .reason == "not-allowlisted" and .surface_id == "not-on-allowlist")' < "$P2_AUDIT" >/dev/null 2>&1; then
    pass_probe "P2 audit log carries consult-blocked / not-allowlisted record with surface_id=not-on-allowlist"
  else
    fail_probe "P2 audit log missing consult-blocked record"
    cat "$P2_AUDIT" >&2
  fi
else
  fail_probe "P2 audit log not written at $P2_AUDIT"
fi

# --- P3: provenance additivity (narrower per-surface diff) ---
#
# pf_emit invoked WITHOUT consultation flags must NOT emit consulted_at
# or consultation_response_hash lines, for each of surfaces 1/2/5/9
# (un-retrofitted SP12 surfaces). Behavioral additivity proof — preserves
# byte-equivalence with pre-T-3 callers.

P3_FAIL_COUNT=0
for sid_pair in "surface-1-claude-home test-fixture" "surface-2-memory-seeds test-fixture" "surface-5-doc-dependencies test-fixture" "surface-9-architect-prior-seed test-fixture"; do
  set -- $sid_pair
  sid="$1"
  gfrom="$2"
  P3_OUT=$(
    set +u
    # shellcheck disable=SC1090
    . "$PF_LIB" >/dev/null 2>&1
    pf_emit "$sid" "$gfrom"
  ) || P3_FAIL_COUNT=$((P3_FAIL_COUNT + 1))

  if printf '%s' "$P3_OUT" | grep -qE '^consulted_at:'; then
    fail_probe "P3 surface=$sid consulted_at unexpectedly emitted (additivity broken)"
    P3_FAIL_COUNT=$((P3_FAIL_COUNT + 1))
    continue
  fi
  if printf '%s' "$P3_OUT" | grep -qE '^consultation_response_hash:'; then
    fail_probe "P3 surface=$sid consultation_response_hash unexpectedly emitted (additivity broken)"
    P3_FAIL_COUNT=$((P3_FAIL_COUNT + 1))
    continue
  fi
  # Sanity: required fields still present
  if printf '%s' "$P3_OUT" | grep -q "^generated_by: $sid$" \
     && printf '%s' "$P3_OUT" | grep -q "^generated_from: $gfrom$" \
     && printf '%s' "$P3_OUT" | grep -q '^last_user_edit: null$'; then
    : # ok
  else
    fail_probe "P3 surface=$sid required fields malformed in pf_emit output"
    P3_FAIL_COUNT=$((P3_FAIL_COUNT + 1))
    continue
  fi
done

if [ "$P3_FAIL_COUNT" -eq 0 ]; then
  pass_probe "P3 provenance additivity holds for surfaces 1/2/5/9 (no consulted fields when flags absent; required fields preserved)"
fi

# --- P4 + P5: surface-3 (vault CLAUDE.md) consultation retrofit, accept + reject ---

if [ ! -x "$T4_TEST" ]; then
  fail_probe "P4/P5 t4 test missing or non-executable: $T4_TEST"
else
  T4_OUTPUT="$T9_TEST_DIR/t4-output.txt"
  if "$T4_TEST" > "$T4_OUTPUT" 2>&1; then
    T4_RESULT=$(grep -E '^(Total:|PASS:|FAIL:)' "$T4_OUTPUT" | tail -3 || echo "[no summary]")
    T4_PASS=$(grep -cE '^PASS ' "$T4_OUTPUT" 2>/dev/null || true)
    T4_FAIL=$(grep -cE '^FAIL ' "$T4_OUTPUT" 2>/dev/null || true)
    if [ "${T4_FAIL:-0}" -eq 0 ] && [ "${T4_PASS:-0}" -gt 0 ]; then
      pass_probe "P4 surface-3 accept paths green (t4: ${T4_PASS} PASS / ${T4_FAIL} FAIL across 3 archetypes + audit ordering + ≥3 citations + provenance frontmatter consulted fields)"
      pass_probe "P5 surface-3 reject path green (t4: zero vault write + reject audit entry; no generate/apply records)"
    else
      fail_probe "P4/P5 t4 test reported FAILs: ${T4_PASS} PASS / ${T4_FAIL} FAIL"
      tail -30 "$T4_OUTPUT" >&2
    fi
  else
    fail_probe "P4/P5 t4 test exited non-zero"
    tail -30 "$T4_OUTPUT" >&2
  fi
fi

# --- P6: surface-4 (tag-prefixes) consultation retrofit + ≤9 cap + 5 citations + evil-12 block ---

if [ ! -x "$T5_TEST" ]; then
  fail_probe "P6 t5 test missing or non-executable: $T5_TEST"
else
  T5_OUTPUT="$T9_TEST_DIR/t5-output.txt"
  if "$T5_TEST" > "$T5_OUTPUT" 2>&1; then
    T5_RESULT=$(grep -E '^(Total:|PASS:|FAIL:)' "$T5_OUTPUT" | tail -3 || echo "[no summary]")
    T5_PASS=$(grep -cE '^PASS ' "$T5_OUTPUT" 2>/dev/null || true)
    T5_FAIL=$(grep -cE '^FAIL ' "$T5_OUTPUT" 2>/dev/null || true)
    if [ "${T5_FAIL:-0}" -eq 0 ] && [ "${T5_PASS:-0}" -gt 0 ]; then
      pass_probe "P6 surface-4 green (t5: ${T5_PASS} PASS / ${T5_FAIL} FAIL — 4 archetypes ≤9 caps + 5 citations + reject + evil-12 cap stress + no-op re-run)"
    else
      fail_probe "P6 t5 test reported FAILs: ${T5_PASS} PASS / ${T5_FAIL} FAIL"
      tail -30 "$T5_OUTPUT" >&2
    fi
  else
    fail_probe "P6 t5 test exited non-zero"
    tail -30 "$T5_OUTPUT" >&2
  fi
fi

# --- P7: surface-6 (frontmatter-enforce) consultation retrofit + ≤5 cap + evil-8 block ---

if [ ! -x "$T6_TEST" ]; then
  fail_probe "P7 t6 test missing or non-executable: $T6_TEST"
else
  T6_OUTPUT="$T9_TEST_DIR/t6-output.txt"
  if "$T6_TEST" > "$T6_OUTPUT" 2>&1; then
    T6_RESULT=$(grep -E '^(Total:|PASS:|FAIL:)' "$T6_OUTPUT" | tail -3 || echo "[no summary]")
    T6_PASS=$(grep -cE '^PASS ' "$T6_OUTPUT" 2>/dev/null || true)
    T6_FAIL=$(grep -cE '^FAIL ' "$T6_OUTPUT" 2>/dev/null || true)
    if [ "${T6_FAIL:-0}" -eq 0 ] && [ "${T6_PASS:-0}" -gt 0 ]; then
      pass_probe "P7 surface-6 green (t6: ${T6_PASS} PASS / ${T6_FAIL} FAIL — 4 canonical types ≤5 caps + custom-type cap + reject + evil-8 cap stress + no-op re-run)"
    else
      fail_probe "P7 t6 test reported FAILs: ${T6_PASS} PASS / ${T6_FAIL} FAIL"
      tail -30 "$T6_OUTPUT" >&2
    fi
  else
    fail_probe "P7 t6 test exited non-zero"
    tail -30 "$T6_OUTPUT" >&2
  fi
fi

# --- P8: SP13 Stage 2.5 accept + reject + missing-input rc=2 + AC9 round-trip ---

if [ ! -x "$T7_TEST" ]; then
  fail_probe "P8 t7 test missing or non-executable: $T7_TEST"
else
  T7_OUTPUT="$T9_TEST_DIR/t7-output.txt"
  if "$T7_TEST" > "$T7_OUTPUT" 2>&1; then
    T7_RESULT=$(grep -E '^(Total:|PASS:|FAIL:)' "$T7_OUTPUT" | tail -3 || echo "[no summary]")
    T7_PASS=$(grep -cE '^PASS ' "$T7_OUTPUT" 2>/dev/null || true)
    T7_FAIL=$(grep -cE '^FAIL ' "$T7_OUTPUT" 2>/dev/null || true)
    if [ "${T7_FAIL:-0}" -eq 0 ] && [ "${T7_PASS:-0}" -gt 0 ]; then
      pass_probe "P8 SP13 Stage 2.5 green (t7: ${T7_PASS} PASS / ${T7_FAIL} FAIL — 10 ACs incl. accept + reject + missing-input rc=2 + AC9 real-T-6 round-trip through review-gate.sh)"
    else
      fail_probe "P8 t7 test reported FAILs: ${T7_PASS} PASS / ${T7_FAIL} FAIL"
      tail -30 "$T7_OUTPUT" >&2
    fi
  else
    fail_probe "P8 t7 test exited non-zero"
    tail -30 "$T7_OUTPUT" >&2
  fi
fi

# --- P9: audit log carries consult action with required-field shape ---
#
# Each child test (t4 / t5 / t6 / t7) covers AC for its own surface's
# consult-action audit record (t4 AC1 audit ordering; t5 AC1 audit ordering;
# t6 AC1 audit ordering; t7 AC8 audit ordering). If P4..P8 are all green,
# the consult-action shape was verified across all 4 consulted surfaces.

if [ "$PROBE_FAIL" -eq 0 ]; then
  # If we got here, P1..P8 all passed.
  pass_probe "P9 audit log consult action shape verified across surface-3 / surface-4 / surface-6 / import-plan-consultation (transitive via P4..P8 each covering its surface's consult-record AC)"
else
  fail_probe "P9 NOT EVALUATED — upstream probes failed; audit log shape coverage incomplete"
fi

# --- P10: R-55 audit — zero ~/.claude/ writes; G1 deny-log delta == 0 ---

if [ -f "$R55_LOG" ]; then
  R55_FINAL=$(wc -l < "$R55_LOG" | tr -d ' ')
else
  R55_FINAL=0
fi
R55_DELTA=$(( R55_FINAL - R55_BASELINE ))

if [ "$R55_DELTA" -eq 0 ]; then
  pass_probe "P10 R-55 G1 override-log delta == 0 (baseline=$R55_BASELINE final=$R55_FINAL — zero ~/.claude/ writes from T-9 run)"
else
  fail_probe "P10 R-55 G1 override-log delta=$R55_DELTA (baseline=$R55_BASELINE final=$R55_FINAL — possible containment breach)"
  if [ "$R55_DELTA" -gt 0 ]; then
    printf '   Recent override-log entries (post-baseline):\n' >&2
    tail -n "$R55_DELTA" "$R55_LOG" >&2
  fi
fi

# --- P11: T-8 cut outcome present (filesystem invariant) ---

P11_OK=1
T8_CUT_MARKER="$PLAN_TREE_ROOT/state/T-8.cut"
T8_CUT_DECISION="$PLAN_TREE_ROOT/state/T-8-cut-decision.md"
SP15_MANIFEST="$PLAN_TREE_ROOT/manifest.json"
SP15_TASKS="$PLAN_TREE_ROOT/tasks.md"

if [ ! -f "$T8_CUT_MARKER" ]; then
  fail_probe "P11 state/T-8.cut marker missing"
  P11_OK=0
fi
if [ ! -f "$T8_CUT_DECISION" ]; then
  fail_probe "P11 state/T-8-cut-decision.md missing"
  P11_OK=0
fi
if [ ! -f "$SP15_MANIFEST" ]; then
  fail_probe "P11 SP15 manifest.json missing"
  P11_OK=0
else
  T8_STATUS=$(jq -r '.tasks[] | select(.id == "T-8") | .status' "$SP15_MANIFEST" 2>/dev/null)
  if [ "$T8_STATUS" != "cut" ]; then
    fail_probe "P11 SP15 manifest T-8 status='$T8_STATUS' (expected 'cut')"
    P11_OK=0
  fi
fi
if [ ! -f "$SP15_TASKS" ]; then
  fail_probe "P11 SP15 tasks.md missing"
  P11_OK=0
else
  if ! grep -qE 'T-8.*cut|task-cut: 15/T-8' "$SP15_TASKS"; then
    fail_probe "P11 SP15 tasks.md T-8 cut header not found"
    P11_OK=0
  fi
fi
if [ "$P11_OK" -eq 1 ]; then
  pass_probe "P11 T-8 cut outcome present (state/T-8.cut + state/T-8-cut-decision.md; manifest T-8 status=cut; tasks.md T-8 cut header)"
fi

# --- Final report ---

printf '\n%s\n' '========================================'
printf '  SP15 T-9 cross-cutting smoke report\n'
printf '%s\n' '========================================'
printf '  Probes passed : %d\n' "$PROBE_PASS"
printf '  Probes failed : %d\n' "$PROBE_FAIL"
printf '%s\n' '----------------------------------------'
printf '  Child tests:\n'
printf '    t4 (P4/P5) : %s\n' "${T4_RESULT:-[skipped]}"
printf '    t5 (P6)    : %s\n' "${T5_RESULT:-[skipped]}"
printf '    t6 (P7)    : %s\n' "${T6_RESULT:-[skipped]}"
printf '    t7 (P8)    : %s\n' "${T7_RESULT:-[skipped]}"
printf '%s\n' '----------------------------------------'
printf '  R-55 G1 log : baseline=%s  final=%s  delta=%s\n' "$R55_BASELINE" "$R55_FINAL" "$R55_DELTA"
printf '%s\n\n' '========================================'

if [ "$PROBE_FAIL" -eq 0 ] && [ "$PROBE_PASS" -ge 12 ]; then
  printf 'Total: %d PASS / 0 FAIL — GREEN (11 spec probes + R-23 lint on lib + orchestrator).\n' "$PROBE_PASS"
  exit 0
else
  printf 'Total: %d PASS / %d FAIL.\n' "$PROBE_PASS" "$PROBE_FAIL" >&2
  exit 1
fi
