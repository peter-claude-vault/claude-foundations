#!/usr/bin/env bash
# SP17a T-5 — R-52 write-time DENY hook branch unit test (AC-4)
#
# Verifies the new hook branch at pre-write-guard.sh (post-G1, pre-dead-plans):
#   - Fires ONLY when $FILE_PATH = overlay-master.json (narrow file-path gate)
#   - Invokes foundation-overlay-load.sh WITHOUT --force-override (the SINGLE
#     such call site)
#   - DENIES Write+Edit when pending overlay shadows foundation without
#     per-entry _override_reason (canonical shape per ADR-0006 + SP17a T-5
#     Decision Point #1)
#   - PERMITS when shadowing entry carries per-entry _override_reason
#   - PERMITS when R52_FORCE_OVERRIDE=1 (per-write bypass)
#   - Does NOT fire on writes to other files (e.g. random vault markdown)
#
# Scope: bash 3.2 compatible; mktemp-jailed fixtures; zero ~/.claude/ writes.

set -u

# Resolve repo from script location so tests bind to THIS worktree, not the
# live ~/Code/claude-stem (matches per-pillar-collision-test convention).
_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FOUNDATION_REPO="${FOUNDATION_REPO:-$(cd "$_TEST_DIR/../.." && pwd)}"
HOOK="$FOUNDATION_REPO/hooks/pre-write-guard.sh"
HELPER="$FOUNDATION_REPO/lib/foundation-overlay-load.sh"
[ -x "$HOOK" ]   || { printf 'FATAL: hook not executable: %s\n' "$HOOK"   >&2; exit 2; }
[ -x "$HELPER" ] || { printf 'FATAL: helper not executable: %s\n' "$HELPER" >&2; exit 2; }

TEMPROOT="$(mktemp -d -t sp17a-r52-deny.XXXXXX)" || exit 2
trap 'rm -rf "$TEMPROOT"' EXIT

# Stage minimal foundation bundle + hook substrate. Mirror SP14 substrate
# layout so the hook's helper-path dual-layout resolution finds the helper.
mkdir -p "$TEMPROOT/.claude/governance" \
         "$TEMPROOT/.claude/hooks/lib" \
         "$TEMPROOT/.claude/hooks/state" \
         "$TEMPROOT/.claude/skills/librarian/lib"
cp "$HELPER" "$TEMPROOT/.claude/hooks/lib/foundation-overlay-load.sh"
chmod +x "$TEMPROOT/.claude/hooks/lib/foundation-overlay-load.sh"

# Stub plan-path.sh (hook sources it for R-27 plan naming check). Without
# this stub the hook fails downstream of the T-5 branch on non-DENY paths.
cat > "$TEMPROOT/.claude/skills/librarian/lib/plan-path.sh" <<'EOF'
#!/bin/bash
plan_root() { echo "$1"; }
classify_plan_path() { return 0; }
EOF

# Minimal foundation bundle: one type slot for collision testing.
cat > "$TEMPROOT/.claude/governance/foundation-master.json" <<'JSON'
{
  "schema_version": "1.2.0",
  "frontmatter": {
    "types": {
      "context": {"required": ["type", "tags"]}
    }
  }
}
JSON

# Stage paths.sh + registry.sh stubs so the hook can source them.
mkdir -p "$TEMPROOT/.claude/hooks/lib"
cat > "$TEMPROOT/.claude/hooks/lib/paths.sh" <<EOF
#!/bin/bash
export CLAUDE_HOME="$TEMPROOT/.claude"
export HOOKS_STATE="$TEMPROOT/.claude/hooks/state"
export GOVERNANCE_DIR="$TEMPROOT/.claude/governance"
export FOUNDATION_MASTER="$TEMPROOT/.claude/governance/foundation-master.json"
export PLANS_DIR_DEAD="$TEMPROOT/.claude/plans-dead"
export VAULT="$TEMPROOT/vault"
mkdir -p "\$VAULT"
EOF
cat > "$TEMPROOT/.claude/hooks/lib/registry.sh" <<'EOF'
#!/bin/bash
format_output_deny() {
  printf 'DENY: %s\n' "$2" >&2
  exit 0
}
EOF

OVERLAY_PATH="$TEMPROOT/.claude/governance/overlay-master.json"
PASS=0
FAIL=0

assert() {
  local label="$1" exp="$2" got="$3"
  if [ "$exp" = "$got" ]; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s (expected %s, got %s)\n' "$label" "$exp" "$got"
    FAIL=$((FAIL + 1))
  fi
}

