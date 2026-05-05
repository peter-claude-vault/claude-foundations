#!/bin/bash
# SP12 T-13 (G3) — manifest-driven context_pressure thresholds in
# hooks/prompt-context.sh.
#
# Verifies WARN_PCT / MANDATE_PCT / HARD_PCT load correctly across 3 manifest
# states: (1) custom values set, (2) fields null, (3) fields missing.
#
# Strategy: extract the manifest-load block from prompt-context.sh, source it
# in an isolated subshell with each fixture, assert resolved values.
#
# Bash 3.2 clean (R-23). No live ~/.claude/ writes (R-55).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$ROOT/hooks/prompt-context.sh"

PASS=0
FAIL=0
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }

# Probe: write a tiny harness script that sources the extracted manifest-load
# block under a synthetic CLAUDE_HOME, then invoke it. Avoids quoting hell of
# nested bash -c.
probe_thresholds() {
    local fixture_dir="$1"
    local block="$TMP/block.sh"
    awk '/--- SP12 T-13 \(G3\)/,/^fi$/' "$TARGET" > "$block"
    local harness="$TMP/harness.sh"
    cat > "$harness" <<HARNESS
#!/bin/bash
export CLAUDE_HOME="$fixture_dir"
source "$block"
printf '%s|%s|%s\n' "\$WARN_PCT" "\$MANDATE_PCT" "\$HARD_PCT"
HARNESS
    bash "$harness"
}

TMP="$(mktemp -d -t context-pressure-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# === State 1: custom thresholds set ===
mkdir -p "$TMP/state1"
cat > "$TMP/state1/user-manifest.json" <<'JSON'
{"hooks":{"context_pressure":{"warn_pct":30,"mandate_pct":40,"hard_pct":70}}}
JSON
got=$(probe_thresholds "$TMP/state1")
if [ "$got" = "30|40|70" ]; then
    pass "State 1 (custom 30/40/70): resolved correctly"
else
    fail "State 1 (custom 30/40/70): expected '30|40|70', got '$got'"
fi

# === State 2: fields null ===
mkdir -p "$TMP/state2"
cat > "$TMP/state2/user-manifest.json" <<'JSON'
{"hooks":{"context_pressure":{"warn_pct":null,"mandate_pct":null,"hard_pct":null}}}
JSON
got=$(probe_thresholds "$TMP/state2")
if [ "$got" = "45|48|80" ]; then
    pass "State 2 (fields null): falls back to defaults 45/48/80"
else
    fail "State 2 (fields null): expected '45|48|80', got '$got'"
fi

# === State 3: fields missing ===
mkdir -p "$TMP/state3"
cat > "$TMP/state3/user-manifest.json" <<'JSON'
{"identity":{"name":"u"}}
JSON
got=$(probe_thresholds "$TMP/state3")
if [ "$got" = "45|48|80" ]; then
    pass "State 3 (fields missing): falls back to defaults 45/48/80"
else
    fail "State 3 (fields missing): expected '45|48|80', got '$got'"
fi

# === State 4: manifest entirely absent ===
mkdir -p "$TMP/state4"
got=$(probe_thresholds "$TMP/state4")
if [ "$got" = "45|48|80" ]; then
    pass "State 4 (manifest absent): falls back to defaults 45/48/80"
else
    fail "State 4 (manifest absent): expected '45|48|80', got '$got'"
fi

# === AC#1: grep returns >=3 hits ===
hits=$(grep -cE "context_pressure" "$TARGET" || true)
if [ "$hits" -ge 3 ]; then
    pass "AC#1: grep returns $hits hits for 'context_pressure' (>=3 required)"
else
    fail "AC#1: only $hits 'context_pressure' hits (expected >=3)"
fi

# === AC#2: 45/48 only inside fallback-default branches ===
# Allowed contexts: comment lines (#), initial defaults (WARN_PCT=45 / MANDATE_PCT=48),
# fallback in _ctxp_read invocations (... '.warn_pct' 45). NOT allowed: bare 45/48
# in conditional expressions like `if (( pct_int >= 48 ))`.
bad=$(grep -nE "\b45\b|\b48\b" "$TARGET" | grep -vE "^[0-9]+:#|^[0-9]+:WARN_PCT=45|^[0-9]+:MANDATE_PCT=48|_ctxp_read.*'\\s+(45|48)\\s*\\)|warn_pct'\\s+45|mandate_pct'\\s+48" || true)
if [ -z "$bad" ]; then
    pass "AC#2: no 45/48 outside fallback-default branches"
else
    fail "AC#2: 45/48 found outside fallback-default branches:"
    printf '%s\n' "$bad" | sed 's/^/      /'
fi

echo
echo "=== TOTAL: $PASS PASS, $FAIL FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL CHECKS PASS"
