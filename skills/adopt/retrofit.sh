#!/usr/bin/env bash
# retrofit.sh — SP13 T-13 `--retrofit-existing` orchestrator.
#
# Closes the SP08 v2.1-deferred /adopt --retrofit-existing surface (previously
# exit 22). Walks an existing populated vault as IR source for Stage 1 and 2,
# augments the import plan with a collision matrix appendix, runs the SP15
# Stage 2.5 consultation gate (when present), invokes the existing T-7
# review-gate, and on apply runs T-8 seed.sh + T-10 inbox-disposition.sh
# against the FILTERED taxonomy (truly-new candidates only).
#
# Reuses existing scripts UNMODIFIED:
#   T-3 ir-builder.sh          (IR construction from intake manifest)
#   T-4 cluster.sh             (embedding cluster)
#   T-5 propose-taxonomy.sh    (LLM-proposed candidate types + paths)
#   T-6 import-plan.sh         (markdown plan rendering)
#   SP15 stage-2-5-consultation.sh  (Stage 2.5 consultation gate, if present)
#   T-7 review-gate.sh         (user [a/e/s/b] gate over import plan)
#   T-8 seed.sh                (PRD/Context/Updates scaffolder)
#   T-10 inbox-disposition.sh  (non-project routing)
#
# Retrofit-specific layers:
#   1. Intake walker (in this script): walks vault tree honoring .seedignore;
#      filters out files already carrying generated_by: retrofit@* in head 20
#      lines (idempotency check); emits intake manifest for ir-builder.sh.
#   2. retrofit-prefilter.py: drops already-scaffolded candidates; annotates
#      candidates with retrofit-action enum (scaffold|keep|move-to|inbox|review).
#   3. retrofit-collision-matrix.sh: appends collision-matrix section to
#      import-plan.md (paginated at 50 rows).
#
# Usage (called by adopt.sh when --retrofit-existing is passed):
#   retrofit.sh --vault-root PATH [POSITIONAL_PATH] [--dry-run] \
#               [--retrofit-cap N] [--retrofit-keep-threshold F] \
#               [--seed-batch-cap N] [--audience SELF|...]
#
# POSITIONAL_PATH: when supplied, scopes retrofit to a sub-tree (must be
# under vault-root). Default: vault-root.
#
# Exit codes:
#   0   success (apply OR dry-run OR skip)
#   1   user abort at gate
#   2   pre-flight or pipeline failure
#   3   retrofit cap exceeded (refusal with guidance)
#
# CONSTRAINTS (R-23): bash 3.2 — no `declare -A`, no `mapfile`, no `${var,,}`.
# `jq`, `python3`, `find`, `grep` REQUIRED on PATH.
#
# OUTPUT CONTRACT (R-43):
#   Files written:
#     - $WORK_DIR/intake-manifest.jsonl     (retrofit-specific intake)
#     - $WORK_DIR/ir.jsonl                  (T-3 IR)
#     - $WORK_DIR/cluster-output.json       (T-4)
#     - $WORK_DIR/propose-taxonomy-output.json  (T-5)
#     - $WORK_DIR/retrofit-filtered-taxonomy.json (sp13-t5/1; retrofit-prefilter)
#     - $WORK_DIR/retrofit-matrix.json      (sp13-t13/1; retrofit-prefilter)
#     - $WORK_DIR/import-plan.md            (T-6 + collision matrix appendix)
#     - $WORK_DIR/idempotency-skip.list     (newline-separated; populated by intake)
#     - vault writes (Stage 3): only on user [a]pply; only for truly-new candidates.
#   Schema-types: documented per file inline.
#   Pre-write validation: vault-root must be a directory; sub-tree must be
#     under vault-root; cap check pre-Stage-1.
#   Failure mode: BLOCK AND LOG.
#
# Author: Claude Opus 4.7 — Plan 71 SP13 Session 11 (T-13).

set -u

RETROFIT_VERSION="v2.1.0"
DEFAULT_CAP=500
DEFAULT_KEEP_THRESHOLD="0.8"
DEFAULT_BATCH_CAP=100

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ONBOARDING_DIR="$REPO_ROOT/onboarding"
INFER_DIR="$REPO_ROOT/skills/infer-vault-structure"
SEED_DIR="$REPO_ROOT/skills/seed-projects"

