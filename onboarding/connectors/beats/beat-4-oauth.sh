#!/usr/bin/env bash
# onboarding/connectors/beats/beat-4-oauth.sh — SP14 T-10 (Plan 71 SP14
# Session 3b).
#
# Beat 4 of the connector wizard: for each connectors[] entry with
# auth_status:"pending", sequentially walk OAuth. For Anthropic-bundled MCPs
# (mcp_server starts with "claude_ai_"), surface the bundled-auth instruction
# (the user invokes `mcp__claude_ai_<id>__authenticate` from Claude Code in
# a separate session). For community MCPs (mcp_server ends with "-community"
# or is otherwise non-bundled), surface the OAuth URL + await user confirm.
# On confirm: persist auth_status:"connected" + auth_expires_at (when the
# provider exposes one). Skip semantics: user input "skip" records pending,
# proceeds to next connector. Settings.json merge: append mcpServers.<id>
# entries with placeholder env-var slots; SP12 three-step gate fires per merge.
# Re-invocation resumes at the first pending connector (idempotent).
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - $USER_MANIFEST — per-connector auth_status + auth_expires_at updates
#     - $SETTINGS_JSON — mcpServers.<id> placeholder entries appended
#                        (SP12 gate-protected; --no-gate skips for synthetic)
#   Schema-types: user-manifest-schema.json#/properties/connectors/items
#                 (auth_status enum: connected | pending | expired)
#   Pre-write validation: SP12 gate_apply per settings-merge
#   Failure mode: BLOCK AND LOG. rc=2 bad invocation; rc=3 manifest write
#                 fail; rc=4 user aborted at gate; rc=5 settings.json merge
#                 fail.
#
# Usage:
#   bash beat-4-oauth.sh [--manifest <path>] [--settings <path>]
#                        [--input-actions <id1:action,id2:action,...>]
#                        [--accept-on-empty-stdin] [--no-gate]
#                        [--mock-expiry "2026-08-01T00:00:00Z"]
#
# Flags:
#   --input-actions <pairs>   Non-interactive: comma-separated <id>:<action>
#                             pairs where action ∈ {confirm, skip}. Synthetic
#                             test mode. Connectors without an entry get
#                             "skip" by default.
#   --accept-on-empty-stdin   Pass-through to SP12 gate_apply.
#   --no-gate                 Skip SP12 gate (synthetic merge-only tests).
#   --mock-expiry <iso>       For confirmed connectors, set auth_expires_at
#                             to this ISO-8601 string. Default: 90 days from
#                             now.
#
# Exit codes: 0=success, 2=bad invocation, 3=manifest write fail,
#             4=user aborted at SP12 gate, 5=settings.json merge fail

set -u

_diag() { printf 'beat-4-oauth FAIL: %s\n' "$1" >&2; }
_info() { printf 'beat-4-oauth: %s\n' "$1"; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
GATE_LIB="$REPO_ROOT/onboarding/lib/three-step-gate.sh"
USER_MANIFEST="${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json"
SETTINGS_JSON="${CLAUDE_HOME:-$HOME/.claude}/settings.json"

manifest_arg=""
settings_arg=""
input_actions=""
accept_eof=0
no_gate=0
mock_expiry=""

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) [ $# -lt 2 ] && { _diag "--manifest requires path"; exit 2; }; manifest_arg="$2"; shift 2 ;;
    --settings) [ $# -lt 2 ] && { _diag "--settings requires path"; exit 2; }; settings_arg="$2"; shift 2 ;;
    --input-actions) [ $# -lt 2 ] && { _diag "--input-actions requires value"; exit 2; }; input_actions="$2"; shift 2 ;;
    --accept-on-empty-stdin) accept_eof=1; shift ;;
    --no-gate) no_gate=1; shift ;;
    --mock-expiry) [ $# -lt 2 ] && { _diag "--mock-expiry requires ISO string"; exit 2; }; mock_expiry="$2"; shift 2 ;;
    -*) _diag "unknown flag: $1"; exit 2 ;;
    *) _diag "unexpected positional: $1"; exit 2 ;;
  esac
done

[ -n "$manifest_arg" ] && USER_MANIFEST="$manifest_arg"
[ -n "$settings_arg" ] && SETTINGS_JSON="$settings_arg"

if [ ! -r "$USER_MANIFEST" ]; then
  _diag "user-manifest not readable: $USER_MANIFEST"
  exit 2
fi

