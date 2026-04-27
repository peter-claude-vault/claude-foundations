#!/bin/bash
# SessionStart hook: detect and clean up resurrected ~/.claude/plans/ stub.
# Context: plans dir migrated to ~/.claude-plans/ on 2026-04-13. Any code path
# that recreates the dead path is a bug. This canary logs the forensic trail
# and auto-removes the empty stub. See spine-remediation Session 02.
source "$HOME/.claude/hooks/lib/paths.sh"

LOG="$HOOKS_STATE/tripwire.log"
mkdir -p "$HOOKS_STATE"

# Session 14 redesign (2026-04-14): coexist with the harmless reappearance of
# ~/.claude/plans/. The dir is now a permanent placeholder containing only
# README.md. Tripwire fires only if UNEXPECTED contents appear (anything other
# than README.md) — that is the real failure mode (a stale reference actually
# writing data into the legacy path). Pre-write-guard.sh DENY rule still blocks
# all writes via Edit|Write tool path with a single README.md exception.
UNEXPECTED=""
if [[ -d "$PLANS_DIR_DEAD" ]]; then
  UNEXPECTED=$(/bin/ls -A "$PLANS_DIR_DEAD" 2>/dev/null | grep -v '^README\.md$' || true)
fi
if [[ -n "$UNEXPECTED" ]]; then
  TS="$(date -Iseconds)"
  FORENSICS="$HOOKS_STATE/tripwire-forensics.log"
  {
    echo "=========="
    echo "$TS REAPPEARANCE — capturing forensics (canary pid $$)"
    echo "-- ancestor chain (pid → ppid → ...):"
    pid=$$
    depth=0
    while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" && $depth -lt 12 ]]; do
      ps -o pid=,ppid=,etime=,command= -p "$pid" 2>/dev/null
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      depth=$((depth + 1))
    done
    echo "-- dir contents:"
    ls -la@ "$PLANS_DIR_DEAD" 2>&1
    echo "-- dir stat:"
    stat -f "birth=%SB ctime=%Sc mtime=%Sm uid=%Su" "$PLANS_DIR_DEAD" 2>&1
    echo "-- lsof on dir:"
    lsof +D "$PLANS_DIR_DEAD" 2>&1 | head -20
    echo "-- recent claude/node/bun/python/mcp processes:"
    ps -axo pid=,ppid=,etime=,command= 2>/dev/null | grep -E '(claude|node|bun|python|mcp)' | grep -v grep | head -30
    echo "-- launchd jobs (peter / claude / cron / librarian / digest / meeting / plan-exec / backlog / architect):"
    launchctl list 2>&1 | grep -E 'peter|claude|cron|librarian|digest|meeting|plan-exec|backlog|architect' | head -20
    echo ""
  } >> "$FORENSICS"
  echo "$TS TRIPWIRE: $PLANS_DIR_DEAD has unexpected contents — see tripwire-forensics.log" >> "$LOG"
  echo "$TS   unexpected files: $(echo "$UNEXPECTED" | tr '\n' ' ')" >> "$LOG"
  echo "$TS   action: NONE (manual investigation required — placeholder README preserved)" >> "$LOG"
fi

exit 0
