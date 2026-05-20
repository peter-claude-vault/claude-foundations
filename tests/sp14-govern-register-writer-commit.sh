#!/usr/bin/env bash
# SP14 T-18 Theme B — /govern register writer mode commit (Class D)
#
# Scope: commit roundtrip; writer-reference .md file written via atomic
# temp+mv; library invoked with empty {} vault_writers payload (confirms
# library wraps action-log row atomicity); action-log row kind: "writer".
#
# Per Plan 81 SP14 spec.md §7 + Batch H handoff smoke test #14.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"

TEMPROOT="$(mktemp -d -t sp14-writer-commit.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export VAULT_ROOT="$TEMPROOT/vault"
export CLAUDE_SESSION_ID="sp14-t18-writer-commit"
mkdir -p "$VAULT_ROOT/Vault Writers"
echo '{}' > "$OVERLAY_MASTER"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 writer-commit ===\n'

PROPOSAL="$TEMPROOT/proposal.json"
bash "$FOUNDATION_REPO/skills/govern/register/process.sh" propose --kind writer --writer-name granola-meetings --writer-kind connector --writer-subtype granola >"$PROPOSAL" 2>/dev/null

bash "$FOUNDATION_REPO/skills/govern/register/process.sh" commit --kind writer --proposal "$PROPOSAL" >"$TEMPROOT/stdout" 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "commit rc=0" || emit_fail "commit rc=$RC; stderr: $(cat "$TEMPROOT/stderr")"

# Writer-reference .md written
WRITER_MD="$VAULT_ROOT/Vault Writers/granola-meetings.md"
[ -f "$WRITER_MD" ] && emit_pass "writer-reference .md written at $WRITER_MD" || emit_fail "writer-reference .md missing"

# Frontmatter present
if head -1 "$WRITER_MD" | grep -q '^---$' 2>/dev/null; then
  emit_pass "writer .md has frontmatter delimiter"
else
  emit_fail "writer .md frontmatter delimiter missing"
fi

# YAML body has expected fields
if grep -q '^type: vault-writer$' "$WRITER_MD" 2>/dev/null; then
  emit_pass "writer .md frontmatter type: vault-writer"
else
  emit_fail "writer .md missing type: vault-writer"
fi

if grep -q '^writer_name: granola-meetings$' "$WRITER_MD" 2>/dev/null; then
  emit_pass "writer .md frontmatter writer_name: granola-meetings"
else
  emit_fail "writer .md missing writer_name"
fi

# Overlay: vault_writers slot with empty {} (library invoked with no-op)
if jq -e '.vault_writers == {}' "$OVERLAY_MASTER" >/dev/null 2>&1; then
  emit_pass "overlay.vault_writers == {} (no-op payload)"
else
  emit_fail "overlay.vault_writers shape mismatch: $(cat "$OVERLAY_MASTER")"
fi

# Action-log: 1 row with kind: writer
ROW_COUNT=$(wc -l < "$ACTION_LOG" | tr -d ' ')
[ "$ROW_COUNT" = "1" ] && emit_pass "action-log has 1 row" || emit_fail "row count = $ROW_COUNT"

K=$(jq -r '.kind' < <(head -1 "$ACTION_LOG"))
[ "$K" = "writer" ] && emit_pass "row.kind == writer" || emit_fail "row.kind = '$K'"

TGT=$(jq -r '.target' < <(head -1 "$ACTION_LOG"))
[ "$TGT" = "granola-meetings" ] && emit_pass "row.target == granola-meetings" || emit_fail "row.target = '$TGT'"

if python3 -c "
import json, jsonschema
schema = json.load(open('$FOUNDATION_REPO/schemas/overlay-master-schema.json'))
jsonschema.Draft202012Validator(schema).validate(json.load(open('$OVERLAY_MASTER')))
" 2>"$TEMPROOT/se"; then
  emit_pass "overlay validates against schema"
else
  emit_fail "overlay schema: $(cat "$TEMPROOT/se")"
fi

if python3 -c "
import json, jsonschema
schema = json.load(open('$FOUNDATION_REPO/schemas/governance-action-log-schema.json'))
jsonschema.Draft202012Validator(schema).validate(json.loads(open('$ACTION_LOG').read().strip()))
" 2>"$TEMPROOT/le"; then
  emit_pass "action-log row validates against schema"
else
  emit_fail "action-log schema: $(cat "$TEMPROOT/le")"
fi

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%b\n' "$FAILED_CHECKS"; exit 1; }
exit 0
