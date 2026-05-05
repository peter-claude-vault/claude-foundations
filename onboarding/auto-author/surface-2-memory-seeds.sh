#!/usr/bin/env bash
# onboarding/auto-author/surface-2-memory-seeds.sh — SP12 T-5 (Plan 71 SP12 Session 2)
#
# Surface #2 — Auto-author $CLAUDE_HOME memory seeds (LLM-composed enrichment
# layer on top of SP11 T-3's deterministic R-45-frontmatter seeds). Coordinates
# with SP11 via the Mirror Collision Contract documented in
# 12-auto-authored-personalization/spec.md L156-162.
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - 0-5 *.md seed files under
#       ${CLAUDE_HOME:-$HOME/.claude}/projects/<slug>/memory/
#       (each carrying combined provenance + R-45 frontmatter).
#     - MEMORY.md index entries appended for newly-written seeds (existing
#       SP11-authored entries preserved).
#     - Per-file decision audit JSONL at
#       $CLAUDE_HOME/onboarding/audit/surface-2-upgrades.jsonl
#       (action ∈ {new, upgrade, skip-user-edited, abort-no-provenance}).
#   Schema-types declared:
#     - Seed-file frontmatter combines provenance-frontmatter-schema.json
#       (generated_by, generated_from, last_user_edit) WITH the R-45 contract
#       (name, description, type, last_verified). additionalProperties=true on
#       both schemas means a single fenced YAML block carries both.
#   Pre-write validation:
#     - SP11 done-marker present (clean halt + skip-with-report otherwise).
#     - Each staged seed validates against provenance-frontmatter-schema.json.
#     - Collision contract scan completes without ABORT decisions.
#   Failure mode: BLOCK AND LOG.
#
# Mirror Collision Contract (per spec L156-162):
#   1. Detection: scan $MEMORY_DIR for *.md files with provenance frontmatter
#      `generated_by: memory-bootstrap*`.
#   2. UPGRADE: SP11 seed found with provenance → upgrade in place; preserve
#      lineage via `superseded_by: surface-2-memory-seeds` + `original_sha256: <pre-bytes>`.
#   3. NEW: target path absent → standard provenance write.
#   4. SKIP: SP11 seed where last_user_edit > generated_by timestamp → preserve
#      user edits; audit-log skip-user-edited; do NOT overwrite.
#   5. ABORT: any SP11 seed lacks provenance frontmatter → SP11 contract
#      violation; surface for manual reconciliation; do NOT silently overwrite.
#
# Known divergence (CFF candidate, surfaced 2026-05-03):
#   SP11 T-3's bootstrap-schemas.sh::seed_memories() writes seeds with R-45
#   frontmatter ONLY — no provenance frontmatter. In production deployment
#   where SP11 ran first, T-5's collision-scan would trigger the ABORT path
#   for every SP11 seed. Resolution requires an SP11 amendment to prepend
#   provenance frontmatter (or T-5 relaxation to recognize R-45-only as
#   memory-bootstrap-implicit). Tracked as a close-out CFF; documented in handoff.md.
#
# CONSTRAINTS (R-23): bash 3.2 — no `declare -A`, no `mapfile`, no `${var,,}`.
# `jq` REQUIRED on PATH. lib/three-step-gate.sh + lib/provenance-frontmatter.sh
# REQUIRED — sourced via relative-path resolution.
#
# USAGE:
#   surface-2-memory-seeds.sh
#     [--user-manifest PATH]
#     [--memory-dir DIR]
#     [--inputs-dir DIR]
#     [--memory-bootstrap-done-marker PATH]
#     [--upgrades-log PATH]
#     [--mock-llm]
#     [--auto-apply] [--skip-preview] [--dry-run]
#
# Exit codes:
#   0   apply succeeded OR clean-halt (SP11 done-marker absent) OR skipped
#   1   user aborted at gate prompt OR collision-contract ABORT triggered
#   2   IO / dependency / generation error
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP12 Session 2

set -u

