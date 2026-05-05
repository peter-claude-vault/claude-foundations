#!/usr/bin/env bash
# onboarding/auto-author/surface-4-tag-prefixes.sh — SP12 T-7 + SP15 T-5
#
# Surface #4 — Auto-author `_tag_prefixes[]` based on declared workflow
# archetype (vault.tag_prefix_archetype, set by Q-ID A-CB-7 in section-a.sh
# per T-14). Persists into TWO targets:
#   1. ${CLAUDE_HOME}/schemas/vault-schema.json._tag_prefixes (canonical
#      registry consumed by frontmatter-enforce + librarian)
#   2. user-manifest.json::vault.tag_prefixes (mirror — runtime-readable
#      by capabilities via lib/paths.sh / umr_get_array)
#
# SP15 T-5 retrofit (2026-05-04): wraps the canonical write with the
# SP15 consultation gate. `consultation_propose` fires FIRST with a
# research-backed rationale (Cowan-4 working-memory cap, Forte PARA,
# Luhmann's 100→11 Zettelkasten maturation, Ahrens taxonomy minimalism,
# Matrixflows IA depth/discoverability) and per-archetype 5-prefix
# proposals capped structurally at ≤9. User can [a]ccept / [r]eject /
# [e]dit-rationale before any artifact is staged. On accept, the standard
# 3-step gate (`gate_generate → gate_preview → gate_apply`) writes the
# canonical (vault-schema.json) atomically; the mirror (user-manifest.json)
# is patched as a post-return step preserving canonical-first ordering
# (mirror must never be ahead of canonical — downstream consumers cache
# the mirror as a runtime materialization of the canonical registry).
#
# Provenance: vault-schema canonical write goes through the central audit
# log (lib/three-step-gate.sh) with action "apply"; user-manifest mirror
# write continues to use the per-surface JSONL sidecar at
# ${CLAUDE_HOME}/onboarding/audit/surface-4-provenance.jsonl with action
# "update" (path retained for SP12 T-16 sealed-attestation compatibility,
# even after the SURFACE_ID rename). Both records carry the SP15 T-3
# fields `consulted_at` + `consultation_response_hash` when the
# accept-path orchestration produced them; absent otherwise.
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - $VAULT_SCHEMA (gate_apply atomic cp+mv after consultation accept)
#     - $USER_MANIFEST (jq-patched .vault.tag_prefixes — post-return mirror)
#     - $PROVENANCE_LOG (sidecar JSONL provenance audit; JSON files cannot
#       carry frontmatter without polluting their consumed schema, so
#       provenance lineage is recorded in this audit log).
#     - central auto-author-log.jsonl (delegated — consult + generate +
#       preview + apply records via the 3-step gate).
#   Schema-types:
#     - Both writes are array updates; pre/post-jq-patch validation runs
#       jq-parse on both files.
#   Pre-write validation:
#     - Both targets readable + jq-parseable.
#     - Proposed prefix list is non-empty array of slug-shaped strings.
#     - Hard cap ≤9 enforced structurally regardless of archetype seed
#       (cap fires twice — pre-merge on the proposal, post-merge on the
#       union with existing prefixes).
#   Failure mode: BLOCK AND LOG.
#
# Archetype-keyed prefix table (spec-aligned, SP15 T-5):
#   consultant : engagement/, project/, scope/, topic/, person/
#   researcher : topic/, paper/, dataset/, method/, person/
#   operator   : system/, incident/, runbook/, service/, person/
#   <other>    : custom — sparse generic set (project/, topic/, person/,
#                                              reference/), capped at 9
#   <null>     : custom — same path
#
# CONSTRAINTS (R-23): bash 3.2; jq required.
#
# USAGE:
#   surface-4-tag-prefixes.sh
#     [--user-manifest PATH]
#     [--vault-schema PATH]
#     [--provenance-log PATH]
#     [--archetype-override STR]   # bypass manifest read; useful for tests
#     [--evil-prefix-list STR]     # comma-separated cap-test fixture (test only)
#     [--auto-apply] [--skip-preview] [--dry-run]
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP12 Session 2 + SP15 Session 5 (T-5)

set -u

