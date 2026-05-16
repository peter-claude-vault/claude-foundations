#!/usr/bin/env bash
# onboarding/auto-author/surface-5-doc-dependencies.sh — SP12 T-8 (Plan 71 SP12 Session 3)
#
# Surface #5 — Auto-author hooks/config/doc-dependencies.json with 3-5 cascade
# entries derived from declared structure flags. Replaces the empty
# {"version":2,"entries":[]} skeleton with a populated cascade registry that
# pre-write-guard.sh R-54 reads to surface mirror-review prompts on dependent
# writes.
#
# Source flags (user-manifest.json):
#   .vault.has_structured_projects (bool)        → engagement-list cascade
#   .vault.top_level_folder (str)                → engagement primary_dir
#   .vault.organizational_method (str)           → people-list cascade gating
#                                                  (engagement-based vaults
#                                                  customarily ship People/)
#
# Always-on entries (regardless of declared structure):
#   - system-backlog cascade  (System Backlog.md ↔ Logs/backlog-progress/)
#   - vault-claude-md cascade (vault CLAUDE.md ↔ vault-schema canonical types)
#   - plan-state cascade      (Plans/ symlink ↔ $PLANS_HOME _index.md)
#
# Three-step gate (single-target via gate_generate + gate_apply). Provenance
# lives at file-level under a top-level `_provenance` field — pre-write-guard
# reads `.entries[]` only, so the additional sibling key is non-breaking.
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - $DOC_DEP_FILE (full overwrite via three-step gate apply)
#   Schema-types:
#     - JSON; pre/post jq-parse validation; .entries[] is array of entry
#       objects with required {id, kind, primary|primary_dir, mirrors}.
#   Pre-write validation:
#     - user-manifest.json readable + parseable
#     - proposed registry validates: .entries length 3..5; each entry has
#       non-empty id + kind + (primary|primary_dir) + mirrors array
#     - bash -n on this script; jq -e . on output
#   Failure mode: BLOCK AND LOG (proposed registry rejected → exit 2; gate
#                 abort → exit 1; no partial write).
#
# CONSTRAINTS (R-23): bash 3.2; jq required.
#
# USAGE:
#   surface-5-doc-dependencies.sh
#     [--user-manifest PATH]
#     [--doc-dep-file PATH]
#     [--auto-apply] [--skip-preview] [--dry-run]
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP12 Session 3

set -u

diag() { printf 'surface-5 FAIL: %s\n' "$1" >&2; }
info() { printf 'surface-5: %s\n' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONBOARDING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GATE_LIB="$ONBOARDING_DIR/lib/three-step-gate.sh"
[ -r "$GATE_LIB" ] || { diag "three-step-gate.sh not readable"; exit 2; }
# shellcheck source=/dev/null
. "$GATE_LIB"

# --- defaults + arg parsing ---
USER_MANIFEST="${USER_MANIFEST:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
DOC_DEP_FILE="${DOC_DEP_FILE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/config/doc-dependencies.json}"
SURFACE_ID="surface-5-doc-dependencies"
GENERATED_FROM="vault-structure-flags+template-table"
AUTO_APPLY=0
SKIP_PREVIEW=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user-manifest) USER_MANIFEST="$2"; shift 2 ;;
    --doc-dep-file)  DOC_DEP_FILE="$2"; shift 2 ;;
    --auto-apply)    AUTO_APPLY=1; shift ;;
    --skip-preview)  SKIP_PREVIEW=1; shift ;;
    --dry-run)       DRY_RUN=1; gate_set_dry_run 1; shift ;;
    -h|--help)       sed -n '2,46p' "$0"; exit 0 ;;
    *)               diag "unknown arg: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { diag "jq required on PATH"; exit 2; }
[ -f "$USER_MANIFEST" ] || { diag "user-manifest not found: $USER_MANIFEST"; exit 2; }
mkdir -p "$(dirname "$DOC_DEP_FILE")" 2>/dev/null

jq -e . "$USER_MANIFEST" >/dev/null 2>&1 || { diag "user-manifest invalid JSON"; exit 2; }

# --- read declared structure flags ---
HAS_PROJECTS="$(jq -r '.vault.has_structured_projects // false' "$USER_MANIFEST" 2>/dev/null)"
TOP_LEVEL="$(jq -r '.vault.top_level_folder // "Engagements"' "$USER_MANIFEST" 2>/dev/null)"
ORG_METHOD="$(jq -r '.vault.organizational_method // ""' "$USER_MANIFEST" 2>/dev/null)"
ORG_METHOD_LC="$(printf '%s' "$ORG_METHOD" | tr 'A-Z' 'a-z')"

NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- entry builders ---

build_system_backlog_entry() {
  jq -nc '{
    id: "system-backlog",
    kind: "satellite-cascade",
    primary: "System Backlog.md",
    mirrors: [
      {file: "Logs/backlog-progress/", section: "(per-row satellite)"}
    ],
    rationale: "Backlog rows carry only the current-state pointer; satellites under Logs/backlog-progress/ are the single source of session history."
  }'
}

