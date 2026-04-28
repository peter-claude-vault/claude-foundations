#!/bin/bash
# Hook: PostToolUse (Edit|Write) — Validate vault file frontmatter after writes.
# Advisory only — the write already happened. Surfaces problems in-session via additionalContext.
set -euo pipefail

source "$HOME/.claude/hooks/lib/paths.sh"

SCHEMA_FILE="$SCHEMAS_DIR/vault-schema.json"

# Parse stdin
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Skip if no file path or not a vault file
if [[ -z "$FILE_PATH" ]] || [[ "$FILE_PATH" != "$VAULT_ROOT/"* ]]; then
  exit 0
fi

# Skip if schema doesn't exist
if [[ ! -f "$SCHEMA_FILE" ]]; then
  exit 0
fi

# Skip if file doesn't exist (deleted or failed write)
if [[ ! -f "$FILE_PATH" ]]; then
  exit 0
fi

# Skip non-markdown files
if [[ "$FILE_PATH" != *.md ]]; then
  exit 0
fi

# Skip operational files (manifests, coordination, etc.)
REL_PATH="${FILE_PATH#$VAULT_ROOT/}"
if [[ "$REL_PATH" == Logs/librarian-manifest* ]] || [[ "$REL_PATH" == Logs/.coordination/* ]]; then
  exit 0
fi

# --- Engagement CLAUDE.md completeness check ---
if [[ "$REL_PATH" == Engagements/*/CLAUDE.md ]]; then
  ENG_DIR=$(dirname "$FILE_PATH")
  ENG_NAME=$(basename "$ENG_DIR")
  WARNINGS=""

  # Check: all .md files in engagement tree are referenced in CLAUDE.md
  CLAUDE_CONTENT=$(cat "$FILE_PATH")
  while IFS= read -r md_file; do
    [[ -z "$md_file" ]] && continue
    base=$(basename "$md_file" .md)
    # Skip CLAUDE.md itself, _index.md, .DS_Store, File-Index
    [[ "$base" == "CLAUDE" || "$base" == "_index" || "$base" == "File-Index" || "$base" == ".DS_Store" ]] && continue
    if ! echo "$CLAUDE_CONTENT" | grep -q "$base" 2>/dev/null; then
      WARNINGS="${WARNINGS}File not in navigation table or skip list: ${md_file#$ENG_DIR/}. "
    fi
  done < <(find "$ENG_DIR" -name "*.md" -not -name "CLAUDE.md" -not -name "_index.md" -not -name "File-Index.md" 2>/dev/null)

  # Check: all People/*.md files referenced in Key People
  if [[ -d "$ENG_DIR/People" ]]; then
    while IFS= read -r pfile; do
      [[ -z "$pfile" ]] && continue
      pbase=$(basename "$pfile" .md)
      if ! echo "$CLAUDE_CONTENT" | grep -q "$pbase" 2>/dev/null; then
        WARNINGS="${WARNINGS}Person file not in Key People: People/${pbase}.md. "
      fi
    done < <(find "$ENG_DIR/People" -name "*.md" 2>/dev/null)
  fi

  if [[ -n "$WARNINGS" ]]; then
    SAFE_WARN=$(echo "$WARNINGS" | tr '"' "'")
    mkdir -p "$HOOKS_STATE" 2>/dev/null || true
    echo "$(date -Iseconds) | post-write-verify | INCOMPLETE | ${FILE_PATH} | ${SAFE_WARN}" >> "$HOOKS_STATE/hook-audit.log" 2>/dev/null || true
    printf '{"additionalContext":"Engagement CLAUDE.md completeness check: %s Fix before moving on."}\n' "$SAFE_WARN"
    exit 0
  fi
fi

# Extract frontmatter (between first two --- lines)
FRONTMATTER=$(awk '/^---$/{c++;next} c==1{print} c>=2{exit}' "$FILE_PATH")

# If no frontmatter, skip (some files legitimately have none, e.g. CLAUDE.md)
if [[ -z "$FRONTMATTER" ]]; then
  exit 0
fi

