#!/bin/bash
# audit-test.sh — T-10 acceptance fixture (Plan 80/81 SP01).
#
# Validates l3-registry-audit.sh behavior against synthetic plists, hook
# scripts, registry, and plan manifests. Tests:
#   1. summary on missing registry: exists=false
#   2. summary on present registry: writer counts derived
#   3. walk surfaces unregistered launchd labels (drift)
#   4. walk surfaces missing labels (in registry, absent from disk)
#   5. lint flags Incident-β-class: writer write_paths overlap plan scope_paths,
#      writer not declared in layer_3
#   6. lint clean when writer is declared in layer_3.launchd_labels
#   7. lint clean when writer's write_paths covered by exempt_paths
#   8. lint clean when plan's live_mutation_scope.enabled = false (skipped)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$REPO_ROOT/skills/librarian/capabilities/l3-registry-audit.sh"
[[ -x "$H" ]] || { echo "FAIL: $H not executable"; exit 1; }

TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

PASS_COUNT=0
FAIL_COUNT=0

assert() {
  if [[ "$1" == "$2" ]]; then
    echo "  PASS: $3"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: $3 (expected '$2', got '$1')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# Synthetic plists root + hooks dir + registry
PLISTS="$TEST_DIR/LaunchAgents"
HOOKS="$TEST_DIR/hooks"
REGISTRY="$TEST_DIR/l3-writer-registry.json"
PLANS="$TEST_DIR/.claude-plans"
mkdir -p "$PLISTS" "$HOOKS" "$PLANS"

# Two on-disk plists
touch "$PLISTS/com.foo-cron.plist" "$PLISTS/com.bar-cron.plist"
# Two on-disk hooks
echo "#!/bin/bash" > "$HOOKS/foo-end.sh"
echo "#!/bin/bash" > "$HOOKS/baz-end.sh"

# Registry has com.foo-cron AND com.missing-cron (missing from disk),
# foo-end.sh AND missing-end.sh (missing from disk).
cat > "$REGISTRY" <<EOF
{
  "schema_version": 1,
  "regenerated_at": "2026-05-08T00:00:00Z",
  "writers": [
    {
      "id": "com.foo-cron",
      "trigger": "launchd cron",
      "launchd_label": "com.foo-cron",
      "plist_path": "$PLISTS/com.foo-cron.plist",
      "write_paths": ["\$HOME/.local/state/foo/**"],
      "pause_mechanism": "launchctl"
    },
    {
      "id": "com.missing-cron",
      "trigger": "launchd cron",
      "launchd_label": "com.missing-cron",
      "plist_path": "$PLISTS/com.missing-cron.plist",
      "write_paths": ["\$HOME/.local/state/missing/**"],
      "pause_mechanism": "launchctl"
    },
    {
      "id": "foo-end.sh",
      "trigger": "SessionEnd hook",
      "hook_path": "$HOOKS/foo-end.sh",
      "write_paths": ["\$HOME/.local/share/foo-data/**"],
      "pause_mechanism": "sentinel",
      "sentinel_path": "\$HOOKS_STATE/foo-end.lock"
    },
    {
      "id": "missing-end.sh",
      "trigger": "SessionEnd hook",
      "hook_path": "$HOOKS/missing-end.sh",
      "write_paths": ["\$HOME/.local/share/missing-data/**"],
      "pause_mechanism": "sentinel"
    }
  ]
}
EOF

run() {
  L3_REGISTRY_PATH="$REGISTRY" \
  PLISTS_ROOT_OVERRIDE="$PLISTS" \
  HOOKS_DIR_OVERRIDE="$HOOKS" \
  PLANS_ROOT_OVERRIDE="$PLANS" \
  bash "$H" "$@"
}

# === Test 1: summary on missing registry ==================================
echo "Test 1: summary on missing registry → exists=false"
out=$(L3_REGISTRY_PATH="$TEST_DIR/missing.json" bash "$H" summary)
assert "$(echo "$out" | jq -r '.exists')" "false" "T1 exists=false"

# === Test 2: summary on present registry ==================================
echo ""
echo "Test 2: summary on present registry → counts derived"
out=$(run summary)
assert "$(echo "$out" | jq -r '.exists')" "true" "T2 exists=true"
assert "$(echo "$out" | jq -r '.writer_counts.total')" "4" "T2 4 writers"

# === Test 3: walk surfaces unregistered labels ============================
echo ""
echo "Test 3: walk surfaces unregistered labels (com.bar-cron on disk only)"
out=$(run walk)
unreg=$(echo "$out" | jq -c '.drift.unregistered_labels')
assert "$unreg" '["com.bar-cron"]' "T3 drift.unregistered_labels=[com.bar-cron]"

# === Test 4: walk surfaces missing labels ================================
echo ""
echo "Test 4: walk surfaces missing labels (com.missing-cron registered, absent from disk)"
out=$(run walk)
missing=$(echo "$out" | jq -c '.drift.missing_labels_in_registry_only')
assert "$missing" '["com.missing-cron"]' "T4 drift.missing_labels=[com.missing-cron]"

# === Test 5: lint flags Incident-β-class omission =========================
echo ""
echo "Test 5: lint flags Incident-β-class omission"
mkdir -p "$PLANS/plan-leaky"
# Plan claims scope $HOME/.local/** but doesn't declare com.foo-cron pause
# and doesn't exempt $HOME/.local/state/foo/. com.foo-cron's write_paths
# overlap → must be declared or exempt'd.
cat > "$PLANS/plan-leaky/manifest.json" <<EOF
{
  "schema_version": 1,
  "live_mutation_scope": {
    "enabled": true,
    "scope_paths": ["\$HOME/.local/**"],
    "layer_3": {"enabled": false}
  }
}
EOF
out=$(run lint plan-leaky 2>/dev/null) && rc=0 || rc=$?
assert "$rc" "1" "T5 lint exit=1 on findings"
assert "$(echo "$out" | jq -r '.status')" "lint_errors" "T5 status=lint_errors"
fcount=$(echo "$out" | jq -r '.finding_count')
[[ "$fcount" -ge 2 ]] && {
  PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: T5 ≥2 findings (got $fcount)"
} || {
  FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: T5 expected ≥2 findings, got $fcount"
}
sev_uniq=$(echo "$out" | jq -r '[.findings[].severity] | unique | join(",")')
assert "$sev_uniq" "incident_beta_class" "T5 all findings tagged incident_beta_class"

# === Test 6: lint clean when writer declared in layer_3.launchd_labels ====
echo ""
echo "Test 6: lint clean when writer declared in layer_3.launchd_labels"
mkdir -p "$PLANS/plan-careful"
cat > "$PLANS/plan-careful/manifest.json" <<EOF
{
  "schema_version": 1,
  "live_mutation_scope": {
    "enabled": true,
    "scope_paths": ["\$HOME/.local/**"],
    "layer_3": {
      "enabled": true,
      "launchd_labels": ["com.foo-cron"],
      "session_end_hooks": [{"path": "$HOOKS/foo-end.sh", "pause_via": "sentinel", "sentinel_path": "/tmp/x"}]
    }
  }
}
EOF
# But com.missing-cron and missing-end.sh's write_paths also overlap; we must
# declare/exempt those too. Include them via exempt_paths.
cat > "$PLANS/plan-careful/manifest.json" <<EOF
{
  "schema_version": 1,
  "live_mutation_scope": {
    "enabled": true,
    "scope_paths": ["\$HOME/.local/**"],
    "exempt_paths": ["\$HOME/.local/state/missing/**", "\$HOME/.local/share/missing-data/**"],
    "layer_3": {
      "enabled": true,
      "launchd_labels": ["com.foo-cron"],
      "session_end_hooks": [{"path": "$HOOKS/foo-end.sh", "pause_via": "sentinel", "sentinel_path": "/tmp/x"}]
    }
  }
}
EOF
out=$(run lint plan-careful) && rc=0 || rc=$?
assert "$rc" "0" "T6 lint exit=0 (clean)"
assert "$(echo "$out" | jq -r '.status')" "clean" "T6 status=clean"
assert "$(echo "$out" | jq -r '.finding_count')" "0" "T6 0 findings"

# === Test 7: lint clean when writer's write_paths covered by exempt_paths =
echo ""
echo "Test 7: lint clean when writer's write_paths fully exempt'd"
mkdir -p "$PLANS/plan-exempt"
cat > "$PLANS/plan-exempt/manifest.json" <<EOF
{
  "schema_version": 1,
  "live_mutation_scope": {
    "enabled": true,
    "scope_paths": ["\$HOME/.local/**"],
    "exempt_paths": [
      "\$HOME/.local/state/foo/**",
      "\$HOME/.local/state/missing/**",
      "\$HOME/.local/share/foo-data/**",
      "\$HOME/.local/share/missing-data/**"
    ],
    "layer_3": {"enabled": false}
  }
}
EOF
out=$(run lint plan-exempt) && rc=0 || rc=$?
assert "$rc" "0" "T7 lint exit=0"
assert "$(echo "$out" | jq -r '.finding_count')" "0" "T7 0 findings (all exempt)"

# === Test 8: lint skipped when enabled=false ==============================
echo ""
echo "Test 8: lint skipped when live_mutation_scope.enabled=false"
mkdir -p "$PLANS/plan-disabled"
cat > "$PLANS/plan-disabled/manifest.json" <<'EOF'
{"schema_version": 1, "live_mutation_scope": {"enabled": false}}
EOF
out=$(run lint plan-disabled 2>/dev/null) && rc=0 || rc=$?
assert "$rc" "0" "T8 lint exit=0 on disabled scope"
assert "$(echo "$out" | jq -r '.status')" "skipped" "T8 status=skipped"

# === Summary ==============================================================
echo ""
echo "Tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
echo "All T-10 l3-registry-audit assertions PASSED."
exit 0
