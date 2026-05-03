#!/usr/bin/env bash
# onboarding/auto-author/surface-6-frontmatter-enforce.sh — SP12 T-9 (Plan 71 SP12 Session 3)
#
# Surface #6 — Auto-author per-capability config for frontmatter-enforce.
# Three manifest fields written under .vault.*:
#   - projects_root_dirname  (default "Engagements"; user-declared name if
#                             different) — closes A3-Gap #1 12-regex hardcode.
#   - engagement_aliases     (project-shortname → tag-suffix map; existing
#                             schema field — additive merge, no clobber).
#   - required_fields_overrides (per-canonical-type required-field overrides;
#                                additive merge with existing entries).
#
# Three-step gate (single-target via gate_generate + gate_apply against the
# user-manifest target). Provenance lives in the audit log + via wrapper
# JSON; user-manifest itself does not carry frontmatter (it's a schema-
# constrained JSON document).
#
# DECISION (T-9 AC #4 — REMOVE OR DEFER, no punt):
#
#   PATH CHOSEN: REMOVE (12-regex removal landed in skills/librarian/
#   capabilities/frontmatter-enforce.sh as part of this commit).
#
#   Rationale:
#     - Spec L298: "ship the manifest field while leaving consumers blind to
#       it would ship a stale promise."
#     - Mechanical regex-substitution; bash 3.2 + Python 3 compatible via
#       rf"^{PD}/..." patterns where PD = re.escape(PROJ_DIR).
#     - Default fallback ("Engagements") preserves backward compatibility for
#       users who never declared the field.
#     - Verified: grep -c 'Engagements/' frontmatter-enforce.sh -> 0.
#     - Verified: tests/sp12/frontmatter-enforce-projdir-unit-test.sh -> 12/12 PASS.
#
#   REJECTED: DEFER path would require SP10 reopen + remove the contingent
#   "frontmatter-enforce-12-regex-removal" v2.1 charter row. Higher friction,
#   no benefit — the patch is mechanical and self-contained.
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - $USER_MANIFEST (jq-patched .vault.{projects_root_dirname,
#                       engagement_aliases, required_fields_overrides})
#   Schema-types:
#     - JSON; user-manifest-schema.json declares all three fields as 1.5.x
#       additive (no const bump). Pre/post jq-parse validation.
#   Pre-write validation:
#     - user-manifest readable + parseable
#     - proposed projects_root_dirname is a non-empty string
#     - proposed engagement_aliases is an object of string→string
#     - proposed required_fields_overrides is an object of string→string-array
#     - bash -n on this script
#   Failure mode: BLOCK AND LOG.
#
# CONSTRAINTS (R-23): bash 3.2; jq required.
#
# USAGE:
#   surface-6-frontmatter-enforce.sh
#     [--user-manifest PATH]
#     [--projects-root-dirname-override STR]   # bypass interview read
#     [--auto-apply] [--skip-preview] [--dry-run]
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP12 Session 3

set -u

diag() { printf 'surface-6 FAIL: %s\n' "$1" >&2; }
info() { printf 'surface-6: %s\n' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONBOARDING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GATE_LIB="$ONBOARDING_DIR/lib/three-step-gate.sh"
[ -r "$GATE_LIB" ] || { diag "three-step-gate.sh not readable"; exit 2; }
# shellcheck source=/dev/null
. "$GATE_LIB"

# --- defaults + arg parsing ---
USER_MANIFEST="${USER_MANIFEST:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
PROJECTS_ROOT_OVERRIDE=""
SURFACE_ID="sp12-t9"
GENERATED_FROM="vault-projects-structure-interview+default-table"
AUTO_APPLY=0
SKIP_PREVIEW=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user-manifest)                    USER_MANIFEST="$2"; shift 2 ;;
    --projects-root-dirname-override)   PROJECTS_ROOT_OVERRIDE="$2"; shift 2 ;;
    --auto-apply)                       AUTO_APPLY=1; shift ;;
    --skip-preview)                     SKIP_PREVIEW=1; shift ;;
    --dry-run)                          DRY_RUN=1; gate_set_dry_run 1; shift ;;
    -h|--help)                          sed -n '2,53p' "$0"; exit 0 ;;
    *)                                  diag "unknown arg: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { diag "jq required on PATH"; exit 2; }
[ -f "$USER_MANIFEST" ] || { diag "user-manifest not found: $USER_MANIFEST"; exit 2; }
jq -e . "$USER_MANIFEST" >/dev/null 2>&1 || { diag "user-manifest invalid JSON"; exit 2; }

