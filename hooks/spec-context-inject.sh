#!/bin/bash
# Hook: UserPromptSubmit — Inject sub-plan spec authority context.
#
# Purpose: When a user prompt references an active sub-plan (via path or
# "Plan N SPM" framing), inject the sub-plan's spec.md head + manifest AC +
# master spec head as additionalContext. Prevents brief-vs-spec drift
# (feedback_spec_authority_over_brief.md). Plan 81 SP01 Session 20 origin.
#
# Fires once per (session × sub-plan); subsequent prompts in the same
# session for the same sub-plan are silent (sentinel-gated).
#
# Detection signals:
#   1. Path pattern in prompt: .claude-plans/NN-slug/NN-slug
#   2. "Plan N SPM" + matching plan + sub-plan dirs exist
#
# False-positive guards:
#   - Skip closed/superseded/cancelled sub-plans
#   - Sentinel-gated per (session, sub-plan)
#   - Fail open: silent on any error; never blocks the prompt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/registry.sh"

STATE_DIR="$HOME/.claude/hooks/state"
PLANS_DIR="$HOME/.claude-plans"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')

[[ -z "$PROMPT" ]] && exit 0
[[ -z "$SESSION_ID" ]] && exit 0
[[ ! -d "$PLANS_DIR" ]] && exit 0

# === Detection ===

SUB_PLAN_REL=""

# Signal 1: explicit path in prompt
SUB_PLAN_REL=$(printf '%s\n' "$PROMPT" | grep -oE '\.claude-plans/[0-9]{2,3}-[a-z0-9-]+/[0-9]{2}-[a-z0-9-]+' | head -1 || true)

# Signal 2: "Plan N SPM" framing + slug existence
if [[ -z "$SUB_PLAN_REL" ]]; then
  PLAN_NUM=$(printf '%s\n' "$PROMPT" | grep -oiE 'Plan +[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  SP_NUM=$(printf '%s\n' "$PROMPT" | grep -oiE 'SP[0-9]+' | head -1 | grep -oE '[0-9]+' || true)

  if [[ -n "$PLAN_NUM" && -n "$SP_NUM" ]]; then
    PLAN_DIR=$(find "$PLANS_DIR" -maxdepth 1 -type d -name "${PLAN_NUM}-*" 2>/dev/null | head -1)
    if [[ -n "$PLAN_DIR" ]]; then
      # SP_NUM may be "01" or "1"; pad to 2 digits
      SP_PADDED=$(printf "%02d" $((10#$SP_NUM)))
      SP_DIR=$(find "$PLAN_DIR" -maxdepth 1 -type d -name "${SP_PADDED}-*" 2>/dev/null | head -1)
      if [[ -n "$SP_DIR" ]]; then
        SUB_PLAN_REL=".claude-plans/$(basename "$PLAN_DIR")/$(basename "$SP_DIR")"
      fi
    fi
  fi
fi

[[ -z "$SUB_PLAN_REL" ]] && exit 0

SP_ABS="$HOME/$SUB_PLAN_REL"
[[ ! -d "$SP_ABS" ]] && exit 0
[[ ! -f "$SP_ABS/spec.md" ]] && exit 0

PLAN_SLUG=$(basename "$(dirname "$SP_ABS")")
SP_SLUG=$(basename "$SP_ABS")

# === False-positive guards ===

# Skip closed/superseded/cancelled
SP_MANIFEST="$SP_ABS/manifest.json"
if [[ -f "$SP_MANIFEST" ]]; then
  STATUS=$(jq -r '.status // ""' "$SP_MANIFEST" 2>/dev/null || echo "")
  case "$STATUS" in
    closed|complete|superseded|cancelled) exit 0 ;;
  esac
fi

# Idempotency sentinel: per (session, sub-plan)
SENTINEL="$STATE_DIR/spec-injected-${SESSION_ID:0:8}-${PLAN_SLUG}-${SP_SLUG}.flag"
[[ -f "$SENTINEL" ]] && exit 0

# === Context build ===

PLAN_ABS="$HOME/.claude-plans/$PLAN_SLUG"

context="## SPEC AUTHORITY — active sub-plan: \`$PLAN_SLUG/$SP_SLUG\`

You are entering work in this sub-plan. Per \`feedback_spec_authority_over_brief\`, the spec ranks above any operational brief. Authoritative excerpts are quoted below. **Framing claims must be grounded in spec text** — cite line numbers in close-out summaries.

### \`$SP_SLUG/spec.md\` — first 80 lines
"
context+='```'$'\n'
context+="$(head -80 "$SP_ABS/spec.md" 2>/dev/null || echo '(unreadable)')"
context+=$'\n''```'$'\n'

if [[ -f "$SP_MANIFEST" ]]; then
  context+="
### \`$SP_SLUG/manifest.json\` — status, deps, AC

"
  context+='```json'$'\n'
  context+="$(jq '{status, schema_version, parent_plan, sub_plan_id, dependencies, tasks: ([.tasks[]? | {id, title, status, depends_on, acceptance_criteria, max_budget_usd}] // [])}' "$SP_MANIFEST" 2>/dev/null | head -120 || echo '{}')"
  context+=$'\n''```'$'\n'
fi

if [[ -f "$SP_ABS/00-ideation-brief.md" ]]; then
  context+="
### \`$SP_SLUG/00-ideation-brief.md\` — first 30 lines
"
  context+='```'$'\n'
  context+="$(head -30 "$SP_ABS/00-ideation-brief.md" 2>/dev/null)"
  context+=$'\n''```'$'\n'
fi

if [[ -f "$PLAN_ABS/spec.md" ]]; then
  context+="
### \`$PLAN_SLUG/spec.md\` (master) — first 50 lines
"
  context+='```'$'\n'
  context+="$(head -50 "$PLAN_ABS/spec.md" 2>/dev/null)"
  context+=$'\n''```'$'\n'
fi

context+="
**Reminder:** brief is operational; spec is authoritative. If they disagree, spec wins and the brief is defective. Read the full \`spec.md\` and \`00-ideation-brief.md\` if your task touches scope/sequencing/dependency questions."

# Cap below SP03 validator maxLength=10240 (B3 community-docs 10K bound) with
# ~750-byte headroom for JSON envelope + escape-expansion. Pre-SP03 this hook
# capped at 12KB which exceeded the validator and produced silent schema_valid:false
# rejections — fixed 2026-05-11 as Plan 84 SP04 soak-gate pre-flight upstream fix.
ctx_bytes=$(printf '%s' "$context" | wc -c | tr -d ' ')
if (( ctx_bytes > 9728 )); then
  context=$(printf '%s' "$context" | head -c 9500)
  context+="

[truncated at 9.5KB to fit hook-output validator cap — read the full files directly for more]"
fi

if format_output "UserPromptSubmit" "$context"; then
  mkdir -p "$STATE_DIR"
  touch "$SENTINEL"
  exit 0
else
  exit 1
fi
