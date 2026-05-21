#!/usr/bin/env bash
# SP17a T-9 — Extended unit-test scenarios for T-6 part-2 + T-7 + T-8
#
# Verifies invariants from:
#   - T-6 part-2 (top-level denorm slot retirement; pillar-nested reads only)
#   - T-7 (per-leaf merge-strategy registry; UNION at list-typed leaves)
#   - T-8 (librarian capability spec retargets to union helper)
#
# Per spec L218-L222, the suite covers:
#   - pillar-nested .frontmatter.types read after top-level retirement
#   - pillar-nested .frontmatter.r32_type_aliases read
#   - foundation-only bundle lacking top-level denorm slots loads cleanly
#   - overlay extending .frontmatter.r32_type_aliases composes via helper
#   - librarian capability specs cite the union helper as access pattern
#   - per-leaf UNION at dimension_prefixes / user_facing_dimensions /
#     registered_archetypes; REPLACE elsewhere; dict-shape fallback preserves
#     SP14 baseline merge semantics
#
# Scope: bash 3.2 compatible; mktemp-jailed fixtures; zero ~/.claude/ writes.

set -u

# Resolve repo from script location so tests bind to THIS worktree, not the
# live ~/Code/claude-stem (matches T-5 sp17a-r52-write-time-deny-test.sh).
_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FOUNDATION_REPO="${FOUNDATION_REPO:-$(cd "$_TEST_DIR/../.." && pwd)}"
HELPER="$FOUNDATION_REPO/lib/foundation-overlay-load.sh"
BUNDLE="$FOUNDATION_REPO/governance/foundation-master.json"
CAP_DIR="$FOUNDATION_REPO/governance/librarian-capabilities"

[ -x "$HELPER" ] || { printf 'FATAL: helper not executable: %s\n' "$HELPER" >&2; exit 2; }
[ -f "$BUNDLE" ] || { printf 'FATAL: bundle not present: %s\n' "$BUNDLE" >&2; exit 2; }

TEMPROOT="$(mktemp -d -t sp17a-extended.XXXXXX)" || exit 2
trap 'rm -rf "$TEMPROOT"' EXIT

PASS=0
FAIL=0
say_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
say_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

# =============================================================================
# (1) Bundle shape post-T-6 part-2: top-level denorm slots ABSENT;
# pillar-nested form PRESENT.
# =============================================================================
echo "--- (1) Bundle shape — top-level denorm slots retired ---"

if jq -e 'has("types") | not' "$BUNDLE" >/dev/null 2>&1; then
  say_pass "(1a) Bundle has NO top-level .types (denorm slot retired)"
else
  say_fail "(1a) Bundle still has top-level .types"
fi

if jq -e 'has("r32_type_aliases") | not' "$BUNDLE" >/dev/null 2>&1; then
  say_pass "(1b) Bundle has NO top-level .r32_type_aliases (denorm slot retired)"
else
  say_fail "(1b) Bundle still has top-level .r32_type_aliases"
fi

if jq -e '.frontmatter.types | type == "object" and (keys | length > 0)' "$BUNDLE" >/dev/null 2>&1; then
  say_pass "(1c) Bundle has pillar-nested .frontmatter.types (canonical)"
else
  say_fail "(1c) Bundle missing pillar-nested .frontmatter.types"
fi

if jq -e '.frontmatter.r32_type_aliases | type == "object" and (keys | length > 0)' "$BUNDLE" >/dev/null 2>&1; then
  say_pass "(1d) Bundle has pillar-nested .frontmatter.r32_type_aliases (relocated)"
else
  say_fail "(1d) Bundle missing pillar-nested .frontmatter.r32_type_aliases"
fi

# =============================================================================
# (2) Union helper exposes pillar-nested form unchanged from foundation-only
# read when no overlay extends r32_type_aliases.
# =============================================================================
echo "--- (2) Union helper preserves pillar-nested form ---"

