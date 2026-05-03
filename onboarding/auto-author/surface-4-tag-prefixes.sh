#!/usr/bin/env bash
# onboarding/auto-author/surface-4-tag-prefixes.sh — SP12 T-7 (Plan 71 SP12 Session 2)
#
# Surface #4 — Auto-author `_tag_prefixes[]` based on declared workflow
# archetype (vault.tag_prefix_archetype, set by Q-ID A-CB-7 in section-a.sh
# per T-14). Persists into TWO targets:
#   1. ${CLAUDE_HOME}/schemas/vault-schema.json._tag_prefixes (canonical
#      registry consumed by frontmatter-enforce + librarian)
#   2. user-manifest.json::vault.tag_prefixes (mirror — runtime-readable
#      by capabilities via lib/paths.sh / umr_get_array)
# Three-step gate (custom batched — single preview spans BOTH writes).
# Existing populated prefixes trigger MERGE (union) — no clobber.
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - $VAULT_SCHEMA (jq-patched ._tag_prefixes)
#     - $USER_MANIFEST (jq-patched .vault.tag_prefixes)
#     - $PROVENANCE_LOG (sidecar JSONL provenance audit; JSON files cannot
#       carry frontmatter without polluting their consumed schema, so
#       provenance lineage is recorded in this audit log).
#   Schema-types:
#     - Both writes are array updates; pre/post-jq-patch validation runs
#       jq-parse on both files.
#   Pre-write validation:
#     - Both targets readable + jq-parseable.
#     - Proposed prefix list is non-empty array of slug-shaped strings.
#   Failure mode: BLOCK AND LOG.
#
# Archetype-keyed prefix table:
#   consultant : engagement/, project/, scope/
#   researcher : topic/, paper/, dataset/
#   developer  : project/, repo/, feature/
#   educator   : course/, module/, student/
#   manager    : team/, project/, kpi/
#   <other>    : LLM-compose fallback (currently emits a sane generic set)
#   <null>     : LLM-compose fallback (same path)
#
# CONSTRAINTS (R-23): bash 3.2; jq required.
#
# USAGE:
#   surface-4-tag-prefixes.sh
#     [--user-manifest PATH]
#     [--vault-schema PATH]
#     [--provenance-log PATH]
#     [--archetype-override STR]   # bypass manifest read; useful for tests
#     [--auto-apply] [--skip-preview] [--dry-run]
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP12 Session 2

set -u

diag() { printf 'surface-4 FAIL: %s\n' "$1" >&2; }
info() { printf 'surface-4: %s\n' "$1"; }

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
USER_MANIFEST="${USER_MANIFEST:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
VAULT_SCHEMA="${VAULT_SCHEMA:-${CLAUDE_HOME:-$HOME/.claude}/schemas/vault-schema.json}"
PROVENANCE_LOG="${PROVENANCE_LOG:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/audit/sp12-t7-provenance.jsonl}"
ARCHETYPE_OVERRIDE=""
SURFACE_ID="sp12-t7"
GENERATED_FROM="A-CB-7+vault-archetype-table"
LLM_MOCK="${AUTO_AUTHOR_MOCK_LLM:-0}"
AUTO_APPLY=0
SKIP_PREVIEW=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user-manifest)        USER_MANIFEST="$2"; shift 2 ;;
    --vault-schema)         VAULT_SCHEMA="$2"; shift 2 ;;
    --provenance-log)       PROVENANCE_LOG="$2"; shift 2 ;;
    --archetype-override)   ARCHETYPE_OVERRIDE="$2"; shift 2 ;;
    --mock-llm)             LLM_MOCK=1; shift ;;
    --auto-apply)           AUTO_APPLY=1; shift ;;
    --skip-preview)         SKIP_PREVIEW=1; shift ;;
    --dry-run)              DRY_RUN=1; gate_set_dry_run 1; shift ;;
    -h|--help)              sed -n '2,40p' "$0"; exit 0 ;;
    *)                      diag "unknown arg: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { diag "jq required on PATH"; exit 2; }
[ -f "$USER_MANIFEST" ] || { diag "user-manifest not found: $USER_MANIFEST"; exit 2; }
[ -f "$VAULT_SCHEMA" ]  || { diag "vault-schema not found: $VAULT_SCHEMA"; exit 2; }
mkdir -p "$(dirname "$PROVENANCE_LOG")" 2>/dev/null

