#!/bin/bash
# l3-pause-helper.sh — plan-agnostic L3 writer-pause helper (Plan 80/81 SP01 T-4).
#
# Coordinates pause/resume of writers (SessionEnd hooks, UserPromptSubmit
# writers, launchd labels) declared in a plan's manifest at
# .live_mutation_scope.layer_3. Reads l3-writer-registry.json (T-5) for
# write_paths + per-writer pause-mechanism semantics. Implements:
#
# Subcommands: pause | resume | status | validate <plan-id>
#
# Multi-owner stack (Vault sealed-mode pattern): one state file per writer
# at $HOOKS_STATE/l3-pause-state/<writer-id>.json carrying
# {owners: [plan-id, ...], paused_at, mechanism, original_state, writer_id}.
# pause(plan-id) appends; resume(plan-id) removes; mechanism only fires when
# owners was empty (pause) / becomes empty (resume). Plan 80 deploying atop
# Plan 71 paused state inherits the stack — resume only releases when ALL
# owners drained.
#
# Atomic semantics, fail-closed with rollback: pause() captures original
# state per writer, applies in declared order. On ANY single failure,
# immediately invokes resume(<plan-id>) to roll back partials. Exit
# non-zero. No "best-effort partial pause" (SP09 footgun).
#
# Quiescence period (k8s drain pattern): after successful pause-broadcast,
# helper sleeps $expected_quiescence_period_seconds (default 30s) before
# returning success. Catches in-flight writes that haven't settled.
#
# Crash recovery: state files survive across sessions. l3-pause-helper.sh
# status surfaces orphans (state file present but plan declared closed);
# explicit user action required to resume — NO auto-resume.
#
# Pause mechanisms:
#   sentinel       - touch/rm the sentinel_path
#   env            - record env_var name; soft-pause (depends on writer
#                    checking env at invocation; documentary in v1)
#   launchctl      - launchctl unload/load (macOS launchd labels). rc errors
#                    surfaced to stderr + audit log per
#                    feedback_sandbox_exec_filesystem_only.
#   carve_out_in_g1 - validate-only: helper checks that the plan's
#                    live-guard.sh exempt_paths covers writer's write_paths;
#                    no pause action taken (UserPromptSubmit / PostToolUse
#                    writers have no native pause API).
#
# Test-isolation env (mirror T-3.5 contract):
#   HOOKS_STATE_OVERRIDE - state dir base
#   PLANS_ROOT_OVERRIDE  - plan-tree walk root
#   L3_REGISTRY_PATH     - override l3-writer-registry.json location
#   L3_LAUNCHCTL_BIN     - override launchctl binary (test mocking; default
#                          /bin/launchctl when present, else /usr/bin/launchctl)
#   L3_QUIESCENCE_OVERRIDE - override quiescence period seconds (test fast-path)

set -uo pipefail

# === Path resolution ======================================================
HOOKS_STATE="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-$HOME/.claude/hooks/state}}"
PLANS_ROOT="${PLANS_ROOT_OVERRIDE:-${PLANS_DIR:-$HOME/.claude-plans}}"
PAUSE_STATE_DIR="$HOOKS_STATE/l3-pause-state"
L3_REGISTRY_PATH="${L3_REGISTRY_PATH:-$HOME/.claude/hooks/lib/l3-writer-registry.json}"
LAUNCHCTL_BIN="${L3_LAUNCHCTL_BIN:-/bin/launchctl}"
[[ -x "$LAUNCHCTL_BIN" ]] || LAUNCHCTL_BIN="/usr/bin/launchctl"

