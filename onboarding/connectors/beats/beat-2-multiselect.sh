#!/usr/bin/env bash
# onboarding/connectors/beats/beat-2-multiselect.sh — SP14 T-8 (Plan 71 SP14
# Session 3a).
#
# Beat 2 of the connector wizard: render the T-4 catalog as a checkbox-style
# multiselect grid, pre-checked with the recommended subset for the user's
# role (set in Beat 1 → connectors_meta.user_role). Already-installed MCP
# servers (per T-6 settings-paths-probe) are badged "[installed]". User
# toggles selections; apply writes user-manifest.json#/connectors[] with one
# entry per checked connector populated minimally from catalog defaults.
#
# OUTPUT CONTRACT (R-43):
#   Files written: $USER_MANIFEST — jq-merge populates .connectors[]
#   Schema-types: user-manifest-schema.json#/properties/connectors/items
#   Pre-write validation: each new entry must have id + mcp_server (catalog
#                 entries with null mcp_server_id are rejected unless --allow-
#                 community-null is passed)
#   Failure mode: BLOCK AND LOG. rc=2 on bad invocation; rc=3 on manifest
#                 write failure; rc=4 if catalog unreadable.
#
# Usage:
#   bash beat-2-multiselect.sh [--catalog <path>] [--manifest <path>]
#                              [--input-checks <comma-sep-ids>]
#                              [--search <substring>]
#                              [--installed-list <path>]
#                              [--allow-community-null]
#
# Flags:
#   --input-checks <ids>   Non-interactive: comma-separated ids to check
#                          (e.g., "granola,gcal,gmail"). Synthetic test mode.
#   --search <substr>      Filter the rendered grid to entries whose
#                          display_name OR category contains <substr> (case-
#                          insensitive). Combinable with --input-checks.
#   --installed-list <p>   Path to a newline-separated list of already-installed
#                          server-ids (typically the output of T-6 probe in
#                          --dedup mode). Each catalog entry's mcp_server_id
#                          matched against this list gets the "[installed]" tag.
#   --allow-community-null Permit catalog entries with null mcp_server_id to
#                          be checked (community/non-bundled MCPs without a
#                          first-party Anthropic id). Default: reject.
#
# Exit codes:
#   0  success
#   2  bad invocation
#   3  manifest write failure
#   4  catalog unreadable / parse failure

set -u

_diag() { printf 'beat-2-multiselect FAIL: %s\n' "$1" >&2; }
_info() { printf 'beat-2-multiselect: %s\n' "$1"; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
CATALOG="${CLAUDE_STEM_CATALOG:-$REPO_ROOT/onboarding/connectors/catalog.json}"
USER_MANIFEST="${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json"

manifest_arg=""
input_checks=""
search=""
installed_list=""
allow_community_null=0

while [ $# -gt 0 ]; do
  case "$1" in
    --catalog) [ $# -lt 2 ] && { _diag "--catalog requires path"; exit 2; }; CATALOG="$2"; shift 2 ;;
    --manifest) [ $# -lt 2 ] && { _diag "--manifest requires path"; exit 2; }; manifest_arg="$2"; shift 2 ;;
    --input-checks) [ $# -lt 2 ] && { _diag "--input-checks requires value"; exit 2; }; input_checks="$2"; shift 2 ;;
    --search) [ $# -lt 2 ] && { _diag "--search requires value"; exit 2; }; search="$2"; shift 2 ;;
    --installed-list) [ $# -lt 2 ] && { _diag "--installed-list requires path"; exit 2; }; installed_list="$2"; shift 2 ;;
    --allow-community-null) allow_community_null=1; shift ;;
    -*) _diag "unknown flag: $1"; exit 2 ;;
    *) _diag "unexpected positional: $1"; exit 2 ;;
  esac
done

[ -n "$manifest_arg" ] && USER_MANIFEST="$manifest_arg"

if [ ! -r "$CATALOG" ]; then
  _diag "catalog not readable: $CATALOG"
  exit 4
fi

# --- read user role (Beat 1 output) ---
role=""
if [ -r "$USER_MANIFEST" ]; then
  role=$(jq -r '.connectors_meta.user_role // ""' "$USER_MANIFEST" 2>/dev/null)
fi
# Empty role = no pre-checked subset (still allows --input-checks / interactive)

# --- build installed-set for badging ---
installed_set=""
if [ -n "$installed_list" ] && [ -r "$installed_list" ]; then
  installed_set=$(cat "$installed_list" 2>/dev/null | sort -u)
fi