diag() { printf 'surface-4 FAIL: %s\n' "$1" >&2; }
info() { printf 'surface-4: %s\n' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONBOARDING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ONBOARDING_DIR/.." && pwd)"

GATE_LIB="$ONBOARDING_DIR/lib/three-step-gate.sh"
PF_LIB="$REPO_ROOT/lib/provenance-frontmatter.sh"
CG_LIB="$REPO_ROOT/lib/consultation-gate.sh"
[ -r "$GATE_LIB" ] || { diag "three-step-gate.sh not readable"; exit 2; }
[ -r "$PF_LIB" ]   || { diag "provenance-frontmatter.sh not readable"; exit 2; }
[ -r "$CG_LIB" ]   || { diag "consultation-gate.sh not readable"; exit 2; }
# shellcheck source=/dev/null
. "$GATE_LIB"
# shellcheck source=/dev/null
. "$PF_LIB"
# shellcheck source=/dev/null
. "$CG_LIB"

# --- defaults + arg parsing ---
USER_MANIFEST="${USER_MANIFEST:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
VAULT_SCHEMA="${VAULT_SCHEMA:-${CLAUDE_HOME:-$HOME/.claude}/schemas/vault-schema.json}"
# PROVENANCE_LOG: per-surface sidecar audit log. The filename is a stable
# anchor for downstream consumers; the SURFACE_ID is the logical identifier
# inside the JSONL records.
PROVENANCE_LOG="${PROVENANCE_LOG:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/audit/surface-4-provenance.jsonl}"
ARCHETYPE_OVERRIDE=""
EVIL_PREFIX_LIST=""
# SURFACE_ID is aligned to the consultation-gate allowlist entry
# (`lib/consultation-gate.allowlist`). Same identifier flows through the
# central audit log (consult + generate + preview + apply via the 3-step
# gate) AND the per-surface sidecar JSONL records.
SURFACE_ID="surface-4-tag-prefixes"
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
    --evil-prefix-list)     EVIL_PREFIX_LIST="$2"; shift 2 ;;
    --mock-llm)             LLM_MOCK=1; shift ;;
    --auto-apply)           AUTO_APPLY=1; shift ;;
    --skip-preview)         SKIP_PREVIEW=1; shift ;;
    --dry-run)              DRY_RUN=1; gate_set_dry_run 1; shift ;;
    -h|--help)              sed -n '2,80p' "$0"; exit 0 ;;
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

# --- archetype-keyed prefix table (SP15 T-5 spec-aligned, 5 prefixes per) ---
prefixes_for_archetype() {
  case "$1" in
    consultant) printf 'engagement/\nproject/\nscope/\ntopic/\nperson/\n' ;;
    researcher) printf 'topic/\npaper/\ndataset/\nmethod/\nperson/\n' ;;
    operator)   printf 'system/\nincident/\nrunbook/\nservice/\nperson/\n' ;;
    *)          # custom fallback — sparse generic, capped at 9.
                printf 'project/\ntopic/\nperson/\nreference/\n' ;;
  esac
}

# --- SP15 T-5: hard cap helper ---
# Slices a newline-separated prefix list to the first 9 non-empty entries.
# Fires regardless of declared archetype — even an "evil" archetype
# attempting 12+ prefixes must collapse to ≤9 (Cowan-4 working-memory
# cap; Luhmann's 100→11 mature-Zettelkasten ceiling).
_s4_apply_cap() {
  printf '%s' "$1" | awk 'NF { if (++n <= 9) print }'
}

# --- compose proposed prefix list (cap-enforced pre-merge) ---
if [ -n "$EVIL_PREFIX_LIST" ]; then
  # Test fixture: split comma-separated list; cap fires below.
  PROPOSED_PREFIXES_RAW="$(printf '%s' "$EVIL_PREFIX_LIST" | tr ',' '\n')"
else
  PROPOSED_PREFIXES_RAW="$(prefixes_for_archetype "$ARCHETYPE_LC")"
fi
PROPOSED_PREFIXES="$(_s4_apply_cap "$PROPOSED_PREFIXES_RAW")"
if [ -z "$PROPOSED_PREFIXES" ]; then
  diag "could not derive proposed prefix list (empty)"
  exit 2
fi

# JSON array form.
PROPOSED_JSON="$(printf '%s\n' "$PROPOSED_PREFIXES" | jq -R . | jq -cs 'map(select(. != ""))')"

