#!/bin/bash
# generate-corpus.sh — Plan 80/81 SP01 T-16 corpus expansion (25 → 70+).
#
# Authors fixtures f26..f73 covering:
#   - Vault-shape representatives (engagements, logs, daily, archives) — 18
#   - YAML / frontmatter adversarial edge cases — 12
#   - Tag taxonomy adversarial — 10
#   - Path-based exemption + non-md edge cases — 8
#
# All fixtures are decision-class agnostic at author time; baseline is locked
# via decision-equivalence-test.sh --snapshot after generation. The runner's
# behavior-preservation contract (T-6 refactor → 0 divergences vs baseline)
# is the authoritative test.
#
# Run idempotently: re-running overwrites fixtures + manifest.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

# Create a single fixture JSON file. Args: id, file_path, content_lines_via_stdin
write_fixture() {
  local id="$1" tool="$2" path="$3"
  local content
  content=$(cat)
  jq -n \
    --arg t "$tool" \
    --arg p "$path" \
    --arg c "$content" \
    '{tool_name: $t, tool_input: {file_path: $p, content: $c}}' \
    > "$FIXTURES_DIR/${id}.json"
}

# === f26: Engagements/<X>/Updates/<file>.md, type: updates (alias → engagement) ===
write_fixture f26-updates-alias Write '$VAULT_ROOT/Engagements/Acme/Updates/2026-04-15.md' <<'EOF'
---
type: updates
engagement: Acme
updated: 2026-05-07
status: active
tags:
  - engagement/acme
  - status/active
---

Daily updates body.
EOF

# === f27: Engagements/<X>/Meetings/<file>.md, type: meeting-note ===
write_fixture f27-engagement-meeting Write '$VAULT_ROOT/Engagements/Acme/Meetings/2026-05-07-standup.md' <<'EOF'
---
type: meeting-note
engagement: Acme
date: 2026-05-07
participants:
  - PT
tags:
  - engagement/acme
  - scope/meeting
---

# Standup
Notes.
EOF

# === f28: Engagements/<X>/CLAUDE.md (NON-exempt; T4 navigation) ===
write_fixture f28-engagement-claude-md Write '$VAULT_ROOT/Engagements/Acme/CLAUDE.md' <<'EOF'
---
type: navigation
engagement: Acme
updated: 2026-05-07
tags:
  - engagement/acme
---

# Acme Engagement Navigation
Subfolders + key links.
EOF

# === f29: Engagements/<X>/People/<person>.md, type: people ===
write_fixture f29-engagement-people Write '$VAULT_ROOT/Engagements/Acme/People/jane-doe.md' <<'EOF'
---
type: people
name: Jane Doe
role: PM
engagement: Acme
tags:
  - engagement/acme
  - scope/people
---

# Jane Doe
Context.
EOF

# === f30: Engagements/<X>/Project/<X>.md, type: project ===
write_fixture f30-engagement-project Write '$VAULT_ROOT/Engagements/Acme/Project/Migration.md' <<'EOF'
---
type: project
project: Migration
engagement: Acme
status: active
updated: 2026-05-07
tags:
  - engagement/acme
  - project/migration
  - status/active
---

# Project: Migration
Body.
EOF

# === f31: Logs/architect-2026-05-07.md (architect output) ===
write_fixture f31-logs-architect Write '$VAULT_ROOT/Logs/architect-2026-05-07.md' <<'EOF'
---
type: log
date: 2026-05-07
tags:
  - log/architect
---

# Architect — 2026-05-07
Output.
EOF

# === f32: Logs/foundations-essays/<x>.md — R-47 EXEMPT ===
write_fixture f32-foundations-essay Write '$VAULT_ROOT/Logs/foundations-essays/ai-fluency.md' <<'EOF'
---
type: log
date: 2026-05-07
---

# AI Fluency Essay
No tags required (R-47 exempt path).
EOF

# === f33: Logs/backlog-progress/<slug>.md — R-47 EXEMPT ===
write_fixture f33-backlog-progress Write '$VAULT_ROOT/Logs/backlog-progress/manifest-generalization.md' <<'EOF'
---
type: log
date: 2026-05-07
---

<!-- task-done: 03/T-12 -->
Session work for plan 81 SP01.
EOF

