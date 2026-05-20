#!/usr/bin/env bash
# SP14 T-18 Theme B — lib/overlay-master-mutate.sh atomic write
#
# Scope: single-pillar payload; library writes via tempfile-then-rename;
# final file passes jsonschema validation; action-log row appended.
#
# Per Plan 81 SP14 spec.md §7. bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
LIB="$FOUNDATION_REPO/lib/overlay-master-mutate.sh"
SCHEMA="$FOUNDATION_REPO/schemas/overlay-master-schema.json"

TEMPROOT="$(mktemp -d -t sp14-mutate-atomic.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export SCHEMA
export CLAUDE_SESSION_ID="sp14-t18-mutate-atomic"
echo '{}' > "$OVERLAY_MASTER"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 overlay-mutate-atomic-write ===\n'

# Single pillar payload — tagging extension
PAYLOAD="$TEMPROOT/p.json"
printf '%s\n' '{"taxonomy":{"dimension_prefixes":{"delivery":["spec","build"]}}}' > "$PAYLOAD"

bash "$LIB" \
  --pillar tagging \
  --payload-file "$PAYLOAD" \
  --kind tag-extension \
  --target delivery \
  --proposed-by user-direct >"$TEMPROOT/stdout" 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "library rc=0" || emit_fail "library rc=$RC; stderr: $(cat "$TEMPROOT/stderr")"

# Confirm no .tmp leftover (tempfile cleaned via mv -f)
TMPLEFT=$(find "$(dirname "$OVERLAY_MASTER")" -maxdepth 1 -name "$(basename "$OVERLAY_MASTER").tmp.*" 2>/dev/null | wc -l | tr -d ' ')
[ "$TMPLEFT" = "0" ] && emit_pass "no leftover .tmp file (atomic temp+rename cleaned up)" || emit_fail "$TMPLEFT leftover .tmp files"

# File parses as JSON
jq empty "$OVERLAY_MASTER" >/dev/null 2>&1 && emit_pass "overlay-master.json is valid JSON" || emit_fail "overlay-master.json not valid JSON"

# Payload landed
if jq -e '.tagging.taxonomy.dimension_prefixes.delivery | contains(["spec","build"])' "$OVERLAY_MASTER" >/dev/null 2>&1; then
  emit_pass "payload landed into .tagging.taxonomy.dimension_prefixes.delivery"
else
  emit_fail "payload missing; got: $(cat "$OVERLAY_MASTER")"
fi

# Schema validation
if python3 -c "
import json, jsonschema
schema = json.load(open('$SCHEMA'))
doc = json.load(open('$OVERLAY_MASTER'))
jsonschema.Draft202012Validator(schema).validate(doc)
" 2>"$TEMPROOT/se"; then
  emit_pass "overlay-master.json validates against overlay-master-schema.json"
else
  emit_fail "schema validation: $(cat "$TEMPROOT/se")"
fi

# Action-log row appended
ROW_COUNT=$(wc -l < "$ACTION_LOG" | tr -d ' ')
[ "$ROW_COUNT" = "1" ] && emit_pass "action-log has 1 row" || emit_fail "row count = $ROW_COUNT"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%b\n' "$FAILED_CHECKS"; exit 1; }
exit 0
