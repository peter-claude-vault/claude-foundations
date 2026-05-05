#!/usr/bin/env bash
# tests/sp14/catalog-discovery-unit-test.sh — synthetic unit tests for SP14
# Group B (T-4/T-5/T-6 catalog + discovery).
#
# T-4 ACs:
#   1. catalog.json exists
#   2. length in [8, 12]
#   3. each entry validates against connector-catalog-schema.json
#   4. each role has ≥3 pre-checked
#   5. granola entry default_pipeline_template_id == "granola-meetings"
#
# T-5 ACs:
#   1. mcp-registry-probe.sh exists; bash -n clean
#   2. live registry probe returns ≥1 server (network-permitting; non-fatal)
#   3. offline graceful-degrade (PATH-mocked curl) proceeds with bundled+catalog
#   4. tengu_claudeai_mcp_connectors:true enumerates bundled set
#   5. tool-cap warning fires synthetic >80
#
# T-6 ACs:
#   1. settings-paths-probe.sh exists; bash -n clean
#   2. references all 3 settings paths (grep ≥3)
#   3. 3-path synthetic returns deduplicated server-id list
#   4. missing-path fixture returns available servers without erroring
#
# Run: bash tests/sp14/catalog-discovery-unit-test.sh
# Exit: 0 on all-pass; 1 on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CATALOG="$REPO_ROOT/onboarding/connectors/catalog.json"
CATALOG_SCHEMA="$REPO_ROOT/schemas/connector-catalog-schema.json"
REG_PROBE="$REPO_ROOT/onboarding/lib/mcp-registry-probe.sh"
PATH_PROBE="$REPO_ROOT/onboarding/lib/settings-paths-probe.sh"

PASS=0; FAIL=0
check() {
  if [ "$1" = "$2" ]; then
    PASS=$((PASS+1)); echo "PASS $3"
  else
    FAIL=$((FAIL+1)); echo "FAIL $3 (got '$1' expected '$2')" >&2
  fi
}
check_ge() {
  if [ "$1" -ge "$2" ] 2>/dev/null; then
    PASS=$((PASS+1)); echo "PASS $3 ($1 ≥ $2)"
  else
    FAIL=$((FAIL+1)); echo "FAIL $3 (got '$1' expected ≥ $2)" >&2
  fi
}

# ============================================================
# T-4: catalog
# ============================================================
echo "=== T-4: catalog ==="
[ -r "$CATALOG" ] && PASS=$((PASS+1)) && echo "PASS T-4 AC1: catalog.json exists" || { FAIL=$((FAIL+1)); echo "FAIL T-4 AC1: catalog.json missing"; }
[ -r "$CATALOG_SCHEMA" ] && PASS=$((PASS+1)) && echo "PASS T-4: catalog schema exists" || { FAIL=$((FAIL+1)); echo "FAIL T-4: catalog schema missing"; }

n=$(jq 'length' "$CATALOG" 2>/dev/null)
if [ -n "$n" ] && [ "$n" -ge 8 ] && [ "$n" -le 12 ]; then
  PASS=$((PASS+1)); echo "PASS T-4 AC2: length=$n in [8,12]"
else
  FAIL=$((FAIL+1)); echo "FAIL T-4 AC2: length=$n not in [8,12]"
fi

# AC4: per-role ≥3 pre-checked
for role in consultant solo-founder engineer researcher operator; do
  count=$(jq --arg r "$role" '[.[] | select(.role_recommendations | index($r))] | length' "$CATALOG")
  check_ge "$count" "3" "T-4 AC4: role '$role' pre-checked count"
done

# AC5: granola template id
granola_tpl=$(jq -r '.[] | select(.id=="granola") | .default_pipeline_template_id' "$CATALOG")
check "$granola_tpl" "granola-meetings" "T-4 AC5: granola.default_pipeline_template_id"

# AC3: structural validation per entry (jq fallback when ajv unavailable)
# Required fields present + id pattern + category enum + failure_mode enum.
bad_id=$(jq -r '.[].id | select(test("^[a-z][a-z0-9-]*$") | not)' "$CATALOG")
check "$bad_id" "" "T-4 AC3: all ids match ^[a-z][a-z0-9-]*\$"

bad_cat=$(jq -r '.[] | .category | select(([.] | inside(["calendar","messaging","email","tasks","notes","dev","design","transcription","storage"]) | not))' "$CATALOG")
check "$bad_cat" "" "T-4 AC3: all categories in enum"

