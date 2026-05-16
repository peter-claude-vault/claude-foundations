#!/usr/bin/env bash
# onboarding/auto-author/surface-3-vault-claude-md.sh — SP12 T-6 + SP15 T-4
#
# Surface #3 — Auto-author the vault root CLAUDE.md (replaces SP07's thin
# identity-substituted skeleton with a generated artifact carrying:
#   - Routing Decision Tree (RDT) tuned to declared vault.organizational_method
#   - Tag taxonomy section keyed off declared _tag_prefixes (surface #4)
#   - Pre-write checklist tuned to declared canonical_file_types
#
# SP15 T-4 retrofit (2026-05-04): wraps the existing
# `gate_generate → gate_preview → gate_apply` chain with the SP15
# consultation gate. `consultation_propose` fires FIRST with a
# research-backed rationale (Forte PARA, Ahrens taxonomy minimalism,
# Cowan-4 working-memory cap, Matrixflows IA depth/discoverability)
# explaining the proposed vault.organizational_method. User can
# [a]ccept / [r]eject / [e]dit-rationale before any artifact is staged.
# On accept, the existing 3-step gate (now invoked from inside
# `consultation_propose`) fires unchanged.
#
# Provenance frontmatter prepended; `consulted_at` +
# `consultation_response_hash` are emitted on accept-path artifacts via
# CG_CONSULTED_AT / CG_RATIONALE_SHA env vars exported by
# consultation_propose (SP15 T-3 schema additivity contract).
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
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP12 Session 2 + SP15 Session 4 (T-4)

set -u

diag() { printf 'surface-3 FAIL: %s\n' "$1" >&2; }
info() { printf 'surface-3: %s\n' "$1"; }

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
TEMPLATE_PATH="${TEMPLATE_PATH:-$REPO_ROOT/templates/vault-claude-md-template.md}"
USER_MANIFEST="${USER_MANIFEST:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
VAULT_SCHEMA="${VAULT_SCHEMA:-${CLAUDE_HOME:-$HOME/.claude}/schemas/vault-schema.json}"
TARGET=""
# SP15 T-4: SURFACE_ID aligned to the consultation-gate allowlist entry
# (`lib/consultation-gate.allowlist`). Same identifier flows through (a)
# consultation_propose's audit-log `consult` records, (b) gate_generate /
# gate_preview / gate_apply records (via the staging filename basename),
# and (c) pf_emit's `generated_by` field on the produced artifact —
# unifying the surface identity across the audit log + provenance
# frontmatter for downstream consumers (architect, librarian, regen-paths).
SURFACE_ID="surface-3-vault-claude-md"
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

# USER-VOCAB SEED — consultant archetype onboarding reference (canonical §H)
# This RDT is specific to the Engagements/<client>/Projects/<project>/ folder pattern
# used by consultant-archetype adopters. It is NOT a foundation-canonical structure —
# it is a user-vocab seed populated at install time from the consultant archetype seed.
# Researcher, developer, and manager archetypes receive different RDT shapes via their
# own archetype seed branches (_rdt_para or custom). The folder names, tag prefixes,
# and routing rules declared here belong to the adopter's overlay-master, not the
# foundation governance pillars. See canonical §H (user-vocab vs foundation distinction)
# and governance/tagging-rules.json#taxonomy._adopter_extension_path.
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

# --- SP15 T-4: rationale function for the consultation gate ---
#
# Emits to stdout the full proposal + rationale block consultation_propose
# renders to the user before any artifact is staged. Pulls declared values
# (vault.organizational_method, top_level_folder, identity.role) from the
# user-manifest already loaded into the parent shell scope by mf_get above.
#
# Archetype detection is keyed off `vault.organizational_method` substring
# (matches `emit_rdt`'s case branches) — never off raw role text — so the
# rationale shape stays in lockstep with the actual RDT that will be
# written if the user accepts. No archetype crosstalk: each branch
# emits ONLY its archetype's reasoning.
#
# Citations (≥3 PKM/IA sources required by SP15 T-4 AC2):
#   - Tiago Forte, PARA Method (Forte Labs)
#   - Sönke Ahrens, How to Take Smart Notes §taxonomy minimalism
#   - Nelson Cowan, "The magical number 4" Behavioral and Brain Sciences (2001)
#   - Matrixflows, Knowledge-Base Taxonomy Best Practices
# All four URLs verified at SP15 T-4 ship time (2026-05-04). If any 404s
# at re-cite time, replace per spec L151 ("never silent-degrade to 'based
# on research'").

