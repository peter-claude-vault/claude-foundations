# ~/.claude/hooks/lib/validate-hook-output.sh
# Plan 84 SP03 — Pre-emit JSON schema validator for Claude Code hook stdout.
#
# Source this file — do not execute it.
#   source "$HOME/.claude/hooks/lib/validate-hook-output.sh"
#
# Public function:
#   validate_hook_output
#     Reads JSON payload from stdin.
#     Returns 0 on valid; 1 on invalid; writes rejection reason to stderr.
#
# Schema: $HOOKS_SCHEMAS_DIR/hook-output.json (default ~/.claude/hooks/schemas/hook-output.json).
#
# Validation engine: Python jsonschema (preferred); jq structural fallback (deny-on-doubt).
# Strict mode per spec.md AC-7: invalid emission → rc=1 + clear stderr error.

# Resolve schemas dir chain.
__vho_resolve_schemas_dir() {
  printf '%s' "${HOOKS_SCHEMAS_DIR:-${CLAUDE_HOME:-$HOME/.claude}/hooks/schemas}"
}

# Public: validate JSON on stdin against hook-output.json schema.
validate_hook_output() {
  local schemas_dir schema_file payload
  schemas_dir=$(__vho_resolve_schemas_dir)
  schema_file="$schemas_dir/hook-output.json"

  if [[ ! -f "$schema_file" ]]; then
    echo "[validate-hook-output] schema file missing: $schema_file" >&2
    return 1
  fi

  payload=$(cat)
  if [[ -z "$payload" ]]; then
    echo "[validate-hook-output] empty payload" >&2
    return 1
  fi

  # Preferred engine: Python jsonschema.
  # Payload via env var (NOT stdin) to avoid heredoc+stdin collision —
  # see feedback_python_heredoc_argv.md.
  if command -v python3 >/dev/null 2>&1; then
    local py_rc
    PAYLOAD_FOR_VALIDATION="$payload" python3 - "$schema_file" <<'PY'
import os, sys, json
try:
    import jsonschema
except ImportError:
    sys.stderr.write("ENGINE_MISSING: jsonschema not installed\n")
    sys.exit(2)

schema_path = sys.argv[1]
payload_str = os.environ.get("PAYLOAD_FOR_VALIDATION", "")

if not payload_str:
    sys.stderr.write("EMPTY_PAYLOAD\n")
    sys.exit(1)

try:
    payload = json.loads(payload_str)
except json.JSONDecodeError as e:
    sys.stderr.write(f"PAYLOAD_PARSE_ERROR: {e}\n")
    sys.exit(1)

try:
    schema = json.load(open(schema_path))
except Exception as e:
    sys.stderr.write(f"SCHEMA_LOAD_ERROR: {e}\n")
    sys.exit(2)

try:
    jsonschema.validate(payload, schema)
    sys.exit(0)
except jsonschema.ValidationError as e:
    path = "/".join(str(p) for p in e.absolute_path) or "<root>"
    msg = str(e.message).replace("\n", " ")
    sys.stderr.write(f"VALIDATION_FAILED at {path}: {msg}\n")
    sys.exit(1)
PY
    py_rc=$?
    if [[ $py_rc -eq 0 ]]; then
      return 0
    elif [[ $py_rc -eq 1 ]]; then
      return 1
    fi
    # py_rc==2 → engine missing or schema load error; fall through to jq.
    echo "[validate-hook-output] python engine unavailable (rc=$py_rc); falling back to jq" >&2
  fi

  # Fallback engine: jq structural check.
  if ! command -v jq >/dev/null 2>&1; then
    echo "[validate-hook-output] no validation engine available (need python3+jsonschema or jq)" >&2
    return 1
  fi

  # Structural assertions:
  #   1. payload is JSON object
  #   2. .hookSpecificOutput exists and is an object
  #   3. .hookSpecificOutput.hookEventName ∈ {PreToolUse, UserPromptSubmit, PostToolUse, SessionStart, Stop}
  #   4. payload root has ONLY hookSpecificOutput as top-level key
  local jq_err
  jq_err=$(printf '%s' "$payload" | jq -e '
    (type == "object")
    and ((.hookSpecificOutput // null) | type) == "object"
    and (.hookSpecificOutput.hookEventName as $e |
         ($e == "PreToolUse" or $e == "UserPromptSubmit" or $e == "PostToolUse" or $e == "SessionStart" or $e == "Stop"))
    and ((keys | length) == 1)
    and (keys[0] == "hookSpecificOutput")
  ' 2>&1)
  local jq_rc=$?
  if [[ $jq_rc -eq 0 ]]; then
    return 0
  fi
  echo "[validate-hook-output] jq-fallback rejection: $jq_err" >&2
  return 1
}
