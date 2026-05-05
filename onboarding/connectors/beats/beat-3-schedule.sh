#!/usr/bin/env bash
# onboarding/connectors/beats/beat-3-schedule.sh — SP14 T-9 (Plan 71 SP14
# Session 3a).
#
# Beat 3 of the connector wizard: render a compact per-connector table for
# every connectors[] entry written by Beat 2, allowing the user to override
# schedule, target_vault_path, and processor_skill per row. Defaults from
# Beat 2 (catalog-derived) apply when the user accepts a row unchanged.
#
# OUTPUT CONTRACT (R-43):
#   Files written: $USER_MANIFEST — jq-merge updates per-connector schedule
#                  and/or target_vault_path and/or processor_skill fields
#   Schema-types: user-manifest-schema.json#/properties/connectors/items
#   Pre-write validation: SP12 three-step gate (gate_apply) fires before write
#   Failure mode: BLOCK AND LOG. rc=2 bad invocation; rc=3 manifest write
#                 failure; rc=4 user aborted at three-step gate.
#
# Usage:
#   bash beat-3-schedule.sh [--manifest <path>] [--input-overrides <json>]
#                           [--accept-on-empty-stdin] [--no-gate]
#
# Flags:
#   --input-overrides <json>  Non-interactive JSON specifying per-connector
#                             field overrides for synthetic tests. Shape:
#                             '{"granola":{"schedule":"0 8 * * *",
#                                "target_vault_path":"Inbox/Custom/"}, ...}'
#   --accept-on-empty-stdin   On EOF/empty stdin at the three-step gate
#                             prompt, treat as "apply" (test-only).
#   --no-gate                 Skip the SP12 three-step gate (for synthetic
#                             tests that exercise the merge logic only).
#
# Exit codes:
#   0  success (manifest written or no changes)
#   2  bad invocation
#   3  manifest write failure
#   4  user aborted at three-step gate

set -u

_diag() { printf 'beat-3-schedule FAIL: %s\n' "$1" >&2; }
_info() { printf 'beat-3-schedule: %s\n' "$1"; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
GATE_LIB="$REPO_ROOT/onboarding/lib/three-step-gate.sh"
USER_MANIFEST="${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json"

manifest_arg=""
input_overrides=""
accept_eof=0
no_gate=0

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) [ $# -lt 2 ] && { _diag "--manifest requires path"; exit 2; }; manifest_arg="$2"; shift 2 ;;
    --input-overrides) [ $# -lt 2 ] && { _diag "--input-overrides requires JSON"; exit 2; }; input_overrides="$2"; shift 2 ;;
    --accept-on-empty-stdin) accept_eof=1; shift ;;
    --no-gate) no_gate=1; shift ;;
    -*) _diag "unknown flag: $1"; exit 2 ;;
    *) _diag "unexpected positional: $1"; exit 2 ;;
  esac
done

[ -n "$manifest_arg" ] && USER_MANIFEST="$manifest_arg"

if [ ! -r "$USER_MANIFEST" ]; then
  _diag "user-manifest not readable: $USER_MANIFEST (run Beat 1 + Beat 2 first)"
  exit 2
fi

connectors=$(jq -c '.connectors // []' "$USER_MANIFEST" 2>/dev/null)
n=$(printf '%s' "$connectors" | jq 'length')
if [ "$n" = "0" ]; then
  _info "connectors[] empty; nothing to schedule"
  exit 0
fi

# --- render per-connector table to stderr ---
printf '\nConnector Wizard — Beat 3 of 4\n' >&2
printf 'Per-connector schedule + target path + processor. Edit any row, or accept defaults.\n\n' >&2
printf '  %-15s | %-20s | %-25s | %-20s\n' "id" "schedule" "target_vault_path" "processor_skill" >&2
printf '  %-15s-+-%-20s-+-%-25s-+-%-20s\n' "---------------" "--------------------" "-------------------------" "--------------------" >&2
printf '%s' "$connectors" | jq -r '.[] | [.id, (.schedule // "—"), (.target_vault_path // "—"), (.processor_skill // "—")] | @tsv' \
  | while IFS=$'\t' read -r id sched tvp ps; do
      printf '  %-15s | %-20s | %-25s | %-20s\n' "$id" "$sched" "$tvp" "$ps" >&2
    done
printf '\n' >&2

# --- apply overrides ---
new_connectors="$connectors"
if [ -n "$input_overrides" ]; then
  # Validate input_overrides is JSON
  if ! printf '%s' "$input_overrides" | jq -e . >/dev/null 2>&1; then
    _diag "--input-overrides not valid JSON"
    exit 2
  fi
  new_connectors=$(printf '%s' "$connectors" | jq \
    --argjson o "$input_overrides" \
    '
      map(
        . as $c
        | if ($o[$c.id] // null) != null then
            $c + ($o[$c.id] | with_entries(select(.value != null)))
          else $c end
      )
    ' 2>/dev/null) || {
    _diag "override merge failed"
    exit 3
  }
else
  # Interactive: accept defaults for now (full per-row prompting is post-MVP)
  _info "no overrides provided; accepting catalog defaults for all connectors"
fi

# --- SP12 three-step gate before write ---
if [ "$no_gate" -eq 0 ]; then
  if [ ! -r "$GATE_LIB" ]; then
    _diag "three-step-gate.sh not readable at $GATE_LIB; pass --no-gate to skip"
    exit 2
  fi
  # shellcheck source=/dev/null
  . "$GATE_LIB"

  # Build a staging file with the proposed connectors[] for gate_preview/apply.
  stage_dir=$(mktemp -d -t beat3-gate-XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -rf '$stage_dir'" EXIT
  staging="$stage_dir/connectors.proposed.json"
  printf '%s\n' "$new_connectors" > "$staging"
  preview_target="$USER_MANIFEST.connectors-preview"
  current_connectors=$(printf '%s' "$connectors")
  printf '%s\n' "$current_connectors" > "$preview_target"

  apply_args="--skip-preview"
  [ "$accept_eof" -eq 1 ] && apply_args="$apply_args --accept-on-empty-stdin"

  if ! gate_apply "$staging" "$preview_target" $apply_args; then
    _diag "user aborted at three-step gate"
    exit 4
  fi
  rm -f "$preview_target"
fi

# --- merge connectors[] back into user-manifest ---
base_json=$(cat "$USER_MANIFEST")
new_json=$(printf '%s' "$base_json" | jq --argjson c "$new_connectors" '.connectors = $c' 2>/dev/null) || {
  _diag "jq merge failed"
  exit 3
}

tmp="$USER_MANIFEST.tmp.$$"
printf '%s\n' "$new_json" > "$tmp" || { _diag "tmp write failed"; exit 3; }
mv -f "$tmp" "$USER_MANIFEST" || { _diag "atomic mv failed"; exit 3; }

_info "Beat 3 applied; $n connectors updated in $USER_MANIFEST"
exit 0
