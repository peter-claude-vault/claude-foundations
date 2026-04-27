#!/bin/bash
# Research queue management — shared functions for intake hook and overnight runner.
# Queue file: ~/.claude/hooks/state/research-queue.json

QUEUE_FILE="$HOME/.claude/hooks/state/research-queue.json"
QUEUE_LOCK="$HOME/.claude/hooks/state/research-queue.lock"
MAX_QUEUE_DEPTH=20
PRUNE_AGE_DAYS=7

# Ensure queue file exists with valid structure.
ensure_queue() {
  if [[ ! -f "$QUEUE_FILE" ]] || [[ ! -s "$QUEUE_FILE" ]]; then
    printf '{"queue":[]}\n' > "$QUEUE_FILE"
  fi
}

# Read queue JSON. Creates file if missing.
read_queue() {
  ensure_queue
  cat "$QUEUE_FILE"
}

# Atomic write. Arg: JSON content.
write_queue() {
  local tmp="${QUEUE_FILE}.tmp.$$"
  printf '%s\n' "$1" > "$tmp"
  mv "$tmp" "$QUEUE_FILE"
}

# Add item to queue. Args: project_name, notes, priority (normal|urgent).
# Returns 0 on success, 1 if queue full or duplicate.
queue_add() {
  local project="$1" notes="$2" priority="${3:-normal}"
  local queue now depth existing

  queue=$(read_queue)
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Check for duplicate (same project, status pending or in-progress)
  existing=$(echo "$queue" | jq -r --arg p "$project" \
    '[.queue[] | select(.project == $p and (.status == "pending" or .status == "in-progress"))] | length')
  if (( existing > 0 )); then
    return 1
  fi

  # Check max depth (only count active items)
  depth=$(echo "$queue" | jq '[.queue[] | select(.status == "pending" or .status == "in-progress")] | length')
  if (( depth >= MAX_QUEUE_DEPTH )); then
    return 1
  fi

  queue=$(echo "$queue" | jq --arg p "$project" --arg n "$notes" --arg pri "$priority" --arg ts "$now" \
    '.queue += [{"project":$p,"notes":$n,"queued_at":$ts,"status":"pending","priority":$pri,"research_output":null}]')

  write_queue "$queue"
  return 0
}

# Pick up to N pending items (urgent first, then FIFO). Args: max_count.
# Outputs JSON array of items.
queue_pick() {
  local max="${1:-3}"
  read_queue | jq --argjson max "$max" \
    '[.queue[] | select(.status == "pending")] |
     sort_by(if .priority == "urgent" then 0 else 1 end, .queued_at) |
     .[:$max]'
}

# Update item status. Args: project_name, new_status, research_output (optional).
queue_update_status() {
  local project="$1" new_status="$2" output="${3:-}"
  local queue

  queue=$(read_queue)

  if [[ -n "$output" ]]; then
    queue=$(echo "$queue" | jq --arg p "$project" --arg s "$new_status" --arg o "$output" \
      '(.queue[] | select(.project == $p and (.status == "pending" or .status == "in-progress"))) |= (.status = $s | .research_output = $o)')
  else
    queue=$(echo "$queue" | jq --arg p "$project" --arg s "$new_status" \
      '(.queue[] | select(.project == $p and (.status == "pending" or .status == "in-progress"))) |= (.status = $s)')
  fi

  write_queue "$queue"
}

# Prune completed/failed items older than PRUNE_AGE_DAYS.
queue_prune() {
  local queue cutoff_epoch now_epoch item_ts item_epoch
  queue=$(read_queue)
  now_epoch=$(date +%s)
  cutoff_epoch=$(( now_epoch - PRUNE_AGE_DAYS * 86400 ))

  queue=$(echo "$queue" | jq --argjson cutoff "$cutoff_epoch" '
    .queue |= [.[] | select(
      (.status == "pending" or .status == "in-progress") or
      ((.queued_at | split(".")[0] | sub("Z$"; "") | strptime("%Y-%m-%dT%H:%M:%S") | mktime) > $cutoff)
    )]')

  write_queue "$queue"
}