# --- filter catalog by --search ---
filter_jq='.[]'
if [ -n "$search" ]; then
  search_lower=$(printf '%s' "$search" | tr '[:upper:]' '[:lower:]')
  filter_jq=".[] | select(
    (.display_name | ascii_downcase | contains(\"$search_lower\")) or
    (.category | ascii_downcase | contains(\"$search_lower\"))
  )"
fi

# --- render the grid (visible regardless of mode; tests can capture stderr) ---
render_grid() {
  printf '\n' >&2
  printf 'Connector Wizard — Beat 2 of 4\n' >&2
  printf 'Pick the connectors you use. Pre-checked = recommended for role "%s".\n' "$role" >&2
  if [ -n "$search" ]; then
    printf '(filter: "%s")\n' "$search" >&2
  fi
  printf '\n' >&2
  jq -r --arg role "$role" "
    $filter_jq | [
      (if (.role_recommendations | index(\$role)) then \"x\" else \" \" end),
      .id,
      .display_name,
      .category,
      (.mcp_server_id // \"<community>\")
    ] | @tsv
  " "$CATALOG" 2>/dev/null | while IFS=$'\t' read -r checked id name category mcp; do
    badge=""
    if [ -n "$installed_set" ] && printf '%s\n' "$installed_set" | grep -qFx "$mcp"; then
      badge=" [installed]"
    fi
    printf '  [%s] %-20s — %s (%s)%s\n' "$checked" "$id" "$name" "$category" "$badge" >&2
  done
  printf '\n' >&2
}

render_grid

# --- determine checked ids ---
checked_ids=""
if [ -n "$input_checks" ]; then
  # Non-interactive: split comma-separated input
  checked_ids=$(printf '%s' "$input_checks" | tr ',' '\n' | tr -d ' ' | sort -u)
else
  # Interactive: read user's checks from stdin
  printf 'Enter ids to check (comma-sep), or empty Enter for default-checked subset: ' >&2
  if IFS= read -r typed; then
    if [ -z "$typed" ]; then
      # Default: take role-recommended subset
      checked_ids=$(jq -r --arg role "$role" '.[] | select(.role_recommendations | index($role)) | .id' "$CATALOG" 2>/dev/null)
    else
      checked_ids=$(printf '%s' "$typed" | tr ',' '\n' | tr -d ' ' | sort -u)
    fi
  fi
fi

if [ -z "$checked_ids" ]; then
  _info "no connectors checked; manifest connectors[] will be empty"
fi

# --- validate checked ids exist in catalog + filter rejects ---
final_ids=""
while IFS= read -r id; do
  [ -z "$id" ] && continue
  entry=$(jq -c --arg id "$id" '.[] | select(.id == $id)' "$CATALOG" 2>/dev/null)
  if [ -z "$entry" ]; then
    _info "skipping unknown id '$id' (not in catalog)"
    continue
  fi
  mcp_server_id=$(printf '%s' "$entry" | jq -r '.mcp_server_id // "null"')
  if [ "$mcp_server_id" = "null" ] && [ "$allow_community_null" -ne 1 ]; then
    _info "skipping '$id' — null mcp_server_id (community); pass --allow-community-null to include"
    continue
  fi
  final_ids="$final_ids $id"
done <<EOF
$checked_ids
EOF

final_ids=$(printf '%s' "$final_ids" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

# --- build connectors[] entries from catalog defaults ---
connectors_jq='[]'
while IFS= read -r id; do
  [ -z "$id" ] && continue
  entry_jq=$(jq -c --arg id "$id" '
    .[] | select(.id == $id) | {
      id: .id,
      mcp_server: (.mcp_server_id // (.id + "-community")),
      auth_status: "pending",
      auth_expires_at: null,
      schedule: .default_schedule,
      scope: "read",
      target_vault_path: .default_target_vault_path,
      processor_skill: .default_processor_skill,
      last_run: null,
      last_status: null,
      failure_mode: .failure_mode_catalog_ref
    }
  ' "$CATALOG" 2>/dev/null)
  if [ -n "$entry_jq" ]; then
    connectors_jq=$(jq --argjson e "$entry_jq" '. + [$e]' <<<"$connectors_jq")
  fi
done <<EOF
$final_ids
EOF

# --- merge into user-manifest.json ---
mkdir -p "$(dirname "$USER_MANIFEST")"
if [ -r "$USER_MANIFEST" ]; then
  base_json=$(cat "$USER_MANIFEST")
else
  base_json='{}'
fi

new_json=$(printf '%s' "$base_json" | jq \
  --argjson conns "$connectors_jq" \
  '.connectors = $conns' 2>/dev/null) || {
  _diag "jq merge failed; manifest may be malformed: $USER_MANIFEST"
  exit 3
}

tmp="$USER_MANIFEST.tmp.$$"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$new_json" > "$tmp" || { _diag "tmp write failed: $tmp"; exit 3; }
mv -f "$tmp" "$USER_MANIFEST" || { _diag "atomic mv failed"; exit 3; }
trap - EXIT

n=$(printf '%s' "$connectors_jq" | jq 'length')
_info "wrote $n connector entr$([ "$n" = 1 ] && echo y || echo ies) to $USER_MANIFEST#/connectors"
exit 0