# === f34: Logs/digest-2026-05-07.md ===
write_fixture f34-logs-digest Write '$VAULT_ROOT/Logs/digest-2026-05-07.md' <<'EOF'
---
type: log
date: 2026-05-07
tags:
  - log/digest
---

# Digest 2026-05-07
EOF

# === f35: Logs/build-<feature>.md — R-47 EXEMPT ===
write_fixture f35-logs-build Write '$VAULT_ROOT/Logs/build-active-gates-rebuild.md' <<'EOF'
---
type: log
date: 2026-05-07
---

# Build Log
EOF

# === f36: Logs/ideation-brief-<slug>.md — R-47 EXEMPT (legacy alias path) ===
write_fixture f36-ideation-brief-legacy Write '$VAULT_ROOT/Logs/ideation-brief-foo.md' <<'EOF'
---
type: ideation-brief
date: 2026-05-07
---

# Ideation Brief
EOF

# === f37: Daily/2026-05-07.md (current daily-note, no type — inferred) ===
write_fixture f37-daily-current Write '$VAULT_ROOT/Daily/2026-05-07.md' <<'EOF'
# 2026-05-07
Today's note.
EOF

# === f38: Daily/2025/Q1/2025-01-15.md (archived daily-archive) ===
write_fixture f38-daily-archive Write '$VAULT_ROOT/Daily/2025/Q1/2025-01-15.md' <<'EOF'
---
type: daily-archive
date: 2025-01-15
tags:
  - log/daily
---

Archived daily.
EOF

# === f39: Daily/Weekly/2026-W18.md, type: weekly-summary ===
write_fixture f39-weekly-summary Write '$VAULT_ROOT/Daily/Weekly/2026-W18.md' <<'EOF'
---
type: weekly-summary
week: 2026-W18
tags:
  - log/weekly
---

# Week of 2026-W18
EOF

# === f40: Tags/<tag>.md — R-47 EXEMPT ===
write_fixture f40-tag-folder Write '$VAULT_ROOT/Tags/engagement-acme.md' <<'EOF'
---
type: index
---

# Tag: engagement/acme
EOF

# === f41: Archive/**/<x>.md — R-47 EXEMPT ===
write_fixture f41-archive Write '$VAULT_ROOT/Archive/2024/old-engagement.md' <<'EOF'
---
type: archive
archived_at: 2024-12-31
---

Old archived content.
EOF

# === f42: _orchestrator/<x>.md — R-47 EXEMPT ===
write_fixture f42-orchestrator Write '$VAULT_ROOT/_orchestrator/job-runner.md' <<'EOF'
---
type: reference
---

Orchestrator content.
EOF

# === f43: Personal Initiatives/<X>.md ===
write_fixture f43-personal-initiative Write '$VAULT_ROOT/Personal Initiatives/Claude Foundations/index.md' <<'EOF'
---
type: personal-initiative
status: active
updated: 2026-05-07
tags:
  - initiative/claude-foundations
  - status/active
---

# Claude Foundations
EOF

# === Adversarial: YAML edge cases (f44-f55) ===

# === f44: Frontmatter not closed (missing trailing ---) ===
write_fixture f44-unclosed-frontmatter Write '$VAULT_ROOT/Engagements/Acme/broken.md' <<'EOF'
---
type: engagement
engagement: Acme
tags:
  - engagement/acme

# Body content without closing fence
This file has no closing --- after frontmatter.
EOF

# === f45: Type as YAML list (invalid) ===
write_fixture f45-type-as-list Write '$VAULT_ROOT/Engagements/Acme/list-type.md' <<'EOF'
---
type:
  - engagement
  - reference
engagement: Acme
tags:
  - engagement/acme
---

Type field is a list. Should be a string.
EOF

# === f46: Type as null ===
write_fixture f46-type-null Write '$VAULT_ROOT/Engagements/Acme/null-type.md' <<'EOF'
---
type: null
engagement: Acme
tags:
  - engagement/acme
---

Body.
EOF

# === f47: Type with capitalization ===
write_fixture f47-type-capital Write '$VAULT_ROOT/Engagements/Acme/capital.md' <<'EOF'
---
type: Engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - engagement/acme
---

Type with capital letter — strict matching.
EOF

# === f48: Multi-doc YAML (---  twice in frontmatter) ===
write_fixture f48-multi-doc-yaml Write '$VAULT_ROOT/Engagements/Acme/multidoc.md' <<'EOF'
---
type: engagement
engagement: Acme
---
---
extra: doc
---