DEFAULT_INTAKE_FILTER="$ONBOARDING_DIR/seed-content/seedignore-filter.sh"
DEFAULT_IR_BUILDER="$ONBOARDING_DIR/seed-content/ir-builder.sh"
DEFAULT_CLUSTER="$INFER_DIR/cluster.sh"
DEFAULT_PROPOSE="$INFER_DIR/propose-taxonomy.sh"
DEFAULT_IMPORT_PLAN="$INFER_DIR/import-plan.sh"
DEFAULT_REVIEW_GATE="$INFER_DIR/review-gate.sh"
DEFAULT_STAGE_2_5="$INFER_DIR/stage-2-5-consultation.sh"
DEFAULT_SEED_SH="$SEED_DIR/seed.sh"
DEFAULT_PREFILTER="$SCRIPT_DIR/retrofit-prefilter.py"
DEFAULT_MATRIX_SH="$SCRIPT_DIR/retrofit-collision-matrix.sh"

VAULT_ROOT=""
SUB_PATH=""
DRY_RUN=0
RETROFIT_CAP="$DEFAULT_CAP"
KEEP_THRESHOLD="$DEFAULT_KEEP_THRESHOLD"
BATCH_CAP="$DEFAULT_BATCH_CAP"
AUDIENCE="self"
WORK_DIR=""
EMBEDDING_MODE="auto"
LLM_MODE="auto"
ACCEPT_ON_EOF="${RETROFIT_ACCEPT_ON_EOF:-0}"

usage() {
  cat <<EOF
retrofit.sh — SP13 T-13 /adopt --retrofit-existing orchestrator.

Usage:
  retrofit.sh --vault-root PATH [POSITIONAL_PATH] [OPTIONS]

Required:
  --vault-root PATH         Vault root (writes will land relative to here).

Positional:
  POSITIONAL_PATH           Optional sub-tree under vault-root to scope the
                            retrofit. Default: walk entire vault-root.

Options:
  --dry-run                 Run Stages 1+2 + render collision matrix to
                            stdout. Skip Stage 2.5 consultation, T-7 gate,
                            and Stage 3 entirely. No writes outside \$WORK_DIR.
  --retrofit-cap N          Refuse if walked corpus exceeds N records
                            (default: $DEFAULT_CAP). Forces sub-tree scoping
                            on large vaults.
  --retrofit-keep-threshold F
                            Modal-parent ratio above which reference/meeting
                            candidates are 'keep' rather than 'move-to'
                            (default: $DEFAULT_KEEP_THRESHOLD).
  --seed-batch-cap N        Per-batch IR cap (default: $DEFAULT_BATCH_CAP).
  --audience SELF|TEAM|...  Audience field for SP12 provenance (default: self).
  --work-dir PATH           Override staging dir (default: mktemp).
  --embedding-mode MODE     stub|voyage|auto (default: auto).
  --llm-mode MODE           stub|live|auto (default: auto).
  --accept-on-eof           Treat stdin EOF as 'apply' at gate (smoke tests).
  --help                    This message.

Exit codes:
  0   success (apply / dry-run / skip)
  1   user abort
  2   pre-flight or pipeline failure
  3   retrofit cap exceeded
EOF
}

# ----- argv parse -----

