#!/bin/bash
# Hook: PreToolUse (Edit|Write) — Generic R-rule enforcement for the foundation hook set.
#
# Manifest-driven. Reads optional config from user-manifest.json (1.1.0+):
#   .hooks.protected_session_end_hooks[]   — hook names that must remain in settings.json
#   .hooks.audit_log_path                  — override for $HOOKS_STATE/hook-audit.log
#   .schema.size_guards[]                  — per-file size enforcement entries
#   .plans.backlog_enforcement             — row_format + error_template (R-15)
#   .vault.root_directories[]              — Tier 3 vault-root allowlist
# Absent fields fall back to hardcoded defaults below; all enforcement degrades
# gracefully when user-manifest.json is missing or jq is unavailable.
#
# Generic R-rules enforced here:
#   R-01  dead plans path DENY                    (hard block on $PLANS_DIR_DEAD writes)
#   R-02  skill change protocol reminder          (advisory on $CLAUDE_HOME/skills/*/SKILL.md)
#   R-04  size guards + vault-root allowlist      (block over-limit writes; advise unknown roots)
#   R-15  plan→backlog reminder                   (advisory on plan-tree writes)
#   R-23  cron wrapper bash 3.2 compatibility     (DENY bash 4+ syntax in cron wrappers)
#   R-24  protected SessionEnd hooks              (DENY removal; HOOK_GUARD_DISABLE_OK escape)
#   R-27  plan naming + status                    (DENY missing prefix or status)
#   R-28  parent_plan advisory at depth ≥3        (advisory; suppresses R-15 in sub-plan tree)
#   R-32  type: allowlist                         (DENY unknown type from vault-schema.json)
#   R-33  folder placement advisory               (advisory on type/path mismatch)
#   R-40  plan-artifact frontmatter advisory      (advisory on canonical filenames)
#   R-42  multi-session file overlap              (advisory when peer session touched the file)
#   R-45  memory-schema validation                (Write+Edit advisory; appends JSONL audit)
#   R-54  doc-dependency cascade                  (advisory; reads $HOOKS_DIR/config/doc-dependencies.json)
#
# Rules implemented elsewhere (documented in DROPPED-RULES.md):
#   R-26 → prompt-context.sh + stop-checkpoint-check.sh
#   R-38 → post-write-verify.sh
#   R-46 → librarian skill (waiver-audit capability)
set -euo pipefail

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"

# --- helpers ----------------------------------------------------------------

# audit_log <line> — append timestamped line to the audit log. Path resolves
# via manifest.hooks.audit_log_path with $HOOKS_STATE/hook-audit.log fallback.
audit_log() {
  local _path
  _path="$(_manifest_get .hooks.audit_log_path)"
  [ -z "$_path" ] && _path="$HOOKS_STATE/hook-audit.log"
  mkdir -p "$(dirname "$_path")" 2>/dev/null || true
  echo "$(date -Iseconds) | pre-write-guard | $1" >> "$_path" 2>/dev/null || true
}

# literal_replace <path> <old> <new> <replace_all> — reconstruct post-Edit content
# without regex pitfalls. Echoes resulting content to stdout; on failure echoes
# the original file. Used by R-24, R-27, R-40, R-45, vault-schema Edit branches.
literal_replace() {
  python3 - "$1" "$2" "$3" "$4" <<'PYEOF' 2>/dev/null || cat "$1"
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
}

# emit_deny <reason> — print PreToolUse deny JSON and exit.
emit_deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# emit_allow_ctx <ctx> — print PreToolUse allow JSON with additionalContext and exit.
emit_allow_ctx() {
  jq -n --arg c "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:$c}}'
  exit 0
}

# --- input parse ------------------------------------------------------------

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ -z "$FILE_PATH" ] && exit 0

