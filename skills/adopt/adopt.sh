#!/usr/bin/env bash
# /adopt fresh-vault MVP scaffolding script.
#
# Reads $CLAUDE_HOME/user-manifest.json (SP07 Phase 1 output) and scaffolds the
# minimum-viable vault skeleton at vault.root: 5 directories, CLAUDE.md seeded
# from templates/vault-claude-md-template.md with identity substitution, an
# empty System Backlog.md, and a vault.canonical_file_types skeleton.
#
# Idempotent: mkdir -p, ln -sfn, cp -n. Re-running on an already-scaffolded
# vault is a no-op (post-write validation still runs).
#
# Exit codes:
#   0  success
#   10 pre-flight failure (CLAUDE_HOME unset, user-manifest missing/invalid)
#   20 vault.is_fresh != true (refusal)
#   21 state user-only without --force-install (refusal)
#   22 --retrofit-existing flag (v2.1 deferral refusal)
#   30 vault.root missing/empty in manifest
#   40 scaffolding write failure (block-and-log)
#   50 post-write validation failure (placeholder tokens remain)

set -uo pipefail

ADOPT_VERSION="1.0.0-mvp"

# ---- argv parse -------------------------------------------------------------

FORCE_INSTALL=0
RETROFIT_EXISTING=0
DRY_RUN=0
VERBOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --force-install)     FORCE_INSTALL=1 ;;
    --retrofit-existing) RETROFIT_EXISTING=1 ;;
    --dry-run)           DRY_RUN=1 ;;
    --verbose|-v)        VERBOSE=1 ;;
    --version)           echo "$ADOPT_VERSION"; exit 0 ;;
    --help|-h)
      cat <<'EOF'
Usage: adopt.sh [--force-install] [--dry-run] [--verbose]

Fresh-vault MVP scaffolding. Reads $CLAUDE_HOME/user-manifest.json and
scaffolds the vault root with 5 directories, seeded CLAUDE.md, empty
System Backlog.md, and canonical_file_types skeleton.

Refuses with exit 22 if --retrofit-existing is passed (v2.1 deferral).
EOF
      exit 0
      ;;
    *) printf 'adopt: unknown argument: %s\n' "$1" >&2; exit 10 ;;
  esac
  shift
done

# ---- diagnostic helpers -----------------------------------------------------

log_info() {
  if [ "$VERBOSE" = "1" ]; then
    printf 'adopt: %s\n' "$1"
  fi
}

log_err() {
  printf 'adopt: ERROR: %s\n' "$1" >&2
}

# ---- early refusal: --retrofit-existing -------------------------------------

if [ "$RETROFIT_EXISTING" = "1" ]; then
  log_err "--retrofit-existing is deferred to v2.1."
  log_err "MVP supports fresh-vault adoption only. See spec.md SP08 §scope-cuts:"
  log_err "  Retrofit is a high-touch edge case; v2.1 will ship a collision matrix."
  log_err "Workaround: copy your existing vault content into the scaffolded skeleton"
  log_err "manually after a fresh /adopt run."
  exit 22
fi

# ---- pre-flight: CLAUDE_HOME ------------------------------------------------

if [ -z "${CLAUDE_HOME:-}" ]; then
  log_err "CLAUDE_HOME is unset or empty."
  log_err "Resolve via: export CLAUDE_HOME=\"\$HOME/.claude\" (or wherever foundation is installed)."
  exit 10
fi

if [ ! -d "$CLAUDE_HOME" ]; then
  log_err "CLAUDE_HOME does not exist: $CLAUDE_HOME"
  exit 10
fi

USER_MANIFEST="$CLAUDE_HOME/user-manifest.json"
if [ ! -f "$USER_MANIFEST" ]; then
  log_err "user-manifest.json missing at $USER_MANIFEST"
  log_err "Run /onboard-foundation (SP07) BEFORE /adopt."
  exit 10
fi

# Validate JSON parseable.
if ! jq -e . "$USER_MANIFEST" >/dev/null 2>&1; then
  log_err "user-manifest.json is not valid JSON: $USER_MANIFEST"
  exit 10
fi

# ---- state classification: user-only refusal --------------------------------
#
# Foundation install presence is the proxy: $CLAUDE_HOME/foundation-manifest.json
# is shipped by install.sh (SP08 T-5 + T-1 cp -n step). Absent => state user-only
# (foundation not installed cleanly). Refuse without --force-install.