# --- read declared values ---
# projects_root_dirname: prefer override, else manifest, else default "Engagements".
PROPOSED_PROJ_DIR=""
if [ -n "$PROJECTS_ROOT_OVERRIDE" ]; then
  PROPOSED_PROJ_DIR="$PROJECTS_ROOT_OVERRIDE"
else
  declared="$(jq -r '.vault.projects_root_dirname // ""' "$USER_MANIFEST")"
  if [ -n "$declared" ] && [ "$declared" != "null" ]; then
    PROPOSED_PROJ_DIR="$declared"
  else
    # No declaration → also check top_level_folder (Section A field; SP07 path).
    top="$(jq -r '.vault.top_level_folder // ""' "$USER_MANIFEST")"
    if [ -n "$top" ] && [ "$top" != "null" ]; then
      PROPOSED_PROJ_DIR="$top"
    else
      PROPOSED_PROJ_DIR="Engagements"
    fi
  fi
fi
# Strip trailing slash defensively.
PROPOSED_PROJ_DIR="${PROPOSED_PROJ_DIR%/}"

# engagement_aliases: existing manifest value (preserved as-is unless extended
# during interview; SP12 T-9 does not auto-compose new aliases — that's user
# territory). Default {} when absent.
EXISTING_ALIASES_JSON="$(jq -c '.vault.engagement_aliases // {}' "$USER_MANIFEST")"

# required_fields_overrides: same — preserved as-is unless extended during
# interview. Default {} when absent.
EXISTING_OVERRIDES_JSON="$(jq -c '.vault.required_fields_overrides // {}' "$USER_MANIFEST")"

# Validate shapes.
if ! printf '%s' "$EXISTING_ALIASES_JSON" | jq -e '. | type == "object"' >/dev/null 2>&1; then
  diag "vault.engagement_aliases is not an object"
  exit 2
fi
if ! printf '%s' "$EXISTING_OVERRIDES_JSON" | jq -e '. | type == "object"' >/dev/null 2>&1; then
  diag "vault.required_fields_overrides is not an object"
  exit 2
fi

# --- generator (called by gate_generate) ---
gen_user_manifest() {
  jq \
    --arg pd "$PROPOSED_PROJ_DIR" \
    --argjson aliases "$EXISTING_ALIASES_JSON" \
    --argjson overrides "$EXISTING_OVERRIDES_JSON" \
    '
      .vault.projects_root_dirname = $pd
      | .vault.engagement_aliases = (.vault.engagement_aliases // {}) * $aliases
      | .vault.required_fields_overrides = (.vault.required_fields_overrides // {}) * $overrides
    ' "$USER_MANIFEST"
}

# --- main ---
if [ -z "${TG_STAGE_DIR:-}" ]; then
  TG_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sp12-t9.XXXXXX")"
  export TG_STAGE_DIR
fi

stage="$(gate_generate "$SURFACE_ID" gen_user_manifest)" || { diag "gate_generate failed"; exit 2; }

# --- post-generation validation ---
if ! jq -e . "$stage" >/dev/null 2>&1; then
  diag "staged user-manifest failed jq parse"
  exit 2
fi
got_pd="$(jq -r '.vault.projects_root_dirname // ""' "$stage")"
if [ "$got_pd" != "$PROPOSED_PROJ_DIR" ]; then
  diag "staged projects_root_dirname mismatch (got '$got_pd' expected '$PROPOSED_PROJ_DIR')"
  exit 2
fi

apply_args=""
[ "$SKIP_PREVIEW" = "1" ] && apply_args="$apply_args --skip-preview"
[ "$AUTO_APPLY"   = "1" ] && apply_args="$apply_args --accept-on-empty-stdin"

# shellcheck disable=SC2086
gate_apply "$stage" "$USER_MANIFEST" $apply_args
rc=$?
case "$rc" in
  0) info "surface-6 complete (projects_root_dirname='$PROPOSED_PROJ_DIR'; aliases=$(printf '%s' "$EXISTING_ALIASES_JSON" | jq -r 'length'); overrides=$(printf '%s' "$EXISTING_OVERRIDES_JSON" | jq -r 'length'))" ;;
  1) info "surface-6 aborted at gate prompt" ;;
  *) diag "gate_apply returned rc=$rc" ;;
esac
exit "$rc"
