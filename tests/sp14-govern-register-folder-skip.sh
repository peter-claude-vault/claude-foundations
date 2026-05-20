#!/usr/bin/env bash
# SP14 T-18 Theme B — /govern register folder mode skip path
#
# Scope: process.sh skip --kind folder --reason "..." appends action-log row
# with unregistered: true + proposed_by: skipped + skip_reason in
# rejected_fields; overlay-master.json UNCHANGED.
#
# Per Plan 81 SP14 spec.md §7 + Batch H handoff smoke test #15 + Batch H
# judgment-call note "skip-path action-log row composition".
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"

TEMPROOT="$(mktemp -d -t sp14-folder-skip.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export VAULT_ROOT="$TEMPROOT/vault"
export CLAUDE_SESSION_ID="sp14-t18-folder-skip"
mkdir -p "$VAULT_ROOT"
echo '{}' > "$OVERLAY_MASTER"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 folder-skip ===\n'

bash "$FOUNDATION_REPO/skills/govern/register/process.sh" skip --kind folder --target Misc --reason "ad-hoc one-off" >"$TEMPROOT/stdout" 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "skip rc=0" || emit_fail "skip rc=$RC; stderr: $(cat "$TEMPROOT/stderr")"

# ---- overlay UNCHANGED ------------------------------------------------------
OVERLAY_CONTENT=$(cat "$OVERLAY_MASTER")
[ "$OVERLAY_CONTENT" = "{}" ] && emit_pass "overlay-master.json UNCHANGED" || emit_fail "overlay-master mutated: $OVERLAY_CONTENT"

# ---- action-log row inspection ---------------------------------------------
ROW_COUNT=$(wc -l < "$ACTION_LOG" | tr -d ' ')
[ "$ROW_COUNT" = "1" ] && emit_pass "action-log has 1 row" || emit_fail "row count = $ROW_COUNT (expected 1)"

ROW=$(head -1 "$ACTION_LOG")

UNREG=$(printf '%s' "$ROW" | jq -r '.unregistered')
[ "$UNREG" = "true" ] && emit_pass ".unregistered == true" || emit_fail ".unregistered = '$UNREG'"

PB=$(printf '%s' "$ROW" | jq -r '.proposed_by')
[ "$PB" = "skipped" ] && emit_pass ".proposed_by == skipped" || emit_fail ".proposed_by = '$PB'"

KIND_F=$(printf '%s' "$ROW" | jq -r '.kind')
[ "$KIND_F" = "folder" ] && emit_pass ".kind == folder" || emit_fail ".kind = '$KIND_F'"

TGT=$(printf '%s' "$ROW" | jq -r '.target')
[ "$TGT" = "Misc" ] && emit_pass ".target == Misc" || emit_fail ".target = '$TGT'"

SKIP_REASON=$(printf '%s' "$ROW" | jq -r '.rejected_fields.skip_reason')
[ "$SKIP_REASON" = "ad-hoc one-off" ] && emit_pass ".rejected_fields.skip_reason captured" || emit_fail ".rejected_fields.skip_reason = '$SKIP_REASON'"

# ---- schema validation ------------------------------------------------------
if python3 -c "
import json, jsonschema
schema = json.load(open('$FOUNDATION_REPO/schemas/governance-action-log-schema.json'))
row = json.loads(open('$ACTION_LOG').read().strip())
jsonschema.Draft202012Validator(schema).validate(row)
" 2>"$TEMPROOT/se"; then
  emit_pass "skip row validates against action-log schema"
else
  emit_fail "skip row schema validation failed: $(cat "$TEMPROOT/se")"
fi

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%b\n' "$FAILED_CHECKS"; exit 1; }
exit 0
