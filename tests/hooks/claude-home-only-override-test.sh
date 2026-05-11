#!/usr/bin/env bash
# tests/hooks/claude-home-only-override-test.sh
#
# Validates the env-override invariant claimed in hooks/README.md: when an
# adopter sets CLAUDE_HOME to a non-default path, the hooks must resolve
# their state directory under the override, not under $HOME/.claude.
#
# Existing hermetic tests override BOTH $HOME and $CLAUDE_HOME to the same
# sandbox base, so they don't actually validate this invariant — a hook that
# hardcoded $HOME/.claude/hooks/state would still pass them. This test sets
# only CLAUDE_HOME (leaves HOME unchanged) and asserts the four state-touching
# hooks read/write under the override.
#
# Targets:
#   - hooks/prompt-context.sh
#   - hooks/session-register.sh
#   - hooks/stop-checkpoint-check.sh
#   - hooks/worker-statusline.sh
#
# Each was rewritten to use ${HOOKS_STATE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/state}.
# This test exercises the CLAUDE_HOME → STATE_DIR resolution path.
#
# Plan 84 SP02 (2026-05-11): context-pressure.json migrated to per-session path
# `sessions/<sid>/context-pressure.json`. worker-statusline requires session_id
# in stdin payload (else skips write); stop-checkpoint-check requires
# CLAUDE_SESSION_ID env (else exits 0 graceful). Test fixture below carries
# TEST_SID through both writer and reader paths to exercise the per-session
# canary location.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WORK="$(mktemp -d)"
trap "rm -rf $WORK" EXIT

# Build a minimal sandbox CLAUDE_HOME with the foundation tree the hooks need
SANDBOX_CLAUDE="$WORK/sandbox-claude"
mkdir -p "$SANDBOX_CLAUDE/hooks/state"
mkdir -p "$SANDBOX_CLAUDE/hooks/lib"

# Copy the four target hooks plus their supporting libs
cp "$REPO_ROOT/hooks/prompt-context.sh" "$SANDBOX_CLAUDE/hooks/"
cp "$REPO_ROOT/hooks/session-register.sh" "$SANDBOX_CLAUDE/hooks/"
cp "$REPO_ROOT/hooks/stop-checkpoint-check.sh" "$SANDBOX_CLAUDE/hooks/"
cp "$REPO_ROOT/hooks/worker-statusline.sh" "$SANDBOX_CLAUDE/hooks/"
cp "$REPO_ROOT/lib/registry.sh" "$SANDBOX_CLAUDE/hooks/lib/" 2>/dev/null || \
  cp "$REPO_ROOT/hooks/lib/registry.sh" "$SANDBOX_CLAUDE/hooks/lib/" 2>/dev/null || true

# Sanity: confirm the sandbox is NOT $HOME/.claude
if [ "$SANDBOX_CLAUDE" = "$HOME/.claude" ]; then
  echo "FAIL: sandbox path collides with real HOME/.claude" >&2
  exit 1
fi

# Plan 84 SP02: per-session pressure file. Test SID + per-session canary.
TEST_SID="claude-home-test-$$-$(date +%s)"
SANDBOX_SESSION_DIR="$SANDBOX_CLAUDE/hooks/state/sessions/$TEST_SID"
SANDBOX_PRESSURE="$SANDBOX_SESSION_DIR/context-pressure.json"
mkdir -p "$SANDBOX_SESSION_DIR"

# Pre-seed a context-pressure state file under the SANDBOX so the hooks
# can read it. If they read from $HOME/.claude/hooks/state instead, they
# either find a different file (real one, polluting test) or no file (and
# silently degrade). Either way, the test detects misrouting.
echo '{"pct": 17, "ts": "2026-01-01T00:00:00Z"}' > "$SANDBOX_PRESSURE"

fail=0

# --- Test 1: worker-statusline.sh writes pressure to SANDBOX, not $HOME/.claude
# worker-statusline reads stdin and writes to STATE_DIR/sessions/<sid>/context-pressure.json
# (Plan 84 SP02 per-session). Payload must include session_id; empty SID skips write.
test1_payload=$(printf '{"context_window":{"used_percentage":33},"session_id":"%s"}' "$TEST_SID")
# Remove the pre-seeded file so we can detect a fresh write
rm -f "$SANDBOX_PRESSURE"
# Snapshot the real $HOME/.claude per-session canary dir (if any) to detect pollution
REAL_SESSION_DIR="$HOME/.claude/hooks/state/sessions/$TEST_SID"
real_before_exists=0
if [ -d "$REAL_SESSION_DIR" ]; then
  real_before_exists=1