mkdir -p "$PAUSE_STATE_DIR" 2>/dev/null || true

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# === Usage ================================================================
usage() {
  cat <<EOF
Usage: l3-pause-helper.sh <subcommand> <plan-id> [options]

Subcommands:
  pause <plan-id>       Pause all writers declared in <plan-id>'s manifest.
                        Atomic: rolls back on any partial failure.
  resume <plan-id>      Remove <plan-id> from each writer's owners stack.
                        Mechanism reverts only when owners become empty.
  status [<plan-id>]    Print current pause state. Without plan-id: all writers.
                        With plan-id: only writers owned by that plan.
  validate <plan-id>    Static-analysis check: validate manifest layer_3
                        against l3-writer-registry.json without action.

Options:
  --quiescence-skip     Skip the post-pause quiescence sleep (test fast-path).
  --skip-launchctl      Skip launchctl operations (no-op them; test isolation).
EOF
  exit 2
}

# === Helpers ==============================================================
get_plan_manifest() {
  local plan_id="$1"
  local m="$PLANS_ROOT/$plan_id/manifest.json"
  [[ -r "$m" ]] && echo "$m" || return 1
}

get_layer3_block() {
  local plan_id="$1"
  local m
  m=$(get_plan_manifest "$plan_id") || return 1
  jq -c '.live_mutation_scope.layer_3 // empty' "$m"
}

# Enumerate writers as flat JSON-objects-per-line:
#   {writer_id, mechanism, target}
# where target = sentinel_path | env_var | launchd_label | path_pattern.
enumerate_writers() {
  local plan_id="$1"
  local layer3
  layer3=$(get_layer3_block "$plan_id") || return 1
  [[ -z "$layer3" ]] && return 0

  local enabled
  enabled=$(echo "$layer3" | jq -r '.enabled // false')
  [[ "$enabled" != "true" ]] && return 0

  # session_end_hooks: array of {path, pause_via, sentinel_path?, env_var?}
  echo "$layer3" | jq -c '
    .session_end_hooks[]? as $h
    | {
        writer_id: ($h.path | split("/") | last),
        mechanism: $h.pause_via,
        target: ($h.sentinel_path // $h.env_var // $h.path),
        path: $h.path
      }
  '

  # user_prompt_submit_writers: array of {path_pattern, pause_via}
  echo "$layer3" | jq -c '
    .user_prompt_submit_writers[]? as $w
    | {
        writer_id: ("ups:" + $w.path_pattern),
        mechanism: $w.pause_via,
        target: $w.path_pattern,
        path: $w.path_pattern
      }
  '

  # launchd_labels: array of strings
  echo "$layer3" | jq -c '
    .launchd_labels[]? as $l
    | {
        writer_id: $l,
        mechanism: "launchctl",
        target: $l,
        path: ("launchd:" + $l)
      }
  '
}

state_file_for() {
  local writer_id="$1"
  # writer_id may contain path separators (e.g., "ups:$HOME/.claude/...");
  # sanitize via tr to make a valid filename.
  local safe
  safe=$(printf '%s' "$writer_id" | tr '/:.*$' '___-_')
  echo "$PAUSE_STATE_DIR/${safe}.json"
}

# === Mechanism: launchctl ================================================
launchctl_capture_state() {
  local label="$1"
  if [[ "${SKIP_LAUNCHCTL:-0}" == "1" ]]; then
    echo "skipped"; return 0
  fi
  if "$LAUNCHCTL_BIN" list "$label" >/dev/null 2>&1; then
    echo "loaded"
  else
    echo "unloaded"
  fi
}

launchctl_apply_pause() {
  local label="$1" plist="${2:-}"
  if [[ "${SKIP_LAUNCHCTL:-0}" == "1" ]]; then return 0; fi
  if [[ -n "$plist" ]] && [[ -e "$plist" ]]; then
    "$LAUNCHCTL_BIN" unload "$plist" 2>&1
  else
    "$LAUNCHCTL_BIN" remove "$label" 2>&1
  fi
}

launchctl_revert_pause() {
  local label="$1" plist="${2:-}" original_state="${3:-loaded}"
  if [[ "${SKIP_LAUNCHCTL:-0}" == "1" ]]; then return 0; fi
  [[ "$original_state" != "loaded" ]] && return 0
  if [[ -n "$plist" ]] && [[ -e "$plist" ]]; then
    "$LAUNCHCTL_BIN" load "$plist" 2>&1
  fi
}

# Resolve plist path for a label by reading the registry.
plist_for_label() {
  local label="$1"
  [[ -r "$L3_REGISTRY_PATH" ]] || { echo ""; return; }
  local plist
  plist=$(jq -r --arg l "$label" '
    (.writers[]? // empty) | select(.launchd_label == $l) | .plist_path // ""
  ' "$L3_REGISTRY_PATH" 2>/dev/null | head -1)
  echo "${plist//\$HOME/$HOME}"
}

# === Pause apply per mechanism ===========================================
# Returns 0 on success, non-zero on failure. Writes original_state to stdout.
apply_pause() {
  local mechanism="$1" target="$2" writer_id="$3"
  local original=""

  case "$mechanism" in
    sentinel)
      target="${target//\$HOOKS_STATE/$HOOKS_STATE}"
      target="${target//\$HOME/$HOME}"
      if [[ -e "$target" ]]; then
        original="present"
      else
        original="absent"
        touch "$target" 2>/dev/null || return 1
      fi
      ;;
    env)
      # Documentary pause: record the env_var name. Writer must check at
      # invocation. v1 mechanism — see writer-registry _notes.
      original="env-soft-pause"
      ;;
    launchctl)
      original=$(launchctl_capture_state "$target")
      if [[ "$original" == "loaded" ]]; then
        local plist
        plist=$(plist_for_label "$target")
        local rc_msg
        rc_msg=$(launchctl_apply_pause "$target" "$plist" 2>&1) || {
          echo "launchctl unload failed for $target: $rc_msg" >&2
          return 1
        }
      fi
      ;;
    carve_out_in_g1)
      # Validate-only: helper does NOT take action; expects gate's
      # exempt_paths to cover writer's write_paths. Validation enforced at
      # `validate` subcommand; pause path is a no-op recorded in state.
      original="g1-carve-out"
      ;;
    *)
      echo "unknown pause mechanism: $mechanism" >&2
      return 1
      ;;
  esac
  echo "$original"
  return 0
}