_s3_archetype_signal() {
  case "$ORG_METHOD" in
    *engagement*|*Engagement*|*ENGAGEMENT*) printf 'consultant' ;;
    *PARA*|*para*|*topic*|*Topic*|*project-based*|*Project-based*) printf 'researcher' ;;
    *)                                       printf 'custom' ;;
  esac
}

_s3_archetype_reasoning() {
  case "$(_s3_archetype_signal)" in
    consultant)
      cat <<EOF
Your declared role ("${ROLE}") and organizational_method ("${ORG_METHOD}")
signal a consultant / advisory archetype: work organized around external
clients with finite engagement durations, where each engagement carries
its own meetings, deliverables, stakeholders, and strategic context.

The Engagements layout (\`${TOP_LEVEL_FOLDER:-Engagements}/<engagement>/...\`) is
the proposed default because it MIRRORS your billing and accountability
structure: each engagement is a closed-world unit with its own people,
deadlines, and definition-of-done. Closing an engagement (set
\`status: complete|archived|closed\` on its Overview.md) tells the
librarian's stale-detect to stop probing it. Capture surfaces (Inbox,
Logs) stay engagement-agnostic at the vault root.

Tradeoff you're accepting: per-engagement folders deepen the hierarchy
by one level vs PARA's flat Projects/Areas split. The Cowan-4 cap below
applies to top-level structure only — within an engagement, you can
nest deeper because the working-memory load is scoped to the engagement
you're currently in.
EOF
      ;;
    researcher)
      cat <<EOF
Your declared organizational_method ("${ORG_METHOD}") signals a
research / writing / project-driven archetype: work organized around
discoverable categories rather than client-bound engagements.

The PARA-equivalent layout (top-level \`${TOP_LEVEL_FOLDER:-Projects}/\` or
\`Topics/\`, plus Areas/Resources/Archives as needed) is the proposed
default because it caps top-level structure at the categories that
match your discoverability needs. Forte's PARA method derives its
4-category cap from Cowan's working-memory research below — the same
principle Surface-4 will enforce on tag prefixes (≤9 cap).

Tradeoff you're accepting: cross-cutting work (a paper that spans two
topics, a project that produces both an essay and a dataset) requires
either duplication, symlinks, or wikilinks across categories — vs the
consultant archetype where everything for one client lives under one
folder. PARA-equivalents accept this in exchange for top-level
discoverability.
EOF
      ;;
    custom|*)
      cat <<EOF
Your declared organizational_method ("${ORG_METHOD}") doesn't match the
two pre-baked archetypes (Engagements / PARA-equivalent). The proposed
RDT will document your declared top-level folder
("\`${TOP_LEVEL_FOLDER:-(undeclared)}/\`") AS DECLARED rather than retrofit a
pattern that doesn't match how you actually work.

Tradeoff you're accepting: less guidance on routing edge-cases (Where
does a meeting note for a non-engagement live? Where does a build log
go?) — the generic RDT branch will surface these as user-judgment
moments rather than auto-routing them. If you'd rather pick one of
the pre-baked archetypes, [r]eject this proposal and re-run
\`/onboard --section c\` to re-declare with "engagement-based" or
"project-based" / "topic-based" / "para".
EOF
      ;;
  esac
}

_s3_rationale_fn() {
  cat <<EOF
PROPOSAL — Vault root CLAUDE.md
===============================

  Declared organizational_method:  "${ORG_METHOD}"
  Declared top-level folder:       "${TOP_LEVEL_FOLDER:-(undeclared)}"
  Declared role:                   "${ROLE}"

The vault root CLAUDE.md hardcodes a Routing Decision Tree (RDT) for
this vault. Every future Claude session, every capture-and-route, every
librarian audit follows the RDT shape this file declares. Choosing the
right shape now is materially cheaper than retrofitting later — schema
migration cost is documented at 50–70% of project effort once a
structure is in production (DataFlowMapper).

ARCHETYPE-EQUIVALENT LAYOUTS
----------------------------

These are not alternatives — each is the canonical layout for a different
adopter archetype. The system ships all three; the onboarder selects one
at install time based on the declared archetype.

1. Engagements layout (top-level Engagements/<cluster>/...)
   Archetype: consultant / services / advisory
   Organized around external clients with finite engagement durations.
   Closing an engagement is a first-class status transition.

2. PARA-equivalent layout (Projects/Areas/Resources/Archives, OR
   Topics-based for content-driven workflows)
   Archetype: researcher / writer / project-based knowledge worker
   Discoverable categories matter more than client boundaries. Forte's
   PARA caps top-level at 4 (Cowan-grounded).

3. Custom (user-named top_level_folder, generic RDT branch)
   Archetype: any workflow not matching a pre-baked archetype pattern
   The RDT documents what you declared rather than retrofitting a
   pattern that doesn't match.

WHY THIS PROPOSAL FOR YOU
-------------------------

$(_s3_archetype_reasoning)

TRADEOFFS YOU'RE ACCEPTING
--------------------------

- Discoverability vs flexibility: every additional hierarchy level
  reduces discoverability by ~50%; by 5 levels deep, 90%+ of users
  abandon search and fall back to keyword-only navigation. Top-level
  structure earns its place; below it, depth is paid for in
  discoverability cost (Matrixflows enterprise IA research).

- Working-memory cap on top-level structures: human short-term memory
  holds ~4 ± 1 chunks (Cowan 2001, replacing Miller's 7 ± 2). Top-level
  taxonomies that exceed this get navigated via search rather than
  browse, defeating the structure's purpose. PARA's 4-category cap and
  Surface-4's ≤9 tag-prefix cap are both grounded here.

- Curated taxonomy over exhaustive: Luhmann's mature Zettelkasten kept
  ~11 top-level categories despite having 90,000+ notes; index averaged
  1–2 notes per keyword (Ahrens, How to Take Smart Notes §taxonomy
  minimalism). Sparse, curated tags beat exhaustive coverage.

CITATIONS
---------

- Tiago Forte. "PARA Method: The Simple System for Organizing Your
  Digital Life in Seconds." Forte Labs.
  https://fortelabs.com/blog/para/  (accessed 2026-05-04)

- Sönke Ahrens. "How to Take Smart Notes." 2017. §taxonomy minimalism.
  https://www.soenkeahrens.de/en/takesmartnotes  (accessed 2026-05-04)

- Nelson Cowan. "The magical number 4 in short-term memory: A
  reconsideration of mental storage capacity." Behavioral and Brain
  Sciences, 24(1), 2001. (Replaces Miller 7±2; PARA's 4-category cap
  is justified on this.)
  https://www.cambridge.org/core/journals/behavioral-and-brain-sciences/article/abs/magical-number-4-in-shortterm-memory-a-reconsideration-of-mental-storage-capacity/44023F1147D4A1D44BABA6BCE2DE0B7C  (accessed 2026-05-04)

- Matrixflows. "Knowledge Base Taxonomy Best Practices."
  https://www.matrixflows.com/blog/knowledge-base-taxonomy-best-practices  (accessed 2026-05-04)

WHAT HAPPENS NEXT
-----------------

[a]ccept   → consultation passes; the existing 3-step gate fires
             (gate_generate → preview → apply). You see the staged
             vault CLAUDE.md, can edit at the preview step, and apply
             when satisfied. Frontmatter records consulted_at +
             consultation_response_hash so future librarian / architect
             passes can tell this was user-ratified vs auto-inferred.

[r]eject   → no vault CLAUDE.md is written. Audit log records the
             rejection (with the rationale sha you saw, so we know
             which proposal you turned down). Re-run /onboard --section c
             to re-declare with different values, or run surface-3
             again later when you're ready.

[e]dit     → opens \$EDITOR on this rationale buffer. Refine the
             tradeoffs / citations / archetype reasoning, then re-prompt.
             Useful when the rationale is mostly right but you want to
             record additional context for future-you.
EOF
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
  # 1. Provenance frontmatter.
  # SP15 T-4: when the consultation gate fired and accept-path is in
  # progress, consultation_propose has exported CG_RATIONALE_SHA +
  # CG_CONSULTED_AT into our environment. Forward both to pf_emit so
  # the artifact's frontmatter records the consultation event (T-3
  # schema fields). When env vars are unset (e.g., direct invocation
  # without consultation), pf_emit's output is byte-identical to
  # pre-T-3 — additivity contract preserved.
  # R-23: bash 3.2 + `set -u` rejects expanding an empty array with
  # `"${arr[@]}"`. Build the args array, then guard the call site on
  # ${#arr[@]} > 0.
  local pf_args
  pf_args=()
  if [ -n "${CG_CONSULTED_AT:-}" ]; then
    pf_args+=(--consulted-at "$CG_CONSULTED_AT")
  fi
  if [ -n "${CG_RATIONALE_SHA:-}" ]; then
    pf_args+=(--response-hash "$CG_RATIONALE_SHA")
  fi
  if [ ${#pf_args[@]} -gt 0 ]; then
    pf_emit "$SURFACE_ID" "$GENERATED_FROM" "${pf_args[@]}" || return 1
  else
    pf_emit "$SURFACE_ID" "$GENERATED_FROM" || return 1
  fi
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
  TG_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/surface-3-vault-claude-md.XXXXXX")"
  export TG_STAGE_DIR
fi

# SP15 T-4: route through the consultation gate. consultation_propose
# orchestrates gate_generate → gate_preview → gate_apply on the accept
# path; the rationale function explains the proposed organizational_method
# with research-backed citations BEFORE any artifact is staged. CG_TARGET_PATH
# tells the gate where to apply on accept (Session 1 design decision).
#
# --auto-apply legacy flag: pre-T-4 mapped to gate_apply --accept-on-empty-stdin.
# Under consultation orchestration there are now TWO prompts (consultation
# accept + apply confirm), so --auto-apply pre-feeds 'a\na\n' to stdin
# instead of plumbing a flag through. --skip-preview becomes a no-op
# under consultation (consultation_propose always passes --skip-preview
# to its inner gate_apply because gate_preview already fired). Documented
# regression: SP12 T-16 attestation is sealed (spec L105) and gets its
# own SP15 T-9 cross-cutting smoke; SP12 T-16 is no longer expected to
# pass post-T-4 against surface-3 without a stdin pre-feed shim.
export CG_TARGET_PATH="$TARGET"

if [ "$AUTO_APPLY" = "1" ]; then
  # First 'a' accepts the consultation rationale; second 'a' accepts
  # gate_apply's preview-then-apply prompt.
  printf 'a\na\n' | consultation_propose "$SURFACE_ID" _s3_rationale_fn gen_vault_claude_md
  rc=$?
else
  consultation_propose "$SURFACE_ID" _s3_rationale_fn gen_vault_claude_md
  rc=$?
fi

unset CG_TARGET_PATH

case "$rc" in
  0) info "surface-3 complete (target: $TARGET)" ;;
  1) info "surface-3 rejected at consultation OR aborted at gate prompt" ;;
  *) diag "consultation_propose returned rc=$rc" ;;
esac
exit "$rc"