Body after multi-doc YAML.
EOF

# === f49: Empty content body, valid frontmatter ===
write_fixture f49-empty-body Write '$VAULT_ROOT/Engagements/Acme/empty.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - engagement/acme
  - status/active
---
EOF

# === f50: Tags as inline-flow YAML ===
write_fixture f50-inline-flow-tags Write '$VAULT_ROOT/Engagements/Acme/inline.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags: [engagement/acme, status/active]
---

Tags via inline-flow YAML notation.
EOF

# === f51: Frontmatter with quoted strings ===
write_fixture f51-quoted-frontmatter Write '$VAULT_ROOT/Engagements/Acme/quoted.md' <<'EOF'
---
type: "engagement"
engagement: "Acme"
owner: "PT"
status: "active"
updated: "2026-05-07"
tags:
  - "engagement/acme"
  - "status/active"
---

Quoted strings should still parse.
EOF

# === f52: Tag with hash prefix (legacy Obsidian) ===
write_fixture f52-hash-prefix-tags Write '$VAULT_ROOT/Engagements/Acme/hash.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - "#engagement/acme"
  - "#status/active"
---

Hash prefix — Obsidian inline-tag syntax in YAML.
EOF

# === f53: Frontmatter with extra whitespace ===
write_fixture f53-frontmatter-whitespace Write '$VAULT_ROOT/Engagements/Acme/whitespace.md' <<'EOF'
---
type:    engagement
engagement:    Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  -   engagement/acme
  -   status/active
---

Extra whitespace around values.
EOF

# === f54: Tags as multi-line block scalar ===
write_fixture f54-block-scalar-tags Write '$VAULT_ROOT/Engagements/Acme/block.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags: |
  engagement/acme
  status/active
---

Tags as block-scalar literal (atypical).
EOF

# === f55: BOM-prefixed file ===
write_fixture f55-bom-prefix Write '$VAULT_ROOT/Engagements/Acme/bom.md' <<'EOF'
﻿---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - engagement/acme
  - status/active
---

UTF-8 BOM-prefixed file. Frontmatter parser must handle.
EOF

# === Adversarial: tag taxonomy (f56-f65) ===

# === f56: All 8 dimensions present ===
write_fixture f56-all-eight-dims Write '$VAULT_ROOT/Engagements/Acme/all-dims.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - engagement/acme
  - project/migration
  - scope/meeting
  - status/active
  - initiative/foundations
  - artefact-bd/proposal
  - about-me/learning
  - log/digest
---

All 8 dimensions tagged.
EOF

# === f57: Tag exceeds 25-cap ===
write_fixture f57-tag-cap-exceeded Write '$VAULT_ROOT/Engagements/Acme/many-tags.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - engagement/a
  - engagement/b
  - engagement/c
  - engagement/d
  - engagement/e
  - engagement/f
  - engagement/g
  - engagement/h
  - engagement/i
  - engagement/j
  - engagement/k
  - engagement/l
  - engagement/m
  - engagement/n
  - engagement/o
  - engagement/p
  - engagement/q
  - engagement/r
  - engagement/s
  - engagement/t
  - engagement/u
  - engagement/v
  - engagement/w
  - engagement/x
  - engagement/y
  - engagement/z
---

26 tags — exceeds 25-cap (R-47 advisory).
EOF

# === f58: Tag with leading slash ===
write_fixture f58-tag-leading-slash Write '$VAULT_ROOT/Engagements/Acme/slash.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - /engagement/acme
  - /status/active
---

Leading slash on tags — invalid prefix grammar.
EOF

# === f59: Tag dimension at limit (cap-25 exact) ===
write_fixture f59-tag-cap-exact-25 Write '$VAULT_ROOT/Engagements/Acme/cap25.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - engagement/a
  - engagement/b
  - engagement/c
  - engagement/d
  - engagement/e
  - engagement/f
  - engagement/g
  - engagement/h
  - engagement/i
  - engagement/j
  - engagement/k
  - engagement/l
  - engagement/m
  - engagement/n
  - engagement/o
  - engagement/p
  - engagement/q
  - engagement/r
  - engagement/s
  - engagement/t
  - engagement/u
  - engagement/v
  - engagement/w
  - engagement/x
  - engagement/y
