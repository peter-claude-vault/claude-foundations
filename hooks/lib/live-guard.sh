#!/bin/bash
# live-guard.sh — plan-agnostic G1 live-mutation runtime gate (Plan 80/81 SP01 T-3)
#
# Replaces hardcoded plan-71-live-guard.sh. Reads each active plan's
# `live_mutation_scope` block from manifest (or active-gates.json read-replica
# when T-8 ships); evaluates detection signals; honors exempt_paths,
# nonce overrides, sentinels, bypass-env. Emits decisions to a single decoupled
# audit log regardless of match_action (decoupled-from-enforcement per
# OPA Gatekeeper convergent pattern).
#
# Invocation contract (from pre-write-guard.sh G1):
#   FILE_PATH="$FILE_PATH" TOOL_NAME="$TOOL_NAME" HOOKS_STATE="$HOOKS_STATE" \
#     "$HOME/.claude/hooks/lib/live-guard.sh"
#
# Test-isolation env (T-3.5):
#   HOOKS_STATE_OVERRIDE  - redirect state dir base
#   PLANS_ROOT_OVERRIDE   - redirect plan-tree walk root
#   ACTIVE_GATES_PATH     - explicit override for read-replica location
#   CLAUDE_HOME           - override foundation-repo git path (default $HOME/.claude)
#   CLAUDE_SESSION_ID     - tier-2 active-plans.txt path key (canonical Claude
#                           Code env); MUST NOT be derived from find-mtime
#                           (closes Plan 71 SP09 Incident δ stochasticity).
#
# Outputs:
#   stdout - hookSpecificOutput JSON if a decision reached; empty for pass-through.
#   stderr - bypass warnings only.
#   side effect - $HOOKS_STATE/gate-decisions.log JSONL append per decision;
#                 nonce file rm'd on allow-override.
#
# Exit codes: always 0 in normal operation. Non-zero only on internal error;
# caller (pre-write-guard.sh G1) interprets non-zero per the gate's
# enforcement.error_action: deny=fail-closed (default; security-gate posture)
# vs ignore=fail-open (Phase A bootstrap exception ONLY).

set -uo pipefail

# === Required input contract =============================================
: "${FILE_PATH:?missing FILE_PATH}"
: "${TOOL_NAME:=unknown}"

# === Path resolution =====================================================
HOOKS_STATE="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-$HOME/.claude/hooks/state}}"
PLANS_ROOT="${PLANS_ROOT_OVERRIDE:-${PLANS_DIR:-$HOME/.claude-plans}}"
CLAUDE_HOME_LOCAL="${CLAUDE_HOME:-$HOME/.claude}"

# active-gates.json read-replica (T-8 product). Default derives from HOOKS_STATE
# parent: $HOOKS_STATE = ~/.claude/hooks/state, so parent is ~/.claude/, then
# /state/active-gates.json = ~/.claude/state/active-gates.json. Override via
# ACTIVE_GATES_PATH env for explicit test placement.
DEFAULT_AG_PATH="${HOOKS_STATE%/hooks/state}/state/active-gates.json"
ACTIVE_GATES_PATH="${ACTIVE_GATES_PATH:-$DEFAULT_AG_PATH}"

mkdir -p "$HOOKS_STATE" 2>/dev/null || true
DECISIONS_LOG="$HOOKS_STATE/gate-decisions.log"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# === Helper: emit JSONL audit row =========================================
audit() {
  local decision="$1" plan_id="$2" rule="$3" signal="${4:-}" reason="${5:-}" \
        nonce_task="${6:-}" sha="${7:-}" gate_match="${8:-}"
  jq -nc \
    --arg ts "$TS" \
    --arg decision "$decision" \
    --arg plan_id "$plan_id" \
    --arg rule "$rule" \
    --arg tool "$TOOL_NAME" \
    --arg file "$FILE_PATH" \
    --arg signal "$signal" \
    --arg reason "$reason" \
    --arg nonce_task "$nonce_task" \
    --arg sha "$sha" \
    --arg gate_match "$gate_match" \
    --argjson schema_version 1 \
    '{
      ts: $ts, decision: $decision, plan_id: $plan_id, rule: $rule,
      tool: $tool, file: $file, signal: $signal, reason: $reason,
      nonce_task: $nonce_task, sha: $sha, gate_match: $gate_match,
      schema_version: $schema_version
    } | with_entries(select(.value != "" and .value != null))' \
    >> "$DECISIONS_LOG" 2>/dev/null || true
}

