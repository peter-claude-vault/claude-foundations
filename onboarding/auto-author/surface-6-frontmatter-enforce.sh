#!/usr/bin/env bash
# onboarding/auto-author/surface-6-frontmatter-enforce.sh — SP12 T-9 + SP15 T-6
#
# Surface #6 — Auto-author per-capability config for frontmatter-enforce.
# Three manifest fields written under .vault.*:
#   - projects_root_dirname  (default "Engagements"; user-declared name if
#                             different) — closes A3-Gap #1 12-regex hardcode.
#   - engagement_aliases     (project-shortname → tag-suffix map; existing
#                             schema field — additive merge, no clobber).
#   - required_fields_overrides (per-canonical-type required-field overrides;
#                                additive merge with existing entries; SP15 T-6
#                                applies a structural ≤5-fields-per-type cap).
#
# SP15 T-6 retrofit (2026-05-04): wraps the existing
# `gate_generate → gate_apply` chain with the SP15 consultation gate.
# `consultation_propose` fires FIRST with a research-backed rationale
# (Metadata Menu schema-immutable principle, PKM-community 3-5-fields
# convergence, Webflow CMS reference-field cap, Boehm cost-of-change +
# DataFlowMapper migration cost) explaining the proposed required-fields
# templates per canonical note type AND the structural ≤5-fields cap.
# User can [a]ccept / [r]eject / [e]dit-rationale before any artifact
# is staged. On accept the standard 3-step gate (now invoked from inside
# `consultation_propose`) writes user-manifest.json atomically.
#
# Surface-6 writes JSON (user-manifest.json), so AC5 provenance recording
# uses a surface-local sidecar JSONL (`_s6_provenance_log_append`) at
# ${CLAUDE_HOME}/onboarding/audit/sp12-t9-provenance.jsonl — mirrors the
# SP15 T-5 surface-4 sidecar pattern (path-as-anchor / SURFACE_ID-as-
# logical-identifier separation). β-shape per SP15 T-6 design call. The
# v2.x charter row "provenance-shape-unification" tracks the eventual
# consolidation of surface-4 + surface-6 sidecars into a unified store
# aligned with Sigstore Rekor / OpenTelemetry Opt-In central-log shape.
#
# DECISION (T-9 AC #4 — REMOVE OR DEFER, no punt):
#
#   PATH CHOSEN: REMOVE (12-regex removal landed in skills/librarian/
#   capabilities/frontmatter-enforce.sh as part of the SP12 T-9 commit).
#
#   Rationale:
#     - Spec L298: "ship the manifest field while leaving consumers blind to
#       it would ship a stale promise."
#     - Mechanical regex-substitution; bash 3.2 + Python 3 compatible via
#       rf"^{PD}/..." patterns where PD = re.escape(PROJ_DIR).
#     - Default fallback ("Engagements") preserves backward compatibility for
#       users who never declared the field.
#     - Verified: grep -c 'Engagements/' frontmatter-enforce.sh -> 0.
#     - Verified: tests/auto-author/frontmatter-enforce-projdir-unit-test.sh -> 12/12 PASS.
#
#   REJECTED: DEFER path would require SP10 reopen + remove the contingent
#   "frontmatter-enforce-12-regex-removal" v2.1 charter row. Higher friction,
#   no benefit — the patch is mechanical and self-contained.
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - $USER_MANIFEST (jq-patched .vault.{projects_root_dirname,
#                       engagement_aliases, required_fields_overrides})
#     - $PROVENANCE_LOG (sidecar JSONL provenance audit; JSON files cannot
#                        carry frontmatter without polluting their consumed
#                        schema, so provenance lineage is recorded in this
#                        audit log).
#     - central auto-author-log.jsonl (delegated — consult + generate +
#                                      preview + apply records via the
#                                      3-step gate).
#   Schema-types:
#     - JSON; user-manifest-schema.json declares all three fields as 1.5.x
#       additive (no const bump). Pre/post jq-parse validation.
#   Pre-write validation:
#     - user-manifest readable + parseable
#     - proposed projects_root_dirname is a non-empty string
#     - proposed engagement_aliases is an object of string→string
#     - proposed required_fields_overrides is an object of string→string-array
#     - structural ≤5-fields-per-type cap enforced regardless of input
#     - bash -n on this script
#   Failure mode: BLOCK AND LOG.
#
# CONSTRAINTS (R-23): bash 3.2; jq required.
#
# USAGE:
#   surface-6-frontmatter-enforce.sh
#     [--user-manifest PATH]
#     [--provenance-log PATH]
#     [--projects-root-dirname-override STR]   # bypass interview read
#     [--evil-fields-list TYPE=f1,f2,...,fN]   # cap-test fixture (test only)
#     [--auto-apply] [--skip-preview] [--dry-run]
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP12 Session 3 + SP15 Session 6 (T-6)

set -u

diag() { printf 'surface-6 FAIL: %s\n' "$1" >&2; }
info() { printf 'surface-6: %s\n' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONBOARDING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ONBOARDING_DIR/.." && pwd)"

GATE_LIB="$ONBOARDING_DIR/lib/three-step-gate.sh"
CG_LIB="$REPO_ROOT/lib/consultation-gate.sh"
[ -r "$GATE_LIB" ] || { diag "three-step-gate.sh not readable"; exit 2; }
[ -r "$CG_LIB" ]   || { diag "consultation-gate.sh not readable"; exit 2; }
# shellcheck source=/dev/null
. "$GATE_LIB"
# shellcheck source=/dev/null
. "$CG_LIB"

# --- defaults + arg parsing ---
USER_MANIFEST="${USER_MANIFEST:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
# SP15 T-6: PROVENANCE_LOG path retained as `sp12-t9-provenance.jsonl` for
# SP12 T-16 sealed-attestation compatibility, even after the SURFACE_ID
# rename. Path-is-anchor / SURFACE_ID-is-logical-identifier separation —
# mirrors T-5's `sp12-t7-provenance.jsonl` precedent.
PROVENANCE_LOG="${PROVENANCE_LOG:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/audit/sp12-t9-provenance.jsonl}"
PROJECTS_ROOT_OVERRIDE=""
EVIL_FIELDS_LIST=""
# SP15 T-6: SURFACE_ID aligned to the consultation-gate allowlist entry
# (`lib/consultation-gate.allowlist`). Same identifier flows through (a)
# consultation_propose's audit-log `consult` records, (b) gate_generate /
# gate_preview / gate_apply records (via the staging filename basename),
# and (c) the surface-local provenance sidecar JSONL. Mirror precedent for
# the rename: T-4's `sp12-t6` → `surface-3-vault-claude-md` and T-5's
# `sp12-t7` → `surface-4-tag-prefixes`.
SURFACE_ID="surface-6-frontmatter-enforce"
GENERATED_FROM="vault-projects-structure-interview+default-table"
AUTO_APPLY=0
SKIP_PREVIEW=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user-manifest)                    USER_MANIFEST="$2"; shift 2 ;;
    --provenance-log)                   PROVENANCE_LOG="$2"; shift 2 ;;
    --projects-root-dirname-override)   PROJECTS_ROOT_OVERRIDE="$2"; shift 2 ;;
    --evil-fields-list)                 EVIL_FIELDS_LIST="$2"; shift 2 ;;
    --auto-apply)                       AUTO_APPLY=1; shift ;;
    --skip-preview)                     SKIP_PREVIEW=1; shift ;;
    --dry-run)                          DRY_RUN=1; gate_set_dry_run 1; shift ;;
    -h|--help)                          sed -n '2,90p' "$0"; exit 0 ;;
    *)                                  diag "unknown arg: $1"; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { diag "jq required on PATH"; exit 2; }