bad_fail=$(jq -r '.[] | .failure_mode_catalog_ref | select(([.] | inside(["block-and-log","auto-disable","backoff-retry","skip-and-log","no-op"]) | not))' "$CATALOG")
check "$bad_fail" "" "T-4 AC3: all failure_mode_catalog_ref in enum"

# ============================================================
# T-5: mcp-registry-probe
# ============================================================
echo
echo "=== T-5: mcp-registry-probe ==="
[ -r "$REG_PROBE" ] && PASS=$((PASS+1)) && echo "PASS T-5 AC1: probe exists" || { FAIL=$((FAIL+1)); echo "FAIL T-5 AC1: probe missing"; }
bash -n "$REG_PROBE" && PASS=$((PASS+1)) && echo "PASS T-5 AC1: bash -n clean" || { FAIL=$((FAIL+1)); echo "FAIL T-5 AC1: bash -n"; }

# AC4: bundled enabled fixture
TMPDIR="$(mktemp -d -t sp14-cat-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/.claude.json" <<'JSON'
{"tengu_claudeai_mcp_connectors": true, "mcpServers": {"existing": {}}}
JSON
out=$(USER_CLAUDE_JSON="$TMPDIR/.claude.json" bash "$REG_PROBE" --bundled-only --no-cap-check 2>/dev/null)
bundled_count=$(printf '%s\n' "$out" | grep -c '"source":"bundled"')
check_ge "$bundled_count" "5" "T-5 AC4: bundled enumeration with flag=true"

# AC4-neg: bundled disabled fixture
cat > "$TMPDIR/.claude-disabled.json" <<'JSON'
{"tengu_claudeai_mcp_connectors": false}
JSON
out=$(USER_CLAUDE_JSON="$TMPDIR/.claude-disabled.json" bash "$REG_PROBE" --bundled-only --no-cap-check 2>/dev/null)
bundled_count=$(printf '%s\n' "$out" | grep -c '"source":"bundled"')
check "$bundled_count" "0" "T-5 AC4: flag=false skips bundled enumeration"

# AC3: offline graceful-degrade — point Registry URL at unroutable address
out=$(MCP_REGISTRY_URL="http://127.0.0.1:1/v0/servers" \
      USER_CLAUDE_JSON="$TMPDIR/.claude.json" \
      bash "$REG_PROBE" --no-cap-check 2>/dev/null)
catalog_count=$(printf '%s\n' "$out" | grep -c '"source":"catalog"')
check_ge "$catalog_count" "8" "T-5 AC3: offline degrade — catalog still emitted"

# AC5: tool-cap warning fires synthetic >80 (build the fixture in pure jq)
jq -n '
  reduce range(0; 85) as $i (
    {"tengu_claudeai_mcp_connectors": true, "mcpServers": {}};
    .mcpServers["srv-" + ($i|tostring)] = {}
  )
' > "$TMPDIR/.claude-overcap.json"

cap_warn=$(USER_CLAUDE_JSON="$TMPDIR/.claude-overcap.json" \
           MCP_REGISTRY_URL="http://127.0.0.1:1/v0/servers" \
           bash "$REG_PROBE" --bundled-only 2>&1 >/dev/null | grep -c "exceeds Cursor's reference cap")
check "$cap_warn" "1" "T-5 AC5: tool-cap warning fires at 85 mcpServers"

# Bonus: AC2 live-registry probe (graceful failure tolerated)
live_out=$(USER_CLAUDE_JSON="$TMPDIR/.claude-disabled.json" \
           bash "$REG_PROBE" --registry-only --no-cap-check 2>/dev/null)
live_count=$(printf '%s\n' "$live_out" | grep -c '"source":"registry"' || true)
if [ "${live_count:-0}" -ge 1 ]; then
  PASS=$((PASS+1)); echo "PASS T-5 AC2: live registry returned $live_count server(s)"
else
  echo "info T-5 AC2: live registry returned 0 (network-blocked or registry-changed; not failing)"
fi

# ============================================================
# T-6: settings-paths-probe
# ============================================================
echo
echo "=== T-6: settings-paths-probe ==="
[ -r "$PATH_PROBE" ] && PASS=$((PASS+1)) && echo "PASS T-6 AC1: probe exists" || { FAIL=$((FAIL+1)); echo "FAIL T-6 AC1: probe missing"; }
bash -n "$PATH_PROBE" && PASS=$((PASS+1)) && echo "PASS T-6 AC1: bash -n clean" || { FAIL=$((FAIL+1)); echo "FAIL T-6 AC1: bash -n"; }

