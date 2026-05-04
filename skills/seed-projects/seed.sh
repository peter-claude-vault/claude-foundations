#!/usr/bin/env bash
# seed.sh — SP13 T-8 Stage 3 GENERATE-WITH-GATE: scaffold PRD/Context/Updates
# triads from a user-approved import plan.
#
# Consumes T-7 output (state/approved-import-plan.md; sp13-t6/1). For each
# project candidate, stages a folder + PRD.md + Context.md + Updates.md
# under a staging dir; renders a SINGLE batched preview of all 15 staged
# files diffed against any pre-existing target files; surfaces ONE user
# prompt [a/e/s/b]; on apply, atomically copies each staged file to its
# vault destination. Atomic-on-approve: all 15 files write or none.
#
# Each generated file carries SP12 provenance frontmatter via
# lib/provenance-frontmatter.sh::pf_emit (15 emissions per 5-project plan).
#
# Audit-log shape: REUSES SP12's auto-author-log.jsonl stream. Records
# carry surface_id="seed-projects" + action enum (generate / preview /
# apply / skip / abort / error). Same shape as T-7's audit records — the
# audit log is one chronological view of every auto-authoring event.
#
# The wrapper sources lib/three-step-gate.sh for `gate_audit_path` (public
# audit-log resolver). For batched-record emission we bypass `gate_apply`
# (would force per-file prompts) and write JSONL records directly using
# the same shape the gate library uses.
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - $VAULT_ROOT/<proposed_path>/{PRD,Context,Updates}.md per project
#       candidate (only on `apply` choice)
#     - audit log entries appended to SP12's auto-author-log.jsonl stream
#       (or $AUTO_AUTHOR_LOG override)
#   Schema-types:
#     - Input: T-7 approved-import-plan.md (`schema_version: sp13-t6/1`)
#       — validated by seed.py before staging
#     - Per-file output: SP12 provenance frontmatter (validated against
#       schemas/provenance-frontmatter-schema.json via pf_validate)
#   Pre-write validation:
#     - SP12 T-2 done-marker present (dev-mode only — production adopters
#       have no plan tree, check is no-op)
#     - approved-import-plan.md exists + carries sp13-t6/1
#     - Templates exist (prd / context / updates)
#     - lib/provenance-frontmatter.sh exists + sourceable
#     - lib/three-step-gate.sh exists + sourceable
#     - Vault root exists (caller's responsibility — seed.sh refuses to
#       mkdir an entire missing vault tree)
#   Failure mode: BLOCK AND LOG.
#     - Missing pre-flight → exit 2 (clean halt with stderr)
#     - Staging step (seed.py) failure → exit 2; no audit "apply"
#     - User abort → exit 1 (audit "abort"; no files copied)
#     - User skip → exit 0 (audit "skip"; no files copied)
#     - Apply-time copy failure → exit 3 (audit "error"; partial state
#       possible; caller should re-run after fix)
#
# CONSTRAINTS (R-23): bash 3.2 — no `declare -A`, no `mapfile`,
# no `${var,,}`. `jq`, `python3`, `shasum`/`sha256sum` REQUIRED.
#
# Author: Claude Opus 4.7 — Plan 71 SP13 Session 6

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
DEFAULT_APPROVED_PLAN="$REPO_ROOT/onboarding/seed-content/state/approved-import-plan.md"
DEFAULT_TEMPLATES_DIR="$REPO_ROOT/templates"
DEFAULT_PF_LIB="$REPO_ROOT/lib/provenance-frontmatter.sh"
DEFAULT_GATE_LIB="$REPO_ROOT/onboarding/lib/three-step-gate.sh"
DEFAULT_PLAN_TREE="$HOME/.claude-plans/71-claude-foundations-engine-v2"

