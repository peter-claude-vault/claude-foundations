#!/usr/bin/env bash
# clean-vault-silent-fire.sh — SP02 T-10 commit 1.
#
# All 18 hooks fire silently against an empty vault + minimal manifest.
# Each hook is invoked with valid stdin for its registered event type and
# must (a) exit 0 and (b) emit no Tier 1/Tier 2 advisory text.
#
# Sandbox HOME-override pattern (SP01 T-15 + SP02 T-4 precedent). Bash 3.2
# compatible (R-23). Pre-creates only what every hook needs to bootstrap
# (state file dirs, plan-path classifier, empty registry); zero references
# to Peter-live state.
#
# Hook taxonomy (18 total):
#   PreToolUse[Edit|Write] (1):  pre-write-guard
#   PostToolUse[Edit|Write] (3): post-write-verify, track-vault-write,
#                                 tasks-md-autosync
#   SessionStart (3):            session-register, cron-health-banner,
#                                 session-start-canary
#   SessionEnd (4):              session-deregister, memory-consolidation-check,
#                                 auto-commit-surfaces, reconcile-sessions
#   UserPromptSubmit (1):        prompt-context
#   Stop (2):                    stop-checkpoint-check, stop-drift-scan
#   PreCompact (1):              pre-compact-checkpoint
#   statusLineCommand (1):       worker-statusline
#   Spawned helpers (2):         memory-consolidation-run, session-auto-close
#
# Exit 0 on all green; 1 on any failure. Per-hook PASS/FAIL printed.

set -u

SBX="/tmp/clean-vault-silent-fire-sbx-$$"
SRC="$(cd "$(dirname "$0")/.." && pwd)"

trap 'rm -rf "$SBX"' EXIT

pass=0
fail=0
fail_log=""

record_pass() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
record_fail() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
  fail_log="${fail_log}
  FAIL: $1
    detail: $2"
}