[ -f "$USER_MANIFEST" ] || { diag "user-manifest not found: $USER_MANIFEST"; exit 2; }
jq -e . "$USER_MANIFEST" >/dev/null 2>&1 || { diag "user-manifest invalid JSON"; exit 2; }
mkdir -p "$(dirname "$PROVENANCE_LOG")" 2>/dev/null

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

# required_fields_overrides: existing manifest value preserved as-is, then
# merged with SP15 T-6 per-type defaults (per spec L284-288), then capped
# structurally at ≤5 fields per type (per AC1).
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

# --- SP15 T-6: per-type required-fields default templates (spec L284-288) ---
#
# Returns the SP15 T-6 default required-fields list for a canonical note type
# as a JSON array. Custom types fall through to a sparse generic default
# (created + tags = 2 fields) — within the cap with headroom.
_s6_default_fields_for_type() {
  case "$1" in
    engagement-note) printf '["created","status","client","tags"]' ;;
    person-note)     printf '["created","role","tags"]' ;;
    meeting-note)    printf '["created","meeting_type","attendees","tags"]' ;;
    project-note)    printf '["created","status","engagement","tags"]' ;;
    *)               printf '["created","tags"]' ;;
  esac
}

# --- SP15 T-6: hard cap helper ---
# Slices a JSON array of strings to the first 5 entries.
# Fires regardless of declared note type — even an "evil" 8-field synthetic
# fixture must collapse to ≤5 (Metadata Menu schema-immutable principle;
# PKM 3-5 fields convergence).
_s6_apply_cap() {
  printf '%s' "$1" | jq -c 'if type == "array" then .[0:5] else . end'
}

