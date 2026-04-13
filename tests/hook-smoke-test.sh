#!/usr/bin/env bash
# tests/hook-smoke-test.sh — exercise every hook under four manifest states.
#
# States:
#   1. no manifest (cold install)
#   2. valid manifest with vault.root set
#   3. valid manifest with vault.root null (no-vault user)
#   4. malformed (non-JSON) manifest
#
# For each state every hook script is invoked with a synthetic payload on
# stdin (tool hooks) or no stdin (lifecycle hooks). Each invocation must
# exit 0 and not crash with a shell error. PreToolUse/PostToolUse are allowed
# to exit 2 ONLY on a genuine policy violation — in these smoke scenarios the
# payload is benign, so we assert exit 0.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK"
HOME="$WORK" "$REPO/install.sh" >/dev/null 2>&1 || { echo "install failed"; exit 1; }

HOOK_DIR="$HOME/.claude/hooks"
MANIFEST="$HOME/.claude/user-manifest.json"

PASS=0
FAIL=0
FAILS=()

run_case() {
  local state="$1" hook="$2" payload="$3" wants_stdin="$4"
  local out err rc
  out=$(mktemp); err=$(mktemp)
  if [[ "$wants_stdin" == "yes" ]]; then
    printf '%s' "$payload" | CLAUDE_HOME="$HOME/.claude" "$HOOK_DIR/$hook" >"$out" 2>"$err"
  else
    CLAUDE_HOME="$HOME/.claude" "$HOOK_DIR/$hook" </dev/null >"$out" 2>"$err"
  fi
  rc=$?
  if [[ $rc -ne 0 ]]; then
    FAIL=$((FAIL+1))
    FAILS+=("[$state] $hook rc=$rc stderr=$(tr '\n' ' ' <"$err")")
  else
    PASS=$((PASS+1))
  fi
  rm -f "$out" "$err"
}

set_state() {
  case "$1" in
    none)      rm -f "$MANIFEST" ;;
    vault)     cp "$REPO/manifest/examples/consultant.json" "$MANIFEST"
               mkdir -p "$HOME/fake-vault"
               tmp=$(mktemp); jq --arg r "$HOME/fake-vault" '.vault.root = $r' "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST" ;;
    novault)   cp "$REPO/manifest/examples/greenfield.json" "$MANIFEST" ;;
    malformed) echo '{ this is not json' > "$MANIFEST" ;;
  esac
}

HOOKS_STDIN=(pre-tool-use.sh post-tool-use.sh)
HOOKS_NOSTDIN=(pre-compact.sh session-start.sh stop.sh user-prompt-submit.sh)

BENIGN_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'

for state in none vault novault malformed; do
  set_state "$state"
  for h in "${HOOKS_STDIN[@]}"; do
    run_case "$state" "$h" "$BENIGN_PAYLOAD" yes
  done
  for h in "${HOOKS_NOSTDIN[@]}"; do
    run_case "$state" "$h" "" no
  done
done

echo
echo "=== Hook Smoke Test ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '  %s\n' "${FAILS[@]}"
  exit 1
fi
exit 0
