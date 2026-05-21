#!/usr/bin/env bash
# SP17a T-9 partial — Extended unit-test scenarios for T-6 part-2 + T-8
#
# Verifies invariants from T-6 part-2 (top-level denorm slot retirement;
# pillar-nested reads only) and T-8 (librarian capability spec retargets).
# Per spec L218-L222, the suite covers:
#   - pillar-nested .frontmatter.types read after top-level retirement
#   - pillar-nested .frontmatter.r32_type_aliases read
#   - foundation-only bundle lacking top-level denorm slots loads cleanly
#   - overlay extending .frontmatter.r32_type_aliases composes via helper
#   - librarian capability specs cite the union helper as access pattern
#
# Per-leaf merge UNION/REPLACE scenarios deferred to Session 5 T-7 work.
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
echo
echo "=== SP17a T-9 partial — extended unit-test results: ${PASS} PASS, ${FAIL} FAIL ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
