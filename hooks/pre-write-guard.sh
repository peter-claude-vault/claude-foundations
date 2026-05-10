#!/bin/bash
# Hook: PreToolUse (Edit|Write) — Guards and reminders for specific file patterns.
#
# Manifest edits:     BLOCKED (must use /librarian to regenerate)
# Plan file writes:   Reminder to update System Backlog.md
# Skill file edits:   4-step change protocol checklist
# Tasks.md edits:     Table format validation reminder
#
# ENFORCEMENT-MAP rules implemented here (see ~/.claude-plans/ENFORCEMENT-MAP.md):
#   R-01  dead plans path DENY                        — line 26+
#   R-03  VA.md size guard                            — line 39+ (VA_MAX_LINES=400)
#   R-04  vault-root allowlist                        — line ~532
#   R-07  doc-dependency cascade                      — line ~495
#   R-09  Logs/ deny-list (soft-warn)                 — line ~549
#   R-23  cron wrapper bash 3.2 compatibility         — line 39+
#   R-24  claude-mem SessionEnd protection            — line 78+
#   R-27  plan naming + status enforcement            — line 123+
#   R-32  type: allowlist (Tier 2 DENY)               — line 675+
#   R-33  folder placement advisory (Tier 1)          — line 705+
# Rules implemented elsewhere:
#   R-29/R-30/R-31  backlog row size + sentinel pattern  — ~/.claude/skills/backlog-hygiene/SKILL.md
#   R-34  self-healing boundary                          — documentary (53-spine-remediation-followup/_research/r34-self-healing-boundary.md)
#   R-35  stage-gated promotion framework               — documentary (53-spine-remediation-followup/_research/r35-stage-gated-promotion.md)
#   R-36  Stop-hook touched-file drift scan            — ~/.claude/hooks/stop-drift-scan.sh
#   R-37  schema-addition lockstep commit rule         — documentary (enforced by git atomicity)
#   R-38  blockquote summary advisory                  — ~/.claude/hooks/post-write-verify.sh (combined R-38+R-39 block)
#   R-39  provides: presence advisory                  — ~/.claude/hooks/post-write-verify.sh (same block)
set -euo pipefail

source "$HOME/.claude/hooks/lib/paths.sh"

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# No file path → nothing to guard
[[ -z "$FILE_PATH" ]] && exit 0

# === G1: live-mutation gate — Phase A parallel-run (Plan 81 SP01 T-20) =====
# Two helpers run side-by-side:
#   1. NEW plan-agnostic live-guard.sh (manifest-driven) — shadow mode,
#      error_action: ignore. Crash → continue with old helper, do not deny.
#   2. OLD plan-71-live-guard.sh (hardcoded R-55) — authoritative.
# Both decisions logged JSONL to $HOOKS_STATE/parallel-run.log per call so
# librarian r55-parallel-run-audit (T-9) can disposition divergences before
# Phase B retires the old helper.
#
# Helper paths overridable via $G1_NEW_HELPER / $G1_HELPER for fixture testing.
G1_NEW_HELPER="${G1_NEW_HELPER:-$HOME/.claude/hooks/lib/live-guard.sh}"
G1_HELPER="${G1_HELPER:-$HOME/.claude/hooks/lib/plan-71-live-guard.sh}"
G1_CRASH_DIR="${HOOKS_STATE_OVERRIDE:-$HOOKS_STATE}"
mkdir -p "$G1_CRASH_DIR" 2>/dev/null || true

# Shadow invocation: NEW helper. error_action: ignore — crash is logged but
# never denies; production behavior is preserved by old helper alone.
G1_NEW_OUTPUT=""
G1_NEW_EXIT=0
if [[ -x "$G1_NEW_HELPER" ]]; then
  set +e
  G1_NEW_OUTPUT=$(FILE_PATH="$FILE_PATH" TOOL_NAME="$TOOL_NAME" HOOKS_STATE="$HOOKS_STATE" CLAUDE_HOME="$CLAUDE_HOME" "$G1_NEW_HELPER" 2>>"$G1_CRASH_DIR/live-guard-crashes.log")
  G1_NEW_EXIT=$?
  set -e
  if [[ "$G1_NEW_EXIT" -ne 0 ]]; then
    printf '%s live-guard.sh exit=%s; shadow-only, ignored\n' "$(date -u +%FT%TZ)" "$G1_NEW_EXIT" >> "$G1_CRASH_DIR/live-guard-crashes.log" 2>/dev/null || true
  fi
fi

# Authoritative invocation: OLD helper. Behavior preserved verbatim.
G1_OUTPUT=""
G1_EXIT=0
if [[ -x "$G1_HELPER" ]]; then
  set +e
  G1_OUTPUT=$(FILE_PATH="$FILE_PATH" TOOL_NAME="$TOOL_NAME" HOOKS_STATE="$HOOKS_STATE" CLAUDE_HOME="$CLAUDE_HOME" "$G1_HELPER" 2>>"$G1_CRASH_DIR/plan-71-gate-crashes.log")
  G1_EXIT=$?
  set -e
  if [[ "$G1_EXIT" -ne 0 ]]; then
    printf '%s plan-71-live-guard.sh exit=%s; failed open\n' "$(date -u +%FT%TZ)" "$G1_EXIT" >> "$G1_CRASH_DIR/plan-71-gate-crashes.log" 2>/dev/null || true
  fi
fi

# Parallel-run audit row: one JSONL per call, both verdicts side-by-side.
# Verdict normalization: crash → "crash"; empty stdout → "allow"; non-empty
# stdout → permissionDecision field.
_g1_verdict() {
  local out="$1" code="$2" d
  if [[ "$code" -ne 0 ]]; then printf 'crash'; return; fi
  if [[ -z "$out" ]]; then printf 'allow'; return; fi
  d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)
  printf '%s' "${d:-allow}"
}
G1_NEW_VERDICT=$(_g1_verdict "$G1_NEW_OUTPUT" "$G1_NEW_EXIT")
G1_OLD_VERDICT=$(_g1_verdict "$G1_OUTPUT" "$G1_EXIT")
if command -v jq >/dev/null 2>&1; then
  jq -nc \
    --arg ts "$(date -u +%FT%TZ)" \
    --arg file "$FILE_PATH" \
    --arg tool "$TOOL_NAME" \
    --arg session "${CLAUDE_SESSION_ID:-}" \
    --arg new_verdict "$G1_NEW_VERDICT" \
    --arg old_verdict "$G1_OLD_VERDICT" \
    --argjson new_exit "$G1_NEW_EXIT" \
    --argjson old_exit "$G1_EXIT" \
    '{ts:$ts,file:$file,tool:$tool,session:$session,new_helper:{verdict:$new_verdict,exit:$new_exit},old_helper:{verdict:$old_verdict,exit:$old_exit},divergent:($new_verdict != $old_verdict)}' \
    >> "$G1_CRASH_DIR/parallel-run.log" 2>/dev/null || true
fi

# Authoritative decision: OLD helper. Phase B (T-22) flips this to NEW.
if [[ "$G1_EXIT" -eq 0 && -n "$G1_OUTPUT" ]]; then
  printf '%s\n' "$G1_OUTPUT"
  exit 0
fi
# === end G1 ================================================================

# --- BLOCK: Writes to the dead plans path (migrated 2026-04-13) ---
# Tripwire added by spine-remediation Session 02, redesigned in Session 14
# (2026-04-14). The path ~/.claude/plans/ is now a permanent placeholder
# containing only README.md. Claude Code's harness recreates the folder
# intermittently and that's accepted as cosmetic. ANY Edit|Write to that
# folder is still denied with one exception: README.md itself, which is the
# coexistence marker. Stale-reference bugs still fail loudly here.
if [[ "$FILE_PATH" == "$PLANS_DIR_DEAD/README.md" ]]; then
  : # allow (placeholder marker — coexistence README)
elif [[ "$FILE_PATH" == "$PLANS_DIR_DEAD/"* ]] || [[ "$FILE_PATH" == "$PLANS_DIR_DEAD" ]]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Dead path ~/.claude/plans/ — migrated to ~/.claude-plans/ on 2026-04-13. This folder is a permanent placeholder; only its README.md may be written. Update your reference to use $PLANS_DIR (from ~/.claude/hooks/lib/paths.sh) or the new absolute path ~/.claude-plans/. See spine-remediation Session 14 handoff for context."
    }
  }'
  exit 0
fi

