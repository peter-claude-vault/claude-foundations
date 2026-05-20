#!/usr/bin/env bash
# tests/sp14-hooks-RUN-ALL.sh
#
# SP14 T-18 — Hook fixture driver. Runs every sp14-hooks-*.sh fixture
# (except this file and the common setup library) in a fresh subprocess,
# emits per-fixture PASS/FAIL, prints a final summary, exits 0 only if
# all fixtures pass.
#
# ============================================================================
#  README — how to use this suite
# ============================================================================
#
# 1. Run a single fixture (recommended during development):
#      bash tests/sp14-hooks-branch1-classA-folder-happy.sh
#    Each fixture is self-contained: jails $HOME under mktemp -d, stages the
#    foundation-repo hooks/ + governance/ tree into the jail, constructs a
#    PreToolUse JSON payload, invokes the hook, asserts the response. No
#    writes to live ~/.claude/ or ~/Documents/Obsidian Vault/.
#
# 2. Run the full suite:
#      bash tests/sp14-hooks-RUN-ALL.sh
#    Exits 0 if every fixture passes; 1 with a per-fixture FAIL report
#    otherwise.
#
# 3. HOME-jailing contract (do-not-violate):
#    - setup_jailed_home (in sp14-hooks-setup.sh) creates a TEMPROOT via
#      mktemp -d, exports HOME=$TEMPROOT, exports VAULT_ROOT=$TEMPROOT/vault,
#      PLANS_DIR=$TEMPROOT/plans, and verifies $HOME matches one of the
#      safe-prefix patterns (/tmp/*, /var/folders/*, /private/...).
#    - stage_substrate copies foundation-repo hooks/ + governance/ +
#      librarian plan-path.sh + lib/registry.sh (or live fallback) into
#      $HOME/.claude/. Governance is ALSO mirrored to
#      $HOME/Code/claude-stem/governance/ because pre-write-guard.sh
#      Branch #2 + Branch #3 hardcode that absolute path.
#    - G1 live-guard.sh is chmod -x'd to fall through during fixtures.
#    - A trap rm -rf "$TEMPROOT" runs on EXIT/INT/TERM.
#
# 4. Fixture → spec.md §7 / hook-branch-implementations.md L-* mapping:
#    | Fixture filename                                    | Branch / function                     | spec.md §7 line |
#    | --------------------------------------------------- | ------------------------------------- | --------------- |
#    | sp14-hooks-branch1-classA-folder-happy.sh           | Branch #1 Class A (folder)            | L-28 happy      |
#    | sp14-hooks-branch1-classB-filetype-violation.sh     | Branch #1 Class C (file-type)         | L-28 violation  |
#    | sp14-hooks-branch1-classC-tagext-skip.sh            | Branch #1 Class D (skill, registered) | L-61 skip       |
#    | sp14-hooks-branch1-classD-writer-scopemiss.sh       | Branch #3 excluded_paths              | L-58 scope-miss |
#    | sp14-hooks-branch2-happy-pastdate.sh                | Branch #2 historical-data warn        | L-74-77 happy   |
#    | sp14-hooks-branch2-violation-edit-historical.sh     | Branch #2 Edit-op path                | L-74-77 viol.   |
#    | sp14-hooks-branch2-skip-futuredate.sh               | Branch #2 future-date pass-through    | L-77 skip       |
#    | sp14-hooks-branch2-scopemiss-no-pattern.sh          | Branch #2 universal-default fall-thru | L-75/L-85 miss  |
#    | sp14-hooks-branch3-happy-valid-frontmatter.sh       | Branch #3 valid writer-ref            | L-58 happy      |
#    | sp14-hooks-branch3-violation-missing-field.sh       | Branch #3 missing required            | L-58 violation  |
#    | sp14-hooks-branch3-violation-bad-enum.sh            | Branch #3 enum violation              | L-58 violation  |
#    | sp14-hooks-branch3-scopemiss-index-md.sh            | Branch #3 excluded_paths              | L-58 scope-miss |
#    | sp14-hooks-branch4-happy-stamped.sh                 | Branch #4 librarian env-stamp pass    | L-78-80 happy   |
#    | sp14-hooks-branch4-violation-unstamped.sh           | Branch #4 unstamped deny              | L-78-80 violat. |
#    | sp14-hooks-branch4-skip-non-librarian-path.sh       | Branch #4 path-scoped (skip)          | L-78-80 skip    |
#    | sp14-hooks-branch4-scopemiss-no-prefix-collision.sh | Branch #4 non-protected basename      | L-78-80 miss    |
#    | sp14-hooks-preasq-dqp-substantive-fires.sh          | pre-asq DQP nudge                     | L-83 happy      |
#    | sp14-hooks-preasq-dqp-trivial-silent.sh             | pre-asq DQP yes/no skip               | L-83 skip       |
#    | sp14-hooks-preasq-hc-substantive-fires.sh           | pre-asq HC fragment                   | L-81-82 fires   |
#    | sp14-hooks-preasq-hc-trivial-silent.sh              | pre-asq HC single-opt skip            | L-81-82 silent  |
#
# 5. Substrate divergences surfaced by fixtures (load-bearing findings):
#    - Branch #1 Class C (pre-write-guard.sh:861) — malformed jq filter
#      `.types // {} | keys[]?, .r32_type_aliases // {} | keys[]?` collapses
#      to `keys[]?` over a string. B1_KNOWN_TYPES is always empty so the
#      Class C nudge NEVER fires; R-32 Tier 2 deny catches the unregistered
#      type with a different message. Corrected filter: parens around each
#      `(... | keys[]?)` alternative.
#    - Pre-write-guard:457 — references PL_CONTENT under `set -u` without
#      initialization when basename is not one of the 4 canonical plan-
#      artifact filenames. Any .md write under ~/.claude-plans/ that is
#      not spec.md / tasks.md / handoff.md / 00-ideation-brief.md trips
#      "PL_CONTENT: unbound variable" → hook exits 1 with no JSON. Fix:
#      initialize PL_CONTENT="" at the top of the if block at line 400.
#    - Branch #4 (line 172) hardcodes `B4_PT_PARENT="$HOME/.claude-plans"`
#      instead of using $PLANS_DIR. Fixtures targeting Branch #4 must
#      construct paths under $HOME/.claude-plans/ regardless of the
#      $PLANS_DIR env value.
#    - DQP/HC KEYWORDS regex is broad ("path" matches "file path"). Single-
#      option confirmation questions must avoid those words to remain in
#      the silent-skip permutation. Possible substrate refinement: tighten
#      to phrase-level keywords (e.g., "which path", "code path").
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0
FAILED_FIXTURES=""

