#!/usr/bin/env bash
# tests/sp14-hooks-branch1-classC-tagext-skip.sh
#
# SP14 T-18 fixture — pre-write-guard.sh Branch #1 Class D (SKILL.md
# vault-write detection — substrate name at line 484-538) WITH writer-
# reference already registered. Permutation: SKIP (the propose-and-validate
# nudge does NOT fire because the writer is registered).
#
# Inventory-labeled "Class C tagext-skip"; substrate has NO tag-extension
# class. The closest skip-path scenario in Branch #1 is Class D's "already
# registered" branch (line 522-525): if Vault Writers/*.md frontmatter
# contains writer_skill: <skill-slug>, the propose-and-validate fragment
# is omitted, only the standard SKILL CHANGE PROTOCOL fires.
#
# Substrate divergence finding (DOCUMENTED):
#   spec.md §1 lists "Classes A/B/C/D" for Branch #1; substrate implements
#   A/B/C/D where C = file-type (not tag-extension). No tag-extension class
#   exists in pre-write-guard.sh. The dispatch brief inventory's "Class C
#   tagext-skip" presumably refers to a planned-but-unimplemented class
#   OR mislabels Class D's skip path. Fixture exercises Class D skip path.
#
# Filename retained per dispatch brief inventory.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sp14-hooks-setup.sh"

setup_jailed_home
stage_substrate

printf '[fixture] Branch #1 Class D — SKILL.md with registered writer (skip)\n'

# Stage a SKILL.md under foundation-repo skills path (Class D matcher includes
# $HOME/Code/claude-stem/skills/<slug>/SKILL.md).
skill_slug="my-test-writer-skill"
skill_path="$HOME/Code/claude-stem/skills/$skill_slug/SKILL.md"
mkdir -p "$(dirname "$skill_path")"

# Pre-register the writer-reference in Vault Writers/ to exercise SKIP path.
mkdir -p "$VAULT_ROOT/Vault Writers"
cat > "$VAULT_ROOT/Vault Writers/$skill_slug.md" <<EOF
---
type: vault-writer
writer_name: My Test Writer
writer_kind: scheduled-skill
writer_skill: $skill_slug
destinations:
  - path: \$VAULT_ROOT/Daily/
    output_type: markdown
status: active
schedule: "@daily"
created: 2026-05-20
updated: 2026-05-20
tags:
  - type/vault-writer
---

# My Test Writer
EOF

# Construct a SKILL.md that declares vault writes in its Output Contract.
skill_content="---
name: $skill_slug
description: Test writer skill
---

# My Test Writer Skill

## Output Contract

Writes to \$VAULT_ROOT/Daily/{date}.md per tick.
Schema: daily-note.
Failure mode: block-and-log.
"

payload=$(build_write_payload "$skill_path" "$skill_content")
out=$(printf '%s' "$payload" | bash "$HOME/.claude/hooks/pre-write-guard.sh" 2>/dev/null)
rc=$?

assert_rc "exit code is 0 (allow with SKILL CHANGE PROTOCOL only)" 0 "$rc"
assert_contains "SKILL CHANGE PROTOCOL fragment present" "$out" "SKILL CHANGE PROTOCOL"
# Class D propose-and-validate is OMITTED because writer is registered.
assert_not_contains "Class D propose-and-validate fragment NOT present (skip path)" "$out" "SP14 Branch #1 Class D"

fixture_summary