run_hook() {
  # args: file_path tool_name <payload-json>
  local fp="$1" tn="$2" payload="$3"
  local input
  input=$(jq -n --arg fp "$fp" --arg tn "$tn" --argjson p "$payload" \
    '{tool_name: $tn, tool_input: ($p + {file_path: $fp})}')
  # `VAR=val cmd1 | cmd2` applies VAR to cmd1 only; the hook on the right
  # side of the pipe inherits the parent env unmodified. Use `env` so the
  # vars reach the hook process.
  printf '%s' "$input" \
    | env \
        HOME="$TEMPROOT" \
        FOUNDATION_MASTER_PATH="$TEMPROOT/.claude/governance/foundation-master.json" \
        OVERLAY_MASTER_PATH="$OVERLAY_PATH" \
        FOUNDATION_OVERLAY_LOAD="$TEMPROOT/.claude/hooks/lib/foundation-overlay-load.sh" \
        HOOKS_STATE_OVERRIDE="$TEMPROOT/.claude/hooks/state" \
        "$HOOK" >"$TEMPROOT/out.txt" 2>"$TEMPROOT/err.txt"
  echo $?
}

# ============================================================================
# Scenario 1: Write to overlay-master.json with shadowing entry NO reason → DENY
# ============================================================================
printf '\n--- (1) Write to overlay-master.json — shadows foundation, no _override_reason → DENY ---\n'
SHADOW_NO_REASON='{"content":"{\"frontmatter\":{\"types\":{\"context\":{\"required\":[\"type\"]}}}}"}'
rc=$(run_hook "$OVERLAY_PATH" "Write" "$SHADOW_NO_REASON")
assert "Write rc=0 (DENY emitted but hook exits 0 per pattern)" "0" "$rc"
if grep -qF "R-52 write-time DENY" "$TEMPROOT/err.txt"; then
  printf '  PASS: stderr carries R-52 DENY signal\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: stderr missing R-52 DENY signal\n'
  printf '    stderr=%s\n' "$(cat "$TEMPROOT/err.txt")"
  FAIL=$((FAIL + 1))
fi

# ============================================================================
# Scenario 2: Write to overlay-master.json with per-entry _override_reason → PERMIT
# ============================================================================
printf '\n--- (2) Write to overlay-master.json — shadows foundation WITH _override_reason → PERMIT ---\n'
SHADOW_WITH_REASON='{"content":"{\"frontmatter\":{\"types\":{\"context\":{\"required\":[\"type\"],\"_override_reason\":\"adopter narrowed required fields\"}}}}"}'
rc=$(run_hook "$OVERLAY_PATH" "Write" "$SHADOW_WITH_REASON")
# PERMIT scenarios let the hook continue past T-5; downstream stubs are
# minimal so hook may rc=1. Scope = R-52 DENY did NOT fire.
if grep -qF "R-52 write-time DENY" "$TEMPROOT/err.txt"; then
  printf '  FAIL: stderr falsely emitted R-52 DENY despite per-entry override\n'
  printf '    stderr=%s\n' "$(cat "$TEMPROOT/err.txt")"
  FAIL=$((FAIL + 1))
else
  printf '  PASS: stderr clean (no DENY; per-entry override permits)\n'
  PASS=$((PASS + 1))
fi

# ============================================================================
# Scenario 3: Write to overlay-master.json — TOP-LEVEL override_reasons dict
# (retired shape) → DENY
# Verifies the SP17a T-5 Decision Point #1 retirement is enforced.
# ============================================================================
printf '\n--- (3) Write to overlay-master.json — retired top-level dict shape → DENY ---\n'
TOPLEVEL_DICT='{"content":"{\"frontmatter\":{\"types\":{\"context\":{\"required\":[\"type\"]}}},\"override_reasons\":{\"frontmatter\":{\"types\":{\"context\":\"retired dict shape\"}}}}"}'
rc=$(run_hook "$OVERLAY_PATH" "Write" "$TOPLEVEL_DICT")
assert "Write rc=0 (DENY emitted; hook exits 0)" "0" "$rc"
if grep -qF "R-52 write-time DENY" "$TEMPROOT/err.txt"; then
  printf '  PASS: top-level dict shape REJECTED (Decision Point #1 enforced)\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: retired top-level dict shape was not rejected\n'
  printf '    stderr=%s\n' "$(cat "$TEMPROOT/err.txt")"
  FAIL=$((FAIL + 1))
fi

