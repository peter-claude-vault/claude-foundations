#!/bin/bash
# Hook: PreCompact — Mechanically extract session state before compaction.
# Zero-LLM-cost: all bash/grep/sed/jq. Must complete in <3 seconds.
# Output matches Session Continuity Block schema from CLAUDE.md.
set -uo pipefail

source "$HOME/.claude/hooks/lib/paths.sh"

STATE_DIR="$HOOKS_STATE"
CHECKPOINT_FILE="$STATE_DIR/checkpoint.md"
SESSION_REGISTRY="$VAULT_LOGS/.coordination/session-registry.json"

INPUT=$(cat)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

mkdir -p "$STATE_DIR"

# --- Mechanical State Extraction ---
has_structured=false
plan_id=""
phase=""
task_id=""
completed_steps=""
files_modified=""
key_decisions=""
next_steps=""
ac_status=""
current_blocker=""

# 1. Find most recently modified plan file
if [[ -d "$PLANS_DIR" ]]; then
  # Check both flat .md files and dir-based plans (dir/plan.md or dir/tasks.md)
  active_plan=$(find "$PLANS_DIR" -maxdepth 2 -name "*.md" ! -name "_index.md" -type f -newer "$PLANS_DIR/_index.md" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
  if [[ -z "$active_plan" ]]; then
    active_plan=$(find "$PLANS_DIR" -maxdepth 2 -name "*.md" ! -name "_index.md" -type f -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
  fi

  if [[ -n "$active_plan" ]]; then
    # Extract plan slug from path
    rel_path="${active_plan#$PLANS_DIR/}"
    plan_id=$(echo "$rel_path" | sed 's|/.*||; s|\.md$||')
    has_structured=true

    # Extract phase: look for "Phase N" or "## Phase" markers with status
    phase=$(grep -iE '^\s*(#+\s*)?phase\s+[0-9]' "$active_plan" 2>/dev/null | grep -iE '(in.progress|current|active|\*\*)' | head -1 | sed 's/^[# ]*//' | head -c 100)
    if [[ -z "$phase" ]]; then
      # Fallback: last phase heading
      phase=$(grep -iE '^\s*(#+\s*)?phase\s+[0-9]' "$active_plan" 2>/dev/null | tail -1 | sed 's/^[# ]*//' | head -c 100)
    fi

    # Look for tasks.md in same directory
    plan_dir=$(dirname "$active_plan")
    tasks_file="$plan_dir/tasks.md"
    if [[ -f "$tasks_file" ]]; then
      # Grep for in-progress tasks (marked with [ ] or [~] or "in-progress")
      task_id=$(grep -iE '\[[ ~x]\].*in.progress|\-\s*\[~\]|\-\s*\[ \].*current' "$tasks_file" 2>/dev/null | head -3 | tr '\n' '; ' | head -c 300)
      completed_steps=$(grep -iE '\[x\]' "$tasks_file" 2>/dev/null | tail -10 | tr '\n' '; ' | head -c 500)
    fi

    # Extract next steps from plan
    next_steps=$(sed -n '/[Nn]ext [Ss]tep/,/^##/p' "$active_plan" 2>/dev/null | grep -E '^\s*-' | head -5 | tr '\n' '; ' | head -c 300)

    # Extract acceptance criteria status
    ac_status=$(sed -n '/[Aa]cceptance [Cc]riteria/,/^##/p' "$active_plan" 2>/dev/null | grep -E '^\s*-\s*\[' | head -10 | tr '\n' '; ' | head -c 300)
  fi
fi

# 2. Read session registry for touched files
if [[ -f "$SESSION_REGISTRY" ]]; then
  # Get touched files from the most recent active session
  registry_files=$(jq -r '.sessions | to_entries | map(select(.value.status == "active")) | sort_by(.value.last_heartbeat) | last | .value.touched_files // [] | .[]' "$SESSION_REGISTRY" 2>/dev/null | head -20 | tr '\n' '; ')
  if [[ -n "$registry_files" ]]; then
    files_modified="$registry_files"
    has_structured=true
  fi
fi

# 3. Read existing checkpoint for accumulated state
if [[ -f "$CHECKPOINT_FILE" ]] && [[ -s "$CHECKPOINT_FILE" ]]; then
  # Pull key_decisions and current_blocker from existing checkpoint if present
  if [[ -z "$key_decisions" ]]; then
    key_decisions=$(sed -n '/[Kk]ey [Dd]ecision/,/^##/p' "$CHECKPOINT_FILE" 2>/dev/null | grep -E '^\s*-' | head -5 | tr '\n' '; ' | head -c 300)
  fi
  if [[ -z "$current_blocker" ]]; then
    current_blocker=$(sed -n '/[Bb]locker\|[Ee]rror/,/^##/p' "$CHECKPOINT_FILE" 2>/dev/null | grep -E '^\s*-' | head -3 | tr '\n' '; ' | head -c 200)
  fi
  has_structured=true
fi

# --- Write checkpoint ---
if [[ "$has_structured" == "true" ]]; then
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  tmp="${CHECKPOINT_FILE}.tmp.$$"
  cat > "$tmp" <<EOF
# Session Continuity Block
**Generated:** $ts
**Source:** PreCompact hook — mechanical extraction

plan_id: $plan_id
phase: $phase
task_id: $task_id
completed_steps: $completed_steps
files_modified: $files_modified
key_decisions: $key_decisions
next_steps: $next_steps
ac_status: $ac_status
current_blocker: $current_blocker

## Action Required
- Resume from this checkpoint after compaction
- Re-read any files listed in files_modified if actively editing
EOF
  mv "$tmp" "$CHECKPOINT_FILE"

  context="SESSION CONTINUITY BLOCK: plan_id=${plan_id:-none} | phase=${phase:-unknown} | task_id=${task_id:-none} | files_modified=${files_modified:-none} | current_blocker=${current_blocker:-none}. Full state at $CHECKPOINT_FILE."
else
  # --- Transcript fallback (no structured sources) ---
  panic_context="No structured state sources found."
  if [[ -n "$TRANSCRIPT_PATH" ]] && [[ -f "$TRANSCRIPT_PATH" ]]; then
    last_actions=$(tail -50 "$TRANSCRIPT_PATH" 2>/dev/null | jq -r 'select(.type == "tool_use" or .type == "assistant") | .content // .tool_name // empty' 2>/dev/null | tail -10 | tr '\n' '; ' | head -c 500)
    if [[ -n "$last_actions" ]]; then
      panic_context="Panic checkpoint from transcript tail: ${last_actions}"
    fi
  fi

  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  tmp="${CHECKPOINT_FILE}.tmp.$$"
  cat > "$tmp" <<EOF
# Panic Checkpoint (auto-generated at compaction)
**Generated:** $ts
**Source:** PreCompact hook — no structured sources, transcript fallback

## Last Known Context
$panic_context

## Action Required
- Read this file to restore context
- Check task list for current progress
- Re-read any files you were actively editing
EOF
  mv "$tmp" "$CHECKPOINT_FILE"

  context="CHECKPOINT REFERENCE: Panic checkpoint generated at $CHECKPOINT_FILE. $panic_context Resume from this checkpoint after compaction."
fi

# Output additionalContext for the compacted conversation
jq -n --arg ctx "$context" \
  '{"hookSpecificOutput":{"hookEventName":"PreCompact","additionalContext":$ctx}}'