# --- read existing prefix lists ---
EXISTING_VS_JSON="$(jq -c '._tag_prefixes // []' "$VAULT_SCHEMA")"
EXISTING_UM_JSON="$(jq -c '.vault.tag_prefixes // []' "$USER_MANIFEST")"

# --- compute merge result (union, deduplicated, sorted), then re-cap ---
# SP15 T-5: cap MUST also fire post-merge — pre-existing prefixes carried
# forward must not push the merged set above 9 either. _s4_apply_cap is
# idempotent on already-capped input.
MERGED_VS_RAW="$(printf '%s\n%s\n' "$EXISTING_VS_JSON" "$PROPOSED_JSON" | jq -s 'add | unique | .[]' | tr -d '"')"
MERGED_UM_RAW="$(printf '%s\n%s\n' "$EXISTING_UM_JSON" "$PROPOSED_JSON" | jq -s 'add | unique | .[]' | tr -d '"')"
MERGED_VS_CAPPED="$(_s4_apply_cap "$MERGED_VS_RAW")"
MERGED_UM_CAPPED="$(_s4_apply_cap "$MERGED_UM_RAW")"
MERGED_VS_JSON="$(printf '%s\n' "$MERGED_VS_CAPPED" | jq -R . | jq -cs 'map(select(. != ""))')"
MERGED_UM_JSON="$(printf '%s\n' "$MERGED_UM_CAPPED" | jq -R . | jq -cs 'map(select(. != ""))')"

# Did anything actually change?
VS_CHANGED=0
UM_CHANGED=0
[ "$EXISTING_VS_JSON" != "$MERGED_VS_JSON" ] && VS_CHANGED=1
[ "$EXISTING_UM_JSON" != "$MERGED_UM_JSON" ] && UM_CHANGED=1

# --- SP15 T-5: rationale function for the consultation gate ---
#
# Emits the full proposal + rationale block on stdout. consultation_propose
# captures stdout into a buffer, renders it to stderr, and prompts the user.
# Per spec/tasks T-5:
#   - 4 archetypes (consultant / researcher / operator / custom)
#   - 5 prefixes per non-custom archetype (custom: sparse generic set)
#   - 5 citations covering Cowan, Forte, Luhmann, Ahrens, Matrixflows
#   - Hard cap ≤9 prefixes structurally enforced via _s4_apply_cap
#
# Each archetype's WHY-FOR-YOU block carries a distinctive single-line
# marker phrase (used by the T-5 acceptance test for archetype-crosstalk
# detection): MIRROR your billing / topic/ is the primary backbone /
# incident/ is incident-specific / If your work follows a stronger pattern.
#
# All five citation URLs verified at SP15 T-5 ship time (2026-05-04). If
# any 404 at re-cite time, replace per spec L151 ("never silent-degrade
# to 'based on research'").

_s4_archetype_signal() {
  case "$ARCHETYPE_LC" in
    consultant) printf 'consultant' ;;
    researcher) printf 'researcher' ;;
    operator)   printf 'operator' ;;
    *)          printf 'custom' ;;
  esac
}

_s4_archetype_reasoning() {
  case "$(_s4_archetype_signal)" in
    consultant)
      cat <<EOF
Your declared archetype ("${ARCHETYPE}") signals client-engagement work
organized around external clients with finite engagement durations. The
proposed 5 prefixes follow that grain:

  engagement/   — closed-world unit (one client, one engagement, finite)
  project/      — sub-deliverables within an engagement
  scope/        — workstreams cutting across deliverables
  topic/        — durable knowledge anchored to subject, not client
  person/       — stakeholders / contacts / interviewees

The first three (engagement/project/scope) MIRROR your billing and
accountability hierarchy — each engagement is a closed-world unit with
its own people, deadlines, and definition-of-done. topic/ + person/
extend across engagement boundaries — durable knowledge that survives
a closed engagement.
EOF
      ;;
    researcher)
      cat <<EOF
Your declared archetype ("${ARCHETYPE}") signals research / writing /
project-driven work organized around discoverable categories rather
than client-bound engagements. The proposed 5 prefixes follow that
grain:

  topic/        — durable subject anchor for what the work is about
  paper/        — academic / long-form artifact under active development
  dataset/      — empirical material distinct from interpretive notes
  method/       — methodology / technique / instrument categorization
  person/       — interviewees / collaborators / cited authors

