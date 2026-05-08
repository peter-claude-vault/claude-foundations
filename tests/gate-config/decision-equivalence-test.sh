#!/bin/bash
# decision-equivalence-test.sh — Plan 80/81 SP01 T-16 fixture corpus runner.
#
# Snapshots pre-write-guard.sh decisions across the fixture corpus at
# tests/gate-config/fixtures/. Compares against baseline-pre-t6-refactor.json (if
# present); creates baseline if --snapshot flag passed.
#
# Usage:
#   decision-equivalence-test.sh                 # compare current decisions vs baseline
#   decision-equivalence-test.sh --snapshot      # snapshot current decisions as baseline
#   decision-equivalence-test.sh --hook PATH     # use alternate hook path (default: live)
#
# Behavior-preservation contract: T-6 refactors pre-write-guard.sh to read
# R-32/R-47 from gate-config.json. Post-refactor decisions MUST match baseline
# verbatim across this corpus. Divergence count > 0 fails A1 anti-success
# criterion.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
BASELINE_FILE="$SCRIPT_DIR/baseline-pre-t6-refactor.json"
HOOK="${HOOK:-$HOME/.claude/hooks/pre-write-guard.sh}"
SNAPSHOT_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) SNAPSHOT_MODE=1; shift ;;
    --hook) HOOK="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# //; s/^#//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ ! -x "$HOOK" ]] && { echo "Hook not executable: $HOOK" >&2; exit 1; }
[[ ! -d "$FIXTURES_DIR" ]] && { echo "Fixtures dir missing: $FIXTURES_DIR" >&2; exit 1; }

VAULT_ROOT_REAL="${VAULT_ROOT:-$HOME/Documents/Obsidian Vault}"

# Derive decision class from hook stdout + stderr.
classify() {
  local stdout="$1"
  local exit_code="$2"

  # Empty stdout + exit 0 → allow / pass-through
  if [[ -z "$stdout" ]] && [[ "$exit_code" -eq 0 ]]; then
    echo "allow"
    return
  fi

  # Non-zero exit → hook crash; classify separately
  if [[ "$exit_code" -ne 0 ]]; then
    echo "crash-rc-$exit_code"
    return
  fi

  # Stdout JSON inspection
  local decision
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // "unknown"' <<< "$stdout" 2>/dev/null || echo "parse-fail")
  local reason
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // .hookSpecificOutput.additionalContext // ""' <<< "$stdout" 2>/dev/null || echo "")

  case "$decision" in
    deny)
      # Distinguish R-32 type/required-field deny vs R-32 tag deny
      if grep -qiE 'type|required|schema' <<< "$reason"; then
        echo "deny-r32-type"
      elif grep -qiE 'tag|taxonomy' <<< "$reason"; then
        echo "deny-r32-tags"
      elif grep -qiE 'plan-71-live-guard|R-55' <<< "$reason"; then
        echo "g1-deny"
      else
        echo "deny-other"
      fi
      ;;
    allow)
      # G1 allow-carve-out / allow-override emits permissionDecision: allow
      if grep -qiE 'plan-71-live-guard|carve-out|override' <<< "$reason"; then
        echo "g1-allow"
      else
        echo "allow-explicit"
      fi
      ;;
    *)
      echo "unknown-$decision"
      ;;
  esac
}

