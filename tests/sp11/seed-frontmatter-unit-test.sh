#!/bin/bash
# SP11 T-3 _write_seed frontmatter contract test (CFF-SP12-S2-1 amendment).
#
# Pre-amendment contract: 4 frontmatter fields (R-45: name, description, type,
# last_verified). Post-amendment contract: 7 frontmatter fields — provenance
# (generated_by, generated_from, last_user_edit) emitted FIRST, then R-45.
#
# Why: SP12 T-5's mirror collision contract scans seeds for `generated_by:
# sp11-t3` to route through the UPGRADE path instead of the ABORT path. Seeds
# without provenance trigger ABORT in production where SP11 ran first.
#
# Both schemas (provenance + R-45) declare additionalProperties:true so the
# combined block is valid against both.
#
# Bash 3.2 clean (R-23). No live ~/.claude/ writes (R-55).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/onboarding/bootstrap-schemas.sh"

PASS=0
FAIL=0
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }

# Extract _write_seed function body via awk: from `_write_seed() {` through
# matching `}` at column 4 (function body indent).
extract_write_seed() {
    awk '
        /^    _write_seed\(\) \{/ { in_fn = 1 }
        in_fn { print }
        in_fn && /^    \}$/ { in_fn = 0 }
    ' "$SCRIPT"
}

WS_BODY="$(extract_write_seed)"
if [ -z "$WS_BODY" ]; then
    fail "could not extract _write_seed function body"
    echo "TOTAL: $PASS PASS, $FAIL FAIL"
    exit 1
fi
pass "extracted _write_seed body"

# Build a test harness that sources just _write_seed + minimal env.
TMP="$(mktemp -d -t sp11-seed-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/harness.sh" <<HARNESS
#!/bin/bash
set -euo pipefail
mem_dir="$TMP/memory"
mkdir -p "\$mem_dir"
seeds_count=0
r45_advisories=0
advisory_log="\$mem_dir/.r45-advisories.log"
now_iso="2026-05-03T12:00:00Z"
now_date="2026-05-03"
audit_event() { :; }

# Inject extracted _write_seed (de-indent by 4 spaces so it parses at top level)
$(printf '%s\n' "$WS_BODY" | sed 's/^    //')

# Exercise it: write a user-typed seed
_write_seed "\$mem_dir/user_test.md" "test seed" "test description" "user" "Body content."
echo "seeds_count=\$seeds_count"
HARNESS

bash "$TMP/harness.sh" >/dev/null 2>&1 || {
    fail "harness execution failed"
    bash "$TMP/harness.sh" 2>&1 | sed 's/^/    /'
    echo "TOTAL: $PASS PASS, $FAIL FAIL"
    exit 1
}
pass "harness executed _write_seed without error"

SEED="$TMP/memory/user_test.md"
[ -f "$SEED" ] || { fail "seed file not created at $SEED"; echo "TOTAL: $PASS PASS, $FAIL FAIL"; exit 1; }
pass "seed file created"

# --- Frontmatter shape assertions ---

# 1. Provenance fields present
for fld in generated_by generated_from last_user_edit; do
    if grep -q "^${fld}: " "$SEED"; then
        pass "frontmatter contains '$fld:'"
    else
        fail "frontmatter missing '$fld:'"
    fi
done

# 2. R-45 fields still present
for fld in name description type last_verified; do
    if grep -q "^${fld}: " "$SEED"; then
        pass "frontmatter contains '$fld:'"
    else
        fail "frontmatter missing '$fld:'"
    fi
done

# 3. Provenance fields appear BEFORE R-45 fields
gen_by_line=$(grep -n '^generated_by: ' "$SEED" | head -1 | cut -d: -f1)
name_line=$(grep -n '^name: ' "$SEED" | head -1 | cut -d: -f1)
if [ -n "$gen_by_line" ] && [ -n "$name_line" ] && [ "$gen_by_line" -lt "$name_line" ]; then
    pass "provenance fields ordered before R-45 fields (line $gen_by_line < $name_line)"
else
    fail "provenance fields NOT before R-45 fields (gen_by=$gen_by_line name=$name_line)"
fi

# 4. generated_by value matches sp11-t3
val="$(grep '^generated_by: ' "$SEED" | head -1 | sed 's/^generated_by: //')"
if [ "$val" = "sp11-t3" ]; then
    pass "generated_by == sp11-t3"
else
    fail "generated_by mismatch: got '$val' expected 'sp11-t3'"
fi

# 5. last_user_edit == null
val="$(grep '^last_user_edit: ' "$SEED" | head -1 | sed 's/^last_user_edit: //')"
if [ "$val" = "null" ]; then
    pass "last_user_edit == null (initial-write contract)"
else
    fail "last_user_edit mismatch: got '$val' expected 'null'"
fi

# 6. Total frontmatter field count >= 7
fm_count=$(awk '/^---$/{c++; next} c==1 && /^[a-zA-Z_][a-zA-Z0-9_]*: /{n++} END{print n+0}' "$SEED")
if [ "$fm_count" -ge 7 ]; then
    pass "frontmatter field count >= 7 (got $fm_count)"
else
    fail "frontmatter field count < 7 (got $fm_count)"
fi

echo
echo "=== TOTAL: $PASS PASS, $FAIL FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL CHECKS PASS"