FOUNDATION_MANIFEST="$CLAUDE_HOME/foundation-manifest.json"
if [ ! -f "$FOUNDATION_MANIFEST" ]; then
  if [ "$FORCE_INSTALL" = "0" ]; then
    log_err "state classification: user-only ($CLAUDE_HOME lacks foundation-manifest.json)."
    log_err "Foundation install appears incomplete or absent. Re-run install.sh, OR"
    log_err "pass --force-install to scaffold the vault anyway."
    exit 21
  fi
  log_info "user-only state accepted via --force-install"
fi

# ---- read manifest ----------------------------------------------------------

manifest_get() {
  # $1: jq path; emits raw value or empty string on null/missing.
  jq -r "$1 // \"\"" "$USER_MANIFEST" 2>/dev/null
}

VAULT_IS_FRESH=$(jq -r '.vault.is_fresh' "$USER_MANIFEST" 2>/dev/null)
VAULT_ROOT=$(manifest_get '.vault.root')
VAULT_ORG_METHOD=$(manifest_get '.vault.organizational_method')
VAULT_TOP_FOLDER=$(manifest_get '.vault.top_level_folder')
VAULT_DEFAULT_AUDIENCE=$(manifest_get '.vault.default_audience')

IDENT_NAME=$(manifest_get '.identity.name')
IDENT_ROLE=$(manifest_get '.identity.role')
IDENT_ORG=$(manifest_get '.identity.organization')
IDENT_INDUSTRY=$(manifest_get '.identity.industry')

# ---- vault.is_fresh refusal -------------------------------------------------

if [ "$VAULT_IS_FRESH" != "true" ]; then
  log_err "vault.is_fresh is not true (got: ${VAULT_IS_FRESH:-null})."
  log_err "/adopt MVP scaffolds fresh vaults only. For an existing vault, defer to v2.1"
  log_err "retrofit flow (--retrofit-existing) which is not yet shipped."
  exit 20
fi

# ---- vault.root resolution --------------------------------------------------

if [ -z "$VAULT_ROOT" ]; then
  log_err "vault.root is empty in user-manifest.json."
  log_err "Re-run /onboard --section a to set the vault root path."
  exit 30
fi

# Expand ~ if present (bash 3.2 safe substring slice, NOT ${var#~/} which
# matches against expanded ~).
if [ "${VAULT_ROOT:0:2}" = "~/" ]; then
  VAULT_ROOT="$HOME/${VAULT_ROOT:2}"
fi

log_info "vault.root resolved: $VAULT_ROOT"

# ---- $PLANS_HOME resolution -------------------------------------------------

PLANS_HOME_RESOLVED="${PLANS_HOME:-$HOME/.claude-plans}"
log_info "PLANS_HOME resolved: $PLANS_HOME_RESOLVED"

# ---- substitution defaults --------------------------------------------------
#
# Reference-leak floor: empty manifest fields fall back to generic placeholders
# (not Peter-specific). Ensures vault CLAUDE.md is portable across users.

[ -z "$IDENT_NAME" ]              && IDENT_NAME="_not provided — set via /onboard --section a_"
[ -z "$IDENT_ROLE" ]              && IDENT_ROLE="_not provided_"
[ -z "$IDENT_ORG" ]               && IDENT_ORG="_not provided_"
[ -z "$IDENT_INDUSTRY" ]          && IDENT_INDUSTRY="_not provided_"
[ -z "$VAULT_ORG_METHOD" ]        && VAULT_ORG_METHOD="flat"
[ -z "$VAULT_TOP_FOLDER" ]        && VAULT_TOP_FOLDER="Engagements"
[ -z "$VAULT_DEFAULT_AUDIENCE" ]  && VAULT_DEFAULT_AUDIENCE="self"

# ---- dry-run summary --------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  cat <<EOF
adopt: dry-run summary
  vault_root:        $VAULT_ROOT
  plans_home:        $PLANS_HOME_RESOLVED
  identity.name:     $IDENT_NAME
  identity.role:     $IDENT_ROLE
  identity.org:      $IDENT_ORG
  vault.org_method:  $VAULT_ORG_METHOD
  vault.top_folder:  $VAULT_TOP_FOLDER
  would_create:
    - $VAULT_ROOT/Inbox/
    - $VAULT_ROOT/Logs/
    - $VAULT_ROOT/Logs/backlog-progress/
    - $VAULT_ROOT/.coordination/
    - $VAULT_ROOT/Plans -> $PLANS_HOME_RESOLVED
  would_seed:
    - $VAULT_ROOT/CLAUDE.md (from templates/vault-claude-md-template.md)
    - $VAULT_ROOT/System Backlog.md (empty)
    - $VAULT_ROOT/.coordination/canonical-file-types.json (skeleton)
  would_update:
    - $USER_MANIFEST: vault.canonical_file_types (skeleton if null)
EOF
  exit 0
fi

# ---- locate template --------------------------------------------------------