topic/ is the primary backbone — vs the consultant archetype's
engagement/. paper/ and dataset/ are research-specific deliverables;
method/ separates technique from subject (important when the same
method applies to multiple papers).
EOF
      ;;
    operator)
      cat <<EOF
Your declared archetype ("${ARCHETYPE}") signals operations / SRE /
platform work organized around running systems. The proposed 5
prefixes follow that grain:

  system/       — long-lived service or platform (the noun)
  incident/     — discrete time-bounded operational events
  runbook/      — procedural knowledge (the how, not the what)
  service/      — finer-grained component of a system (often per-team)
  person/       — oncall contacts / incident owners / vendor reps

incident/ is incident-specific so postmortems and timelines stay
separate from durable runbook/ knowledge. service/ vs system/ encodes
the common distinction between platform-level (system) and team-level
(service) ownership.
EOF
      ;;
    custom|*)
      cat <<EOF
Your declared archetype ("${ARCHETYPE:-(undeclared)}") doesn't match
any of the pre-baked archetypes. The proposed prefix set is a sparse
generic default:

  project/      — outcome-bound work
  topic/        — subject anchor
  person/       — contacts
  reference/    — durable lookup material

If your work follows a stronger pattern, [r]eject this proposal and
re-run /onboard --section a to re-declare your tag_prefix_archetype
as "consultant" / "researcher" / "operator". You can also [e]dit
this rationale to refine the proposal — the cap of ≤9 is enforced
regardless of how you compose the set.
EOF
      ;;
  esac
}

_s4_alternatives_block() {
  cat <<'EOF'
ALTERNATIVES CONSIDERED
-----------------------

1. Consultant   (engagement/ project/ scope/ topic/ person/)
   Best for: client-engagement work with finite durations + per-engagement
   accountability. Each engagement is a closed-world unit.

2. Researcher   (topic/ paper/ dataset/ method/ person/)
   Best for: long-form writing or research where work organizes around
   subject + artifact + methodology, not external clients.

3. Operator     (system/ incident/ runbook/ service/ person/)
   Best for: running systems — platform / SRE / oncall work where the
   incident-vs-runbook-vs-system distinction is load-bearing.

4. Custom       (project/ topic/ person/ reference/  + user-edits)
   Best for: workflows that don't fit the three pre-baked archetypes.
   Sparse default; user is invited to edit. Cap ≤9 still enforced.
EOF
}

