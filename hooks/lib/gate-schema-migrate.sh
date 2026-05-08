#!/bin/bash
# gate-schema-migrate.sh — Plan 80/81 SP01 T-11 schema migration callback.
#
# Per Terraform state-upgrade pattern: ship the migration contract NOW even if
# v1-only. v2 callback bodies land when v2 schema lands; v1→v1 is no-op
# pass-through. Lock-file at $HOME/.claude/state/gate-schemas.lock records
# which schema version each plan was last validated against; drift between
# declared and locked version triggers re-validation on next index regen.
#
# Usage:
#   gate-schema-migrate.sh <from-version> <to-version> < manifest-in.json > manifest-out.json
#
# Exit codes:
#   0    successful migration (manifest written to stdout)
#   1    no migration path (from > to, or migration callback not implemented)
#   2    invalid input JSON
#   3    invalid version arguments
#
# Migration registry (extend as schema versions land):
#   1 → 1   no-op pass-through
#   1 → 2   NOT YET DEFINED (v2 schema not yet landed)
#
# OQ-1 disposition: stdin/stdout for testability (per packet §13.1 OQ-1 lean).

set -uo pipefail

FROM_VERSION="${1:-}"
TO_VERSION="${2:-}"

if [[ -z "$FROM_VERSION" ]] || [[ -z "$TO_VERSION" ]]; then
  echo "Usage: $0 <from-version> <to-version> < manifest-in.json > manifest-out.json" >&2
  exit 3
fi

# Validate version args are positive integers.
if ! [[ "$FROM_VERSION" =~ ^[1-9][0-9]*$ ]] || ! [[ "$TO_VERSION" =~ ^[1-9][0-9]*$ ]]; then
  echo "Versions must be positive integers; got from=$FROM_VERSION to=$TO_VERSION" >&2
  exit 3
fi

# Read manifest from stdin
INPUT=$(cat)

# Validate input is valid JSON
if ! jq -e . <<< "$INPUT" >/dev/null 2>&1; then
  echo "Input is not valid JSON" >&2
  exit 2
fi

# Validate input declares the from-version it claims
INPUT_VERSION=$(jq -r '.schema_version // empty' <<< "$INPUT")
if [[ -z "$INPUT_VERSION" ]]; then
  echo "Input manifest missing schema_version field" >&2
  exit 2
fi

# Schema_version may be int or string; coerce to int for comparison
INPUT_VERSION_NUM=$(jq -r 'if (.schema_version | type) == "number" then .schema_version else (.schema_version | tonumber? // 0) end' <<< "$INPUT" 2>/dev/null || echo "0")
if [[ "$INPUT_VERSION_NUM" != "$FROM_VERSION" ]]; then
  echo "Input manifest declares schema_version=$INPUT_VERSION (parsed=$INPUT_VERSION_NUM); migration claimed from=$FROM_VERSION" >&2
  exit 2
fi

# Migration dispatch
migration_key="${FROM_VERSION}-${TO_VERSION}"

case "$migration_key" in
  1-1)
    # No-op pass-through (idempotent revalidation use case).
    jq '.' <<< "$INPUT"
    exit 0
    ;;

  1-2)
    # v1 → v2 callback. NOT YET DEFINED — v2 schema not yet landed.
    # When v2 lands, this branch implements the transformation logic. Per
    # packet §3.12: "Migration callback contract defined now: gate-schema-migrate.sh
    # <from-version> <to-version> accepts a manifest + outputs the migrated manifest."
    #
    # Expected v2 changes (placeholder; revisit at v2 design time):
    #   - subplan_carve_out field for sub-plan narrowing master scope
    #     (deferred from v1 per packet §10 deferred section)
    #   - per-plan R-37 coupled_surfaces (v1 ships global only per OQ-7)
    #   - cross-vault scope sharing fields
    echo "Migration 1→2 not yet implemented (v2 schema not landed). Place this manifest behind v1 declaration until v2 lands." >&2
    exit 1
    ;;

  *)
    if [[ "$FROM_VERSION" -gt "$TO_VERSION" ]]; then
      echo "Downgrade migrations not supported (from=$FROM_VERSION > to=$TO_VERSION). Schema migrations are forward-only." >&2
    else
      echo "No migration path defined for $FROM_VERSION → $TO_VERSION." >&2
    fi
    exit 1
    ;;
esac