APPROVED_PLAN="$DEFAULT_APPROVED_PLAN"
VAULT_ROOT=""
TEMPLATES_DIR="$DEFAULT_TEMPLATES_DIR"
PF_LIB="$DEFAULT_PF_LIB"
GATE_LIB="$DEFAULT_GATE_LIB"
PLAN_TREE="$DEFAULT_PLAN_TREE"
ACCEPT_ON_EOF="${SEED_PROJECTS_ACCEPT_ON_EOF:-0}"
PROMPT_CHOICE="${SEED_PROJECTS_PROMPT_CHOICE:-}"
GENERATED_AT="${SEED_PROJECTS_GENERATED_AT:-}"
AUDIENCE="self"

usage() {
  cat <<EOF
seed.sh — SP13 T-8 Stage 3 PRD/Context/Updates scaffolder.

Usage:
  seed.sh --vault-root PATH [--approved-plan PATH] [--templates-dir PATH]
          [--pf-lib PATH] [--gate-lib PATH] [--plan-tree PATH]
          [--audience SELF|TEAM|...] [--accept-on-eof]

Required:
  --vault-root PATH        Vault root; project folders land under here.

Defaults:
  --approved-plan          $DEFAULT_APPROVED_PLAN
  --templates-dir          $DEFAULT_TEMPLATES_DIR
  --pf-lib                 $DEFAULT_PF_LIB
  --gate-lib               $DEFAULT_GATE_LIB
  --plan-tree              $DEFAULT_PLAN_TREE
                           (used only to detect dev-mode SP12 T-2 done-marker;
                            absent → check is a no-op for production adopters)
  --audience               self

Env hooks (test-only):
  SEED_PROJECTS_ACCEPT_ON_EOF=1   treat EOF on stdin as 'apply' (smoke tests)
  SEED_PROJECTS_PROMPT_CHOICE=X   pre-canned single choice (smoke tests)
  SEED_PROJECTS_GENERATED_AT=ISO  reproducible-test timestamp override
  AUTO_AUTHOR_LOG=PATH            override audit-log path (default: SP12)
  TG_STAGE_DIR=PATH               override staging dir (default: mktemp)

Exit codes:
  0   apply or skip (intentional, no error)
  1   user abort
  2   pre-flight failure (SP12 done-marker, missing input, schema mismatch)
  3   apply-time copy error (partial state; re-run safe after fix)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --vault-root) VAULT_ROOT="$2"; shift 2 ;;
    --approved-plan|--input) APPROVED_PLAN="$2"; shift 2 ;;
    --templates-dir) TEMPLATES_DIR="$2"; shift 2 ;;
    --pf-lib) PF_LIB="$2"; shift 2 ;;
    --gate-lib) GATE_LIB="$2"; shift 2 ;;
    --plan-tree) PLAN_TREE="$2"; shift 2 ;;
    --audience) AUDIENCE="$2"; shift 2 ;;
    --accept-on-eof) ACCEPT_ON_EOF=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'seed.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# ----- pre-flight: vault-root required -----

if [ -z "$VAULT_ROOT" ]; then
  printf 'seed.sh: --vault-root is required\n' >&2
  usage >&2
  exit 2
fi
if [ ! -d "$VAULT_ROOT" ]; then
  printf 'seed.sh: vault-root does not exist (caller must scaffold it first): %s\n' "$VAULT_ROOT" >&2
  exit 2
fi

# ----- pre-flight: SP12 T-2 done-marker (dev-mode only) -----

SP12_DONE_RELPATH="12-auto-authored-personalization/state/T-2.done"
SP12_DONE="$PLAN_TREE/$SP12_DONE_RELPATH"
if [ -d "$PLAN_TREE" ] && [ ! -f "$SP12_DONE" ]; then
  cat <<EOF >&2
seed.sh: HARD ABORT — SP12 T-2 done-marker not found.
  Expected at: $SP12_DONE
  Plan tree:   $PLAN_TREE

SP12 T-2 ships lib/provenance-frontmatter.sh (pf_emit) which T-8 consumes
to prepend conformant provenance frontmatter to every generated triad.
Cannot proceed until SP12 T-2 closes and the done-marker exists.

Production adopters with no plan tree skip this check automatically —
the absence of the plan tree directory is the signal that this is a
runtime adopter context, not a Plan 71 dev session.
EOF
  exit 2
fi

# ----- pre-flight: input plan exists + sp13-t6/1 anchor -----