# === Cron wrapper bash 3.2 compatibility check (Session 19 R-23) =========
# macOS /bin/bash is 3.2 — launchd cron wrappers MUST be bash 3.2-compatible.
# Scope: ONLY files under orchestrator/cron-wrappers/*.sh. Other shells are
# free to assume bash 4+.
if [[ "$FILE_PATH" == *"/orchestrator/cron-wrappers/"*".sh" ]]; then
  CW_CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    CW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]]; then
    CW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
  fi
  if [[ -n "$CW_CONTENT" ]]; then
    CW_OFFENDER=""
    if echo "$CW_CONTENT" | grep -qE '^[[:space:]]*declare[[:space:]]+-A\b'; then
      CW_OFFENDER="declare -A (associative arrays, bash 4+)"
    elif echo "$CW_CONTENT" | grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*,,\}|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^\}'; then
      CW_OFFENDER='${var,,} / ${var^^} case expansion (bash 4+)'
    elif echo "$CW_CONTENT" | grep -qE '^[[:space:]]*(readarray|mapfile)\b'; then
      CW_OFFENDER="readarray / mapfile (bash 4+)"
    elif echo "$CW_CONTENT" | grep -qE '\{[0-9]+\.\.[0-9]+\.\.[0-9]+\}'; then
      CW_OFFENDER="brace-expansion step syntax {a..b..n} (bash 4+)"
    elif echo "$CW_CONTENT" | grep -qE '(^|[^&])&>>'; then
      CW_OFFENDER="&>> append redirect (bash 4+)"
    fi
    if [[ -n "$CW_OFFENDER" ]]; then
      CW_REASON="Cron wrapper bash 3.2 compatibility (R-23, spine-remediation Session 19): offending construct — ${CW_OFFENDER}. macOS /bin/bash is 3.2; launchd cron wrappers MUST be bash 3.2-compatible or they will silently fail in cron context. Substitute a 3.2 alternative: parallel indexed arrays instead of declare -A; tr/awk for case conversion; while-read loops instead of readarray; explicit lists instead of step brace expansion; '>>file 2>&1' instead of '&>>file'."
      jq -n --arg r "$CW_REASON" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: $r
        }
      }'
      exit 0
    fi
  fi
fi
# === end cron wrapper bash3 check ========================================

# === claude-mem SessionEnd protection (Session 19 R-24) ==================
# Peter's explicit instruction: claude-mem is required infrastructure.
# Block any settings.json Write/Edit that removes the memory-consolidation-
# check.sh / claude-mem SessionEnd hook. Escape hatch: CLAUDE_MEM_DISABLE_OK=1
if [[ "$FILE_PATH" == "$HOME/.claude/settings.json" ]]; then
  CM_CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    CM_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
    CM_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
    CM_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
    CM_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
    CM_CONTENT=$(python3 - "$FILE_PATH" "$CM_OLD" "$CM_NEW" "$CM_RALL" <<'PYEOF' 2>/dev/null || cat "$FILE_PATH"
import sys
with open(sys.argv[1]) as f:
    c = f.read()
old, new = sys.argv[2], sys.argv[3]
if sys.argv[4] == "true":
    c = c.replace(old, new)
else:
    c = c.replace(old, new, 1)
sys.stdout.write(c)
PYEOF
)
  fi
  if [[ -n "$CM_CONTENT" ]]; then
    if ! echo "$CM_CONTENT" | grep -qE 'memory-consolidation-check\.sh|claude-mem'; then
      if [[ "${CLAUDE_MEM_DISABLE_OK:-0}" != "1" ]]; then
        CM_REASON="claude-mem protection (R-24, spine-remediation Session 19): this settings.json write removes the claude-mem / memory-consolidation-check SessionEnd hook. claude-mem is required infrastructure per Peter's explicit instruction (\"do everything else but don't turn Claude Mem off\"). To override intentionally, set CLAUDE_MEM_DISABLE_OK=1 in the environment for this write."
        jq -n --arg r "$CM_REASON" '{
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $r
          }
        }'
        exit 0
      else
        echo "$(date -Iseconds) | pre-write-guard | CLAUDE_MEM_DISABLE_OK override | $FILE_PATH" >> "$HOME/Desktop/artefact-daily-logs/hook-audit.log" 2>/dev/null || true
      fi
    fi
  fi
fi
# === end claude-mem protection ===========================================

# === Plan naming + status enforcement (Session 22 R-27) =================
# Promotes feedback_plan_naming_conventions.md from memory-only to procedural
# enforcement. Scoped NARROWLY to plan-root files — sub-tasks, handoffs, test
# artifacts, and orchestrator exhaust are explicitly NOT enforced (they inherit
# status from the parent plan via the stale-detect scope fix in the same session).
#
# Enforced files:
#   ~/.claude-plans/*.md                        (flat root plans)
#   ~/.claude-plans/*/spec.md
#   ~/.claude-plans/*/00-ideation-brief.md
#   ~/.claude-plans/*/README.md                 (folder-style plans' index doc)
#   ~/.claude-plans/*/manifest.json             (top-level status field)
#
# Whitelisted (vault-wide registries, not plans):
#   ~/.claude-plans/ENFORCEMENT-MAP.md
#   ~/.claude-plans/_index.md
#
# Detection: reconstruct post-write content; require one of
#   (a) **Status:** <value> header bullet
#   (b) YAML frontmatter status: <value>
#   (c) manifest.json top-level "status" field (manifest writes only)
#
# Escape hatch: PLAN_STATUS_OK=1 env var (logged to hook-audit.log)
#
# bash 3.2 clean: no associative arrays, no ${var,,}, no readarray, no &>>
# R-27 plan-root classification — sourced from canonical helper to eliminate
# the demonstrated hook ↔ librarian drift surface. Plan 61 (2026-04-19/20).
# classify_plan_path returns is_plan|is_manifest|top_segment.
source "$HOME/.claude/skills/librarian/lib/plan-path.sh"
PS_INFO=$(classify_plan_path "$FILE_PATH")
PS_IS_PLAN="${PS_INFO%%|*}"
PS_REST="${PS_INFO#*|}"
PS_IS_MANIFEST="${PS_REST%%|*}"
PS_TOP_SEGMENT="${PS_REST#*|}"

# Prefix check (R-27 widened Session 22 Module 22-I): when a plan-root file
# is in scope, verify its top-level segment starts with NN-. Prefix check runs
# BEFORE the status check — both must pass.
if [[ "$PS_IS_PLAN" == "1" ]]; then
  PS_PREFIX_OK=0
  if [[ "$PS_TOP_SEGMENT" =~ ^[0-9]+- ]]; then
    PS_PREFIX_OK=1
  fi
  if [[ "$PS_PREFIX_OK" == "0" ]]; then
    if [[ "${PLAN_STATUS_OK:-0}" == "1" ]]; then
      echo "$(date -Iseconds) | pre-write-guard | PLAN_STATUS_OK override (prefix) | $FILE_PATH" >> "$HOME/Desktop/artefact-daily-logs/hook-audit.log" 2>/dev/null || true
    else
      PS_PREFIX_REASON="Plan naming convention (R-27, feedback_plan_naming_conventions.md): this plan-root path is missing the required NN- numeric prefix. Top segment: '${PS_TOP_SEGMENT}'. New plan files and directories at ~/.claude-plans/ must start with a numeric prefix matching the next-available integer (run 'ls ~/.claude-plans/ | grep -oE \"^[0-9]+\" | sort -n | tail -1' and add 1). Use descriptive slug, not auto-generated. Escape hatch: export PLAN_STATUS_OK=1 (logged to hook-audit.log)."
      jq -n --arg r "$PS_PREFIX_REASON" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: $r
        }
      }'
      exit 0
    fi
  fi
fi

if [[ "$PS_IS_PLAN" == "1" ]]; then
  PS_CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    PS_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
    PS_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
    PS_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
    PS_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
    PS_CONTENT=$(python3 - "$FILE_PATH" "$PS_OLD" "$PS_NEW" "$PS_RALL" <<'PYEOF' 2>/dev/null || cat "$FILE_PATH"
import sys
with open(sys.argv[1]) as f:
    c = f.read()
old, new = sys.argv[2], sys.argv[3]
if sys.argv[4] == "true":
    c = c.replace(old, new)
else:
    c = c.replace(old, new, 1)
sys.stdout.write(c)
PYEOF
)
  fi

  if [[ -n "$PS_CONTENT" ]]; then
    PS_HAS_STATUS=0
    if [[ "$PS_IS_MANIFEST" == "1" ]]; then
      # JSON top-level "status" field, non-empty
      PS_JSON_STATUS=$(echo "$PS_CONTENT" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
  v=d.get("status","") if isinstance(d,dict) else ""
  print(v if v else "")
except Exception:
  print("")' 2>/dev/null)
      if [[ -n "$PS_JSON_STATUS" ]]; then
        PS_HAS_STATUS=1
      fi
    else
      # Markdown: **Status:** header bullet OR YAML status: field
      if echo "$PS_CONTENT" | grep -qE '^\*\*Status:\*\*[[:space:]]*\S+'; then
        PS_HAS_STATUS=1
      elif echo "$PS_CONTENT" | awk '/^---[[:space:]]*$/{n++; next} n==1{print} n>=2{exit}' | grep -qE '^status:[[:space:]]*\S+'; then
        PS_HAS_STATUS=1
      fi
    fi

    if [[ "$PS_HAS_STATUS" == "0" ]]; then
      if [[ "${PLAN_STATUS_OK:-0}" == "1" ]]; then
        echo "$(date -Iseconds) | pre-write-guard | PLAN_STATUS_OK override | $FILE_PATH" >> "$HOME/Desktop/artefact-daily-logs/hook-audit.log" 2>/dev/null || true
      else
        PS_REASON="Plan naming convention (R-27, feedback_plan_naming_conventions.md): this plan file is missing a status marker. Required: one of (a) **Status:** header bullet with value (e.g., **Status:** briefed), (b) YAML frontmatter status: field, or (c) manifest.json top-level status field (for manifest writes). Scope: flat root plans + spec.md + 00-ideation-brief.md + README.md + manifest.json. Sub-task files, handoff.md, and orchestrator artifacts are explicitly NOT required to carry status (they inherit from the parent plan). Escape hatch: export PLAN_STATUS_OK=1 (logged to hook-audit.log)."
        jq -n --arg r "$PS_REASON" '{
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $r
          }
        }'
        exit 0
      fi
    fi
  fi
