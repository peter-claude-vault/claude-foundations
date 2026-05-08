#!/bin/bash
# post-tool-use-manifest.sh — PostToolUse hook firing on plan manifest writes
# (Plan 80/81 SP01 T-13).
#
# Refreshes ~/.claude/state/active-gates.json read-replica when a tool call
# edits a plan manifest under ~/.claude-plans/. Cache-invalidation correctness:
# three trigger points wired across the system (this PostToolUse hook,
# SessionStart hook bootstrap, explicit invocation). live-guard.sh slow-path
# fallback (~50-100ms penalty) is the safety net for missed regen — see
# active-gates-rebuild.sh comments for the mtime contract.
#
# Hook contract (Claude Code PostToolUse):
#   stdin  - JSON event payload: {tool_name, tool_input: {file_path, ...}, ...}
#   stdout - Optional hookSpecificOutput JSON; we emit empty / no decision.
#   timing - Async-dispatched regen MUST NOT block the tool result; we
#            background the rebuild via `&` + disown.
#
# Match conditions (all must hold):
#   tool_name in {Edit, Write, MultiEdit, Update}
#   file_path matches one of:
#     */.claude-plans/*/manifest.json          (top-level master manifest)
#     */.claude-plans/*/[0-9][0-9]-*/manifest.json   (sub-plan manifest)
#
# Output target:
#   ${ACTIVE_GATES_PATH:-$HOME/.claude/state/active-gates.json}
#
# mtime cache invalidation contract (documented per T-13 spec):
#   This hook is the FAST path: regen fires immediately after a manifest write,
#   so the read-replica's regenerated_at moves forward to cover the new mtime.
#   But hook-miss is possible (e.g., direct shell `vi`/git checkout, sandboxed
#   tool invocation, hook disabled). In that case live-guard.sh slow-path
#   fallback walks plan manifests directly — the read-replica is a cache, not
#   a source of truth. The slow-path fallback comparison is mtime-based:
#   if any plan-tree manifest has mtime > active-gates.json regenerated_at,
#   the replica is stale and slow-path is preferred. Cost: ~50-100ms penalty
#   per evaluation; behavior degrades latency before enforcement.
#
# Test-isolation env (mirror T-3.5 contract):
#   PLANS_ROOT_OVERRIDE     - redirect plan-tree walk root
#   ACTIVE_GATES_PATH       - explicit override for read-replica location
#   POST_TOOL_USE_SYNC_MODE  - if set to "1", run regen synchronously (test path)
#   ACTIVE_GATES_REBUILD_BIN - override path to active-gates-rebuild.sh
#   POST_TOOL_USE_LOG       - explicit log path override

set -uo pipefail

# === Read tool event from stdin ===========================================
INPUT=$(cat 2>/dev/null || echo "{}")

# Parse via jq; fall back to no-op if malformed
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# === Match conditions =====================================================
case "$TOOL_NAME" in
  Edit|Write|MultiEdit|Update) ;;
  *) exit 0 ;;
esac

[[ -z "$FILE_PATH" ]] && exit 0

# Match top-level OR sub-plan manifest under any .claude-plans tree
is_plan_manifest=0

# Top-level: */.claude-plans/<plan>/manifest.json
if [[ "$FILE_PATH" == */.claude-plans/*/manifest.json ]]; then
  # Distinguish from sub-plan: parent of basename must NOT match [0-9][0-9]-*
  parent_dir=$(basename "$(dirname "$FILE_PATH")")
  if [[ ! "$parent_dir" =~ ^[0-9][0-9]- ]]; then
    is_plan_manifest=1
  else
    is_plan_manifest=1  # sub-plan also triggers regen
  fi
fi

[[ "$is_plan_manifest" == "0" ]] && exit 0

# === Resolve regen binary =================================================
REBUILD_BIN="${ACTIVE_GATES_REBUILD_BIN:-}"
if [[ -z "$REBUILD_BIN" ]]; then
  # Prefer foundation-repo location (where this hook lives during build);
  # fall back to deployed location.
  if [[ -x "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/active-gates-rebuild.sh" ]]; then
    REBUILD_BIN="${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/active-gates-rebuild.sh"
  elif [[ -x "$HOME/Code/claude-stem/skills/librarian/capabilities/active-gates-rebuild.sh" ]]; then
    REBUILD_BIN="$HOME/Code/claude-stem/skills/librarian/capabilities/active-gates-rebuild.sh"
  else
    # Silent no-op: regen unavailable, slow-path fallback covers correctness
    exit 0
  fi
fi

# === Async regen dispatch =================================================
LOG_PATH="${POST_TOOL_USE_LOG:-${HOOKS_STATE_OVERRIDE:-$HOME/.claude/hooks/state}/post-tool-use-manifest.log}"
mkdir -p "$(dirname "$LOG_PATH")" 2>/dev/null || true

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

dispatch() {
  {
    echo "[$TS] regen triggered by $TOOL_NAME on $FILE_PATH"
    "$REBUILD_BIN" 2>&1
    echo "[$TS] regen exit=$?"
  } >> "$LOG_PATH" 2>&1
}

if [[ "${POST_TOOL_USE_SYNC_MODE:-0}" == "1" ]]; then
  # Sync path: useful for fixture tests; production path is async.
  dispatch
else
  # Async dispatch: nohup + & + disown so the regen doesn't block tool result.
  dispatch &
  disown 2>/dev/null || true
fi

exit 0