if [ ! -f "$APPROVED_PLAN" ]; then
  printf 'seed.sh: approved plan not found: %s\n' "$APPROVED_PLAN" >&2
  printf '  Run T-7 review-gate.sh first to generate it.\n' >&2
  exit 2
fi
if ! grep -q '^schema_version: sp13-t6/1$' "$APPROVED_PLAN"; then
  cat <<EOF >&2
seed.sh: approved plan schema_version mismatch (expected 'sp13-t6/1').
  Path: $APPROVED_PLAN
This file does not appear to be a T-7 approved plan. Re-run review-gate.sh
to regenerate, or fix the schema_version anchor in the YAML frontmatter.
EOF
  exit 2
fi

# ----- pre-flight: templates -----

for tpl in "$TEMPLATES_DIR/prd-template.md" \
           "$TEMPLATES_DIR/context-template.md" \
           "$TEMPLATES_DIR/updates-template.md"; do
  if [ ! -f "$tpl" ]; then
    printf 'seed.sh: missing template: %s\n' "$tpl" >&2
    exit 2
  fi
done

# ----- pre-flight: pf_emit + gate library both sourceable -----

if [ ! -f "$PF_LIB" ]; then
  printf 'seed.sh: pf-lib not found: %s\n' "$PF_LIB" >&2
  exit 2
fi
if [ ! -f "$GATE_LIB" ]; then
  printf 'seed.sh: gate-lib not found: %s\n' "$GATE_LIB" >&2
  exit 2
fi
# shellcheck disable=SC1090
. "$GATE_LIB" || { printf 'seed.sh: failed to source gate lib\n' >&2; exit 2; }

# ----- staging -----

# Initialize TG_STAGE_DIR (gate library helper). Honors caller override.
if [ -z "${TG_STAGE_DIR:-}" ]; then
  TG_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/seed-projects-stage.XXXXXX")"
  export TG_STAGE_DIR
fi

# Run seed.py to stage all triads + emit manifest.
MANIFEST_JSON="$TG_STAGE_DIR/seed-projects-manifest.json"
SEED_PY="$SCRIPT_DIR/seed.py"
if [ ! -f "$SEED_PY" ]; then
  printf 'seed.sh: seed.py helper not found: %s\n' "$SEED_PY" >&2
  exit 2
fi

GEN_AT_ARG=""
if [ -n "$GENERATED_AT" ]; then
  GEN_AT_ARG="--generated-at $GENERATED_AT"
fi

if ! python3 "$SEED_PY" \
  --approved-plan "$APPROVED_PLAN" \
  --vault-root "$VAULT_ROOT" \
  --stage-dir "$TG_STAGE_DIR" \
  --templates-dir "$TEMPLATES_DIR" \
  --pf-lib "$PF_LIB" \
  --audience "$AUDIENCE" \
  $GEN_AT_ARG \
  > "$MANIFEST_JSON"; then
  printf 'seed.sh: seed.py staging failed\n' >&2
  exit 2
fi

if ! jq -e . "$MANIFEST_JSON" >/dev/null 2>&1; then
  printf 'seed.sh: seed.py emitted invalid JSON manifest\n' >&2
  exit 2
fi

CANDIDATES_COUNT=$(jq -r '.candidates_count' "$MANIFEST_JSON")
WRITES_COUNT=$(jq -r '.writes | length' "$MANIFEST_JSON")

if [ "$CANDIDATES_COUNT" = "0" ]; then
  printf 'seed.sh: approved plan has 0 project candidates; nothing to scaffold.\n' >&2
  emit_audit "skip" "$MANIFEST_JSON" "" "" "no-project-candidates"
  exit 0
fi

# ----- audit-log helper -----

# Resolve audit log path via gate library's public API.
AUDIT_LOG=$(gate_audit_path)
AUDIT_LOG_DIR=$(dirname "$AUDIT_LOG")
mkdir -p "$AUDIT_LOG_DIR" 2>/dev/null || true

_seed_sha_of() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  else
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  fi
}