FIX_GOV2="$TEMPROOT/foundation-only"
mkdir -p "$FIX_GOV2"
cp "$BUNDLE" "$FIX_GOV2/foundation-master.json"
# Empty overlay (no slots) — union view should equal foundation view.
printf '{}\n' > "$FIX_GOV2/overlay-master.json"

UNION_JSON=$("$HELPER" \
  --foundation-path "$FIX_GOV2/foundation-master.json" \
  --overlay-path "$FIX_GOV2/overlay-master.json" \
  --force-override 2>/dev/null)

if [ -n "$UNION_JSON" ] && jq -e '.frontmatter.types | keys | length > 0' <<<"$UNION_JSON" >/dev/null 2>&1; then
  say_pass "(2a) Union view exposes .frontmatter.types under no-overlay scenario"
else
  say_fail "(2a) Union view missing .frontmatter.types under no-overlay scenario"
fi

if jq -e '.frontmatter.r32_type_aliases."file-index" == "index"' <<<"$UNION_JSON" >/dev/null 2>&1; then
  say_pass "(2b) Union view exposes .frontmatter.r32_type_aliases entries"
else
  say_fail "(2b) Union view missing .frontmatter.r32_type_aliases entries"
fi

# =============================================================================
# (3) Overlay extending .frontmatter.r32_type_aliases composes into union view.
# =============================================================================
echo "--- (3) Overlay-extended .frontmatter.r32_type_aliases composes via helper ---"

FIX_GOV3="$TEMPROOT/overlay-aliases"
mkdir -p "$FIX_GOV3"
cp "$BUNDLE" "$FIX_GOV3/foundation-master.json"
cat > "$FIX_GOV3/overlay-master.json" <<'JSON'
{
  "frontmatter": {
    "r32_type_aliases": {
      "client-brief-alias": "client-brief"
    }
  }
}
JSON

UNION_JSON3=$("$HELPER" \
  --foundation-path "$FIX_GOV3/foundation-master.json" \
  --overlay-path "$FIX_GOV3/overlay-master.json" \
  --force-override 2>/dev/null)

if jq -e '.frontmatter.r32_type_aliases."file-index" == "index"' <<<"$UNION_JSON3" >/dev/null 2>&1; then
  say_pass "(3a) Foundation alias 'file-index' preserved in union view"
else
  say_fail "(3a) Foundation alias 'file-index' lost in union view"
fi

if jq -e '.frontmatter.r32_type_aliases."client-brief-alias" == "client-brief"' <<<"$UNION_JSON3" >/dev/null 2>&1; then
  say_pass "(3b) Overlay alias 'client-brief-alias' merged into union view"
else
  say_fail "(3b) Overlay alias 'client-brief-alias' missing from union view"
fi

# =============================================================================
# (4) R-52 collision detection still walks .frontmatter sections (post-T-6
# part-2 the helper's per-pillar walk uses pillar-nested paths exclusively).
# Overlay shadowing a foundation type without _override_reason → helper rc=1.
# =============================================================================
echo "--- (4) R-52 walk still fires on .frontmatter.types collision ---"

FIX_GOV4="$TEMPROOT/r52-collision"
mkdir -p "$FIX_GOV4"
cp "$BUNDLE" "$FIX_GOV4/foundation-master.json"
# Overlay shadows existing foundation type "people" without _override_reason.
cat > "$FIX_GOV4/overlay-master.json" <<'JSON'
{
  "frontmatter": {
    "types": {
      "people": {
        "required": ["name", "overridden_field"]
      }
    }
  }
}
JSON

"$HELPER" \
  --foundation-path "$FIX_GOV4/foundation-master.json" \
  --overlay-path "$FIX_GOV4/overlay-master.json" \
  >/dev/null 2>"$TEMPROOT/r52-stderr.log"
RC4=$?

if [ "$RC4" -eq 1 ] && grep -q "R-52" "$TEMPROOT/r52-stderr.log"; then
  say_pass "(4) Helper DENIES shadowing of .frontmatter.types entry without _override_reason"