build_vault_claude_md_entry() {
  jq -nc '{
    id: "vault-claude-md-canonical-types",
    kind: "schema-mirror",
    primary: "CLAUDE.md",
    mirrors: [
      {file: "$CLAUDE_HOME/schemas/vault-schema.json", section: ".types[]"}
    ],
    rationale: "Vault CLAUDE.md describes the canonical-file-types contract that vault-schema.json enforces. Lockstep edits required."
  }'
}

build_plans_entry() {
  jq -nc '{
    id: "plan-state",
    kind: "external-mirror",
    primary_dir: "Plans/",
    mirrors: [
      {file: "$PLANS_HOME/_index.md", section: "(plan index)"}
    ],
    rationale: "Plans/ is a read-only navigation symlink into $PLANS_HOME. Plan-state lives outside the vault to escape Claude Code sensitive-file gates."
  }'
}

build_engagement_entry() {
  local top="$1"
  jq -nc --arg top "$top" --arg dir "${top}/" '{
    id: "engagement-list",
    kind: "directory-mirror",
    primary_dir: $dir,
    mirrors: [
      {file: "CLAUDE.md", section: "Directory layout"},
      {file: ($top + "/_index.md"), section: "Engagements"}
    ],
    rationale: "Each engagement directory is enumerated in vault CLAUDE.md and (when present) the top-level _index.md routing surface."
  }'
}

build_people_entry() {
  local top="$1"
  jq -nc --arg top "$top" --arg dir "${top}/" '{
    id: "people-list",
    kind: "directory-mirror",
    primary_dir: ($dir + "*/People/"),
    mirrors: [
      {file: ($top + "/_index.md"), section: "People"}
    ],
    rationale: "People files under each cluster are surfaced in the cluster-level _index.md routing layer."
  }'
}

# --- generator (called by gate_generate) ---
gen_doc_dependencies() {
  local entries_jsonl=""
  entries_jsonl+="$(build_system_backlog_entry)"$'\n'
  entries_jsonl+="$(build_vault_claude_md_entry)"$'\n'
  entries_jsonl+="$(build_plans_entry)"$'\n'
  if [ "$HAS_PROJECTS" = "true" ]; then
    entries_jsonl+="$(build_engagement_entry "$TOP_LEVEL")"$'\n'
    case "$ORG_METHOD_LC" in
      *engagement*) entries_jsonl+="$(build_people_entry "$TOP_LEVEL")"$'\n' ;;
    esac
  fi
  local entries_json
  entries_json="$(printf '%s' "$entries_jsonl" | jq -s '[.[] | select(. != null)]')"
  jq -n \
    --argjson entries "$entries_json" \
    --arg surface_id "$SURFACE_ID" \
    --arg generated_from "$GENERATED_FROM" \
    --arg ts "$NOW_TS" \
    '{
      version: 2,
      _provenance: {
        generated_by: $surface_id,
        generated_from: $generated_from,
        generated_at: $ts,
        last_user_edit: null
      },
      entries: $entries
    }'
}

# --- main ---
if [ -z "${TG_STAGE_DIR:-}" ]; then
  TG_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/surface-5.XXXXXX")"
  export TG_STAGE_DIR
fi

stage="$(gate_generate "$SURFACE_ID" gen_doc_dependencies)" || { diag "gate_generate failed"; exit 2; }

# --- post-generation validation ---
if ! jq -e . "$stage" >/dev/null 2>&1; then
  diag "staged JSON failed parse"
  exit 2
fi
SLEN="$(jq -r '.entries | length' "$stage")"
if [ "$SLEN" -lt 3 ] || [ "$SLEN" -gt 5 ]; then
  diag "staged entries length out of range (got $SLEN; expected 3..5)"
  exit 2
fi
INVALID="$(jq '[.entries[] | select(
  (.id // "" | length) == 0 or
  (.kind // "" | length) == 0 or
  (((.primary // "") | length) == 0 and ((.primary_dir // "") | length) == 0) or
  ((.mirrors // []) | length) == 0
)] | length' "$stage")"
if [ "$INVALID" != "0" ]; then
  diag "$INVALID staged entries failed required-field check"
  exit 2
fi

apply_args=""
[ "$SKIP_PREVIEW" = "1" ] && apply_args="$apply_args --skip-preview"
[ "$AUTO_APPLY"   = "1" ] && apply_args="$apply_args --accept-on-empty-stdin"

# shellcheck disable=SC2086
gate_apply "$stage" "$DOC_DEP_FILE" $apply_args
rc=$?
case "$rc" in
  0) info "surface-5 complete (entries=$SLEN; target=$DOC_DEP_FILE)" ;;
  1) info "surface-5 aborted at gate prompt" ;;
  *) diag "gate_apply returned rc=$rc" ;;
esac
exit "$rc"
