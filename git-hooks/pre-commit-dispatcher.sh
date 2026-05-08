#!/bin/bash
# pre-commit-dispatcher.sh — chain R-37 + R-46-cousin gates, fail-fast
#
# (Plan 80/81 SP01 Session 13; T-20 Phase A pre-stage)
#
# Installation: symlink {repo}/.git/hooks/pre-commit to this file (via
# install-hooks.sh). Dispatcher resolves sibling child-hooks by following
# the symlink chain to its source dir in the foundation-repo work tree.
#
# Children invoked in fail-fast order:
#   1. pre-commit-r37.sh                — R-37 coupled-surface lockstep (T-7)
#   2. pre-commit-harness-validated.sh  — R-46-cousin flip-to-complete (T-27)
#
# Order rationale: R-37 enforces a structural repo-wide invariant
# (coupled surfaces land together); R-46-cousin enforces a plan-scoped
# precondition (flip-to-complete must have a fresh harness verdict).
# A coupled-surface partial leaves the repo incoherent regardless of any
# per-plan flip outcome, so checking R-37 first avoids spending
# capability-call cycles on an already-rejectable commit.
#
# Test isolation env (passed through to children unchanged via inheritance):
#   GATE_CONFIG_PATH               (R-37)
#   PRE_COMMIT_STAGED_OVERRIDE     (both)
#   PRE_COMMIT_DIFF_OVERRIDE       (R-46-cousin)
#   HOOKS_STATE_OVERRIDE           (both + dispatcher's own audit log)
#   R37_ENFORCEMENT_OVERRIDE       (R-37)
#   FOUNDATION_REPO_OVERRIDE       (both)
#   FOUNDATION_SHA_OVERRIDE        (R-46-cousin)
#   PLANS_ROOT_OVERRIDE            (R-46-cousin)
#   UPDATE_HARNESS_CAP             (R-46-cousin)
# Plus dispatcher-only:
#   DISPATCHER_HOOKS_DIR_OVERRIDE  — explicit hooks dir (test mode); skips
#                                    the symlink-chain resolution
#
# Exit codes: rc of first non-zero child (fail-fast); 0 if both pass; 2
# on internal error (missing/non-executable child hook).

set -uo pipefail

HOOK_NAME="pre-commit-dispatcher"

# === Resolve sibling-hook directory ====================================
# When invoked through .git/hooks/pre-commit (a symlink to this file in
# foundation-repo/git-hooks/), follow the symlink chain to its source
# directory. The two child hooks live alongside this file.
resolve_hooks_dir() {
  if [[ -n "${DISPATCHER_HOOKS_DIR_OVERRIDE:-}" ]]; then
    printf '%s\n' "$DISPATCHER_HOOKS_DIR_OVERRIDE"
    return
  fi
  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    local link
    link=$(readlink "$src")
    if [[ "$link" = /* ]]; then
      src="$link"
    else
      src="$(cd "$(dirname "$src")" && pwd)/$link"
    fi
  done
  (cd "$(dirname "$src")" && pwd)
}

HOOKS_DIR=$(resolve_hooks_dir)
R37_HOOK="$HOOKS_DIR/pre-commit-r37.sh"
HARNESS_HOOK="$HOOKS_DIR/pre-commit-harness-validated.sh"

HOOKS_STATE="${HOOKS_STATE_OVERRIDE:-$HOME/.claude/hooks/state}"
mkdir -p "$HOOKS_STATE" 2>/dev/null || true
DECISIONS_LOG="$HOOKS_STATE/gate-decisions.log"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

audit() {
  local decision="$1" reason="$2" child_rc="${3:-}"
  jq -nc \
    --arg ts "$TS" --arg hook "$HOOK_NAME" --arg decision "$decision" \
    --arg reason "$reason" --arg child_rc "$child_rc" --arg repo "$REPO_ROOT" \
    --argjson schema_version 1 \
    '{ts:$ts, hook:$hook, decision:$decision, reason:$reason,
      child_rc:$child_rc, repo:$repo, schema_version:$schema_version}
     | with_entries(if .value == "" or .value == null then empty else . end)' \
    >> "$DECISIONS_LOG" 2>/dev/null || true
}

# === Sanity check on child hooks =======================================
for child in "$R37_HOOK" "$HARNESS_HOOK"; do
  if [[ ! -x "$child" ]]; then
    echo "$HOOK_NAME: child hook missing or not executable: $child" >&2
    audit "error" "child-hook-missing-or-not-executable: $(basename "$child")"
    exit 2
  fi
done

# === Run children fail-fast ============================================
"$R37_HOOK"
rc_r37=$?
if (( rc_r37 != 0 )); then
  audit "reject" "blocked-at-r37" "$rc_r37"
  exit "$rc_r37"
fi

"$HARNESS_HOOK"
rc_harness=$?
if (( rc_harness != 0 )); then
  audit "reject" "blocked-at-harness-validated" "$rc_harness"
  exit "$rc_harness"
fi

audit "allow" "both-children-passed"
exit 0