fi
# === end plan status enforcement =========================================

# === VA.md size guard (spine-remediation Session 07) ====================
# Block any Write/Edit on Vault Architecture.md whose result exceeds the
# navigational-index threshold. Force extraction-first discipline.
VA_PATH="$HOME/Documents/Obsidian Vault/Vault Architecture.md"
VA_MAX_LINES=400

if [[ "$FILE_PATH" == "$VA_PATH" ]]; then
  va_new_lines=0
  case "$TOOL_NAME" in
    Write)
      VA_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
      va_new_lines=$(printf '%s' "$VA_CONTENT" | wc -l | tr -d ' ')
      # wc -l counts newlines; add 1 if content doesn't end in newline
      if [[ -n "$VA_CONTENT" ]] && [[ "${VA_CONTENT: -1}" != $'\n' ]]; then
        va_new_lines=$((va_new_lines + 1))
      fi
      ;;
    Edit)
      if [[ -f "$VA_PATH" ]]; then
        VA_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
        VA_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
        VA_REPLACE_ALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
        va_tmp=$(mktemp)
        # Python literal substitution (no regex pitfalls)
        VA_OLD_B64=$(printf '%s' "$VA_OLD" | base64)
        VA_NEW_B64=$(printf '%s' "$VA_NEW" | base64)
        python3 -c "
import sys, base64
path = sys.argv[1]
old = base64.b64decode(sys.argv[2]).decode('utf-8')
new = base64.b64decode(sys.argv[3]).decode('utf-8')
replace_all = sys.argv[4] == 'true'
with open(path, 'r') as f:
    content = f.read()
if replace_all:
    content = content.replace(old, new)
else:
    content = content.replace(old, new, 1)
with open(sys.argv[5], 'w') as f:
    f.write(content)
" "$VA_PATH" "$VA_OLD_B64" "$VA_NEW_B64" "$VA_REPLACE_ALL" "$va_tmp" 2>/dev/null || true
        if [[ -s "$va_tmp" ]]; then
          va_new_lines=$(wc -l < "$va_tmp" | tr -d ' ')
        fi
        rm -f "$va_tmp"
      fi
      ;;
  esac

  if [[ "$va_new_lines" -gt "$VA_MAX_LINES" ]]; then
    REASON="Vault Architecture.md would become ${va_new_lines} lines, exceeding the navigational-index threshold (${VA_MAX_LINES}). VA.md is the hub; long content belongs in a spoke file at Vault Architecture/Vault Architecture - {Topic}.md. To proceed: (1) identify a self-contained section to extract, (2) create or extend a spoke, (3) replace the section in VA.md with a stub redirect, (4) retry the write."
    jq -n --arg reason "$REASON" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
fi
# === end VA.md size guard ===============================================

# --- BLOCK: Direct edits to librarian-manifest.json ---
if [[ "$FILE_PATH" == *"librarian-manifest.json"* ]]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Direct edits to librarian-manifest.json are prohibited. The manifest must be regenerated through /librarian to maintain holistic consistency (backend_sync.in_sync flags go stale on manual edits). Use /librarian with the appropriate capability instead."
    }
  }'
  exit 0
fi

# --- REMINDER: Engagement CLAUDE.md completeness standards ---
# Stored as variable — don't exit here. Let Tier 2 enforce navigation schema fields.
ENGAGEMENT_CLAUDE_REMINDER=""
if [[ "$FILE_PATH" == *"/Engagements/"*"/CLAUDE.md" ]]; then
  ENGAGEMENT_CLAUDE_REMINDER="[ENGAGEMENT CLAUDE.MD STANDARDS] This file must meet completeness standards:\n1. Frontmatter: type: navigation, engagement, updated\n2. Navigation table: every .md file in this engagement tree must be listed OR in Files to Skip\n3. Key People: every People/*.md file must be listed with name, role, wikilink\n4. Line counts: ~N must be within 20% of actual\n5. Status must match Overview frontmatter\nAfter writing, scan the engagement directory to verify. Missing files or people is a blocking error."
fi

# === Plan-artifact frontmatter advisory (R-40) + System Backlog reminder ===
# R-40 (56-spine-remediation-finalization Sub-plan 04, landed 2026-04-17)
# Tier 1 advisory per R-35 stage-gated promotion framework.
# Preserves existing backlog-reminder emission; adds R-40 frontmatter check
# for canonical plan-artifact filenames.
#
# Canonical filename-to-type map (mirrors plans-schema.json _filename_map):
#   spec.md              → type: spec
#   tasks.md             → type: tasks
#   handoff.md           → type: handoff
#   00-ideation-brief.md → type: ideation-brief
#   manifest.json        → type: manifest (JSON, not frontmatter — skipped here)
#
# Scope: only emit R-40 advisory for the 4 canonical Markdown filenames.
# Other .md under ~/.claude-plans/ (research notes, session logs, etc.) get
# the backlog reminder but no R-40 check.
#
# Never blocks. Always exit 0 with permissionDecision: allow.
if [[ "$FILE_PATH" == *"/.claude-plans/"*".md" ]]; then
  R40_ADVISORY=""
  PL_BASE=$(basename "$FILE_PATH")
  PL_EXPECTED_TYPE=""
  case "$PL_BASE" in
    spec.md) PL_EXPECTED_TYPE="spec" ;;
    tasks.md) PL_EXPECTED_TYPE="tasks" ;;
    handoff.md) PL_EXPECTED_TYPE="handoff" ;;
    00-ideation-brief.md) PL_EXPECTED_TYPE="ideation-brief" ;;
  esac

  if [[ -n "$PL_EXPECTED_TYPE" ]]; then
    PL_CONTENT=""
    if [[ "$TOOL_NAME" == "Write" ]]; then
      PL_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
    elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
      PL_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
      PL_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
      PL_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
      PL_CONTENT=$(python3 - "$FILE_PATH" "$PL_OLD" "$PL_NEW" "$PL_RALL" <<'PYEOF' 2>/dev/null || cat "$FILE_PATH"
import sys
with open(sys.argv[1]) as f:
    c = f.read()
old, new = sys.argv[2], sys.argv[3]
if sys.argv[4] == "true":
    c = c.replace(old, new)
else:
    c = c.replace(old, new, 1)
sys.stdout.write(c)
PYEOF
)
    fi

    if [[ -n "$PL_CONTENT" ]]; then
      # Extract type: from YAML frontmatter (first --- block). Tolerate empty
      # matches (pipefail would otherwise kill the script when the file has
      # no frontmatter or no type: line).
      PL_ACTUAL_TYPE=$(printf '%s\n' "$PL_CONTENT" | awk '/^---[[:space:]]*$/{n++; next} n==1{print} n>=2{exit}' 2>/dev/null | grep -E '^type:[[:space:]]*' 2>/dev/null | head -1 | sed -E 's/^type:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//' 2>/dev/null || true)

      if [[ -z "$PL_ACTUAL_TYPE" ]]; then
        R40_ADVISORY="[R-40 PLAN FRONTMATTER] ${PL_BASE} is missing a canonical type: field in YAML frontmatter. Expected: type: ${PL_EXPECTED_TYPE} (per ~/.claude/schemas/plans-schema.json). Advisory only — this write is allowed. Canonical frontmatter stub: ---/title: ...(name)/type: ${PL_EXPECTED_TYPE}/status: planned|active|complete|draft/created: YYYY-MM-DD/updated: YYYY-MM-DD/---"
      elif [[ "$PL_ACTUAL_TYPE" != "$PL_EXPECTED_TYPE" ]]; then
        R40_ADVISORY="[R-40 PLAN FRONTMATTER] ${PL_BASE} has non-canonical type: '${PL_ACTUAL_TYPE}' in YAML frontmatter. Expected: type: ${PL_EXPECTED_TYPE} (per ~/.claude/schemas/plans-schema.json filename-to-type map). Advisory only — this write is allowed. 5 canonical plan-artifact types: spec, tasks, handoff, ideation-brief, manifest."
      fi
    fi
  fi

  # R-15 promotion (Plan 64 Sub-plan 05 T-1, 2026-04-21): advisory text tightened
  # to name the specific vault file, cite the row format, and warn that librarian
  # session-close will emit a `backlog-row-missing` finding (via placement-validate)
  # if no row exists when the session ends. Still Tier 1 advisory — never blocks.
  #
  # Sub-plan exemption (post-validation fix 2026-04-21): if the file carries a
  # `parent_plan:` frontmatter field, it is a sub-plan artifact whose backlog row
  # is owned by the parent plan. Suppress R-15 in that case — the parent row
  # already covers it, per R-28 inheritance semantics.
  PL_IS_SUBPLAN=0
  if [[ -n "$PL_CONTENT" ]] && printf '%s\n' "$PL_CONTENT" | awk '/^---[[:space:]]*$/{n++; next} n==1{print} n>=2{exit}' 2>/dev/null | grep -qE '^parent_plan:[[:space:]]*[^[:space:]]'; then
    PL_IS_SUBPLAN=1
  fi

  PL_CONTEXT=""
  if [[ $PL_IS_SUBPLAN -eq 0 ]]; then
    PL_CONTEXT="[R-15 PLAN→BACKLOG] After writing this plan file, you MUST add or update the corresponding row in ~/Documents/Obsidian Vault/System Backlog.md. Row format: |Project Name| status | category | subcategory | — | \`plan: <NN-slug>\` | dependencies | updated | notes |. Plans without backlog rows are invisible to architect and librarian and will surface as a \`backlog-row-missing\` finding at librarian session-close (via placement-validate). Do not move on until the backlog is updated."
  fi
  if [[ -n "$R40_ADVISORY" ]]; then
    if [[ -n "$PL_CONTEXT" ]]; then
      PL_CONTEXT="${PL_CONTEXT}"$'\n\n'"${R40_ADVISORY}"
    else
      PL_CONTEXT="${R40_ADVISORY}"
    fi
  fi

  if [[ -z "$PL_CONTEXT" ]]; then
    # No advisories — pass through allow with no additionalContext
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow"
      }
    }'
  else
    jq -n --arg ctx "$PL_CONTEXT" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        additionalContext: $ctx
      }
    }'
  fi
  exit 0