# First pass: pull out flags. Anything not starting with -- is the positional.
POSITIONAL_ARGS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --vault-root)
      shift
      [ $# -gt 0 ] || { echo "retrofit.sh: --vault-root requires a path" >&2; exit 2; }
      VAULT_ROOT="$1"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --retrofit-cap)
      shift
      [ $# -gt 0 ] || { echo "retrofit.sh: --retrofit-cap requires N" >&2; exit 2; }
      RETROFIT_CAP="$1"
      ;;
    --retrofit-keep-threshold)
      shift
      [ $# -gt 0 ] || { echo "retrofit.sh: --retrofit-keep-threshold requires F" >&2; exit 2; }
      KEEP_THRESHOLD="$1"
      ;;
    --seed-batch-cap)
      shift
      [ $# -gt 0 ] || { echo "retrofit.sh: --seed-batch-cap requires N" >&2; exit 2; }
      BATCH_CAP="$1"
      ;;
    --audience)
      shift
      [ $# -gt 0 ] || { echo "retrofit.sh: --audience requires a value" >&2; exit 2; }
      AUDIENCE="$1"
      ;;
    --work-dir)
      shift
      [ $# -gt 0 ] || { echo "retrofit.sh: --work-dir requires a path" >&2; exit 2; }
      WORK_DIR="$1"
      ;;
    --embedding-mode)
      shift
      [ $# -gt 0 ] || { echo "retrofit.sh: --embedding-mode requires a mode" >&2; exit 2; }
      EMBEDDING_MODE="$1"
      ;;
    --llm-mode)
      shift
      [ $# -gt 0 ] || { echo "retrofit.sh: --llm-mode requires a mode" >&2; exit 2; }
      LLM_MODE="$1"
      ;;
    --accept-on-eof)
      ACCEPT_ON_EOF=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "retrofit.sh: unknown flag: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      # Positional. Only one allowed.
      if [ -n "$POSITIONAL_ARGS" ]; then
        echo "retrofit.sh: only one positional path allowed (sub-tree scope)" >&2
        exit 2
      fi
      POSITIONAL_ARGS="$1"
      ;;
  esac
  shift
done

# ----- pre-flight -----

if [ -z "$VAULT_ROOT" ]; then
  echo "retrofit.sh: --vault-root is required" >&2
  exit 2
fi
if [ ! -d "$VAULT_ROOT" ]; then
  echo "retrofit.sh: vault-root not a directory: $VAULT_ROOT" >&2
  exit 2
fi

# Resolve absolute path for vault-root.
VAULT_ROOT_ABS=$(cd "$VAULT_ROOT" && pwd)

