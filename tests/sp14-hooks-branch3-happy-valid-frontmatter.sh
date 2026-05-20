#!/usr/bin/env bash
# tests/sp14-hooks-branch3-happy-valid-frontmatter.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #3 vault-writer
# frontmatter validation (line 941-1028). Permutation: HAPPY (valid
# writer-reference file passes branch #3 without deny).
#
# Contract under test (per spec.md §1 + alignment Session 5 L-58):
#   Write to Vault Writers/<writer>.md with complete frontmatter
#   (type=vault-writer + writer_kind ∈ enum + status ∈ enum + all
#   required fields + conditional fields for writer_kind) → branch #3
#   PASSES (no deny). Downstream may emit other context; branch #3
#   itself emits no fragment.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #3 — valid vault-writer frontmatter (happy)\n'

target="$VAULT_ROOT/Vault Writers/granola-meetings.md"
mkdir -p "$(dirname "$target")"

# Complete frontmatter for writer_kind=connector (requires writer_subtype +
# source + authentication + schedule).
content="---
type: vault-writer
writer_name: Granola Meeting Connector
writer_kind: connector
writer_skill: granola-connector
writer_subtype: granola
source: granola-api
authentication: oauth-token
schedule: \"@daily\"
destinations:
  - path: \$VAULT_ROOT/Meetings/{{date}} - {{title}}.md
    output_type: markdown
    posture: direct
status: active
created: 2026-05-20
updated: 2026-05-20
tags:
  - type/vault-writer
  - writer/connector
---

# Granola Meeting Connector

Pulls processed meeting transcripts.
"

payload=$(build_write_payload "$target" "$content")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0" 0 "$rc"
# Branch #3 deny fragment must NOT appear.
assert_not_contains "no Branch #3 schema violation deny" "$out" "Vault Writers/ schema violation"
assert_not_contains "no Branch #3 marker" "$out" "SP14 Branch #3"

fixture_summary