else
  say_fail "(4) Helper did not DENY collision; rc=$RC4 (expected 1)"
fi

# =============================================================================
# (5) Librarian capability specs cite the union helper as access pattern (T-8
# retarget validation; documentation-layer smoke test).
# =============================================================================
echo "--- (5) Librarian capability specs cite union helper (T-8) ---"

if [ -f "$CAP_DIR/governance-parity-audit.md" ] && \
   grep -q "lib/foundation-overlay-load.sh" "$CAP_DIR/governance-parity-audit.md"; then
  say_pass "(5a) governance-parity-audit.md cites lib/foundation-overlay-load.sh"
else
  say_fail "(5a) governance-parity-audit.md missing lib/foundation-overlay-load.sh reference"
fi

if [ -f "$CAP_DIR/packet-staleness-audit.md" ] && \
   grep -q "lib/foundation-overlay-load.sh" "$CAP_DIR/packet-staleness-audit.md"; then
  say_pass "(5b) packet-staleness-audit.md cites lib/foundation-overlay-load.sh"
else
  say_fail "(5b) packet-staleness-audit.md missing lib/foundation-overlay-load.sh reference"
fi

if [ -f "$CAP_DIR/packet-staleness-audit.md" ] && \
   grep -q '\.frontmatter\.types\.packet' "$CAP_DIR/packet-staleness-audit.md"; then
  say_pass "(5c) packet-staleness-audit.md cites .frontmatter.types.packet pillar-nested path"
else
  say_fail "(5c) packet-staleness-audit.md missing pillar-nested path reference"
fi

# =============================================================================
# (6) Per-leaf merge strategy (T-7): registry file present + declares the
# three list-typed leaves as UNION.
# =============================================================================
echo "--- (6) Merge-strategy registry (T-7) declares UNION leaves ---"

REGISTRY="$FOUNDATION_REPO/lib/merge-strategy-registry.json"

if [ -f "$REGISTRY" ]; then
  say_pass "(6a) lib/merge-strategy-registry.json present"
else
  say_fail "(6a) lib/merge-strategy-registry.json missing"
fi

if jq -e '.strategies."tagging.taxonomy.dimension_prefixes" == "union"' "$REGISTRY" >/dev/null 2>&1; then
  say_pass "(6b) registry declares dimension_prefixes as UNION"
else
  say_fail "(6b) registry missing UNION declaration for dimension_prefixes"
fi

if jq -e '.strategies."tagging.taxonomy.user_facing_dimensions" == "union"' "$REGISTRY" >/dev/null 2>&1; then
  say_pass "(6c) registry declares user_facing_dimensions as UNION"
else
  say_fail "(6c) registry missing UNION declaration for user_facing_dimensions"
fi

if jq -e '.strategies."tagging.taxonomy.registered_archetypes" == "union"' "$REGISTRY" >/dev/null 2>&1; then
  say_pass "(6d) registry declares registered_archetypes as UNION"
else
  say_fail "(6d) registry missing UNION declaration for registered_archetypes"
fi

if jq -e '.default == "replace"' "$REGISTRY" >/dev/null 2>&1; then
  say_pass "(6e) registry default strategy is REPLACE"
else
  say_fail "(6e) registry default strategy not REPLACE"
fi

# =============================================================================
# (7) Library UNION semantics at array-shape dimension_prefixes (T-7 AC-6
# verification): foundation [scope,status]; overlay payload [client] →
# overlay state [client,scope,status] (deduped + sorted).
# =============================================================================
echo "--- (7) Library UNION at array-shape dimension_prefixes ---"

LIB="$FOUNDATION_REPO/lib/overlay-master-mutate.sh"
SCHEMA_PATH="$FOUNDATION_REPO/schemas/overlay-master-schema.json"