# ============================================================================
# Scenario 4: Write to overlay-master.json — overlay extends without shadowing → PERMIT
# ============================================================================
printf '\n--- (4) Write to overlay-master.json — adds new type (no collision) → PERMIT ---\n'
NEW_TYPE='{"content":"{\"frontmatter\":{\"types\":{\"client-brief\":{\"required\":[\"type\",\"tags\"]}}}}"}'
rc=$(run_hook "$OVERLAY_PATH" "Write" "$NEW_TYPE")
if grep -qF "R-52 write-time DENY" "$TEMPROOT/err.txt"; then
  printf '  FAIL: extension-only overlay falsely DENIED\n'
  printf '    stderr=%s\n' "$(cat "$TEMPROOT/err.txt")"
  FAIL=$((FAIL + 1))
else
  printf '  PASS: extension-only overlay permitted (no DENY)\n'
  PASS=$((PASS + 1))
fi

# ============================================================================
# Scenario 5: R52_FORCE_OVERRIDE=1 bypasses DENY for one invocation
# ============================================================================
printf '\n--- (5) R52_FORCE_OVERRIDE=1 → bypass DENY (per-write) ---\n'
input=$(jq -n --arg fp "$OVERLAY_PATH" --argjson p '{"content":"{\"frontmatter\":{\"types\":{\"context\":{\"required\":[\"type\"]}}}}"}' \
  '{tool_name: "Write", tool_input: ($p + {file_path: $fp})}')
printf '%s' "$input" \
  | env \
      HOME="$TEMPROOT" \
      FOUNDATION_MASTER_PATH="$TEMPROOT/.claude/governance/foundation-master.json" \
      OVERLAY_MASTER_PATH="$OVERLAY_PATH" \
      FOUNDATION_OVERLAY_LOAD="$TEMPROOT/.claude/hooks/lib/foundation-overlay-load.sh" \
      HOOKS_STATE_OVERRIDE="$TEMPROOT/.claude/hooks/state" \
      R52_FORCE_OVERRIDE=1 \
      "$HOOK" >"$TEMPROOT/out5.txt" 2>"$TEMPROOT/err5.txt"
rc5=$?
if grep -qF "R-52 write-time DENY" "$TEMPROOT/err5.txt"; then
  printf '  FAIL: R52_FORCE_OVERRIDE=1 failed to bypass\n'
  printf '    stderr=%s\n' "$(cat "$TEMPROOT/err5.txt")"
  FAIL=$((FAIL + 1))
else
  printf '  PASS: R52_FORCE_OVERRIDE=1 bypassed DENY (no DENY signal)\n'
  PASS=$((PASS + 1))
fi

# ============================================================================
# Scenario 6: Write to a DIFFERENT file (not overlay-master.json) → branch silent
# ============================================================================
printf '\n--- (6) Write to vault markdown — R-52 branch silent (non-overlay) ---\n'
NON_OVERLAY='{"content":"---\ntype: context\n---\nbody"}'
rc=$(run_hook "$TEMPROOT/vault/Random/Note.md" "Write" "$NON_OVERLAY")
# Hook may still emit other guidance (Tier 1/3) but should NOT carry R-52 DENY.
if grep -qF "R-52 write-time DENY" "$TEMPROOT/err.txt"; then
  printf '  FAIL: R-52 DENY fired on non-overlay file\n'
  printf '    stderr=%s\n' "$(cat "$TEMPROOT/err.txt")"
  FAIL=$((FAIL + 1))
else
  printf '  PASS: R-52 branch silent on non-overlay file\n'
  PASS=$((PASS + 1))
fi

# ============================================================================
# Scenario 7: Edit overlay-master.json — substitution introduces shadowing → DENY
# ============================================================================
printf '\n--- (7) Edit overlay-master.json — old→new introduces shadow → DENY ---\n'
# Seed overlay with a non-shadowing entry first.
cat > "$OVERLAY_PATH" <<'JSON'
{
  "frontmatter": {
    "types": {
      "client-brief": {"required": ["type", "tags"]}
    }
  }
}
JSON
EDIT_PAYLOAD=$(jq -n \
  --arg old '"client-brief": {"required": ["type", "tags"]}' \
  --arg new '"client-brief": {"required": ["type", "tags"]}, "context": {"required": ["type"]}' \
  '{old_string: $old, new_string: $new}')
rc=$(run_hook "$OVERLAY_PATH" "Edit" "$EDIT_PAYLOAD")
assert "Edit rc=0 (DENY emitted; hook exits 0)" "0" "$rc"
if grep -qF "R-52 write-time DENY" "$TEMPROOT/err.txt"; then
  printf '  PASS: Edit-introduced shadow DENIED\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: Edit-introduced shadow not DENIED\n'
  printf '    stderr=%s\n' "$(cat "$TEMPROOT/err.txt")"
  FAIL=$((FAIL + 1))
fi

# ---- Summary ----
printf '\n=== SP17a T-5 R-52 write-time DENY results: %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