# Validate YAML and check required fields in one python3 call
RESULT=$(python3 -c "
import yaml, json, sys, os

raw = sys.stdin.read()
schema_file = os.path.expanduser('~/.claude/schemas/vault-schema.json')

# Parse YAML
try:
    data = yaml.safe_load(raw)
    if not isinstance(data, dict):
        print('YAML_ERROR|Frontmatter is not a YAML mapping')
        sys.exit(0)
except yaml.YAMLError as e:
    msg = str(e).replace(chr(34), chr(39))
    print(f'YAML_ERROR|YAML parse error: {msg}')
    sys.exit(0)

# Load schema
try:
    schema = json.load(open(schema_file))
except Exception:
    sys.exit(0)

# Determine schema key from type field
file_type = data.get('type', '')
rel_path = sys.argv[1] if len(sys.argv) > 1 else ''

type_map = {
    'meeting-note': 'meeting-note',
    'daily-note': 'daily-note',
    'inbox-archive': 'inbox-archive',
    'log': 'log',
    'reference': 'reference',
    'index': 'index',
    'weekly-summary': 'weekly-summary',
    'daily-archive': 'daily-archive',
    'skill-spec': 'reference',
    'people': 'people',
    'project': 'project',
    'engagement': 'engagement',
    'overview': 'engagement',
    'updates': 'engagement',
    'navigation': 'navigation',
    'prd': 'prd',
    'context': 'context',
    'personal-initiative': 'personal-initiative',
    'briefing': 'briefing',
    'strategic': 'strategic',
    'planning': 'planning',
    'archive': 'archive',
    'historical-brief': 'historical-brief',
    'ideation-brief': 'ideation-brief',
    'file-index': 'index',
    'tier-2': 'reference',
}
schema_key = type_map.get(file_type, '')

# Infer from path if type didn't match
if not schema_key:
    if rel_path.startswith('Daily/'):
        schema_key = 'daily-note'
    elif rel_path.startswith('People/'):
        schema_key = 'people'
    elif '/Projects/' in rel_path and rel_path.startswith('Engagements/'):
        schema_key = 'project'
    elif rel_path.startswith('Engagements/'):
        schema_key = 'engagement'

if not schema_key or schema_key not in schema:
    sys.exit(0)

required = schema[schema_key].get('required', [])
missing = [f for f in required if f not in data or data[f] is None]
if missing:
    fields = ', '.join(missing)
    print(f'MISSING|{fields}|{schema_key}')
else:
    print('OK')
" "$REL_PATH" <<< "$FRONTMATTER" 2>&1)

# --- R-38 + R-39 content advisories (Tier 1, combined emission) ---
# R-38: blockquote summary on >200-line non-allowlisted files
# R-39: provides: presence on canonical-scope >200-line files
# Promotion criteria live in ENFORCEMENT-MAP (R-35 framework). Advisory-only.
ADV_MSGS=$(python3 -c "
import yaml, sys

file_path = sys.argv[1]
rel_path = sys.argv[2]

ALLOWLIST_PREFIXES = ('Inbox/', 'Archive/', 'Daily/', 'Logs/', '.claude/skills/')
ALLOWLIST_EXACT = {'CLAUDE.md', 'Tasks.md', 'System Backlog.md', 'System Backlog - Archive.md', 'Vault Architecture.md'}
CANONICAL_SCOPE = {'reference', 'context', 'overview', 'engagement', 'briefing',
                   'strategic', 'planning', 'index', 'navigation', 'people',
                   'prd', 'personal-initiative'}

if rel_path in ALLOWLIST_EXACT or any(rel_path.startswith(p) for p in ALLOWLIST_PREFIXES):
    sys.exit(0)

try:
    with open(file_path, 'r', encoding='utf-8') as fh:
        full = fh.read()
except Exception:
    sys.exit(0)

data = {}
body = full
if full.startswith('---\n'):
    end = full.find('\n---\n', 4)
    if end >= 0:
        try:
            data = yaml.safe_load(full[4:end]) or {}
        except Exception:
            data = {}
        body = full[end+5:].lstrip('\n')
if not isinstance(data, dict):
    sys.exit(0)

line_count = full.count('\n') + 1
file_type = data.get('type', '')

advisories = []

# R-38: blockquote summary
if line_count > 200:
    first_10 = '\n'.join(body.split('\n')[:10])
    has_blockquote = '> **Summary:**' in first_10
    is_people_with_context = file_type == 'people' and '## Context' in body[:2000]
    if not has_blockquote and not is_people_with_context:
        advisories.append('R-38: ' + str(line_count) + '-line file lacks leading blockquote summary (> **Summary:** ... > **Canonical for:** ...)')

# R-39: provides: presence on canonical-scope files
if line_count > 200 and file_type in CANONICAL_SCOPE and 'provides' not in data:
    advisories.append('R-39: canonical-scope file (type=' + file_type + ', ' + str(line_count) + ' lines) lacks provides: field for grep-discoverability')

if advisories:
    print(' | '.join(advisories))
" "$FILE_PATH" "$REL_PATH" 2>/dev/null || true)

# Build combined additionalContext emission
EMIT_MSG=""
case "$RESULT" in
  YAML_ERROR\|*)
    ERR_MSG="${RESULT#YAML_ERROR|}"
    SAFE_MSG=$(echo "$ERR_MSG" | tr '"' "'" | tr '\n' ' ' | sed 's/  */ /g')
    mkdir -p "$HOOKS_STATE" 2>/dev/null || true
    echo "$(date -Iseconds) | post-write-verify | FAIL | ${FILE_PATH} | YAML error: ${SAFE_MSG}" >> "$HOOKS_STATE/hook-audit.log" 2>/dev/null || true
    EMIT_MSG="Post-write validation failed: ${SAFE_MSG}. Fix immediately."
    ;;
  MISSING\|*)
    BODY="${RESULT#MISSING|}"
    FIELDS="${BODY%|*}"
    SKEY="${BODY##*|}"
    SAFE_REL=$(echo "$REL_PATH" | tr '"' "'")
    mkdir -p "$HOOKS_STATE" 2>/dev/null || true
    echo "$(date -Iseconds) | post-write-verify | FAIL | ${FILE_PATH} | Missing fields: ${FIELDS} (${SKEY})" >> "$HOOKS_STATE/hook-audit.log" 2>/dev/null || true
    EMIT_MSG="Post-write validation failed: missing required fields [${FIELDS}] for schema type ${SKEY} in ${SAFE_REL}. Fix immediately."
    ;;
  OK|"")
    ;;
esac

if [[ -n "$ADV_MSGS" ]]; then
  SAFE_ADV=$(echo "$ADV_MSGS" | tr '"' "'" | tr '\n' ' ' | sed 's/  */ /g')
  mkdir -p "$HOOKS_STATE" 2>/dev/null || true
  echo "$(date -Iseconds) | post-write-verify | tier1_emit | ${FILE_PATH} | ${SAFE_ADV}" >> "$HOOKS_STATE/hook-audit.log" 2>/dev/null || true
  if [[ -n "$EMIT_MSG" ]]; then
    EMIT_MSG="${EMIT_MSG} | [CONTENT ADVISORIES] ${SAFE_ADV}"
  else
    EMIT_MSG="[CONTENT ADVISORIES] ${SAFE_ADV}"
  fi
fi

if [[ -n "$EMIT_MSG" ]]; then
  printf '{"additionalContext":"%s"}\n' "$EMIT_MSG"
fi

exit 0
