#!/bin/bash
# tests/foundation/librarian-full/run.sh
#
# Plan 71 SP04 T-12 — Hermetic end-to-end test for the foundation-repo
# librarian distribution.
#
# Materializes a fresh $DOGFOOD_ROOT, lays out a synthetic $CLAUDE_HOME
# (foundation-repo lib + skills + schemas symlinked into install-shape),
# materializes the synthetic vault from fixtures/vault-minimal/, and runs
# the 5 integrity capabilities (frontmatter-enforce, xref-check, log-archive,
# stale-detect, placement-validate) — the chain documented as `/librarian
# full` in skills/librarian/SKILL.md L17 / L50.
#
# Asserts the SP04 T-12 acceptance contract:
#   AC#1  /librarian full chain completes against synthetic vault, exit 0
#   AC#2  Aggregated log written to $VAULT_LOGS/session-close-*.md
#   AC#3  librarian-manifest.json populated with 7 expected top-level data
#         sections (excluding metadata schema_version)
#   AC#4  Zero unexpected findings (baseline fixture has known-zero drift)
#   AC#5  Both has_structured_projects: true + false manifest variants pass
#
# Hermetic-isolation strategy:
#   - HOME=$DOGFOOD_ROOT for the duration of the run. Several capabilities
#     (log-archive.sh, xref-check.sh, drift-sweep.sh, architect-triage.sh,
#     entity-parity.sh, cron-log-architecture.sh, handoff-disposition-check.sh)
#     hard-code `$HOME/.claude/...` rather than honoring `${CLAUDE_HOME:-...}`.
#     HOME-override is the cleanest hermetic escape hatch and works uniformly
#     across the inconsistent capabilities. Carry-forward observation flagged
#     in S43 close-out — not in T-12 scope to fix.
#   - PLANS_DIR=$DOGFOOD_ROOT/plans (empty), so plan-walking capabilities
#     find nothing to flag.
#   - FINDINGS_OUTPUT=$DOGFOOD_ROOT/findings.ndjson per capability, truncated
#     each invocation; a non-empty file = unexpected finding.
#   - MANIFEST_PATH=$VAULT_LOGS/librarian-manifest.json (lib/manifest.sh L33
#     default, made explicit).
#
# Exit codes:
#   0  all variants pass all 5 ACs
#   1  one or more ACs failed (driver prints the failing AC to stderr)
#   2  setup error (foundation-repo path missing, mktemp failed, etc.)
#
# R-23: bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
TEST_DIR="$FOUNDATION_REPO/tests/foundation"
FIXTURE_VAULT="$TEST_DIR/fixtures/vault-minimal"
FIXTURE_CLAUDE_HOME="$TEST_DIR/fixtures/claude-home"

# Per-capability flag table. Encoded as parallel arrays (R-23: bash 3.2 has
# no associative arrays). Order matches `/librarian full` chain in SKILL.md L50.
INTEGRITY_CAPS="frontmatter-enforce xref-check log-archive stale-detect placement-validate"
# Flag mapping (matched positionally by space-tokenized index in INTEGRITY_CAPS):
#   frontmatter-enforce: --full
#   xref-check:          --full
#   log-archive:         (no flag — defaults to dry-run per SKILL.md L34)
#   stale-detect:        (no flag — full vault by default; no --full flag)
#   placement-validate:  (no flag — defaults to $VAULT_ROOT scope)
cap_flags() {
  case "$1" in
    frontmatter-enforce|xref-check) printf '%s' '--full' ;;
    log-archive|stale-detect|placement-validate) printf '%s' '' ;;
    *) printf '%s' '' ;;
  esac
}

# 7 expected top-level data sections in librarian-manifest.json (per
# templates/librarian-manifest-skeleton.json — schema_version is metadata,
# the other 7 are the data sections asserted by AC#3).
EXPECTED_SECTIONS="inventory xref_graph tags scan_state drift_findings architect_recommendations rename_history"

# --- Preconditions ---
if [ ! -d "$FOUNDATION_REPO" ]; then
  printf 'run.sh: FOUNDATION_REPO not found: %s\n' "$FOUNDATION_REPO" >&2
  exit 2
fi
if [ ! -d "$FIXTURE_VAULT" ] || [ ! -d "$FIXTURE_CLAUDE_HOME" ]; then
  printf 'run.sh: fixtures missing under %s\n' "$TEST_DIR" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'run.sh: jq not on PATH\n' >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'run.sh: python3 not on PATH\n' >&2
  exit 2
fi

# --- $DOGFOOD_ROOT (hermetic teardown trap) ---
# shellcheck source=/dev/null
. "$FOUNDATION_REPO/tests/dogfood-root-helper.sh"
printf 'DOGFOOD_ROOT=%s\n' "$DOGFOOD_ROOT"

# Optional inspection escape hatch — set T12_KEEP_DOGFOOD=1 to disable the
# helper's cleanup trap so the materialized fixtures + capability outputs
# remain on disk after the run for debugging. Default behavior remains
# hermetic teardown.
if [ -n "${T12_KEEP_DOGFOOD:-}" ]; then
  trap - EXIT INT TERM
  printf 'T12_KEEP_DOGFOOD=1 — cleanup trap disabled; inspect %s\n' "$DOGFOOD_ROOT"
