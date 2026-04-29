#!/usr/bin/env bash
# manifest-missing-graceful.sh — SP02 T-10 commit 4.
#
# Delete user-manifest.json from a fully-built sandbox; fire all 18 hooks;
# assert exit 0 graceful-degrade per SP02 spec Constraint:
#
#   "Every hook exits 0 on missing manifest; no silent runtime failures
#    on fresh install."
#
# Stderr warnings are acceptable (the manifest_get helper degrades to
# empty, paths.sh falls back to install-convention defaults). What is not
# acceptable: non-zero exit, "command not found", "syntax error",
# unbound-variable crashes.
#
# Differs from clean-vault-silent-fire: that test asserts silence WITH
# manifest. This one asserts no-crash WITHOUT manifest. Both are needed —
# silence and graceful-degrade are independent properties.
#
# Bash 3.2 compatible (R-23). Sandbox HOME-override pattern.

set -u

SBX="/tmp/manifest-missing-graceful-sbx-$$"
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

make_sbx_no_manifest() {
  rm -rf "$SBX"
  mkdir -p "$SBX/.claude/hooks/lib" "$SBX/.claude/hooks/state" \
           "$SBX/.claude/hooks/config" "$SBX/.claude/schemas" \
           "$SBX/.claude/skills/librarian/lib" "$SBX/.claude-plans" \
           "$SBX/vault/Logs/.coordination" \
           "$SBX/.claude/projects"
  cp "$SRC/hooks"/*.sh "$SBX/.claude/hooks/"
  cp "$SRC/lib"/*.sh "$SBX/.claude/hooks/lib/"

  echo '{"version":2,"entries":[]}' > "$SBX/.claude/hooks/config/doc-dependencies.json"
  cat > "$SBX/.claude/schemas/vault-schema.json" <<'JSON'
{"schema_version":"1.0.0","_aliases":{}}
JSON
  # plan-path.sh stub — installed at hooks/lib/ post-SP02 T-9.
  cat > "$SBX/.claude/hooks/lib/plan-path.sh" <<'PLANPATH'
classify_plan_path() { echo "0|0|"; }
PLANPATH
  echo '{"sessions":{},"pending_reconciliation":false,"last_reconciled":""}' \
    > "$SBX/vault/Logs/.coordination/session-registry.json"

  # Pre-create memory dir matching pwd-derived slug
  local slug
  slug=$(echo "$SBX" | sed 's|/|-|g')
  mkdir -p "$SBX/.claude/projects/${slug}/memory"
  cat > "$SBX/.claude/projects/${slug}/memory/.consolidation-state.json" <<'JSON'
{"config":{"hours_threshold":24,"sessions_threshold":5},"last_consolidation":"1970-01-01T00:00:00Z","sessions_since_last":0,"last_session_id":""}
JSON
  echo "# Memory Index" > "$SBX/.claude/projects/${slug}/memory/MEMORY.md"

  # CRITICAL: do NOT write user-manifest.json. The whole point of this
  # test is hooks fire without a manifest present.
}

run_hook() {
  local hook="$1" stdin="$2" extra_env="${3:-}"
  env -i HOME="$SBX" CLAUDE_HOME="$SBX/.claude" \
    PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
    VAULT_ROOT="$SBX/vault" PLANS_DIR="$SBX/.claude-plans" \
    PWD="$SBX" $extra_env \
    bash -c "cd '$SBX' && bash '$SBX/.claude/hooks/$hook'" <<< "$stdin"
}

# Graceful-degrade assertion: exit 0; stderr-warnings allowed.
assert_graceful() {
  local hook="$1" stdin="$2" extra_env="${3:-}"
  local out err rc err_file
  err_file="$SBX/.err.$$"
  out=$(run_hook "$hook" "$stdin" "$extra_env" 2>"$err_file")
  rc=$?
  err=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"

  if [ "$rc" -ne 0 ]; then
    record_fail "$hook" "expected exit 0 (graceful-degrade), got $rc | stdout: $out | stderr: $err"
    return
  fi

  # Detect crash signatures in stderr
  case "$err" in
    *"unbound variable"*|*"command not found"*|*"syntax error"*|*"parse error"*)
      record_fail "$hook" "crash signature in stderr: $err"
      return
      ;;
  esac

  if [ -n "$err" ]; then
    record_pass "$hook (exit 0; stderr warning ok)"
  else
    record_pass "$hook (exit 0; silent)"
  fi
}

# ============================================================================
# Build sandbox WITHOUT manifest
# ============================================================================
make_sbx_no_manifest

# Sanity-check: confirm manifest absent
if [ -f "$SBX/.claude/user-manifest.json" ]; then
  echo "TEST BUG: user-manifest.json exists in no-manifest sandbox" >&2
  exit 2
fi

# ============================================================================
# Fire all 18 hooks
# ============================================================================

# --- PreToolUse (1) ---
INPUT=$(jq -nc --arg fp "$SBX/junk/some-file.txt" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"x"}}')
assert_graceful "pre-write-guard.sh" "$INPUT"

# --- PostToolUse (3) ---
INPUT=$(jq -nc --arg fp "$SBX/junk/some-file.txt" \
  --arg sid "test-sid-1234" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"x"},session_id:$sid}')
assert_graceful "post-write-verify.sh" "$INPUT"
assert_graceful "track-vault-write.sh" "$INPUT"
assert_graceful "tasks-md-autosync.sh" "$INPUT"

# --- SessionStart (3) ---
INPUT=$(jq -nc '{session_id:"test-sid-1234",source:"startup"}')
assert_graceful "session-register.sh" "$INPUT"
assert_graceful "cron-health-banner.sh" "$INPUT"
assert_graceful "session-start-canary.sh" "$INPUT"

# --- SessionEnd (4) ---
INPUT=$(jq -nc '{session_id:"test-sid-1234",reason:"clear"}')
assert_graceful "session-deregister.sh" "$INPUT"
assert_graceful "memory-consolidation-check.sh" "$INPUT"
assert_graceful "auto-commit-surfaces.sh" "" "CLAUDE_SESSION_ID=test-sid-1234"
assert_graceful "reconcile-sessions.sh" ""

# --- UserPromptSubmit (1) ---
INPUT=$(jq -nc '{session_id:"test-sid-1234"}')
assert_graceful "prompt-context.sh" "$INPUT"

# --- Stop (2) ---
INPUT=$(jq -nc '{session_id:"test-sid-1234"}')
assert_graceful "stop-checkpoint-check.sh" "$INPUT"
assert_graceful "stop-drift-scan.sh" "$INPUT"

# --- PreCompact (1) ---
INPUT=$(jq -nc '{transcript_path:"/dev/null"}')
assert_graceful "pre-compact-checkpoint.sh" "$INPUT"

# --- statusLine (1) ---
INPUT=$(jq -nc '{session_id:"test-sid-1234",context_window:{used_percentage:0}}')
assert_graceful "worker-statusline.sh" "$INPUT"

# --- Spawned helpers (2) ---
err_file="$SBX/.err.run.$$"
env -i HOME="$SBX" CLAUDE_HOME="$SBX/.claude" \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  VAULT_ROOT="$SBX/vault" PWD="$SBX" \
  bash -c "cd '$SBX' && bash '$SBX/.claude/hooks/memory-consolidation-run.sh'" \
  </dev/null >/dev/null 2>"$err_file"
rc=$?
err=$(cat "$err_file" 2>/dev/null || true)
rm -f "$err_file"
case "$err" in
  *"unbound variable"*|*"command not found"*|*"syntax error"*|*"parse error"*)
    record_fail "memory-consolidation-run.sh" "crash signature: $err" ;;
  *)
    if [ "$rc" -eq 0 ]; then
      record_pass "memory-consolidation-run.sh (graceful no-manifest exit 0)"
    else
      record_fail "memory-consolidation-run.sh" "exit $rc | stderr: $err"
    fi ;;
esac

err_file="$SBX/.err.close.$$"
env -i HOME="$SBX" CLAUDE_HOME="$SBX/.claude" \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  VAULT_ROOT="$SBX/vault" PWD="$SBX" \
  bash "$SBX/.claude/hooks/session-auto-close.sh" "test-sid-1234" "" \
  </dev/null >/dev/null 2>"$err_file"
rc=$?
err=$(cat "$err_file" 2>/dev/null || true)
rm -f "$err_file"
case "$err" in
  *"unbound variable"*|*"command not found"*|*"syntax error"*|*"parse error"*)
    record_fail "session-auto-close.sh" "crash signature: $err" ;;
  *)
    if [ "$rc" -eq 0 ]; then
      record_pass "session-auto-close.sh (graceful no-manifest exit 0)"
    else
      record_fail "session-auto-close.sh" "exit $rc | stderr: $err"
    fi ;;
esac

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