# === Helper: emit hookSpecificOutput JSON to stdout =======================
emit_decision() {
  local permission="$1"   # allow | deny
  local reason="$2"
  jq -n \
    --arg perm "$permission" \
    --arg reason "$reason" \
    '{
      hookSpecificOutput: ({
        hookEventName: "PreToolUse",
        permissionDecision: $perm
      } + (if $perm == "deny" then {permissionDecisionReason: $reason}
           else {additionalContext: $reason} end))
    }'
}

# === Helper: glob match (vault-relative or absolute) ======================
# Returns 0 (match) / 1 (no match). Honors ** (recursive), * (segment).
# Bash extglob is good enough for our patterns; we set it locally per call.
glob_match() {
  local path="$1" pattern="$2"
  shopt -s extglob globstar nullglob 2>/dev/null
  # Expand $HOME and other env refs in the pattern at match-time. patterns may
  # carry e.g., "$HOME/.claude/**" verbatim from manifest.
  pattern="${pattern//\$HOME/$HOME}"
  pattern="${pattern//\$VAULT_ROOT/${VAULT_ROOT:-$HOME/Documents/Obsidian Vault}}"
  pattern="${pattern//\$CLAUDE_HOME/$CLAUDE_HOME_LOCAL}"
  # shellcheck disable=SC2053
  [[ "$path" == $pattern ]]
}

# === Helper: any-glob match across array ==================================
# Reads array via stdin (one pattern per line). Returns 0 if any match.
any_glob_match() {
  local path="$1"
  local pat
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    glob_match "$path" "$pat" && return 0
  done
  return 1
}

