#!/usr/bin/env bash
# tests/sp14-hooks-branch3-violation-bad-enum.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #3 vault-writer
# frontmatter validation. Permutation: VIOLATION (bad enum value).
#
# Contract under test (line 989-993 — writer_kind enum check):
#   Write to Vault Writers/<writer>.md with a writer_kind value NOT in
#   pillar-6 enum [connector, agentic-flow, auto-research, scheduled-skill,
#   custom] → DENY with reason naming the offending value + enum list.
#
# Note: spec inventory says "destinations[] contains value not in pillar-7
# enum" but pre-write-guard.sh Branch #3 (line 941-1028) does NOT validate
# destinations[] entries against any enum — it only checks frontmatter_
# enums.writer_kind / .status / .type and required-field presence. The
# enum-violation fixture exercises writer_kind enum (load-bearing in the
# substrate). This is a documented divergence — see RUN-ALL header.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #3 — bad writer_kind enum value (violation/deny)\n'

target="$VAULT_ROOT/Vault Writers/bad-enum-writer.md"
mkdir -p "$(dirname "$target")"

# writer_kind=unknown-kind is NOT in the enum.
content="---
type: vault-writer
writer_name: Bad Enum Writer
writer_kind: unknown-kind
writer_skill: bad-enum
destinations:
  - path: \$VAULT_ROOT/Foo/bar.md
    output_type: markdown
status: active
created: 2026-05-20
updated: 2026-05-20
tags:
  - type/vault-writer
---

# Bad Enum Writer
"

payload=$(build_write_payload "$target" "$content")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0 (deny via JSON)" 0 "$rc"
assert_contains "Branch #3 marker present" "$out" "SP14 Branch #3"
assert_contains "writer_kind enum violation reason" "$out" "writer_kind: 'unknown-kind'"
assert_contains "lists enum values" "$out" "not in enum"
assert_contains "permissionDecision is deny" "$out" "\"permissionDecision\": \"deny\""

fixture_summary