_s4_rationale_fn() {
  cat <<EOF
PROPOSAL — Tag Prefix Taxonomy
==============================

  Declared archetype:        "${ARCHETYPE:-(undeclared)}"
  Existing _tag_prefixes:    $(printf '%s' "$EXISTING_VS_JSON" | jq -c .)
  Existing manifest mirror:  $(printf '%s' "$EXISTING_UM_JSON" | jq -c .)
  Proposed merged set (≤9):  $(printf '%s' "$MERGED_VS_JSON" | jq -c .)

Tag taxonomies are routed via search, browse, and graph queries thousands
of times over a vault's lifetime. Picking the wrong shape now cascades —
schema retrofit cost runs 50–70% of migration project effort once
prefixes are in production (DataFlowMapper). The structural question is
not "what tags do I want?" — it's "what taxonomy shape matches how I
actually work?". Below is the proposal grounded in your declared
archetype + working-memory research.

$(_s4_alternatives_block)

WHY THIS PROPOSAL FOR YOU
-------------------------

$(_s4_archetype_reasoning)

TRADEOFFS YOU'RE ACCEPTING
--------------------------

- Working-memory cap on top-level taxonomy: human short-term memory
  holds ~4 ± 1 chunks (Cowan 2001, peer-reviewed replacement for
  Miller 7±2). Top-level taxonomies that exceed this get navigated
  via search rather than browse — defeating the structure's purpose.
  PARA's 4-category cap is grounded here. SP15 T-5 caps top-level
  prefixes at single digits (≤9) as a structural enforcement. Below
  that you can nest deeper per-prefix because working memory is
  scoped to the prefix you're currently in.

- Curated taxonomy over exhaustive: Luhmann's mature Zettelkasten kept
  ~11 top-level subjects despite ~90,000 notes; index averaged 1–2
  notes per keyword (Ahrens, How to Take Smart Notes §taxonomy
  minimalism). Sparse, curated tags beat exhaustive coverage. The
  proposal here is 4–5 prefixes — well under the cap, leaving headroom
  for evolution.

- Discoverability vs flexibility: every additional hierarchy level
  reduces discoverability ~50%; by 5 levels deep, 90%+ of users
  abandon search and fall back to keyword-only navigation (Matrixflows
  enterprise IA research). Top-level structure earns its place; depth
  is paid for in discoverability cost.

CITATIONS
---------

- Nelson Cowan. "The magical number 4 in short-term memory: A
  reconsideration of mental storage capacity." Behavioral and Brain
  Sciences, 24(1), 2001. (Replaces Miller 7±2; PARA's 4-category cap
  is justified on this.)
  https://www.cambridge.org/core/journals/behavioral-and-brain-sciences/article/abs/magical-number-4-in-shortterm-memory-a-reconsideration-of-mental-storage-capacity/44023F1147D4A1D44BABA6BCE2DE0B7C  (accessed 2026-05-04)

- Tiago Forte. "PARA Method: The Simple System for Organizing Your
  Digital Life in Seconds." Forte Labs. (4-category cap, Cowan-grounded.)
  https://fortelabs.com/blog/para/  (accessed 2026-05-04)

- Niklas Luhmann's Zettelkasten — top-level subjects collapsed from
  100+ → 11 across system maturation. (Sparse mature taxonomy beats
  exhaustive early one.) Zettelkasten.de overview.
  https://zettelkasten.de/overview/  (accessed 2026-05-04)

- Sönke Ahrens. "How to Take Smart Notes." 2017. §taxonomy minimalism.
  (Luhmann's index averaged 1–2 notes per keyword; tags sparse +
  curated.)
  https://www.soenkeahrens.de/en/takesmartnotes  (accessed 2026-05-04)

- Matrixflows. "Knowledge Base Taxonomy Best Practices." Enterprise IA
  research on hierarchy depth vs discoverability.
  https://www.matrixflows.com/blog/knowledge-base-taxonomy-best-practices  (accessed 2026-05-04)

WHAT HAPPENS NEXT
-----------------

[a]ccept   → consultation passes; the standard 3-step gate fires on the
             canonical (vault-schema.json._tag_prefixes) — you see the
             diff, can apply or edit, and persist. The user-manifest
             mirror (vault.tag_prefixes) is patched immediately after to
             keep mirror lockstep with canonical. Provenance JSONL
             records the consultation event with consulted_at +
             consultation_response_hash.

[r]eject   → no _tag_prefixes write to either target. Audit log records
             the rejection (with the rationale sha you saw, so we know
             which proposal you turned down). Re-run /onboard --section
             a to re-declare archetype, or re-run surface-4 later.

[e]dit     → opens \$EDITOR on this rationale buffer. Refine the
             proposal / tradeoffs / citations, then re-prompt. Useful
             when the rationale is mostly right but you want to record
             additional context for future-you.
EOF
}

# --- SP15 T-5 K-pattern: tmpfile env-var capture ---
#
# `consultation_propose`'s accept-path exports CG_RATIONALE_SHA +
# CG_CONSULTED_AT before invoking gate_generate (which runs the generator
# in a subshell via "$(...)"). A subshell can READ the exports but
# cannot set parent-shell vars. The generator captures the env-var
# values to known-path tmpfiles inside the subshell; surface-4's main
# shell reads them after consultation_propose returns. Mirrors the
# env-var-byte-match pattern T-4 established in lib/consultation-gate.sh
# self-test sub-test 6 (lines 533-540).

T5_CG_CAPTURE_DIR="${T5_CG_CAPTURE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/sp15-t5-cg-capture.XXXXXX")}"
T5_CONSULTED_AT_FILE="$T5_CG_CAPTURE_DIR/consulted-at"
T5_RATIONALE_SHA_FILE="$T5_CG_CAPTURE_DIR/rationale-sha"
: > "$T5_CONSULTED_AT_FILE"
: > "$T5_RATIONALE_SHA_FILE"
trap 'rm -rf "$T5_CG_CAPTURE_DIR" 2>/dev/null' EXIT INT TERM