fi

# Invoke worker-statusline with ONLY CLAUDE_HOME overridden (HOME unchanged)
echo "$test1_payload" | CLAUDE_HOME="$SANDBOX_CLAUDE" HOOKS_STATE="" \
  bash "$SANDBOX_CLAUDE/hooks/worker-statusline.sh" >/dev/null 2>&1 || true

if [ -f "$SANDBOX_PRESSURE" ]; then
  echo "PASS: worker-statusline.sh wrote pressure file under CLAUDE_HOME override (per-session path)"
else
  echo "FAIL: worker-statusline.sh did NOT write pressure file under CLAUDE_HOME override; STATE_DIR misrouted" >&2
  fail=1
fi

# Verify $HOME/.claude per-session canary dir was NOT polluted
if [ -d "$REAL_SESSION_DIR" ] && [ "$real_before_exists" -eq 0 ]; then
  echo "FAIL: \$HOME/.claude/hooks/state/sessions/$TEST_SID was created by the test (pollution)" >&2
  fail=1
else
  echo "PASS: \$HOME/.claude per-session canary dir not created (no pollution)"
fi

# --- Test 2: stop-checkpoint-check.sh reads pressure from SANDBOX
# Re-seed pressure with low value (< 48%) — should NOT block stop.
# Plan 84 SP02: stop-checkpoint-check requires CLAUDE_SESSION_ID env var.
echo '{"pct": 10}' > "$SANDBOX_PRESSURE"
set +e
CLAUDE_HOME="$SANDBOX_CLAUDE" HOOKS_STATE="" CLAUDE_SESSION_ID="$TEST_SID" \
  bash "$SANDBOX_CLAUDE/hooks/stop-checkpoint-check.sh" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "PASS: stop-checkpoint-check.sh read low pressure from CLAUDE_HOME sandbox; allowed stop (rc=0)"
else
  echo "FAIL: stop-checkpoint-check.sh did not honor CLAUDE_HOME override (rc=$rc; expected 0 for low pressure)" >&2
  fail=1
fi

# --- Test 3: prompt-context.sh + session-register.sh resolve correctly
# These hooks have more complex dependencies (registry.sh, manifest reads).
# We assert only that they don't write to $HOME/.claude/hooks/state when
# CLAUDE_HOME is overridden. They may exit non-zero on missing deps; that's
# fine — the test is about WHERE state writes go, not whether the hook
# completes successfully.
real_state_before_count=0
if [ -d "$HOME/.claude/hooks/state" ]; then
  real_state_before_count=$(find "$HOME/.claude/hooks/state" -newer "$SANDBOX_CLAUDE" -type f 2>/dev/null | wc -l | tr -d ' ')
fi

echo "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"test\",\"session_id\":\"$TEST_SID\"}" | \
  CLAUDE_HOME="$SANDBOX_CLAUDE" HOOKS_STATE="" \
  bash "$SANDBOX_CLAUDE/hooks/prompt-context.sh" >/dev/null 2>&1 || true

echo "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"session_id\":\"$TEST_SID\"}" | \
  CLAUDE_HOME="$SANDBOX_CLAUDE" HOOKS_STATE="" \
  bash "$SANDBOX_CLAUDE/hooks/session-register.sh" >/dev/null 2>&1 || true

real_state_after_count=0
if [ -d "$HOME/.claude/hooks/state" ]; then
  real_state_after_count=$(find "$HOME/.claude/hooks/state" -newer "$SANDBOX_CLAUDE" -type f 2>/dev/null | wc -l | tr -d ' ')
fi

if [ "$real_state_before_count" -eq "$real_state_after_count" ]; then
  echo "PASS: prompt-context.sh + session-register.sh did not write to \$HOME/.claude/hooks/state under CLAUDE_HOME override"
else
  echo "FAIL: \$HOME/.claude/hooks/state gained $((real_state_after_count - real_state_before_count)) new files during test (CLAUDE_HOME override not honored)" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo ""
  echo "All checks passed: 4 target hooks honor CLAUDE_HOME override without HOME override"
fi
exit "$fail"
