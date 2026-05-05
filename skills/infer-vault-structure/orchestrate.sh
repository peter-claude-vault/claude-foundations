#!/usr/bin/env bash
# orchestrate.sh — SP16 T-1. Deterministic 4-stage Stage-2/Stage-3 chain.
#
# Wraps cluster.sh → propose-taxonomy.sh → import-plan.sh → review-gate.sh in
# a single composition. Idempotent: each stage skipped if its done-marker
# exists. Halt-resume on review-gate stall: when --halt-before-review is set
# (or stdin is not a TTY and REVIEW_GATE_ACCEPT_ON_EOF is unset), the
# orchestrator writes state/review-pending.flag and exits 64 (EX_USAGE)
# before invoking review-gate; user reviews, then re-invokes with --resume.
#
# COMPOSITION-NOT-FORK contract (SP16 ideation brief #Hard constraint 1):
# the four wrapped scripts are CONSUMED UNCHANGED. orchestrate.sh adds only
# the chain + state-marker + halt-resume layer.
#
# Usage:
#   orchestrate.sh --slug <slug> [--ir-path <ir.jsonl>] [--resume]
#                  [--halt-before-review]
#                  [--llm-mode {stub|live|auto}]
#                  [--embedding-mode {stub|voyage|auto}]
#                  [--min-cluster-size N]
#                  [--state-dir <path>]
#                  [--gate-lib <path>]
#                  [--plan-tree <path>]
#
# Required:
#   --slug <slug>      — namespace under $CLAUDE_HOME/projects/<slug>/inferred
#
# Conditional:
#   --ir-path <path>   — required for fresh runs (no cluster.done marker yet);
#                        ignored on --resume after stage 1 completed
#
# Defaults:
#   state-dir          = ${CLAUDE_HOME:-$HOME/.claude}/projects/<slug>/inferred
#   llm-mode           = auto (forwarded to propose-taxonomy.sh)
#   embedding-mode     = auto (forwarded to cluster.sh)
#   min-cluster-size   = 3
#   gate-lib           = $REPO_ROOT/onboarding/lib/three-step-gate.sh
#   plan-tree          = $HOME/.claude-plans/71-claude-foundations-engine-v2
#
# State layout (under state-dir):
#   cluster-output.json                  ← stage 1 output
#   propose-taxonomy-output.json         ← stage 2 output
#   import-plan.md                       ← stage 3 output
#   approved-import-plan.md              ← stage 4 output (if user approved)
#   state/cluster.done                   ← stage 1 marker
#   state/propose-taxonomy.done          ← stage 2 marker
#   state/import-plan.done               ← stage 3 marker
#   state/review-gate.done               ← stage 4 marker
#   state/review-pending.flag            ← transient halt marker
#   orchestrate-log.jsonl                ← per-stage JSONL records
#
# Done-marker contents: "<stage>\t<ISO-8601 UTC>\t<evidence-path>"
# Log record schema:    {"timestamp","stage","exit_code","duration_ms","evidence_path"}
#
# Exit codes:
#   0    all 4 stages complete (or stage 4 cleanly skipped via review-gate skip)
#   1    user abort during review-gate
#   2    pre-flight failure (missing inputs / scripts / args)
#   64   review-pending halt — user must review import-plan.md and re-run --resume
#
# Constraints (R-23): pure bash 3.2 + stdlib; jq REQUIRED on PATH (used by
# wrapped scripts); python3 REQUIRED (used by cluster.sh / propose-taxonomy.sh
# / import-plan.sh helpers).

set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/../.." && pwd)

CLUSTER_SH="$SELF_DIR/cluster.sh"
PROPOSE_SH="$SELF_DIR/propose-taxonomy.sh"
IMPORT_SH="$SELF_DIR/import-plan.sh"
REVIEW_SH="$SELF_DIR/review-gate.sh"

DEFAULT_GATE_LIB="$REPO_ROOT/onboarding/lib/three-step-gate.sh"
DEFAULT_PLAN_TREE="$HOME/.claude-plans/71-claude-foundations-engine-v2"

