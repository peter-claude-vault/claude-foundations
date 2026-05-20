#!/usr/bin/env bash
# SP14 T-18 Theme B — lib/overlay-master-mutate.sh action-log row schema
#
# Scope: library appends action-log row matching
# schemas/governance-action-log-schema.json exactly — required fields
# (timestamp, kind, proposed_by, session_id) present, enum-valid kind
# (bare nouns per Session 3 A31), ISO-8601 timestamp, unregistered: false
# on success path. Confirms "Library kind enum confirmation" note from
# Batch H handoff: library accepts bare-noun kinds (despite stale help text).
#
# Per Plan 81 SP14 spec.md §7. bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
LIB="$FOUNDATION_REPO/lib/overlay-master-mutate.sh"
SCHEMA="$FOUNDATION_REPO/schemas/overlay-master-schema.json"
LOG_SCHEMA="$FOUNDATION_REPO/schemas/governance-action-log-schema.json"

TEMPROOT="$(mktemp -d -t sp14-mutate-actionlog.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export SCHEMA
export CLAUDE_SESSION_ID="sp14-t18-actionlog-row"
echo '{}' > "$OVERLAY_MASTER"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 overlay-mutate-action-log-schema ===\n'

# Single pillar; bare-noun kind (per schema enum)
PAYLOAD="$TEMPROOT/p.json"
printf '%s\n' '{"taxonomy":{"dimension_prefixes":{"status":["active"]}}}' > "$PAYLOAD"

bash "$LIB" \
  --pillar tagging --payload-file "$PAYLOAD" \
  --kind tag-extension --target status --proposed-by user-direct >"$TEMPROOT/stdout" 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "library rc=0 with bare-noun --kind tag-extension" || emit_fail "rc=$RC; stderr: $(cat "$TEMPROOT/stderr")"

ROW=$(head -1 "$ACTION_LOG")
[ -n "$ROW" ] && emit_pass "action-log has at least 1 row" || emit_fail "action-log empty"

# Required fields per schema
for field in timestamp kind proposed_by session_id; do
  VAL=$(printf '%s' "$ROW" | jq -r ".$field // empty")
  if [ -n "$VAL" ] && [ "$VAL" != "null" ]; then
    emit_pass "required field .$field present (value: $VAL)"
  else
    emit_fail "required field .$field missing"
  fi
done

# Enum validation: kind is bare noun (per schema enum)
K=$(printf '%s' "$ROW" | jq -r '.kind')
case "$K" in
  folder|file-type|tag-extension|writer)
    emit_pass ".kind is a bare-noun (schema enum): $K"
    ;;
  *)
    emit_fail ".kind not in schema enum: $K"
    ;;
esac

# ISO-8601 timestamp format check (Z-suffixed)
TS=$(printf '%s' "$ROW" | jq -r '.timestamp')
case "$TS" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
    emit_pass ".timestamp matches ISO-8601 Z-suffixed format"
    ;;
  *)
    emit_fail ".timestamp invalid format: '$TS'"
    ;;
esac

# unregistered field on success path
UNREG=$(printf '%s' "$ROW" | jq -r '.unregistered // empty')
if [ "$UNREG" = "false" ] || [ -z "$UNREG" ]; then
  # schema default is false; library writes false explicitly
  emit_pass ".unregistered == false (or absent → default false) on success path"
else
  emit_fail ".unregistered = '$UNREG' (expected false)"
fi

# proposed_by enum
PB=$(printf '%s' "$ROW" | jq -r '.proposed_by')
case "$PB" in
  claude-inline|claude-skill-invocation|user-direct|hook-class-a|hook-class-b|hook-class-c|hook-class-d|skipped)
    emit_pass ".proposed_by in schema enum: $PB"
    ;;
  *)
    emit_fail ".proposed_by not in enum: $PB"
    ;;
esac

# Schema validation (full row)
if python3 -c "
import json, jsonschema
schema = json.load(open('$LOG_SCHEMA'))
jsonschema.Draft202012Validator(schema).validate(json.loads(open('$ACTION_LOG').read().strip()))
" 2>"$TEMPROOT/se"; then
  emit_pass "row passes full jsonschema validation against governance-action-log-schema.json"
else
  emit_fail "schema validation failed: $(cat "$TEMPROOT/se")"
fi

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%b\n' "$FAILED_CHECKS"; exit 1; }
exit 0