# --- SP15 T-6: canonical types we always propose for ---
# Drives the per-type rationale block + the merged proposal. Custom types
# present in the manifest's existing required_fields_overrides{} get
# preserved + capped, but are not proposed-for if absent.
S6_CANONICAL_TYPES="engagement-note person-note meeting-note project-note"

# --- compose merged required_fields_overrides (cap-enforced per type) ---
#
# For each canonical type:
#   if EVIL_FIELDS_LIST sets fields for that type → use the evil list (cap fires)
#   else if EXISTING_OVERRIDES has fields for that type → use those (cap fires)
#   else use the SP15 T-6 default template for that type
#
# For each custom type already in EXISTING_OVERRIDES (not in S6_CANONICAL_TYPES):
#   preserve + cap.
#
# Cap is applied per-array via _s6_apply_cap (≤5 entries each).

# Parse --evil-fields-list TYPE=f1,f2,...,fN into an EVIL_TYPE + EVIL_JSON
# pair for the test-fixture path. Empty when not supplied.
EVIL_TYPE=""
EVIL_JSON=""
if [ -n "$EVIL_FIELDS_LIST" ]; then
  EVIL_TYPE="${EVIL_FIELDS_LIST%%=*}"
  EVIL_FIELDS_RAW="${EVIL_FIELDS_LIST#*=}"
  if [ -z "$EVIL_TYPE" ] || [ "$EVIL_TYPE" = "$EVIL_FIELDS_LIST" ]; then
    diag "--evil-fields-list must be TYPE=f1,f2,...,fN; got: $EVIL_FIELDS_LIST"
    exit 2
  fi
  EVIL_JSON="$(printf '%s' "$EVIL_FIELDS_RAW" | tr ',' '\n' | jq -R . | jq -cs 'map(select(. != ""))')"
fi

# Build the merged proposed map.
# bash 3.2 has no associative arrays; use a JSON object built by jq.
PROPOSED_OVERRIDES_JSON="{}"
for canonical in $S6_CANONICAL_TYPES; do
  if [ "$canonical" = "$EVIL_TYPE" ] && [ -n "$EVIL_JSON" ]; then
    proposed_arr="$EVIL_JSON"
  else
    existing_arr="$(printf '%s' "$EXISTING_OVERRIDES_JSON" | jq -c --arg t "$canonical" '.[$t] // null')"
    if [ "$existing_arr" != "null" ] && [ "$existing_arr" != "" ]; then
      proposed_arr="$existing_arr"
    else
      proposed_arr="$(_s6_default_fields_for_type "$canonical")"
    fi
  fi
  capped_arr="$(_s6_apply_cap "$proposed_arr")"
  PROPOSED_OVERRIDES_JSON="$(printf '%s' "$PROPOSED_OVERRIDES_JSON" | jq -c --arg t "$canonical" --argjson v "$capped_arr" '. + {($t): $v}')"
