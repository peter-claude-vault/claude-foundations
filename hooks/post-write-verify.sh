#!/bin/bash
# Hook: PostToolUse (Edit|Write) — Validate vault file frontmatter after writes.
# Advisory only — the write already happened. Surfaces problems in-session via additionalContext.
set -euo pipefail

source "$HOME/.claude/hooks/lib/paths.sh"
source "$HOME/.claude/hooks/lib/registry.sh"

# =============================================================================
# SP13 T-3 (2026-05-14) — foundation-master.json bundle-at-load
# =============================================================================
# Single governance read source per hook invocation. Replaces direct reads of:
#   - schemas/vault-schema.json    (DISSOLVED SP13 T-4 — types absorbed)
#   - governance/mandatory-files-rules.json  (consumed via bundle.mandatory_files)
# $FOUNDATION_MASTER_PATH override mirrors pre-write-guard.sh test-isolation
# contract. Missing bundle → fail-OPEN (same posture as legacy SCHEMA_FILE
# missing-file behavior).
FOUNDATION_MASTER="${FOUNDATION_MASTER_PATH:-$HOME/Code/claude-stem/governance/foundation-master.json}"

# Parse stdin
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Skip if no file path or not a vault file
if [[ -z "$FILE_PATH" ]] || [[ "$FILE_PATH" != "$VAULT_ROOT/"* ]]; then
  exit 0
fi

# Skip if bundle doesn't exist (fail-OPEN; T-8 install.sh ships the bundle)
if [[ ! -f "$FOUNDATION_MASTER" ]]; then
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

# --- _index.md self-exempt loop guard (SP03 Session 20 — R-44 / _index.md mandate) ---
# Per governance/file-type-contracts/_index.md.json `consumers[0].loop_guard`: the post-write
# hook must self-exempt on _index.md writes to prevent the Tier 1 bootstrap+live-sync section
# below from recursing on its own writes. Pre-write-guard validates _index.md frontmatter at
# write-time; post-write validation surface is intentionally skipped here per the contract.
if [[ "$FILE_PATH" == */_index.md ]]; then
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
    format_output "PostToolUse" "Engagement CLAUDE.md completeness check: ${SAFE_WARN} Fix before moving on." || true
    exit 0
  fi
fi

# Extract frontmatter (between first two --- lines)
FRONTMATTER=$(awk '/^---$/{c++;next} c==1{print} c>=2{exit}' "$FILE_PATH")

# If no frontmatter, skip (some files legitimately have none, e.g. CLAUDE.md)
if [[ -z "$FRONTMATTER" ]]; then
  exit 0
fi

