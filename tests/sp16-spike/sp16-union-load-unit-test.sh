#!/usr/bin/env bash
# SP16 T-4 — 6-scenario unit test for lib/foundation-overlay-load.sh + the
# R-32 type-DENY retrofit at pre-write-guard.sh:L1147-L1172.
#
# Per Plan 81 SP16 packet 06 §"Spike scope" point 4 + AC-4.
#
# Scenarios:
#   (a) foundation-only type allowed (no overlay entry)
#         expectation: hook R-32 PERMITS the write
#   (b) overlay-only type allowed (foundation doesn't declare)
#         expectation: hook R-32 PERMITS via union view (bug fix verified)
#   (c) collision-without-reason
#         expectation: helper R-52 DENY with rc=1
#   (d) collision-with-per-entry-reason
#         expectation: helper rc=0; union view honors overlay-wins
#   (e) collision-with-top-level-override-reasons (shape-bridge variant)
#         expectation: helper rc=0; union view honors overlay-wins
#   (f) --force-override bypasses R-52 DENY for one invocation
#   (g) invalid overlay JSON → fail-closed (helper rc=0, foundation-only view,
#         warning to stderr; hook still PERMITS foundation types)
#
# AC-4 packet 06 lists 6 scenarios; this test adds (g) as a 7th explicitly
# because shape-bridge separates the per-entry vs top-level-dict permit
# pathways into two distinct scenarios (d and e), while ADR-0006 considered
# them one. The 7th covers fail-closed semantics; under the AC-4 numbering
# fail-closed is scenario (f).
#
# Hard constraints:
#   - All fixtures under $TEMPROOT (mktemp jail)
#   - Zero writes to ~/.claude/
#   - bash 3.2 compatible

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
HOOK="$FOUNDATION_REPO/hooks/pre-write-guard.sh"
HELPER="$FOUNDATION_REPO/lib/foundation-overlay-load.sh"
FOUNDATION_SRC="$FOUNDATION_REPO/governance/foundation-master.json"

[ -x "$HOOK" ] || { printf 'FATAL: hook not executable: %s\n' "$HOOK" >&2; exit 2; }
[ -x "$HELPER" ] || { printf 'FATAL: helper not executable: %s\n' "$HELPER" >&2; exit 2; }
[ -r "$FOUNDATION_SRC" ] || { printf 'FATAL: foundation-master source missing\n' >&2; exit 2; }

