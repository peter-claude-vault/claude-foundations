#!/usr/bin/env bash
# onboarding/auto-author/surface-3-vault-claude-md.sh — SP12 T-6 (Plan 71 SP12 Session 2)
#
# Surface #3 — Auto-author the vault root CLAUDE.md (replaces SP07's thin
# identity-substituted skeleton with a generated artifact carrying:
#   - Routing Decision Tree (RDT) tuned to declared vault.organizational_method
#   - Tag taxonomy section keyed off declared _tag_prefixes (surface #4)
#   - Pre-write checklist tuned to declared canonical_file_types
# Three-step gate (single-target — uses lib/three-step-gate.sh).
# Provenance frontmatter prepended.
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - $TARGET (default <vault_root>/CLAUDE.md) when gate apply succeeds.
#     - $AUTO_AUTHOR_LOG (delegated to lib/three-step-gate.sh).
#   Schema-types declared:
#     - Provenance frontmatter validates against
#       schemas/provenance-frontmatter-schema.json.
#   Pre-write validation:
#     - User-manifest readable; baseline template readable.
#     - Pre-existing target without provenance frontmatter is treated as
#       protected (refuse unless --accept-user-authored).
#   Failure mode: BLOCK AND LOG.
#
# CONSTRAINTS (R-23): bash 3.2; jq required.
#
# USAGE:
#   surface-3-vault-claude-md.sh
#     [--target PATH]                   # default: <vault_root>/CLAUDE.md
#     [--user-manifest PATH]
#     [--vault-schema PATH]             # for _tag_prefixes lookup
#     [--template PATH]
#     [--auto-apply] [--skip-preview] [--dry-run]
#     [--accept-user-authored]
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP12 Session 2

set -u

diag() { printf 'surface-3 FAIL: %s\n' "$1" >&2; }
info() { printf 'surface-3: %s\n' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONBOARDING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ONBOARDING_DIR/.." && pwd)"

GATE_LIB="$ONBOARDING_DIR/lib/three-step-gate.sh"
PF_LIB="$REPO_ROOT/lib/provenance-frontmatter.sh"
[ -r "$GATE_LIB" ] || { diag "three-step-gate.sh not readable"; exit 2; }
[ -r "$PF_LIB" ]   || { diag "provenance-frontmatter.sh not readable"; exit 2; }
# shellcheck source=/dev/null
. "$GATE_LIB"
# shellcheck source=/dev/null
. "$PF_LIB"

# --- defaults + arg parsing ---
TEMPLATE_PATH="${TEMPLATE_PATH:-$REPO_ROOT/templates/vault-claude-md-template.md}"
USER_MANIFEST="${USER_MANIFEST:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
VAULT_SCHEMA="${VAULT_SCHEMA:-${CLAUDE_HOME:-$HOME/.claude}/schemas/vault-schema.json}"
TARGET=""
SURFACE_ID="sp12-t6"
GENERATED_FROM="section-c-vault+manifest"
ACCEPT_USER_AUTHORED=0
AUTO_APPLY=0
SKIP_PREVIEW=0

while [ $# -gt 0 ]; do
  case "$1" in
    --target)               TARGET="$2"; shift 2 ;;
    --user-manifest)        USER_MANIFEST="$2"; shift 2 ;;
    --vault-schema)         VAULT_SCHEMA="$2"; shift 2 ;;
    --template)             TEMPLATE_PATH="$2"; shift 2 ;;
    --auto-apply)           AUTO_APPLY=1; shift ;;
    --skip-preview)         SKIP_PREVIEW=1; shift ;;
    --dry-run)              gate_set_dry_run 1; shift ;;
    --accept-user-authored) ACCEPT_USER_AUTHORED=1; shift ;;
    -h|--help)              sed -n '2,40p' "$0"; exit 0 ;;
    *)                      diag "unknown arg: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { diag "jq required on PATH"; exit 2; }
[ -f "$TEMPLATE_PATH" ] || { diag "template not found: $TEMPLATE_PATH"; exit 2; }
[ -f "$USER_MANIFEST" ] || { diag "user-manifest not found: $USER_MANIFEST"; exit 2; }

# --- manifest accessors ---
mf_get() {
  local p="$1"
  jq -r --arg p "$p" '
    ($p | split(".")) as $parts
    | getpath($parts) // ""
    | if type == "object" or type == "array" then "" else (. | tostring) end
  ' "$USER_MANIFEST" 2>/dev/null
}

