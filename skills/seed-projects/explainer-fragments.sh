#!/usr/bin/env bash
# explainer-fragments.sh — SP13 T-9 tag/frontmatter inline explainer.
#
# Sourceable bash 3.2 library. Provides three public functions consumed by
# seed.sh::print_batched_preview to render a "Why these tags + frontmatter?"
# explanatory block at the gate_preview surface BEFORE the per-file diff
# bundle (so the user reads what the tags/fields mean, then the diffs, then
# the "what happens next" UX, then the apply prompt).
#
# Each per-tag and per-field explainer is short (1-3 sentences) and CITES
# `docs/personalization-model.md` rather than re-declaring the universal /
# combined / personal classification framing — that doc is the single source
# of truth and this lib points to it.
#
# PUBLIC API:
#   emit_tag_explainer <tag>    — print a 1-3 sentence explainer for one tag
#                                  (handles #project, #engagement/<name>,
#                                  #scope/<x>, #research, #internal,
#                                  #meeting / #reference / #unclassified;
#                                  unknown tags get a generic citation
#                                  fallback).
#   emit_field_explainer <field> — print a 1-3 sentence explainer for one
#                                  frontmatter field (handles type, status,
#                                  audience, tags, generated_by,
#                                  generated_from, last_user_edit, title,
#                                  created; unknown fields are silent skip).
#   emit_full_block [stage_root] — print the full "Why these tags +
#                                  frontmatter?" section. When stage_root is
#                                  supplied and exists, scans staged files
#                                  for actual tags + fields and emits
#                                  explainers ONLY for what's present
#                                  (anchored to actual generated content per
#                                  spec L291). When omitted, falls back to
#                                  the union of all known tags + fields.
#
# OUTPUT: stdout. Callers redirect to >&2 if they want the block to land on
# the preview surface (seed.sh does).
#
# CONSTRAINTS (R-23): bash 3.2 — no `declare -A`, no `mapfile`, no
# `${var,,}`. `awk` (POSIX) and `find` REQUIRED.
#
# Author: Claude Opus 4.7 — Plan 71 SP13 Session 7

# Path to the personalization model doc, relative to repo root. Override
# via env if a downstream consumer needs an absolute path.
PERSONALIZATION_MODEL_DOC="${PERSONALIZATION_MODEL_DOC:-docs/personalization-model.md}"

# ----------------------------------------------------------------------
# emit_tag_explainer <tag>
# ----------------------------------------------------------------------
emit_tag_explainer() {
  local tag="$1"
  case "$tag" in
    "#project"|"#project/"*)
      cat <<EOF
