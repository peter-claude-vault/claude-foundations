#!/usr/bin/env bash
# tests/sp14-hooks-branch3-violation-missing-field.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #3 vault-writer
# frontmatter validation. Permutation: VIOLATION (required field missing).
#
# Contract under test (line 969-979):
#   Write to Vault Writers/<writer>.md with one or more frontmatter_required
#   fields missing → DENY with reason naming the missing fields.
#   Reason format: "Vault Writers/ schema violation (SP14 Branch #3 / L-58).
#   Missing required: [field1, field2, ...]. ..."

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #3 — missing required field (violation/deny)\n'

target="$VAULT_ROOT/Vault Writers/broken-writer.md"
mkdir -p "$(dirname "$target")"

# Frontmatter is missing: writer_kind, writer_skill, destinations, status,
# created, updated, tags. Only type + writer_name supplied.
content="---
type: vault-writer
writer_name: Broken
---

# Broken
"

payload=$(build_write_payload "$target" "$content")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0 (deny via JSON not rc)" 0 "$rc"
assert_contains "Branch #3 deny marker present" "$out" "SP14 Branch #3"
assert_contains "schema violation reason" "$out" "Vault Writers/ schema violation"
assert_contains "names missing field writer_kind" "$out" "writer_kind"
assert_contains "lists missing required block" "$out" "Missing required:"
assert_contains "permissionDecision is deny" "$out" "\"permissionDecision\": \"deny\""

fixture_summary
