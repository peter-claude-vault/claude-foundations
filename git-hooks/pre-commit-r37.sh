#!/bin/bash
# pre-commit-r37.sh — R-37 coupled-surface enforcement (Plan 80/81 SP01 T-7)
#
# Foundation-repo + plans-repo pre-commit hook. Reads `r37.coupled_surfaces`
# from `gate-config.json`. For each declared coupled set, if the staged diff
# touches at least `min_match` paths from the set but NOT the full set, the
# commit is flagged as a partial-coupled-set commit. Per the gate's
# `enforcement_action` (warn|deny), partial commits are advisory or rejected.
#
# Promotes R-37 from documentary (pre-write-guard.sh comment) to structural
# enforcement at G2 via Option α (per spec L192 + Agent 4 finding).
#
# Override:
#   $REPO_ROOT/.allow-r37-partial sentinel + `git commit --no-verify`
#   (two physical actions; logged to gate-decisions.log).
#
# Test isolation env (mirrors pre-commit-harness-validated.sh contract):
#   GATE_CONFIG_PATH          - override gate-config.json path
#   PRE_COMMIT_STAGED_OVERRIDE - newline-separated staged paths (test mode)
#   HOOKS_STATE_OVERRIDE      - audit log directory base
#   R37_ENFORCEMENT_OVERRIDE  - force warn|deny (overrides config)
#
# Exit codes: 0=allow; 1=reject (deny mode + partial detected, no override);
# 2=internal error.

set -uo pipefail

HOOK_NAME="pre-commit-r37"

# === Path resolution ===================================================
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "$HOOK_NAME: not in a git repo; pass through" >&2
  exit 0
}

FOUNDATION_REPO="${FOUNDATION_REPO_OVERRIDE:-$HOME/Code/claude-stem}"
HOOKS_STATE="${HOOKS_STATE_OVERRIDE:-$HOME/.claude/hooks/state}"
SENTINEL="$REPO_ROOT/.allow-r37-partial"
GATE_CONFIG="${GATE_CONFIG_PATH:-$FOUNDATION_REPO/schemas/gate-config.json}"

mkdir -p "$HOOKS_STATE" 2>/dev/null || true
DECISIONS_LOG="$HOOKS_STATE/gate-decisions.log"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

audit() {
  local decision="$1" reason="$2" set_name="${3:-}" missed="${4:-}" matched="${5:-}"
  jq -nc \
    --arg ts "$TS" --arg hook "$HOOK_NAME" --arg decision "$decision" \
    --arg reason "$reason" --arg set_name "$set_name" \
    --arg missed "$missed" --arg matched "$matched" --arg repo "$REPO_ROOT" \
    --arg rule "R-37" --argjson schema_version 1 \
    '{ts:$ts, hook:$hook, decision:$decision, rule:$rule, reason:$reason,
      set_name:$set_name, missed:$missed, matched:$matched, repo:$repo,
      schema_version:$schema_version}
     | with_entries(select(.value != "" and .value != null))' \
    >> "$DECISIONS_LOG" 2>/dev/null || true
}

# === Config load =======================================================
if [[ ! -f "$GATE_CONFIG" ]]; then
  echo "$HOOK_NAME: gate-config.json not found at $GATE_CONFIG; pass through" >&2
  audit "allow" "gate-config-missing-best-effort"
  exit 0
fi

R37_ENABLED=$(jq -r '.r37.enabled // false' "$GATE_CONFIG" 2>/dev/null)
if [[ "$R37_ENABLED" != "true" ]]; then
  audit "allow" "r37-disabled-in-config"
  exit 0
fi

ENFORCEMENT="${R37_ENFORCEMENT_OVERRIDE:-$(jq -r '.r37.enforcement_action // "warn"' "$GATE_CONFIG")}"
case "$ENFORCEMENT" in
  warn|deny|dryrun) ;;
  *)
    echo "$HOOK_NAME: unknown enforcement_action '$ENFORCEMENT'; defaulting to warn" >&2
    ENFORCEMENT="warn"
    ;;
esac

# === Sentinel override =================================================
if [[ -f "$SENTINEL" ]]; then
  echo "$HOOK_NAME: sentinel $SENTINEL present; allow + log" >&2
  audit "allow" "sentinel-override-via-.allow-r37-partial"
  exit 0