# Evaluate one fixture; emit JSON line {id, expected, observed}.
eval_fixture() {
  local fixture_id="$1"
  local input_file="$2"
  local expected="$3"

  # Substitute placeholders. jq's gsub for $VAULT_ROOT and $HOME.
  local input_json
  input_json=$(jq --arg vr "$VAULT_ROOT_REAL" --arg home "$HOME" \
    '.tool_input.file_path |= (gsub("\\$VAULT_ROOT"; $vr) | gsub("\\$HOME"; $home))' \
    "$FIXTURES_DIR/$input_file")

  # Invoke hook with stdin = input_json. HOOKS_STATE_OVERRIDE isolates G1
  # state writes to a tmp dir so the live overrides log doesn't get polluted.
  local tmp_state
  tmp_state=$(mktemp -d -t sp01-fixture-state.XXXXXX)
  local stdout
  local exit_code
  stdout=$(HOOKS_STATE_OVERRIDE="$tmp_state" "$HOOK" <<< "$input_json" 2>/dev/null)
  exit_code=$?
  rm -rf "$tmp_state"

  local observed
  observed=$(classify "$stdout" "$exit_code")

  # Build result row
  jq -nc \
    --arg id "$fixture_id" \
    --arg expected "$expected" \
    --arg observed "$observed" \
    --arg stdout "$stdout" \
    --arg exit "$exit_code" \
    '{id: $id, expected: $expected, observed: $observed, exit_code: ($exit | tonumber), stdout_preview: ($stdout | .[0:300])}'
}

# Read manifest; iterate fixtures.
MANIFEST="$FIXTURES_DIR/manifest.json"
[[ ! -f "$MANIFEST" ]] && { echo "Manifest missing: $MANIFEST" >&2; exit 1; }

RESULTS=()
while IFS=$'\t' read -r id input_file expected; do
  RESULTS+=("$(eval_fixture "$id" "$input_file" "$expected")")
done < <(jq -r '.fixtures[] | [.id, .input_file, (.expected_class_override // .expected_class)] | @tsv' "$MANIFEST")

# Aggregate
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RESULTS_JSON=$(printf '%s\n' "${RESULTS[@]}" | jq -s '.')
SUMMARY=$(jq -nc \
  --arg ts "$TS" \
  --arg hook "$HOOK" \
  --argjson results "$RESULTS_JSON" \
  '{
    ts: $ts,
    hook_path: $hook,
    fixture_count: ($results | length),
    decisions: $results,
    decision_class_counts: ($results | map(.observed) | group_by(.) | map({key: .[0], value: length}) | from_entries),
    expected_match_count: ($results | map(select(.expected == .observed)) | length),
    divergence_count: ($results | map(select(.expected != .observed)) | length),
    divergences: ($results | map(select(.expected != .observed)) | map({id, expected, observed}))
  }')

if [[ "$SNAPSHOT_MODE" -eq 1 ]]; then
  echo "$SUMMARY" | jq '.' > "$BASELINE_FILE"
  echo "Baseline snapshotted to: $BASELINE_FILE"
  jq '{ts, fixture_count, expected_match_count, divergence_count, decision_class_counts}' "$BASELINE_FILE"
  exit 0
fi

# Compare mode
if [[ ! -f "$BASELINE_FILE" ]]; then
  echo "ERROR: no baseline at $BASELINE_FILE — run with --snapshot to create" >&2
  exit 1
fi

DIVERGENCES_VS_BASELINE=$(jq -n \
  --argjson baseline "$(cat "$BASELINE_FILE")" \
  --argjson current "$SUMMARY" \
  '
  ($baseline.decisions | INDEX(.id)) as $bidx
  | $current.decisions
  | map(. as $cur | {
      id: .id,
      baseline_observed: ($bidx[$cur.id].observed),
      current_observed: $cur.observed,
      drift: ($bidx[$cur.id].observed != $cur.observed)
    })
  | map(select(.drift == true))
  ')

DIVERGENCE_COUNT=$(jq 'length' <<< "$DIVERGENCES_VS_BASELINE")
echo "Fixture count: $(jq '.fixture_count' <<< "$SUMMARY")"
echo "Decision-class divergences vs baseline: $DIVERGENCE_COUNT"

if [[ "$DIVERGENCE_COUNT" -gt 0 ]]; then
  echo "Divergent fixtures:"
  jq '.' <<< "$DIVERGENCES_VS_BASELINE"
  echo ""
  echo "FAIL: A1 anti-success criterion (R-32/R-47 unjustified divergence)"
  exit 1
fi

echo "PASS: zero divergences vs baseline"