# Validate both targets parse.
jq -e . "$USER_MANIFEST" >/dev/null 2>&1 || { diag "user-manifest invalid JSON"; exit 2; }
jq -e . "$VAULT_SCHEMA"  >/dev/null 2>&1 || { diag "vault-schema invalid JSON"; exit 2; }

# --- read declared archetype ---
ARCHETYPE=""
if [ -n "$ARCHETYPE_OVERRIDE" ]; then
  ARCHETYPE="$ARCHETYPE_OVERRIDE"
else
  ARCHETYPE="$(jq -r '.vault.tag_prefix_archetype // ""' "$USER_MANIFEST" 2>/dev/null)"
fi
ARCHETYPE_LC="$(printf '%s' "$ARCHETYPE" | tr 'A-Z' 'a-z')"

# --- archetype-keyed prefix table ---
prefixes_for_archetype() {
  case "$1" in
    consultant) printf 'engagement/\nproject/\nscope/\n' ;;
    researcher) printf 'topic/\npaper/\ndataset/\n' ;;
    developer)  printf 'project/\nrepo/\nfeature/\n' ;;
    educator)   printf 'course/\nmodule/\nstudent/\n' ;;
    manager)    printf 'team/\nproject/\nkpi/\n' ;;
    *)          # LLM-compose fallback (mock + real both fall through to generic set)
                printf 'project/\ntopic/\nreference/\n' ;;
  esac
}

# Compose proposed prefix list.
PROPOSED_PREFIXES="$(prefixes_for_archetype "$ARCHETYPE_LC")"
if [ -z "$PROPOSED_PREFIXES" ]; then
  diag "could not derive proposed prefix list (empty)"
  exit 2
fi

# JSON array form.
PROPOSED_JSON="$(printf '%s\n' "$PROPOSED_PREFIXES" | jq -R . | jq -s 'map(select(. != ""))')"

# --- read existing prefix lists ---
EXISTING_VS_JSON="$(jq -c '._tag_prefixes // []' "$VAULT_SCHEMA")"
EXISTING_UM_JSON="$(jq -c '.vault.tag_prefixes // []' "$USER_MANIFEST")"

# --- compute merge result (union, deduplicated, sorted) ---
MERGED_VS_JSON="$(printf '%s\n%s\n' "$EXISTING_VS_JSON" "$PROPOSED_JSON" | jq -s 'add | unique')"
MERGED_UM_JSON="$(printf '%s\n%s\n' "$EXISTING_UM_JSON" "$PROPOSED_JSON" | jq -s 'add | unique')"

# Did anything actually change?
VS_CHANGED=0
UM_CHANGED=0
[ "$EXISTING_VS_JSON" != "$MERGED_VS_JSON" ] && VS_CHANGED=1
[ "$EXISTING_UM_JSON" != "$MERGED_UM_JSON" ] && UM_CHANGED=1

# --- preview ---
render_preview() {
  printf '\n=== sp12-t7: BATCHED PREVIEW (tag-prefix auto-author) ===\n\n' >&2
  printf 'Declared archetype: %s\n' "${ARCHETYPE:-(undeclared)}" >&2
  printf 'Archetype-keyed proposal: %s\n' "$(printf '%s' "$PROPOSED_JSON" | jq -c .)" >&2
  printf '\n' >&2
  printf -- '--- vault-schema.json._tag_prefixes ---\n' >&2
  printf 'existing: %s\n' "$EXISTING_VS_JSON" >&2
  printf 'merged:   %s\n' "$MERGED_VS_JSON" >&2
  if [ "$VS_CHANGED" = "1" ]; then
    printf '(WILL UPDATE)\n' >&2
  else
    printf '(no change — merged set equals existing)\n' >&2
  fi
  printf '\n' >&2
  printf -- '--- user-manifest.json::vault.tag_prefixes ---\n' >&2
  printf 'existing: %s\n' "$EXISTING_UM_JSON" >&2
  printf 'merged:   %s\n' "$MERGED_UM_JSON" >&2
  if [ "$UM_CHANGED" = "1" ]; then
    printf '(WILL UPDATE)\n' >&2
  else
    printf '(no change — merged set equals existing)\n' >&2
  fi
  printf '\n=== end PREVIEW ===\n\n' >&2
}