SLUG=""
IR_PATH=""
RESUME=0
HALT_BEFORE_REVIEW=0
LLM_MODE="auto"
EMBEDDING_MODE="auto"
MIN_CLUSTER_SIZE="3"
STATE_DIR_OVERRIDE=""
GATE_LIB="$DEFAULT_GATE_LIB"
PLAN_TREE="$DEFAULT_PLAN_TREE"

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --slug)
      shift
      [ $# -gt 0 ] || { echo "orchestrate.sh: --slug requires a value" >&2; exit 2; }
      SLUG="$1"
      ;;
    --ir-path|--ir)
      shift
      [ $# -gt 0 ] || { echo "orchestrate.sh: --ir-path requires a path" >&2; exit 2; }
      IR_PATH="$1"
      ;;
    --resume)
      RESUME=1
      ;;
    --halt-before-review)
      HALT_BEFORE_REVIEW=1
      ;;
    --llm-mode)
      shift
      [ $# -gt 0 ] || { echo "orchestrate.sh: --llm-mode requires {stub|live|auto}" >&2; exit 2; }
      LLM_MODE="$1"
      ;;
    --embedding-mode)
      shift
      [ $# -gt 0 ] || { echo "orchestrate.sh: --embedding-mode requires {stub|voyage|auto}" >&2; exit 2; }
      EMBEDDING_MODE="$1"
      ;;
    --min-cluster-size)
      shift
      [ $# -gt 0 ] || { echo "orchestrate.sh: --min-cluster-size requires N" >&2; exit 2; }
      MIN_CLUSTER_SIZE="$1"
      ;;
    --state-dir)
      shift
      [ $# -gt 0 ] || { echo "orchestrate.sh: --state-dir requires a path" >&2; exit 2; }
      STATE_DIR_OVERRIDE="$1"
      ;;
    --gate-lib)
      shift
      [ $# -gt 0 ] || { echo "orchestrate.sh: --gate-lib requires a path" >&2; exit 2; }
      GATE_LIB="$1"
      ;;
    --plan-tree)
      shift
      [ $# -gt 0 ] || { echo "orchestrate.sh: --plan-tree requires a path" >&2; exit 2; }
      PLAN_TREE="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "orchestrate.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# ---------- pre-flight ----------

[ -n "$SLUG" ] || { echo "orchestrate.sh: --slug required" >&2; exit 2; }

# Slug sanity: alnum + hyphen + underscore only (avoid path-traversal).
case "$SLUG" in
  *[!A-Za-z0-9_-]*|""|.*|/*)
    echo "orchestrate.sh: --slug must be [A-Za-z0-9_-]+ (got: $SLUG)" >&2
    exit 2
    ;;
esac

for script in "$CLUSTER_SH" "$PROPOSE_SH" "$IMPORT_SH" "$REVIEW_SH"; do
  if [ ! -x "$script" ]; then
    echo "orchestrate.sh: required wrapped script missing or non-executable: $script" >&2
    exit 2
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "orchestrate.sh: jq required on PATH" >&2
  exit 2
fi

# Resolve state directory.
if [ -n "$STATE_DIR_OVERRIDE" ]; then
  STATE_DIR="$STATE_DIR_OVERRIDE"
else
  CH="${CLAUDE_HOME:-$HOME/.claude}"
  STATE_DIR="$CH/projects/$SLUG/inferred"
fi
MARKER_DIR="$STATE_DIR/state"
LOG_PATH="$STATE_DIR/orchestrate-log.jsonl"

mkdir -p "$STATE_DIR" "$MARKER_DIR" || {
  echo "orchestrate.sh: cannot create state dirs under $STATE_DIR" >&2
  exit 2
}

# Stage output paths.
CLUSTER_OUT="$STATE_DIR/cluster-output.json"
PROPOSE_OUT="$STATE_DIR/propose-taxonomy-output.json"
IMPORT_OUT="$STATE_DIR/import-plan.md"
APPROVED_OUT="$STATE_DIR/approved-import-plan.md"

CLUSTER_DONE="$MARKER_DIR/cluster.done"
PROPOSE_DONE="$MARKER_DIR/propose-taxonomy.done"
IMPORT_DONE="$MARKER_DIR/import-plan.done"
REVIEW_DONE="$MARKER_DIR/review-gate.done"
REVIEW_PENDING="$MARKER_DIR/review-pending.flag"

# ---------- helpers ----------

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Append one JSONL record to orchestrate-log.jsonl. Args: stage, rc, duration_ms, evidence.
log_stage() {
  _stage="$1"; _rc="$2"; _ms="$3"; _ev="$4"
  jq -nc \
    --arg ts "$(now_iso)" \
    --arg st "$_stage" \
    --argjson ec "$_rc" \
    --argjson dur "$_ms" \
    --arg ev "$_ev" \
    '{timestamp:$ts, stage:$st, exit_code:$ec, duration_ms:$dur, evidence_path:$ev}' \
    >> "$LOG_PATH"
}

# Write done-marker. Args: marker-path, stage, evidence.
write_marker() {
  _path="$1"; _stage="$2"; _ev="$3"
  printf '%s\t%s\t%s\n' "$_stage" "$(now_iso)" "$_ev" > "$_path"
}

# Best-effort millisecond timer using `date +%s%N` (GNU) or fallback to seconds × 1000.
ms_now() {
  _ns=$(date +%s%N 2>/dev/null)
  case "$_ns" in
    *N|"")
      # macOS / BSD `date` doesn't support %N — fall back to seconds×1000.
      _s=$(date +%s)
      echo $(( _s * 1000 ))
      ;;
    *)
      echo $(( _ns / 1000000 ))
      ;;
  esac
}

# ---------- IR pre-flight (only if stage 1 not done) ----------

if [ ! -f "$CLUSTER_DONE" ]; then
  if [ -z "$IR_PATH" ]; then
    echo "orchestrate.sh: --ir-path required for fresh runs (no $CLUSTER_DONE yet)" >&2
    exit 2
  fi
  if [ ! -f "$IR_PATH" ]; then
    echo "orchestrate.sh: --ir-path file not found: $IR_PATH" >&2
    exit 2
  fi
fi

# Resume sanity: --resume on a clean state dir is allowed (becomes equivalent
# to a fresh run); we don't error there. We do NOT clear partial markers; the
# user is responsible for `rm -rf state-dir/state` if they want a hard reset.
if [ "$RESUME" -eq 1 ]; then
  echo "orchestrate.sh: --resume requested; honoring existing done markers under $MARKER_DIR" >&2
fi

# ---------- stage 1: cluster ----------

if [ -f "$CLUSTER_DONE" ]; then
  echo "orchestrate.sh: stage 1 (cluster) — SKIP (marker exists)" >&2
  log_stage "cluster" 0 0 "$CLUSTER_OUT"
else
  echo "orchestrate.sh: stage 1 (cluster) — RUN" >&2
  _t0=$(ms_now)
  "$CLUSTER_SH" \
    --ir "$IR_PATH" \
    --out "$CLUSTER_OUT" \
    --min-cluster-size "$MIN_CLUSTER_SIZE" \
    --embedding-mode "$EMBEDDING_MODE"
  _rc=$?
  _t1=$(ms_now)
  _dur=$(( _t1 - _t0 ))
  log_stage "cluster" "$_rc" "$_dur" "$CLUSTER_OUT"
  if [ "$_rc" -ne 0 ]; then
    echo "orchestrate.sh: stage 1 (cluster) FAILED rc=$_rc" >&2
    exit "$_rc"
  fi
  if [ ! -s "$CLUSTER_OUT" ]; then
    echo "orchestrate.sh: stage 1 (cluster) produced no output at $CLUSTER_OUT" >&2
    exit 1
  fi
  write_marker "$CLUSTER_DONE" "cluster" "$CLUSTER_OUT"
fi

# ---------- stage 2: propose-taxonomy ----------

if [ -f "$PROPOSE_DONE" ]; then
  echo "orchestrate.sh: stage 2 (propose-taxonomy) — SKIP (marker exists)" >&2
  log_stage "propose-taxonomy" 0 0 "$PROPOSE_OUT"
else
  echo "orchestrate.sh: stage 2 (propose-taxonomy) — RUN" >&2
  # propose-taxonomy.sh requires --ir even when consuming cluster output.
  if [ -z "$IR_PATH" ]; then
    echo "orchestrate.sh: stage 2 needs --ir-path (propose-taxonomy.sh requires it)" >&2
    exit 2
  fi
  _t0=$(ms_now)
  "$PROPOSE_SH" \
    --cluster-output "$CLUSTER_OUT" \
    --ir "$IR_PATH" \
    --out "$PROPOSE_OUT" \
    --llm-mode "$LLM_MODE"
  _rc=$?
  _t1=$(ms_now)
  _dur=$(( _t1 - _t0 ))
  log_stage "propose-taxonomy" "$_rc" "$_dur" "$PROPOSE_OUT"
  if [ "$_rc" -ne 0 ]; then
    echo "orchestrate.sh: stage 2 (propose-taxonomy) FAILED rc=$_rc" >&2
    exit "$_rc"
  fi
  if [ ! -s "$PROPOSE_OUT" ]; then
    echo "orchestrate.sh: stage 2 produced no output at $PROPOSE_OUT" >&2
    exit 1
  fi
  write_marker "$PROPOSE_DONE" "propose-taxonomy" "$PROPOSE_OUT"
fi

# ---------- stage 3: import-plan ----------

if [ -f "$IMPORT_DONE" ]; then
  echo "orchestrate.sh: stage 3 (import-plan) — SKIP (marker exists)" >&2
  log_stage "import-plan" 0 0 "$IMPORT_OUT"
else
  echo "orchestrate.sh: stage 3 (import-plan) — RUN" >&2
  _t0=$(ms_now)
  "$IMPORT_SH" \
    --propose-taxonomy "$PROPOSE_OUT" \
    --out "$IMPORT_OUT"
  _rc=$?
  _t1=$(ms_now)
  _dur=$(( _t1 - _t0 ))
  log_stage "import-plan" "$_rc" "$_dur" "$IMPORT_OUT"
  if [ "$_rc" -ne 0 ]; then
    echo "orchestrate.sh: stage 3 (import-plan) FAILED rc=$_rc" >&2
    exit "$_rc"
  fi
  if [ ! -s "$IMPORT_OUT" ]; then
    echo "orchestrate.sh: stage 3 produced no output at $IMPORT_OUT" >&2
    exit 1
  fi
  write_marker "$IMPORT_DONE" "import-plan" "$IMPORT_OUT"
fi

# ---------- stage 4: review-gate (with halt-resume) ----------

if [ -f "$REVIEW_DONE" ]; then
  echo "orchestrate.sh: stage 4 (review-gate) — SKIP (marker exists)" >&2
  log_stage "review-gate" 0 0 "$APPROVED_OUT"
  # Clear any stale review-pending flag from a prior halted run.
  [ -f "$REVIEW_PENDING" ] && rm -f "$REVIEW_PENDING"
  echo "orchestrate.sh: all stages complete (idempotent re-run)" >&2
  exit 0
fi

# Decide: run review-gate now, or write review-pending.flag and halt?
# Halt when:
#   (a) --halt-before-review explicit, OR
#   (b) stdin is not a TTY AND REVIEW_GATE_ACCEPT_ON_EOF is unset/0 (i.e., no
#       way for review-gate to make a decision) AND REVIEW_GATE_PROMPT_CHOICE
#       is unset
do_halt=0
if [ "$HALT_BEFORE_REVIEW" -eq 1 ]; then
  do_halt=1
elif [ ! -t 0 ] \
     && [ -z "${REVIEW_GATE_ACCEPT_ON_EOF:-}" ] \
     && [ -z "${REVIEW_GATE_PROMPT_CHOICE:-}" ]; then
  do_halt=1
fi

# An existing review-pending.flag from a prior halt is informational only —
# we re-evaluate halt vs run on each invocation based on current flags/TTY.

if [ "$do_halt" -eq 1 ]; then
  printf 'review-pending\t%s\t%s\n' "$(now_iso)" "$IMPORT_OUT" > "$REVIEW_PENDING"
  log_stage "review-gate" 64 0 "$REVIEW_PENDING"
  cat <<EOF >&2

orchestrate.sh: review pending.

  Import plan ready for review:  $IMPORT_OUT

Review the plan, then re-run with:

  $0 --slug $SLUG --resume

(or pipe an answer into review-gate via REVIEW_GATE_PROMPT_CHOICE / set
REVIEW_GATE_ACCEPT_ON_EOF=1 to default-apply on the next invocation.)
EOF
  exit 64
fi

# Run review-gate. Pass through env (REVIEW_GATE_ACCEPT_ON_EOF /
# REVIEW_GATE_PROMPT_CHOICE) and stdin to it as-is.
echo "orchestrate.sh: stage 4 (review-gate) — RUN" >&2
_t0=$(ms_now)
"$REVIEW_SH" \
  --import-plan "$IMPORT_OUT" \
  --approved-out "$APPROVED_OUT" \
  --gate-lib "$GATE_LIB" \
  --plan-tree "$PLAN_TREE"
_rc=$?
_t1=$(ms_now)
_dur=$(( _t1 - _t0 ))

# review-gate exit codes:
#   0 → apply (approved-import-plan.md present) OR skip (not present); both clean
#   1 → user abort
#   2 → pre-flight failure
case "$_rc" in
  0)
    if [ -s "$APPROVED_OUT" ]; then
      log_stage "review-gate" 0 "$_dur" "$APPROVED_OUT"
      write_marker "$REVIEW_DONE" "review-gate" "$APPROVED_OUT"
      [ -f "$REVIEW_PENDING" ] && rm -f "$REVIEW_PENDING"
      echo "orchestrate.sh: all 4 stages complete; approved plan at $APPROVED_OUT" >&2
      exit 0
    else
      # User chose [s]kip — clean exit, no apply-marker, no error.
      log_stage "review-gate" 0 "$_dur" ""
      [ -f "$REVIEW_PENDING" ] && rm -f "$REVIEW_PENDING"
      echo "orchestrate.sh: review-gate exited cleanly (skip); no approved plan written" >&2
      exit 0
    fi
    ;;
  1)
    log_stage "review-gate" 1 "$_dur" ""
    echo "orchestrate.sh: review-gate aborted by user (rc=1)" >&2
    exit 1
    ;;
  *)
    log_stage "review-gate" "$_rc" "$_dur" ""
    echo "orchestrate.sh: review-gate failed rc=$_rc (pre-flight or runtime error)" >&2
    exit "$_rc"
    ;;
esac
