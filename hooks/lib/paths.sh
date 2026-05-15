# ~/.claude/hooks/lib/paths.sh
# Single source of truth for filesystem paths used by hooks, orchestrator
# scripts, and cron wrappers. Source this file — do not execute it.
#
#   source "$HOME/.claude/hooks/lib/paths.sh"
#
# To migrate a path vault-wide, edit this file — nothing else. Scripts that
# forget to source paths.sh will break loudly on undefined variables rather
# than silently skip. That is intentional (see spine-remediation Session 02).

export PLANS_DIR="${PLANS_DIR:-$HOME/.claude-plans}"
export PLANS_DIR_DEAD="$HOME/.claude/plans"                         # tripwire — must not exist
export VAULT_ROOT="${VAULT_ROOT:-$HOME/Documents/Obsidian Vault}"
export VAULT_LOGS="$VAULT_ROOT/Logs"
export CLAUDE_HOME="$HOME/.claude"
export HOOKS_DIR="$CLAUDE_HOME/hooks"
export HOOKS_STATE="$HOOKS_DIR/state"
export SCHEMAS_DIR="$CLAUDE_HOME/schemas"
export GOVERNANCE_DIR="$CLAUDE_HOME/governance"                     # pillar registries + file-type contracts + librarian-capability contracts (SP03 Session 20)
export FOUNDATION_MASTER="$GOVERNANCE_DIR/foundation-master.json"   # composed governance bundle (SP13 P1.5 2026-05-15) — bundle-at-load runtime read for hooks per canonical §B
export CRON_WRAPPERS="$CLAUDE_HOME/orchestrator/cron-wrappers"     # system-wide cron wrapper home (spine-remediation Session 15, 2026-04-14)

# Git infrastructure (spine-remediation Session 08, 2026-04-14)
export CLAUDE_GIT_REPO="$CLAUDE_HOME"                               # git-tracked config surface
export PLANS_GIT_REPO="$PLANS_DIR"                                  # git-tracked plan surface
export BACKUPS_DIR="${BACKUPS_DIR:-$HOME/Backups}"                  # local bare mirror target
