#!/bin/bash
# tests/foundation/librarian-full/capability-coverage.sh
#
# Plan 71 SP04 T-12 c4 — Smoke harness for the 12 mechanical-tier librarian
# capabilities NOT covered by:
#   (a) skills/librarian/capabilities/tests/synthetic-*.sh per-cap suite
#   (b) tests/foundation/librarian-full/run.sh (which covers the 5 integrity
#       caps in /librarian full)
#
# Targets the carry-forward deferred from T-2 / T-9a / T-5a / SP05 T-1..T-3
# and the AR-prefix mixed-fixture variant deferred from T-10 (per S42 close
# carry-forward block).
#
# Coverage matrix (mechanical tier only — judgment tier excluded):
#                              tested by per-cap   covered by run.sh
#   architect-triage           YES (AR-prefix)
#   capability-registry-parity YES (parity + runtime)
#   librarian-manifest-validate YES
#   rename-detect              YES
#   rename-history-sync        YES
#   rename-cascade             YES
#   sync-check                 YES (gate)
#   trinity-drift-detect       YES
#   wikilink-repair            YES
#   frontmatter-enforce                            YES
#   xref-check                                     YES
#   log-archive                                    YES
#   stale-detect                                   YES
#   placement-validate                             YES
#   ----- THIS HARNESS COVERS THE REMAINING 12 -----
#   backup
#   cron-log-architecture
#   drift-sweep
#   entity-parity
#   handoff-disposition-check
#   people-audit
#   plan-index
#   plan-parent-resolve
#   sanctioned-schema-drift-detect
#   skill-parity
#   tag-coverage-audit
#   waiver-audit
#
# Smoke-test contract per capability:
#   PASS  exit 0 AND findings_file is empty (zero unexpected findings against
#         known-zero-drift baseline fixture)
#   SKIP  capability needs per-fixture seeding beyond the minimal vault
#         (e.g., backup needs git repos; cron-log-architecture needs plists);
#         documented inline with reason
#   FAIL  exit non-zero OR findings_file non-empty against minimal fixture
#
# Hermetic isolation: identical pattern to run.sh (HOME-override + symlinked
# CLAUDE_HOME + dogfood-root-helper teardown trap).
#
# Exit codes:
#   0  every non-skipped cap PASS
#   1  one or more caps FAIL
#   2  setup error
#
# R-23 bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-foundations-v2}"
TEST_DIR="$FOUNDATION_REPO/tests/foundation"
FIXTURE_VAULT="$TEST_DIR/fixtures/vault-minimal"
FIXTURE_CLAUDE_HOME="$TEST_DIR/fixtures/claude-home"

# Capability list (one per line). Per-cap behavior resolved via lookup
# functions below. Tab-separated record parsing was rejected after a
# consecutive-tab field-collapse bug surfaced (bash read -r with single-char
# whitespace-class IFS collapses adjacent tabs into one separator).
CAPS_UNDER_TEST="backup
cron-log-architecture
drift-sweep
entity-parity
handoff-disposition-check
people-audit
plan-index
plan-parent-resolve
sanctioned-schema-drift-detect
skill-parity
tag-coverage-audit
waiver-audit"

# cap_flags <name> — print the safest invocation flags (or empty for default).
cap_flags() {
  case "$1" in
    backup|drift-sweep|entity-parity|plan-index|plan-parent-resolve|skill-parity|waiver-audit)
      printf '%s' '--dry-run' ;;
    *) printf '%s' '' ;;
  esac
}

# cap_skip_reason <name> — print SKIP reason (or empty to run).
# Per-capability skip rationale resolved AFTER first empirical run; reasons
# below reflect actual behavior against the minimal fixture, not
# assumed/imagined failures.
cap_skip_reason() {
  case "$1" in
    backup)
      printf '%s' 'requires git-initialized vault + plans repos; minimal fixture has none (defer to T-13 dogfood)' ;;
    plan-index)
      printf '%s' 'capability hard-aborts (exit 4) on empty PLANS_DIR — "walk found 0 plan roots; aborting to prevent _index.md wipe" — a load-bearing safeguard, not a fixture defect' ;;
    *) printf '%s' '' ;;
  esac
}