TEMPROOT="$(mktemp -d -t sp16-unit.XXXXXX)" || exit 2
case "$TEMPROOT" in /*) ;; *) printf 'FATAL: TEMPROOT not absolute\n' >&2; exit 2 ;; esac
trap 'rm -rf "$TEMPROOT"' EXIT

FIX_CLAUDE="$TEMPROOT/.claude"
FIX_GOV="$FIX_CLAUDE/governance"
FIX_VAULT="$TEMPROOT/vault"
FIX_STATE="$FIX_CLAUDE/hooks/state"
mkdir -p "$FIX_GOV" "$FIX_VAULT/Archive/Adopter" "$FIX_STATE"

cp "$FOUNDATION_SRC" "$FIX_GOV/foundation-master.json"

PASS=0
FAIL=0
FAILED_SCENARIOS=""

emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() {
  printf '  FAIL: %s — %s\n' "$1" "$2";
  FAIL=$((FAIL + 1));
  FAILED_SCENARIOS="$FAILED_SCENARIOS\n    - $1: $2"
}

# ---- Helper: run hook with given overlay + content; return DENY status -----
# args: overlay-json-path, content-string, [extra env var assignments]
# emits to stdout: "DENY" or "ALLOW"
# also captures rc/stdout/stderr to $TEMPROOT/hook-{out,err,rc}
run_hook() {
  local overlay_path="$1"
  local content="$2"
  local write_path="$FIX_VAULT/Archive/Adopter/test-note.md"

  local payload
  payload=$(jq -nc \
    --arg fp "$write_path" \
    --arg content "$content" \
    '{tool_name: "Write", tool_input: {file_path: $fp, content: $content}}')

  set +e
  printf '%s' "$payload" | \
    VAULT_ROOT="$FIX_VAULT" \
    FOUNDATION_MASTER_PATH="$FIX_GOV/foundation-master.json" \
    OVERLAY_MASTER_PATH="$overlay_path" \
    HOOKS_STATE_OVERRIDE="$FIX_STATE" \
    CLAUDE_SESSION_ID="sp16-t4-unit" \
    bash "$HOOK" >"$TEMPROOT/hook-out" 2>"$TEMPROOT/hook-err"
  echo $? > "$TEMPROOT/hook-rc"
  set -e

  if grep -qF "R-32 UNKNOWN TYPE" "$TEMPROOT/hook-out" 2>/dev/null; then
    echo "DENY-R32-UNKNOWN"
  elif grep -qF "permissionDecision\": \"deny\"" "$TEMPROOT/hook-out" 2>/dev/null; then
    echo "DENY-OTHER"
  else
    echo "ALLOW"
  fi
}

# Standard write content factory (parameterized by type slug)
make_content() {
  local type_slug="$1"
  cat <<EOF
---
type: $type_slug
title: Unit test fixture
tags:
  - "#status/active"
created: 2026-05-21
updated: 2026-05-21
---
# Body
EOF
}

printf '=== SP16 T-4 unit-test: lib/foundation-overlay-load.sh + R-32 retrofit ===\n'

# ============================================================================
# Scenario (a) — foundation-only type allowed (no overlay entry)
# Expectation: hook R-32 PERMITS write of canonical type "reference"
# (reference picked over context: 3 required fields all present in fixture)
# ============================================================================
printf '\n--- (a) foundation-only type "reference" allowed ---\n'
echo '{}' > "$TEMPROOT/overlay-a.json"
RESULT=$(run_hook "$TEMPROOT/overlay-a.json" "$(make_content reference)")
if [ "$RESULT" = "ALLOW" ]; then
  emit_pass "(a) foundation-only type permitted"
else
  emit_fail "(a) foundation-only type rejected" "$RESULT; hook-out: $(cat "$TEMPROOT/hook-out" | head -c 200)"
fi

# ============================================================================
# Scenario (b) — overlay-only type allowed (foundation doesn't declare)
# Expectation: hook R-32 PERMITS via union view (bug fix verified)
# ============================================================================
printf '\n--- (b) overlay-extended type "client-brief" permitted via union ---\n'
cat > "$TEMPROOT/overlay-b.json" <<'JSON'
{"frontmatter": {"types": {"client-brief": {"required": ["type"]}}}}
JSON
RESULT=$(run_hook "$TEMPROOT/overlay-b.json" "$(make_content client-brief)")
if [ "$RESULT" = "ALLOW" ]; then
  emit_pass "(b) overlay-only type permitted via union (bug fix)"
else
  emit_fail "(b) overlay-only type rejected" "$RESULT; hook-out: $(cat "$TEMPROOT/hook-out" | head -c 200)"
fi

# ============================================================================
# Scenario (c) — collision without _override_reason (helper R-52 DENY)
# Expectation: helper exits 1 with R-52 violation message
# ============================================================================
printf '\n--- (c) collision without _override_reason → helper R-52 DENY ---\n'
cat > "$TEMPROOT/overlay-c.json" <<'JSON'
{"frontmatter": {"types": {"context": {"required": ["type"]}}}}
JSON
set +e
"$HELPER" \
  --foundation-path "$FIX_GOV/foundation-master.json" \
  --overlay-path "$TEMPROOT/overlay-c.json" \
  >"$TEMPROOT/helper-out" 2>"$TEMPROOT/helper-err"
HELPER_RC=$?
set -e
if [ "$HELPER_RC" = "1" ] && grep -qF "R-52 violation" "$TEMPROOT/helper-err"; then
  emit_pass "(c) helper R-52 DENY fired (rc=1; violation message present)"
else
  emit_fail "(c) helper R-52 DENY did not fire" "rc=$HELPER_RC; stderr: $(cat "$TEMPROOT/helper-err" | head -c 200)"
fi

# ============================================================================
# Scenario (d) — collision WITH per-entry _override_reason (overlay wins)
# Expectation: helper rc=0; union view honors overlay-wins; hook reads override
# ============================================================================
printf '\n--- (d) collision with per-entry _override_reason → permits ---\n'
cat > "$TEMPROOT/overlay-d.json" <<'JSON'
{"frontmatter": {"types": {"context": {"required": ["type"], "_override_reason": "adopter overrides for unit test"}}}}
JSON
set +e
"$HELPER" \
  --foundation-path "$FIX_GOV/foundation-master.json" \
  --overlay-path "$TEMPROOT/overlay-d.json" \
  --query '.frontmatter.types.context._override_reason' \
  >"$TEMPROOT/helper-out" 2>"$TEMPROOT/helper-err"
HELPER_RC=$?
set -e
if [ "$HELPER_RC" = "0" ] && grep -qF "adopter overrides" "$TEMPROOT/helper-out"; then
  emit_pass "(d) helper permits collision with per-entry _override_reason"
else
  emit_fail "(d) helper rejected valid per-entry override" "rc=$HELPER_RC; stdout: $(cat "$TEMPROOT/helper-out" | head -c 200); stderr: $(cat "$TEMPROOT/helper-err" | head -c 200)"
fi

# ============================================================================
# Scenario (e) — collision WITH top-level override_reasons (shape-bridge)
# Expectation: helper rc=0 (alternate shape satisfies R-52)
# ============================================================================
printf '\n--- (e) collision with top-level override_reasons (shape-bridge) ---\n'
cat > "$TEMPROOT/overlay-e.json" <<'JSON'
{
  "frontmatter": {"types": {"context": {"required": ["type"]}}},
  "override_reasons": {"frontmatter": {"types": {"context": "shape-bridge dict form for unit test"}}}
}
JSON
set +e
"$HELPER" \
  --foundation-path "$FIX_GOV/foundation-master.json" \
  --overlay-path "$TEMPROOT/overlay-e.json" \
  --query '.frontmatter.types.context.required[0]' \
  >"$TEMPROOT/helper-out" 2>"$TEMPROOT/helper-err"
HELPER_RC=$?
set -e
if [ "$HELPER_RC" = "0" ] && grep -qF "type" "$TEMPROOT/helper-out"; then
  emit_pass "(e) helper permits collision with top-level override_reasons (shape-bridge)"
else
  emit_fail "(e) helper rejected valid top-level override_reasons" "rc=$HELPER_RC; stdout: $(cat "$TEMPROOT/helper-out" | head -c 200); stderr: $(cat "$TEMPROOT/helper-err" | head -c 200)"
fi

# ============================================================================
# Scenario (f) — --force-override bypasses R-52 DENY for one invocation
# Expectation: same collision-without-reason scenario as (c), but with
#              --force-override → helper rc=0
# ============================================================================
printf '\n--- (f) --force-override bypasses R-52 DENY ---\n'
# Reuse overlay-c.json (collision without reason)
set +e
"$HELPER" \
  --foundation-path "$FIX_GOV/foundation-master.json" \
  --overlay-path "$TEMPROOT/overlay-c.json" \
  --force-override \
  --query '.frontmatter.types.context.required[0]' \
  >"$TEMPROOT/helper-out" 2>"$TEMPROOT/helper-err"
HELPER_RC=$?
set -e
if [ "$HELPER_RC" = "0" ] && grep -qF "type" "$TEMPROOT/helper-out"; then
  emit_pass "(f) --force-override bypasses R-52 DENY"
else
  emit_fail "(f) --force-override failed to bypass" "rc=$HELPER_RC; stderr: $(cat "$TEMPROOT/helper-err" | head -c 200)"
fi

# ============================================================================
# Scenario (g) — invalid overlay JSON → fail-closed
# Expectation: helper rc=0; foundation-only view; warning to stderr;
#              hook still PERMITS foundation types via union (degraded but safe)
# ============================================================================
printf '\n--- (g) invalid overlay JSON → fail-closed degraded-but-safe ---\n'
echo '{not valid json' > "$TEMPROOT/overlay-g.json"
set +e
"$HELPER" \
  --foundation-path "$FIX_GOV/foundation-master.json" \
  --overlay-path "$TEMPROOT/overlay-g.json" \
  --query '.frontmatter.types | keys | length' \
  >"$TEMPROOT/helper-out" 2>"$TEMPROOT/helper-err"
HELPER_RC=$?
set -e
HELPER_KEYS=$(cat "$TEMPROOT/helper-out")
if [ "$HELPER_RC" = "0" ] && grep -qF "invalid JSON" "$TEMPROOT/helper-err" && [ "$HELPER_KEYS" -gt "0" ] 2>/dev/null; then
  emit_pass "(g) helper fails closed; foundation-only view emitted; warning present"
else
  emit_fail "(g) fail-closed semantics broken" "rc=$HELPER_RC; keys=$HELPER_KEYS; stderr: $(cat "$TEMPROOT/helper-err" | head -c 200)"
fi

# Bonus: confirm hook still PERMITS foundation type when overlay is invalid
RESULT=$(run_hook "$TEMPROOT/overlay-g.json" "$(make_content reference)")
if [ "$RESULT" = "ALLOW" ]; then
  emit_pass "(g+) hook PERMITS foundation type under invalid-overlay fail-closed"
else
  emit_fail "(g+) hook regressed under invalid-overlay" "$RESULT; hook-out: $(cat "$TEMPROOT/hook-out" | head -c 200)"
fi

# ---- Final tally ------------------------------------------------------------

printf '\n=== SP16 T-4 results: %s PASS, %s FAIL ===\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt "0" ]; then
  printf 'Failed scenarios:%b\n' "$FAILED_SCENARIOS"
  exit 1
fi
exit 0