# === FOUNDATION_TEST_MODE write-safety gate (SP00 isolation harness) ========
# When FOUNDATION_TEST_MODE=1, hook becomes a narrow allowlist enforcer for
# dogfood test runs and all R-rule branches are bypassed. Default off.
if [[ "${FOUNDATION_TEST_MODE:-0}" == "1" ]]; then
  FT_PLANS_HOME="${PLANS_HOME:-$PLANS_DIR}"
  FT_DECISION="deny"
  FT_REASON="FOUNDATION_TEST_MODE: path outside allowlist (DOGFOOD_ROOT, CLAUDE_HOME, PLANS_HOME, /tmp/foundation-test-*, /var/folders/**/foundation-test-*)"
  if [[ -n "${DOGFOOD_ROOT:-}" ]] && [[ "$FILE_PATH" == "$DOGFOOD_ROOT"* ]]; then
    FT_DECISION="allow"; FT_REASON="under DOGFOOD_ROOT"
  elif [[ "$FILE_PATH" == "$CLAUDE_HOME"* ]]; then
    FT_DECISION="allow"; FT_REASON="under CLAUDE_HOME"
  elif [[ "$FILE_PATH" == "$FT_PLANS_HOME"* ]]; then
    FT_DECISION="allow"; FT_REASON="under PLANS_HOME"
  elif [[ "$FILE_PATH" == /tmp/foundation-test-* ]] || [[ "$FILE_PATH" == /var/folders/*/foundation-test-* ]]; then
    FT_DECISION="allow"; FT_REASON="under foundation-test tmpdir"
  fi
  mkdir -p "$HOOKS_STATE" 2>/dev/null || true
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg d "$FT_DECISION" --arg t "$TOOL_NAME" --arg f "$FILE_PATH" --arg r "$FT_REASON" \
    '{ts:$ts,decision:$d,tool:$t,file:$f,reason:$r}' >> "$HOOKS_STATE/foundation-test.log" 2>/dev/null || true
  if [[ "$FT_DECISION" == "deny" ]]; then
    emit_deny "$FT_REASON"
  fi
  emit_allow_ctx "[FOUNDATION_TEST_MODE] allow: $FT_REASON"
fi

# === R-01: dead plans path DENY ============================================
# Permanent placeholder folder; only README.md may be written.
if [[ -n "$PLANS_DIR_DEAD" ]]; then
  if [[ "$FILE_PATH" == "$PLANS_DIR_DEAD/README.md" ]]; then
    : # allow placeholder marker
  elif [[ "$FILE_PATH" == "$PLANS_DIR_DEAD/"* ]] || [[ "$FILE_PATH" == "$PLANS_DIR_DEAD" ]]; then
    emit_deny "Dead path \$PLANS_DIR_DEAD — migrated. Update reference to use \$PLANS_DIR (from lib/paths.sh)."
  fi
fi

# === R-23: cron wrapper bash 3.2 compatibility =============================
# Cron wrappers under $CRON_WRAPPERS/*.sh execute under macOS /bin/bash 3.2.
# DENY bash 4+ syntax that silently fails in cron context.
if [[ "$FILE_PATH" == *"/orchestrator/cron-wrappers/"*".sh" ]] || \
   [[ "$FILE_PATH" == "$CRON_WRAPPERS"/*.sh ]]; then
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
      CW_OFFENDER='parameter case expansion (bash 4+)'
    elif echo "$CW_CONTENT" | grep -qE '^[[:space:]]*(readarray|mapfile)\b'; then
      CW_OFFENDER="readarray / mapfile (bash 4+)"
    elif echo "$CW_CONTENT" | grep -qE '\{[0-9]+\.\.[0-9]+\.\.[0-9]+\}'; then
      CW_OFFENDER="brace-expansion step syntax {a..b..n} (bash 4+)"
    elif echo "$CW_CONTENT" | grep -qE '(^|[^&])&>>'; then
      CW_OFFENDER="&>> append redirect (bash 4+)"
    fi
    if [[ -n "$CW_OFFENDER" ]]; then
      emit_deny "Cron wrapper bash 3.2 compatibility (R-23): offending construct — ${CW_OFFENDER}. macOS /bin/bash is 3.2; cron wrappers will silently fail otherwise. Substitute a 3.2 alternative."
    fi
  fi
fi

# === R-24: protected SessionEnd hooks =====================================
# Block settings.json writes that remove any hook listed in
# manifest.hooks.protected_session_end_hooks[]. Honors HOOK_GUARD_DISABLE_OK
# (per-name) and CLAUDE_MEM_DISABLE_OK=1 (back-compat).
if [[ "$FILE_PATH" == "$CLAUDE_HOME/settings.json" ]]; then
  PROTECTED=$(_manifest_get .hooks.protected_session_end_hooks)
  # Default protected list when manifest absent: claude-mem (back-compat)
  [ -z "$PROTECTED" ] || [ "$PROTECTED" = "null" ] && PROTECTED='["memory-consolidation-check.sh","claude-mem"]'

  HG_CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    HG_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
    HG_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
    HG_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
    HG_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
    HG_CONTENT=$(literal_replace "$FILE_PATH" "$HG_OLD" "$HG_NEW" "$HG_RALL")
  fi
  if [[ -n "$HG_CONTENT" ]]; then
    NAMES=$(echo "$PROTECTED" | jq -r '.[]?' 2>/dev/null)
    for name in $NAMES; do
      if ! echo "$HG_CONTENT" | grep -qE "$(printf '%s' "$name" | sed 's/[][\\.\\*^$()+?{|]/\\&/g')"; then
        # Removal detected. Check overrides.
        if [[ "${CLAUDE_MEM_DISABLE_OK:-0}" == "1" ]] && [[ "$name" == "claude-mem" || "$name" == "memory-consolidation-check.sh" ]]; then
          audit_log "CLAUDE_MEM_DISABLE_OK override | $FILE_PATH | $name"
          continue
        fi
        if [[ "${HOOK_GUARD_DISABLE_OK:-}" == "$name" ]]; then
          audit_log "HOOK_GUARD_DISABLE_OK override | $FILE_PATH | $name"
          continue
        fi
        emit_deny "Protected SessionEnd hook (R-24): this settings.json write removes the protected hook '${name}' (from manifest.hooks.protected_session_end_hooks[]). Set HOOK_GUARD_DISABLE_OK=${name} to override for this write."
      fi
    done
  fi
fi

# === R-27: plan naming + status enforcement ===============================
# Enforce numeric prefix + status header on plan-root files. Sources canonical
# classifier from skills/librarian/lib/plan-path.sh (foundation distribution
# duplicates this into hooks/lib/ to break install-order coupling).
PLAN_PATH_LIB="${CLAUDE_HOME}/hooks/lib/plan-path.sh"
[ ! -f "$PLAN_PATH_LIB" ] && PLAN_PATH_LIB="${CLAUDE_HOME}/skills/librarian/lib/plan-path.sh"
if [ -f "$PLAN_PATH_LIB" ]; then
  source "$PLAN_PATH_LIB"
  PS_INFO=$(classify_plan_path "$FILE_PATH" 2>/dev/null || echo "0|0|")
  PS_IS_PLAN="${PS_INFO%%|*}"
  PS_REST="${PS_INFO#*|}"
  PS_IS_MANIFEST="${PS_REST%%|*}"
  PS_TOP_SEGMENT="${PS_REST#*|}"

  if [[ "$PS_IS_PLAN" == "1" ]]; then
    # Prefix check first — must start with NN-
    if ! [[ "$PS_TOP_SEGMENT" =~ ^[0-9]+- ]]; then
      if [[ "${PLAN_STATUS_OK:-0}" == "1" ]]; then
        audit_log "PLAN_STATUS_OK override (prefix) | $FILE_PATH"
      else
        emit_deny "Plan naming (R-27): missing required NN- numeric prefix on top segment '${PS_TOP_SEGMENT}'. Plans under \$PLANS_DIR must start with the next-available integer. Escape: PLAN_STATUS_OK=1 (logged)."
      fi
    fi

    # Status check
    PS_CONTENT=""
    if [[ "$TOOL_NAME" == "Write" ]]; then
      PS_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
    elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
      PS_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
      PS_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
      PS_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
      PS_CONTENT=$(literal_replace "$FILE_PATH" "$PS_OLD" "$PS_NEW" "$PS_RALL")
    fi
    if [[ -n "$PS_CONTENT" ]]; then
      PS_HAS_STATUS=0
      if [[ "$PS_IS_MANIFEST" == "1" ]]; then
        if echo "$PS_CONTENT" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); v=d.get("status","") if isinstance(d,dict) else ""
  sys.exit(0 if v else 1)
except Exception:
  sys.exit(1)' 2>/dev/null; then PS_HAS_STATUS=1; fi
      else
        if echo "$PS_CONTENT" | grep -qE '^\*\*Status:\*\*[[:space:]]*\S+'; then
          PS_HAS_STATUS=1
        elif echo "$PS_CONTENT" | awk '/^---[[:space:]]*$/{n++; next} n==1{print} n>=2{exit}' | grep -qE '^status:[[:space:]]*\S+'; then
          PS_HAS_STATUS=1
        fi
      fi
      if [[ "$PS_HAS_STATUS" == "0" ]]; then
        if [[ "${PLAN_STATUS_OK:-0}" == "1" ]]; then
          audit_log "PLAN_STATUS_OK override (status) | $FILE_PATH"
        else
          emit_deny "Plan naming (R-27): missing status marker. Required: (a) **Status:** <value> bullet, (b) YAML status: field, or (c) manifest.json top-level status field. Escape: PLAN_STATUS_OK=1 (logged)."
        fi
      fi
    fi
  fi
fi

# === Size guards (R-04 size dimension) =====================================
# Read manifest.schema.size_guards[] (each: {path, soft_limit_bytes,
# hard_limit_bytes, message_template}). DENY when post-write size exceeds
# hard_limit_bytes; surface warning when over soft_limit_bytes.
SG_ENTRIES=$(_manifest_get .schema.size_guards)
if [ -n "$SG_ENTRIES" ] && [ "$SG_ENTRIES" != "null" ] && [ "$SG_ENTRIES" != "[]" ]; then
  SG_MATCH=$(echo "$SG_ENTRIES" | jq -c --arg fp "$FILE_PATH" '.[] | select(.path == $fp)' 2>/dev/null | head -1)
  if [ -n "$SG_MATCH" ]; then
    SG_HARD=$(echo "$SG_MATCH" | jq -r '.hard_limit_bytes // empty')
    SG_SOFT=$(echo "$SG_MATCH" | jq -r '.soft_limit_bytes // empty')
    SG_TPL=$(echo "$SG_MATCH" | jq -r '.message_template // empty')
    SG_NEW_SIZE=0
    if [[ "$TOOL_NAME" == "Write" ]]; then
      SG_NEW_SIZE=$(echo "$INPUT" | jq -r '.tool_input.content // empty' | wc -c | tr -d ' ')
    elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
      SG_OLD_S=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
      SG_NEW_S=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
      SG_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
      SG_NEW_SIZE=$(literal_replace "$FILE_PATH" "$SG_OLD_S" "$SG_NEW_S" "$SG_RALL" | wc -c | tr -d ' ')
    fi
    if [ -n "$SG_HARD" ] && [ "$SG_NEW_SIZE" -gt "$SG_HARD" ]; then
      SG_MSG="${SG_TPL:-Size guard exceeded for {path}: {size} bytes exceeds hard limit {limit}}"
      SG_MSG="${SG_MSG//\{path\}/$FILE_PATH}"
      SG_MSG="${SG_MSG//\{size\}/$SG_NEW_SIZE}"
      SG_MSG="${SG_MSG//\{limit\}/$SG_HARD}"
      emit_deny "$SG_MSG"
    fi
  fi
fi

# === Direct librarian-manifest block ======================================
if [[ "$FILE_PATH" == *"librarian-manifest.json"* ]]; then
  emit_deny "Direct edits to librarian-manifest.json are prohibited — must be regenerated through /librarian. Manual edits stale the backend_sync flags."
fi

# === R-40 plan-artifact frontmatter advisory + R-15 backlog reminder ======
# Tier 1 advisory; never blocks. R-15 template comes from
# manifest.plans.backlog_enforcement.error_template (with {plan_slug}
# interpolation), or generic fallback. R-28 sub-plan parent_plan suppresses R-15.
if [[ "$FILE_PATH" == "$PLANS_DIR/"*.md ]] || [[ "$FILE_PATH" == *"/.claude-plans/"*.md ]]; then
  R40_ADVISORY=""
  PL_BASE=$(basename "$FILE_PATH")
  PL_EXPECTED_TYPE=""
  case "$PL_BASE" in
    spec.md) PL_EXPECTED_TYPE="spec" ;;
    tasks.md) PL_EXPECTED_TYPE="tasks" ;;
    handoff.md) PL_EXPECTED_TYPE="handoff" ;;
    00-ideation-brief.md) PL_EXPECTED_TYPE="ideation-brief" ;;
  esac

  PL_CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    PL_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
    PL_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
    PL_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
    PL_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
    PL_CONTENT=$(literal_replace "$FILE_PATH" "$PL_OLD" "$PL_NEW" "$PL_RALL")
  fi

  if [[ -n "$PL_EXPECTED_TYPE" ]] && [[ -n "$PL_CONTENT" ]]; then
    PL_ACTUAL_TYPE=$(printf '%s\n' "$PL_CONTENT" | awk '/^---[[:space:]]*$/{n++; next} n==1{print} n>=2{exit}' 2>/dev/null | grep -E '^type:[[:space:]]*' 2>/dev/null | head -1 | sed -E 's/^type:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//' 2>/dev/null || true)
    if [[ -z "$PL_ACTUAL_TYPE" ]]; then
      R40_ADVISORY="[R-40 PLAN FRONTMATTER] ${PL_BASE} is missing canonical type: field. Expected: type: ${PL_EXPECTED_TYPE} (per ${SCHEMAS_DIR}/plans-schema.json). Advisory only."
    elif [[ "$PL_ACTUAL_TYPE" != "$PL_EXPECTED_TYPE" ]]; then
      R40_ADVISORY="[R-40 PLAN FRONTMATTER] ${PL_BASE} has non-canonical type: '${PL_ACTUAL_TYPE}'. Expected: type: ${PL_EXPECTED_TYPE}. Advisory only."
    fi
  fi

  # R-28: parent_plan presence suppresses R-15 (sub-plan inherits backlog row)
  PL_IS_SUBPLAN=0
  if [[ -n "$PL_CONTENT" ]] && printf '%s\n' "$PL_CONTENT" | awk '/^---[[:space:]]*$/{n++; next} n==1{print} n>=2{exit}' 2>/dev/null | grep -qE '^parent_plan:[[:space:]]*[^[:space:]]'; then
    PL_IS_SUBPLAN=1
  fi

  PL_CONTEXT=""
  if [[ $PL_IS_SUBPLAN -eq 0 ]]; then
    R15_TPL=$(_manifest_get .plans.backlog_enforcement.error_template)
    if [ -z "$R15_TPL" ]; then
      R15_TPL="[R-15 PLAN→BACKLOG] After writing this plan file, you MUST add or update the corresponding row in the backlog. Plans without backlog rows are invisible to architect/librarian and will surface as a backlog-row-missing finding at session-close."
    fi
    # {plan_slug} interpolation: derive slug from path under $PLANS_DIR
    PL_SLUG=""
    if [[ "$FILE_PATH" == "$PLANS_DIR"/* ]]; then
      PL_SLUG="${FILE_PATH#$PLANS_DIR/}"
      PL_SLUG="${PL_SLUG%%/*}"
    fi
    PL_CONTEXT="${R15_TPL//\{plan_slug\}/$PL_SLUG}"
  fi
  if [[ -n "$R40_ADVISORY" ]]; then
    [[ -n "$PL_CONTEXT" ]] && PL_CONTEXT="${PL_CONTEXT}"$'\n\n'"${R40_ADVISORY}" || PL_CONTEXT="${R40_ADVISORY}"
  fi

  if [[ -z "$PL_CONTEXT" ]]; then
    jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow"}}'
    exit 0
  fi
  emit_allow_ctx "$PL_CONTEXT"
fi

# === R-02: skill change protocol reminder ================================
if [[ "$FILE_PATH" == "$CLAUDE_HOME/skills/"*"/SKILL.md" ]]; then
  emit_allow_ctx "[SKILL CHANGE PROTOCOL] After this edit, complete the post-change checklist: (1) save/update memory (2) update affected docs (3) grep for downstream effects (4) verify ID emission. Blocking step before moving on."
fi

# === R-45 + R-42: memory file overlap + schema validation ================
# Memory dir resolved from lib/paths.sh resolve_memory_dir() — slugified cwd.
MEMORY_DIR_RESOLVED="$(resolve_memory_dir 2>/dev/null || true)"
if [[ -n "$MEMORY_DIR_RESOLVED" ]] && [[ "$FILE_PATH" == "$MEMORY_DIR_RESOLVED"/*.md ]] && \
   [[ "$(basename "$FILE_PATH")" != "MEMORY.md" ]]; then

  OVERLAP_MSG=""
  SCHEMA_MSG=""
  MEMORY_INDEX="$MEMORY_DIR_RESOLVED/MEMORY.md"
  NEW_BASE="$(basename "$FILE_PATH" .md)"

  if [[ -f "$MEMORY_INDEX" ]]; then
    KEYWORDS=$(echo "$NEW_BASE" | tr '_' '\n' | grep -v -E '^(user|feedback|project|reference)$' | tr '\n' '|')
    KEYWORDS="${KEYWORDS%|}"
    if [[ -n "$KEYWORDS" ]]; then
      MATCHES=$(grep -iE "$KEYWORDS" "$MEMORY_INDEX" | grep '^\- \[' || true)
      if [[ -n "$MATCHES" ]]; then
        OVERLAP_MSG="[MEMORY OVERLAP CHECK] Writing memory file ${NEW_BASE}.md. Potential overlaps:"$'\n'"${MATCHES}"$'\n'"Consider UPDATE (merge) vs ADD (new file)."
      fi
    fi
  fi

  CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
    MS_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
    MS_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
    MS_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
    CONTENT=$(literal_replace "$FILE_PATH" "$MS_OLD" "$MS_NEW" "$MS_RALL")
  fi

  if [[ -n "$CONTENT" ]]; then
    FRONTMATTER=$(echo "$CONTENT" | awk '/^---$/{n++; next} n==1{print} n>=2{exit}')
    MISSING=""
    FM_NAME=$(echo "$FRONTMATTER" | grep -E '^name:' | head -1 | sed 's/^name:[[:space:]]*//' || true)
    FM_DESC=$(echo "$FRONTMATTER" | grep -E '^description:' | head -1 | sed 's/^description:[[:space:]]*//' || true)
    FM_TYPE=$(echo "$FRONTMATTER" | grep -E '^type:' | head -1 | sed 's/^type:[[:space:]]*//' || true)
    FM_VERIFIED=$(echo "$FRONTMATTER" | grep -E '^last_verified:' | head -1 | sed 's/^last_verified:[[:space:]]*//' || true)
    [[ -z "$FM_NAME" ]] && MISSING="${MISSING}"$'\n'"- name: missing"
    [[ -z "$FM_DESC" ]] && MISSING="${MISSING}"$'\n'"- description: missing"
    if [[ -z "$FM_TYPE" ]]; then
      MISSING="${MISSING}"$'\n'"- type: missing (use user|feedback|project|reference)"
    elif ! echo "$FM_TYPE" | grep -qE '^(user|feedback|project|reference)$'; then
      MISSING="${MISSING}"$'\n'"- type: invalid '${FM_TYPE}' (must be user|feedback|project|reference)"
    fi
    TODAY=$(date +%Y-%m-%d)
    if [[ -z "$FM_VERIFIED" ]]; then
      MISSING="${MISSING}"$'\n'"- last_verified: missing (set to ${TODAY})"
    elif ! echo "$FM_VERIFIED" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
      MISSING="${MISSING}"$'\n'"- last_verified: invalid format '${FM_VERIFIED}' (YYYY-MM-DD required)"
    fi
    if [[ "$FM_TYPE" == "project" ]]; then
      FM_STATUS=$(echo "$FRONTMATTER" | grep -E '^status:' | head -1 | sed 's/^status:[[:space:]]*//' || true)
      if [[ -z "$FM_STATUS" ]]; then
        MISSING="${MISSING}"$'\n'"- status: missing (project memories require active|completed|superseded)"
      elif ! echo "$FM_STATUS" | grep -qE '^(active|completed|superseded)$'; then
        MISSING="${MISSING}"$'\n'"- status: invalid '${FM_STATUS}' (must be active|completed|superseded)"
      fi
      if [[ "$FM_STATUS" == "superseded" ]]; then
        FM_SUPER=$(echo "$FRONTMATTER" | grep -E '^superseded_by:' | head -1 | sed 's/^superseded_by:[[:space:]]*//' || true)
        if [[ -z "$FM_SUPER" ]]; then
          MISSING="${MISSING}"$'\n'"- superseded_by: missing (required when status=superseded)"
        elif [[ ! -f "$MEMORY_DIR_RESOLVED/$FM_SUPER" ]]; then
          MISSING="${MISSING}"$'\n'"- superseded_by: file '${FM_SUPER}' not found"
        fi
      fi
    fi
    if [[ -n "$MISSING" ]]; then
      SCHEMA_MSG="[MEMORY SCHEMA CHECK] $(basename "$FILE_PATH")"$'\n'"Missing/invalid:${MISSING}"
      MS_AUDIT_FILE="$HOOKS_STATE/memory-schema-advisory-history.jsonl"
      mkdir -p "$HOOKS_STATE" 2>/dev/null || true
      MS_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      jq -nc --arg ts "$MS_TS" --arg tool "$TOOL_NAME" --arg path "$FILE_PATH" --arg miss "$MISSING" \
        '{ts:$ts,tool:$tool,file:$path,missing_fields:($miss|split("\n")|map(select(length>0)))}' \
        >> "$MS_AUDIT_FILE" 2>/dev/null || true
    fi
  fi

  if [[ -n "$OVERLAP_MSG" ]] || [[ -n "$SCHEMA_MSG" ]]; then
    COMBINED=""
    [[ -n "$OVERLAP_MSG" ]] && COMBINED="$OVERLAP_MSG"
    if [[ -n "$SCHEMA_MSG" ]]; then
      [[ -n "$COMBINED" ]] && COMBINED="${COMBINED}"$'\n\n'
      COMBINED="${COMBINED}${SCHEMA_MSG}"
    fi
    emit_allow_ctx "$COMBINED"
  fi
fi

# === R-54: doc-dependency cascade =========================================
DOC_DEP_FILE="${HOOKS_DIR}/config/doc-dependencies.json"
DOC_DEP_CTX=""
if [[ -f "$DOC_DEP_FILE" ]]; then
  DD_REL=""
  if [[ -n "$VAULT_ROOT" ]] && [[ "$FILE_PATH" == "$VAULT_ROOT"/* ]]; then
    DD_REL="${FILE_PATH#$VAULT_ROOT/}"
  fi
  if [[ "$FILE_PATH" == "$HOME"/* ]]; then
    DD_HOMEKEY="~/${FILE_PATH#$HOME/}"
  else
    DD_HOMEKEY="$FILE_PATH"
  fi
  DEP_MATCH=$(jq -r --arg rel "$DD_REL" --arg abs "$DD_HOMEKEY" '
    .entries[]?
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
    DOC_DEP_CTX="[DOC-DEPENDENCY CASCADE] This write touches a registered dependency:"$'\n'"${DEP_MATCH}"$'\n\n'"Review mirrors in this session, OR file a waiver via cascade_waiver_write."
  fi
fi

# === Vault schema 3-tier (R-04 placement, R-32 type, R-33 folder) ========
SCHEMA_FILE="$SCHEMAS_DIR/vault-schema.json"
if [[ -n "$VAULT_ROOT" ]] && [[ "$FILE_PATH" == "$VAULT_ROOT/"* ]] && \
   [[ "$FILE_PATH" == *.md ]] && [[ -f "$SCHEMA_FILE" ]]; then

  REL_PATH="${FILE_PATH#$VAULT_ROOT/}"

  # Skip operational files (manifests, coordination, root CLAUDE.md)
  if [[ "$REL_PATH" != "Logs/librarian-manifest"* ]] && \
     [[ "$REL_PATH" != "Logs/.coordination/"* ]] && \
     [[ "$REL_PATH" != "CLAUDE.md" ]] && \
     [[ "$REL_PATH" != *"/CLAUDE.md" ]]; then

    CONTENT=""
    if [[ "$TOOL_NAME" == "Write" ]]; then
      CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
    elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
      VS_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
      VS_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
      VS_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
      CONTENT=$(literal_replace "$FILE_PATH" "$VS_OLD" "$VS_NEW" "$VS_RALL")
      [[ -z "$CONTENT" ]] && [[ -f "$FILE_PATH" ]] && CONTENT=$(cat "$FILE_PATH")
    fi

    if [[ -n "$CONTENT" ]]; then
      FRONTMATTER=$(echo "$CONTENT" | awk '/^---$/{c++;next} c==1{print} c>=2{exit}')
      if [[ -n "$FRONTMATTER" ]]; then
        TIER1_MSGS=""
        TIER2_MSGS=""
        TIER3_MSGS=""

        fm_val() { echo "$FRONTMATTER" | grep -E "^${1}:" | head -1 | sed "s/^${1}:[[:space:]]*//" || true; }
        fm_has() { echo "$FRONTMATTER" | grep -qE "^${1}:" && return 0 || return 1; }

        FM_TYPE=$(fm_val "type")

        # === R-32: type allowlist (Tier 2 DENY) — sourced from vault-schema.json ===
        if [[ -n "$FM_TYPE" ]]; then
          # Build allowed set: top-level keys + any aliases declared in _aliases
          TYPE_OK=$(jq -r --arg t "$FM_TYPE" '
            ([keys[] | select(startswith("_") | not)] +
             (._aliases // {} | keys // [])) | index($t) // empty
          ' "$SCHEMA_FILE" 2>/dev/null)
          if [[ -z "$TYPE_OK" ]]; then
            TIER2_MSGS="${TIER2_MSGS}[R-32 UNKNOWN TYPE] type: '${FM_TYPE}' is not in the schema allowlist. To add: update vault-schema.json with required fields, then commit lockstep with hook updates (R-37)."$'\n'
          fi
        fi

        # Resolve schema key (alias-aware)
        SCHEMA_KEY="$FM_TYPE"
        if [[ -n "$FM_TYPE" ]]; then
          ALIAS_TARGET=$(jq -r --arg t "$FM_TYPE" '._aliases[$t] // empty' "$SCHEMA_FILE" 2>/dev/null)
          [[ -n "$ALIAS_TARGET" ]] && SCHEMA_KEY="$ALIAS_TARGET"
        fi

        # Tier 1: 'updated' field per schema's required list
        if [[ -n "$SCHEMA_KEY" ]] && ! fm_has "updated"; then
          UPDATED_REQUIRED=$(jq -r --arg key "$SCHEMA_KEY" '.[$key].required // [] | .[] | select(. == "updated")' "$SCHEMA_FILE" 2>/dev/null)
          if [[ -n "$UPDATED_REQUIRED" ]]; then
            TIER1_MSGS="${TIER1_MSGS}Vault write needs 'updated: $(date +%Y-%m-%d)' in frontmatter."$'\n'
          fi
        fi

        # === R-33: folder placement advisory (Tier 1) ===
        # Schema entries may declare a path-pattern hint via _placement_pattern.
        if [[ -n "$FM_TYPE" ]] && [[ -n "$SCHEMA_KEY" ]]; then
          PLACE_PATTERN=$(jq -r --arg key "$SCHEMA_KEY" '.[$key]._placement_pattern // empty' "$SCHEMA_FILE" 2>/dev/null)
          if [[ -n "$PLACE_PATTERN" ]] && ! [[ "$REL_PATH" == $PLACE_PATTERN ]]; then
            TIER1_MSGS="${TIER1_MSGS}[R-33 FOLDER PLACEMENT] type '${FM_TYPE}' typically lives under '${PLACE_PATTERN}'. Current: '${REL_PATH}'. Move before writing or ignore if intentional."$'\n'
          fi
        fi

        # Tier 2: required fields per schema
        if [[ -n "$SCHEMA_KEY" ]]; then
          REQUIRED_FIELDS=$(jq -r --arg key "$SCHEMA_KEY" '.[$key].required // [] | .[]' "$SCHEMA_FILE" 2>/dev/null)
          if [[ -n "$REQUIRED_FIELDS" ]]; then
            MISSING_FIELDS=""
            while IFS= read -r field; do
              if [[ "$field" != "updated" ]] && ! fm_has "$field"; then
                MISSING_FIELDS="${MISSING_FIELDS}${field}, "
              fi
            done <<< "$REQUIRED_FIELDS"
            MISSING_FIELDS="${MISSING_FIELDS%, }"
            if [[ -n "$MISSING_FIELDS" ]]; then
              TIER2_MSGS="${TIER2_MSGS}Missing required fields [${MISSING_FIELDS}] for file type '${SCHEMA_KEY}'."$'\n'
            fi
          fi
        fi

        # Tier 2: emit DENY if any blocking issue
        if [[ -n "$TIER2_MSGS" ]]; then
          audit_log "DENY | $FILE_PATH | $TIER2_MSGS"
          emit_deny "Write blocked — vault schema enforcement:"$'\n'"${TIER2_MSGS}Add the missing fields and retry."
        fi

        # === Tier 3: vault-root allowlist (R-04) ===
        # Read manifest.vault.root_directories[] (allowed top-level dirs).
        # Empty/absent = no allowlist enforcement.
        ROOT_DIR=$(echo "$REL_PATH" | cut -d'/' -f1)
        ROOT_DIRS=$(_manifest_get .vault.root_directories)
        if [ -n "$ROOT_DIRS" ] && [ "$ROOT_DIRS" != "null" ] && [ "$ROOT_DIRS" != "[]" ]; then
          IS_KNOWN=$(echo "$ROOT_DIRS" | jq -r --arg r "$ROOT_DIR" 'index($r) // empty' 2>/dev/null)
          # Allow root .md files (they're not in a directory)
          if [[ -z "$IS_KNOWN" ]] && [[ "$REL_PATH" == */* ]]; then
            TIER3_MSGS="${TIER3_MSGS}[R-04 NEW DIRECTORY] '${ROOT_DIR}/' is not in manifest.vault.root_directories[]. After this write, add it to the manifest or move the file."$'\n'
          fi
        fi

        # Emit combined Tier 1 + Tier 3 + DOC_DEP_CTX
        COMBINED_CTX=""
        [[ -n "$TIER1_MSGS" ]] && COMBINED_CTX="[VAULT SCHEMA - AUTO-FIX NEEDED]"$'\n'"${TIER1_MSGS}"
        if [[ -n "$TIER3_MSGS" ]]; then
          [[ -n "$COMBINED_CTX" ]] && COMBINED_CTX="${COMBINED_CTX}"$'\n'
          COMBINED_CTX="${COMBINED_CTX}[VAULT SCHEMA - FOLLOW-UP REQUIRED]"$'\n'"${TIER3_MSGS}"
        fi
        if [[ -n "$DOC_DEP_CTX" ]]; then
          [[ -n "$COMBINED_CTX" ]] && COMBINED_CTX="${COMBINED_CTX}"$'\n\n'
          COMBINED_CTX="${COMBINED_CTX}${DOC_DEP_CTX}"
          DOC_DEP_CTX=""  # consumed
        fi
        if [[ -n "$COMBINED_CTX" ]]; then
          emit_allow_ctx "$COMBINED_CTX"
        fi
      fi
    fi
  fi
fi

# === R-42: multi-session file overlap advisory ===========================
if [[ -n "$VAULT_ROOT" ]]; then
  REGISTRY="$VAULT_ROOT/Logs/.coordination/session-registry.json"
  if [[ -f "$REGISTRY" ]] && [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    REL_PATH="${FILE_PATH#$VAULT_ROOT/}"
    if [[ "$REL_PATH" != "$FILE_PATH" ]]; then
      PEER=$(jq -r --arg sid "$CLAUDE_SESSION_ID" --arg fp "$REL_PATH" '
        .sessions // {} | to_entries[]
        | select(.key != $sid)
        | select(.value.touched_files // [] | index($fp))
        | .key
      ' "$REGISTRY" 2>/dev/null | head -1)
      if [[ -n "$PEER" ]]; then
        emit_allow_ctx "[MULTI-SESSION OVERLAP] File ${REL_PATH} was modified by peer session ${PEER}. Coordinate before conflicting changes."
      fi
    fi
  fi
fi

# === Terminal fall-through ================================================
# Unconsumed DOC_DEP_CTX (e.g. non-vault write) surfaces here so the cascade
# warning never silently drops.
if [[ -n "${DOC_DEP_CTX:-}" ]]; then
  emit_allow_ctx "$DOC_DEP_CTX"
fi

exit 0