fi
# === end R-40 plan-artifact frontmatter advisory ==========================

# --- REMINDER: Skill change protocol ---
# Runtime skills only (~/.claude/skills/<skill>/SKILL.md). Vault paths
# (Skills/*.md design docs and .claude/skills/*.md spec mirrors) are not
# runtime — the skill-change checklist is not relevant to them.
if [[ "$FILE_PATH" == "$HOME/.claude/skills/"*"/SKILL.md" ]]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: "[SKILL CHANGE PROTOCOL] After this edit, complete the mandatory post-change checklist: (1) Save/update memory for the change (2) Update all affected documentation — specs, CLAUDE.md, MEMORY.md (3) Grep for downstream effects — other skills, hooks, settings that reference this (4) Verify ID emission if applicable. This is a blocking step — do not move to the next task until all four are done."
    }
  }'
  exit 0
fi

# --- REMINDER: Tasks.md format validation ---
if [[ "$FILE_PATH" == *"/Tasks.md" ]]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: "[FORMAT CHECK] After writing to Tasks.md, verify table formatting: one header row + separator per section, consistent cell padding, no blank lines between data rows, no split tables."
    }
  }'
  exit 0
fi

# --- WARNING: Memory file overlap detection + schema validation ---
MEMORY_DIR="$HOME/.claude/projects/-Users-petertiktinsky/memory"
if [[ "$FILE_PATH" == *"/.claude/projects/"*"/memory/"*".md" ]] && \
   [[ "$(basename "$FILE_PATH")" != "MEMORY.md" ]]; then

  OVERLAP_MSG=""
  SCHEMA_MSG=""

  # -- Overlap check (all operations) --
  MEMORY_INDEX="$MEMORY_DIR/MEMORY.md"
  NEW_BASE="$(basename "$FILE_PATH" .md)"
  if [[ -f "$MEMORY_INDEX" ]]; then
    KEYWORDS=$(echo "$NEW_BASE" | tr '_' '\n' | grep -v -E '^(user|feedback|project|reference)$' | tr '\n' '|')
    KEYWORDS="${KEYWORDS%|}"
    if [[ -n "$KEYWORDS" ]]; then
      MATCHES=$(grep -iE "$KEYWORDS" "$MEMORY_INDEX" | grep '^\- \[' || true)
      if [[ -n "$MATCHES" ]]; then
        OVERLAP_MSG="[MEMORY OVERLAP CHECK] Writing to memory file: ${NEW_BASE}.md\n\nPotential overlaps with existing memories:\n${MATCHES}\n\nBefore creating a new file, verify this isn't a duplicate. Consider UPDATE (merge into existing) instead of ADD (new file). See librarian memory-hygiene consolidation logic: ADD/UPDATE/DELETE/NOOP."
      fi
    fi
  fi

  # -- Schema validation (Write + Edit operations) --
  # R-45 extends memory-schema coverage from Write-only to Edit ops by
  # reconstructing the post-Edit frontmatter via the python literal-replace
  # pattern (mirrors R-27/R-40 Edit handling). Advisory-first — failed
  # schema still ALLOWs the write, but emits an appended line to the audit
  # trail at $HOOKS_STATE/memory-schema-advisory-history.jsonl so promotion
  # from advisory→blocking has a FPR baseline.
  CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
    MS_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
    MS_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
    MS_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
    CONTENT=$(python3 - "$FILE_PATH" "$MS_OLD" "$MS_NEW" "$MS_RALL" <<'PYEOF' 2>/dev/null || cat "$FILE_PATH"
import sys
with open(sys.argv[1]) as f:
    c = f.read()
old, new = sys.argv[2], sys.argv[3]
if sys.argv[4] == "true":
    c = c.replace(old, new)
else:
    c = c.replace(old, new, 1)
sys.stdout.write(c)
PYEOF
)
  fi

  if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
    if [[ -n "$CONTENT" ]]; then
      # Extract frontmatter (between first pair of --- delimiters)
      FRONTMATTER=$(echo "$CONTENT" | awk '/^---$/{n++; next} n==1{print} n>=2{exit}')
      MISSING=""

      # Check required fields (|| true to prevent pipefail exit on missing fields)
      FM_NAME=$(echo "$FRONTMATTER" | grep -E '^name:' | head -1 | sed 's/^name:[[:space:]]*//' || true)
      FM_DESC=$(echo "$FRONTMATTER" | grep -E '^description:' | head -1 | sed 's/^description:[[:space:]]*//' || true)
      FM_TYPE=$(echo "$FRONTMATTER" | grep -E '^type:' | head -1 | sed 's/^type:[[:space:]]*//' || true)
      FM_VERIFIED=$(echo "$FRONTMATTER" | grep -E '^last_verified:' | head -1 | sed 's/^last_verified:[[:space:]]*//' || true)

      [[ -z "$FM_NAME" ]] && MISSING="${MISSING}\n- name: missing (required)"
      [[ -z "$FM_DESC" ]] && MISSING="${MISSING}\n- description: missing (required)"

      if [[ -z "$FM_TYPE" ]]; then
        MISSING="${MISSING}\n- type: missing (required — use user|feedback|project|reference)"
      elif ! echo "$FM_TYPE" | grep -qE '^(user|feedback|project|reference)$'; then
        MISSING="${MISSING}\n- type: invalid value '${FM_TYPE}' (must be user|feedback|project|reference)"
      fi

      TODAY=$(date +%Y-%m-%d)
      if [[ -z "$FM_VERIFIED" ]]; then
        MISSING="${MISSING}\n- last_verified: missing (required — set to today's date: ${TODAY})"
      elif ! echo "$FM_VERIFIED" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        MISSING="${MISSING}\n- last_verified: invalid format '${FM_VERIFIED}' (must be YYYY-MM-DD)"
      fi

      # Project-specific: status required
      if [[ "$FM_TYPE" == "project" ]]; then
        FM_STATUS=$(echo "$FRONTMATTER" | grep -E '^status:' | head -1 | sed 's/^status:[[:space:]]*//' || true)
        if [[ -z "$FM_STATUS" ]]; then
          MISSING="${MISSING}\n- status: missing (required for project memories — use active|completed|superseded)"
        elif ! echo "$FM_STATUS" | grep -qE '^(active|completed|superseded)$'; then
          MISSING="${MISSING}\n- status: invalid value '${FM_STATUS}' (must be active|completed|superseded)"
        fi

        # Superseded requires superseded_by
        if [[ "$FM_STATUS" == "superseded" ]]; then
          FM_SUPER=$(echo "$FRONTMATTER" | grep -E '^superseded_by:' | head -1 | sed 's/^superseded_by:[[:space:]]*//' || true)
          if [[ -z "$FM_SUPER" ]]; then
            MISSING="${MISSING}\n- superseded_by: missing (required when status is superseded)"
          elif [[ ! -f "$MEMORY_DIR/$FM_SUPER" ]]; then
            MISSING="${MISSING}\n- superseded_by: file '${FM_SUPER}' does not exist in memory directory"
          fi
        fi
      fi

      if [[ -n "$MISSING" ]]; then
        SCHEMA_MSG="[MEMORY SCHEMA CHECK] File: $(basename "$FILE_PATH")\nMissing or invalid fields:${MISSING}\n\nMemory file schema: name, description, type, last_verified, [status for project], [superseded_by for superseded]"

        # R-45 audit trail — append a JSONL line per advisory hit so the
        # promotion gate has a baseline for FPR computation. Never block.
        MS_AUDIT_FILE="$HOOKS_STATE/memory-schema-advisory-history.jsonl"
        mkdir -p "$HOOKS_STATE" 2>/dev/null || true
        MS_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        MS_AUDIT_LINE=$(python3 - "$MS_TS" "$TOOL_NAME" "$FILE_PATH" "$MISSING" <<'PYEOF' 2>/dev/null || true
import json, sys
ts, tool, path, missing = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# Strip leading "\n- " separators so the log entry is easier to query.
fields = [m.lstrip("- ").strip() for m in missing.split("\\n") if m.strip()]
sys.stdout.write(json.dumps({
    "ts": ts,
    "tool": tool,
    "file": path,
    "missing_fields": fields,
}))
PYEOF
)
        if [[ -n "$MS_AUDIT_LINE" ]]; then
          printf '%s\n' "$MS_AUDIT_LINE" >> "$MS_AUDIT_FILE" 2>/dev/null || true
        fi
      fi
    fi
  fi

  # -- Emit combined warning if either check produced output --
  if [[ -n "$OVERLAP_MSG" ]] || [[ -n "$SCHEMA_MSG" ]]; then
    COMBINED=""
    [[ -n "$OVERLAP_MSG" ]] && COMBINED="$OVERLAP_MSG"
    if [[ -n "$SCHEMA_MSG" ]]; then
      [[ -n "$COMBINED" ]] && COMBINED="${COMBINED}\n\n"
      COMBINED="${COMBINED}${SCHEMA_MSG}"
    fi
    jq -n --arg ctx "$COMBINED" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        additionalContext: $ctx
      }
    }'
    exit 0
  fi