FIX7="$TEMPROOT/t7-union"
mkdir -p "$FIX7"
OVERLAY7="$FIX7/overlay-master.json"
LOG7="$FIX7/action-log.jsonl"
PAYLOAD7="$FIX7/payload.json"

# Seed overlay with existing array-shape entries (foundation-style).
cat > "$OVERLAY7" <<'JSON'
{
  "tagging": {
    "taxonomy": {
      "dimension_prefixes": ["scope", "status"]
    }
  }
}
JSON
: > "$LOG7"
# Adopter adds "client" dimension via array-shape payload.
echo '{"taxonomy":{"dimension_prefixes":["client"]}}' > "$PAYLOAD7"

OVERLAY_MASTER="$OVERLAY7" \
ACTION_LOG="$LOG7" \
SCHEMA="$SCHEMA_PATH" \
CLAUDE_SESSION_ID="sp17a-t9-t7-union" \
  bash "$LIB" --pillar tagging --payload-file "$PAYLOAD7" \
              --kind tag-extension --target client --proposed-by user-direct \
  >/dev/null 2>"$FIX7/err.log"
RC7=$?

if [ "$RC7" -eq 0 ]; then
  say_pass "(7a) Library rc=0 on array+array UNION merge"
else
  say_fail "(7a) Library rc=$RC7 on array+array UNION; stderr: $(cat "$FIX7/err.log")"
fi

EXPECTED7='["client","scope","status"]'
ACTUAL7=$(jq -c '.tagging.taxonomy.dimension_prefixes' "$OVERLAY7" 2>/dev/null)
if [ "$ACTUAL7" = "$EXPECTED7" ]; then
  say_pass "(7b) UNION + dedup + sort: ${EXPECTED7}"
else
  say_fail "(7b) Expected ${EXPECTED7}; got ${ACTUAL7}"
fi

# =============================================================================
# (8) Library UNION dedup at overlapping entries: foundation [scope,status];
# overlay payload [status,client] → [client,scope,status] (overlap deduped).
# =============================================================================
echo "--- (8) Library UNION dedups overlapping entries ---"

FIX8="$TEMPROOT/t7-dedup"
mkdir -p "$FIX8"
OVERLAY8="$FIX8/overlay-master.json"
LOG8="$FIX8/action-log.jsonl"
PAYLOAD8="$FIX8/payload.json"

cat > "$OVERLAY8" <<'JSON'
{
  "tagging": {
    "taxonomy": {
      "dimension_prefixes": ["scope", "status"]
    }
  }
}
JSON
: > "$LOG8"
echo '{"taxonomy":{"dimension_prefixes":["status","client"]}}' > "$PAYLOAD8"

OVERLAY_MASTER="$OVERLAY8" \
ACTION_LOG="$LOG8" \
SCHEMA="$SCHEMA_PATH" \
CLAUDE_SESSION_ID="sp17a-t9-t7-dedup" \
  bash "$LIB" --pillar tagging --payload-file "$PAYLOAD8" \
              --kind tag-extension --target client --proposed-by user-direct \
  >/dev/null 2>"$FIX8/err.log"
RC8=$?

EXPECTED8='["client","scope","status"]'
ACTUAL8=$(jq -c '.tagging.taxonomy.dimension_prefixes' "$OVERLAY8" 2>/dev/null)
if [ "$RC8" -eq 0 ] && [ "$ACTUAL8" = "$EXPECTED8" ]; then
  say_pass "(8) UNION dedup at overlap: ${EXPECTED8}"
else
  say_fail "(8) Expected rc=0 + ${EXPECTED8}; got rc=$RC8 + ${ACTUAL8}"
fi

# =============================================================================
# (9) Library REPLACE semantics at non-declared leaf (regression-test the
# default jq * deep-merge path; ensure T-7 didn't break sibling slots).
# Use `tagging.taxonomy.tag_pattern_regex` (scalar leaf, not in registry).
# =============================================================================
echo "--- (9) Library REPLACE (default) at non-declared scalar leaf ---"