# Validate YAML and check required fields in one python3 call.
# SP13 T-3 (2026-05-14): schema_file is now foundation-master.json; extract
# the `.types` subtree (shape-compatible with the dissolved vault-schema.json
# per-type-key registry).
RESULT=$(python3 -c "
import yaml, json, sys

raw = sys.stdin.read()
schema_file = sys.argv[2] if len(sys.argv) > 2 else ''

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

# Load schema — bundle.types subtree (SP13 T-3: was vault-schema.json top level)
try:
    bundle = json.load(open(schema_file))
    schema = bundle.get('types', {})
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
" "$REL_PATH" "$FOUNDATION_MASTER" <<< "$FRONTMATTER" 2>&1)

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
  format_output "PostToolUse" "$EMIT_MSG" || true
fi

# --- Tier 1 — _index.md auto-bootstrap (SP03 Session 20 — R-44 / _index.md mandate) ---
#
# Per governance/mandatory-files-rules.json `mandates._index_md` + governance/file-type-contracts/_index.md.json:
# when a write hits a non-exempt folder lacking a sibling _index.md, auto-create it with
# frontmatter stub + H1 + placeholder folder-context paragraph + empty sentinel-wrapped
# contents-enum table. The loop guard above prevents recursion when this section's write
# triggers the hook on the new _index.md.
#
# Tier 2 (audit sweep) and Tier 3 (--deep semantic audit) live in
# skills/librarian/capabilities/index-maintain.sh (contract at
# governance/librarian-capabilities/index-maintain.md; SP05 implements per
# SP03-authors-contract / SP05-implements pattern).
#
# Live-sync of the contents-enum table for the written sibling file is part of this
# Tier 1 surface per the contract but deferred to a subsequent commit (the bootstrap
# is the load-bearing structural mandate; live-sync is convenience surfaced by the
# Tier 2 daily sweep). Search this file for [SP03-Session-20-live-sync-deferred].
# SP13 T-3 (2026-05-14): exemption_paths sourced from foundation-master.json
# bundle (.mandatory_files.mandates._index_md.exemption_paths) instead of the
# direct read of governance/mandatory-files-rules.json. $FOUNDATION_MASTER
# resolves from $FOUNDATION_MASTER_PATH override → foundation-repo default.
if [[ -f "$FOUNDATION_MASTER" ]]; then
  FOLDER_DIR=$(dirname "$FILE_PATH")
  SIBLING_INDEX="$FOLDER_DIR/_index.md"
  if [[ ! -f "$SIBLING_INDEX" ]]; then
    BOOTSTRAP_RESULT=$(python3 - "$FOLDER_DIR" "$SIBLING_INDEX" "$FILE_PATH" "$VAULT_ROOT" "$FOUNDATION_MASTER" <<'PY' 2>&1 || true
import sys, os, json, fnmatch, datetime

folder_dir, sibling_index, file_path, vault_root, bundle_file = sys.argv[1:6]

# Bail out cleanly if folder is not under vault root
if not folder_dir.startswith(vault_root + os.sep) and folder_dir != vault_root:
    print("SKIP: not under vault root")
    sys.exit(0)

rel_folder = folder_dir[len(vault_root) + 1:] if folder_dir != vault_root else ""

# Don't bootstrap at vault root — vault-root _index.md is out of mandate scope
if not rel_folder:
    print("SKIP: vault root")
    sys.exit(0)

# Load exemption list from foundation-master.json#mandatory_files.mandates._index_md.exemption_paths
# (SP13 T-3: was governance/mandatory-files-rules.json#mandates._index_md.exemption_paths)
try:
    with open(bundle_file) as fh:
        bundle = json.load(fh)
    mandates = bundle.get("mandatory_files", {})
    exempt_globs = mandates.get("mandates", {}).get("_index_md", {}).get("exemption_paths", [])
except Exception as e:
    print(f"SKIP: bundle file unreadable: {e}")
    sys.exit(0)

# Match folder against exemption globs (fnmatch on the **/* glob shape)
for glob in exempt_globs:
    glob_stripped = glob.rstrip("/").rstrip("*").rstrip("/")
    if not glob_stripped:
        continue
    if rel_folder == glob_stripped or rel_folder.startswith(glob_stripped + "/"):
        print(f"SKIP: exempt path matched glob '{glob}'")
        sys.exit(0)

# Derive frontmatter values from path
folder_name = os.path.basename(folder_dir)
path_depth = rel_folder.count(os.sep) + 1  # 1 for top-level (depth 1)

# Infer tag from structural-dimension lineage (best-effort; first path segment maps to a dimension prefix)
inferred_tags = []
segments = rel_folder.split(os.sep)
if segments:
    first_segment = segments[0]
    # Conservative tag inference — vault-specific dimension mapping
    tag_prefix_map = {
        "Engagements": ("engagement", segments[1] if len(segments) > 1 else None),
        "Personal Initiatives": ("initiative", segments[1] if len(segments) > 1 else None),
        "About Me": ("about-me", segments[1] if len(segments) > 1 else "general"),
    }
    if first_segment in tag_prefix_map:
        prefix, value = tag_prefix_map[first_segment]
        if value:
            slug = value.lower().replace(" ", "-").replace("_", "-")
            inferred_tags.append(f"#{prefix}/{slug}")
    if not inferred_tags:
        # Fallback: tag the folder by its lineage as a generic scope
        slug = first_segment.lower().replace(" ", "-").replace("_", "-")
        inferred_tags.append(f"#scope/{slug}")

# Build frontmatter
today = datetime.date.today().isoformat()
fm_lines = ["---", "type: index"]
if path_depth >= 2:
    fm_lines.append(f"parent_folder: {rel_folder}")
fm_lines.append("tags:")
for tag in inferred_tags:
    fm_lines.append(f'  - "{tag}"')
fm_lines.append(f"updated: {today}")
fm_lines.append("---")
fm_lines.append("")

# Build body
body_lines = [
    f"# {folder_name}",
    "",
    "*[Folder context paragraph: 2-4 sentences describing what lives here, what doesn't, why the folder exists. Pedagogical. Replace this placeholder on next visit.]*",
    "",
    "<!-- contents-enum:start -->",
    "",
    "| File | Lines | Type | Description |",
    "|---|---|---|---|",
    "",
    "<!-- contents-enum:end -->",
    "",
]

content = "\n".join(fm_lines + body_lines) + "\n"
try:
    # Atomic temp+rename — never partial state visible
    tmp_path = sibling_index + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.rename(tmp_path, sibling_index)
    print(f"BOOTSTRAP_OK: {sibling_index}")
except Exception as e:
    print(f"BOOTSTRAP_FAIL: {e}")
    sys.exit(1)
PY
)
    if [[ "$BOOTSTRAP_RESULT" == BOOTSTRAP_OK:* ]]; then
      mkdir -p "$HOOKS_STATE" 2>/dev/null || true
      echo "$(date -Iseconds) | post-write-verify | bootstrap-auto-created | ${SIBLING_INDEX} | triggered-by ${FILE_PATH}" >> "$HOOKS_STATE/hook-audit.log" 2>/dev/null || true
      format_output "PostToolUse" "[R-44 _INDEX.MD AUTO-BOOTSTRAPPED] Created ${SIBLING_INDEX#$VAULT_ROOT/} at first-write to non-exempt folder. Fill the placeholder folder-context paragraph on next visit. Live-sync of the contents-enum table is deferred to the Tier 2 daily sweep ([SP03-Session-20-live-sync-deferred]); /librarian full reconciles." || true
    elif [[ "$BOOTSTRAP_RESULT" == BOOTSTRAP_FAIL:* ]]; then
      mkdir -p "$HOOKS_STATE" 2>/dev/null || true
      echo "$(date -Iseconds) | post-write-verify | bootstrap-failed | ${SIBLING_INDEX} | ${BOOTSTRAP_RESULT}" >> "$HOOKS_STATE/hook-audit.log" 2>/dev/null || true
    fi
  fi
fi

exit 0