# Search order:
#   1. $CLAUDE_HOME/templates/vault-claude-md-template.md (runtime path post-install)
#   2. Sibling-of-script: $SCRIPT_DIR/../../templates/...  (foundation-repo source)
#
# Test harness invokes via foundation-repo path; production via runtime path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEMPLATE=""
for candidate in \
  "$CLAUDE_HOME/templates/vault-claude-md-template.md" \
  "$SCRIPT_DIR/../../templates/vault-claude-md-template.md"
do
  if [ -f "$candidate" ]; then
    TEMPLATE="$candidate"
    break
  fi
done

if [ -z "$TEMPLATE" ]; then
  log_err "vault-claude-md-template.md not found. Searched:"
  log_err "  $CLAUDE_HOME/templates/"
  log_err "  $SCRIPT_DIR/../../templates/"
  exit 40
fi

log_info "template located: $TEMPLATE"

# ---- atomic write helper ----------------------------------------------------

atomic_write() {
  # $1: target path, stdin: payload
  local target="$1"
  local tmp
  tmp="$target.adopt.tmp.$$"
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

# ---- scaffold directories (idempotent) --------------------------------------

mkdir -p "$VAULT_ROOT" || { log_err "mkdir vault root failed: $VAULT_ROOT"; exit 40; }
mkdir -p "$VAULT_ROOT/Inbox" || { log_err "mkdir Inbox failed"; exit 40; }
mkdir -p "$VAULT_ROOT/Logs" || { log_err "mkdir Logs failed"; exit 40; }
mkdir -p "$VAULT_ROOT/Logs/backlog-progress" || { log_err "mkdir Logs/backlog-progress failed"; exit 40; }
mkdir -p "$VAULT_ROOT/.coordination" || { log_err "mkdir .coordination failed"; exit 40; }

# Plans symlink: idempotent via ln -sfn (symbolic, force, no-deref).
# If $PLANS_HOME_RESOLVED does not exist, create it (otherwise dangling symlink).
mkdir -p "$PLANS_HOME_RESOLVED" || { log_err "mkdir PLANS_HOME failed: $PLANS_HOME_RESOLVED"; exit 40; }
ln -sfn "$PLANS_HOME_RESOLVED" "$VAULT_ROOT/Plans" || { log_err "ln -sfn Plans failed"; exit 40; }

log_info "scaffolded 5 directories + Plans symlink"

# ---- seed CLAUDE.md with identity substitution ------------------------------
#
# Idempotent strategy: if CLAUDE.md exists, do NOT overwrite (preserve user
# edits). If it doesn't exist, render from template with substitution.

CLAUDE_MD="$VAULT_ROOT/CLAUDE.md"
if [ ! -f "$CLAUDE_MD" ]; then
  # Render template -> substitute -> atomic write.
  rendered=""
  if ! rendered=$(cat "$TEMPLATE"); then
    log_err "failed to read template: $TEMPLATE"
    exit 40
  fi

  # Substitution. sed with delimiter | to avoid collision with substituted /
  # path content. Identity values may contain special regex chars; escape via
  # printf %s | sed for sed-safe escaping. For MVP, restrict identity strings
  # to printable ASCII and rely on simple sed substitution.
  sed_escape() {
    printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'
  }

  rendered=$(printf '%s' "$rendered" \
    | sed "s|{{IDENTITY_NAME}}|$(sed_escape "$IDENT_NAME")|g" \
    | sed "s|{{IDENTITY_ROLE}}|$(sed_escape "$IDENT_ROLE")|g" \
    | sed "s|{{IDENTITY_ORGANIZATION}}|$(sed_escape "$IDENT_ORG")|g" \
    | sed "s|{{IDENTITY_INDUSTRY}}|$(sed_escape "$IDENT_INDUSTRY")|g" \
    | sed "s|{{VAULT_ORGANIZATIONAL_METHOD}}|$(sed_escape "$VAULT_ORG_METHOD")|g" \
    | sed "s|{{VAULT_TOP_LEVEL_FOLDER}}|$(sed_escape "$VAULT_TOP_FOLDER")|g" \
    | sed "s|{{VAULT_DEFAULT_AUDIENCE}}|$(sed_escape "$VAULT_DEFAULT_AUDIENCE")|g")

  if ! printf '%s\n' "$rendered" | atomic_write "$CLAUDE_MD"; then
    log_err "atomic write failed: $CLAUDE_MD"
    exit 40
  fi

  # Post-write: verify no placeholder tokens remain. AC #4 enforcement.
  if grep -E '\{\{[A-Z_]+\}\}' "$CLAUDE_MD" >/dev/null 2>&1; then
    log_err "post-write validation: placeholder tokens remain in $CLAUDE_MD"
    log_err "$(grep -nE '\{\{[A-Z_]+\}\}' "$CLAUDE_MD" | head -5)"
    exit 50
  fi

  log_info "seeded $CLAUDE_MD"
else
  log_info "CLAUDE.md exists; preserving (idempotent)"
  # Even on existing file, AC #4 says "no placeholder tokens remain" — verify.
  if grep -E '\{\{[A-Z_]+\}\}' "$CLAUDE_MD" >/dev/null 2>&1; then
    log_err "existing $CLAUDE_MD contains placeholder tokens — prior /adopt run failed"
    log_err "Delete CLAUDE.md and re-run /adopt to re-seed."
    exit 50
  fi
fi

# ---- seed empty System Backlog.md (idempotent) ------------------------------

BACKLOG="$VAULT_ROOT/System Backlog.md"
if [ ! -f "$BACKLOG" ]; then
  cat > "$BACKLOG.adopt.tmp.$$" <<'EOF'
---
type: index
updated: ADOPT_TS_PLACEHOLDER
---

# System Backlog

System-project ideas. Triaged by `/backlog-triage`, researched by
`/backlog-research`, executed via `/new-plan`. The librarian and architect
work this surface over time.

## Active

(empty)

## Archived

(empty)
EOF
  # Substitute timestamp.
  sed -i.bak "s/ADOPT_TS_PLACEHOLDER/$(date -u '+%Y-%m-%dT%H:%M:%SZ')/" "$BACKLOG.adopt.tmp.$$" \
    && rm -f "$BACKLOG.adopt.tmp.$$.bak"
  mv "$BACKLOG.adopt.tmp.$$" "$BACKLOG" || { log_err "mv System Backlog.md failed"; exit 40; }
  log_info "seeded $BACKLOG"
else
  log_info "System Backlog.md exists; preserving (idempotent)"
fi

# ---- write canonical-file-types.json skeleton -------------------------------

CFT_FILE="$VAULT_ROOT/.coordination/canonical-file-types.json"
if [ ! -f "$CFT_FILE" ]; then
  CFT_PAYLOAD=$(printf '{\n  "schema_version": "skeleton-1.0.0",\n  "phase": "MVP",\n  "note": "Phase 2 in v2.1 will populate this from archetype heuristic. See SP08 spec §/adopt fresh-vault flow.",\n  "file_types": []\n}\n')
  if ! printf '%s' "$CFT_PAYLOAD" | atomic_write "$CFT_FILE"; then
    log_err "atomic write failed: $CFT_FILE"
    exit 40
  fi
  log_info "wrote $CFT_FILE"
else
  log_info "canonical-file-types.json exists; preserving (idempotent)"
fi

# ---- update user-manifest.json: vault.canonical_file_types skeleton ---------
#
# If null, set to []. If already populated by SP07 archetype heuristic, leave
# alone. Atomic via tmp+rename through jq.

NEEDS_CFT_INIT=$(jq -r '.vault.canonical_file_types // "null"' "$USER_MANIFEST" 2>/dev/null)
if [ "$NEEDS_CFT_INIT" = "null" ] || [ -z "$NEEDS_CFT_INIT" ]; then
  TMP_MANIFEST="$USER_MANIFEST.adopt.tmp.$$"
  if jq '.vault.canonical_file_types = (.vault.canonical_file_types // [])' "$USER_MANIFEST" > "$TMP_MANIFEST"; then
    mv "$TMP_MANIFEST" "$USER_MANIFEST" || { rm -f "$TMP_MANIFEST"; log_err "mv user-manifest update failed"; exit 40; }
    log_info "user-manifest.json: vault.canonical_file_types initialized to []"
  else
    rm -f "$TMP_MANIFEST"
    log_err "jq update of user-manifest.json failed"
    exit 40
  fi
else
  log_info "user-manifest.json: vault.canonical_file_types already populated; preserving"
fi

# ---- success summary --------------------------------------------------------

cat <<EOF
adopt: vault scaffolded at $VAULT_ROOT
  directories:  Inbox/ Logs/ Logs/backlog-progress/ .coordination/ Plans -> $PLANS_HOME_RESOLVED
  seeded:       CLAUDE.md, System Backlog.md, .coordination/canonical-file-types.json
  identity:     $IDENT_NAME ($IDENT_ROLE @ $IDENT_ORG)

Next steps:
  - Open $VAULT_ROOT/CLAUDE.md and review vault conventions
  - Capture system-project ideas in System Backlog.md
  - Create your first engagement: $VAULT_ROOT/$VAULT_TOP_FOLDER/<engagement-name>/
EOF

exit 0
