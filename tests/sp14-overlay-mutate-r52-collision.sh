#!/usr/bin/env bash
# SP14 T-18 Theme B — lib/overlay-master-mutate.sh R-52 collision tiebreaker
#
# Scope: pre-populate overlay with a key under tagging.taxonomy.dimension_prefixes;
# library invocation with overlapping key in the payload — overlay-side
# WINS on key collision (deep-merge with payload-side replacement of
# the inner array via jq * operator, which is the library's R-52 semantics:
# adopter override; overlay's most-recent value persists).
#
# Per Plan 81 SP14 spec.md §7 (R-52 collision tiebreaker; overlay wins
# adopter override). bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
LIB="$FOUNDATION_REPO/lib/overlay-master-mutate.sh"
SCHEMA="$FOUNDATION_REPO/schemas/overlay-master-schema.json"

TEMPROOT="$(mktemp -d -t sp14-mutate-r52.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export SCHEMA
export CLAUDE_SESSION_ID="sp14-t18-mutate-r52"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 overlay-mutate-r52-collision ===\n'

# Pre-populate overlay with an existing key.
cat > "$OVERLAY_MASTER" <<'JSON'
{
  "tagging": {
    "taxonomy": {
      "dimension_prefixes": {
        "scope": ["foundation-existing-a", "foundation-existing-b"]
      }
    }
  }
}
JSON

# Library invocation: same key with new payload (adopter override).
P1="$TEMPROOT/p1.json"
printf '%s\n' '{"taxonomy":{"dimension_prefixes":{"scope":["adopter-override-1","adopter-override-2"]}}}' > "$P1"

bash "$LIB" \
  --pillar tagging --payload-file "$P1" \
  --kind tag-extension --target scope --proposed-by user-direct >"$TEMPROOT/stdout" 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "library rc=0" || emit_fail "rc=$RC; stderr: $(cat "$TEMPROOT/stderr")"

# Per R-52 (overlay wins on collision; deep-merge via jq *): the array at
# the leaf is REPLACED by the payload (jq * on arrays replaces). Result:
# .tagging.taxonomy.dimension_prefixes.scope == adopter values.
RESULT=$(jq -c '.tagging.taxonomy.dimension_prefixes.scope' "$OVERLAY_MASTER")
EXPECTED='["adopter-override-1","adopter-override-2"]'
if [ "$RESULT" = "$EXPECTED" ]; then
  emit_pass "R-52: adopter override REPLACED foundation-existing values at leaf"
else
  emit_fail "R-52 collision result mismatch: got '$RESULT' expected '$EXPECTED'"
fi

# Add a DIFFERENT key — confirms deep-merge preserves siblings
P2="$TEMPROOT/p2.json"
printf '%s\n' '{"taxonomy":{"dimension_prefixes":{"status":["active","retired"]}}}' > "$P2"

bash "$LIB" \
  --pillar tagging --payload-file "$P2" \
  --kind tag-extension --target status --proposed-by user-direct >"$TEMPROOT/stdout2" 2>"$TEMPROOT/stderr2"
RC2=$?
[ "$RC2" = "0" ] && emit_pass "library rc=0 (second invocation)" || emit_fail "rc=$RC2; stderr: $(cat "$TEMPROOT/stderr2")"

# Both keys present
if jq -e '.tagging.taxonomy.dimension_prefixes.scope and .tagging.taxonomy.dimension_prefixes.status' "$OVERLAY_MASTER" >/dev/null 2>&1; then
  emit_pass "deep-merge preserves sibling keys (scope + status both present)"
else
  emit_fail "deep-merge dropped sibling: $(cat "$OVERLAY_MASTER")"
fi

# Schema validation
if python3 -c "
import json, jsonschema
schema = json.load(open('$SCHEMA'))
jsonschema.Draft202012Validator(schema).validate(json.load(open('$OVERLAY_MASTER')))
" 2>"$TEMPROOT/se"; then
  emit_pass "overlay validates against schema after R-52 collision"
else
  emit_fail "schema: $(cat "$TEMPROOT/se")"
fi

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%b\n' "$FAILED_CHECKS"; exit 1; }
exit 0