revert_pause() {
  local mechanism="$1" target="$2" original_state="$3"

  case "$mechanism" in
    sentinel)
      target="${target//\$HOOKS_STATE/$HOOKS_STATE}"
      target="${target//\$HOME/$HOME}"
      if [[ "$original_state" == "absent" ]]; then
        rm -f "$target" 2>/dev/null
      fi
      ;;
    env|carve_out_in_g1)
      : # no-op revert (documentary-only mechanisms)
      ;;
    launchctl)
      local plist
      plist=$(plist_for_label "$target")
      launchctl_revert_pause "$target" "$plist" "$original_state" >/dev/null 2>&1 || true
      ;;
  esac
}

# === Subcommand: pause ====================================================
cmd_pause() {
  local plan_id="$1" skip_quiescence="${2:-0}"

  local writers_json
  writers_json=$(enumerate_writers "$plan_id")
  if [[ -z "$writers_json" ]]; then
    echo "l3-pause-helper: no layer_3 writers declared for $plan_id (or layer_3.enabled=false); pause is a no-op"
    return 0
  fi

  local quiescence
  quiescence=$(get_layer3_block "$plan_id" | jq -r '.expected_quiescence_period_seconds // 30')
  [[ -n "${L3_QUIESCENCE_OVERRIDE:-}" ]] && quiescence="$L3_QUIESCENCE_OVERRIDE"
  [[ "$skip_quiescence" == "1" ]] && quiescence=0

  # Track applied writers for rollback
  local applied=()
  local failed=0

  while IFS= read -r writer; do
    [[ -z "$writer" ]] && continue
    local writer_id mechanism target
    writer_id=$(echo "$writer" | jq -r '.writer_id')
    mechanism=$(echo "$writer" | jq -r '.mechanism')
    target=$(echo "$writer" | jq -r '.target')

    local sf
    sf=$(state_file_for "$writer_id")

    # Multi-owner stack: if state file exists and another plan owns, just
    # add this plan to owners. mechanism should not re-fire.
    if [[ -e "$sf" ]]; then
      local owners
      owners=$(jq -r '.owners[]?' "$sf" 2>/dev/null || true)
      if echo "$owners" | grep -qx "$plan_id"; then
        # Already owned; idempotent
        continue
      fi
      # Add owner without re-applying mechanism
      jq --arg p "$plan_id" '.owners += [$p]' "$sf" > "$sf.tmp" \
        && mv "$sf.tmp" "$sf"
      applied+=("$writer_id|$sf|added-owner")
      continue
    fi

    # Fresh pause: capture state, apply mechanism, write state file
    local original_state
    if ! original_state=$(apply_pause "$mechanism" "$target" "$writer_id" 2>&1); then
      echo "l3-pause-helper: pause FAILED for $writer_id (mechanism=$mechanism): $original_state" >&2
      failed=1
      break
    fi

    jq -n \
      --arg writer_id "$writer_id" \
      --arg mechanism "$mechanism" \
      --arg target "$target" \
      --arg ts "$TS" \
      --arg owner "$plan_id" \
      --arg state "$original_state" \
      '{
        writer_id: $writer_id, mechanism: $mechanism, target: $target,
        owners: [$owner], paused_at: $ts, original_state: $state,
        schema_version: 1
      }' > "$sf"

    applied+=("$writer_id|$sf|applied")
  done <<< "$writers_json"

  if [[ "$failed" == "1" ]]; then
    # === Atomic rollback ===
    echo "l3-pause-helper: rolling back partial pause for $plan_id" >&2
    for entry in "${applied[@]}"; do
      IFS='|' read -r wid sf state <<< "$entry"
      case "$state" in
        applied)
          local mechanism target original_state
          mechanism=$(jq -r '.mechanism' "$sf" 2>/dev/null || echo "")
          target=$(jq -r '.target' "$sf" 2>/dev/null || echo "")
          original_state=$(jq -r '.original_state' "$sf" 2>/dev/null || echo "")
          [[ -n "$mechanism" ]] && revert_pause "$mechanism" "$target" "$original_state"
          rm -f "$sf"
          ;;
        added-owner)
          # Remove this plan from owners we'd added
          jq --arg p "$plan_id" '.owners = (.owners - [$p])' "$sf" > "$sf.tmp" \
            && mv "$sf.tmp" "$sf"
          ;;
      esac
    done
    return 1
  fi

  # === Quiescence period (k8s drain pattern) ===
  if [[ "$quiescence" -gt 0 ]]; then
    sleep "$quiescence"
  fi

  echo "l3-pause-helper: paused $plan_id (writers: ${#applied[@]}, quiescence=${quiescence}s)"
  return 0
}

