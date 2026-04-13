#!/usr/bin/env bash
# discovery.sh — read-only environment scan for /onboard-foundation.
# Emits a discovery_context JSON object on stdout.
#
# Convention: CLAUDE_HOME is the source of truth for the Claude dir.
# Fallback: $HOME/.claude

set -euo pipefail

CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required for discovery" >&2
  exit 2
fi

existing_setup=false
[[ -d "$CLAUDE_DIR" ]] && existing_setup=true

# Existing skills
existing_skills="[]"
if [[ -d "$CLAUDE_DIR/skills" ]]; then
  existing_skills=$(
    find "$CLAUDE_DIR/skills" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null \
      | awk -F/ '{print $(NF-1)}' \
      | jq -R . | jq -s .
  )
fi

# MCP servers from settings.json (best-effort)
mcp_servers="[]"
settings="$CLAUDE_DIR/settings.json"
if [[ -f "$settings" ]]; then
  mcp_servers=$(jq -c '(.mcpServers // {}) | keys' "$settings" 2>/dev/null || echo "[]")
fi

# Vault candidates
vault_candidates="[]"
if [[ -d "$HOME/Documents" ]]; then
  hits=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && hits+=("$line")
  done < <(find "$HOME/Documents" -mindepth 2 -maxdepth 4 -type d -name .obsidian 2>/dev/null || true)
  if (( ${#hits[@]} > 0 )); then
    vault_candidates=$(
      for h in "${hits[@]}"; do
        root="${h%/.obsidian}"
        count=$(find "$root" -type f 2>/dev/null | wc -l | tr -d ' ')
        jq -n --arg path "$root" --argjson count "${count:-0}" \
          '{path:$path, file_count:$count, organizational_hint:"custom"}'
      done | jq -s .
    )
  fi
fi

# Git identity
git_name=""
git_email=""
if [[ -f "$HOME/.gitconfig" ]]; then
  git_name=$(git config --file "$HOME/.gitconfig" --get user.name 2>/dev/null || true)
  git_email=$(git config --file "$HOME/.gitconfig" --get user.email 2>/dev/null || true)
fi

# Dev environment sniff from shell profile
dev_env="[]"
profile=""
[[ -f "$HOME/.zshrc"  ]] && profile="$HOME/.zshrc"
[[ -z "$profile" && -f "$HOME/.bashrc" ]] && profile="$HOME/.bashrc"
if [[ -n "$profile" ]]; then
  dev_env=$(
    grep -oE 'brew|nvm|pyenv|conda|rustup|go|docker' "$profile" 2>/dev/null \
      | sort -u | jq -R . | jq -s . || echo "[]"
  )
fi

jq -n \
  --arg claude_dir "$CLAUDE_DIR" \
  --argjson existing_setup "$existing_setup" \
  --argjson existing_skills "$existing_skills" \
  --argjson mcp_servers "$mcp_servers" \
  --argjson vault_candidates "$vault_candidates" \
  --arg git_name "$git_name" \
  --arg git_email "$git_email" \
  --argjson dev_env "$dev_env" \
  '{
    claude_dir: $claude_dir,
    existing_setup: $existing_setup,
    existing_skills: $existing_skills,
    mcp_servers: $mcp_servers,
    vault_candidates: $vault_candidates,
    git_identity: {
      name:  (if $git_name  == "" then null else $git_name  end),
      email: (if $git_email == "" then null else $git_email end)
    },
    dev_env: $dev_env,
    conflicts: []
  }'
