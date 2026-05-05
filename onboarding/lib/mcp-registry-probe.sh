#!/usr/bin/env bash
# onboarding/lib/mcp-registry-probe.sh — SP14 T-5 (Plan 71 SP14 Session 2).
#
# Probes the official MCP Registry + enumerates Anthropic-bundled `claude_ai_*`
# connectors. Emits a merged catalog (catalog → bundled → registry precedence)
# the SP14 wizard Beat 2 consumes. Offline-graceful: on Registry fetch failure,
# logs a warning and proceeds with bundled + catalog only.
#
# OUTPUT CONTRACT (R-43):
#   Files written: none — pure-read probe; emits to stdout
#   Schema-types: stdout is JSONL; one record per line of shape:
#     {"id": "<server-id>", "source": "registry"|"bundled"|"catalog",
#      "display_name": "<name>", "mcp_server_id": "<id-or-null>"}
#   Pre-write validation: not applicable (no writes)
#   Failure mode: BLOCK AND LOG only on hard errors (catalog unreadable +
#                 jq parse fail). Registry fetch failure = warning + degrade.
#
# Usage:
#   bash onboarding/lib/mcp-registry-probe.sh \
#     [--catalog <path>] [--bundled-only] [--registry-only] [--no-cap-check]
#
# Flags:
#   --catalog <path>    Override default catalog path
#                       (default: $CLAUDE_STEM_REPO/onboarding/connectors/catalog.json)
#   --bundled-only      ONLY emit bundled enumeration; skip catalog + Registry
#   --registry-only     ONLY emit Registry probe; skip catalog + bundled
#   --catalog-only      ONLY emit catalog; skip bundled + Registry
#   --no-cap-check      Skip the 80-tool-cap warning (for synthetic tests)
#
# Exit codes:
#   0  success (catalog + bundled enumeration always succeed; registry may
#      be empty due to network failure but probe still rc=0)
#   2  bad invocation OR catalog unreadable / parse fail (hard error)
#   3  unexpected jq failure (should be unreachable)
#
# Dependencies: bash 3.2, jq, curl. R-37 single-deliverable.

set -u

_diag() { printf 'mcp-registry-probe FAIL: %s\n' "$1" >&2; }
_warn() { printf 'mcp-registry-probe WARN: %s\n' "$1" >&2; }

# --- defaults ---
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
CATALOG="${CLAUDE_STEM_CATALOG:-$REPO_ROOT/onboarding/connectors/catalog.json}"
USER_CLAUDE_JSON="${USER_CLAUDE_JSON:-$HOME/.claude.json}"
REGISTRY_URL="${MCP_REGISTRY_URL:-https://registry.modelcontextprotocol.io/v0/servers}"
TOOL_CAP=80

mode="all"
cap_check=1

while [ $# -gt 0 ]; do
  case "$1" in
    --catalog)
      [ $# -lt 2 ] && { _diag "--catalog requires path"; exit 2; }
      CATALOG="$2"; shift 2 ;;
    --bundled-only) mode="bundled"; shift ;;
    --registry-only) mode="registry"; shift ;;
    --catalog-only) mode="catalog"; shift ;;
    --no-cap-check) cap_check=0; shift ;;
    -*) _diag "unknown flag: $1"; exit 2 ;;
    *) _diag "unexpected positional arg: $1"; exit 2 ;;
  esac
done

# --- catalog read (default) ---
emit_catalog() {
  if [ ! -r "$CATALOG" ]; then
    _diag "catalog not readable: $CATALOG"
    return 2
  fi
  jq -c '.[] | {id: .id, source: "catalog", display_name: .display_name, mcp_server_id: .mcp_server_id}' "$CATALOG" 2>/dev/null || {
    _diag "jq parse failed on catalog: $CATALOG"
    return 2
  }
}

# --- Anthropic-bundled enumerator ---
# Bundled set is hardcoded — these are the well-known claude_ai_* MCPs the
# Anthropic harness exposes when tengu_claudeai_mcp_connectors=true.
BUNDLED_SET='[
  {"id": "granola", "display_name": "Granola", "mcp_server_id": "claude_ai_Granola"},
  {"id": "gcal", "display_name": "Google Calendar", "mcp_server_id": "claude_ai_Google_Calendar"},
  {"id": "gmail", "display_name": "Gmail", "mcp_server_id": "claude_ai_Gmail"},
  {"id": "gdrive", "display_name": "Google Drive", "mcp_server_id": "claude_ai_Google_Drive"},
  {"id": "atlassian", "display_name": "Atlassian", "mcp_server_id": "claude_ai_Atlassian"}
]'

emit_bundled() {
  local enabled
  if [ ! -r "$USER_CLAUDE_JSON" ]; then
    _warn "$USER_CLAUDE_JSON not readable; assuming Anthropic-bundled connectors disabled"
    return 0
  fi
  enabled=$(jq -r '.tengu_claudeai_mcp_connectors // false' "$USER_CLAUDE_JSON" 2>/dev/null)
  if [ "$enabled" != "true" ]; then
    _warn "tengu_claudeai_mcp_connectors flag not true; skipping bundled enumeration"
    return 0
  fi
  printf '%s\n' "$BUNDLED_SET" | jq -c '.[] | {id, source: "bundled", display_name, mcp_server_id}'
}