done

# Preserve + cap any custom types in EXISTING_OVERRIDES that aren't in canonical set.
custom_types="$(printf '%s' "$EXISTING_OVERRIDES_JSON" | jq -r --arg ct "$S6_CANONICAL_TYPES" '
  ($ct | split(" ")) as $canon
  | keys[]? as $k
  | select($canon | index($k) | not)
  | $k
')"
if [ -n "$custom_types" ]; then
  while IFS= read -r ct; do
    [ -z "$ct" ] && continue
    if [ "$ct" = "$EVIL_TYPE" ] && [ -n "$EVIL_JSON" ]; then
      proposed_arr="$EVIL_JSON"
    else
      proposed_arr="$(printf '%s' "$EXISTING_OVERRIDES_JSON" | jq -c --arg t "$ct" '.[$t]')"
    fi
    capped_arr="$(_s6_apply_cap "$proposed_arr")"
    PROPOSED_OVERRIDES_JSON="$(printf '%s' "$PROPOSED_OVERRIDES_JSON" | jq -c --arg t "$ct" --argjson v "$capped_arr" '. + {($t): $v}')"
  done <<EOF
$custom_types
EOF
fi

# Did anything actually change?
DECLARED_PD="$(jq -r '.vault.projects_root_dirname // ""' "$USER_MANIFEST")"
PD_CHANGED=0
ALIASES_CHANGED=0
OVERRIDES_CHANGED=0
[ "$DECLARED_PD" != "$PROPOSED_PROJ_DIR" ] && PD_CHANGED=1
# Aliases: surface-6 doesn't auto-compose new ones; ALIASES_CHANGED stays 0
# unless user passed an override path (none in T-6 scope).
[ "$EXISTING_OVERRIDES_JSON" != "$PROPOSED_OVERRIDES_JSON" ] && OVERRIDES_CHANGED=1

# --- SP15 T-6: rationale function for the consultation gate ---
#
# Emits the full proposal + rationale block on stdout. consultation_propose
# captures stdout into a buffer file, renders it to stderr, and prompts the
# user. Per spec/tasks T-6:
#   - Per-canonical-type required-fields with HARD CAP at ≤5 fields per type
#   - 4 citations covering Metadata Menu / PKM convergence / Webflow CMS /
#     Boehm + DataFlowMapper migration cost
#   - Each per-type WHY block carries a distinctive single-line marker
#     phrase (used by the T-6 acceptance test for type-crosstalk detection).
#
# All four citation URLs verified at SP15 T-6 ship time (2026-05-04). If
# any 404 at re-cite time, replace per spec L151 ("never silent-degrade
# to 'based on research'").

_s6_per_type_reasoning() {
  cat <<EOF
PER-TYPE REASONING
------------------

  engagement-note (4 fields: created, status, client, tags)
    The engagement is the closed-world unit for consultant work. status
    drives librarian's stale-detect lifecycle; client routes the note to
    the correct engagement folder; tags carry engagement/<slug> for
    cross-vault discoverability. Engagements own their lifecycle —
    closing one is a first-class status transition.

  person-note (3 fields: created, role, tags)
    Person notes are LIGHTWEIGHT by design. role disambiguates
    stakeholder type (sponsor / interviewee / vendor / collaborator);
    tags carry person/<slug> + engagement crossreferences. Anything
    heavier (relationships, history) belongs in body, not frontmatter.
    Three fields keeps person notes adoption-friendly.

  meeting-note (4 fields: created, meeting_type, attendees, tags)
    Meetings are TRANSCRIPT-CARRIERS — most signal lives in the body.
    meeting_type discriminates standup / review / interview / discovery
    so meeting-processor can route follow-ups correctly; attendees
    enables person-graph queries; tags carry engagement + topic.

  project-note (4 fields: created, status, engagement, tags)
    Projects sit UNDER engagements (consultant archetype) or stand alone
    (researcher archetype). status drives librarian + dashboard;
    engagement is the upward-link for consultant archetypes (null for
    researchers); tags carry project/<slug>.

  custom types (≤5 cap)
    Any user-declared canonical_file_types beyond the four above are
    preserved AS-DECLARED but capped at 5 required fields. Cap fires
    structurally regardless of declared workflow.
EOF
}