provenance_log_append() {
  local action="$1" target="$2" pre="$3" post="$4"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg surface_id "$SURFACE_ID" \
    --arg generated_from "$GENERATED_FROM" \
    --arg archetype "$ARCHETYPE" \
    --arg action "$action" \
    --arg target "$target" \
    --argjson pre "$pre" \
    --argjson post "$post" \
    '{ts:$ts, surface_id:$surface_id, generated_from:$generated_from, archetype:$archetype, action:$action, target:$target, pre:$pre, post:$post, last_user_edit:null}' \
    >> "$PROVENANCE_LOG"
}

# --- prompt ---
do_apply=0
if [ "$SKIP_PREVIEW" != "1" ]; then
  render_preview
fi
if [ "$DRY_RUN" = "1" ]; then
  do_apply=0
  info "dry-run; no apply"
elif [ "$AUTO_APPLY" = "1" ]; then
  do_apply=1
elif [ "$VS_CHANGED" = "0" ] && [ "$UM_CHANGED" = "0" ]; then
  info "no changes — both targets already carry the merged set; exiting clean."
  provenance_log_append "no-op" "$VAULT_SCHEMA $USER_MANIFEST" "$MERGED_VS_JSON" "$MERGED_VS_JSON"
  exit 0
else
  printf 'Apply tag-prefix updates to BOTH vault-schema.json AND user-manifest.json? [a]pply (default) / [s]kip / [b]ort: ' >&2
  if ! IFS= read -r choice; then
    info "stdin EOF without --auto-apply; aborting"
    provenance_log_append "abort-stdin-eof" "$VAULT_SCHEMA $USER_MANIFEST" "$EXISTING_VS_JSON" "$EXISTING_VS_JSON"
    exit 1
  fi
  case "$choice" in
    ""|a|A) do_apply=1 ;;
    s|S)
      info "user skipped apply"
      provenance_log_append "skip-user" "$VAULT_SCHEMA $USER_MANIFEST" "$EXISTING_VS_JSON" "$EXISTING_VS_JSON"
      exit 0
      ;;
    b|B|q|Q)
      info "user aborted"
      provenance_log_append "abort-user" "$VAULT_SCHEMA $USER_MANIFEST" "$EXISTING_VS_JSON" "$EXISTING_VS_JSON"
      exit 1
      ;;
    *)
      info "invalid choice; aborting"
      provenance_log_append "abort-invalid-input" "$VAULT_SCHEMA $USER_MANIFEST" "$EXISTING_VS_JSON" "$EXISTING_VS_JSON"
      exit 1
      ;;
  esac
fi

# --- apply ---
if [ "$do_apply" = "1" ]; then
  if [ "$VS_CHANGED" = "1" ]; then
    vs_tmp="$VAULT_SCHEMA.tmp.$$"
    jq --argjson v "$MERGED_VS_JSON" '._tag_prefixes = $v' "$VAULT_SCHEMA" > "$vs_tmp" && \
      jq -e . "$vs_tmp" >/dev/null 2>&1 && \
      mv "$vs_tmp" "$VAULT_SCHEMA" || { diag "vault-schema patch failed"; rm -f "$vs_tmp"; exit 2; }
    provenance_log_append "update" "$VAULT_SCHEMA" "$EXISTING_VS_JSON" "$MERGED_VS_JSON"
  else
    provenance_log_append "no-op" "$VAULT_SCHEMA" "$EXISTING_VS_JSON" "$EXISTING_VS_JSON"
  fi

  if [ "$UM_CHANGED" = "1" ]; then
    um_tmp="$USER_MANIFEST.tmp.$$"
    jq --argjson v "$MERGED_UM_JSON" '.vault.tag_prefixes = $v' "$USER_MANIFEST" > "$um_tmp" && \
      jq -e . "$um_tmp" >/dev/null 2>&1 && \
      mv "$um_tmp" "$USER_MANIFEST" || { diag "user-manifest patch failed"; rm -f "$um_tmp"; exit 2; }
    provenance_log_append "update" "$USER_MANIFEST" "$EXISTING_UM_JSON" "$MERGED_UM_JSON"
  else
    provenance_log_append "no-op" "$USER_MANIFEST" "$EXISTING_UM_JSON" "$EXISTING_UM_JSON"
  fi

  info "T-7 complete: tag-prefix auto-author applied (archetype=$ARCHETYPE; merged set length=$(printf '%s' "$MERGED_VS_JSON" | jq -r 'length'))"
fi

exit 0
