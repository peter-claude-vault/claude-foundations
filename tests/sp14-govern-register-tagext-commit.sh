#!/usr/bin/env bash
# SP14 T-18 Theme B — /govern register tag-extension commit (single pillar)
#
# Scope: commit roundtrip; single-pillar write to
# tagging.taxonomy.dimension_prefixes; action-log kind: "tag-extension".
#
# Per Plan 81 SP14 spec.md §7 + Batch H handoff smoke test #12.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"

TEMPROOT="$(mktemp -d -t sp14-tagext-commit.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export VAULT_ROOT="$TEMPROOT/vault"
export CLAUDE_SESSION_ID="sp14-t18-tagext-commit"
mkdir -p "$VAULT_ROOT"
echo '{}' > "$OVERLAY_MASTER"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 tagext-commit ===\n'

PROPOSAL="$TEMPROOT/proposal.json"
bash "$FOUNDATION_REPO/skills/govern/register/process.sh" propose --kind tag-extension --dimension delivery --values "spec,build,ship,retro" >"$PROPOSAL" 2>/dev/null

bash "$FOUNDATION_REPO/skills/govern/register/process.sh" commit --kind tag-extension --proposal "$PROPOSAL" >"$TEMPROOT/stdout" 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "commit rc=0" || emit_fail "commit rc=$RC; stderr: $(cat "$TEMPROOT/stderr")"

# Single pillar write — tagging.taxonomy.dimension_prefixes.delivery
if jq -e '.tagging.taxonomy.dimension_prefixes.delivery | contains(["spec","build","ship","retro"])' "$OVERLAY_MASTER" >/dev/null 2>&1; then
  emit_pass "overlay.tagging.taxonomy.dimension_prefixes.delivery == [spec,build,ship,retro]"
else
  emit_fail "overlay missing tagging.taxonomy entry; got: $(cat "$OVERLAY_MASTER")"
fi

# Only one row (single pillar)
ROW_COUNT=$(wc -l < "$ACTION_LOG" | tr -d ' ')
[ "$ROW_COUNT" = "1" ] && emit_pass "action-log has 1 row (single pillar)" || emit_fail "row count = $ROW_COUNT"

K=$(jq -r '.kind' < <(head -1 "$ACTION_LOG"))
[ "$K" = "tag-extension" ] && emit_pass "row.kind == tag-extension" || emit_fail "row.kind = '$K'"

if python3 -c "
import json, jsonschema
schema = json.load(open('$FOUNDATION_REPO/schemas/overlay-master-schema.json'))
jsonschema.Draft202012Validator(schema).validate(json.load(open('$OVERLAY_MASTER')))
" 2>"$TEMPROOT/se"; then
  emit_pass "overlay validates against schema"
else
  emit_fail "overlay schema validation: $(cat "$TEMPROOT/se")"
fi

if python3 -c "
import json, jsonschema
schema = json.load(open('$FOUNDATION_REPO/schemas/governance-action-log-schema.json'))
jsonschema.Draft202012Validator(schema).validate(json.loads(open('$ACTION_LOG').read().strip()))
" 2>"$TEMPROOT/le"; then
  emit_pass "action-log row validates against schema"
else
  emit_fail "action-log schema validation: $(cat "$TEMPROOT/le")"
fi

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%b\n' "$FAILED_CHECKS"; exit 1; }
exit 0