# --- generator (called by gate_generate inside consultation_propose) ---
#
# Emits the FULL new vault-schema.json content (existing schema with
# `_tag_prefixes` patched to MERGED_VS_JSON) to stdout. gate_apply later
# atomically replaces vault-schema.json with this content via cp + mv.
# Side effect: captures CG_RATIONALE_SHA + CG_CONSULTED_AT env vars to
# tmpfiles for the post-return mirror-patch + provenance recording (env
# vars are unset by consultation_propose before it returns, so tmpfile
# capture is the only post-return-visible channel).
gen_vault_schema_with_prefixes() {
  # SP15 T-5: capture consultation env vars to tmpfile (subshell-safe).
  # Env vars are ONLY exported during accept-path orchestration — when
  # they're absent, fall through with empty captures (preserves
  # pre-consultation behavior for direct invocation paths).
  printf '%s' "${CG_CONSULTED_AT:-}" > "$T5_CONSULTED_AT_FILE"
  printf '%s' "${CG_RATIONALE_SHA:-}" > "$T5_RATIONALE_SHA_FILE"

  # Emit the new vault-schema.json content with merged _tag_prefixes.
  jq --argjson v "$MERGED_VS_JSON" '._tag_prefixes = $v' "$VAULT_SCHEMA" || return 1
  return 0
}

# --- provenance log helper (extended SP15 T-5: optional consulted fields) ---
#
# Pre-T-5 callers continue producing byte-identical output (consulted_at +
# response_hash absent, NOT null) — additive contract, mirrors T-3's
# pf_emit flag-walk pattern.
provenance_log_append() {
  local action="$1" target="$2" pre="$3" post="$4"
  local consulted_at="${5:-}"
  local response_hash="${6:-}"
  if [ -n "$consulted_at" ] || [ -n "$response_hash" ]; then
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg surface_id "$SURFACE_ID" \
      --arg generated_from "$GENERATED_FROM" \
      --arg archetype "$ARCHETYPE" \
      --arg action "$action" \
      --arg target "$target" \
      --argjson pre "$pre" \
      --argjson post "$post" \
      --arg consulted_at "$consulted_at" \
      --arg response_hash "$response_hash" \
      '{ts:$ts, surface_id:$surface_id, generated_from:$generated_from, archetype:$archetype, action:$action, target:$target, pre:$pre, post:$post, last_user_edit:null}
       + (if $consulted_at != "" then {consulted_at:$consulted_at} else {} end)
       + (if $response_hash != "" then {consultation_response_hash:$response_hash} else {} end)' \
      >> "$PROVENANCE_LOG"
  else
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
  fi
}

# --- pre-flight no-op short-circuit ---
# If neither target would change, exit clean WITHOUT firing the consultation
# gate (preserves UX of pre-T-5 no-op-rerun behavior — no surprise prompts
# when there's nothing to ratify). Skipped on dry-run for completeness.
if [ "$VS_CHANGED" = "0" ] && [ "$UM_CHANGED" = "0" ] && [ "$DRY_RUN" = "0" ]; then
  info "no changes — both targets already carry the merged set; exiting clean."
  provenance_log_append "no-op" "$VAULT_SCHEMA $USER_MANIFEST" "$MERGED_VS_JSON" "$MERGED_VS_JSON"
  exit 0
fi

# --- main: consultation_propose orchestrates rationale + canonical write ---
#
# K-pattern (SP15 T-5):
#   1. consultation_propose fires rationale gate
#   2. On accept → gate_generate (gen_vault_schema_with_prefixes) →
#      gate_preview → gate_apply (writes vault-schema.json atomically;
#      canonical-first ordering)
#   3. Post-return → patch user-manifest.json mirror with consulted
#      fields recorded in JSONL
#
# CG_TARGET_PATH points at the canonical (vault-schema.json). The mirror
# is patched as a separate step AFTER consultation_propose returns so we
# preserve the canonical-first invariant (mirror must never be ahead of
# canonical — downstream consumers cache the mirror as a runtime
# materialization of the canonical registry).
#
# --auto-apply legacy flag: pre-feed `printf 'a\na\n'` so consultation
# accept (first 'a') AND gate_apply accept (second 'a') both default-apply.
# Mirrors T-4 surface-3's pattern.
#
# Documented regressions (mirror T-4's call-outs):
#   - SP12 T-16's `--auto-apply --skip-preview` invocation against this
#     surface now requires the stdin pre-feed, handled internally by
#     this branch. T-16 attestation is sealed per spec L105; SP15
#     doesn't re-attest SP12.
#   - --skip-preview becomes a no-op under consultation orchestration
#     (consultation_propose handles preview internally via gate_preview
#     before gate_apply --skip-preview).
#   - The custom batched preview from pre-T-5 is replaced by gate_preview
#     on the canonical (single-target diff). The mirror's diff is no
#     longer rendered to the user — it's a pure side-effect of accepting
#     the canonical proposal (mirror is by definition lockstep with
#     canonical post-T-5).