FIX9="$TEMPROOT/t7-replace"
mkdir -p "$FIX9"
OVERLAY9="$FIX9/overlay-master.json"
LOG9="$FIX9/action-log.jsonl"
PAYLOAD9="$FIX9/payload.json"

cat > "$OVERLAY9" <<'JSON'
{
  "tagging": {
    "taxonomy": {
      "tag_pattern_regex": "^#[a-z]+/[a-z]+$"
    }
  }
}
JSON
: > "$LOG9"
echo '{"taxonomy":{"tag_pattern_regex":"^#[a-z0-9-]+/[a-z0-9-]+$"}}' > "$PAYLOAD9"

OVERLAY_MASTER="$OVERLAY9" \
ACTION_LOG="$LOG9" \
SCHEMA="$SCHEMA_PATH" \
CLAUDE_SESSION_ID="sp17a-t9-t7-replace" \
  bash "$LIB" --pillar tagging --payload-file "$PAYLOAD9" \
              --kind tag-extension --target tag_pattern_regex --proposed-by user-direct \
  >/dev/null 2>"$FIX9/err.log"
RC9=$?

ACTUAL9=$(jq -r '.tagging.taxonomy.tag_pattern_regex' "$OVERLAY9" 2>/dev/null)
EXPECTED9='^#[a-z0-9-]+/[a-z0-9-]+$'
if [ "$RC9" -eq 0 ] && [ "$ACTUAL9" = "$EXPECTED9" ]; then
  say_pass "(9) REPLACE at non-declared scalar leaf: payload wins"
else
  say_fail "(9) Expected rc=0 + payload-wins; got rc=$RC9 + actual=${ACTUAL9}"
fi

# =============================================================================
# (10) Dict-shape fallback (SP14 baseline preservation): if BOTH existing
# and payload are objects at a declared UNION leaf, library falls through to
# object recursive merge (no array coercion). Verifies SP14 tag-extension
# tests still PASS unchanged.
# =============================================================================
echo "--- (10) Dict-shape fallback at declared UNION leaf ---"

FIX10="$TEMPROOT/t7-dict-fallback"
mkdir -p "$FIX10"
OVERLAY10="$FIX10/overlay-master.json"
LOG10="$FIX10/action-log.jsonl"
PAYLOAD10="$FIX10/payload.json"

# Existing dict-shape overlay (legacy /govern register tag-extension emit shape).
cat > "$OVERLAY10" <<'JSON'
{
  "tagging": {
    "taxonomy": {
      "dimension_prefixes": {
        "scope": ["client-a", "client-b"]
      }
    }
  }
}
JSON
: > "$LOG10"
# Payload also dict-shape adds sibling entry.
echo '{"taxonomy":{"dimension_prefixes":{"delivery":["spec","build"]}}}' > "$PAYLOAD10"

OVERLAY_MASTER="$OVERLAY10" \
ACTION_LOG="$LOG10" \
SCHEMA="$SCHEMA_PATH" \
CLAUDE_SESSION_ID="sp17a-t9-t7-dict" \
  bash "$LIB" --pillar tagging --payload-file "$PAYLOAD10" \
              --kind tag-extension --target delivery --proposed-by user-direct \
  >/dev/null 2>"$FIX10/err.log"
RC10=$?

# Expectation: object recursive merge — both "scope" and "delivery" keys present.
if [ "$RC10" -eq 0 ] && \
   jq -e '.tagging.taxonomy.dimension_prefixes | has("scope") and has("delivery")' "$OVERLAY10" >/dev/null 2>&1; then
  say_pass "(10) Dict-shape fallback preserves both keys (SP14 baseline)"
else
  say_fail "(10) Dict-shape fallback failed; rc=$RC10; overlay: $(cat "$OVERLAY10")"
fi

# =============================================================================
echo
echo "=== SP17a T-9 — extended unit-test results: ${PASS} PASS, ${FAIL} FAIL ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
