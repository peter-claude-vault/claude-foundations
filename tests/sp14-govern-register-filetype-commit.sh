#!/usr/bin/env bash
# SP14 T-18 Theme B — /govern register file-type mode commit (R-37 atomic)
#
# Scope: commit roundtrip; R-37 atomic across frontmatter.types and
# file_type_contracts.<slug>; action-log kind: "file-type".
#
# Per Plan 81 SP14 spec.md §7 + Batch H handoff smoke test #11.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"

TEMPROOT="$(mktemp -d -t sp14-filetype-commit.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export VAULT_ROOT="$TEMPROOT/vault"
export CLAUDE_SESSION_ID="sp14-t18-filetype-commit"
mkdir -p "$VAULT_ROOT"
echo '{}' > "$OVERLAY_MASTER"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 filetype-commit ===\n'

PROPOSAL="$TEMPROOT/proposal.json"
bash "$FOUNDATION_REPO/skills/govern/register/process.sh" propose --kind file-type --name engagement-note >"$PROPOSAL" 2>/dev/null

bash "$FOUNDATION_REPO/skills/govern/register/process.sh" commit --kind file-type --proposal "$PROPOSAL" >"$TEMPROOT/stdout" 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "commit rc=0" || emit_fail "commit rc=$RC; stderr: $(cat "$TEMPROOT/stderr")"

# Both pillars present (R-37 atomic). SP17a T-6 part-1 (2026-05-21):
# frontmatter.types migrated from array `[<slug>]` to object `{<slug>: <entry>}`
# matching foundation `.frontmatter.types.<slug>` shape (Surprise #2 res).
if jq -e '.frontmatter.types | has("engagement-note")' "$OVERLAY_MASTER" >/dev/null 2>&1; then
  emit_pass "overlay.frontmatter.types has key engagement-note"
else
  emit_fail "overlay missing frontmatter.types[engagement-note] entry; got: $(cat "$OVERLAY_MASTER")"
fi

if jq -e '.file_type_contracts."engagement-note".frontmatter.required | contains(["type","tags","created","updated"])' "$OVERLAY_MASTER" >/dev/null 2>&1; then
  emit_pass "overlay.file_type_contracts.engagement-note carries MV stub"
else
  emit_fail "overlay missing file_type_contracts.engagement-note; got: $(cat "$OVERLAY_MASTER")"
fi

# Action log: 2 rows (one per pillar) with kind=file-type
ROW_COUNT=$(wc -l < "$ACTION_LOG" | tr -d ' ')
[ "$ROW_COUNT" = "2" ] && emit_pass "action-log has 2 rows" || emit_fail "row count = $ROW_COUNT"

KINDS=$(jq -r '.kind' < "$ACTION_LOG" | sort -u | tr '\n' ',')
[ "$KINDS" = "file-type," ] && emit_pass "all rows kind == file-type" || emit_fail "kinds = '$KINDS'"

UNREG=$(jq -r '.unregistered' < <(head -1 "$ACTION_LOG"))
[ "$UNREG" = "false" ] && emit_pass "row.unregistered == false" || emit_fail "row.unregistered = '$UNREG'"

# Schema validation
if python3 -c "
import json, jsonschema
schema = json.load(open('$FOUNDATION_REPO/schemas/overlay-master-schema.json'))
doc = json.load(open('$OVERLAY_MASTER'))
jsonschema.Draft202012Validator(schema).validate(doc)
" 2>"$TEMPROOT/se"; then
  emit_pass "overlay validates against overlay-master-schema.json"
else
  emit_fail "overlay schema validation: $(cat "$TEMPROOT/se")"
fi

if python3 -c "
import json, jsonschema
schema = json.load(open('$FOUNDATION_REPO/schemas/governance-action-log-schema.json'))
v = jsonschema.Draft202012Validator(schema)
for line in open('$ACTION_LOG'):
    line = line.strip()
    if not line: continue
    v.validate(json.loads(line))
" 2>"$TEMPROOT/le"; then
  emit_pass "action-log rows validate against schema"
else
  emit_fail "action-log schema validation: $(cat "$TEMPROOT/le")"
fi

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%b\n' "$FAILED_CHECKS"; exit 1; }
exit 0
