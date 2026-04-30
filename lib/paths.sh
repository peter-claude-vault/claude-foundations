# lib/paths.sh — single source of truth for filesystem paths used by hooks,
# orchestrator scripts, and cron wrappers. Source this file — do not execute it.
#
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
#
# Resolution order for each path:
#   1. Caller-set environment variable wins (test/CI overrides).
#   2. Field in user-manifest.json (when file exists, jq present, key non-empty).
#   3. Install-convention default ($HOME-relative).
#
# VAULT_ROOT and BACKUPS_DIR have no install-convention default — they stay
# empty when neither env nor manifest provides them. Consumers must check
# before use; missing-vault is graceful-degrade per SP02 spec Constraint
# "Every hook exits 0 on missing manifest".
#
# Bash 3.2 clean (R-23): no associative arrays, no bash-4 file-into-array
# builtins, no parameter-expansion case-conversion (lowercase or uppercase),
# and no regex capture groups in production paths.

# --- install-convention base (never empty) ---
export CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
export HOOKS_DIR="${HOOKS_DIR:-$CLAUDE_HOME/hooks}"
export SCHEMAS_DIR="${SCHEMAS_DIR:-$CLAUDE_HOME/schemas}"

# --- manifest reader (graceful-degrade) ---
# Returns the value at the given dotted-path inside user-manifest.json, or
# empty string if the file is missing, jq is absent, or the key is null/empty.
# Never errors — every consumer must tolerate empty output.
_USER_MANIFEST="${USER_MANIFEST_PATH:-$CLAUDE_HOME/user-manifest.json}"
_manifest_get() {
  if [ -r "$_USER_MANIFEST" ] && command -v jq >/dev/null 2>&1; then
    jq -r --arg p "$1" '
      . as $m
      | ($p | split(".") | map(select(length > 0)))
      | reduce .[] as $k ($m; if . == null then null else .[$k]? end)
      | if . == null or . == "" then "" else . end
    ' "$_USER_MANIFEST" 2>/dev/null
  fi
}

# --- hooks runtime state ---
if [ -z "${HOOKS_STATE:-}" ]; then
  _v="$(_manifest_get .paths.hooks_state)"
  if [ -n "$_v" ]; then HOOKS_STATE="$_v"; else HOOKS_STATE="$HOOKS_DIR/state"; fi
  unset _v
fi
export HOOKS_STATE

# --- plans tree ---
if [ -z "${PLANS_DIR:-}" ]; then
  _v="$(_manifest_get .paths.plans_root)"
  if [ -n "$_v" ]; then PLANS_DIR="$_v"; else PLANS_DIR="$HOME/.claude-plans"; fi
  unset _v
fi
export PLANS_DIR

# Tripwire path. Held as null-stub by default per Lead 2 §3 / Q10 (runtime-
# recreation investigation pending). Honors env override for test/CI scenarios.
# Consumers MUST gate on non-empty before using.
export PLANS_DIR_DEAD="${PLANS_DIR_DEAD:-}"

# --- vault (no install-convention default) ---
if [ -z "${VAULT_ROOT:-}" ]; then
  _v="$(_manifest_get .paths.vault_root)"
  if [ -z "$_v" ]; then _v="$(_manifest_get .vault.root)"; fi
  VAULT_ROOT="$_v"
  unset _v
fi
export VAULT_ROOT

if [ -z "${VAULT_LOGS:-}" ]; then
  if [ -n "$VAULT_ROOT" ]; then VAULT_LOGS="$VAULT_ROOT/Logs"; else VAULT_LOGS=""; fi
fi
export VAULT_LOGS

# --- cron wrappers (install-convention) ---
export CRON_WRAPPERS="${CRON_WRAPPERS:-$CLAUDE_HOME/orchestrator/cron-wrappers}"

# --- log dir (install-convention; replaces user-specific Desktop leak) ---
# Consumed by dispatch.sh delayed-launchd plists, job-runner.sh log header,
# and cron wrappers. SP08 install.sh creates the dir; runtime gracefully
# mkdir -p's via consumers. Override via env (test/CI) wins.
export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-$CLAUDE_HOME/logs}"

# --- git infrastructure ---
# CLAUDE_GIT_REPO + PLANS_GIT_REPO mirror their containing dirs by default but
# may be overridden via env when the user separates config repo from working tree.
export CLAUDE_GIT_REPO="${CLAUDE_GIT_REPO:-$CLAUDE_HOME}"
export PLANS_GIT_REPO="${PLANS_GIT_REPO:-$PLANS_DIR}"

if [ -z "${BACKUPS_DIR:-}" ]; then
  _v="$(_manifest_get .paths.backups_dir)"
  if [ -n "$_v" ]; then BACKUPS_DIR="$_v"; else BACKUPS_DIR="$HOME/Backups"; fi
  unset _v
fi
export BACKUPS_DIR

# resolve_memory_dir — absolute memory-dir path for the current session.
# Claude Code keys per-project state by a slug of the launch cwd (each "/"
# replaced with "-"). The shell that runs hooks inherits cwd from Claude Code,
# so `pwd` at hook entry resolves the same slug. MEMORY_DIR env override wins
# (test/CI). Returns the path on stdout; never errors.
resolve_memory_dir() {
  if [ -n "${MEMORY_DIR:-}" ]; then
    echo "$MEMORY_DIR"
    return
  fi
  # Use logical pwd (no symlink resolution) so slug matches Claude Code's
  # internal projects/ keying, which uses the launch path verbatim. Critical
  # on macOS where /tmp resolves to /private/tmp under physical pwd.
  local slug
  slug=$(pwd -L | sed 's|/|-|g')
  echo "${CLAUDE_HOME}/projects/${slug}/memory"
}