# === Load gate set ========================================================
# Strategy: prefer active-gates.json read-replica (T-8 product, fast); fall
# back to walking plan manifests (slow path, ~50-100ms penalty per packet).
# Each gate is one element in the JSON array we feed downstream.
load_gates() {
  if [[ -r "$ACTIVE_GATES_PATH" ]]; then
    # Read-replica shape (T-8 emits): {schema_version, regenerated_at, gates: [...]}
    jq -c '.gates[]?' "$ACTIVE_GATES_PATH" 2>/dev/null
    return
  fi

  # Slow path: walk plan manifests. Emit one JSON object per enabled gate,
  # injecting plan_slug as the plan_id field for log/decision use.
  if [[ -d "$PLANS_ROOT" ]]; then
    for manifest in "$PLANS_ROOT"/*/manifest.json; do
      [[ -e "$manifest" ]] || continue
      local plan_slug
      plan_slug=$(basename "$(dirname "$manifest")")
      jq -c --arg plan_id "$plan_slug" '
        select((.live_mutation_scope.enabled // false) == true)
        | .live_mutation_scope + {plan_id: $plan_id}
      ' "$manifest" 2>/dev/null
    done
  fi
}

# === Tier-1 deterministic detection =======================================
# OR semantics: any one signal triggers DETECTED.
detect_tier1() {
  local gate="$1"
  local cwd_pattern plan_id_pattern plan_mode_env

  cwd_pattern=$(echo "$gate" | jq -r '.detection_signals.cwd_pattern // empty')
  plan_id_pattern=$(echo "$gate" | jq -r '.detection_signals.plan_id_pattern // empty')
  plan_mode_env=$(echo "$gate" | jq -r '.detection_signals.plan_mode_env_var // empty')

  if [[ -n "$cwd_pattern" ]]; then
    local cwd
    cwd=$(pwd -P 2>/dev/null || pwd)
    # cwd_pattern is glob (verbatim from Plan 71: $HOME/.claude-plans/71-*)
    if glob_match "$cwd" "$cwd_pattern"; then
      echo "cwd"; return 0
    fi
  fi

  if [[ -n "$plan_id_pattern" ]] && [[ -n "${PLAN_ID:-}" ]]; then
    if [[ "$PLAN_ID" =~ $plan_id_pattern ]]; then
      echo "plan-id"; return 0
    fi
  fi

  if [[ -n "$plan_mode_env" ]]; then
    local val="${!plan_mode_env:-0}"
    if [[ "$val" == "1" ]]; then
      echo "plan-mode"; return 0
    fi
  fi

  return 1
}

# === Tier-2 deterministic active-plans.txt detection ======================
# Reads $HOOKS_STATE/$CLAUDE_SESSION_ID/active-plans.txt (T-12 product).
# Match each line against the gate's plan_id_pattern OR plan_id literal slug.
detect_tier2() {
  local gate="$1"
  local plan_id_pattern plan_slug
  plan_id_pattern=$(echo "$gate" | jq -r '.detection_signals.plan_id_pattern // empty')
  plan_slug=$(echo "$gate" | jq -r '.plan_id // empty')

  [[ -z "${CLAUDE_SESSION_ID:-}" ]] && return 1
  local ap_file="$HOOKS_STATE/$CLAUDE_SESSION_ID/active-plans.txt"
  [[ -r "$ap_file" ]] || return 1

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Pattern match (when declared)
    if [[ -n "$plan_id_pattern" ]] && [[ "$line" =~ $plan_id_pattern ]]; then
      echo "active-plans"; return 0
    fi
    # Literal slug match (always allowed)
    if [[ -n "$plan_slug" ]] && [[ "$line" == "$plan_slug" ]]; then
      echo "active-plans"; return 0
    fi
  done < "$ap_file"

  return 1
}

# === Tier-3 transcript-regex detection (opt-in fallback) ==================
# OPT-IN ONLY (transcript_regex declared AND deterministic_only != true).
# LOCKED to $CLAUDE_SESSION_ID transcript file (NOT find-mtime); closes
# Plan 71 SP09 Incident δ stochasticity.
detect_tier3() {
  local gate="$1"
  local regex deterministic_only
  regex=$(echo "$gate" | jq -r '.detection_signals.transcript_regex // empty')
  deterministic_only=$(echo "$gate" | jq -r '.detection_signals.deterministic_only // false')

  [[ -z "$regex" ]] && return 1
  [[ "$deterministic_only" == "true" ]] && return 1
  [[ -z "${CLAUDE_SESSION_ID:-}" ]] && return 1

  # Locate the session's transcript by deterministic id, NOT mtime.
  # Claude Code stores transcripts at ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
  local tr_dir="$CLAUDE_HOME_LOCAL/projects"
  [[ -d "$tr_dir" ]] || return 1

  # Search for the file matching this session id. Globbing across project dirs.
  local transcript=""
  while IFS= read -r f; do
    transcript="$f"
    break
  done < <(find "$tr_dir" -name "${CLAUDE_SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)

  [[ -z "$transcript" ]] || [[ ! -r "$transcript" ]] && return 1

  # Drain tail into variable: avoids SIGPIPE-from-grep-q under pipefail (per
  # plan-71-live-guard.sh:99-101 inherited mitigation).
  local tail_data
  tail_data=$(tail -c 200000 "$transcript" 2>/dev/null || true)
  [[ -z "$tail_data" ]] && return 1

  if grep -qE "$regex" <<< "$tail_data" 2>/dev/null; then
    echo "transcript"; return 0
  fi
  return 1
}

# === Per-gate evaluation ==================================================
evaluate_gate() {
  local gate="$1"
  local plan_id signal=""

  plan_id=$(echo "$gate" | jq -r '.plan_id // "unknown"')

  # === Detection (any tier triggers) ====================================
  signal=$(detect_tier1 "$gate") || signal=$(detect_tier2 "$gate") \
    || signal=$(detect_tier3 "$gate") || true
  [[ -z "$signal" ]] && return 0  # not detected, skip this gate silently

  # === Trigger: is FILE_PATH under any scope_paths? ====================
  local in_scope=0
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if glob_match "$FILE_PATH" "$p"; then in_scope=1; break; fi
  done < <(echo "$gate" | jq -r '.scope_paths[]?')

  [[ "$in_scope" == "0" ]] && return 0  # not under scope, skip silently

  # === Bypass env (highest precedence after detection+scope) ============
  local bypass_var
  bypass_var=$(echo "$gate" | jq -r '.override.bypass_env_var // empty')
  if [[ -n "$bypass_var" ]] && [[ "${!bypass_var:-0}" == "1" ]]; then
    audit "bypass-env" "$plan_id" "R-55" "$signal" "$bypass_var=1"
    echo "[live-guard] BYPASS via $bypass_var=1 (plan: $plan_id, file: $FILE_PATH)" >&2
    GATE_MATCHED=1
    GATE_DECISION_EMITTED=0
    return 0
  fi

  # === Carve-out: exempt_paths (post-detection, pre-deny) ==============
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if glob_match "$FILE_PATH" "$p"; then
      audit "allow-carve-out" "$plan_id" "R-55" "$signal" \
        "exempt_paths match: $p"
      emit_decision allow \
        "[live-guard] allow-carve-out: $plan_id exempt_paths match (signal=$signal, pattern=$p)"
      GATE_MATCHED=1
      GATE_DECISION_EMITTED=1
      return 0
    fi
  done < <(echo "$gate" | jq -r '.exempt_paths[]?')

  # === Sentinel override ===============================================
  local sentinel
  sentinel=$(echo "$gate" | jq -r '.override.sentinel_override_path // empty')
  if [[ -n "$sentinel" ]]; then
    sentinel="${sentinel//\$HOME/$HOME}"
    sentinel="${sentinel//\$CLAUDE_HOME/$CLAUDE_HOME_LOCAL}"
    if [[ -e "$sentinel" ]]; then
      audit "allow-sentinel" "$plan_id" "R-55" "$signal" \
        "sentinel-present: $sentinel"
      emit_decision allow \
        "[live-guard] allow-sentinel: $plan_id sentinel present (signal=$signal)"
      GATE_MATCHED=1
      GATE_DECISION_EMITTED=1
      return 0
    fi
  fi

  # === Nonce override (basename-match-env primary; A5 LOCKED) ==========
  local nonce_dir nonce_anchor nonce_min affinity_env strategy
  nonce_dir=$(echo "$gate" | jq -r '.override.nonce_dir // empty')
  nonce_anchor=$(echo "$gate" | jq -r '.override.nonce_sha_anchor // empty')
  nonce_min=$(echo "$gate" | jq -r '.override.nonce_min_reason_length // 12')
  affinity_env=$(echo "$gate" | jq -r '.override.nonce_affinity_env // empty')
  strategy=$(echo "$gate" | jq -r '.override.nonce_consume_strategy // empty')

  if [[ -n "$nonce_dir" ]] && [[ -n "$nonce_anchor" ]]; then
    nonce_dir="${nonce_dir//\$HOME/$HOME}"
    nonce_dir="${nonce_dir//\$HOOKS_STATE/$HOOKS_STATE}"
    nonce_dir="${nonce_dir//\$CLAUDE_HOME/$CLAUDE_HOME_LOCAL}"

    local current_sha=""
    current_sha=$(git -C "$CLAUDE_HOME_LOCAL" rev-parse "$nonce_anchor" 2>/dev/null || true)

    if [[ -n "$current_sha" ]] && [[ -d "$nonce_dir" ]]; then
      # === A5: basename-match-env primary ============================
      # Caller sets $affinity_env to indicate which task-bound nonce to consume.
      local target_basename=""
      if [[ -n "$affinity_env" ]]; then
        local hint="${!affinity_env:-}"
        [[ -n "$hint" ]] && target_basename="${hint}.nonce"
      fi

      local nonce_file="" nonce_task="" nonce_reason=""

      # Strategy: basename-match-env. If affinity hint provided, ONLY consume
      # the matching basename. If hint absent, no nonce match (deny by
      # default — explicit affinity required). first-match-glob is DEPRECATED
      # (A5 anti-success criterion).
      if [[ "$strategy" == "basename_match_env" ]] || [[ -z "$strategy" ]]; then
        if [[ -n "$target_basename" ]]; then
          local candidate="$nonce_dir/$target_basename"
          if [[ -e "$candidate" ]]; then
            nonce_file="$candidate"
          fi
        fi
      fi

      # Validate nonce content (task<TAB>reason<TAB>sha) if file located
      if [[ -n "$nonce_file" ]] && [[ -r "$nonce_file" ]]; then
        local content task reason sha
        content=$(cat "$nonce_file" 2>/dev/null || echo "")
        task=$(printf '%s' "$content" | awk -F'\t' '{print $1}')
        reason=$(printf '%s' "$content" | awk -F'\t' '{print $2}')
        sha=$(printf '%s' "$content" | awk -F'\t' '{print $3}')

        if [[ "$sha" == "$current_sha" ]] && [[ "${#reason}" -ge "$nonce_min" ]]; then
          # Single-use: consume on match
          rm -f "$nonce_file"
          audit "allow-override" "$plan_id" "R-55" "$signal" \
            "nonce-consumed: $task reason=$reason" "$task" "$current_sha"
          emit_decision allow \
            "[live-guard] allow-override: $plan_id nonce $task consumed (reason: $reason; signal=$signal)"
          GATE_MATCHED=1
          GATE_DECISION_EMITTED=1
          return 0
        fi
      fi
    fi
  fi

  # === No override → enforce match_action ==============================
  local match_action
  match_action=$(echo "$gate" | jq -r '.enforcement.match_action // "deny"')

  case "$match_action" in
    deny)
      audit "deny" "$plan_id" "R-55" "$signal" \
        "no valid override for live mutation under scope"
      local reason
      reason="[live-guard] R-55 BLOCK: $plan_id context detected (signal=$signal); live mutation under scope is denied. File: $FILE_PATH. Override requires nonce at declared nonce_dir with affinity env set, sentinel file, or shell-rc-set bypass env."
      emit_decision deny "$reason"
      GATE_MATCHED=1
      GATE_DECISION_EMITTED=1
      return 0
      ;;
    warn)
      audit "warn" "$plan_id" "R-55" "$signal" \
        "advisory match (warn mode); allowing"
      emit_decision allow \
        "[live-guard] R-55 WARN: $plan_id context detected (signal=$signal); soak-window advisory only. File: $FILE_PATH"
      GATE_MATCHED=1
      GATE_DECISION_EMITTED=1
      return 0
      ;;
    dryrun)
      audit "dryrun" "$plan_id" "R-55" "$signal" \
        "dryrun mode; allowing silently"
      # No decision emitted to caller — silent allow (caller continues main flow).
      GATE_MATCHED=1
      GATE_DECISION_EMITTED=0
      return 0
      ;;
    *)
      audit "config-error" "$plan_id" "R-55" "$signal" \
        "unknown match_action: $match_action; failing-closed (deny)"
      emit_decision deny \
        "[live-guard] CONFIG ERROR: $plan_id match_action=$match_action invalid; failing-closed."
      GATE_MATCHED=1
      GATE_DECISION_EMITTED=1
      return 0
      ;;
  esac
}

# === Main loop ============================================================
GATE_MATCHED=0
GATE_DECISION_EMITTED=0

while IFS= read -r gate; do
  [[ -z "$gate" ]] && continue
  evaluate_gate "$gate"
  # First gate that emits a decision wins (deny dominates allow naturally;
  # multi-gate scope-overlap is a config error caught by T-8 active-gates-rebuild).
  [[ "$GATE_DECISION_EMITTED" == "1" ]] && exit 0
done < <(load_gates)

# No gate matched, or all matched gates were dryrun/bypass-env (no decision emitted)
exit 0