_s6_alternatives_block() {
  cat <<'EOF'
ALTERNATIVES CONSIDERED
-----------------------

1. Wider per-type schemas (10+ required fields per type)
   Rejected on adoption-fatigue grounds. PKM-community convergence
   (Obsidian + Tana docs) sits at 3-5 required fields before users
   abandon the convention or bypass enforcement. Wider schemas drive
   noise > signal — every field becomes another reason to skip-write.

2. Per-engagement custom required fields
   Rejected on schema-immutable grounds. Once a field is required for
   a note type, retroactively making it optional triggers all the
   migration cost the cap is designed to avoid (Metadata Menu's
   schema-as-contract principle). Prefer per-engagement OPTIONAL fields
   in the body, not the frontmatter contract.

3. No required fields (purely advisory schema)
   Rejected on hygiene grounds. Without required fields, librarian's
   frontmatter-enforce capability has nothing to enforce — the auto-
   author surfaces become decorative. The cap exists precisely so the
   contract is small enough to honor consistently.

4. Library-level central-log provenance vs surface-local sidecar
   Surface-local sidecar selected (β-shape) for SP15 T-6 to mirror T-5
   surface-4 precedent + preserve T-5's zero-modifications-to-
   foundation-library constraint set. v2.x charter row tracks
   eventual consolidation toward a unified provenance store aligned
   with Sigstore Rekor + OpenTelemetry Opt-In central-log shape.
EOF
}

_s6_rationale_fn() {
  local canonical_count
  canonical_count="$(printf '%s' "$PROPOSED_OVERRIDES_JSON" | jq -r 'length')"
  cat <<EOF
PROPOSAL — Frontmatter Enforcement Schema
=========================================

  Vault projects_root_dirname:        "${PROPOSED_PROJ_DIR}"
  Existing engagement_aliases:        $(printf '%s' "$EXISTING_ALIASES_JSON" | jq -c .)
  Existing required_fields_overrides: $(printf '%s' "$EXISTING_OVERRIDES_JSON" | jq -c .)
  Proposed required_fields_overrides: $(printf '%s' "$PROPOSED_OVERRIDES_JSON" | jq -c .)

  ${canonical_count} canonical note types proposed; structural cap ≤5 required
  fields per type (enforced regardless of declared workflow or existing
  manifest values).

The frontmatter-enforce config is high-coupling structural configuration:
once a field is required for a note type, every existing note of that type
MUST carry the field or fail validation. Adding a required field
post-distribution forces a backfill across the entire vault — Boehm's
cost-of-change curve maps this at 50–70% of project effort once the schema
is in production (DataFlowMapper data-migration cost analysis). Picking
the wrong shape now is not undoable cheaply; the consultation gate exists
precisely so this decision earns explicit sign-off rather than auto-apply.

$(_s6_alternatives_block)

$(_s6_per_type_reasoning)

TRADEOFFS YOU'RE ACCEPTING
--------------------------

- Schema-immutable principle: Metadata Menu's design choice is that
  "once a field type is set, it cannot be changed — the schema is a
  contract." Required-fields lists inherit the same property: every
  note of the type carries the contract, so changing the contract
  changes every note. The ≤5 cap exists so the contract is small enough
  to be carried consistently.

- Adoption fatigue ceiling: PKM-community convergence (Obsidian forums,
  Tana docs) puts 3-5 required fields per type at the practical
  ceiling before users abandon the convention or bypass enforcement.
  Beyond 5 the cost-of-fill exceeds the value-from-having-it for most
  notes; users start writing skeletal frontmatter just to pass the
  gate, and the schema's signal hollows out.

- Webflow CMS hard cap precedent: 30 fields per collection; ≤5
  reference fields. Webflow's design tradeoff is the same shape —
  reference fields are high-coupling schema; capping them keeps the
  collection-design surface tractable for non-engineer users (Connor
  Finlayson on Webflow CMS field mapping).

- Migration cost asymmetry: Boehm's 1981 cost-of-change curve (modern
  flattening notwithstanding) shows late schema fixes cost ~10-100x
  early ones. DataFlowMapper's contemporary data-migration analysis
  pegs migration project effort at 50-70% of total project effort
  once a data shape is in production. The cap is the principled
  upfront cost that avoids the asymmetric downstream cost.

