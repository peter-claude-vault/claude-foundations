#!/bin/bash
# dual-invocation-wiring-test.sh — Plan 81 SP01 T-20 G1 dual-invocation wiring.
#
# T-19's parallel-run-test.sh validates DECISION EQUIVALENCE between the two
# helpers. This test validates the WIRING in pre-write-guard.sh that drives
# them both: shadow-NEW-then-authoritative-OLD, parallel-run.log row written,
# OLD's decision returned, NEW crash falls through (error_action: ignore).
#
# Hermetic: stubs both $G1_NEW_HELPER and $G1_HELPER inside a tmpdir; runs
# pre-write-guard.sh end-to-end via stdin payload mimicking Claude Code's
# PreToolUse hook input. No live $HOME/.claude touched.
#
# Cases:
#   T1: both helpers pass-through → no decision returned, parallel-run.log row
#       written with new=allow + old=allow + divergent=false
#   T2: NEW deny + OLD allow → OLD authoritative (no JSON returned), but
#       parallel-run.log row carries divergent=true so r55-parallel-run-audit
#       (T-9) catches it
#   T3: NEW allow + OLD deny → JSON deny RETURNED (OLD authoritative);
#       parallel-run.log row carries divergent=true
#   T4: NEW crash + OLD allow → pass-through (error_action: ignore);
#       parallel-run.log row carries new.exit != 0 + verdict=crash
#   T5: NEW missing + OLD deny → still emits deny (NEW absent is graceful)
#
# R-23: bash 3.2 compat (macOS /bin/bash).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PRE_WRITE_GUARD="$REPO_ROOT/hooks/pre-write-guard.sh"

[[ -x "$PRE_WRITE_GUARD" ]] || { echo "FAIL: $PRE_WRITE_GUARD not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }

PASS=0
FAIL=0
TMPROOT=""

cleanup() { [[ -n "$TMPROOT" ]] && rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM

assert_eq() {
  local exp="$1" act="$2" label="$3"
  if [[ "$exp" == "$act" ]]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: expected=%q actual=%q\n' "$label" "$exp" "$act" >&2
    FAIL=$((FAIL+1))
  fi
}

# Build a stub helper that emits a fixed verdict + exit code.
# Usage: mk_stub <path> <verdict: allow|deny|crash> [decision-json-if-deny]
mk_stub() {
  local target="$1" verdict="$2" payload="${3:-}"
  case "$verdict" in
    allow)
      cat >"$target" <<'STUB'
#!/bin/bash
exit 0
STUB
      ;;
    deny)
      # payload should be the full hookSpecificOutput JSON to emit.
      # Default to a synthetic deny if not provided.
      if [[ -z "$payload" ]]; then
        payload='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"stub deny"}}'
      fi
      cat >"$target" <<STUB
#!/bin/bash
printf '%s\n' '$payload'
exit 0
STUB
      ;;
    crash)
      cat >"$target" <<'STUB'
#!/bin/bash
echo "stub crash" >&2
exit 1
STUB
      ;;
  esac
  chmod +x "$target"
}

# Run pre-write-guard.sh with stubbed helpers. Captures stdout + exit + log row.
# Sets globals: STDOUT, EXIT, LAST_LOG_ROW
run_case() {
  local case_name="$1" new_verdict="$2" old_verdict="$3" file_path="$4"
  local case_dir="$TMPROOT/$case_name"
  # Synthesize a minimal $HOME/.claude/ tree so pre-write-guard.sh's
  # `source $HOME/.claude/hooks/lib/paths.sh` succeeds.
  mkdir -p "$case_dir/.claude/hooks/lib" "$case_dir/.claude/hooks/state" "$case_dir/state"
  cp "$REPO_ROOT/hooks/lib/paths.sh" "$case_dir/.claude/hooks/lib/paths.sh"
  local new_helper="$case_dir/live-guard.sh"
  local old_helper="$case_dir/plan-71-live-guard.sh"
  if [[ "$new_verdict" != "missing" ]]; then
    mk_stub "$new_helper" "$new_verdict"
  fi
  mk_stub "$old_helper" "$old_verdict"
  local input
  input=$(jq -nc \
    --arg fp "$file_path" \
    '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:"x",new_string:"y"}}')
  set +e
  STDOUT=$(printf '%s' "$input" | \
    HOME="$case_dir" \
    HOOKS_STATE_OVERRIDE="$case_dir/state" \
    CLAUDE_HOME="$case_dir/.claude" \
    G1_NEW_HELPER="$new_helper" \
    G1_HELPER="$old_helper" \
    bash "$PRE_WRITE_GUARD" 2>"$case_dir/.stderr")
  EXIT=$?
  set -e
  LAST_LOG_ROW=""
  if [[ -f "$case_dir/state/parallel-run.log" ]]; then
    LAST_LOG_ROW=$(tail -n1 "$case_dir/state/parallel-run.log")
  fi
}

