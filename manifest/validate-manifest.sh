#!/usr/bin/env bash
# validate-manifest.sh — validate a user-manifest.json against the schema.
#
# Usage: validate-manifest.sh <path-to-manifest.json>
# Exit codes:
#   0  valid
#   1  invalid (structural/required field violations)
#   2  missing file or jq not installed
#
# Deliberately dependency-light: uses jq only. A full JSON Schema validator
# (ajv, check-jsonschema) is optional and preferred in CI; this script is the
# runtime check that hooks and skills call synchronously.

set -euo pipefail

MANIFEST="${1:-}"

if [[ -z "$MANIFEST" ]]; then
  echo "usage: validate-manifest.sh <manifest.json>" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required for manifest validation" >&2
  exit 2
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "error: manifest not found at $MANIFEST" >&2
  exit 2
fi

if ! jq empty "$MANIFEST" >/dev/null 2>&1; then
  echo "error: manifest is not valid JSON" >&2
  exit 1
fi

fail() {
  echo "invalid: $1" >&2
  exit 1
}

# Required top-level sections
jq -e '.system' "$MANIFEST" >/dev/null || fail "missing .system"
jq -e '.identity' "$MANIFEST" >/dev/null || fail "missing .identity"
jq -e '.vault and (.vault | type == "object")' "$MANIFEST" >/dev/null \
  || fail ".vault missing or not an object (Obsidian vault is a hard prerequisite)"
jq -e '.vault.path and (.vault.path | length > 0)' "$MANIFEST" >/dev/null \
  || fail ".vault.path missing or empty"
jq -e '.vault.name and (.vault.name | length > 0)' "$MANIFEST" >/dev/null \
  || fail ".vault.name missing or empty"

# system required fields
jq -e '.system.schema_version and (.system.schema_version | test("^[0-9]+\\.[0-9]+$"))' \
  "$MANIFEST" >/dev/null || fail ".system.schema_version missing or malformed"
jq -e '.system.created_date' "$MANIFEST" >/dev/null \
  || fail ".system.created_date missing"
jq -e '.system.manifest_location' "$MANIFEST" >/dev/null \
  || fail ".system.manifest_location missing"
jq -e '.system.phases_completed | type == "array"' "$MANIFEST" >/dev/null \
  || fail ".system.phases_completed must be an array"

# phases_completed values must be in the allowed enum
jq -e '
  .system.phases_completed
  | all(. as $p | ["foundation","behavioral","domain"] | index($p) != null)
' "$MANIFEST" >/dev/null \
  || fail ".system.phases_completed contains unknown phase"

# identity required fields
jq -e '.identity.role and (.identity.role | length > 0)' "$MANIFEST" >/dev/null \
  || fail ".identity.role missing or empty"

# Optional sections must be object|array|null — never the wrong shape.
jq -e '
  (.tools        // null | type) as $tools        |
  (.vault        // null | type) as $vault        |
  (.projects     // null | type) as $projects     |
  (.people       // null | type) as $people       |
  (.tags         // null | type) as $tags         |
  (.integrations // null | type) as $integrations |
  (.behavioral   // null | type) as $behavioral   |
  (.domain       // null | type) as $domain       |
  ($tools        == "array"  or $tools        == "null") and
  ($vault        == "object") and
  ($projects     == "object" or $projects     == "null") and
  ($people       == "array"  or $people       == "null") and
  ($tags         == "object" or $tags         == "null") and
  ($integrations == "object" or $integrations == "null") and
  ($behavioral   == "object" or $behavioral   == "null") and
  ($domain       == "object" or $domain       == "null")
' "$MANIFEST" >/dev/null \
  || fail "optional sections have wrong types"

echo "valid: $MANIFEST"
exit 0
