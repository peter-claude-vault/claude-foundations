#!/usr/bin/env bash
# stage-2-5-consultation.sh — SP15 T-7 (Plan 71 SP15 Session 8)
#
# Stage 2.5 consultation gate inserted between SP13 T-6 (import-plan.sh) and
# SP13 T-7 (review-gate.sh). Surfaces the WHY of the proposed taxonomy
# (cluster count + confidence + alternatives + PKM/IA citations) BEFORE the
# user reviews the import plan. Two distinct gates by design: this gate
# covers consultation on the *taxonomy decision*; SP13 T-7 covers
# preview/edit/apply on the *generated import plan*.
#
# COMPOSITION (NEVER FORK):
#   stage-2-5-consultation.sh  →  lib/consultation-gate.sh::consultation_propose
#                                 (which sources onboarding/lib/three-step-gate.sh)
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - state/consulted-import-plan.md (only on consultation accept; T-6
#       import-plan.md content + 2 additive YAML frontmatter fields:
#       consulted_at + consultation_response_hash. Preserves the
#       import-plan/1 schema_version anchor for downstream T-7 review-gate.)
#     - $AUTO_AUTHOR_LOG (consult/accept|reject|edit records via
#       lib/consultation-gate.sh + generate/preview/apply records via
#       three-step-gate.sh)
#   Schema-types:
#     - Input: import-plan.md must carry ^schema_version: import-plan/1$.
#     - Templates: schemas/consultation-rationale-templates.json
#       (consultation-rationale-templates/1).
#     - Output: import-plan.md content + 2 additive frontmatter fields.
#       schema_version anchor preserved → T-7 review-gate accepts.
#   Pre-write validation:
#     - Input plan exists + schema_version anchor present
#     - Templates config exists + parseable + schema_version=consultation-rationale-templates/1
#     - consultation-gate.sh sourceable
#     - Templates carry an entry for $SURFACE_ID
#   Failure mode: BLOCK AND LOG.
#     - Missing/malformed input plan → rc=2 + clear error
#     - Missing/malformed templates → rc=2
#     - Missing consultation-gate library → rc=2
#     - Surface-id missing from templates → rc=2
#     - User reject → rc=1; consulted-import-plan.md NOT written
#     - User accept → rc=0; consulted-import-plan.md written atomically
#
# CONSTRAINTS (R-23): bash 3.2.57 — no `declare -A`, no `mapfile`,
# no `${var,,}`. `jq` REQUIRED on PATH. `python3` stdlib only (no pyyaml).
#
# Usage:
#   stage-2-5-consultation.sh [--import-plan PATH] [--out PATH]
#                             [--templates PATH] [--cg-lib PATH]
#                             [--auto-apply]
#
# Defaults:
#   --import-plan   <repo>/onboarding/seed-content/state/import-plan.md
#   --out           <repo>/onboarding/seed-content/state/consulted-import-plan.md
#   --templates     <repo>/schemas/consultation-rationale-templates.json
#   --cg-lib        <repo>/lib/consultation-gate.sh
#
# Test hooks: caller may export AUTO_AUTHOR_LOG / TG_STAGE_DIR /
# CG_ALLOWLIST_PATH / EDITOR / CLAUDE_HOME for hermetic isolation per
# feedback_test_isolation_for_hooks_state.
#
# Exit codes:
#   0   consultation accepted; consulted-import-plan.md written
#   1   consultation rejected
#   2   pre-flight failure or library/IO error
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP15 Session 8 (T-7)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEFAULT_INPUT_PLAN="$REPO_ROOT/onboarding/seed-content/state/import-plan.md"
DEFAULT_OUT="$REPO_ROOT/onboarding/seed-content/state/consulted-import-plan.md"
DEFAULT_TEMPLATES="$REPO_ROOT/schemas/consultation-rationale-templates.json"
DEFAULT_CG_LIB="$REPO_ROOT/lib/consultation-gate.sh"

INPUT_PLAN="$DEFAULT_INPUT_PLAN"
OUT="$DEFAULT_OUT"
TEMPLATES="$DEFAULT_TEMPLATES"
CG_LIB="$DEFAULT_CG_LIB"
AUTO_APPLY=0

SURFACE_ID="sp13-stage-2-5-import-plan"
TEMPLATES_SCHEMA_VERSION="consultation-rationale-templates/1"
INPUT_SCHEMA_VERSION="import-plan/1"

usage() {
  cat <<EOF
stage-2-5-consultation.sh — SP15 T-7 Stage 2.5 consultation gate.

Usage:
  stage-2-5-consultation.sh [--import-plan PATH] [--out PATH]
                            [--templates PATH] [--cg-lib PATH]
                            [--auto-apply]

Defaults:
  --import-plan   $DEFAULT_INPUT_PLAN
  --out           $DEFAULT_OUT
  --templates     $DEFAULT_TEMPLATES
  --cg-lib        $DEFAULT_CG_LIB

Flags:
  --auto-apply    pre-feed accept/accept to the consultation + 3-step gate
                  (smoke tests, automated runs).

Exit codes:
  0   consultation accepted; consulted-import-plan.md written
  1   consultation rejected
  2   pre-flight failure or library/IO error
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --import-plan|--input)
      shift
      [ $# -gt 0 ] || { echo "stage-2-5-consultation.sh: --import-plan requires a path" >&2; exit 2; }
      INPUT_PLAN="$1"; shift ;;
    --out)
      shift
      [ $# -gt 0 ] || { echo "stage-2-5-consultation.sh: --out requires a path" >&2; exit 2; }
      OUT="$1"; shift ;;
    --templates)
      shift
      [ $# -gt 0 ] || { echo "stage-2-5-consultation.sh: --templates requires a path" >&2; exit 2; }
      TEMPLATES="$1"; shift ;;
    --cg-lib)
      shift
      [ $# -gt 0 ] || { echo "stage-2-5-consultation.sh: --cg-lib requires a path" >&2; exit 2; }
      CG_LIB="$1"; shift ;;
    --auto-apply)
      AUTO_APPLY=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "stage-2-5-consultation.sh: unknown arg: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

# ----- pre-flight 1: dependencies -----

if ! command -v jq >/dev/null 2>&1; then
  echo "stage-2-5-consultation.sh: jq required on PATH" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "stage-2-5-consultation.sh: python3 required on PATH" >&2
  exit 2
fi

# ----- pre-flight 2: input plan exists + schema_version anchor -----

if [ ! -f "$INPUT_PLAN" ]; then
  cat <<EOF >&2
stage-2-5-consultation.sh: input plan not found: $INPUT_PLAN

Run T-6 import-plan.sh first to generate the import plan from the upstream
T-5 propose-taxonomy-output.json. Stage 2.5 consults on T-6's output before
T-7 review-gate consumes it.
EOF
  exit 2
fi

if ! grep -q "^schema_version: ${INPUT_SCHEMA_VERSION}$" "$INPUT_PLAN"; then
  cat <<EOF >&2
stage-2-5-consultation.sh: input plan schema_version mismatch (expected ${INPUT_SCHEMA_VERSION}).
  Path: $INPUT_PLAN
This file does not appear to be a valid T-6 import plan. Stage 2.5 refuses
to consult on non-conformant plans. Re-run T-6 import-plan.sh first to
regenerate.
EOF
  exit 2
fi

# ----- pre-flight 3: templates config exists + parseable + schema_version -----

if [ ! -f "$TEMPLATES" ]; then
  echo "stage-2-5-consultation.sh: templates config not found: $TEMPLATES" >&2
  exit 2
fi
if ! jq -e . "$TEMPLATES" >/dev/null 2>&1; then
  echo "stage-2-5-consultation.sh: templates config is not valid JSON: $TEMPLATES" >&2
  exit 2
fi
TEMPLATES_VER="$(jq -r '.schema_version // ""' "$TEMPLATES")"
if [ "$TEMPLATES_VER" != "$TEMPLATES_SCHEMA_VERSION" ]; then
  echo "stage-2-5-consultation.sh: templates schema_version mismatch (expected ${TEMPLATES_SCHEMA_VERSION}, got '${TEMPLATES_VER}')" >&2
  exit 2
fi
if ! jq -e --arg sid "$SURFACE_ID" '.templates[$sid]' "$TEMPLATES" >/dev/null 2>&1; then
  echo "stage-2-5-consultation.sh: templates config has no entry for surface-id '$SURFACE_ID'" >&2
  exit 2
fi

# ----- pre-flight 4: consultation-gate library exists + sourceable -----

if [ ! -f "$CG_LIB" ]; then
  echo "stage-2-5-consultation.sh: consultation-gate library not found: $CG_LIB" >&2
  exit 2
fi
# shellcheck disable=SC1090
. "$CG_LIB"

# ----- frontmatter extraction (python3 stdlib; no pyyaml dep) -----
# Extracts a flat key→string map from the leading YAML frontmatter block.
# Handles the wrapper shape rendered by SP13 T-6 import-plan.py — flat
# scalars at depth 0 (schema_version, generated_at) plus a nested `header`
# dict whose scalars we flatten with a `header.` prefix. The full wrapper
# carries vault_tree + unclassified_callout subtrees that we ignore (we
# only need corpus stats for the rationale render).
_parse_frontmatter() {
  python3 - "$INPUT_PLAN" <<'PY'
import sys, re, json
p = sys.argv[1]
with open(p, 'r') as f:
    data = f.read()
m = re.match(r'^---\n(.*?)\n---\n', data, re.DOTALL)
if not m:
    sys.stderr.write("stage-2-5-consultation.sh: leading frontmatter not found in input plan\n")
    sys.exit(2)
fm = m.group(1)
out = {}
# Walk lines tracking 2-space indent depth. Key:value at depth 0 → out[key].
# Key: at depth 0 followed by indented children → walk children with `key.` prefix.
# Stop walking subtrees we don't care about (vault_tree, unclassified_callout).
SKIP_PREFIXES = ("vault_tree", "unclassified_callout")
lines = fm.split("\n")
i = 0
while i < len(lines):
    line = lines[i]
    sl = line.lstrip()
    if not sl or sl.startswith("#"):
        i += 1
        continue
    indent = len(line) - len(sl)
    if indent != 0:
        i += 1
        continue
    if ":" not in sl:
        i += 1
        continue
    k, _, v = sl.partition(":")
    k = k.strip()
    v = v.strip()
    if k in SKIP_PREFIXES:
        # Skip this line + all indented continuation.
        i += 1
        while i < len(lines):
            nxt = lines[i]
            if not nxt:
                i += 1
                continue
            nxt_indent = len(nxt) - len(nxt.lstrip())
            if nxt_indent == 0 and nxt.lstrip():
                break
            i += 1
        continue
    if v != "" and v != "{}" and v != "[]":
        out[k] = v
        i += 1
        continue
    # Empty value → walk indented children with `k.` prefix.
    i += 1
    while i < len(lines):
        nxt = lines[i]
        nxt_sl = nxt.lstrip()
        if not nxt_sl or nxt_sl.startswith("#"):
            i += 1
            continue
        nxt_indent = len(nxt) - len(nxt_sl)
        if nxt_indent == 0:
            break
        if ":" in nxt_sl:
            ck, _, cv = nxt_sl.partition(":")
            ck = ck.strip()
            cv = cv.strip()
            if cv != "" and cv != "{}" and cv != "[]":
                out[k + "." + ck] = cv
        i += 1
print(json.dumps(out))
PY
}

_FM_JSON="$(_parse_frontmatter)" || {
  echo "stage-2-5-consultation.sh: failed to parse import-plan.md frontmatter" >&2
  exit 2
}

_fm_get() {
  printf '%s\n' "$_FM_JSON" | jq -r --arg k "$1" '.[$k] // ""'
}

# ----- rationale function -----
# Composes rationale text from templates config + dynamic per-run data
# extracted from the import-plan.md frontmatter. The static blocks
# (preamble, tradeoffs, citations) are read from $TEMPLATES so adopters
# can edit them without forking this script (D2 of the build decision).
_s13_25_rationale_fn() {
  local n_records n_clusters n_passes items_mapped_pct llm_mode generated_at
  local schema_v
  schema_v="$(_fm_get schema_version)"
  generated_at="$(_fm_get generated_at)"
  n_records="$(_fm_get header.n_records)"
  n_clusters="$(_fm_get header.n_clusters)"
  n_passes="$(_fm_get header.n_passes)"
  items_mapped_pct="$(_fm_get header.items_mapped_pct)"
  llm_mode="$(_fm_get header.llm_mode)"

  local preamble tradeoffs
  preamble="$(jq -r --arg sid "$SURFACE_ID" '.templates[$sid].preamble' "$TEMPLATES")"
  tradeoffs="$(jq -r --arg sid "$SURFACE_ID" '.templates[$sid].tradeoffs' "$TEMPLATES")"

  printf 'PROPOSAL — Ratify the rationale behind the proposed taxonomy.\n'
  printf 'Surface: %s\n' "$SURFACE_ID"
  printf 'Input plan: %s\n' "$INPUT_PLAN"
  printf 'Plan generated_at: %s\n' "${generated_at:-?}"
  printf '\n'

  printf 'PREAMBLE\n--------\n'
  printf '%s\n' "$preamble"
  printf '\n'

  printf 'CORPUS STATS (from T-6 import-plan.md frontmatter)\n'
  printf '%s\n' '--------------------------------------------------'
  printf '%s\n' "- input plan schema_version: ${schema_v:-?}"
  printf '%s\n' "- source records ingested: ${n_records:-?}"
  printf '%s\n' "- clusters identified by upstream embedding pass: ${n_clusters:-?}"
  printf '%s\n' "- LLM passes run: ${n_passes:-?} (mode: ${llm_mode:-?})"
  printf '%s\n' "- items_mapped_pct: ${items_mapped_pct:-?}"
  printf '\n'

  printf 'TRADEOFFS\n---------\n'
  printf '%s\n' "$tradeoffs"
  printf '\n'

  printf 'CITATIONS (research-backed grounding)\n'
  printf '%s\n' '--------------------------------------'
  jq -r --arg sid "$SURFACE_ID" '
    .templates[$sid].citations[]
    | "- \(.author) (\(.year)). \(.title)\n  URL: \(.url)\n  Claim: \(.claim)"
  ' "$TEMPLATES"
  printf '\n'

  printf 'WHAT HAPPENS NEXT\n----------------\n'
  printf 'On [a]ccept → Stage 2.5 ships state/consulted-import-plan.md (T-6\n'
  printf '              content + consulted_at + consultation_response_hash).\n'
  printf '              You then run review-gate.sh against the consulted plan.\n'
  printf 'On [r]eject → no consulted plan written. Re-run T-6 (or upstream\n'
  printf '              T-4/T-5) if you want a different taxonomy.\n'
  printf 'On [e]dit   → open $EDITOR on this rationale buffer; loops back to\n'
  printf '              the prompt with your edits applied.\n'
}

# ----- generator function -----
# Emits T-6 import-plan.md content with consultation provenance fields
# injected into the YAML frontmatter. Reads CG_RATIONALE_SHA +
# CG_CONSULTED_AT exported by consultation_propose accept-path. Additive:
# the import-plan/1 schema_version line is preserved verbatim → downstream T-7
# review-gate.sh's `grep -q '^schema_version: import-plan/1$'` continues to
# match.
_s13_25_generator_fn() {
  python3 - "$INPUT_PLAN" "${CG_CONSULTED_AT:-}" "${CG_RATIONALE_SHA:-}" <<'PY'
import sys
input_plan = sys.argv[1]
consulted_at = sys.argv[2]
response_hash = sys.argv[3]
import re
with open(input_plan, 'r') as f:
    data = f.read()
m = re.match(r'^(---\n)(.*?)(\n---\n)(.*)', data, re.DOTALL)
if not m:
    sys.stderr.write("stage-2-5-consultation.sh: leading frontmatter not found in input plan\n")
    sys.exit(2)
opener, body_fm, closer, rest = m.group(1), m.group(2), m.group(3), m.group(4)
extra = []
if consulted_at:
    extra.append("consulted_at: " + consulted_at)
if response_hash:
    extra.append("consultation_response_hash: " + response_hash)
if extra:
    new_fm = body_fm + "\n" + "\n".join(extra)
else:
    new_fm = body_fm
sys.stdout.write(opener + new_fm + closer + rest)
PY
}

# ----- orchestrate -----

mkdir -p "$(dirname "$OUT")"
export CG_TARGET_PATH="$OUT"

if [ "$AUTO_APPLY" = "1" ]; then
  printf 'a\na\n' | consultation_propose "$SURFACE_ID" _s13_25_rationale_fn _s13_25_generator_fn
  RC=$?
else
  consultation_propose "$SURFACE_ID" _s13_25_rationale_fn _s13_25_generator_fn
  RC=$?
fi

unset CG_TARGET_PATH
exit "$RC"