main() {
  TMPROOT=$(mktemp -d -t dual-invocation.XXXXXX)
  # NOTE: this test scopes to the G1 block only. The rest of pre-write-guard.sh
  # (R-23/R-24/R-27/R-32/R-33/...) requires a richer environment to exit 0 on
  # pass-through; that's outside this test's scope. We verify G1 ran by
  # asserting (a) STDOUT is what G1 produced and (b) parallel-run.log got a row
  # of the expected shape. The script's overall exit code is intentionally not
  # checked when G1 takes the pass-through path — it reflects downstream R-rule
  # environment, not G1 wiring.

  printf '\n[T1] both pass-through → no G1 decision, log divergent=false\n'
  run_case "t1" "allow" "allow" "/tmp/some/file.txt"
  assert_eq "" "$STDOUT" "T1.1: no decision JSON returned"
  assert_eq "allow" "$(echo "$LAST_LOG_ROW" | jq -r '.new_helper.verdict')" "T1.2: new=allow"
  assert_eq "allow" "$(echo "$LAST_LOG_ROW" | jq -r '.old_helper.verdict')" "T1.3: old=allow"
  assert_eq "false" "$(echo "$LAST_LOG_ROW" | jq -r '.divergent')" "T1.4: divergent=false"

  printf '\n[T2] NEW deny + OLD allow → OLD authoritative, divergent=true\n'
  run_case "t2" "deny" "allow" "/tmp/some/file.txt"
  assert_eq "" "$STDOUT" "T2.1: no decision JSON (OLD allowed; authoritative)"
  assert_eq "deny" "$(echo "$LAST_LOG_ROW" | jq -r '.new_helper.verdict')" "T2.2: new=deny"
  assert_eq "allow" "$(echo "$LAST_LOG_ROW" | jq -r '.old_helper.verdict')" "T2.3: old=allow"
  assert_eq "true" "$(echo "$LAST_LOG_ROW" | jq -r '.divergent')" "T2.4: divergent=true"

  printf '\n[T3] NEW allow + OLD deny → deny RETURNED (OLD authoritative)\n'
  run_case "t3" "allow" "deny" "/tmp/some/file.txt"
  assert_eq "deny" "$(echo "$STDOUT" | jq -r '.hookSpecificOutput.permissionDecision')" "T3.1: deny JSON returned"
  assert_eq "allow" "$(echo "$LAST_LOG_ROW" | jq -r '.new_helper.verdict')" "T3.2: new=allow"
  assert_eq "deny" "$(echo "$LAST_LOG_ROW" | jq -r '.old_helper.verdict')" "T3.3: old=deny"
  assert_eq "true" "$(echo "$LAST_LOG_ROW" | jq -r '.divergent')" "T3.4: divergent=true"

  printf '\n[T4] NEW crash + OLD allow → pass-through (error_action: ignore)\n'
  run_case "t4" "crash" "allow" "/tmp/some/file.txt"
  assert_eq "" "$STDOUT" "T4.1: no decision JSON (NEW crashed but ignored)"
  assert_eq "crash" "$(echo "$LAST_LOG_ROW" | jq -r '.new_helper.verdict')" "T4.2: new=crash"
  local new_exit
  new_exit=$(echo "$LAST_LOG_ROW" | jq -r '.new_helper.exit')
  if [[ "$new_exit" -ne 0 ]]; then
    printf '  PASS T4.3: new_helper.exit non-zero (=%s)\n' "$new_exit"
    PASS=$((PASS+1))
  else
    printf '  FAIL T4.3: new_helper.exit expected non-zero, got %s\n' "$new_exit" >&2
    FAIL=$((FAIL+1))
  fi
  assert_eq "allow" "$(echo "$LAST_LOG_ROW" | jq -r '.old_helper.verdict')" "T4.4: old=allow"

  printf '\n[T5] NEW missing + OLD deny → still emits deny\n'
  run_case "t5" "missing" "deny" "/tmp/some/file.txt"
  assert_eq "deny" "$(echo "$STDOUT" | jq -r '.hookSpecificOutput.permissionDecision')" "T5.1: deny JSON returned"
  # NEW missing → not invoked → verdict logged as 'allow' (empty-stdout default)
  # since exit defaults to 0 and output is empty. This is intentional graceful
  # degradation: missing helper is indistinguishable from helper-passes-through
  # in the audit row. Acceptable per T-20 spec ("error_action: ignore").
  assert_eq "deny" "$(echo "$LAST_LOG_ROW" | jq -r '.old_helper.verdict')" "T5.2: old=deny logged"

  printf '\n========================================\n'
  printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
  printf '========================================\n'
  [[ "$FAIL" -eq 0 ]]
}

main "$@"
