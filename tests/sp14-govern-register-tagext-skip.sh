#!/usr/bin/env bash
# SP14 T-18 Theme B — /govern register tag-extension skip path
#
# Per Plan 81 SP14 spec.md §7. bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"

TEMPROOT="$(mktemp -d -t sp14-tagext-skip.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export VAULT_ROOT="$TEMPROOT/vault"
export CLAUDE_SESSION_ID="sp14-t18-tagext-skip"
mkdir -p "$VAULT_ROOT"
echo '{}' > "$OVERLAY_MASTER"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 tagext-skip ===\n'

bash "$FOUNDATION_REPO/skills/govern/register/process.sh" skip --kind tag-extension --target some-dim --reason "not yet ready" 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "skip rc=0" || emit_fail "skip rc=$RC; stderr: $(cat "$TEMPROOT/stderr")"

[ "$(cat "$OVERLAY_MASTER")" = "{}" ] && emit_pass "overlay UNCHANGED" || emit_fail "overlay mutated"

ROW=$(head -1 "$ACTION_LOG")
UNREG=$(printf '%s' "$ROW" | jq -r '.unregistered')
[ "$UNREG" = "true" ] && emit_pass ".unregistered == true" || emit_fail ".unregistered = '$UNREG'"

K=$(printf '%s' "$ROW" | jq -r '.kind')
[ "$K" = "tag-extension" ] && emit_pass ".kind == tag-extension" || emit_fail ".kind = '$K'"

if python3 -c "
import json, jsonschema
schema = json.load(open('$FOUNDATION_REPO/schemas/governance-action-log-schema.json'))
jsonschema.Draft202012Validator(schema).validate(json.loads(open('$ACTION_LOG').read().strip()))
" 2>"$TEMPROOT/se"; then
  emit_pass "skip row validates against schema"
else
  emit_fail "skip row schema: $(cat "$TEMPROOT/se")"
fi

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%b\n' "$FAILED_CHECKS"; exit 1; }
exit 0