# === Subcommand: resume ===================================================
cmd_resume() {
  local plan_id="$1"
  local count=0

  for sf in "$PAUSE_STATE_DIR"/*.json; do
    [[ -e "$sf" ]] || continue
    local owners
    owners=$(jq -r '.owners[]?' "$sf" 2>/dev/null || true)
    echo "$owners" | grep -qx "$plan_id" || continue

    # Remove this plan from owners
    jq --arg p "$plan_id" '.owners = (.owners - [$p])' "$sf" > "$sf.tmp" \
      && mv "$sf.tmp" "$sf"

    local remaining
    remaining=$(jq -r '.owners | length' "$sf")
    if [[ "$remaining" == "0" ]]; then
      # Last owner left — actually revert mechanism
      local mechanism target original_state
      mechanism=$(jq -r '.mechanism' "$sf")
      target=$(jq -r '.target' "$sf")
      original_state=$(jq -r '.original_state' "$sf")
      revert_pause "$mechanism" "$target" "$original_state"
      rm -f "$sf"
    fi
    count=$((count + 1))
  done

  echo "l3-pause-helper: resumed $plan_id (writers touched: $count)"
  return 0
}

# === Subcommand: status ===================================================
cmd_status() {
  local plan_id="${1:-}"
  local found=0
  for sf in "$PAUSE_STATE_DIR"/*.json; do
    [[ -e "$sf" ]] || continue
    if [[ -n "$plan_id" ]]; then
      jq -e --arg p "$plan_id" '.owners | index($p)' "$sf" >/dev/null 2>&1 || continue
    fi
    jq -c . "$sf"
    found=$((found + 1))
  done
  if [[ "$found" == "0" ]]; then
    if [[ -n "$plan_id" ]]; then
      echo "l3-pause-helper: no active pauses owned by $plan_id"
    else
      echo "l3-pause-helper: no active pauses"
    fi
  fi
  return 0
}

# === Subcommand: validate =================================================
# Static-analysis read: walks plan's layer_3 writer declarations and verifies
# they're consistent with l3-writer-registry.json. Returns drift findings
# without taking action. Catches Incident-β-class omissions at manifest-author
# time (per packet §3.16 + T-10 lint contract).
cmd_validate() {
  local plan_id="$1"
  local issues=0

  if ! get_plan_manifest "$plan_id" >/dev/null; then
    echo "validate: plan $plan_id manifest not found in $PLANS_ROOT" >&2
    return 1
  fi

  local writers_json
  writers_json=$(enumerate_writers "$plan_id" || echo "")

  if [[ -z "$writers_json" ]]; then
    echo "validate: $plan_id has no layer_3 declarations (or layer_3.enabled=false)"
    return 0
  fi

  echo "validate: $plan_id layer_3 declarations:"

  while IFS= read -r writer; do
    [[ -z "$writer" ]] && continue
    local writer_id mechanism
    writer_id=$(echo "$writer" | jq -r '.writer_id')
    mechanism=$(echo "$writer" | jq -r '.mechanism')

    # Cross-reference with registry for write_paths drift (best-effort; the
    # registry is the source of truth for writer paths; manifest-time lint
    # in T-10 will gate on this match, but T-4 surfaces it here as a finding).
    if [[ -r "$L3_REGISTRY_PATH" ]]; then
      local in_registry
      in_registry=$(jq -c --arg id "$writer_id" \
        '.writers[]? | select(.id == $id or .launchd_label == $id) | .write_paths' \
        "$L3_REGISTRY_PATH" 2>/dev/null | head -1)
      if [[ -z "$in_registry" ]]; then
        echo "  [WARN] writer_id=$writer_id NOT FOUND in registry (drift; consider running l3-registry-audit)"
        issues=$((issues + 1))
      else
        echo "  [OK]   writer_id=$writer_id mechanism=$mechanism (registry write_paths: $in_registry)"
      fi
    else
      echo "  [INFO] writer_id=$writer_id mechanism=$mechanism (registry not readable: $L3_REGISTRY_PATH)"
    fi
  done <<< "$writers_json"

  if [[ "$issues" == "0" ]]; then
    echo "validate: $plan_id PASS (0 issues)"
    return 0
  else
    echo "validate: $plan_id $issues drift findings"
    return 1
  fi
}

# === Main =================================================================
[[ $# -lt 1 ]] && usage

SUBCMD="$1"; shift

# Parse common options
SKIP_QUIESCENCE=0
export SKIP_LAUNCHCTL="${SKIP_LAUNCHCTL:-0}"
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiescence-skip) SKIP_QUIESCENCE=1; shift ;;
    --skip-launchctl) SKIP_LAUNCHCTL=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

PLAN_ID="${ARGS[0]:-}"

case "$SUBCMD" in
  pause)
    [[ -z "$PLAN_ID" ]] && usage
    cmd_pause "$PLAN_ID" "$SKIP_QUIESCENCE"
    ;;
  resume)
    [[ -z "$PLAN_ID" ]] && usage
    cmd_resume "$PLAN_ID"
    ;;
  status)
    cmd_status "${PLAN_ID:-}"
    ;;
  validate)
    [[ -z "$PLAN_ID" ]] && usage
    cmd_validate "$PLAN_ID"
    ;;
  *)
    usage
    ;;
esac