mf_get_array() {
  local p="$1"
  jq -r --arg p "$p" '
    ($p | split(".")) as $parts
    | getpath($parts) // []
    | if type == "array" then .[] else empty end
  ' "$USER_MANIFEST" 2>/dev/null
}

NAME="$(mf_get 'identity.name')"
ROLE="$(mf_get 'identity.role')"
ORGANIZATION="$(mf_get 'identity.organization')"
INDUSTRY="$(mf_get 'identity.industry')"
DEFAULT_AUDIENCE="$(mf_get 'vault.default_audience')"
ORG_METHOD="$(mf_get 'vault.organizational_method')"
TOP_LEVEL_FOLDER="$(mf_get 'vault.top_level_folder')"
HAS_STRUCTURED="$(mf_get 'vault.has_structured_projects')"
VAULT_ROOT="$(mf_get 'paths.vault_root')"
[ -z "$VAULT_ROOT" ] && VAULT_ROOT="$(mf_get 'vault.root')"

[ -z "$NAME" ]              && NAME="(unknown)"
[ -z "$ROLE" ]              && ROLE="(unknown)"
[ -z "$ORGANIZATION" ]      && ORGANIZATION="(unspecified)"
[ -z "$DEFAULT_AUDIENCE" ]  && DEFAULT_AUDIENCE="claude"
[ -z "$ORG_METHOD" ]        && ORG_METHOD="(undeclared)"
[ -z "$TOP_LEVEL_FOLDER" ]  && TOP_LEVEL_FOLDER="(undeclared)"

# Default target → <vault_root>/CLAUDE.md
if [ -z "$TARGET" ]; then
  if [ -z "$VAULT_ROOT" ]; then
    diag "vault root not declared in manifest; pass --target explicitly to write."
    exit 2
  fi
  TARGET="$VAULT_ROOT/CLAUDE.md"
fi

# --- pre-existing target detection ---
if [ -f "$TARGET" ]; then
  if pf_extract "$TARGET" 2>/dev/null | grep -q '^generated_by:'; then
    : # provenance present → gate diff path
  else
    if [ "$ACCEPT_USER_AUTHORED" != "1" ]; then
      diag "target exists without provenance frontmatter (treated as user-authored): $TARGET"
      diag "refusing to overwrite. Re-run with --accept-user-authored to proceed."
      exit 1
    fi
    info "target lacks provenance; --accept-user-authored set; gate will diff and prompt."
  fi
fi

# --- tag prefix lookup (manifest > vault-schema fallback) ---
collect_tag_prefixes() {
  # Prefer user-manifest vault.tag_prefixes; fall back to vault-schema._tag_prefixes.
  local mf_pfx
  mf_pfx="$(mf_get_array 'vault.tag_prefixes')"
  if [ -n "$mf_pfx" ]; then
    printf '%s\n' "$mf_pfx"
    return 0
  fi
  if [ -f "$VAULT_SCHEMA" ]; then
    jq -r '._tag_prefixes // [] | .[]' "$VAULT_SCHEMA" 2>/dev/null
  fi
}

# --- canonical_file_types lookup ---
collect_file_types() {
  mf_get_array 'vault.canonical_file_types'
}

# --- RDT (Routing Decision Tree) generators ---
# Three archetype branches keyed off org_method substring; default = generic.

