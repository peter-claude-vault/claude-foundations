#!/bin/bash
# people-audit — Periodic audit of People/*.md files under engagement directories.
# Cron-time only (NOT write-time) — write-time emission was disqualified by
# its 28% false-positive rate.
#
# Checks per people file (type: people):
#   1. Required fields present (sourced from `vault-schema.json.people.required`)
#   2. Body contains a `## Context` H2 section
#
# Engagement-status exemption (gated on manifest.vault.has_structured_projects):
#   When the vault uses an `Engagements/` structured-projects layout, engagement
#   directories whose overview/_index file declares `status: complete|archived|
#   historical|closed` are excluded from the scan.
#
# Exemptions:
#   - Files without `type: people` in frontmatter (not a People archetype)
#   - Engagement directories with terminal status (when structured projects on)
#
# Usage: people-audit.sh [--output FILE] [--batch-size N] [--verbose]
# Output: JSON-lines findings, one per non-conforming file.
set -euo pipefail

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
source "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/lib/findings.sh"

OUTPUT=""
BATCH_SIZE=50
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)     OUTPUT="$2"; shift 2 ;;
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    --verbose)    VERBOSE=true; shift ;;
    *)            echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Route findings emission via findings.sh (writes to FINDINGS_OUTPUT or stdout).
export FINDINGS_OUTPUT="$OUTPUT"

# Local emit() preserved for non-finding payloads (start/end/progress/exemption
# events) — these are raw JSON-line passthroughs.
emit() {
  emit_event "$1"
}

# Source required-field list from vault-schema (zero inline fallback).
VAULT_SCHEMA="${SCHEMAS_DIR:-${CLAUDE_HOME:-$HOME/.claude}/schemas}/vault-schema.json"
PEOPLE_REQUIRED=""
if [[ -r "$VAULT_SCHEMA" ]] && command -v jq >/dev/null 2>&1; then
  PEOPLE_REQUIRED=$(jq -r '.people.required // [] | join(",")' "$VAULT_SCHEMA" 2>/dev/null)
fi
if [[ -z "$PEOPLE_REQUIRED" ]]; then
  emit "{ \"people_audit_skipped\": \"vault-schema.people.required missing or empty\" }"
  exit 0
fi