# --- Registry fetch (graceful-degrade) ---
# SP16 T-5c (closes audit S-3 LOW + B5): response-shape allowlist.
# REGISTRY_URL pins to canonical https://registry.modelcontextprotocol.io by
# default (line 48 above); MCP_REGISTRY_URL env retained for offline-degrade
# testing + adopter override of mirror endpoints. Defense-in-depth: each
# returned record must carry a resolvable id, display_name, and mcp_server_id.
# Records failing the allowlist are dropped + logged to STDERR; the probe
# continues with the validated subset (graceful-degrade preserved).
emit_registry() {
  local payload tmp valid_count rejected_count
  payload=$(curl -m 10 --silent --fail "$REGISTRY_URL" 2>/dev/null) || {
    _warn "Registry fetch failed ($REGISTRY_URL); proceeding without Registry contributions"
    return 0
  }
  if [ -z "$payload" ]; then
    _warn "Registry returned empty payload; skipping"
    return 0
  fi

  tmp=$(mktemp -t mcp-reg-validate-XXXXXX) || { _diag "mktemp failed"; return 3; }

  # Emit one tagged JSON record per server: _shape is "valid" or "rejected".
  # Rejection reasons are reported individually so adopters can reason about
  # why a record was dropped (missing-id, missing-display-name, missing-mcp-server-id).
  #
  # Canonical registry payload shape (https://registry.modelcontextprotocol.io/v0/servers
  # as of MCP server.schema.json/2025-12-11): {"servers": [{"server": {...}, "_meta": {...}}, ...]}
  # — fields like name/title live under each record's `.server` object. Older
  # mirror shapes emit fields at the top level. The (.server // .) fallback
  # accepts both: descends to `.server` if present, else treats the record as
  # the inner payload.
  printf '%s' "$payload" | jq -c '
    (if type == "object" then (.servers // .) else . end) as $servers
    | if ($servers | type) != "array" then empty
      else
        $servers[]
        | (.server // .) as $s
        | ($s.name // $s.id // "") as $rid
        | ($s.display_name // $s.title // $s.name // "") as $rdisplay
        | ($s.id // $s.name // null) as $rmcp
        | (if ($rid | type) != "string" or ($rid | length) == 0 then "missing-id"
           elif ($rdisplay | type) != "string" or ($rdisplay | length) == 0 then "missing-display-name"
           elif $rmcp == null then "missing-mcp-server-id"
           else "" end) as $reason
        | if $reason == "" then
            {_shape: "valid", id: $rid, source: "registry",
             display_name: $rdisplay, mcp_server_id: $rmcp}
          else
            {_shape: "rejected", reason: $reason,
             observed_id: ($rid // null),
             observed_display: ($rdisplay // null)}
          end
      end
  ' 2>/dev/null > "$tmp" || {
    _warn "Registry payload jq parse failed; skipping"
    rm -f "$tmp"
    return 0
  }

  rejected_count=$(grep -c '"_shape":"rejected"' "$tmp" 2>/dev/null || true)
  rejected_count=${rejected_count:-0}
  valid_count=$(grep -c '"_shape":"valid"' "$tmp" 2>/dev/null || true)
  valid_count=${valid_count:-0}

  if [ "$rejected_count" -gt 0 ]; then
    _warn "Registry response-shape allowlist rejected $rejected_count record(s); see diagnostics below"
    grep '"_shape":"rejected"' "$tmp" | while IFS= read -r r; do
      _warn "  rejected: $r"
    done
  fi

  # Emit valid records with the _shape discriminator stripped.
  if [ "$valid_count" -gt 0 ]; then
    grep '"_shape":"valid"' "$tmp" | jq -c 'del(._shape)'
  fi

  rm -f "$tmp"
}

# --- merge logic: catalog > bundled > registry; dedup by id ---
emit_merged() {
  local tmp
  tmp=$(mktemp -t mcp-merge-XXXXXX) || { _diag "mktemp failed"; return 3; }
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  case "$mode" in
    all)
      emit_catalog > "$tmp" || return $?
      emit_bundled >> "$tmp"
      emit_registry >> "$tmp"
      ;;
    bundled)
      emit_bundled > "$tmp"
      ;;
    registry)
      emit_registry > "$tmp"
      ;;
    catalog)
      emit_catalog > "$tmp" || return $?
      ;;
  esac

  # Dedup: first occurrence of each id wins (catalog > bundled > registry order
  # preserved by emission sequence).
  awk -F'"id":' '
    NF > 1 {
      id = $2
      sub(/^"/, "", id)
      sub(/".*/, "", id)
      if (!(id in seen)) {
        seen[id] = 1
        print $0
      }
    }
  ' "$tmp"
}

# --- tool-count cap warning ---
check_tool_cap() {
  [ "$cap_check" -eq 0 ] && return 0
  if [ ! -r "$USER_CLAUDE_JSON" ]; then return 0; fi
  # Conservative: count distinct mcpServers across user-checked sources.
  local server_count
  server_count=$(jq -r '(.mcpServers // {}) | length' "$USER_CLAUDE_JSON" 2>/dev/null)
  if [ -n "$server_count" ] && [ "$server_count" -gt "$TOOL_CAP" ]; then
    _warn "user mcpServers count ($server_count) exceeds Cursor's reference cap of $TOOL_CAP — selective tool-toggling per server is recommended"
  fi
}

# --- main ---
emit_merged
check_tool_cap
exit 0
