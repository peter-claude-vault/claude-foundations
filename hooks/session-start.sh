#!/bin/bash
# hooks/session-start.sh — SP07 T-10 SessionStart hook: onboarding-resume detect.
#
# Reads $CLAUDE_HOME/user-manifest.json. If onboarding has started but not
# completed (phases_completed[] ⊊ {A,B,C,D,E}), emits a SessionStart
# additionalContext banner prompting the user to resume the next-incomplete
# section or re-record from scratch via /onboard --resume.
#
# Detection is read-only: this hook never mutates the manifest. The /onboard
# skill is what actually drives resume; this hook only surfaces awareness.
#
# Four detection states:
#   1. user-manifest.json absent
#         → fresh install. Silent. /onboard handles fresh starts.
#   2. file exists, .system.phases_completed unreachable / not an array
#         → manifest corruption. Silent (other hooks/tools surface this).
#   3. file exists, phases_completed contains all of {A,B,C,D,E}
#         → onboarding complete. Silent.
#   4. file exists, phases_completed ⊊ {A,B,C,D,E}
#         → INCOMPLETE. Emit resume prompt with:
#             - which section_ids are missing
#             - the resume vs re-record next-step language
#             - the /onboard --resume invocation
#
# AC2 → state #4 detection. AC3 → resume vs re-record language in the
# emitted banner. AC5 → "mid-Section-X quit" maps to state #4: the
# previously-incomplete section_id reappears, /onboard --resume re-invokes
# the section runner from scratch (stateless re-render of the same prompt
# card; no per-card state required because nothing was committed).
#
# Failure-isolation pattern (mirrors cron-health-banner.sh):
#   - set -uo pipefail (NOT -e)
#   - main() runs; any failure is caught + logged to a vault error file
#   - mandatory exit 0 — SessionStart hooks that non-zero exit can break
#     the user's session
#
# Hard invariants:
#   - Bash 3.2 + R-23 compatible
#   - Reference-leak floor: emits only section-id literals (A..E), the
#     /onboard slash command, and the manifest path. No user-typed strings.

set -uo pipefail  # NO -e — handle errors via top-level rc capture

# --- source paths.sh if present (post-install runtime); fall back to env ---
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi

USER_MANIFEST="${USER_MANIFEST:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
ERR_LOG_DIR="${VAULT_LOGS:-${HOOKS_STATE:-${CLAUDE_HOME:-$HOME/.claude}/hooks/state}}"
ERR_LOG="$ERR_LOG_DIR/session-start-error-$(date +%Y%m%d 2>/dev/null || echo unknown).md"

# Self-error handler — writes to vault/state error log; never touches stdout.
log_self_error() {
  local exit_code="${1:-?}"
  local stage="${2:-unknown}"
  mkdir -p "$ERR_LOG_DIR" 2>/dev/null || return 0
  {
    echo "---"
    echo "type: log"
    echo "log-type: session-start-error"
    echo "date: $(date +%Y-%m-%d 2>/dev/null || echo unknown)"
    echo "---"
    echo ""
    echo "$(date -Iseconds 2>/dev/null || echo unknown) session-start.sh FAIL stage=${stage} exit=${exit_code}"
  } >> "$ERR_LOG" 2>/dev/null || true
}

# Compute missing sections from {A,B,C,D,E} - phases_completed[].
# Output: space-separated section ids (e.g. "B C") or empty if complete.
# Returns non-zero only on jq failure or unparseable manifest.
missing_sections() {
  jq -r '
    (["A","B","C","D","E"]) as $all
    | (.system.phases_completed // []) as $done
    | ($all - $done) | join(" ")
  ' "$USER_MANIFEST" 2>/dev/null
}

main() {
  # State #1: manifest absent → fresh install, silent.
  if [ ! -f "$USER_MANIFEST" ]; then
    return 0
  fi

  # Drain stdin if Claude Code is sending JSON event payload (we don't read it
  # but should not block).
  if [ ! -t 0 ]; then
    cat >/dev/null 2>&1 || true
  fi

  # State #2: manifest exists but unreadable / not parseable.
  if ! jq -e . "$USER_MANIFEST" >/dev/null 2>&1; then
    return 0
  fi

  local missing
  missing="$(missing_sections)"

  # State #3: phases_completed covers all 5 sections.
  if [ -z "$missing" ]; then
    return 0
  fi

  # State #4: incomplete onboarding. Emit resume prompt.
  # Render section list as comma-separated (e.g. "Section B, Section C").
  local missing_label
  missing_label="$(printf '%s' "$missing" | tr ' ' '\n' | sed 's/^/Section /' \
    | paste -sd "," - | sed 's/,/, /g')"

  # Identify the next section to resume (first missing in A..E order).
  local next_section
  next_section="$(printf '%s' "$missing" | awk '{print $1}')"

  local banner_text
  printf -v banner_text 'Onboarding incomplete. Outstanding: %s.\n  Resume next: Section %s — run `/onboard --resume` to pick up the same prompt card.\n  Or re-record a section: run `/onboard` and elect re-record at the summary screen.' \
    "$missing_label" "$next_section"

  # Emit hookSpecificOutput JSON via jq (safe escaping).
  jq -n --arg ctx "$banner_text" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
}

main
rc=$?
if [ "$rc" -ne 0 ]; then
  log_self_error "$rc" "main"
fi

exit 0
