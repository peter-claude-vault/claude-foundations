#!/bin/bash
# auto-commit-surfaces.sh — SessionEnd hook: auto-commit dirty state in
# claude-home + claude-plans git repos, push to all configured remotes.
#
# Module 16-D of spine-remediation Session 16 (2026-04-14). Registered in
# settings.json SessionEnd hooks. Fail-soft by design — never blocks session end.
#
# Skip condition: canary-editing.lock in $HOOKS_STATE reserves the path for
# Session 14's canary forensic edits; normally a no-op.

set -uo pipefail

source "$HOME/.claude/hooks/lib/paths.sh"

LOG_FILE="$HOOKS_STATE/auto-commit.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "$(date -Iseconds) $*" >> "$LOG_FILE"; }

log "auto-commit-surfaces start session=${CLAUDE_SESSION_ID:-unknown} pid=$$"

if [ -f "$HOOKS_STATE/canary-editing.lock" ]; then
  log "canary-editing.lock present — skipping auto-commit"
  exit 0
fi

for repo in "$CLAUDE_GIT_REPO" "$PLANS_GIT_REPO"; do
  [ -d "$repo/.git" ] || { log "skip: $repo is not a git repo"; continue; }
  cd "$repo" || { log "skip: cd $repo failed"; continue; }

  if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
    log "clean: $repo"
  else
    git add -A 2>>"$LOG_FILE" || { log "git add failed in $repo"; continue; }
    msg1="auto: session-end@$(date -Iseconds)"
    msg2="session-id: ${CLAUDE_SESSION_ID:-unknown}"
    if git commit -m "$msg1" -m "$msg2" >>"$LOG_FILE" 2>&1; then
      log "committed: $repo"
    else
      log "commit failed or nothing to commit: $repo"
    fi
  fi

  for remote in $(git remote); do
    if git push "$remote" --all --porcelain >>"$LOG_FILE" 2>&1; then
      log "pushed $repo -> $remote"
    else
      log "push FAILED $repo -> $remote (fail-soft, continuing)"
    fi
  done
done

log "auto-commit-surfaces end"
exit 0