diag() { printf 'surface-2 FAIL: %s\n' "$1" >&2; }
info() { printf 'surface-2: %s\n' "$1"; }

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
INPUTS_DIR="${INPUTS_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding}"
MEMORY_BASE="${CLAUDE_HOME:-$HOME/.claude}"
MEMORY_DIR_OVERRIDE=""
SP11_DONE_MARKER="${SP11_DONE_MARKER:-${PLANS_HOME:-$HOME/.claude-plans}/71-claude-foundations-engine-v2/11-memory-bootstrap/state/T-3.done}"
UPGRADES_LOG="${UPGRADES_LOG:-$INPUTS_DIR/audit/surface-2-upgrades.jsonl}"
SURFACE_ID="surface-2-memory-seeds"
LLM_MOCK="${AUTO_AUTHOR_MOCK_LLM:-0}"
AUTO_APPLY=0
SKIP_PREVIEW=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user-manifest)     USER_MANIFEST="$2"; shift 2 ;;
    --memory-dir)        MEMORY_DIR_OVERRIDE="$2"; shift 2 ;;
    --inputs-dir)        INPUTS_DIR="$2"; shift 2 ;;
    --memory-bootstrap-done-marker)  SP11_DONE_MARKER="$2"; shift 2 ;;
    --upgrades-log)      UPGRADES_LOG="$2"; shift 2 ;;
    --mock-llm)          LLM_MOCK=1; shift ;;
    --auto-apply)        AUTO_APPLY=1; shift ;;
    --skip-preview)      SKIP_PREVIEW=1; shift ;;
    --dry-run)           gate_set_dry_run 1; shift ;;
    -h|--help)           sed -n '2,75p' "$0"; exit 0 ;;
    *)                   diag "unknown arg: $1"; exit 2 ;;
  esac
done

# --- preflight ---
command -v jq >/dev/null 2>&1 || { diag "jq required"; exit 2; }
command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 || { diag "shasum or sha256sum required"; exit 2; }
[ -f "$USER_MANIFEST" ] || { diag "user-manifest not found: $USER_MANIFEST"; exit 2; }

# --- SP11 done-marker check (clean-halt path) ---
if [ ! -f "$SP11_DONE_MARKER" ]; then
  info "SP11 done-marker absent at $SP11_DONE_MARKER — clean halt; defer T-5 to a session after SP11 closes."
  exit 0
fi

# --- compute memory dir ---
if [ -n "$MEMORY_DIR_OVERRIDE" ]; then
  MEMORY_DIR="$MEMORY_DIR_OVERRIDE"
else
  mem_slug="$(printf '%s' "$MEMORY_BASE" | tr '/' '-' | sed 's/^-//')"
  MEMORY_DIR="$MEMORY_BASE/projects/$mem_slug/memory"
fi
mkdir -p "$MEMORY_DIR" 2>/dev/null || { diag "cannot create memory dir: $MEMORY_DIR"; exit 2; }
mkdir -p "$(dirname "$UPGRADES_LOG")" 2>/dev/null || { diag "cannot create upgrades log dir"; exit 2; }

# --- helpers (defined before any use) ---

sha256_of() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  else
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  fi
}

upgrades_log_append() {
  local action="$1" target="$2" note="${3:-}"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg surface_id "$SURFACE_ID" \
    --arg action "$action" \
    --arg target "$target" \
    --arg note "$note" \
    '{ts:$ts, surface_id:$surface_id, action:$action, target:$target, note:$note}' \
    >> "$UPGRADES_LOG"
}

mf_get() {
  local p="$1"
  jq -r --arg p "$p" '
    ($p | split(".")) as $parts
    | getpath($parts) // ""
    | if type == "object" or type == "array" then "" else (. | tostring) end
  ' "$USER_MANIFEST" 2>/dev/null
}

slug_of() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr ' ' '-' | tr -dc 'a-z0-9-' | sed -e 's/^-*//' -e 's/-*$//'
}