# Enumerate fixtures (excluding setup + RUN-ALL itself).
FIXTURES=$(ls "$SCRIPT_DIR"/sp14-hooks-*.sh 2>/dev/null | \
  grep -v -E '/(sp14-hooks-setup\.sh|sp14-hooks-RUN-ALL\.sh)$' | LC_ALL=C sort)

if [ -z "$FIXTURES" ]; then
  printf 'sp14-hooks-RUN-ALL: no fixtures found under %s\n' "$SCRIPT_DIR" >&2
  exit 2
fi

printf '=== SP14 T-18 Hook Fixtures — RUN-ALL ===\n'

for fix in $FIXTURES; do
  fix_name=$(basename "$fix")
  printf '\n--- %s ---\n' "$fix_name"
  # Run in subshell to isolate env / trap / HOME between fixtures.
  bash "$fix"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf '[PASS] %s\n' "$fix_name"
  else
    FAIL=$((FAIL + 1))
    FAILED_FIXTURES="${FAILED_FIXTURES}
  - $fix_name (rc=$rc)"
    printf '[FAIL] %s (rc=%s)\n' "$fix_name" "$rc"
  fi
done

TOTAL=$((PASS + FAIL))
printf '\n=== SP14 T-18 RUN-ALL SUMMARY ===\n'
printf 'Total fixtures: %d\n' "$TOTAL"
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"

if [ "$FAIL" -ne 0 ]; then
  printf '\nFailed fixtures:%s\n' "$FAILED_FIXTURES"
  exit 1
fi

printf '\nALL FIXTURES PASS (%d/%d)\n' "$PASS" "$TOTAL"
exit 0
