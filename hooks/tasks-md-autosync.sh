#!/bin/bash
# Hook: PostToolUse (Edit|Write) — Sync tasks.md status when progress-log
# records a task completion via canonical marker comment.
#
# Contract: writer appends `<!-- task-done: <subplan>/T-<N> -->` (or
# `<!-- task-done: T-<N> -->` for single-plan cases) inside a progress-log
# entry. This hook scans backlog-progress files for those markers and
# idempotently flips the matching task's `**Status:**` field in tasks.md
# to `done`.
#
# Never blocks. Silent on no-op. Errors to hook-audit log.
set -uo pipefail

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# Only fire on backlog-progress writes
if [[ -z "$FILE_PATH" ]] || [[ "$FILE_PATH" != *"/Logs/backlog-progress/"*".md" ]]; then
  exit 0
fi

[[ ! -f "$FILE_PATH" ]] && exit 0

LOG_FILE="$HOOKS_STATE/tasks-md-autosync.log"
mkdir -p "$(dirname "$LOG_FILE")"
TS=$(date -Iseconds)

# Section E-3-adjacent toggle (Plan 71 SP10 T-5): short-circuit when user opted
# out via /onboard. Default-enabled; opt-out is explicit `false`. Audit log
# entry written before exit.
hook_enabled="$(_manifest_get .behavioral.hook_preferences.tasks_autosync_enabled 2>/dev/null || true)"
if [ "$hook_enabled" = "false" ]; then
  echo "$TS | skip | manifest-disabled | $FILE_PATH" >> "$LOG_FILE"
  exit 0
fi

# Resolve parent plan dir via frontmatter
PARENT_PLAN=$(awk '/^---$/{c++; next} c==1 && /^parent_plan:/{sub(/^parent_plan:[[:space:]]*/,""); print; exit}' "$FILE_PATH")
if [[ -z "$PARENT_PLAN" ]]; then
  echo "$TS | skip | no-parent-plan | $FILE_PATH" >> "$LOG_FILE"
  exit 0
fi

# Find plan directory — bare slug OR NN-<slug> prefix
PLAN_DIR=""
if [[ -d "$PLANS_DIR/$PARENT_PLAN" ]]; then
  PLAN_DIR="$PLANS_DIR/$PARENT_PLAN"
else
  for candidate in "$PLANS_DIR"/*-"$PARENT_PLAN"; do
    if [[ -d "$candidate" ]]; then PLAN_DIR="$candidate"; break; fi
  done
fi
if [[ -z "$PLAN_DIR" ]]; then
  echo "$TS | skip | plan-dir-not-found | parent=$PARENT_PLAN" >> "$LOG_FILE"
  exit 0
fi

# Extract all task-done markers. Two forms:
#   <!-- task-done: NN/T-M -->   (sub-plan NN, task T-M)
#   <!-- task-done: T-M -->      (plan root tasks.md)
MARKERS=$(grep -oE '<!-- task-done: ([0-9]+/)?T-[0-9]+ -->' "$FILE_PATH" | sort -u)
if [[ -z "$MARKERS" ]]; then
  exit 0  # no markers → nothing to sync
fi

FLIPPED_COUNT=0
while IFS= read -r marker; do
  # Parse: <!-- task-done: 02/T-3 --> or <!-- task-done: T-3 -->
  body=$(echo "$marker" | sed 's/^<!-- task-done: //; s/ -->$//')
  subplan=""
  taskid=""
  if [[ "$body" == *"/"* ]]; then
    subplan="${body%%/*}"
    taskid="${body##*/}"
  else
    taskid="$body"
  fi

  # Locate target tasks.md
  TASKS_MD=""
  if [[ -n "$subplan" ]]; then
    for candidate in "$PLAN_DIR/${subplan}-"*; do
      if [[ -d "$candidate" ]] && [[ -f "$candidate/tasks.md" ]]; then
        TASKS_MD="$candidate/tasks.md"
        break
      fi
    done
  else
    [[ -f "$PLAN_DIR/tasks.md" ]] && TASKS_MD="$PLAN_DIR/tasks.md"
  fi
  if [[ -z "$TASKS_MD" ]]; then
    echo "$TS | skip | tasks-md-not-found | parent=$PARENT_PLAN subplan=$subplan task=$taskid" >> "$LOG_FILE"
    continue
  fi

  # Idempotent flip via python — find ### T-N: section, flip **Status:** to done
  RESULT=$(python3 - "$TASKS_MD" "$taskid" <<'PY' 2>/dev/null
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
task = sys.argv[2]
txt = p.read_text()
pattern = rf'(### {re.escape(task)}:[^\n]*\n\n\*\*Status:\*\*\s+)([a-z\-]+)'
m = re.search(pattern, txt)
if not m:
    print("no-match")
    sys.exit(0)
if m.group(2) == 'done':
    print("already-done")
    sys.exit(0)
new_txt = re.sub(pattern, lambda mm: mm.group(1) + 'done', txt, count=1)
p.write_text(new_txt)
print(f"flipped:{m.group(2)}->done")
PY
)
  case "$RESULT" in
    flipped:*)
      FLIPPED_COUNT=$((FLIPPED_COUNT+1))
      echo "$TS | flip | $TASKS_MD | $taskid | $RESULT" >> "$LOG_FILE"
      ;;
    already-done)
      : # idempotent no-op
      ;;
    no-match)
      echo "$TS | warn | task-id-not-found | $TASKS_MD | $taskid" >> "$LOG_FILE"
      ;;
    *)
      echo "$TS | error | unexpected-result | $TASKS_MD | $taskid | $RESULT" >> "$LOG_FILE"
      ;;
  esac
done <<< "$MARKERS"

if [[ $FLIPPED_COUNT -gt 0 ]]; then
  echo "$TS | summary | $FILE_PATH | flipped=$FLIPPED_COUNT" >> "$LOG_FILE"
fi

exit 0