# Emit one JSONL record matching SP12's audit-log shape exactly.
emit_audit() {
  # $1=action $2=target_path $3=sha_before $4=sha_after [$5=note]
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -nc \
    --arg ts "$ts" \
    --arg surface_id "seed-projects" \
    --arg action "$1" \
    --arg target_path "$2" \
    --arg sha_before "$3" \
    --arg sha_after "$4" \
    --arg note "${5:-}" \
    '{ts:$ts, surface_id:$surface_id, action:$action, target_path:$target_path, sha_before:$sha_before, sha_after:$sha_after, note:$note}' \
    >> "$AUDIT_LOG"
}

MANIFEST_SHA=$(_seed_sha_of "$MANIFEST_JSON")
emit_audit "generate" "$MANIFEST_JSON" "" "$MANIFEST_SHA"

# ----- batched preview render -----

print_batched_preview() {
  printf '\n=== three-step gate: PREVIEW (batched, surface seed-projects) ===\n' >&2
  printf 'Approved plan:    %s\n' "$APPROVED_PLAN" >&2
  printf 'Vault root:       %s\n' "$VAULT_ROOT" >&2
  printf 'Project candidates: %s   Files staged: %s\n' \
    "$CANDIDATES_COUNT" "$WRITES_COUNT" >&2
  printf '\n' >&2
  printf 'For each candidate, %d files (PRD.md / Context.md / Updates.md)\n' 3 >&2
  printf 'will be written under the candidate proposed_path. Below is the\n' >&2
  printf 'diff per file (full content for new files; unified diff against\n' >&2
  printf 'pre-existing target if present). All %s files apply atomically\n' \
    "$WRITES_COUNT" >&2
  printf 'on [a]pply, or none on [s]kip / [b]ort.\n\n' >&2

  local i=0
  local total
  total=$(jq -r '.writes | length' "$MANIFEST_JSON")
  while [ $i -lt $total ]; do
    local stage target label kind
    stage=$(jq -r ".writes[$i].staging" "$MANIFEST_JSON")
    target=$(jq -r ".writes[$i].target" "$MANIFEST_JSON")
    label=$(jq -r ".writes[$i].label" "$MANIFEST_JSON")
    kind=$(jq -r ".writes[$i].kind" "$MANIFEST_JSON")
    printf '\n--- [%d/%s] %s / %s ---\n' "$((i + 1))" "$total" "$label" "$kind" >&2
    printf 'staging: %s\n' "$stage" >&2
    printf 'target:  %s\n' "$target" >&2
    if [ -f "$target" ]; then
      printf '+++ diff target vs staging:\n' >&2
      diff -u "$target" "$stage" >&2 || true
    else
      printf '+++ target absent; full proposed content (head 40 lines):\n' >&2
      head -40 "$stage" >&2
    fi
    i=$((i + 1))
  done
  printf '\n=== end PREVIEW ===\n\n' >&2
}

print_what_happens_next() {
  cat <<EOF >&2

=== what happens next ===
On [a]pply  → atomically copy all $WRITES_COUNT staged files into the vault
              under their candidate proposed_paths. Each generated file
              carries SP12 provenance frontmatter
              (generated_by: seed-projects@v2.0.0, generated_from:
              <candidate_id>/<label>, last_user_edit: null) so future
              regen-decisions know what's safe to update vs preserve.

On [e]dit   → open \${EDITOR:-vi} on the staging tree at:
                $TG_STAGE_DIR/seed-projects/
              Edit any of the $WRITES_COUNT files (or all of them) in
              place. Save and quit your editor to return to this prompt;
              whatever you saved is what apply will write.

On [s]kip   → exit Stage 3 cleanly. No vault writes occur. The approved
              plan is preserved; you can re-run T-8 later. Stage 3
              T-10 (Inbox routing) and T-11 (meeting ingestor) remain
              unaffected.

On [b]ort   → exit with non-zero rc. No vault writes. No partial state.
=== end what happens next ===

EOF
}

# ----- prompt loop -----