- \`$tag\` — Marks this file as a project workspace. The \`librarian\`
  capability enumerates every \`#project\` (or \`#project/<name>\`) tag to
  build cross-project digests; \`architect\` uses it as the unit of analysis
  for drift detection. See \`$PERSONALIZATION_MODEL_DOC\` §2 (\`librarian\`
  + \`architect\` rows) for how project-scoped capabilities consume this tag.
EOF
      ;;
    "#engagement/"*)
      local _efx_eng="${tag#"#engagement/"}"
      cat <<EOF
- \`$tag\` — Groups this file under the \`$_efx_eng\` engagement cluster.
  The \`architect\` capability aggregates engagement-level signals (scope
  creep, stalled decisions, blocked dependencies) across every file carrying
  the same \`#engagement/*\` tag. See \`$PERSONALIZATION_MODEL_DOC\` §2
  \`architect\` row.
EOF
      ;;
    "#scope/"*)
      local _efx_axis="${tag#"#scope/"}"
      cat <<EOF
- \`$tag\` — Tags this file's scope axis (here: \`$_efx_axis\`). Used by your
  \`_tag_prefixes\` archetype to disambiguate when multiple projects share an
  engagement or workstream. See \`$PERSONALIZATION_MODEL_DOC\` §2
  \`vault.tag_prefixes[]\` row for archetype-keyed selection.
EOF
      ;;
    "#research")
      cat <<EOF
- \`$tag\` — Marks this engagement as research-track (vs delivery-track).
  Surfaces in \`architect\` research-topics rollups and contributes to the
  \`prior_seed[]\` namespace. See \`$PERSONALIZATION_MODEL_DOC\` §2
  \`architect.prior_seed[]\` + \`research_topics[]\` row.
EOF
      ;;
    "#internal")
      cat <<EOF
- \`$tag\` — Marks this engagement as internal-facing (vs client-facing).
  Audience-aware capabilities filter what surfaces in client-shareable
  digests on this signal. See \`$PERSONALIZATION_MODEL_DOC\` §2 (audience
  semantics) for how the tag interacts with the \`audience\` frontmatter
  field.
EOF
      ;;
    "#meeting"|"#reference"|"#unclassified")
      local _efx_kind="${tag#\#}"
      cat <<EOF
- \`$tag\` — Routing tag (kind: \`$_efx_kind\`). Set when an Inbox routing
  pass or T-10 disposition classifies the file; capabilities consume it to
  decide whether the artifact is project-bound or belongs to your reference
  / meeting / triage stream. See \`$PERSONALIZATION_MODEL_DOC\` §2 for
  disposition tag semantics.
EOF
      ;;
    *)
      cat <<EOF
- \`$tag\` — Carried through from your approved import plan. The full
  taxonomy is keyed off your declared \`_tag_prefixes\` archetype;
  capabilities that consume this tag are listed in
  \`$PERSONALIZATION_MODEL_DOC\` §2.
EOF
      ;;
  esac
}

# ----------------------------------------------------------------------
# emit_field_explainer <field>
# ----------------------------------------------------------------------
emit_field_explainer() {
  local field="$1"
  case "$field" in
    type)
      cat <<EOF
- \`type\` — Declares the artifact category (\`prd\`, \`context\`, \`updates\`).
  \`frontmatter-enforce.sh\` uses this to apply per-type required-fields
  validation; \`librarian\` filters index views by it. See
  \`$PERSONALIZATION_MODEL_DOC\` §2 \`frontmatter-enforce.sh\` row.
EOF
      ;;
    status)
      cat <<EOF
- \`status\` — Lifecycle state (\`active\` at scaffold time; bump to
  \`archived\` when the project closes). See \`$PERSONALIZATION_MODEL_DOC\`
  §5 re-generation semantics for how status interacts with regen.
EOF
      ;;
    audience)
      cat <<EOF
- \`audience\` — Who the artifact is written for (\`self\`, \`team\`, ...).
  Audience-aware capabilities filter accordingly. Defaults to your
  \`--audience\` flag at seed time. See \`$PERSONALIZATION_MODEL_DOC\` §2
  audience-semantics rows.
EOF
      ;;
    tags)
      cat <<EOF
- \`tags\` — YAML list of \`#tag\` strings. The full taxonomy is keyed off
  your \`_tag_prefixes\` archetype declared at onboarding. See
  \`$PERSONALIZATION_MODEL_DOC\` §2 \`vault.tag_prefixes[]\` row.
EOF
      ;;
    generated_by)
      cat <<EOF
- \`generated_by\` — Provenance: which auto-author surface produced this
  content (e.g., \`seed-projects@v2.0.0\`). Re-generation logic uses this to
  identify the upstream owner. See \`$PERSONALIZATION_MODEL_DOC\` §4 audit
  story.
EOF
      ;;
    generated_from)
      cat <<EOF
- \`generated_from\` — Provenance: the input source for this artifact
  (\`<candidate_id>/<label>\` from your approved import plan). Lets you
  trace back to the seeded source items that produced this content. See
  \`$PERSONALIZATION_MODEL_DOC\` §4.
EOF
      ;;
    last_user_edit)
      cat <<EOF
- \`last_user_edit\` — Provenance: ISO-timestamp of the most recent
  hand-edit, or \`null\` if untouched. When this exceeds the
  \`generated_by\` timestamp, regeneration treats the artifact as
  user-owned and SKIPS it. See \`$PERSONALIZATION_MODEL_DOC\` §5
  re-generation semantics + Mirror Collision Contract.
EOF
      ;;
    title)
      cat <<EOF
- \`title\` — Display name (defaults to \`candidate.label\` from your
  approved import plan). Edit freely; does not affect routing or capability
  behavior.
EOF
      ;;
    created)
      cat <<EOF
- \`created\` — Scaffold timestamp. Independent of \`generated_by\` (which
  carries the surface identity); used for chronological ordering in vault
  views.
EOF
      ;;
    *)
      # Unknown / unopinionated field: silent skip. Don't pollute the
      # explainer block with fields we have no documented semantics for.
      :
      ;;
  esac
}

# ----------------------------------------------------------------------
# emit_full_block [stage_root]
# ----------------------------------------------------------------------
emit_full_block() {
  local stage_root="${1:-}"

  printf '=== Why these tags + frontmatter? ===\n'
  printf 'Each generated file declares a small set of YAML frontmatter\n'
  printf 'fields and (typically) a `tags:` list. The notes below explain\n'
  printf 'what each tag and field means in the context of this Claude\n'
  printf 'Foundations install. The deeper classification framing\n'
  printf '(see \xc2\xa71) lives at `%s` —\n' "$PERSONALIZATION_MODEL_DOC"
  printf 'this preview cites that doc rather than rewriting it.\n\n'

  local tags
  if [ -n "$stage_root" ] && [ -d "$stage_root" ]; then
    tags=$(_efx_collect_tags "$stage_root")
  else
    tags=$(printf '#project\n#engagement/example\n#scope/example\n#research\n#internal\n')
  fi

  if [ -n "$tags" ]; then
    printf '### Tags\n\n'
    local _efx_tag
    while IFS= read -r _efx_tag; do
      [ -z "$_efx_tag" ] && continue
      emit_tag_explainer "$_efx_tag"
    done <<EOF
$tags
EOF
    printf '\n'
  fi

  local fields
  if [ -n "$stage_root" ] && [ -d "$stage_root" ]; then
    fields=$(_efx_collect_fields "$stage_root")
  else
    fields=$(printf 'type\nstatus\naudience\ntags\ngenerated_by\ngenerated_from\nlast_user_edit\ntitle\ncreated\n')
  fi

  if [ -n "$fields" ]; then
    printf '### Frontmatter fields\n\n'
    local _efx_field
    while IFS= read -r _efx_field; do
      [ -z "$_efx_field" ] && continue
      emit_field_explainer "$_efx_field"
    done <<EOF
$fields
EOF
    printf '\n'
  fi

  printf 'Capabilities referenced above (`librarian`, `architect`,\n'
  printf '`frontmatter-enforce.sh`) are documented in\n'
  printf '`%s` §2 with their inputs, tier\n' "$PERSONALIZATION_MODEL_DOC"
  printf 'classification, and re-generation semantics.\n'
  printf '=== end explainer ===\n'
}

# ----------------------------------------------------------------------
# Internal helpers
# ----------------------------------------------------------------------

# _efx_collect_tags <stage_root>
#   Walk every staged .md file's frontmatter `tags:` block; emit unique
#   tag-prefix representatives (one entry per prefix bucket; #engagement/a
#   and #engagement/b collapse to a single representative since the
#   per-tag explainer dispatches on prefix). Output: one tag per line.
_efx_collect_tags() {
  local stage_root="$1"
  find "$stage_root" -type f -name '*.md' -print0 2>/dev/null | \
    xargs -0 -I {} awk '
      BEGIN { in_fm=0; in_tags=0 }
      /^---[[:space:]]*$/ { in_fm = 1 - in_fm; in_tags = 0; next }
      in_fm && /^tags:[[:space:]]*$/ { in_tags = 1; next }
      in_fm && in_tags && /^[[:space:]]*-[[:space:]]+/ {
        line = $0
        sub(/^[[:space:]]*-[[:space:]]+/, "", line)
        gsub(/"/, "", line)
        sub(/[[:space:]]*$/, "", line)
        if (line != "") print line
        next
      }
      in_fm && in_tags && /^[^[:space:]]/ { in_tags = 0 }
    ' {} | _efx_dedupe_tag_prefixes
}

# _efx_dedupe_tag_prefixes (stdin → stdout)
#   Bucket tags by their first '/'-delimited segment so we explain each
#   prefix once. Preserves first-seen order.
_efx_dedupe_tag_prefixes() {
  awk '
    {
      raw = $0
      if (raw == "") next
      bucket = raw
      sub(/\/.*/, "", bucket)
      if (!(bucket in seen)) {
        seen[bucket] = raw
        order[++n] = bucket
      }
    }
    END {
      for (i = 1; i <= n; i++) print seen[order[i]]
    }
  '
}

# _efx_collect_fields <stage_root>
#   Walk every staged .md file's frontmatter; emit unique top-level field
#   names (in first-seen order across all staged files). Skips list-item
#   continuation lines (those starting with whitespace). Output: one field
#   per line.
_efx_collect_fields() {
  local stage_root="$1"
  find "$stage_root" -type f -name '*.md' -print0 2>/dev/null | \
    xargs -0 -I {} awk '
      BEGIN { in_fm = 0 }
      /^---[[:space:]]*$/ { in_fm = 1 - in_fm; next }
      in_fm && /^[A-Za-z_][A-Za-z0-9_]*:/ {
        key = $0
        sub(/:.*$/, "", key)
        print key
      }
    ' {} | awk '!seen[$0]++'
}