fi

# === Staged-file resolution ============================================
get_staged_files() {
  if [[ -n "${PRE_COMMIT_STAGED_OVERRIDE:-}" ]]; then
    printf '%s\n' "$PRE_COMMIT_STAGED_OVERRIDE"
    return
  fi
  git diff --cached --name-only 2>/dev/null
}

# === Glob match ========================================================
# Matches `path` against `pattern` using bash extglob/globstar. Pattern
# may contain `*` and `**`. Repo-relative paths only.
glob_match() {
  local path="$1" pattern="$2"
  shopt -s globstar extglob 2>/dev/null || true
  [[ "$path" == $pattern ]]
}

# === Coupled-set evaluation ============================================
# For each set, count: matched paths in staged-diff vs total set size.
# Triggered = matched >= min_match. Partial = triggered AND matched < total.
SET_COUNT=$(jq -r '.r37.coupled_surfaces | length' "$GATE_CONFIG" 2>/dev/null)
if [[ -z "$SET_COUNT" || "$SET_COUNT" == "null" || "$SET_COUNT" -eq 0 ]]; then
  audit "allow" "no-coupled-surfaces-declared"
  exit 0
fi

STAGED=$(get_staged_files)
if [[ -z "$STAGED" ]]; then
  audit "allow" "no-staged-files"
  exit 0
fi

partial_count=0
violations=()

for ((i=0; i<SET_COUNT; i++)); do
  set_name=$(jq -r ".r37.coupled_surfaces[$i].name // \"unnamed-$i\"" "$GATE_CONFIG")
  min_match=$(jq -r ".r37.coupled_surfaces[$i].min_match // 1" "$GATE_CONFIG")
  set_paths=$(jq -r ".r37.coupled_surfaces[$i].paths[]" "$GATE_CONFIG")
  total_paths=$(printf '%s\n' "$set_paths" | grep -c .)

  matched=()
  unmatched=()

  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    hit=0
    while IFS= read -r staged_path; do
      [[ -z "$staged_path" ]] && continue
      if glob_match "$staged_path" "$pattern"; then
        hit=1
        break
      fi
    done <<< "$STAGED"
    if (( hit == 1 )); then
      matched+=("$pattern")
    else
      unmatched+=("$pattern")
    fi
  done <<< "$set_paths"

  matched_count=${#matched[@]}

  # Trigger: at least min_match paths in this set are touched
  if (( matched_count < min_match )); then
    continue
  fi

  # Build comma-joined view ahead of branch for set -u safety (else branch
  # references matched_str even when unmatched array is empty).
  matched_str=$(IFS=,; echo "${matched[*]:-}")
  missed_str=$(IFS=,; echo "${unmatched[*]:-}")

  # Partial: triggered AND not all paths matched
  if (( matched_count < total_paths )); then
    partial_count=$((partial_count + 1))
    violations+=("$set_name|$matched_str|$missed_str")
    audit "$([[ $ENFORCEMENT == deny ]] && echo reject || echo warn)" \
          "r37-partial-set-commit" "$set_name" "$missed_str" "$matched_str"
  else
    audit "allow" "r37-full-set-commit" "$set_name" "" "$matched_str"
  fi
done

if (( partial_count == 0 )); then
  exit 0
fi

# === Emit human-readable findings ======================================
echo "" >&2
echo "$HOOK_NAME: R-37 partial coupled-set commit(s) detected" >&2
echo "" >&2
for v in "${violations[@]}"; do
  IFS='|' read -r set_name matched_str missed_str <<< "$v"
  echo "  Set: $set_name" >&2
  echo "    Matched (staged):  ${matched_str//,/ }" >&2
  echo "    Missed (required): ${missed_str//,/ }" >&2
  echo "" >&2
done
echo "  R-37 contract: when a coupled set is touched, ALL paths in the set" >&2
echo "  must land in the same commit (lockstep discipline)." >&2
echo "" >&2
echo "  Resolution: stage the missing paths and retry, OR" >&2
echo "  Override:   touch $SENTINEL && git commit --no-verify" >&2
echo "" >&2

case "$ENFORCEMENT" in
  deny)
    exit 1
    ;;
  warn|dryrun)
    echo "  enforcement_action=$ENFORCEMENT — advisory only; commit allowed." >&2
    exit 0
    ;;
esac
