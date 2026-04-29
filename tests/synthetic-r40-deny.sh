#!/usr/bin/env bash
# synthetic-r40-deny.sh — SP02 T-10 commit 2.
#
# Plan-tree frontmatter coverage. Brief asked for "synthetic plan write
# missing R-40 frontmatter → pre-write-guard DENIES."
#
# Foundation reality (T-4 ground truth, hooks/pre-write-guard.sh L24,
# L283-339): R-40 is **advisory-only**. Missing/wrong canonical type emits
# additionalContext, never deny. The "plan write without frontmatter →
# DENY" path is enforced by **R-27 missing-status-header**, not R-40.
#
# Filename preserved per brief; coverage matches actual rule semantics:
#
#   case 1  no frontmatter at all      → DENY (R-27 status marker missing)
#   case 2  frontmatter, no type:      → ALLOW + R-40 advisory
#   case 3  frontmatter, wrong type:   → ALLOW + R-40 advisory
#   case 4  frontmatter, correct type: → ALLOW, no R-40 advisory (control)
#
# Bash 3.2 compatible (R-23). Sandbox HOME-override pattern.

set -u

SBX="/tmp/synthetic-r40-deny-sbx-$$"
SRC="$(cd "$(dirname "$0")/.." && pwd)"

trap 'rm -rf "$SBX"' EXIT

pass=0
fail=0
fail_log=""

record_pass() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
record_fail() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
  fail_log="${fail_log}
  FAIL: $1
    detail: $2"
}