if [ -z "$mock_expiry" ]; then
  # Default: 90 days from now in ISO-8601 UTC. Use python3 for portable date math.
  if command -v python3 >/dev/null 2>&1; then
    mock_expiry=$(python3 -c 'import datetime; print((datetime.datetime.utcnow() + datetime.timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  else
    mock_expiry=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
fi

# --- look up action for a given connector id ---
action_for_id() {
  local target="$1"
  local pair found
  found=""
  if [ -n "$input_actions" ]; then
    printf '%s' "$input_actions" | tr ',' '\n' | while IFS=: read -r id action; do
      if [ "$id" = "$target" ]; then
        printf '%s' "$action"
        break
      fi
    done
  fi
}

# --- per-connector OAuth walk ---
pending_ids=$(jq -r '.connectors[] | select(.auth_status == "pending") | .id' "$USER_MANIFEST" 2>/dev/null)

if [ -z "$pending_ids" ]; then
  _info "no connectors with auth_status:pending; nothing to walk"
  exit 0
fi

n_pending=$(printf '%s\n' "$pending_ids" | wc -l | tr -d ' ')
printf '\nConnector Wizard — Beat 4 of 4\n' >&2
printf 'OAuth walk for %s pending connector(s).\n\n' "$n_pending" >&2

# Track which connectors got confirmed (for settings.json merge below)
confirmed_ids=""

while IFS= read -r id; do
  [ -z "$id" ] && continue

  # Read connector entry
  entry=$(jq -c --arg id "$id" '.connectors[] | select(.id == $id)' "$USER_MANIFEST")
  mcp_server=$(printf '%s' "$entry" | jq -r '.mcp_server')

  printf '─── %s (mcp_server: %s) ───\n' "$id" "$mcp_server" >&2
  case "$mcp_server" in
    claude_ai_*)
      printf '  Bundled connector. Run from Claude Code: mcp__%s__authenticate\n' "$mcp_server" >&2
      ;;
    *-community|*)
      printf '  Community connector. Open the providers OAuth URL in your browser, complete auth, return here.\n' >&2
      ;;
  esac

  # Determine action
  action=""
  if [ -n "$input_actions" ]; then
    # Inline lookup (sub-pipe + read avoids subshell loop variable issues)
    action=$(printf '%s' "$input_actions" | awk -F: -v target="$id" 'BEGIN{RS=","} $1==target{print $2; exit}')
    [ -z "$action" ] && action="skip"
  else
    printf '  [confirm] auth-completed | [skip] for now: ' >&2
    if IFS= read -r typed; then
      action="$typed"
    else
      action="skip"
    fi
  fi

  case "$action" in
    confirm)
      # Persist auth_status:connected + auth_expires_at
      tmp="$USER_MANIFEST.tmp.$$"
      jq --arg id "$id" --arg exp "$mock_expiry" \
        '.connectors |= map(if .id == $id then (.auth_status = "connected" | .auth_expires_at = $exp) else . end)' \
        "$USER_MANIFEST" > "$tmp" || { _diag "jq update failed for $id"; rm -f "$tmp"; exit 3; }
      mv -f "$tmp" "$USER_MANIFEST" || { _diag "atomic mv failed for $id"; exit 3; }
      _info "$id: auth_status=connected, auth_expires_at=$mock_expiry"
      confirmed_ids="$confirmed_ids $id"
      ;;
    skip)
      _info "$id: skipped (auth_status remains 'pending')"
      ;;
    *)
      _diag "unknown action '$action' for $id; treating as skip"
      ;;
  esac
done <<EOF
$pending_ids
EOF

# --- settings.json merge for confirmed connectors ---
if [ -z "$confirmed_ids" ]; then
  _info "no confirmed connectors; skipping settings.json merge"
  exit 0
fi

# Build proposed settings.json with new mcpServers entries
if [ -r "$SETTINGS_JSON" ]; then
  base_settings=$(cat "$SETTINGS_JSON")
else
  base_settings='{"mcpServers": {}}'
fi

new_settings="$base_settings"
for id in $confirmed_ids; do
  entry=$(jq -c --arg id "$id" '.connectors[] | select(.id == $id)' "$USER_MANIFEST")
  mcp_server=$(printf '%s' "$entry" | jq -r '.mcp_server')

  # Skip if mcp_server already in settings.json
  already=$(printf '%s' "$new_settings" | jq -r --arg s "$mcp_server" '.mcpServers // {} | has($s)' 2>/dev/null)
  if [ "$already" = "true" ]; then
    _info "$id: mcp_server '$mcp_server' already in settings.json; skipping merge"
    continue
  fi

  # Append placeholder entry
  new_settings=$(printf '%s' "$new_settings" | jq \
    --arg s "$mcp_server" \
    '.mcpServers = ((.mcpServers // {}) | .[$s] = {"placeholder": true, "env": {"AUTH_TOKEN": "<set-at-runtime>"}})' 2>/dev/null) || {
    _diag "settings.json merge failed for $mcp_server"
    exit 5
  }
done

# --- SP12 three-step gate before settings.json write ---
if [ "$no_gate" -eq 0 ]; then
  if [ ! -r "$GATE_LIB" ]; then
    _diag "three-step-gate.sh not readable at $GATE_LIB"
    exit 2
  fi
  # shellcheck source=/dev/null
  . "$GATE_LIB"

  stage_dir=$(mktemp -d -t beat4-gate-XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -rf '$stage_dir'" EXIT
  staging="$stage_dir/settings.proposed.json"
  printf '%s\n' "$new_settings" > "$staging"

  # Stage current state for preview comparison
  preview_target="$SETTINGS_JSON.preview"
  printf '%s\n' "$base_settings" > "$preview_target"

  apply_args="--skip-preview"
  [ "$accept_eof" -eq 1 ] && apply_args="$apply_args --accept-on-empty-stdin"

  if ! gate_apply "$staging" "$preview_target" $apply_args; then
    _diag "user aborted at three-step gate"
    rm -f "$preview_target"
    exit 4
  fi
  rm -f "$preview_target"
fi

# Write settings.json atomically
mkdir -p "$(dirname "$SETTINGS_JSON")"
tmp="$SETTINGS_JSON.tmp.$$"
printf '%s\n' "$new_settings" > "$tmp" || { _diag "tmp write failed"; exit 5; }
mv -f "$tmp" "$SETTINGS_JSON" || { _diag "atomic mv failed"; exit 5; }

n_confirmed=$(printf '%s\n' "$confirmed_ids" | wc -w | tr -d ' ')
_info "Beat 4 complete; $n_confirmed connector(s) merged into $SETTINGS_JSON"
exit 0