_rdt_engagements() {
  cat <<EOF
## Routing Decision Tree

Use this tree when deciding where a new file goes in this vault.

\`\`\`
Is this related to a client engagement?
├── YES → Engagements/<engagement-name>/...
│         ├── Is it a meeting? → Engagements/<engagement>/Meetings/YYYY-MM-DD-<topic>.md
│         ├── Is it a project deliverable? → Engagements/<engagement>/Projects/<project>/<Name> - PRD.md
│         ├── Is it a stakeholder file? → Engagements/<engagement>/People/<Name>.md
│         ├── Is it strategic context? → Engagements/<engagement>/Strategic/<topic>.md
│         └── Is it a planning artifact? → Engagements/<engagement>/Planning/<artifact>.md
└── NO  → Is it transient capture or an idea?
          ├── Capture (email, transcript, dashboard) → Inbox/
          ├── Build log or session note      → Logs/build-<topic>.md
          ├── Ideation brief (system project)→ Logs/ideation-brief-<slug>.md
          └── System project idea            → System Backlog.md (one row + sentinel)
\`\`\`

When the engagement is closed, set \`status: complete|archived|historical|closed\` in
its Overview.md frontmatter — the librarian's stale-detect capability will exempt
the engagement from staleness audits.
EOF
}

_rdt_para() {
  cat <<EOF
## Routing Decision Tree

Use this tree when deciding where a new file goes in this vault.

\`\`\`
Is this content actively-worked or reference?
├── ACTIVE
│   ├── A specific outcome with deadline? → Projects/<project-name>/...
│   └── Ongoing area of responsibility?   → Areas/<area-name>/...
└── REFERENCE
    ├── Information you'll consult later? → Resources/<topic>/...
    └── Closed/inactive material?         → Archives/<original-path>...

Inbox capture remains the entry surface; daily/weekly review routes from Inbox/
into Projects/Areas/Resources or Archives.
\`\`\`
EOF
}

_rdt_topic() {
  cat <<EOF
## Routing Decision Tree

Use this tree when deciding where a new file goes in this vault.

\`\`\`
Is this content tied to a specific topic or active publication?
├── ACTIVE TOPIC OR PUBLICATION → Topics/<topic-name>/...
│   ├── Drafted essay or post → Topics/<topic>/<title>.md
│   ├── Outline               → Topics/<topic>/_outline-<title>.md
│   └── Source material       → Topics/<topic>/sources/...
├── INTERVIEW OR TRANSCRIPT → Interviews/YYYY-MM-DD-<subject>.md
└── TRANSIENT CAPTURE OR REFERENCE
    ├── Capture surface              → Inbox/
    ├── Build log or session note    → Logs/build-<topic>.md
    └── Reference material           → References/<topic>.md
\`\`\`
EOF
}

_rdt_generic() {
  cat <<EOF
## Routing Decision Tree

Use this tree when deciding where a new file goes in this vault. Adapt the
specifics to your declared organizational method (\`${ORG_METHOD}\`).

\`\`\`
Is this content actively-worked or reference?
├── ACTIVE
│   ├── Project-shaped (specific outcome) → ${TOP_LEVEL_FOLDER:-Projects}/<project>/...
│   └── Ongoing thread                    → ${TOP_LEVEL_FOLDER:-Areas}/<thread>/...
└── REFERENCE / TRANSIENT
    ├── Capture surface                   → Inbox/
    ├── Build log / session note          → Logs/build-<topic>.md
    ├── Ideation brief (system project)   → Logs/ideation-brief-<slug>.md
    └── System project idea               → System Backlog.md (one row + sentinel)
\`\`\`
EOF
}

emit_rdt() {
  case "$ORG_METHOD" in
    *engagement*|*Engagement*|*ENGAGEMENT*) _rdt_engagements ;;
    *PARA*|*para*)                          _rdt_para ;;
    *topic*|*Topic*)                        _rdt_topic ;;
    *)                                       _rdt_generic ;;
  esac
}

# --- Tag taxonomy section ---
emit_tag_taxonomy() {
  printf '## Tag Taxonomy\n\n'
  local prefixes
  prefixes="$(collect_tag_prefixes)"
  if [ -z "$prefixes" ]; then
    cat <<EOF
No \`_tag_prefixes\` are declared yet for this vault. Surface #4 of the
auto-authoring flow (\`onboarding/auto-author/surface-4-tag-prefixes.sh\`)
populates this list from your declared workflow archetype. Re-run that
surface, then re-run surface-3 to refresh this section.

Until then, every non-exempt vault file should carry at least one tag —
orphans in graph view are a hygiene alert.
EOF
    return 0
  fi
  cat <<EOF
Every non-exempt vault file carries \`tags:\` frontmatter with one or more
prefix-namespaced tags. Declared prefixes for this vault (sourced from
\`user-manifest.json\` \`vault.tag_prefixes[]\`):

EOF
  printf '%s\n' "$prefixes" | while IFS= read -r p; do
    [ -z "$p" ] && continue
    printf -- '- `%s`\n' "$p"
  done
  cat <<EOF

Tags should be specific (\`engagement/acme\` not just \`engagement\`). Empty-tagged
files trigger a librarian hygiene advisory. Add new prefixes by editing
\`vault.tag_prefixes[]\` in \`user-manifest.json\` and re-running surface-3 to
update this section.
EOF
}

# --- Pre-write checklist ---
emit_pre_write_checklist() {
  printf '## Pre-Write Checklist\n\n'
  local types
  types="$(collect_file_types)"
  cat <<EOF
Before writing a new file to this vault, verify:

1. **Path is correct.** Use the Routing Decision Tree above. When ambiguous,
   surface the question rather than guessing.
2. **Frontmatter validates.** Every file type has a required-fields contract
   declared in \`\$CLAUDE_HOME/schemas/vault-schema.json\`. Validate before write.
3. **Tags carry a prefix.** At least one tag in \`tags:\` frontmatter; prefix
   matches an entry in the Tag Taxonomy section above.
4. **Wikilinks resolve.** When linking to other vault files, use canonical
   titles; the wikilink contract for this vault is
   \`${DEFAULT_AUDIENCE:-claude}\`-audience aware.
5. **Audience-tagged.** If the file is human-read, exec-read, or
   external-distribution, signal that explicitly in the body intro.

EOF
  if [ -n "$types" ]; then
    cat <<EOF
### Declared file types (\`vault.canonical_file_types[]\`)

The following file types are declared for this vault. Each has a
required-fields contract in \`vault-schema.json\`:

EOF
    printf '%s\n' "$types" | while IFS= read -r t; do
      [ -z "$t" ] && continue
      printf -- '- `%s`\n' "$t"
    done
    printf '\n'
    cat <<EOF
When writing a file of one of these types, validate frontmatter against the
matching \`vault-schema.json\` entry before commit. The pre-write-guard hook
enforces this at write time.
EOF
  else
    cat <<EOF
### Declared file types (\`vault.canonical_file_types[]\`)

No canonical file types are declared yet for this vault. Re-run \`/onboard
--section c\` and re-run surface-3 once Section C captures the user's
declared file types.
EOF
  fi
}

# --- Generator (called by gate_generate) ---
_substitute_identity() {
  sed \
    -e "s|{{IDENTITY_NAME}}|$NAME|g" \
    -e "s|{{IDENTITY_ROLE}}|$ROLE|g" \
    -e "s|{{IDENTITY_ORGANIZATION}}|$ORGANIZATION|g" \
    -e "s|{{IDENTITY_INDUSTRY}}|${INDUSTRY:-(unspecified)}|g" \
    -e "s|{{VAULT_DEFAULT_AUDIENCE}}|$DEFAULT_AUDIENCE|g" \
    -e "s|{{VAULT_ORGANIZATIONAL_METHOD}}|$ORG_METHOD|g" \
    -e "s|{{VAULT_TOP_LEVEL_FOLDER}}|$TOP_LEVEL_FOLDER|g"
}

gen_vault_claude_md() {
  # 1. Provenance frontmatter
  pf_emit "$SURFACE_ID" "$GENERATED_FROM" || return 1
  printf '\n'

  # 2. Template head: title + identity table + Vault conventions section
  #    (everything BEFORE first '## Directory layout')
  awk '
    BEGIN { stop=0 }
    /^## Directory layout/ { stop=1 }
    stop == 0 { print }
  ' "$TEMPLATE_PATH" | _substitute_identity || return 1

  # 3. Generated RDT
  emit_rdt
  printf '\n'

  # 4. Generated tag taxonomy
  emit_tag_taxonomy
  printf '\n'

  # 5. Generated pre-write checklist
  emit_pre_write_checklist
  printf '\n'

  # 6. Template tail: Directory layout + Working with Claude + What /adopt did + What's next
  awk '
    BEGIN { keep=0 }
    /^## Directory layout/ { keep=1 }
    keep == 1 { print }
  ' "$TEMPLATE_PATH" | _substitute_identity || return 1

  return 0
}

# --- main ---
if [ -z "${TG_STAGE_DIR:-}" ]; then
  TG_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sp12-t6.XXXXXX")"
  export TG_STAGE_DIR
fi

stage="$(gate_generate "$SURFACE_ID" gen_vault_claude_md)" || { diag "gate_generate failed"; exit 2; }

if ! pf_validate "$stage" >/dev/null 2>&1; then
  diag "staged artifact failed provenance frontmatter validation"
  exit 2
fi

apply_args=""
[ "$SKIP_PREVIEW" = "1" ] && apply_args="$apply_args --skip-preview"
[ "$AUTO_APPLY"   = "1" ] && apply_args="$apply_args --accept-on-empty-stdin"

# shellcheck disable=SC2086
gate_apply "$stage" "$TARGET" $apply_args
rc=$?
case "$rc" in
  0) info "surface-3 complete (target: $TARGET)" ;;
  1) info "surface-3 aborted at gate prompt" ;;
  *) diag "gate_apply returned rc=$rc" ;;
esac
exit "$rc"