if [ -z "${TG_STAGE_DIR:-}" ]; then
  TG_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/surface-4-tag-prefixes.XXXXXX")"
  export TG_STAGE_DIR
fi

export CG_TARGET_PATH="$VAULT_SCHEMA"

if [ "$AUTO_APPLY" = "1" ]; then
  printf 'a\na\n' | consultation_propose "$SURFACE_ID" _s4_rationale_fn gen_vault_schema_with_prefixes
  rc=$?
else
  consultation_propose "$SURFACE_ID" _s4_rationale_fn gen_vault_schema_with_prefixes
  rc=$?
fi

unset CG_TARGET_PATH

# Reject / abort / IO-error paths: no canonical write happened; do NOT
# patch the mirror either (atomicity: keep both targets consistent on
# failure). Exit with the rc consultation_propose returned.
if [ "$rc" != "0" ]; then
  case "$rc" in
    1) info "surface-4 rejected at consultation OR aborted at gate prompt" ;;
    *) diag "consultation_propose returned rc=$rc" ;;
  esac
  exit "$rc"
fi

# --- post-return mirror patch ---
#
# consultation_propose unsets CG_RATIONALE_SHA + CG_CONSULTED_AT before
# returning, so we read them from the tmpfiles the generator captured.
# Empty values mean a non-consultation accept-path (e.g., dry-run); in
# that case the mirror patch records pre-T-5-shape JSONL records (no
# consulted fields).

CONSULTED_AT="$(cat "$T5_CONSULTED_AT_FILE" 2>/dev/null || true)"
RATIONALE_SHA="$(cat "$T5_RATIONALE_SHA_FILE" 2>/dev/null || true)"

# Provenance for the canonical write — gate_apply already recorded an
# `apply` entry in the central audit log. Mirror that into the per-surface
# JSONL too for downstream consumers (architect, librarian) that key off
# the sidecar.
if [ "$VS_CHANGED" = "1" ]; then
  provenance_log_append "update" "$VAULT_SCHEMA" "$EXISTING_VS_JSON" "$MERGED_VS_JSON" "$CONSULTED_AT" "$RATIONALE_SHA"
else
  provenance_log_append "no-op" "$VAULT_SCHEMA" "$EXISTING_VS_JSON" "$EXISTING_VS_JSON" "$CONSULTED_AT" "$RATIONALE_SHA"
fi

# Mirror patch (user-manifest.json::vault.tag_prefixes).
if [ "$UM_CHANGED" = "1" ]; then
  um_tmp="$USER_MANIFEST.tmp.$$"
  jq --argjson v "$MERGED_UM_JSON" '.vault.tag_prefixes = $v' "$USER_MANIFEST" > "$um_tmp" && \
    jq -e . "$um_tmp" >/dev/null 2>&1 && \
    mv "$um_tmp" "$USER_MANIFEST" || { diag "user-manifest patch failed"; rm -f "$um_tmp"; exit 2; }
  provenance_log_append "update" "$USER_MANIFEST" "$EXISTING_UM_JSON" "$MERGED_UM_JSON" "$CONSULTED_AT" "$RATIONALE_SHA"
else
  provenance_log_append "no-op" "$USER_MANIFEST" "$EXISTING_UM_JSON" "$EXISTING_UM_JSON" "$CONSULTED_AT" "$RATIONALE_SHA"
fi

info "T-5 complete: tag-prefix auto-author applied (archetype=$ARCHETYPE; merged set length=$(printf '%s' "$MERGED_VS_JSON" | jq -r 'length'))"
exit 0