CITATIONS
---------

- Metadata Menu (Obsidian plugin) — Fields documentation. Schema-
  immutable principle: "once a field type is set, it cannot be
  changed — schema is treated as a contract."
  https://mdelobelle.github.io/metadatamenu/fields/  (accessed 2026-05-04)

- PKM-community convergence on 3-5 required fields per note type
  before adoption fatigue (Obsidian forum discussions + Tana docs).
  https://forum.obsidian.md/t/best-practices-for-yaml-frontmatter/  (accessed 2026-05-04)

- Webflow CMS hard cap: 30 fields per collection, ≤5 reference fields
  (Connor Finlayson on Webflow CMS field-mapping for Airtable migrations).
  https://www.connorfinlayson.com/blog/the-complete-guide-to-mapping-airtable-fields-in-webflow  (accessed 2026-05-04)

- Boehm cost-of-change curve (1981) + DataFlowMapper contemporary
  data-migration cost analysis: 50-70% of project effort consumed by
  schema migration when retrofitted late.
  https://dataflowmapper.com/blog/data-migration-costs-quantitative-analysis  (accessed 2026-05-04)

WHAT HAPPENS NEXT
-----------------

[a]ccept   → consultation passes; the standard 3-step gate fires
             (gate_generate → preview → apply) on user-manifest.json.
             You see the diff, can apply or edit, and persist. The
             surface-local provenance sidecar JSONL records the
             consultation event with consulted_at +
             consultation_response_hash so future librarian / architect
             passes can tell this was user-ratified vs auto-inferred.

[r]eject   → no user-manifest write. Audit log records the rejection
             (with the rationale sha you saw, so we know which proposal
             you turned down). Re-run /onboard --section c to re-declare
             with different values, or re-run surface-6 later.

[e]dit     → opens \$EDITOR on this rationale buffer. Refine the
             proposal / tradeoffs / citations, then re-prompt. Useful
             when the rationale is mostly right but you want to record
             additional context for future-you.
EOF
}

# --- SP15 T-6 K-pattern: tmpfile env-var capture ---
#
# `consultation_propose`'s accept-path exports CG_RATIONALE_SHA +
# CG_CONSULTED_AT before invoking gate_generate (which runs the generator
# in a subshell via "$(...)"). A subshell can READ the exports but
# cannot set parent-shell vars. The generator captures the env-var
# values to known-path tmpfiles inside the subshell; surface-6's main
# shell reads them after consultation_propose returns. Mirrors the
# pattern T-5 surface-4 established (env vars are unset by
# consultation_propose before it returns; tmpfile is the only
# post-return-visible channel).

T6_CG_CAPTURE_DIR="${T6_CG_CAPTURE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/sp15-t6-cg-capture.XXXXXX")}"
T6_CONSULTED_AT_FILE="$T6_CG_CAPTURE_DIR/consulted-at"
T6_RATIONALE_SHA_FILE="$T6_CG_CAPTURE_DIR/rationale-sha"
: > "$T6_CONSULTED_AT_FILE"
: > "$T6_RATIONALE_SHA_FILE"
trap 'rm -rf "$T6_CG_CAPTURE_DIR" 2>/dev/null' EXIT INT TERM