fi

PASS=0
FAIL=0
FAILED_AC=""

emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() {
  printf '  FAIL: %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
  FAILED_AC="$FAILED_AC
    - $1"
}

# --- Per-variant runner ---
run_variant() {
  local variant="$1"   # structured | flat
  local manifest_src="$FIXTURE_CLAUDE_HOME/user-manifest-${variant}.json"

  printf '\n=== variant: %s ===\n' "$variant"

  if [ ! -f "$manifest_src" ]; then
    emit_fail "[$variant] user-manifest-${variant}.json not in fixture"
    return
  fi

  # Per-variant subroot under DOGFOOD_ROOT — the helper trap unwinds the
  # whole tree, so per-variant dirs don't need separate cleanup.
  local subroot="$DOGFOOD_ROOT/$variant"
  mkdir -p "$subroot"

  local CH="$subroot/.claude"
  local VR="$subroot/vault"
  local PD="$subroot/plans"

  # --- Materialize $CLAUDE_HOME (install-shape) ---
  mkdir -p "$CH/hooks/lib" "$CH/hooks/state" "$CH/skills" "$CH/schemas"

  # hooks/lib/ ← foundation-repo/lib/ (paths.sh + cascade-waiver.sh + dates.sh + ...)
  for f in "$FOUNDATION_REPO/lib/"*.sh; do
    [ -f "$f" ] && ln -s "$f" "$CH/hooks/lib/$(basename "$f")"
  done

  # skills/librarian/ ← foundation-repo/skills/librarian/ (full subtree)
  ln -s "$FOUNDATION_REPO/skills/librarian" "$CH/skills/librarian"

  # schemas/ ← foundation-repo/schemas/ (full subtree)
  for f in "$FOUNDATION_REPO/schemas/"*.json; do
    [ -f "$f" ] && ln -s "$f" "$CH/schemas/$(basename "$f")"
  done

  # --- Materialize $VAULT_ROOT (deep-copy from fixture so capabilities can write Logs/) ---
  mkdir -p "$VR"
  # cp -R preserves ownership/permissions; we then strip read-only on Logs/
  # to allow capability writes.
  cp -R "$FIXTURE_VAULT/." "$VR/"
  # cp on macOS doesn't copy hidden files starting with `.` from the source
  # in all cp -R variants — handle .gitkeep explicitly. (Quick double-pass.)
  [ -f "$FIXTURE_VAULT/Logs/.gitkeep" ] && touch "$VR/Logs/.gitkeep"
  # Touch every file to mtime=now so stale-detect doesn't fire on age.
  find "$VR" -type f -exec touch {} +

  # --- Materialize $PLANS_DIR (empty — no plans = no plan-walk findings) ---
  mkdir -p "$PD"

  # --- Materialize user-manifest.json with templated paths ---
  python3 - "$manifest_src" "$CH/user-manifest.json" "$VR" "$PD" <<'PY'
import json, sys
src, dst, vr, pd = sys.argv[1:5]
m = json.load(open(src))
m["paths"]["vault_root"] = vr
m["paths"]["plans_root"] = pd
m["vault"]["root"] = vr
json.dump(m, open(dst, "w"), indent=2, ensure_ascii=True)
PY

  # --- Materialize librarian-manifest.json at $VAULT_LOGS/librarian-manifest.json ---
  # lib/manifest.sh L33: MANIFEST_PATH defaults to $VAULT_LOGS/librarian-manifest.json
  cp "$FIXTURE_CLAUDE_HOME/librarian-manifest.json" "$VR/Logs/librarian-manifest.json"

  # --- Hermetic env ---
  HOME="$subroot"
  CLAUDE_HOME="$CH"
  VAULT_ROOT="$VR"
  VAULT_LOGS="$VR/Logs"
  PLANS_DIR="$PD"
  HOOKS_STATE="$CH/hooks/state"
  MANIFEST_PATH="$VR/Logs/librarian-manifest.json"
  USER_MANIFEST_PATH="$CH/user-manifest.json"
  FM_VAULT_SCHEMA="$CH/schemas/vault-schema.json"
  export HOME CLAUDE_HOME VAULT_ROOT VAULT_LOGS PLANS_DIR HOOKS_STATE \
         MANIFEST_PATH USER_MANIFEST_PATH FM_VAULT_SCHEMA

  # --- Run integrity capability chain ---
  # Aggregate log is written AFTER the chain — pre-writing it would cause
  # frontmatter-enforce to flag the still-empty session-close-*.md file as
  # missing required `type/log-type/date/timestamp` fields (detect_type infers
  # type=log from path). Post-write also matches the canonical session-close
  # Step-6 ordering documented in SKILL.md L1305.
  local total_findings=0
  local cap_exit_nonzero=0
  local cap_status_lines=""

  for cap in $INTEGRITY_CAPS; do
    local cap_script="$CH/skills/librarian/capabilities/${cap}.sh"
    if [ ! -x "$cap_script" ] && [ ! -r "$cap_script" ]; then
      emit_fail "[$variant] capability missing: $cap"
      continue
    fi

    local findings_file="$subroot/findings-${cap}.ndjson"
    : > "$findings_file"
    FINDINGS_OUTPUT="$findings_file" export FINDINGS_OUTPUT

    local flag; flag="$(cap_flags "$cap")"
    if [ -n "$flag" ]; then
      bash "$cap_script" "$flag" >"$subroot/${cap}.stdout" 2>"$subroot/${cap}.stderr"
    else
      bash "$cap_script" >"$subroot/${cap}.stdout" 2>"$subroot/${cap}.stderr"
    fi
    local rc=$?

    local fcount; fcount=$(wc -l < "$findings_file" | tr -d ' ')
    total_findings=$((total_findings + fcount))

    cap_status_lines="${cap_status_lines}### ${cap}

  exit: ${rc}
  findings emitted: ${fcount}
  flag: ${flag:-<none>}

"

    if [ "$rc" -ne 0 ]; then
      cap_exit_nonzero=1
      printf '\n%s\n' '---' >&2
      printf '[%s] capability %s exited %d\n' "$variant" "$cap" "$rc" >&2
      printf '  stderr (last 20 lines):\n' >&2
      tail -20 "$subroot/${cap}.stderr" >&2
      printf '  stdout (last 20 lines):\n' >&2
      tail -20 "$subroot/${cap}.stdout" >&2
    fi

    if [ "$fcount" -gt 0 ]; then
      printf '\n%s\n' '---' >&2
      printf '[%s] capability %s emitted %d findings\n' "$variant" "$cap" "$fcount" >&2
      head -20 "$findings_file" >&2
    fi
  done

  # --- Write aggregated log AFTER capability chain ---
  local ts; ts=$(date -u +"%Y%m%d-%H%M%S")
  local agg_log="$VR/Logs/session-close-${ts}.md"
  {
    printf '# session-close (synthetic, T-12 hermetic)\n\n'
    printf 'Variant: %s\n' "$variant"
    printf 'Vault: %s\n' "$VR"
    printf 'Claude home: %s\n' "$CH"
    printf 'Plans: %s\n\n' "$PD"
    printf '## Capability runs\n\n'
    printf '%s' "$cap_status_lines"
    printf '## Totals\n\n'
    printf 'Total findings emitted: %d\n' "$total_findings"
    printf 'Any non-zero exit: %d\n' "$cap_exit_nonzero"
  } > "$agg_log"

  # --- AC#1: chain completion (every cap exit 0) ---
  if [ "$cap_exit_nonzero" -eq 0 ]; then
    emit_pass "[$variant] AC#1 /librarian full chain completes (all 5 caps exit 0)"
  else
    emit_fail "[$variant] AC#1 chain failed (one or more capabilities exited non-zero)"
  fi

  # --- AC#2: aggregated log present in Logs/ ---
  local glob_match; glob_match=$(ls "$VR/Logs/"session-close-*.md 2>/dev/null | head -1)
  if [ -n "$glob_match" ] && [ -s "$glob_match" ]; then
    emit_pass "[$variant] AC#2 aggregated log present at $glob_match"
  else
    emit_fail "[$variant] AC#2 aggregated log absent or empty under $VR/Logs/"
  fi

  # --- AC#3: librarian-manifest.json has 7 top-level data sections ---
  local missing=""
  for sec in $EXPECTED_SECTIONS; do
    if ! jq -e --arg k "$sec" 'has($k)' "$MANIFEST_PATH" >/dev/null 2>&1; then
      missing="$missing $sec"
    fi
  done
  if [ -z "$missing" ]; then
    emit_pass "[$variant] AC#3 manifest has 7 expected top-level sections"
  else
    emit_fail "[$variant] AC#3 manifest missing sections:$missing"
  fi

  # --- AC#4: zero unexpected findings ---
  if [ "$total_findings" -eq 0 ]; then
    emit_pass "[$variant] AC#4 zero unexpected findings (sum across 5 caps)"
  else
    emit_fail "[$variant] AC#4 unexpected findings emitted: $total_findings (expected 0)"
  fi
}

# --- Main loop ---
printf '=== Plan 71 SP04 T-12 hermetic end-to-end ===\n'
printf 'FOUNDATION_REPO=%s\n' "$FOUNDATION_REPO"

run_variant structured
run_variant flat

# --- AC#5 (composite): both variants passed ---
# This is implicit if all per-variant ACs above passed. Surface explicitly.
if [ "$FAIL" -eq 0 ]; then
  emit_pass "AC#5 both has_structured_projects variants passed"
else
  emit_fail "AC#5 at least one variant did not fully pass"
fi

# --- Summary ---
printf '\n=== T-12 summary ===\n'
printf 'PASS: %d\nFAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf 'Failed:%s\n' "$FAILED_AC" >&2
  exit 1
fi
exit 0
