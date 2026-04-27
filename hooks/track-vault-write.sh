#!/bin/bash
# Hook: PostToolUse (Edit|Write) — Track vault file writes in session registry.
# Overlap warnings surface via prompt-context.sh on the next UserPromptSubmit.
# (PostToolUse additionalContext confirmed non-functional — 2026-03-30 smoke test.)
set -euo pipefail

source "$HOME/.claude/hooks/lib/paths.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/registry.sh"

# Parse stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
if [[ -z "$SESSION_ID" ]]; then
  exit 0
fi

# Extract file path from tool_input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Only track vault files
REL_PATH=$(vault_relative "$FILE_PATH")
if [[ -z "$REL_PATH" ]]; then
  exit 0
fi

# Update registry under lock (adds to touched_files, updates heartbeat)
export MSC_SESSION_ID="$SESSION_ID"
export MSC_FILE_PATH="$REL_PATH"
lockf -k "$REGISTRY_LOCK" "$SCRIPT_DIR/lib/registry-op.sh" update-files > /dev/null

# --- Backlog intake detection ---
# If the written file is System Backlog.md, detect new "idea" rows and fire triage.
if [[ "$REL_PATH" == "System Backlog.md" ]]; then
  STATE_DIR="$SCRIPT_DIR/state"
  SNAPSHOT="$STATE_DIR/backlog-snapshot.md"
  BACKLOG_FILE="$VAULT_ROOT/System Backlog.md"
  TRIAGE_LOG="$STATE_DIR/backlog-triage-trigger.log"

  # Source queue management
  source "$SCRIPT_DIR/lib/research-queue.sh"

  # Create snapshot on first run
  if [[ ! -f "$SNAPSHOT" ]]; then
    cp "$BACKLOG_FILE" "$SNAPSHOT"
    exit 0
  fi

  # Find new lines in the backlog (added lines from diff, macOS-compatible)
  NEW_LINES=$(diff "$SNAPSHOT" "$BACKLOG_FILE" 2>/dev/null | grep '^> ' | sed 's/^> //' || true)

  # Save previous snapshot for status-transition detection, then update
  cp "$SNAPSHOT" "$STATE_DIR/backlog-snapshot-prev.md"
  cp "$BACKLOG_FILE" "$SNAPSHOT"

  # Look for new table rows with status "idea"
  # Table rows start with "| " and contain " idea " as a status field
  NEW_IDEAS=$(echo "$NEW_LINES" | grep -E '^\|[^|]+\| *idea *\|' || true)

  if [[ -n "$NEW_IDEAS" ]]; then
    # Extract project names (first column after leading pipe)
    while IFS= read -r row; do
      PROJECT=$(echo "$row" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
      if [[ -z "$PROJECT" ]]; then
        continue
      fi

      # Fire triage as background process (must not block hook)
      CLAUDE="$HOME/.local/bin/claude"
      if [[ -x "$CLAUDE" ]]; then
        (
          # Per-session triage log (avoids stale grep from cumulative file)
          SESSION_TRIAGE_LOG="$STATE_DIR/triage-session-$(date +%Y%m%d-%H%M%S)-$$.log"

          nohup "$CLAUDE" -p "You are running as an automated trigger. Triage this new backlog item:

/backlog-triage --item $PROJECT

After triage completes, if the result is NOVEL, report the project name and notes so downstream automation can queue it for research.
IMPORTANT: Output exactly one line in the format: TRIAGE_RESULT=NOVEL (or DUPLICATE, OVERLAP, DEFERRED)" \
            --add-dir "$HOME" \
            --add-dir "$VAULT_ROOT" \
            --permission-mode bypassPermissions \
            --model sonnet \
            --max-budget-usd 1 \
            > "$SESSION_TRIAGE_LOG" 2>&1

          # Append to cumulative log for audit trail
          cat "$SESSION_TRIAGE_LOG" >> "$TRIAGE_LOG"

          # Check session-scoped output with flexible pattern matching
          # Matches: "Triage Result: NOVEL", "Result: NOVEL", "**Result: NOVEL**",
          #          "Result is **NOVEL**", "TRIAGE_RESULT=NOVEL"
          TRIAGE_RESULT=$(grep -oE '(Triage )?Result[: =]+\**\s*(NOVEL|DUPLICATE|OVERLAP|DEFERRED)\**' "$SESSION_TRIAGE_LOG" 2>/dev/null | grep -oE '(NOVEL|DUPLICATE|OVERLAP|DEFERRED)' | tail -1 || true)
          if [[ "$TRIAGE_RESULT" == "NOVEL" ]]; then
            NOTES=$(echo "$row" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $NF); print $NF}')
            source "$SCRIPT_DIR/lib/research-queue.sh"
            queue_add "$PROJECT" "$NOTES" "normal" || true
            echo "$(date -Iseconds) Queued '$PROJECT' for research (triage=NOVEL)" >> "$TRIAGE_LOG"
          else
            echo "$(date -Iseconds) Triage result for '$PROJECT': ${TRIAGE_RESULT:-UNKNOWN} — not queuing" >> "$TRIAGE_LOG"
          fi

          # Clean up session log after merge
          rm -f "$SESSION_TRIAGE_LOG"
        ) &
        disown
      fi
    done <<< "$NEW_IDEAS"

    echo "$(date -Iseconds) Detected new idea(s), triage triggered" >> "$TRIAGE_LOG"
  fi

  # --- Status transition detection: briefed → planned ---
  # Compare old snapshot vs new file at row level to detect status column changes.
  # This catches in-place edits, not just new rows.
  PLAN_GEN_LOG="$STATE_DIR/plan-generation-trigger.log"

  # Extract project names with a given status from a backlog file.
  # Parses all markdown table rows, matches status column (field 3 after pipe-split).
  # Args: file_path status_value → outputs one project name per line.
  extract_projects_by_status() {
    local file="$1" status="$2"
    awk -F'|' -v s="$status" '
      /^\|/ && !/^\|[-]+/ && !/^\| *Project/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $3)
        if ($3 == s) {
          gsub(/^[ \t]+|[ \t]+$/, "", $2)
          if ($2 != "") print $2
        }
      }
    ' "$file"
  }

  # Get projects that were "briefed" in old snapshot
  OLD_BRIEFED=$(extract_projects_by_status "$STATE_DIR/backlog-snapshot-prev.md" "briefed" 2>/dev/null || true)
  # Get projects that are now "planned" in new file
  NEW_PLANNED=$(extract_projects_by_status "$BACKLOG_FILE" "planned")

  # Find projects that transitioned: were briefed, now planned
  TRANSITIONED=""
  if [[ -n "$OLD_BRIEFED" ]]; then
    while IFS= read -r project; do
      [[ -z "$project" ]] && continue
      if echo "$NEW_PLANNED" | grep -qxF "$project"; then
        TRANSITIONED="${TRANSITIONED}${project}"$'\n'
      fi
    done <<< "$OLD_BRIEFED"
  fi

  if [[ -n "$TRANSITIONED" ]]; then
    while IFS= read -r PROJECT; do
      [[ -z "$PROJECT" ]] && continue

      # Derive slug: lowercase, spaces→hyphens, strip non-alphanumeric except hyphens
      SLUG=$(echo "$PROJECT" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
      PLAN_DIR="$PLANS_DIR/$SLUG"
      BRIEF="$PLAN_DIR/00-ideation-brief.md"

      # Graceful failure: if no ideation brief exists, log and skip
      if [[ ! -f "$BRIEF" ]]; then
        echo "$(date -Iseconds) WARN: briefed→planned detected for '$PROJECT' (slug: $SLUG) but no ideation brief at $BRIEF — skipping plan generation" >> "$PLAN_GEN_LOG"
        continue
      fi

      echo "$(date -Iseconds) Detected briefed→planned transition for '$PROJECT' (slug: $SLUG) — checking plan state" >> "$PLAN_GEN_LOG"

      # Check if manifest already exists (draft plan from research phase)
      MANIFEST="$PLAN_DIR/manifest.json"
      VALIDATOR="$HOME/.claude/orchestrator/validate-manifest.sh"

      # Extract Notes column for [FEEDBACK:] tag
      NOTES=$(awk -F'|' -v p="$PROJECT" '
        /^\|/ && !/^\|[-]+/ && !/^\| *Project/ {
          gsub(/^[ \t]+|[ \t]+$/, "", $2)
          if ($2 == p) { n=NF; gsub(/^[ \t]+|[ \t]+$/, "", $n); print $n }
        }
      ' "$BACKLOG_FILE")
      FEEDBACK=""
      if [[ "$NOTES" == *"[FEEDBACK:"* ]]; then
        FEEDBACK=$(echo "$NOTES" | sed -n 's/.*\[FEEDBACK: *\(.*\)\].*/\1/p')
      fi

      CLAUDE="$HOME/.local/bin/claude"
      if [[ -x "$CLAUDE" ]]; then
        (
          TODAY=$(date +%Y-%m-%d)
          LOG_DIR="$HOME/Desktop/artefact-daily-logs"
          mkdir -p "$LOG_DIR"
          GEN_LOG="$LOG_DIR/plan-generation-${TODAY}.log"
          BACKLOG="$VAULT_ROOT/System Backlog.md"

          if [[ -f "$MANIFEST" ]] && [[ -n "$FEEDBACK" ]]; then
            # --- Path A: Existing manifest + feedback → revision session ---
            echo "$(date -Iseconds) Manifest exists + [FEEDBACK:] detected for $SLUG — spawning revision session" >> "$GEN_LOG"

            nohup "$CLAUDE" -p "You are running as an automated plan-revision trigger. A System Backlog item has transitioned from briefed to planned WITH feedback.

Project: $PROJECT
Slug: $SLUG
Plan directory: $PLAN_DIR
Feedback: $FEEDBACK

## Instructions

1. Read the existing plan artifacts:
   - $PLAN_DIR/spec.md
   - $PLAN_DIR/tasks.md
   - $PLAN_DIR/manifest.json
   - $PLAN_DIR/00-ideation-brief.md

2. Apply the feedback: $FEEDBACK
   - Revise spec.md, tasks.md, and manifest.json accordingly
   - Preserve any existing decisions that are not contradicted by the feedback
   - Update the manifest schema validation

3. Update System Backlog.md:
   - Set Location to: \`plan: $SLUG\`
   - Set Last Updated to: $TODAY
   - Remove the [FEEDBACK:] tag from Notes after applying

After revising, report what changed." \
              --add-dir "$HOME" \
              --add-dir "$VAULT_ROOT" \
              --permission-mode bypassPermissions \
              --model sonnet \
              --max-budget-usd 3 \
              >> "$GEN_LOG" 2>&1

          elif [[ -f "$MANIFEST" ]]; then
            # --- Path B: Existing manifest, no feedback → validate and promote ---
            echo "$(date -Iseconds) Manifest already exists for $SLUG — skipping generation, validating directly" >> "$GEN_LOG"

          else
            # --- Path C: No manifest → generate from scratch (original behavior) ---
            echo "$(date -Iseconds) No manifest for $SLUG — generating plan artifacts from brief" >> "$GEN_LOG"

            nohup "$CLAUDE" -p "You are running as an automated plan-generation trigger. A System Backlog item has transitioned from briefed to planned.

Project: $PROJECT
Slug: $SLUG
Plan directory: $PLAN_DIR

## Instructions

1. Read the ideation brief at: $BRIEF
2. Read the spec template at: $HOME/.claude/templates/spec-template.md
3. Read the tasks template at: $HOME/.claude/templates/tasks-template.md
4. Read the manifest schema at: $HOME/.claude/schemas/plan-manifest-schema.json

5. Generate $PLAN_DIR/spec.md:
   - Follow the spec template structure exactly
   - Fill in all sections using information from the ideation brief
   - Set Status to 'planned', Parent to the appropriate parent if mentioned in the brief
   - Include concrete file paths, design decisions, constraints, and risk assessment
   - The spec should be complete enough for a developer to implement without the brief

6. Generate $PLAN_DIR/tasks.md:
   - Follow the tasks template structure exactly
   - Break the work into 3-8 tasks with clear dependencies
   - Every task MUST have File References (absolute paths)
   - Acceptance Criteria: 3-5 bullets each, all verb-first
   - Descriptions: 200-800 tokens each

7. Generate $PLAN_DIR/manifest.json:
   - Must conform to the manifest schema
   - project: '$PROJECT'
   - spec_path: '$PLAN_DIR/spec.md'
   - Task IDs: T-1, T-2, etc.
   - Each task needs: id, title, description, acceptance_criteria, file_references, depends_on
   - Set sensible max_budget_usd per task (default 5)
   - Use parallel_group where tasks are independent and don't share file_references

8. Update System Backlog.md:
   - Find the row for '$PROJECT'
   - Set Location to: \`plan: $SLUG\`
   - Set Last Updated to: $TODAY

After generating all files, report the file paths you created." \
              --add-dir "$HOME" \
              --add-dir "$VAULT_ROOT" \
              --permission-mode bypassPermissions \
              --model sonnet \
              --max-budget-usd 3 \
              >> "$GEN_LOG" 2>&1
          fi

          # Post-generation/revision: validate manifest and optionally promote to ready
          MANIFEST="$PLAN_DIR/manifest.json"

          if [[ -f "$MANIFEST" ]] && [[ -x "$VALIDATOR" ]]; then
            if "$VALIDATOR" "$MANIFEST" >> "$GEN_LOG" 2>&1; then
              echo "$(date -Iseconds) Manifest validation PASSED for $SLUG" >> "$GEN_LOG"

              # Check if all dependency projects are complete
              DEPS_MET=true
              DEP_PROJECTS=$(awk -F'|' -v p="$PROJECT" '
                /^\|/ && !/^\|[-]+/ && !/^\| *Project/ {
                  gsub(/^[ \t]+|[ \t]+$/, "", $2)
                  if ($2 == p) {
                    gsub(/^[ \t]+|[ \t]+$/, "", $8)
                    print $8
                  }
                }
              ' "$BACKLOG")

              if [[ -n "$DEP_PROJECTS" ]] && [[ "$DEP_PROJECTS" != "—" ]] && [[ "$DEP_PROJECTS" != "-" ]]; then
                IFS=',' read -ra DEP_LIST <<< "$DEP_PROJECTS"
                for dep in "${DEP_LIST[@]}"; do
                  dep=$(echo "$dep" | sed 's/^[ \t]*//;s/[ \t]*$//')
                  [[ -z "$dep" || "$dep" == "—" || "$dep" == "-" ]] && continue
                  DEP_STATUS=$(awk -F'|' -v d="$dep" '
                    /^\|/ && !/^\|[-]+/ && !/^\| *Project/ {
                      gsub(/^[ \t]+|[ \t]+$/, "", $2)
                      if ($2 == d) {
                        gsub(/^[ \t]+|[ \t]+$/, "", $3)
                        print $3
                      }
                    }
                  ' "$BACKLOG")
                  if [[ "$DEP_STATUS" != "complete" ]]; then
                    DEPS_MET=false
                    echo "$(date -Iseconds) Dependency '$dep' not complete (status: $DEP_STATUS) — not promoting $SLUG to ready" >> "$GEN_LOG"
                  fi
                done
              fi

              if $DEPS_MET; then
                sed -i '' "s/^\(|[^|]*$PROJECT[^|]*\)| *planned *|/\1| ready |/" "$BACKLOG" 2>/dev/null || true
                echo "$(date -Iseconds) Auto-promoted $SLUG to 'ready' (manifest valid + all deps complete)" >> "$GEN_LOG"
              fi
            else
              echo "$(date -Iseconds) Manifest validation FAILED for $SLUG — leaving at 'planned'" >> "$GEN_LOG"
            fi
          else
            echo "$(date -Iseconds) WARN: Manifest or validator not found after generation for $SLUG" >> "$GEN_LOG"
          fi
        ) &
        disown
      fi
    done <<< "$TRANSITIONED"

    echo "$(date -Iseconds) Detected briefed→planned transition(s), plan generation triggered" >> "$PLAN_GEN_LOG"
  fi
fi

exit 0