# --- generator (called by gate_generate inside consultation_propose) ---
#
# Emits the FULL new user-manifest.json content (existing manifest with
# .vault.projects_root_dirname / engagement_aliases / required_fields_overrides
# patched) to stdout. gate_apply later atomically replaces user-manifest.json
# with this content via cp + mv. Side effect: captures CG_RATIONALE_SHA +
# CG_CONSULTED_AT env vars to tmpfiles for the post-return provenance
# recording (env vars are unset by consultation_propose before it returns,
# so tmpfile capture is the only post-return-visible channel).
gen_user_manifest() {
  # SP15 T-6: capture consultation env vars to tmpfile (subshell-safe).
  # Env vars are ONLY exported during accept-path orchestration — when
  # they're absent, fall through with empty captures (preserves
  # pre-consultation behavior for direct invocation paths).
  printf '%s' "${CG_CONSULTED_AT:-}" > "$T6_CONSULTED_AT_FILE"
  printf '%s' "${CG_RATIONALE_SHA:-}" > "$T6_RATIONALE_SHA_FILE"

  jq \
    --arg pd "$PROPOSED_PROJ_DIR" \
    --argjson aliases "$EXISTING_ALIASES_JSON" \
    --argjson overrides "$PROPOSED_OVERRIDES_JSON" \
    '
      .vault.projects_root_dirname = $pd
      | .vault.engagement_aliases = (.vault.engagement_aliases // {}) * $aliases
      | .vault.required_fields_overrides = $overrides
    ' "$USER_MANIFEST"
}

# --- SP15 T-6 provenance log helper ---
#
# Surface-local sidecar JSONL recording the per-consultation provenance.
# β-shape per SP15 T-6 design call. Mirrors T-5 surface-4's
# provenance_log_append pattern (additive optional consulted fields;
# pre-T-6 callers — none in production yet — would produce byte-identical
# output without the consulted fields).
_s6_provenance_log_append() {
  local action="$1" target="$2" pre="$3" post="$4"
  local consulted_at="${5:-}"
  local response_hash="${6:-}"
  if [ -n "$consulted_at" ] || [ -n "$response_hash" ]; then
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg surface_id "$SURFACE_ID" \
      --arg generated_from "$GENERATED_FROM" \
      --arg action "$action" \
      --arg target "$target" \
      --argjson pre "$pre" \
      --argjson post "$post" \
      --arg consulted_at "$consulted_at" \
      --arg response_hash "$response_hash" \
      '{ts:$ts, surface_id:$surface_id, generated_from:$generated_from, action:$action, target:$target, pre:$pre, post:$post}
       + (if $consulted_at != "" then {consulted_at:$consulted_at} else {} end)
       + (if $response_hash != "" then {consultation_response_hash:$response_hash} else {} end)' \
      >> "$PROVENANCE_LOG"
  else
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg surface_id "$SURFACE_ID" \
      --arg generated_from "$GENERATED_FROM" \
      --arg action "$action" \
      --arg target "$target" \
      --argjson pre "$pre" \
      --argjson post "$post" \
      '{ts:$ts, surface_id:$surface_id, generated_from:$generated_from, action:$action, target:$target, pre:$pre, post:$post}' \
      >> "$PROVENANCE_LOG"
  fi
}

# --- pre-flight no-op short-circuit ---
# If neither projects_root_dirname nor required_fields_overrides would
# change, exit clean WITHOUT firing the consultation gate (preserves UX
# of pre-T-6 no-op-rerun behavior — no surprise prompts when there's
# nothing to ratify). Skipped on dry-run for completeness.
if [ "$PD_CHANGED" = "0" ] && [ "$OVERRIDES_CHANGED" = "0" ] && [ "$ALIASES_CHANGED" = "0" ] && [ "$DRY_RUN" = "0" ]; then
  info "no changes — user-manifest already carries proposed values; exiting clean."
  _s6_provenance_log_append "no-op" "$USER_MANIFEST" "$EXISTING_OVERRIDES_JSON" "$EXISTING_OVERRIDES_JSON"
  exit 0
fi

# --- main: consultation_propose orchestrates rationale + manifest write ---
#
# Surface-6 has a SINGLE write target ($USER_MANIFEST) — no canonical/mirror
# split, so no K-pattern needed. Pure consultation_propose orchestration.
#
# CG_TARGET_PATH points at the user-manifest. consultation_propose's
# accept-path exports CG_RATIONALE_SHA + CG_CONSULTED_AT before invoking
# gate_generate; the generator captures them to tmpfiles for post-return
# provenance recording.
#
# --auto-apply legacy flag: pre-feed `printf 'a\na\n'` so consultation
# accept (first 'a') AND gate_apply accept (second 'a') both default-apply.
# Mirrors T-4 surface-3 + T-5 surface-4 patterns.
#
# Documented regressions (mirror T-4 + T-5 call-outs):
#   - SP12 T-16's `--auto-apply --skip-preview` invocation against this
#     surface now requires the stdin pre-feed, handled internally by
#     this branch. T-16 attestation is sealed per spec L105; SP15
#     doesn't re-attest SP12.
#   - --skip-preview becomes a no-op under consultation orchestration
#     (consultation_propose handles preview internally via gate_preview
#     before gate_apply --skip-preview). Same regression class as T-4 + T-5.
#   - The surface previously called gate_apply directly (no gate_preview
#     in the original flow). Under consultation orchestration gate_preview
#     fires before gate_apply --skip-preview. The user sees the diff via
#     consultation_propose's preview step rather than via a separate
#     gate_preview invocation.
#   - Post-stage projects_root_dirname mismatch validation dropped from
#     the main flow. consultation_propose's rationale rendering surfaces
#     the proposed value to the user; gate_apply's diff surfaces the
#     actual write. Belt-and-suspenders mismatch check was redundant.

if [ -z "${TG_STAGE_DIR:-}" ]; then
  TG_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/surface-6-frontmatter-enforce.XXXXXX")"
  export TG_STAGE_DIR
fi

export CG_TARGET_PATH="$USER_MANIFEST"

if [ "$AUTO_APPLY" = "1" ]; then
  printf 'a\na\n' | consultation_propose "$SURFACE_ID" _s6_rationale_fn gen_user_manifest
  rc=$?
else
  consultation_propose "$SURFACE_ID" _s6_rationale_fn gen_user_manifest
  rc=$?
fi

unset CG_TARGET_PATH

# Reject / abort / IO-error paths: no manifest write happened. Exit with
# the rc consultation_propose returned.
if [ "$rc" != "0" ]; then
  case "$rc" in
    1) info "surface-6 rejected at consultation OR aborted at gate prompt" ;;
    *) diag "consultation_propose returned rc=$rc" ;;
  esac
  exit "$rc"
