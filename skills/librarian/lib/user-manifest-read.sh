# user-manifest-read.sh — Canonical read API for user-manifest.json fields.
#
# Landed: Plan 71 SP04 T-9b (2026-04-29). Closes audit F-1 (SP09 T-7.5
# explicit consumer mandate). Wraps jq queries with default-fallback
# semantics so capability shells stop encoding `user-manifest.json` field
# paths inline.
#
# Usage:
#   source "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/lib/user-manifest-read.sh"
#   for path in $(umr_get_array '.system.backup_targets'); do ...; done
#   exemptions=$(umr_get_array '.vault.tag_audit_exemptions')
#   aliases_json=$(umr_get_object '.vault.engagement_aliases')
#
# Consumers (at ship time):
#   - capabilities/backup.sh             (system.backup_targets[])
#   - capabilities/tag-coverage-audit.sh (vault.tag_audit_exemptions[])
#   - capabilities/placement-validate.sh (vault.logs_whitelist_subdirs[])
#   - capabilities/stale-detect.sh       (vault.logs_whitelist_subdirs[])
#   - capabilities/frontmatter-enforce.sh (vault.engagement_aliases{})
#
# Path resolution order:
#   1. $UMR_USER_MANIFEST_PATH (test/CI override)
#   2. $USER_MANIFEST_PATH (compat with prior consumer convention)
#   3. ${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json
#
# Failure mode (best-effort + diagnostic): missing file / missing field /
# missing jq / parse error → caller-supplied fallback (empty for arrays,
# `{}` for objects). No findings emitted; no non-zero exit. Capability
# wrappers handle graceful-degrade per their own Output Contract.
#
# Bash 3.2 clean per R-23.

_umr_resolve_path() {
  printf '%s' "${UMR_USER_MANIFEST_PATH:-${USER_MANIFEST_PATH:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}}"
}

_umr_readable() {
  local manifest
  manifest=$(_umr_resolve_path)
  [[ -r "$manifest" ]] && command -v jq >/dev/null 2>&1
}

# umr_get_array <jq-path>
# Prints array elements one per line. Empty / missing / error → no output.
umr_get_array() {
  local path="$1"
  if ! _umr_readable; then
    return 0
  fi
  local manifest
  manifest=$(_umr_resolve_path)
  jq -r "${path}[]? // empty" "$manifest" 2>/dev/null
}

# umr_get_object <jq-path>
# Prints object as compact JSON. Missing / error / non-object → "{}".
umr_get_object() {
  local path="$1"
  if ! _umr_readable; then
    printf '%s' '{}'
    return 0
  fi
  local manifest val
  manifest=$(_umr_resolve_path)
  val=$(jq -c "${path} // {}" "$manifest" 2>/dev/null)
  if [[ -z "$val" || "$val" == "null" ]]; then
    printf '%s' '{}'
  else
    printf '%s' "$val"
  fi
}