make_sbx() {
  rm -rf "$SBX"
  mkdir -p "$SBX/.claude/hooks/lib" "$SBX/.claude/hooks/state" \
           "$SBX/.claude/hooks/config" "$SBX/.claude/schemas" \
           "$SBX/.claude/skills/librarian/lib" "$SBX/.claude-plans" \
           "$SBX/vault/Logs/.coordination"
  cp "$SRC/hooks/pre-write-guard.sh" "$SBX/.claude/hooks/"
  cp "$SRC/lib"/*.sh "$SBX/.claude/hooks/lib/"
  echo '{"version":2,"entries":[]}' > "$SBX/.claude/hooks/config/doc-dependencies.json"

  # Vault schema (minimal — R-32 path passes through trivially)
  cat > "$SBX/.claude/schemas/vault-schema.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "_aliases": {}
}
JSON

  # Plan-path classifier — recognizes spec.md/tasks.md/handoff.md as
  # canonical plan-root files at depth 2. Installed at hooks/lib/ post-SP02 T-9
  # (mirrors librarian/lib contract; skills/librarian fallback removed).
  cat > "$SBX/.claude/hooks/lib/plan-path.sh" <<'PLANPATH'
classify_plan_path() {
  local path="$1" plans_dir="${PLANS_DIR:-$HOME/.claude-plans}"
  if [[ "$path" != "$plans_dir/"* ]]; then echo "0|0|"; return; fi
  local rel="${path#$plans_dir/}"
  local top="${rel%%/*}"
  local base
  base="$(basename "$path")"
  local is_manifest=0
  [[ "$base" == "manifest.json" ]] && is_manifest=1
  case "$base" in
    spec.md|tasks.md|handoff.md|00-ideation-brief.md|README.md|manifest.json)
      echo "1|${is_manifest}|${top}"; return ;;
  esac
  echo "0|0|${top}"
}
PLANPATH

  echo '{"sessions":{},"pending_reconciliation":false,"last_reconciled":""}' \
    > "$SBX/vault/Logs/.coordination/session-registry.json"
}

run_hook() {
  local input="$1"
  env -i HOME="$SBX" CLAUDE_HOME="$SBX/.claude" \
    PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
    VAULT_ROOT="$SBX/vault" PLANS_DIR="$SBX/.claude-plans" PWD="$SBX" \
    bash "$SBX/.claude/hooks/pre-write-guard.sh" <<< "$input"
}

assert_decision() {
  local label="$1" expected="$2" output="$3"
  local got
  got=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // "(missing)"' 2>/dev/null)
  if [ "$got" = "$expected" ]; then
    record_pass "$label (decision=$got)"
  else
    record_fail "$label" "expected decision=$expected, got=$got | output: $output"
  fi
}

assert_ctx_contains() {
  local label="$1" needle="$2" output="$3"
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
  case "$ctx" in
    *"$needle"*) record_pass "$label (context contains '$needle')" ;;
    *) record_fail "$label" "context missing '$needle' | got: $ctx" ;;
  esac
}

assert_ctx_lacks() {
  local label="$1" needle="$2" output="$3"
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
  case "$ctx" in
    *"$needle"*) record_fail "$label" "context wrongly contains '$needle' | got: $ctx" ;;
    *) record_pass "$label (context lacks '$needle')" ;;
  esac
}

assert_reason_contains() {
  local label="$1" needle="$2" output="$3"
  local reason
  reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
  case "$reason" in
    *"$needle"*) record_pass "$label (reason contains '$needle')" ;;
    *) record_fail "$label" "reason missing '$needle' | got: $reason" ;;
  esac
}

# ============================================================================
# CASE 1: plan write with NO frontmatter at all → DENY (R-27 missing status)
# ============================================================================
make_sbx
mkdir -p "$SBX/.claude-plans/01-numbered"
INPUT=$(jq -nc --arg fp "$SBX/.claude-plans/01-numbered/spec.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"# Plan with no frontmatter, no status"}}')
OUT=$(run_hook "$INPUT")
assert_decision "case-1: plan no frontmatter → DENY" "deny" "$OUT"
assert_reason_contains "case-1: reason cites status marker" "status marker" "$OUT"

# ============================================================================
# CASE 2: plan write WITH frontmatter, missing canonical type → ALLOW + R-40
# ============================================================================
make_sbx
mkdir -p "$SBX/.claude-plans/01-numbered"
INPUT=$(jq -nc --arg fp "$SBX/.claude-plans/01-numbered/spec.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"---\nstatus: active\n---\n# Spec\n\n**Status:** active"}}')
OUT=$(run_hook "$INPUT")
assert_decision "case-2: plan missing canonical type → ALLOW" "allow" "$OUT"
assert_ctx_contains "case-2: R-40 advisory cites missing type" "R-40 PLAN FRONTMATTER" "$OUT"
assert_ctx_contains "case-2: R-40 advisory cites canonical type" "Expected: type: spec" "$OUT"

# ============================================================================
# CASE 3: plan write WITH non-canonical type → ALLOW + R-40 advisory
# ============================================================================
make_sbx
mkdir -p "$SBX/.claude-plans/01-numbered"
INPUT=$(jq -nc --arg fp "$SBX/.claude-plans/01-numbered/spec.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"---\ntype: random-type\nstatus: active\n---\n# Spec\n\n**Status:** active"}}')
OUT=$(run_hook "$INPUT")
assert_decision "case-3: plan non-canonical type → ALLOW" "allow" "$OUT"
assert_ctx_contains "case-3: R-40 advisory cites non-canonical type" "non-canonical type" "$OUT"

# ============================================================================
# CASE 4: plan write WITH correct R-40 frontmatter → ALLOW, no R-40 advisory
# ============================================================================
make_sbx
mkdir -p "$SBX/.claude-plans/01-numbered"
INPUT=$(jq -nc --arg fp "$SBX/.claude-plans/01-numbered/spec.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"---\ntype: spec\nstatus: active\n---\n# Spec\n\n**Status:** active"}}')
OUT=$(run_hook "$INPUT")
assert_decision "case-4: plan canonical R-40 → ALLOW" "allow" "$OUT"
assert_ctx_lacks "case-4: no R-40 advisory on canonical type" "R-40 PLAN FRONTMATTER" "$OUT"

# ============================================================================
# Summary
# ============================================================================
printf '\n----------------------------------\n'
printf 'passed: %s\n' "$pass"
printf 'failed: %s\n' "$fail"
printf '%s\n' '----------------------------------'
if [ "$fail" -gt 0 ]; then
  printf '\nFailures:%s\n' "$fail_log"
  exit 1
fi
exit 0