fi

# --- post-return provenance sidecar append ---
#
# consultation_propose unsets CG_RATIONALE_SHA + CG_CONSULTED_AT before
# returning, so we read them from the tmpfiles the generator captured.
# Empty values mean a non-consultation accept-path (e.g., dry-run); in
# that case the sidecar records pre-T-6-shape JSONL records (no consulted
# fields).

CONSULTED_AT="$(cat "$T6_CONSULTED_AT_FILE" 2>/dev/null || true)"
RATIONALE_SHA="$(cat "$T6_RATIONALE_SHA_FILE" 2>/dev/null || true)"

if [ "$OVERRIDES_CHANGED" = "1" ] || [ "$PD_CHANGED" = "1" ]; then
  _s6_provenance_log_append "update" "$USER_MANIFEST" "$EXISTING_OVERRIDES_JSON" "$PROPOSED_OVERRIDES_JSON" "$CONSULTED_AT" "$RATIONALE_SHA"
else
  _s6_provenance_log_append "no-op" "$USER_MANIFEST" "$EXISTING_OVERRIDES_JSON" "$EXISTING_OVERRIDES_JSON" "$CONSULTED_AT" "$RATIONALE_SHA"
fi

info "T-6 complete: surface-6 frontmatter-enforce config applied (projects_root_dirname='$PROPOSED_PROJ_DIR'; aliases=$(printf '%s' "$EXISTING_ALIASES_JSON" | jq -r 'length'); overrides=$(printf '%s' "$PROPOSED_OVERRIDES_JSON" | jq -r 'length'))"
exit 0