if [ ! -d "$FOUNDATION_REPO" ]; then
  printf 'capability-coverage: FOUNDATION_REPO not found: %s\n' "$FOUNDATION_REPO" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'capability-coverage: jq not on PATH\n' >&2
  exit 2
fi

# shellcheck source=/dev/null
. "$FOUNDATION_REPO/tests/dogfood-root-helper.sh"
printf 'DOGFOOD_ROOT=%s\n' "$DOGFOOD_ROOT"

if [ -n "${T12_KEEP_DOGFOOD:-}" ]; then
  trap - EXIT INT TERM
  printf 'T12_KEEP_DOGFOOD=1 — cleanup trap disabled; inspect %s\n' "$DOGFOOD_ROOT"
fi

PASS=0
FAIL=0
SKIP=0
FAILED=""

# --- Materialize hermetic CLAUDE_HOME + vault (single variant — structured) ---
# Coverage harness uses one variant since it tests capability-existence, not
# manifest-shape behavior. T-12 c3 (run.sh) already exercises both variants.
SUBROOT="$DOGFOOD_ROOT/coverage"
mkdir -p "$SUBROOT"
CH="$SUBROOT/.claude"
VR="$SUBROOT/vault"
PD="$SUBROOT/plans"
mkdir -p "$CH/hooks/lib" "$CH/hooks/state" "$CH/skills" "$CH/schemas" "$VR" "$PD"

# Empty cron-wrappers dir for cron-log-architecture (reads $CRON_WRAPPERS).
mkdir -p "$CH/orchestrator/cron-wrappers"
# Empty hook-audit.log + cascade-waivers.json for waiver-audit (probes both).
: > "$CH/hooks/state/hook-audit.log"
printf '{"waivers":[]}' > "$CH/hooks/cascade-waivers.json"

for f in "$FOUNDATION_REPO/lib/"*.sh; do
  [ -f "$f" ] && ln -s "$f" "$CH/hooks/lib/$(basename "$f")"
done
ln -s "$FOUNDATION_REPO/skills/librarian" "$CH/skills/librarian"
for f in "$FOUNDATION_REPO/schemas/"*.json; do
  [ -f "$f" ] && ln -s "$f" "$CH/schemas/$(basename "$f")"
done

cp -R "$FIXTURE_VAULT/." "$VR/"
[ -f "$FIXTURE_VAULT/Logs/.gitkeep" ] && touch "$VR/Logs/.gitkeep"
find "$VR" -type f -exec touch {} +

python3 - "$FIXTURE_CLAUDE_HOME/user-manifest-structured.json" \
          "$CH/user-manifest.json" "$VR" "$PD" <<'PY'
import json, sys
src, dst, vr, pd = sys.argv[1:5]
m = json.load(open(src))
m["paths"]["vault_root"] = vr
m["paths"]["plans_root"] = pd
m["vault"]["root"] = vr
json.dump(m, open(dst, "w"), indent=2, ensure_ascii=True)
PY

cp "$FIXTURE_CLAUDE_HOME/librarian-manifest.json" "$VR/Logs/librarian-manifest.json"

HOME="$SUBROOT"
CLAUDE_HOME="$CH"
VAULT_ROOT="$VR"
VAULT_LOGS="$VR/Logs"
PLANS_DIR="$PD"
HOOKS_STATE="$CH/hooks/state"
MANIFEST_PATH="$VR/Logs/librarian-manifest.json"
USER_MANIFEST_PATH="$CH/user-manifest.json"
FM_VAULT_SCHEMA="$CH/schemas/vault-schema.json"
CRON_WRAPPERS="$CH/orchestrator/cron-wrappers"
SCHEMAS_DIR="$CH/schemas"
# sanctioned-schema-drift-detect compares $FOUNDATION_REPO/schemas/<n>.json
# (source of truth) against $LIVE_SCHEMAS/<n>.json (deployed copy). The
# capability resolves both via env overrides — we point them at the real
# foundation-repo and the symlinked CH/schemas (which transitively links
# back to the same files), so the comparison should report zero drift.
LIVE_SCHEMAS="$CH/schemas"
export HOME CLAUDE_HOME VAULT_ROOT VAULT_LOGS PLANS_DIR HOOKS_STATE \
       MANIFEST_PATH USER_MANIFEST_PATH FM_VAULT_SCHEMA CRON_WRAPPERS \
       SCHEMAS_DIR FOUNDATION_REPO LIVE_SCHEMAS