# Read `has_structured_projects` gate from user-manifest.
USER_MANIFEST="${USER_MANIFEST_PATH:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
HAS_STRUCTURED_PROJECTS="false"
if [[ -r "$USER_MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
  HAS_STRUCTURED_PROJECTS=$(jq -r '.vault.has_structured_projects // false' "$USER_MANIFEST" 2>/dev/null)
fi

if [[ -z "${VAULT_ROOT:-}" ]]; then
  emit "{ \"people_audit_skipped\": \"VAULT_ROOT unset\" }"
  exit 0
fi

# --- Build exemption set: engagement paths with terminal status ---
# Gated on has_structured_projects; foundations without that layout skip the probe.
EXEMPT_PATHS=""
if [[ "$HAS_STRUCTURED_PROJECTS" == "true" ]]; then
  EXEMPT_PATHS=$(VAULT_ROOT="$VAULT_ROOT" python3 <<'PYEOF'
import os, re, sys
vault = os.environ.get('VAULT_ROOT', '')
if not vault:
    sys.exit(0)
exempt = []
eng_root = os.path.join(vault, 'Engagements')
if os.path.isdir(eng_root):
    for eng in sorted(os.listdir(eng_root)):
        eng_dir = os.path.join(eng_root, eng)
        if not os.path.isdir(eng_dir):
            continue
        # Probe _index.md, CLAUDE.md, and *Overview*.md for status:
        candidates = [
            os.path.join(eng_dir, '_index.md'),
            os.path.join(eng_dir, 'CLAUDE.md'),
        ]
        for f in os.listdir(eng_dir):
            if f.endswith('.md') and 'overview' in f.lower():
                candidates.append(os.path.join(eng_dir, f))
        status = None
        for cand in candidates:
            if not os.path.isfile(cand):
                continue
            with open(cand, 'r', errors='ignore') as fh:
                head = fh.read(2000)
            m = re.search(r'^status:\s*([a-zA-Z0-9-]+)', head, re.M)
            if m:
                val = m.group(1).lower()
                if val in ('complete', 'archived', 'historical', 'closed'):
                    status = val
                    break
        if status:
            exempt.append(eng_dir)
print('\n'.join(exempt))
PYEOF
)
fi

emit "{ \"people_audit_start\": \"$(date -Iseconds)\", \"exempt_engagements\": $(echo "$EXEMPT_PATHS" | grep -c . || echo 0), \"has_structured_projects\": $HAS_STRUCTURED_PROJECTS }"

if [[ "$VERBOSE" == "true" ]] && [[ -n "$EXEMPT_PATHS" ]]; then
  while IFS= read -r p; do
    [[ -n "$p" ]] && emit "{ \"exemption\": \"$p\" }"
  done <<< "$EXEMPT_PATHS"
fi

SCAN_COUNT=0
FINDING_COUNT=0
BATCH_COUNT=0

is_exempt() {
  local path="$1"
  while IFS= read -r exempt; do
    [[ -z "$exempt" ]] && continue
    if [[ "$path" == "$exempt"/* ]]; then
      return 0
    fi
  done <<< "$EXEMPT_PATHS"
  return 1
}

while IFS= read -r -d '' file; do
  # Only files under */People/ directories
  case "$file" in
    */People/*.md) ;;
    *)             continue ;;
  esac

  SCAN_COUNT=$((SCAN_COUNT + 1))

  if is_exempt "$file"; then
    continue
  fi

  REL="${file#$VAULT_ROOT/}"

  # Extract frontmatter + check type + required + ## Context
  FINDINGS=$(PEOPLE_REQUIRED="$PEOPLE_REQUIRED" python3 - "$file" "$REL" <<'PYEOF' 2>/dev/null || true
import os, sys, re, yaml
path, rel = sys.argv[1], sys.argv[2]
required = [s.strip() for s in os.environ.get('PEOPLE_REQUIRED', '').split(',') if s.strip()]
try:
    with open(path, 'r', errors='ignore') as f:
        raw = f.read()
except Exception:
    sys.exit(0)

m = re.match(r'^---\n(.*?)\n---\n(.*)$', raw, re.S)
if not m:
    sys.exit(0)
try:
    fm = yaml.safe_load(m.group(1)) or {}
except Exception:
    sys.exit(0)
body = m.group(2)

if fm.get('type') != 'people':
    sys.exit(0)

missing = [f for f in required if f not in fm or fm[f] in (None, '', [])]

# `## Context` H2 within first 2KB of body
has_context = bool(re.search(r'^##\s+Context\b', body[:2000], re.M))

findings = []
if missing:
    findings.append('missing_required:' + ','.join(missing))
if not has_context:
    findings.append('missing_context_section')

if findings:
    print('|'.join(findings))
PYEOF
)

  if [[ -n "$FINDINGS" ]]; then
    FINDING_COUNT=$((FINDING_COUNT + 1))
    # Escape for JSON
    SAFE_REL=$(echo "$REL" | sed 's/"/\\"/g')
    SAFE_FIND=$(echo "$FINDINGS" | sed 's/"/\\"/g')
    emit_finding "people_non_conforming" "$SAFE_REL" "issues" "$SAFE_FIND"
  fi

  BATCH_COUNT=$((BATCH_COUNT + 1))
  if [[ $BATCH_COUNT -ge $BATCH_SIZE ]]; then
    emit "{ \"progress\": $SCAN_COUNT, \"findings_so_far\": $FINDING_COUNT }"
    BATCH_COUNT=0
  fi
done < <(find "$VAULT_ROOT" -path "*/People/*.md" -print0 2>/dev/null)

emit "{ \"people_audit_end\": \"$(date -Iseconds)\", \"files_scanned\": $SCAN_COUNT, \"findings\": $FINDING_COUNT }"