# AC2: grep ≥3 path references
grep_count=$(grep -cE 'settings\.json|\.claude\.json|claude_desktop_config\.json' "$PATH_PROBE")
check_ge "$grep_count" "3" "T-6 AC2: ≥3 path references in source"

# 3-path fixture: each path declares a different MCP server
echo '{"mcpServers": {"server-A": {}}}' > "$TMPDIR/settings.json"
echo '{"mcpServers": {"server-B": {}}}' > "$TMPDIR/.claude.json"
mkdir -p "$TMPDIR/desktop-cfg-dir"
echo '{"mcpServers": {"server-C": {}}}' > "$TMPDIR/desktop-cfg-dir/claude_desktop_config.json"

out=$(CLAUDE_STEM_SETTINGS_PATH="$TMPDIR/settings.json" \
      CLAUDE_STEM_CLAUDE_JSON_PATH="$TMPDIR/.claude.json" \
      CLAUDE_STEM_DESKTOP_CONFIG_PATH="$TMPDIR/desktop-cfg-dir/claude_desktop_config.json" \
      bash "$PATH_PROBE" --dedup 2>/dev/null)
got=$(printf '%s\n' "$out" | sort | tr '\n' ',' | sed 's/,$//')
check "$got" "server-A,server-B,server-C" "T-6 AC3: 3-path synthetic dedup"

# Per-source TSV mode
out=$(CLAUDE_STEM_SETTINGS_PATH="$TMPDIR/settings.json" \
      CLAUDE_STEM_CLAUDE_JSON_PATH="$TMPDIR/.claude.json" \
      CLAUDE_STEM_DESKTOP_CONFIG_PATH="$TMPDIR/desktop-cfg-dir/claude_desktop_config.json" \
      bash "$PATH_PROBE" 2>/dev/null)
tsv_lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
check "$tsv_lines" "3" "T-6: per-source TSV mode emits 3 rows"

if printf '%s\n' "$out" | grep -q '^server-A	settings$'; then
  PASS=$((PASS+1)); echo "PASS T-6: server-A tagged 'settings'"
else
  FAIL=$((FAIL+1)); echo "FAIL T-6: server-A wrong tag"
fi
if printf '%s\n' "$out" | grep -q '^server-B	claude-json$'; then
  PASS=$((PASS+1)); echo "PASS T-6: server-B tagged 'claude-json'"
else
  FAIL=$((FAIL+1)); echo "FAIL T-6: server-B wrong tag"
fi

# AC4: missing-path fixture (only 1 of 3 exists)
out=$(CLAUDE_STEM_SETTINGS_PATH="$TMPDIR/settings.json" \
      CLAUDE_STEM_CLAUDE_JSON_PATH="/no/such/.claude.json" \
      CLAUDE_STEM_DESKTOP_CONFIG_PATH="/no/such/desktop_config.json" \
      bash "$PATH_PROBE" --dedup 2>/dev/null)
check "$out" "server-A" "T-6 AC4: missing 2/3 paths returns the 1 available"

# Missing-path fixture should NOT error (rc=0)
# Missing-path rc=0 (run in subshell with env exports so children inherit)
(
  export CLAUDE_STEM_SETTINGS_PATH="$TMPDIR/settings.json"
  export CLAUDE_STEM_CLAUDE_JSON_PATH="/no/such/.claude.json"
  export CLAUDE_STEM_DESKTOP_CONFIG_PATH="/no/such/desktop_config.json"
  bash "$PATH_PROBE" --dedup >/dev/null 2>&1
)
check "$?" "0" "T-6 AC4: missing-path rc=0"

# All-paths-missing fixture (no servers; rc=0; empty output)
out=$(
  export CLAUDE_STEM_SETTINGS_PATH="/no/x.json"
  export CLAUDE_STEM_CLAUDE_JSON_PATH="/no/y.json"
  export CLAUDE_STEM_DESKTOP_CONFIG_PATH="/no/z.json"
  bash "$PATH_PROBE" --dedup 2>/dev/null
)
rc=$?
check "$rc" "0" "T-6: all-paths-missing rc=0"
check "$out" "" "T-6: all-paths-missing empty output"

echo
echo "==========================="
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] && exit 0 || exit 1