fi

# =============================================================================
# DOC-DEPENDENCY REGISTRY CHECK (spine-remediation Session 10)
# Reads ~/.claude/hooks/doc-dependencies.json and builds DOC_DEP_CTX string:
#   - primary / mirror touches → cascade-review reminder
#   - Logs/ directory-write-constraint violation → deliverable-type soft-warn
# Never denies — librarian session-close Step 2c is the blocking backstop.
# DOC_DEP_CTX is merged into the Tier 1/3 emit below, OR emitted standalone
# at the tail of the hook if no other block fires.
# =============================================================================
DOC_DEP_FILE="$HOME/.claude/hooks/doc-dependencies.json"
DOC_DEP_CTX=""

if [[ -f "$DOC_DEP_FILE" ]]; then
  # Build candidate match keys: vault-relative path + ~-abbreviated absolute path.
  DD_REL="${FILE_PATH#$VAULT_ROOT/}"
  [[ "$DD_REL" == "$FILE_PATH" ]] && DD_REL=""  # non-vault → empty
  if [[ "$FILE_PATH" == "$HOME"/* ]]; then
    DD_HOMEKEY="~/${FILE_PATH#$HOME/}"           # ~/.claude/hooks/... form
  else
    DD_HOMEKEY="$FILE_PATH"
  fi

  # --- Primary / mirror / primary_dir match across BOTH key forms ---
  DEP_MATCH=$(jq -r --arg rel "$DD_REL" --arg abs "$DD_HOMEKEY" '
    .entries[]
    | . as $e
    | select(
        (($rel != "") and (
          (($e.primary // "") == $rel) or
          ((($e.mirrors // []) | map(.file) | index($rel)) != null) or
          ((($e.primary_dir // "") != "") and ($rel | startswith($e.primary_dir)))
        )) or
        (($e.primary // "") == $abs) or
        ((($e.mirrors // []) | map(.file) | index($abs)) != null)
      )
    | "  - \($e.id) [\($e.kind)]: " + (
        if (($e.mirrors // []) | length) > 0 then
          "review mirrors → " + (($e.mirrors // []) | map(.file + " §" + (.section // "(whole)")) | join(", "))
        else
          "canonical source — no mirrors to review"
        end
      )
  ' "$DOC_DEP_FILE" 2>/dev/null || true)
  if [[ -n "$DEP_MATCH" ]]; then
    DOC_DEP_CTX="[DOC-DEPENDENCY CASCADE] This write touches a registered documentation dependency:\n${DEP_MATCH}\n\nReview the mirrors in this same session, OR file a waiver via the canonical writer:\n  source ~/.claude/hooks/lib/cascade-waiver.sh && cascade_waiver_write <entry_id> \"<reason>\"\n(Do NOT write cascade-waivers.json directly — drifted shapes have accumulated across 24 sessions. Plan 65 T-1 audit 2026-04-20.)\nLibrarian session-close Step 2c will block otherwise."
  fi

  # --- Logs/ deliverable directory-write-constraint (Write ops only) ---
  if [[ -n "$DD_REL" ]] && [[ "$DD_REL" == Logs/*.md ]] && [[ "$TOOL_NAME" == "Write" ]]; then
    DD_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
    if [[ -n "$DD_CONTENT" ]]; then
      DD_NEW_TYPE=$(echo "$DD_CONTENT" | awk '/^---$/{c++;next} c==1 && /^type:[[:space:]]/{sub(/^type:[[:space:]]*/,""); gsub(/"/,""); print; exit}')
      if [[ -n "$DD_NEW_TYPE" ]]; then
        DD_DENIED=$(jq -r '.entries[] | select(.id == "logs-scratch-only") | .denied_types[]' "$DOC_DEP_FILE" 2>/dev/null || true)
        if echo "$DD_DENIED" | grep -qx "$DD_NEW_TYPE"; then
          DD_LOGS_WARN="[LOGS/ DELIVERABLE SOFT-REJECT] type: '${DD_NEW_TYPE}' is a deliverable type, not scratch. Logs/ is the Claude scratchpad — promote this file to a permanent vault home (Engagements/, Reference/, Vault Architecture/, etc.) before writing. Soft-warn only in MVP; Session 13 may harden to deny."
          [[ -n "$DOC_DEP_CTX" ]] && DOC_DEP_CTX="${DOC_DEP_CTX}\n\n"
          DOC_DEP_CTX="${DOC_DEP_CTX}${DD_LOGS_WARN}"
        fi
      fi
    fi
  fi
fi

# =============================================================================
# 3-TIER VAULT SCHEMA ENFORCEMENT
# Only triggers for files under ~/Documents/Obsidian Vault/
# Tier 1: Auto-fix guidance (additionalContext)
# Tier 2: Block with explanation (DENY)
# Tier 3: Allow with mandatory follow-up warning
# =============================================================================
# VAULT_ROOT comes from paths.sh (sourced at top)
SCHEMA_FILE="$SCHEMAS_DIR/vault-schema.json"

# === gate-config.json — R-32/R-47 source of truth (Plan 81 SP01 T-6) =========
# Foundation-repo authoring at ~/Code/claude-stem/schemas/gate-config.json.
# $GATE_CONFIG_PATH override mirrors T-7 / T-27 test-isolation contract.
# Missing config → degrade gracefully: empty arrays skip R-32 type/tag DENY
# (fail-OPEN, same posture as missing SCHEMA_FILE).
GATE_CONFIG="${GATE_CONFIG_PATH:-$HOME/Code/claude-stem/schemas/gate-config.json}"
GATE_R32_ACCEPTED_TYPES=""
GATE_R32_TYPE_ALIASES=""
GATE_R32_EXEMPT_PATHS=""
GATE_R47_TAG_DIMENSIONS=""
GATE_R47_EXEMPT_PATHS=""
GATE_R47_PREFIX_LIST=""
GATE_R47_PREFIX_REGEX=""
if [[ -f "$GATE_CONFIG" ]]; then
  GATE_R32_ACCEPTED_TYPES=$(jq -r '.r32.accepted_types[]?' "$GATE_CONFIG" 2>/dev/null)
  GATE_R32_TYPE_ALIASES=$(jq -r '.r32.type_aliases | to_entries[]? | "\(.key)\t\(.value)"' "$GATE_CONFIG" 2>/dev/null)
  GATE_R32_EXEMPT_PATHS=$(jq -r '.r32.exempt_paths[]?' "$GATE_CONFIG" 2>/dev/null)
  GATE_R47_TAG_DIMENSIONS=$(jq -r '.r47.tag_dimensions[]?' "$GATE_CONFIG" 2>/dev/null)
  GATE_R47_EXEMPT_PATHS=$(jq -r '.r47.exempt_paths[]?' "$GATE_CONFIG" 2>/dev/null)
  # Display + regex strings derived from r47.tag_dimensions (single-source per
  # gate-config _tag_dimensions_note: same prefix grammar drives R-47 advisory
  # AND R-32 Tier 2 tag-conformance DENY).
  GATE_R47_PREFIX_LIST=$(echo "$GATE_R47_TAG_DIMENSIONS" | awk 'NF{printf "#%s/, ", $0}' | sed 's/, $//')
  GATE_R47_PREFIX_REGEX=$(echo "$GATE_R47_TAG_DIMENSIONS" | awk 'NF{printf "%s|", $0}' | sed 's/|$//')
fi

if [[ "$FILE_PATH" == "$VAULT_ROOT/"* ]] && [[ "$FILE_PATH" == *.md ]]; then

  REL_PATH="${FILE_PATH#$VAULT_ROOT/}"

  # Skip operational files (manifests, coordination, CLAUDE.md, etc.)
  # Engagement CLAUDE.md files are NOT skipped — they need Tier 2 enforcement for navigation schema.
  IS_ENGAGEMENT_CLAUDE=false
  [[ "$REL_PATH" == Engagements/*/CLAUDE.md ]] && IS_ENGAGEMENT_CLAUDE=true

  # R-32 exempt_paths sourced from gate-config.json::r32.exempt_paths (T-6).
  # Engagement-CLAUDE carve-out (T4 navigation enforcement) overrides exemption
  # so Engagements/*/CLAUDE.md always falls through to schema validation.
  R32_EXEMPT=0
  while IFS= read -r _exempt_pattern; do
    [[ -z "$_exempt_pattern" ]] && continue
    if [[ "$REL_PATH" == $_exempt_pattern ]]; then
      R32_EXEMPT=1
      break
    fi
  done <<< "$GATE_R32_EXEMPT_PATHS"
  [[ "$IS_ENGAGEMENT_CLAUDE" == "true" ]] && R32_EXEMPT=0

  if [[ $R32_EXEMPT -eq 0 ]] && [[ -f "$SCHEMA_FILE" ]]; then

    # --- Reconstruct file content for frontmatter analysis ---
    CONTENT=""
    if [[ "$TOOL_NAME" == "Write" ]]; then
      CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
    elif [[ "$TOOL_NAME" == "Edit" ]]; then
      # For Edit ops, read existing file and apply the edit to get resulting content
      if [[ -f "$FILE_PATH" ]]; then
        OLD_STR=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
        NEW_STR=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
        if [[ -n "$OLD_STR" ]]; then
          # Use python for reliable string replacement
          CONTENT=$(python3 -c "
import sys, json
with open(sys.argv[1], 'r') as f:
    content = f.read()
old = json.loads(sys.stdin.read())
content = content.replace(old['old'], old['new'], 1)
print(content, end='')
" "$FILE_PATH" <<< "$(jq -n --arg old "$OLD_STR" --arg new "$NEW_STR" '{old: $old, new: $new}')" 2>/dev/null || true)
        fi
        # If replacement failed or no old_string, fall back to existing file
        if [[ -z "$CONTENT" ]] && [[ -f "$FILE_PATH" ]]; then
          CONTENT=$(cat "$FILE_PATH")
        fi
      fi
    fi

    if [[ -n "$CONTENT" ]]; then
      # Extract frontmatter between --- delimiters
      FRONTMATTER=$(echo "$CONTENT" | awk '/^---$/{c++;next} c==1{print} c>=2{exit}')

      if [[ -n "$FRONTMATTER" ]]; then
        TIER1_MSGS=""
        TIER2_MSGS=""
        TIER3_MSGS=""
        TODAY=$(date +%Y-%m-%d)

        # --- Helper: extract a frontmatter field value ---
        fm_val() {
          echo "$FRONTMATTER" | grep -E "^${1}:" | head -1 | sed "s/^${1}:[[:space:]]*//" || true
        }

        # --- Helper: check if a frontmatter field key exists (handles list-style fields) ---
        fm_has() {
          echo "$FRONTMATTER" | grep -qE "^${1}:" && return 0 || return 1
        }

        # --- Determine file type from frontmatter or path ---
        FM_TYPE=$(fm_val "type")
        SCHEMA_KEY=""

        # Map type → schema key (R-32, gate-config.json::r32, T-6).
        # Aliases override (5 entries: skill-spec, overview, updates, file-index,
        # tier-2 → canonical schema keys per gate-config.json::r32.type_aliases).
        # Other accepted_types map to themselves; unknown types yield empty
        # SCHEMA_KEY and fall through to path inference below.
        if [[ -n "$FM_TYPE" ]]; then
          _alias_target=$(echo "$GATE_R32_TYPE_ALIASES" | awk -F'\t' -v t="$FM_TYPE" '$1 == t {print $2; exit}')
          if [[ -n "$_alias_target" ]]; then
            SCHEMA_KEY="$_alias_target"
          elif echo "$GATE_R32_ACCEPTED_TYPES" | grep -Fxq "$FM_TYPE"; then
            SCHEMA_KEY="$FM_TYPE"
          fi
        fi

        # Infer from path if type didn't match
        if [[ -z "$SCHEMA_KEY" ]]; then
          if [[ "$REL_PATH" == "Daily/"* ]]; then
            SCHEMA_KEY="daily-note"
          elif [[ "$REL_PATH" == "People/"* ]] || [[ "$REL_PATH" == *"/People/"* ]]; then
            SCHEMA_KEY="people"
          elif [[ "$REL_PATH" == "Engagements/"*"/Projects/"* ]]; then
            SCHEMA_KEY="project"
          elif [[ "$REL_PATH" == "Engagements/"* ]]; then
            SCHEMA_KEY="engagement"
          fi
        fi

        # =====================================================================
        # R-32 — TYPE ALLOWLIST (Tier 2 DENY)
        # Promoted from Tier 1 warning to Tier 2 blocking by spine-remediation-
        # followup P4-T01 (2026-04-17). Allowlist sourced from
        # gate-config.json::r32.accepted_types (Plan 81 SP01 T-6, 2026-05-08):
        # 26 accepted values = 21 canonical schema keys + 5 aliases (skill-spec,
        # overview, updates, file-index, tier-2). Adding a type touches the
        # R-37 coupled-surface set (vault-schema.json + pre-write-guard.sh +
        # post-write-verify.sh + CLAUDE.md). Empty config → DENY skipped
        # (fail-OPEN, same posture as missing SCHEMA_FILE).
        # =====================================================================
        if [[ -n "$FM_TYPE" ]] && [[ -n "$GATE_R32_ACCEPTED_TYPES" ]]; then
          if ! echo "$GATE_R32_ACCEPTED_TYPES" | grep -Fxq "$FM_TYPE"; then
            TIER2_MSGS="${TIER2_MSGS}[R-32 UNKNOWN TYPE] type: '${FM_TYPE}' is not in the canonical allowlist (20 schema keys + 5 aliases). To add a new type: (1) update ~/.claude/schemas/vault-schema.json with required fields, (2) add case entry in pre-write-guard.sh, (3) add to post-write-verify.sh type_map, (4) document in vault CLAUDE.md — bundle as R-37 lockstep commit.\n"
          fi
        fi

        # =====================================================================
        # TIER 1 — Auto-fix guidance (additionalContext, always ALLOW)
        # =====================================================================

        # Check for missing 'updated' field — gated on schema's required list
        # for the target type (source of truth). Types whose schema does not
        # declare 'updated' (log, inbox-archive, daily-archive, weekly-summary,
        # daily-note, engagement, project, briefing, archive) are exempted.
        # If SCHEMA_KEY is empty (unknown type + no path match) the advisory
        # is skipped — R-32 DENY + required-field check already catch the
        # upstream cases.
        if ! fm_has "updated"; then
          UPDATED_IN_SCHEMA=""
          if [[ -n "$SCHEMA_KEY" ]]; then
            UPDATED_IN_SCHEMA=$(jq -r --arg key "$SCHEMA_KEY" '.[$key].required // [] | .[] | select(. == "updated")' "$SCHEMA_FILE" 2>/dev/null)
          fi
          if [[ -n "$UPDATED_IN_SCHEMA" ]]; then
            TIER1_MSGS="${TIER1_MSGS}Vault write needs 'updated: ${TODAY}' in frontmatter. Add it before writing.\n"
          fi
        fi

        # --- R-33: Folder placement advisory (Tier 1, never blocks) ---
        # High-confidence (type, expected-path) pairs only. Ambiguous types
        # (reference, context, briefing, strategic, planning, archive,
        # personal-initiative, index, navigation) are intentionally skipped —
        # their placement varies by engagement and scope.
        if [[ -n "$FM_TYPE" ]] && [[ -n "$SCHEMA_KEY" ]]; then
          EXPECTED=""
          case "$FM_TYPE" in
            daily-note)
              [[ "$REL_PATH" != Daily/* ]] && EXPECTED="Daily/" ;;
            people)
              [[ "$REL_PATH" != *People/* ]] && EXPECTED="People/ (or engagement People/ subdir)" ;;
            log)
              [[ "$REL_PATH" != Logs/* ]] && [[ "$REL_PATH" != Archive/Logs/* ]] && EXPECTED="Logs/ or Archive/Logs/" ;;
            weekly-summary)
              [[ "$REL_PATH" != Logs/* ]] && EXPECTED="Logs/weekly-summaries/" ;;
            daily-archive)
              [[ "$REL_PATH" != Archive/Daily/* ]] && EXPECTED="Archive/Daily/" ;;
            inbox-archive)
              [[ "$REL_PATH" != Archive/Inbox/* ]] && [[ "$REL_PATH" != Inbox/* ]] && EXPECTED="Archive/Inbox/ or Inbox/" ;;
            meeting-note)
              [[ "$REL_PATH" != *Meetings/* ]] && EXPECTED="Meetings/ (or engagement Meetings/ subdir)" ;;
            project)
              [[ "$REL_PATH" != Engagements/*/Projects/* ]] && EXPECTED="Engagements/<engagement>/Projects/<project>/" ;;
            engagement|overview|updates)
              [[ "$REL_PATH" != Engagements/* ]] && EXPECTED="Engagements/<engagement>/" ;;
            prd)
              [[ "$REL_PATH" != Engagements/* ]] && EXPECTED="Engagements/<engagement>/Projects/<project>/" ;;
          esac
          if [[ -n "$EXPECTED" ]]; then
            TIER1_MSGS="${TIER1_MSGS}[R-33 FOLDER PLACEMENT] File type '${FM_TYPE}' is typically placed under '${EXPECTED}'. Current path: '${REL_PATH}'. If this is intentional (engagement-specific exception, cross-reference, etc.), ignore this advisory. Otherwise, move before writing.\n"
          fi
        fi

        # Extract tags for Tier 2 validation — handles both YAML forms:
        #   block:  tags:\n  - foo\n  - bar
        #   inline: tags: [foo, bar]
        # Post-validation fix 2026-04-21: inline form was previously treated as
        # empty, causing R-47 false positives on files using `tags: [log/...]`.
        TAGS_BLOCK=$(echo "$FRONTMATTER" | awk '/^tags:[[:space:]]*$/{found=1;next} found && /^  - /{print; next} found{exit}')
        TAGS_INLINE_CONTENT=""
        if echo "$FRONTMATTER" | grep -qE '^tags:[[:space:]]*\['; then
          TAGS_INLINE_CONTENT=$(echo "$FRONTMATTER" | grep -E '^tags:[[:space:]]*\[' | head -1 | sed -E 's/^tags:[[:space:]]*\[[[:space:]]*//; s/[[:space:]]*\].*//')
        fi
        TAGS_RAW="${TAGS_INLINE_CONTENT}${TAGS_BLOCK}"

        # --- R-47: Tag-presence advisory (Tier 1, never blocks) ---
        # Complement to R-32 tag-prefix DENY: soft-warn when non-exempt vault
        # write has missing or empty tags. Graph-view diagnostic per
        # feedback_tags_as_validity_diagnostic — orphan files surface as
        # enforcement alerts. Observation gate 2026-05-19.
        #
        # POSITIVE-LIST SEMANTICS (Plan 67 SP03 T-3, 2026-04-22):
        # Exempt paths are enumerated explicitly below. Future top-level folder
        # additions MUST either (a) add a path pattern here or (b) rely on
        # schema-level `tags` required-field enforcement (R-32) — see CLAUDE.md
        # §Tagging Taxonomy opt-in notes. Unenumerated paths DEFAULT to the
        # advisory, surfacing orphans as drift findings.
        # R-47 exempt_paths sourced from gate-config.json::r47.exempt_paths (T-6).
        # Positive-list semantics (Plan 67 SP03 T-3, 2026-04-22): unenumerated
        # paths default to advisory. Patterns are vault-relative globs.
        R47_EXEMPT=0
        while IFS= read -r _r47_pattern; do
          [[ -z "$_r47_pattern" ]] && continue
          if [[ "$REL_PATH" == $_r47_pattern ]]; then
            R47_EXEMPT=1
            break
          fi
        done <<< "$GATE_R47_EXEMPT_PATHS"
        if [[ $R47_EXEMPT -eq 0 ]] && [[ -n "$FRONTMATTER" ]] && [[ -z "$TAGS_RAW" ]]; then
          R47_KIND="missing"
          if echo "$FRONTMATTER" | grep -q '^tags:'; then
            R47_KIND="empty"
          fi
          TIER1_MSGS="${TIER1_MSGS}[R-47 TAG PRESENCE] File at '${REL_PATH}' has ${R47_KIND} tags. Add tags per the taxonomy in CLAUDE.md §Tagging Taxonomy (${GATE_R47_PREFIX_LIST}). Tags are load-bearing for graph-view health and cross-folder retrieval. Advisory only — not blocking.\n"
        fi

        # --- R-48: Wikilink write-time advisory (Tier 1, never blocks) ---
        # Plan 64 Sub-plan 05 T-2 (2026-04-21). Vault-scoped (already gated by
        # outer REL_PATH checks). Scans CONTENT for [[target]] and [[target|alias]]
        # patterns; emits advisory when target doesn't resolve to a file in the
        # vault. Complements Plan 59 T-6 wikilink-repair.sh (post-hoc capability)
        # with write-time feedback. Observation gate 2026-05-19.
        if [[ -n "$CONTENT" ]]; then
          R48_TMP=$(mktemp -t r48content.XXXXXX)
          printf '%s' "$CONTENT" > "$R48_TMP"
          R48_BROKEN=$(python3 - "$VAULT_ROOT" "$R48_TMP" <<'PYEOF' 2>/dev/null || true
import sys, os, re

vault_root = sys.argv[1]
with open(sys.argv[2]) as f:
    content = f.read()

# Strip fenced code blocks and inline code spans before scanning. Wikilinks
# documented in code (remediation packets, audit reports) are examples, not
# real links — they were the dominant R-48 false-positive class.
content = re.sub(r'```[\s\S]*?```', '', content)
content = re.sub(r'~~~[\s\S]*?~~~', '', content)
content = re.sub(r'``[^`\n]+``', '', content)
content = re.sub(r'`[^`\n]+`', '', content)

# Extract [[target]] or [[target|alias]] — skip embedded images/transclusions ![[...]]
pattern = re.compile(r'(?<!\!)\[\[([^\]|#]+?)(?:\|[^\]]*)?(?:#[^\]]*)?\]\]')
targets = set()
for m in pattern.finditer(content):
    t = m.group(1).strip()
    if t and not t.startswith('http'):
        targets.add(t)

if not targets:
    sys.exit(0)

# Build a lightweight index of vault basenames (case-insensitive) and full rel paths
existing_basenames = set()
existing_paths = set()
for dirpath, dirnames, filenames in os.walk(vault_root):
    dirnames[:] = [d for d in dirnames if not d.startswith('.') and d not in ('_test',)]
    for fn in filenames:
        if fn.endswith('.md'):
            existing_basenames.add(fn[:-3].lower())
            existing_basenames.add(fn.lower())
        rel = os.path.relpath(os.path.join(dirpath, fn), vault_root)
        existing_paths.add(rel.lower())
        if rel.endswith('.md'):
            existing_paths.add(rel[:-3].lower())

broken = []
for t in sorted(targets):
    tn = t.lower()
    # Try direct match: basename, basename.md, rel path, rel path.md
    if tn in existing_basenames:
        continue
    if tn in existing_paths:
        continue
    # Strip any trailing slashes
    tn_stripped = tn.rstrip('/')
    if tn_stripped in existing_basenames or tn_stripped in existing_paths:
        continue
    broken.append(t)

if broken:
    print(",".join(broken[:5]))  # cap at 5 for advisory brevity
PYEOF
)
          rm -f "$R48_TMP" 2>/dev/null || true
          if [[ -n "$R48_BROKEN" ]]; then
            TIER1_MSGS="${TIER1_MSGS}[R-48 BROKEN WIKILINK] File at '${REL_PATH}' contains wikilink(s) to non-existent target(s): ${R48_BROKEN}. Advisory only — not blocking. Run /librarian (wikilink-repair capability) or create the target file if intended.\n"
          fi
        fi

        # =====================================================================
        # TIER 2 — Block with explanation (DENY)
        # =====================================================================

        # Check required fields from schema
        if [[ -n "$SCHEMA_KEY" ]]; then
          REQUIRED_FIELDS=$(jq -r --arg key "$SCHEMA_KEY" '.[$key].required // [] | .[]' "$SCHEMA_FILE" 2>/dev/null)
          if [[ -n "$REQUIRED_FIELDS" ]]; then
            MISSING_FIELDS=""
            while IFS= read -r field; do
              if ! fm_has "$field"; then
                # 'updated' missing is handled by Tier 1, not a hard block
                if [[ "$field" != "updated" ]]; then
                  MISSING_FIELDS="${MISSING_FIELDS}${field}, "
                fi
              fi
            done <<< "$REQUIRED_FIELDS"
            MISSING_FIELDS="${MISSING_FIELDS%, }"
            if [[ -n "$MISSING_FIELDS" ]]; then
              TIER2_MSGS="${TIER2_MSGS}Missing required fields [${MISSING_FIELDS}] for file type '${SCHEMA_KEY}'.\n"
            fi
          fi
        fi

        # Check tags conform to taxonomy prefixes (hard block if clearly wrong).
        # Prefix grammar single-sourced from gate-config.json::r47.tag_dimensions
        # per gate-config _tag_dimensions_note (T-6, 2026-05-08): same array
        # drives R-47 advisory above AND this Tier 2 R-32 tag-conformance DENY.
        # Empty config → DENY skipped (fail-OPEN, matches R-32 type-allowlist).
        if [[ -n "$TAGS_RAW" ]] && [[ -n "$GATE_R47_PREFIX_REGEX" ]]; then
          INVENTED_TAGS=$(echo "$TAGS_RAW" | sed 's/^  - //' | sed 's/^"//' | sed 's/"$//' | grep -E '^#' | grep -v -E "^#(${GATE_R47_PREFIX_REGEX})/" || true)
          if [[ -n "$INVENTED_TAGS" ]]; then
            TIER2_MSGS="${TIER2_MSGS}Tags not matching taxonomy prefixes (${GATE_R47_PREFIX_LIST}): $(echo "$INVENTED_TAGS" | tr '\n' ', ' | sed 's/, $//').\n"
          fi
        fi

        # Check wikilink fields reference existing files (limit to <10 fields for perf)
        WIKILINK_FIELDS="owner engagement attendees projects previous_instance"
        WIKILINK_CHECK_COUNT=0
        BAD_LINKS=""
        for wfield in $WIKILINK_FIELDS; do
          [[ $WIKILINK_CHECK_COUNT -ge 10 ]] && break
          WVAL=$(fm_val "$wfield")
          if [[ -n "$WVAL" ]]; then
            # Extract wikilinks: [[path]] or [[path|alias]]
            LINKS=$(echo "$WVAL" | grep -oE '\[\[[^]]+\]\]' || true)
            if [[ -n "$LINKS" ]]; then
              while IFS= read -r link; do
                [[ $WIKILINK_CHECK_COUNT -ge 10 ]] && break
                # Strip [[ ]] and optional |alias
                LINK_PATH=$(echo "$link" | sed 's/^\[\[//' | sed 's/\]\]$//' | sed 's/|.*//')
                # Check if file exists (try as-is under vault root, and with .md)
                if [[ ! -f "$VAULT_ROOT/$LINK_PATH" ]] && [[ ! -f "$VAULT_ROOT/${LINK_PATH}.md" ]]; then
                  BAD_LINKS="${BAD_LINKS}${wfield}: ${link}, "
                fi
                WIKILINK_CHECK_COUNT=$((WIKILINK_CHECK_COUNT + 1))
              done <<< "$LINKS"
            fi
          fi
        done
        BAD_LINKS="${BAD_LINKS%, }"
        if [[ -n "$BAD_LINKS" ]]; then
          TIER2_MSGS="${TIER2_MSGS}Wikilink fields referencing non-existent files: ${BAD_LINKS}.\n"
        fi

        # --- Emit Tier 2 DENY if any blocking issues ---
        if [[ -n "$TIER2_MSGS" ]]; then
          DENY_REASON="Write blocked — vault schema enforcement:\n${TIER2_MSGS}Add the missing fields/fix the issues and retry."
          # Audit log for Phase 3 monitoring
          echo "$(date -Iseconds) | pre-write-guard | DENY | ${FILE_PATH} | ${TIER2_MSGS}" >> "$HOME/Desktop/artefact-daily-logs/hook-audit.log" 2>/dev/null || true
          jq -n --arg reason "$DENY_REASON" '{
            hookSpecificOutput: {
              hookEventName: "PreToolUse",
              permissionDecision: "deny",
              permissionDecisionReason: $reason
            }
          }'
          exit 0
        fi

        # =====================================================================
        # TIER 3 — Allow with mandatory follow-up warning
        # =====================================================================

        # Check if creating a file in a new vault-root directory
        ROOT_DIR=$(echo "$REL_PATH" | cut -d'/' -f1)
        IS_KNOWN=false
        for d in "About Me" "Archive" "Artefact-BD" "Daily" "Dashboard" "Engagements" "Inbox" "Logs" "Meetings" "Personal Initiatives" "Plans" "Reference" "Skills" "Tags" "Vault Architecture"; do
          if [[ "$ROOT_DIR" == "$d" ]]; then
            IS_KNOWN=true
            break
          fi
        done

        if [[ "$IS_KNOWN" == "false" ]] && [[ "$ROOT_DIR" != "CLAUDE.md" ]] && \
           [[ "$ROOT_DIR" != "Vault Architecture.md" ]] && \
           [[ "$ROOT_DIR" != "Tasks.md" ]] && \
           [[ "$ROOT_DIR" != "System Backlog.md" ]] && \
           [[ "$ROOT_DIR" != "System Backlog - Archive.md" ]]; then
          TIER3_MSGS="${TIER3_MSGS}[NEW DIRECTORY] File is being written to '${ROOT_DIR}/' which is not a documented vault-root directory. After this write, update Vault Architecture.md to document this new directory or move the file to an existing directory.\n"
        fi

        # --- Emit combined Tier 1 + Tier 3 + engagement reminder guidance if any ---
        COMBINED_CTX=""
        [[ -n "$TIER1_MSGS" ]] && COMBINED_CTX="[VAULT SCHEMA - AUTO-FIX NEEDED]\n${TIER1_MSGS}"
        if [[ -n "$TIER3_MSGS" ]]; then
          [[ -n "$COMBINED_CTX" ]] && COMBINED_CTX="${COMBINED_CTX}\n"
          COMBINED_CTX="${COMBINED_CTX}[VAULT SCHEMA - FOLLOW-UP REQUIRED]\n${TIER3_MSGS}"
        fi
        # Append engagement CLAUDE.md reminder if applicable
        if [[ -n "${ENGAGEMENT_CLAUDE_REMINDER:-}" ]]; then
          [[ -n "$COMBINED_CTX" ]] && COMBINED_CTX="${COMBINED_CTX}\n\n"
          COMBINED_CTX="${COMBINED_CTX}${ENGAGEMENT_CLAUDE_REMINDER}"
        fi

        # Append doc-dependency cascade reminder if applicable (Session 10)
        if [[ -n "$DOC_DEP_CTX" ]]; then
          [[ -n "$COMBINED_CTX" ]] && COMBINED_CTX="${COMBINED_CTX}\n\n"
          COMBINED_CTX="${COMBINED_CTX}${DOC_DEP_CTX}"
          DOC_DEP_CTX=""  # consumed
        fi

        if [[ -n "$COMBINED_CTX" ]]; then
          jq -n --arg ctx "$COMBINED_CTX" '{
            hookSpecificOutput: {
              hookEventName: "PreToolUse",
              permissionDecision: "allow",
              additionalContext: $ctx
            }
          }'
          exit 0
        fi
      fi
    fi
  fi
fi

# --- WARNING: Multi-session file overlap detection ---
REGISTRY="$VAULT_ROOT/Logs/.coordination/session-registry.json"

if [[ -f "$REGISTRY" ]] && [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
  REL_PATH="${FILE_PATH#$VAULT_ROOT/}"
  # Only check vault files (if stripping didn't change the path, it's outside the vault)
  if [[ "$REL_PATH" != "$FILE_PATH" ]]; then
    PEER=$(jq -r --arg sid "$CLAUDE_SESSION_ID" --arg fp "$REL_PATH" '
      .sessions // {} | to_entries[]
      | select(.key != $sid)
      | select(.value.touched_files // [] | index($fp))
      | .key
    ' "$REGISTRY" 2>/dev/null | head -1)

    if [[ -n "$PEER" ]]; then
      jq -n --arg rp "$REL_PATH" --arg peer "$PEER" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "allow",
          additionalContext: ("[MULTI-SESSION OVERLAP] File " + $rp + " was already modified by peer session " + $peer + ". Coordinate before making conflicting changes.")
        }
      }'
      exit 0
    fi
  fi
fi

# --- Terminal fall-through: emit unconsumed DOC_DEP_CTX (Session 10) ---
# If no earlier block consumed DOC_DEP_CTX (e.g. non-vault write, or vault
# write that skipped the 3-tier block), surface the reminder here so the
# doc-dependency cascade warning never silently drops.
if [[ -n "${DOC_DEP_CTX:-}" ]]; then
  jq -n --arg ctx "$DOC_DEP_CTX" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: $ctx
    }
  }'
  exit 0
fi

exit 0