# --- Per-capability smoke loop ---
printf '\n=== capability-coverage smoke harness ===\n'
: > "$SUBROOT/results.log"

printf '%s\n' "$CAPS_UNDER_TEST" | while IFS= read -r cap; do
  [ -z "${cap:-}" ] && continue
  cap_script="$CH/skills/librarian/capabilities/${cap}.sh"
  if [ ! -r "$cap_script" ]; then
    printf '  FAIL: %s — script missing at %s\n' "$cap" "$cap_script"
    echo "FAIL:$cap:script-missing" >> "$SUBROOT/results.log"
    continue
  fi

  reason="$(cap_skip_reason "$cap")"
  if [ -n "$reason" ]; then
    printf '  SKIP: %s — %s\n' "$cap" "$reason"
    echo "SKIP:$cap:$reason" >> "$SUBROOT/results.log"
    continue
  fi

  flag="$(cap_flags "$cap")"
  findings_file="$SUBROOT/findings-${cap}.ndjson"
  : > "$findings_file"
  FINDINGS_OUTPUT="$findings_file" export FINDINGS_OUTPUT

  # </dev/null guards against capabilities (e.g., handoff-disposition-check)
  # that read stdin — without it they drain the while-loop's pipe and the
  # next read returns EOF.
  if [ -n "$flag" ]; then
    bash "$cap_script" "$flag" </dev/null >"$SUBROOT/${cap}.stdout" 2>"$SUBROOT/${cap}.stderr"
  else
    bash "$cap_script" </dev/null >"$SUBROOT/${cap}.stdout" 2>"$SUBROOT/${cap}.stderr"
  fi
  rc=$?

  fcount=$(wc -l < "$findings_file" | tr -d ' ')

  if [ "$rc" -eq 0 ] && [ "$fcount" -eq 0 ]; then
    printf '  PASS: %s (exit=0, findings=0, flag=%s)\n' "$cap" "${flag:-<none>}"
    echo "PASS:$cap" >> "$SUBROOT/results.log"
  else
    printf '  FAIL: %s (exit=%d, findings=%d, flag=%s)\n' "$cap" "$rc" "$fcount" "${flag:-<none>}"
    if [ "$rc" -ne 0 ]; then
      printf '    stderr (last 5):\n'
      tail -5 "$SUBROOT/${cap}.stderr" | sed 's/^/      /'
    fi
    if [ "$fcount" -gt 0 ]; then
      printf '    findings (head 3):\n'
      head -3 "$findings_file" | sed 's/^/      /'
    fi
    echo "FAIL:$cap:exit=$rc:findings=$fcount" >> "$SUBROOT/results.log"
  fi
done

# --- Tally from results.log (subshell side-effect persistence) ---
if [ ! -f "$SUBROOT/results.log" ]; then
  printf 'capability-coverage: results.log not produced — pipeline failure\n' >&2
  exit 1
fi
# grep -c always prints a count to stdout (even 0) and exits 1 when the count
# is 0. Use `|| true` rather than `|| echo 0` to avoid the "0\n0" double-print
# that surfaces from the substitution capturing both grep's emitted "0" and
# the fallback echo.
PASS=$(grep -c '^PASS:' "$SUBROOT/results.log" 2>/dev/null || true)
FAIL=$(grep -c '^FAIL:' "$SUBROOT/results.log" 2>/dev/null || true)
SKIP=$(grep -c '^SKIP:' "$SUBROOT/results.log" 2>/dev/null || true)

printf '\n=== smoke summary ===\n'
printf 'PASS: %s\nFAIL: %s\nSKIP: %s\n' "$PASS" "$FAIL" "$SKIP"

if [ "$FAIL" -ne 0 ]; then
  printf '\nFailures:\n'
  grep '^FAIL:' "$SUBROOT/results.log" | sed 's/^/  /'
  exit 1
fi
exit 0
