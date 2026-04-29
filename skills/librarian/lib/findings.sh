# findings.sh — Canonical finding emission for librarian capabilities.
#
# Landed: Plan 61 Librarian Shared-Helper Consolidation (2026-04-19/20).
# Centralizes the JSON-line emission pattern that drift-sweep.sh and
# people-audit.sh both reimplemented inline. Future shell capabilities
# (Plan 59 tag-coverage-audit, wikilink-repair, and the broader capability
# extraction initiative) source this helper from day one.
#
# Usage:
#   source "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/lib/findings.sh"
#   emit_finding <name> <file> [<key> <value> ...]
#   emit_event '<raw JSON line>'
#
# Output routing: if FINDINGS_OUTPUT env var is set, append to that file;
# otherwise echo to stdout. Mirrors the inline OUTPUT-or-stdout pattern that
# both extracted capabilities reimplemented.
#
# Schema (emit_finding):
#   { "finding": "<name>", "file": "<file>"[, "<k>": "<v>" ...] }
#
# All values are wrapped as JSON strings. For numeric/boolean values or
# nested objects, pre-format the line and pass via emit_event instead.
#
# Bash 3.2 clean per R-23.

emit_event() {
  local payload="$1"
  if [[ -n "${FINDINGS_OUTPUT:-}" ]]; then
    echo "$payload" >> "$FINDINGS_OUTPUT"
  else
    echo "$payload"
  fi
}

emit_finding() {
  local name="$1" file="$2"; shift 2
  local json="{ \"finding\": \"${name}\", \"file\": \"${file}\""
  while [[ $# -ge 2 ]]; do
    json="${json}, \"$1\": \"$2\""
    shift 2
  done
  json="${json} }"
  emit_event "$json"
}