# Build sandbox once: silent-fire test runs all hooks against same clean state.
make_sbx() {
  rm -rf "$SBX"
  mkdir -p "$SBX/.claude/hooks/lib" "$SBX/.claude/hooks/state" \
           "$SBX/.claude/hooks/config" "$SBX/.claude/schemas" \
           "$SBX/.claude/skills/librarian/lib" "$SBX/.claude-plans" \
           "$SBX/vault/Logs/.coordination" \
           "$SBX/.claude/projects"
  cp "$SRC/hooks"/*.sh "$SBX/.claude/hooks/"
  cp "$SRC/lib"/*.sh "$SBX/.claude/hooks/lib/"

  # Empty config JSONs — hooks expect these to exist on fresh install
  echo '{"version":2,"entries":[]}' > "$SBX/.claude/hooks/config/doc-dependencies.json"

  # Minimal vault-schema.json so post-write-verify + stop-drift-scan find one
  cat > "$SBX/.claude/schemas/vault-schema.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "_aliases": {}
}
JSON

  # Minimal plan-path.sh classifier (sourced by pre-write-guard at L171)
  cat > "$SBX/.claude/skills/librarian/lib/plan-path.sh" <<'PLANPATH'
classify_plan_path() {
  echo "0|0|"
}
PLANPATH

  # Empty registry — registered shape per registry.sh EMPTY_REGISTRY
  echo '{"sessions":{},"pending_reconciliation":false,"last_reconciled":""}' \
    > "$SBX/vault/Logs/.coordination/session-registry.json"

  # Minimal user-manifest 1.1.0 — required top-level sections present, all
  # optional hooks/schema/plans sections absent (graceful-degrade tested
  # separately by manifest-missing-graceful.sh).
  cat > "$SBX/.claude/user-manifest.json" <<'JSON'
{
  "identity": {},
  "paths": {},
  "tools": {"messaging": []},
  "vault": {},
  "projects": {"active": []},
  "people": [],
  "behavioral": {"hook_preferences": {}},
  "backlog": {},
  "architect": {},
  "system": {"schema_version": "1.1.0", "opt_outs": []}
}
JSON

  # Pre-create memory dir matching the slug derived by resolve_memory_dir
  # (uses pwd -L which we pin via PWD env below). Without it,
  # memory-consolidation-{check,run} cannot bootstrap their state file.
  local slug
  slug=$(echo "$SBX" | sed 's|/|-|g')
  mkdir -p "$SBX/.claude/projects/${slug}/memory"
  cat > "$SBX/.claude/projects/${slug}/memory/.consolidation-state.json" <<'JSON'
{"config":{"hours_threshold":24,"sessions_threshold":5},"last_consolidation":"1970-01-01T00:00:00Z","sessions_since_last":0,"last_session_id":""}
JSON
  echo "# Memory Index" > "$SBX/.claude/projects/${slug}/memory/MEMORY.md"
}

# Run hook in isolated env. PWD pinned to $SBX so resolve_memory_dir's
# pwd -L returns the slug we pre-created.
run_hook() {
  local hook="$1" stdin="$2" extra_env="${3:-}"
  env -i HOME="$SBX" CLAUDE_HOME="$SBX/.claude" \
    PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
    VAULT_ROOT="$SBX/vault" PLANS_DIR="$SBX/.claude-plans" \
    PWD="$SBX" $extra_env \
    bash -c "cd '$SBX' && bash '$SBX/.claude/hooks/$hook'" <<< "$stdin"
}

# Assert: hook exits 0, emits no advisory text in hookSpecificOutput.
assert_silent_fire() {
  local hook="$1" stdin="$2" extra_env="${3:-}"
  local out err rc err_file
  err_file="$SBX/.err.$$"
  out=$(run_hook "$hook" "$stdin" "$extra_env" 2>"$err_file")
  rc=$?
  err=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"

  if [ "$rc" -ne 0 ]; then
    record_fail "$hook" "expected exit 0, got $rc | stdout: $out | stderr: $err"
    return
  fi

  # If stdout parses as JSON, check additionalContext + permissionDecisionReason
  # are empty. Plain-text stdout is acceptable for hooks that don't emit
  # hookSpecificOutput (e.g., worker-statusline writes only to state).
  if echo "$out" | jq -e . >/dev/null 2>&1; then
    local ctx reason
    ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
    reason=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
    if [ -n "$ctx" ] && [ "$ctx" != "null" ]; then
      record_fail "$hook" "advisory leaked on clean vault: $ctx"
      return
    fi
    if [ -n "$reason" ] && [ "$reason" != "null" ]; then
      record_fail "$hook" "decision-reason leaked on clean vault: $reason"
      return
    fi
  fi

  record_pass "$hook (exit 0, silent)"
}

# Assert: hook exits 0. Used for hooks whose contract is "always emit
# something" (e.g., pre-compact-checkpoint always writes a checkpoint
# reference) — silence is not in their contract.
assert_no_crash() {
  local hook="$1" stdin="$2" extra_env="${3:-}"
  local out err rc err_file
  err_file="$SBX/.err.$$"
  out=$(run_hook "$hook" "$stdin" "$extra_env" 2>"$err_file")
  rc=$?
  err=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"

  if [ "$rc" -ne 0 ]; then
    record_fail "$hook" "expected exit 0, got $rc | stdout: $out | stderr: $err"
    return
  fi
  record_pass "$hook (exit 0; emit-always contract)"
}

# ============================================================================
# Build sandbox
# ============================================================================
make_sbx

# ============================================================================
# Fire all 18 hooks
# ============================================================================

# --- PreToolUse (1) ---
INPUT=$(jq -nc --arg fp "$SBX/junk/some-file.txt" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"x"}}')
assert_silent_fire "pre-write-guard.sh" "$INPUT"

# --- PostToolUse (3) — file outside vault → no-op for vault-aware hooks ---
INPUT=$(jq -nc --arg fp "$SBX/junk/some-file.txt" \
  --arg sid "test-sid-1234" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"x"},session_id:$sid}')
assert_silent_fire "post-write-verify.sh" "$INPUT"
assert_silent_fire "track-vault-write.sh" "$INPUT"
assert_silent_fire "tasks-md-autosync.sh" "$INPUT"

# --- SessionStart (3) ---
INPUT=$(jq -nc '{session_id:"test-sid-1234",source:"startup"}')
assert_silent_fire "session-register.sh" "$INPUT"
assert_silent_fire "cron-health-banner.sh" "$INPUT"
assert_silent_fire "session-start-canary.sh" "$INPUT"

# --- SessionEnd (4) ---
INPUT=$(jq -nc '{session_id:"test-sid-1234",reason:"clear"}')
assert_silent_fire "session-deregister.sh" "$INPUT"
assert_silent_fire "memory-consolidation-check.sh" "$INPUT"
assert_silent_fire "auto-commit-surfaces.sh" "" "CLAUDE_SESSION_ID=test-sid-1234"
assert_silent_fire "reconcile-sessions.sh" ""

# --- UserPromptSubmit (1) ---
INPUT=$(jq -nc '{session_id:"test-sid-1234"}')
assert_silent_fire "prompt-context.sh" "$INPUT"

# --- Stop (2) ---
INPUT=$(jq -nc '{session_id:"test-sid-1234"}')
assert_silent_fire "stop-checkpoint-check.sh" "$INPUT"
assert_silent_fire "stop-drift-scan.sh" "$INPUT"

# --- PreCompact (1) — emit-always contract: writes a checkpoint reference
# regardless of state (panic-checkpoint when no structured sources exist) ---
INPUT=$(jq -nc '{transcript_path:"/dev/null"}')
assert_no_crash "pre-compact-checkpoint.sh" "$INPUT"

# --- statusLine (1) ---
INPUT=$(jq -nc '{session_id:"test-sid-1234",context_window:{used_percentage:0}}')
assert_silent_fire "worker-statusline.sh" "$INPUT"

# --- Spawned helpers (2) — invoked directly with their argv contracts ---
# memory-consolidation-run.sh — no stdin; reads STATE_FILE, runs detached.
# Pre-created above. Should no-op + exit 0 on fresh state.
err_file="$SBX/.err.run.$$"
out=$(env -i HOME="$SBX" CLAUDE_HOME="$SBX/.claude" \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  VAULT_ROOT="$SBX/vault" PWD="$SBX" \
  bash -c "cd '$SBX' && bash '$SBX/.claude/hooks/memory-consolidation-run.sh'" \
  </dev/null 2>"$err_file")
rc=$?
err=$(cat "$err_file" 2>/dev/null || true)
rm -f "$err_file"
if [ "$rc" -eq 0 ]; then
  record_pass "memory-consolidation-run.sh (spawned helper, exit 0)"
else
  record_fail "memory-consolidation-run.sh" "exit $rc | stderr: $err"
fi

# session-auto-close.sh — $1=SESSION_ID $2=FILES_LIST_PATH (empty = no work)
err_file="$SBX/.err.close.$$"
env -i HOME="$SBX" CLAUDE_HOME="$SBX/.claude" \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  VAULT_ROOT="$SBX/vault" PWD="$SBX" \
  bash "$SBX/.claude/hooks/session-auto-close.sh" "test-sid-1234" "" \
  </dev/null >/dev/null 2>"$err_file"
rc=$?
err=$(cat "$err_file" 2>/dev/null || true)
rm -f "$err_file"
if [ "$rc" -eq 0 ]; then
  record_pass "session-auto-close.sh (spawned helper, exit 0 with no files)"
else
  record_fail "session-auto-close.sh" "exit $rc | stderr: $err"
fi

# ============================================================================
# Summary
# ============================================================================
printf '\n----------------------------------\n'
printf 'passed: %s\n' "$pass"
printf 'failed: %s\n' "$fail"
printf '%s\n' '----------------------------------'
if [ "$fail" -gt 0 ]; then
  printf '\nFailures:%s\n' "$fail_log"
  exit 1
fi
exit 0