_h2_for_type() {
  case "$1" in
    user)      printf '## User' ;;
    feedback)  printf '## Feedback' ;;
    project)   printf '## Project' ;;
    reference) printf '## Reference' ;;
    *)         printf '## User' ;;
  esac
}

_yaml_quote() {
  # YAML-quote a string for safe single-line value rendering. Escapes embedded
  # double-quotes and backslashes; bare strings without YAML-special chars are
  # passed through unquoted to keep diffs readable. For values containing :, ",
  # \, or leading/trailing whitespace we wrap in double quotes.
  local s="$1"
  case "$s" in
    *:*|*\"*|*\\*|" "*|*" ") printf '"%s"' "$(printf '%s' "$s" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" ;;
    *) printf '%s' "$s" ;;
  esac
}

emit_seed_with_frontmatter() {
  local stage_path="$1" type="$2" name="$3" desc="$4" from="$5" body="$6" pre_sha="${7:-}"
  {
    printf -- '---\n'
    printf 'generated_by: %s\n' "$SURFACE_ID"
    printf 'generated_from: %s\n' "$from"
    printf 'last_user_edit: null\n'
    if [ -n "$pre_sha" ]; then
      printf 'superseded_by: %s\n' "$SURFACE_ID"
      printf 'original_sha256: %s\n' "$pre_sha"
    fi
    # name/description quoted for YAML safety (may contain colons or quotes).
    printf 'name: %s\n' "$(_yaml_quote "$name")"
    printf 'description: %s\n' "$(_yaml_quote "$desc")"
    printf 'type: %s\n' "$type"
    # last_verified quoted to keep YAML parsers from coercing to date object
    # (which python yaml.safe_load + json.dump cannot serialize without
    # `default=str`; quoting keeps it a string for downstream consumers).
    printf 'last_verified: "%s"\n' "$NOW_DATE"
    printf -- '---\n\n'
    printf '%s\n' "$body"
  } > "$stage_path"
}

apply_index_update() {
  # APPLY_PLAN_FILE format: decision \t target \t stage \t type \t name \t desc \t pre_sha
  local idx="$MEMORY_DIR/MEMORY.md"
  local decision target stage seed_type seed_name seed_desc pre_sha base h2 entry
  if [ ! -f "$idx" ]; then
    {
      printf '# Memory Index\n\n'
      printf '## User\n\n'
      printf '## Feedback\n\n'
      printf '## Project\n\n'
      printf '## Reference\n\n'
    } > "$idx"
  fi
  while IFS=$'\t' read -r decision target stage seed_type seed_name seed_desc pre_sha; do
    [ "$decision" = "SKIP" ] && continue
    [ -z "$seed_type" ] && continue
    base="$(basename "$target")"
    if grep -F "$base" "$idx" >/dev/null 2>&1; then
      continue
    fi
    h2="$(_h2_for_type "$seed_type")"
    entry="- [$seed_name](memory/$base) — $seed_desc"
    awk -v hdr="$h2" -v ent="$entry" '
      {print}
      $0 == hdr { print ent }
    ' "$idx" > "$idx.tmp" && mv "$idx.tmp" "$idx"
  done < "$APPLY_PLAN_FILE"
}

# --- composer functions ---

_compose_via_llm_or_mock() {
  if [ "$LLM_MOCK" = "1" ]; then "$2"; return 0; fi
  # Real LLM path deferred (v2.0.0-rc fast-follow); falls through to mock.
  "$2"
}