CHOICE_OUT=""
read_choice() {
  CHOICE_OUT=""
  if [ -n "${PROMPT_CHOICE:-}" ]; then
    CHOICE_OUT="$PROMPT_CHOICE"
    PROMPT_CHOICE=""
    return 0
  fi
  if IFS= read -r CHOICE_OUT; then
    return 0
  fi
  if [ "$ACCEPT_ON_EOF" = "1" ]; then
    CHOICE_OUT="a"
    return 0
  fi
  return 1
}

apply_writes() {
  local i=0
  local total
  total=$(jq -r '.writes | length' "$MANIFEST_JSON")
  local sha_before sha_after
  while [ $i -lt $total ]; do
    local stage target target_dir
    stage=$(jq -r ".writes[$i].staging" "$MANIFEST_JSON")
    target=$(jq -r ".writes[$i].target" "$MANIFEST_JSON")
    target_dir=$(dirname "$target")
    if [ ! -d "$target_dir" ]; then
      if ! mkdir -p "$target_dir"; then
        printf 'seed.sh: mkdir failed: %s\n' "$target_dir" >&2
        emit_audit "error" "$target" "" "" "mkdir-failed"
        return 3
      fi
    fi
    sha_before=$(_seed_sha_of "$target")
    local final_tmp="${target}.tmp.$$"
    if ! cp "$stage" "$final_tmp"; then
      printf 'seed.sh: cp staging->tmp failed: %s\n' "$final_tmp" >&2
      emit_audit "error" "$target" "$sha_before" "" "stage-tmp-failed"
      return 3
    fi
    if ! mv "$final_tmp" "$target"; then
      printf 'seed.sh: mv tmp->target failed: %s\n' "$target" >&2
      rm -f "$final_tmp" 2>/dev/null
      emit_audit "error" "$target" "$sha_before" "" "rename-failed"
      return 3
    fi
    sha_after=$(_seed_sha_of "$target")
    emit_audit "apply" "$target" "$sha_before" "$sha_after"
    i=$((i + 1))
  done
  return 0
}

while :; do
  print_batched_preview
  emit_audit "preview" "$MANIFEST_JSON" "" "$MANIFEST_SHA"
  print_what_happens_next
  printf 'Apply this batched plan? [a]pply (default) / [e]dit / [s]kip / [b]ort: ' >&2
  if ! read_choice; then
    printf '\nseed.sh: stdin EOF; aborting (use --accept-on-eof to default-apply)\n' >&2
    emit_audit "abort" "$MANIFEST_JSON" "" "" "stdin-eof"
    exit 1
  fi
  choice="$CHOICE_OUT"
  case "$choice" in
    ""|a|A)
      if apply_writes; then
        printf 'seed.sh: applied %s files across %s candidates to %s\n' \
          "$WRITES_COUNT" "$CANDIDATES_COUNT" "$VAULT_ROOT" >&2
        exit 0
      else
        rc=$?
        printf 'seed.sh: apply failed mid-batch (rc=%s); audit log has details\n' "$rc" >&2
        exit "$rc"
      fi
      ;;
    e|E)
      ed="${EDITOR:-vi}"
      if ! command -v "$ed" >/dev/null 2>&1; then
        for cand in vi nano vim; do
          if command -v "$cand" >/dev/null 2>&1; then ed="$cand"; break; fi
        done
      fi
      if ! command -v "$ed" >/dev/null 2>&1; then
        printf 'seed.sh: no editor available; cannot edit. Re-prompting.\n' >&2
        continue
      fi
      "$ed" "$TG_STAGE_DIR/seed-projects/" || \
        printf 'seed.sh: editor returned non-zero; re-prompting unchanged.\n' >&2
      ;;
    s|S)
      emit_audit "skip" "$MANIFEST_JSON" "" "$MANIFEST_SHA"
      printf 'seed.sh: skipped — no vault writes.\n' >&2
      exit 0
      ;;
    b|B|q|Q)
      emit_audit "abort" "$MANIFEST_JSON" "" "$MANIFEST_SHA"
      printf 'seed.sh: aborted — no vault writes.\n' >&2
      exit 1
      ;;
    *)
      printf 'seed.sh: invalid choice "%s"; press a, e, s, or b\n' "$choice" >&2
      ;;
  esac
done