# Determine source (vault-root OR sub-tree).
if [ -n "$POSITIONAL_ARGS" ]; then
  # Resolve sub-tree: if absolute, use as-is; if relative, treat as vault-relative.
  case "$POSITIONAL_ARGS" in
    /*) SUB_PATH="$POSITIONAL_ARGS" ;;
    *)  SUB_PATH="$VAULT_ROOT_ABS/$POSITIONAL_ARGS" ;;
  esac
  if [ ! -d "$SUB_PATH" ]; then
    echo "retrofit.sh: sub-tree not a directory: $SUB_PATH" >&2
    exit 2
  fi
  SUB_PATH_ABS=$(cd "$SUB_PATH" && pwd)
  # Sub-tree must be under vault-root.
  case "$SUB_PATH_ABS" in
    "$VAULT_ROOT_ABS"|"$VAULT_ROOT_ABS"/*) ;;
    *)
      echo "retrofit.sh: sub-tree $SUB_PATH_ABS is not under vault-root $VAULT_ROOT_ABS" >&2
      exit 2
      ;;
  esac
  SOURCE="$SUB_PATH_ABS"
else
  SOURCE="$VAULT_ROOT_ABS"
fi

# Cap validation.
case "$RETROFIT_CAP" in
  ''|*[!0-9]*)
    echo "retrofit.sh: --retrofit-cap must be a positive integer" >&2
    exit 2
    ;;
esac
[ "$RETROFIT_CAP" -gt 0 ] || { echo "retrofit.sh: --retrofit-cap must be > 0" >&2; exit 2; }

# Required helpers.
for tool in jq python3 find grep; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "retrofit.sh: missing required tool on PATH: $tool" >&2
    exit 2
  fi
done

for f in "$DEFAULT_IR_BUILDER" "$DEFAULT_CLUSTER" "$DEFAULT_PROPOSE" \
         "$DEFAULT_IMPORT_PLAN" "$DEFAULT_PREFILTER" "$DEFAULT_MATRIX_SH"; do
  if [ ! -f "$f" ]; then
    echo "retrofit.sh: required helper missing: $f" >&2
    exit 2
  fi
done

# ----- staging dir -----

if [ -z "$WORK_DIR" ]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/retrofit.XXXXXX")"
fi
mkdir -p "$WORK_DIR"

INTAKE_MANIFEST="$WORK_DIR/intake-manifest.jsonl"
IR_FILE="$WORK_DIR/ir.jsonl"
CLUSTER_OUT="$WORK_DIR/cluster-output.json"
PROPOSE_OUT="$WORK_DIR/propose-taxonomy-output.json"
FILTERED_TAXONOMY="$WORK_DIR/retrofit-filtered-taxonomy.json"
MATRIX_JSON="$WORK_DIR/retrofit-matrix.json"
IMPORT_PLAN="$WORK_DIR/import-plan.md"
APPROVED_PLAN="$WORK_DIR/approved-import-plan.md"
IDEMPOTENCY_SKIP="$WORK_DIR/idempotency-skip.list"

: > "$INTAKE_MANIFEST"
: > "$IDEMPOTENCY_SKIP"

# ----- Stage 0: walk + idempotency filter -----
#
# Build the intake manifest directly (bypassing intake.sh) because retrofit's
# intake semantics differ: (a) limit to known text formats only (we can't
# reasonably retrofit binaries); (b) apply idempotency filter (skip files
# carrying generated_by: retrofit@* in head 20 lines).

# Detect already-retrofitted files. Use grep with line-count cap to bound
# IO on large files (head -20 + grep is safer than full-file grep on a
# multi-GB log file the user accidentally dropped in vault).
is_retrofit_stamped() {
  # $1 = file path; returns 0 if file's first 20 lines contain
  # `^generated_by: retrofit@`.
  head -20 "$1" 2>/dev/null | grep -q '^generated_by: retrofit@'
}

# Walk source for known text formats. Mirror seed-content/format-detector.sh's
# extension list.
EXT_PATTERNS='-name "*.md" -o -name "*.txt" -o -name "*.markdown" -o -name "*.vtt"'

# Apply seedignore-filter when present. Cleanly mirrors intake.sh:67 semantics.
SEEDIGNORE_FILTER=""
if [ -f "$DEFAULT_INTAKE_FILTER" ] && [ -f "$SOURCE/.seedignore" ]; then
  SEEDIGNORE_FILTER="$DEFAULT_INTAKE_FILTER"
fi

emit_intake_record() {
  # $1 = path, $2 = size_bytes
  jq -nc --arg path "$1" --argjson size "$2" --arg st "file" \
    '{path: $path, size_bytes: $size, source_type: $st}' >> "$INTAKE_MANIFEST"
}

n_walked=0
n_skipped=0
n_retained=0

# Use eval-free find invocation (bash 3.2 + R-23: no `eval` on user input).
# We accept the limited set of extensions as fixed for retrofit MVP.
find_walk() {
  find "$SOURCE" -type f \
    \( -name "*.md" -o -name "*.txt" -o -name "*.markdown" -o -name "*.vtt" \) \
    -print
}

if [ -n "$SEEDIGNORE_FILTER" ]; then
  walked_list=$(find_walk | bash "$SEEDIGNORE_FILTER" --root "$SOURCE")
else
  walked_list=$(find_walk)
fi

# Process walked list. Use a temp file to pipe through (bash 3.2 + while-read
# in subshell loses counter increments via pipe).
WALKED_TMP="$WORK_DIR/walked.list"
printf '%s' "$walked_list" > "$WALKED_TMP"
[ -s "$WALKED_TMP" ] && [ "$(tail -c 1 "$WALKED_TMP")" != "" ] && printf '\n' >> "$WALKED_TMP"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  n_walked=$((n_walked + 1))
  if is_retrofit_stamped "$f"; then
    printf '%s\n' "$f" >> "$IDEMPOTENCY_SKIP"
    n_skipped=$((n_skipped + 1))
    continue
  fi
  sz=$(wc -c < "$f" | tr -d ' ')
  emit_intake_record "$f" "$sz"
  n_retained=$((n_retained + 1))
done < "$WALKED_TMP"

printf 'retrofit.sh: walked %d files; %d retained for IR; %d idempotency-skipped\n' \
  "$n_walked" "$n_retained" "$n_skipped" >&2

# ----- Cap check -----

if [ "$n_retained" -gt "$RETROFIT_CAP" ]; then
  cat <<EOF >&2

retrofit.sh: REFUSING — corpus has $n_retained records (cap: $RETROFIT_CAP).

A matrix this large is unwieldy to review at the gate. Options:
  1. Scope to a sub-tree:
       /adopt --retrofit-existing Engagements/
  2. Raise the cap explicitly (inspect import-plan.md size first):
       /adopt --retrofit-existing --retrofit-cap $((n_retained + 100))
  3. Pre-filter via .seedignore at $SOURCE/.seedignore to exclude unwanted paths.

Refusal preserves user-vault sanity. No files written.

EOF
  exit 3
fi

if [ "$n_retained" -eq 0 ]; then
  if [ "$n_skipped" -gt 0 ]; then
    cat <<EOF >&2

retrofit.sh: every walked file was already retrofit-stamped ($n_skipped files).
Nothing new to retrofit. Re-run is idempotent — no writes occurred.

EOF
    exit 0
  fi
  cat <<EOF >&2

retrofit.sh: no recognized files (.md / .txt / .markdown / .vtt) found under
$SOURCE. Nothing to retrofit.

EOF
  exit 0
fi

# ----- Stage 1: T-3 IR builder -----

if ! bash "$DEFAULT_IR_BUILDER" \
  --manifest "$INTAKE_MANIFEST" \
  --ir "$IR_FILE" \
  --batch-cap "$BATCH_CAP"; then
  echo "retrofit.sh: ir-builder.sh failed" >&2
  exit 2
fi

# ----- Stage 2a: T-4 cluster -----

if ! bash "$DEFAULT_CLUSTER" \
  --ir "$IR_FILE" \
  --out "$CLUSTER_OUT" \
  --embedding-mode "$EMBEDDING_MODE"; then
  echo "retrofit.sh: cluster.sh failed" >&2
  exit 2
fi

# ----- Stage 2b: T-5 propose-taxonomy -----

if ! bash "$DEFAULT_PROPOSE" \
  --cluster-output "$CLUSTER_OUT" \
  --ir "$IR_FILE" \
  --out "$PROPOSE_OUT" \
  --llm-mode "$LLM_MODE"; then
  echo "retrofit.sh: propose-taxonomy.sh failed" >&2
  exit 2
fi

# ----- Stage 2c: retrofit-prefilter (NEW; SP13 T-13 layer) -----

if ! python3 "$DEFAULT_PREFILTER" \
  --propose-taxonomy "$PROPOSE_OUT" \
  --ir "$IR_FILE" \
  --vault-root "$VAULT_ROOT_ABS" \
  --filtered-taxonomy-out "$FILTERED_TAXONOMY" \
  --matrix-out "$MATRIX_JSON" \
  --idempotency-skip-list "$IDEMPOTENCY_SKIP" \
  --retrofit-keep-threshold "$KEEP_THRESHOLD"; then
  echo "retrofit.sh: retrofit-prefilter.py failed" >&2
  exit 2
fi

# ----- Stage 2d: T-6 import-plan + matrix appendix -----

if ! bash "$DEFAULT_IMPORT_PLAN" \
  --propose-taxonomy "$FILTERED_TAXONOMY" \
  --out "$IMPORT_PLAN"; then
  echo "retrofit.sh: import-plan.sh failed" >&2
  exit 2
fi

if ! bash "$DEFAULT_MATRIX_SH" \
  --matrix "$MATRIX_JSON" \
  --import-plan "$IMPORT_PLAN"; then
  echo "retrofit.sh: retrofit-collision-matrix.sh failed" >&2
  exit 2
fi

# ----- Dry-run path: stdout the matrix-augmented plan + exit -----

if [ "$DRY_RUN" = "1" ]; then
  cat <<EOF >&2

retrofit.sh: --dry-run — collision matrix rendered to stdout.
Stage 2.5 consultation, T-7 review-gate, and Stage 3 SKIPPED.
Re-run without --dry-run to commit through the gate.

EOF
  cat "$IMPORT_PLAN"
  exit 0
fi

# ----- Stage 2.5: SP15 consultation (when present) -----
#
# SP15 T-7 retrofit ships stage-2-5-consultation.sh and points review-gate.sh
# at consulted-import-plan.md. When the script is absent (older foundation
# checkout), retrofit gracefully falls through to T-7 directly.

CONSULTED_PLAN="$IMPORT_PLAN"
if [ -f "$DEFAULT_STAGE_2_5" ]; then
  STAGE_2_5_OUT="$WORK_DIR/consulted-import-plan.md"
  if bash "$DEFAULT_STAGE_2_5" \
       --import-plan "$IMPORT_PLAN" \
       --out "$STAGE_2_5_OUT" 2>>"$WORK_DIR/stage-2-5.log"; then
    if [ -f "$STAGE_2_5_OUT" ] && [ -s "$STAGE_2_5_OUT" ]; then
      CONSULTED_PLAN="$STAGE_2_5_OUT"
      printf 'retrofit.sh: Stage 2.5 consultation gate fired → %s\n' \
        "$STAGE_2_5_OUT" >&2
    fi
  else
    rc_25=$?
    printf 'retrofit.sh: Stage 2.5 consultation returned rc=%s; ' "$rc_25" >&2
    printf 'falling through to T-7 with the un-consulted plan ' >&2
    printf '(see %s)\n' "$WORK_DIR/stage-2-5.log" >&2
  fi
fi

# ----- T-7: review-gate -----

if [ ! -f "$DEFAULT_REVIEW_GATE" ]; then
  echo "retrofit.sh: review-gate.sh missing at $DEFAULT_REVIEW_GATE" >&2
  exit 2
fi

GATE_ARGS="--import-plan $CONSULTED_PLAN --approved-out $APPROVED_PLAN"
if [ "$ACCEPT_ON_EOF" = "1" ]; then
  GATE_ARGS="$GATE_ARGS --accept-on-eof"
fi

# review-gate.sh exit codes: 0 apply/skip; 1 abort; 2 pre-flight failure.
bash "$DEFAULT_REVIEW_GATE" $GATE_ARGS
gate_rc=$?

if [ "$gate_rc" = "1" ]; then
  printf 'retrofit.sh: user aborted at gate; no Stage 3 writes.\n' >&2
  exit 1
fi
if [ "$gate_rc" = "2" ]; then
  printf 'retrofit.sh: review-gate.sh pre-flight failure.\n' >&2
  exit 2
fi
if [ ! -f "$APPROVED_PLAN" ]; then
  # User chose [s]kip — gate exited 0 but no approved plan. Clean halt.
  printf 'retrofit.sh: user skipped the gate; no Stage 3 writes.\n' >&2
  exit 0
fi

# ----- Stage 3: T-8 seed.sh + T-10 inbox-disposition (transitively) -----
#
# seed.sh handles BOTH project triads (T-8) AND inbox routing (T-10) when
# inbox-disposition.sh is wired (it's a default at $DEFAULT_SEED_SH). The
# filtered taxonomy that retrofit-prefilter wrote ensures seed.sh sees only
# truly-new candidates — already-scaffolded folders are NOT in the plan.

if [ ! -f "$DEFAULT_SEED_SH" ]; then
  echo "retrofit.sh: seed.sh missing at $DEFAULT_SEED_SH" >&2
  exit 2
fi

SEED_ARGS="--vault-root $VAULT_ROOT_ABS --approved-plan $APPROVED_PLAN --audience $AUDIENCE"
if [ "$ACCEPT_ON_EOF" = "1" ]; then
  SEED_ARGS="$SEED_ARGS --accept-on-eof"
fi

bash "$DEFAULT_SEED_SH" $SEED_ARGS
seed_rc=$?

case "$seed_rc" in
  0)
    printf 'retrofit.sh: Stage 3 complete; vault writes applied.\n' >&2
    exit 0
    ;;
  1)
    printf 'retrofit.sh: Stage 3 aborted at gate; no vault writes.\n' >&2
    exit 1
    ;;
  2)
    printf 'retrofit.sh: Stage 3 pre-flight failure.\n' >&2
    exit 2
    ;;
  3)
    printf 'retrofit.sh: Stage 3 partial-state copy error (rc=3); audit log has details.\n' >&2
    exit 2
    ;;
  *)
    printf 'retrofit.sh: Stage 3 unexpected rc=%s\n' "$seed_rc" >&2
    exit 2
    ;;
esac