---

Exactly 25 tags — at cap.
EOF

# === f60: Tags with deeply nested prefixes ===
write_fixture f60-deep-tag-paths Write '$VAULT_ROOT/Engagements/Acme/deep.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - engagement/acme/sub-team/migration/phase-1
  - status/active/in-progress/blocked
---

Deep nesting in tag paths.
EOF

# === f61: Tag with unicode chars ===
write_fixture f61-unicode-tags Write '$VAULT_ROOT/Engagements/Acme/unicode.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - engagement/é-acçents
  - status/aktiv
  - scope/中文
---

Unicode characters in tags.
EOF

# === f62: Empty tag string ===
write_fixture f62-empty-tag-string Write '$VAULT_ROOT/Engagements/Acme/empty-tag.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - ""
  - engagement/acme
---

Empty string as a tag entry.
EOF

# === f63: Tag with trailing slash ===
write_fixture f63-tag-trailing-slash Write '$VAULT_ROOT/Engagements/Acme/trailing.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - engagement/acme/
  - status/
---

Trailing slash on tags.
EOF

# === f64: Tag duplicates ===
write_fixture f64-tag-duplicates Write '$VAULT_ROOT/Engagements/Acme/dupes.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - engagement/acme
  - engagement/acme
  - engagement/acme
  - status/active
---

Repeated tag values.
EOF

# === f65: Tags-as-string (invalid YAML for Obsidian) ===
write_fixture f65-tags-as-string Write '$VAULT_ROOT/Engagements/Acme/string-tags.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags: engagement/acme status/active
---

Tags as a single space-delimited string (atypical Obsidian shape).
EOF

# === Adversarial: path-based exemption + non-md (f66-f73) ===

# === f66: File at vault root (not in any subfolder) ===
write_fixture f66-vault-root Write '$VAULT_ROOT/Misc.md' <<'EOF'
---
type: reference
updated: 2026-05-07
tags:
  - scope/misc
---

File directly at vault root.
EOF

# === f67: Path with spaces ===
write_fixture f67-path-with-spaces Write '$VAULT_ROOT/Engagements/My Engagement/file.md' <<'EOF'
---
type: engagement
engagement: My-Engagement
owner: PT
status: active
updated: 2026-05-07
tags:
  - engagement/my-engagement
---

Path contains spaces.
EOF

# === f68: Hidden file (.foo.md) ===
write_fixture f68-hidden-file Write '$VAULT_ROOT/Engagements/Acme/.hidden.md' <<'EOF'
---
type: engagement
engagement: Acme
owner: PT
status: active
updated: 2026-05-07
tags:
  - engagement/acme
---

Hidden file (dotfile prefix).
EOF

# === f69: Non-md file (.txt) ===
write_fixture f69-non-md-txt Write '$VAULT_ROOT/Engagements/Acme/notes.txt' <<'EOF'
This is a plain text file. Should be exempt from R-32/R-47 (vault-schema applies to *.md only).
EOF

# === f70: librarian-manifest variant — exempt path ===
write_fixture f70-librarian-manifest Write '$VAULT_ROOT/Logs/librarian-manifest.json' <<'EOF'
{"schema_version":1,"plans":[]}
EOF

# === f71: _index.md (legitimate infrastructure per feedback_index_file_convention) ===
write_fixture f71-index-md Write '$VAULT_ROOT/Engagements/_index.md' <<'EOF'
---
type: index
---

# Engagements Index
EOF

# === f72: File-Index.md (legitimate infrastructure) ===
write_fixture f72-file-index Write '$VAULT_ROOT/Engagements/Acme/File-Index.md' <<'EOF'
---
type: file-index
---

# File Index
EOF

# === f73: Sub-folder CLAUDE.md (NOT Engagements; should be exempt) ===
write_fixture f73-subfolder-claude-md Write '$VAULT_ROOT/Logs/CLAUDE.md' <<'EOF'
---
type: navigation
---

# Logs Navigation
Logs subfolder CLAUDE.md should be exempt (only Engagements/CLAUDE.md is non-exempt per T4).
EOF

echo "Generated fixtures f26..f73 ($(ls "$FIXTURES_DIR"/f[2-7][0-9]*.json 2>/dev/null | wc -l) files total)"
exit 0