_mock_communication_style_body() {
  cat <<EOF
${NAME} operates in **${AUTONOMY:-balanced}-autonomy** mode with a **${NOTIF_STYLE:-digest}** notification preference. Default audience for vault writes is \`${DEFAULT_AUDIENCE:-claude}\`.

Practical guidance for collaboration:

- Confirm before destructive operations, shared-state changes, or anything affecting infrastructure beyond the local environment.
- Default to digest-style summaries; expand to verbose only when explicitly asked.
- Frame outputs for the declared audience: \`claude\` is internal scratchwork, \`joint\` is human-and-Claude collaborative, \`human\` is reader-only.

Captured during onboarding from Section A (autonomy + notification style + default audience).
EOF
}

_mock_priorities_body() {
  cat <<EOF
${NAME}'s priorities and concerns surfaced during onboarding:

- Role context: ${ROLE:-(role unknown)}${ORGANIZATION:+ at ${ORGANIZATION}}${INDUSTRY:+ ($INDUSTRY)}.
- Architect prior-seed concerns: ${PRIOR_SEED:-(none captured)}.

These concerns prime the architect skill's analysis dimensions. When evaluating vault state or recommending system changes, weight these concerns explicitly.
EOF
}

_mock_project_vault_body() {
  cat <<EOF
Primary vault: \`${VAULT_ROOT:-<not declared>}\`

Organizational method: \`${ORG_METHOD:-<not declared>}\`. ${NAME} works within this organizational frame for engagement-related capture, project tracking, and routine vault operations.

Treat this vault as the operational database for ${NAME}'s work — meeting notes, project context, briefings, daily logs, ideation briefs, references.
EOF
}

_mock_feedback_communication_body() {
  cat <<EOF
**Feedback rule:** Mirror ${NAME}'s structural patterns when giving recommendations.

**Why:** ${NAME}'s declared communication style favors anchored coaching: identify what works → name the gap → provide direction → give an example. Reverting to generic "here are 3 options" framing loses signal.

**How to apply:** When asked for recommendations or alternatives, structure responses as: (1) what's working in the current approach, (2) the specific gap, (3) recommended direction, (4) one concrete example.
EOF
}

_mock_feedback_autonomy_body() {
  cat <<EOF
**Feedback rule:** Match the declared autonomy posture: \`${AUTONOMY:-balanced}\`.

**Why:** ${NAME} explicitly chose this posture during onboarding. Drifting toward more (or less) autonomous behavior breaks the trust contract.

**How to apply:** For destructive or shared-state operations, default to ask-then-act when in \`balanced\` or \`strict\` mode. Use \`permissive\` mode's act-then-report only when ${NAME} switches the posture.
EOF
}

# --- pull manifest fields ---
NAME="$(mf_get 'identity.name')"
ROLE="$(mf_get 'identity.role')"
ORGANIZATION="$(mf_get 'identity.organization')"
INDUSTRY="$(mf_get 'identity.industry')"
AUTONOMY="$(mf_get 'behavioral.autonomy')"
NOTIF_STYLE="$(mf_get 'behavioral.hook_preferences.notification_style')"
DEFAULT_AUDIENCE="$(mf_get 'vault.default_audience')"
ORG_METHOD="$(mf_get 'vault.organizational_method')"
PRIOR_SEED="$(mf_get 'architect.prior_seed')"
VAULT_ROOT="$(mf_get 'paths.vault_root')"
[ -z "$VAULT_ROOT" ] && VAULT_ROOT="$(mf_get 'vault.root')"

if [ -z "$NAME" ]; then
  diag "identity.name absent in manifest; cannot derive seed slugs."
  exit 2
fi

NAME_SLUG="$(slug_of "$NAME")"
[ -z "$NAME_SLUG" ] && NAME_SLUG="user"
VAULT_SLUG=""
if [ -n "$VAULT_ROOT" ]; then
  VAULT_SLUG="$(printf '%s' "$VAULT_ROOT" | sed 's|/$||; s|.*/||')"
  VAULT_SLUG="$(slug_of "$VAULT_SLUG")"
fi
[ -z "$VAULT_SLUG" ] && VAULT_SLUG="vault"

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_DATE="$(printf '%s' "$NOW_ISO" | cut -c1-10)"

# --- seed manifest ---
# 5 entries, one per line: PATH | TYPE | NAME | DESCRIPTION | GENERATED_FROM | COMPOSER_FN
SEEDS_MANIFEST="$(cat <<EOF
$MEMORY_DIR/user_${NAME_SLUG}_communication_style.md|user|${NAME} communication style|Communication style and autonomy posture captured during onboarding (Section A/D)|section-a-communication|_mock_communication_style_body
$MEMORY_DIR/user_${NAME_SLUG}_priorities.md|user|${NAME} priorities|Concerns + role context surfaced during onboarding for architect prior-seeding|section-d-architect-concerns|_mock_priorities_body
$MEMORY_DIR/project_${VAULT_SLUG}.md|project|Vault: ${VAULT_SLUG}|Primary vault root + organizational method captured during onboarding|section-c-vault|_mock_project_vault_body
$MEMORY_DIR/feedback_${NAME_SLUG}_communication_pattern.md|feedback|Mirror ${NAME}'s coaching feedback structure|Communication-pattern feedback derived from interview|section-a-style-pattern|_mock_feedback_communication_body
$MEMORY_DIR/feedback_${NAME_SLUG}_autonomy.md|feedback|Match ${NAME}'s autonomy posture|Autonomy-posture feedback derived from interview|section-d-autonomy|_mock_feedback_autonomy_body
EOF
)"

# --- collision-contract scan ---
DECISIONS_FILE="$(mktemp "${TMPDIR:-/tmp}/surface-2-decisions.XXXXXX")"
ABORT_DETECTED=0

while IFS='|' read -r seed_path seed_type seed_name seed_desc seed_from composer_fn; do
  [ -z "$seed_path" ] && continue
  decision="NEW"
  pre_sha=""
  reason=""
  if [ -f "$seed_path" ]; then
    fm="$(pf_extract "$seed_path" 2>/dev/null)"
    if printf '%s\n' "$fm" | grep -q '^generated_by:'; then
      gen_by="$(printf '%s\n' "$fm" | awk -F': ' '/^generated_by:/ {print $2; exit}' | tr -d ' "')"
      lue="$(printf '%s\n' "$fm" | awk -F': ' '/^last_user_edit:/ {print $2; exit}' | tr -d ' "')"
      case "$gen_by" in
        memory-bootstrap*)
          if [ -z "$lue" ] || [ "$lue" = "null" ]; then
            decision="UPGRADE"
            pre_sha="$(sha256_of "$seed_path")"
          else
            decision="SKIP"
            reason="last_user_edit=$lue (user-edited, contract-preserved)"
          fi
          ;;
        surface-2-memory-seeds*|sp12-t5*)
          decision="UPGRADE"
          pre_sha="$(sha256_of "$seed_path")"
          reason="re-running surface against its own prior output (idempotent; sp12-t5* match is back-compat for files written by earlier foundation versions)"
          ;;
        *)
          decision="SKIP"
          reason="generated_by=$gen_by (foreign generator; preserve)"
          ;;
      esac
    else
      decision="ABORT"
      reason="SP11 contract violation: existing seed without provenance frontmatter"
      ABORT_DETECTED=1
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$seed_path" "$seed_type" "$seed_name" "$seed_desc" "$seed_from" "$composer_fn" \
    "$decision" "$pre_sha" "$reason" >> "$DECISIONS_FILE"
done <<EOF
$SEEDS_MANIFEST
EOF

if [ "$ABORT_DETECTED" = "1" ]; then
  diag "Mirror Collision Contract ABORT: one or more existing seeds lack provenance frontmatter."
  diag "Decisions:"
  awk -F'\t' '{ printf "  %s  -> %s%s\n", $1, $7, ($9 != "" ? "  (" $9 ")" : "") }' "$DECISIONS_FILE" >&2
  diag "Manual reconciliation required — either delete the un-provenanced seeds OR amend SP11 to prepend provenance frontmatter on its writes."
  upgrades_log_append "abort-no-provenance" "$MEMORY_DIR" "ABORT: one or more SP11 seeds lack provenance frontmatter; surface for reconciliation"
  rm -f "$DECISIONS_FILE"
  exit 1
fi

# --- stage seed bodies ---
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/surface-2-stage.XXXXXX")"
APPLY_PLAN_FILE="$(mktemp "${TMPDIR:-/tmp}/surface-2-apply.XXXXXX")"

while IFS=$'\t' read -r seed_path seed_type seed_name seed_desc seed_from composer_fn decision pre_sha reason; do
  [ -z "$seed_path" ] && continue
  if [ "$decision" = "SKIP" ]; then
    # Plan format: decision \t target \t stage \t type \t name \t desc \t pre_sha (reason carried as desc field for SKIP rows)
    printf 'SKIP\t%s\t\t%s\t%s\t%s\t\n' "$seed_path" "$seed_type" "$seed_name" "$reason" >> "$APPLY_PLAN_FILE"
    continue
  fi
  body="$("$composer_fn" 2>/dev/null)"
  if [ -z "$body" ]; then
    diag "composer $composer_fn returned empty body; aborting"
    rm -rf "$STAGE_DIR"; rm -f "$DECISIONS_FILE" "$APPLY_PLAN_FILE"
    exit 2
  fi
  base="$(basename "$seed_path")"
  stage_path="$STAGE_DIR/$base"
  emit_seed_with_frontmatter "$stage_path" "$seed_type" "$seed_name" "$seed_desc" "$seed_from" "$body" "$pre_sha"
  if ! pf_validate "$stage_path" >/dev/null 2>&1; then
    diag "staged seed failed provenance validation: $stage_path"
    rm -rf "$STAGE_DIR"; rm -f "$DECISIONS_FILE" "$APPLY_PLAN_FILE"
    exit 2
  fi
  # Plan format: decision \t target \t stage \t type \t name \t desc \t pre_sha
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$decision" "$seed_path" "$stage_path" "$seed_type" "$seed_name" "$seed_desc" "$pre_sha" >> "$APPLY_PLAN_FILE"
done < "$DECISIONS_FILE"

# --- batched preview ---
preview_index_update() {
  # APPLY_PLAN_FILE format: decision \t target \t stage \t type \t name \t desc \t pre_sha
  local idx="$MEMORY_DIR/MEMORY.md"
  local decision target stage seed_type seed_name seed_desc pre_sha
  printf -- '--- INDEX UPDATE %s\n' "$idx" >&2
  if [ ! -f "$idx" ]; then
    printf '    (MEMORY.md absent; will be created with skeleton + new entries)\n' >&2
    return 0
  fi
  printf '    (proposed appends — entries for newly-written seeds; existing entries preserved)\n' >&2
  while IFS=$'\t' read -r decision target stage seed_type seed_name seed_desc pre_sha; do
    [ "$decision" = "SKIP" ] && continue
    [ -z "$seed_type" ] && continue
    if ! grep -F "$(basename "$target")" "$idx" >/dev/null 2>&1; then
      printf '    + %s -> %s (under H2 %s)\n' "$seed_name" "$(basename "$target")" "$(_h2_for_type "$seed_type")" >&2
    else
      printf '    = %s -> %s (already indexed)\n' "$seed_name" "$(basename "$target")" >&2
    fi
  done < "$APPLY_PLAN_FILE"
}

render_preview() {
  # APPLY_PLAN_FILE format: decision \t target \t stage \t type \t name \t desc \t pre_sha
  local decision target stage seed_type seed_name seed_desc pre_sha
  printf '\n=== surface-2-memory-seeds: BATCHED PREVIEW ===\n\n' >&2
  printf 'Memory dir: %s\n' "$MEMORY_DIR" >&2
  printf '\n' >&2
  while IFS=$'\t' read -r decision target stage seed_type seed_name seed_desc pre_sha; do
    case "$decision" in
      SKIP)
        printf -- '--- SKIP %s\n' "$target" >&2
        [ -n "$seed_desc" ] && printf '    reason: %s\n' "$seed_desc" >&2
        ;;
      NEW)
        printf -- '--- NEW %s\n' "$target" >&2
        printf '    (full content of proposed seed)\n' >&2
        cat "$stage" >&2
        ;;
      UPGRADE)
        printf -- '--- UPGRADE %s\n' "$target" >&2
        printf '    (diff: existing -> proposed)\n' >&2
        diff -u "$target" "$stage" >&2 || true
        ;;
    esac
    printf '\n' >&2
  done < "$APPLY_PLAN_FILE"
  preview_index_update
  printf '\n=== end PREVIEW ===\n\n' >&2
}

# --- prompt ---
do_apply=0
if [ "$SKIP_PREVIEW" != "1" ]; then
  render_preview
fi
if [ "$AUTO_APPLY" = "1" ]; then
  do_apply=1
elif [ "${TG_DRY_RUN:-0}" = "1" ]; then
  do_apply=0
  info "dry-run; no apply"
else
  printf 'Apply ALL proposed seed writes + index update? [a]pply (default) / [s]kip / [b]ort: ' >&2
  if ! IFS= read -r choice; then
    info "stdin EOF without --auto-apply; aborting"
    rm -rf "$STAGE_DIR"; rm -f "$DECISIONS_FILE" "$APPLY_PLAN_FILE"
    upgrades_log_append "abort-stdin-eof" "$MEMORY_DIR" "stdin EOF; no writes"
    exit 1
  fi
  case "$choice" in
    ""|a|A) do_apply=1 ;;
    s|S)
      info "user skipped apply"
      upgrades_log_append "skip-user" "$MEMORY_DIR" "user skipped batched apply"
      do_apply=0
      ;;
    b|B|q|Q)
      info "user aborted"
      upgrades_log_append "abort-user" "$MEMORY_DIR" "user aborted at batched prompt"
      rm -rf "$STAGE_DIR"; rm -f "$DECISIONS_FILE" "$APPLY_PLAN_FILE"
      exit 1
      ;;
    *)
      info "invalid choice; aborting"
      upgrades_log_append "abort-invalid-input" "$MEMORY_DIR" "invalid prompt input"
      rm -rf "$STAGE_DIR"; rm -f "$DECISIONS_FILE" "$APPLY_PLAN_FILE"
      exit 1
      ;;
  esac
fi

# --- apply ---
# APPLY_PLAN_FILE format: decision \t target \t stage \t type \t name \t desc \t pre_sha
if [ "$do_apply" = "1" ]; then
  while IFS=$'\t' read -r decision target stage seed_type seed_name seed_desc pre_sha; do
    case "$decision" in
      SKIP)
        upgrades_log_append "skip-user-edited" "$target" "$seed_desc"
        ;;
      NEW)
        target_dir="$(dirname "$target")"
        mkdir -p "$target_dir" 2>/dev/null
        tmp="$target.tmp.$$"
        if cp "$stage" "$tmp" && mv "$tmp" "$target"; then
          upgrades_log_append "new" "$target" ""
        else
          diag "write failed: $target"
          rm -rf "$STAGE_DIR"; rm -f "$DECISIONS_FILE" "$APPLY_PLAN_FILE"
          exit 2
        fi
        ;;
      UPGRADE)
        tmp="$target.tmp.$$"
        if cp "$stage" "$tmp" && mv "$tmp" "$target"; then
          upgrades_log_append "upgrade" "$target" "lineage_pre_sha256=$pre_sha"
        else
          diag "upgrade failed: $target"
          rm -rf "$STAGE_DIR"; rm -f "$DECISIONS_FILE" "$APPLY_PLAN_FILE"
          exit 2
        fi
        ;;
    esac
  done < "$APPLY_PLAN_FILE"

  apply_index_update
fi

rm -rf "$STAGE_DIR"
rm -f "$DECISIONS_FILE" "$APPLY_PLAN_FILE"

if [ "$do_apply" = "1" ]; then
  info "T-5 complete: memory-seeds auto-author applied to $MEMORY_DIR"
else
  info "T-5 complete: no apply (preview-only or skip)"
fi
exit 0
