#!/usr/bin/env bash
# pre-write-guard-r-rules.sh — synthetic R-rule fire tests for SP02 T-4 rewrite.
#
# Tests one synthetic input per preserved R-rule. The 13 rules tested here are
# the ones actually enforced by foundation-repo/hooks/pre-write-guard.sh:
#   R-01, R-02, R-04 (size-guard + vault-root paths counted as one rule), R-15,
#   R-23, R-24, R-27, R-28, R-32, R-33, R-40, R-42, R-45, R-54
#
# The original SP02 T-4 spec listed 16 preserved rules but 3 of them
# (R-26, R-38, R-46) are enforced by other hooks/skills:
#   R-26 → prompt-context.sh + stop-checkpoint-check.sh
#   R-38 → post-write-verify.sh
#   R-46 → librarian skill (waiver-audit capability)
# Their tests belong to those hook test suites, not this one. See
# foundation-repo/hooks/DROPPED-RULES.md §"Dropped — covered-elsewhere".
#
# Architecture: HOME-override sandbox (T-15 pattern). Per-test:
#   1. Stage hook + lib/paths.sh + minimal user-manifest into sandbox.
#   2. Construct stdin JSON ({tool_name, tool_input}).
#   3. Pipe to hook; capture exit code + stdout JSON.
#   4. Assert permissionDecision shape and reason/context substring.
#
# bash 3.2 compatible (R-23): no associative arrays, no readarray.

set -u

SBX="/tmp/pwg-r-rules-sbx-$$"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SRC/hooks/pre-write-guard.sh"
LIB_PATHS="$SRC/lib/paths.sh"

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

# Fresh sandbox per test (cheap; isolates env contamination).
make_sbx() {
  rm -rf "$SBX"
  mkdir -p "$SBX/.claude/hooks/lib" "$SBX/.claude/hooks/state" "$SBX/.claude/hooks/config" \
           "$SBX/.claude/schemas" "$SBX/.claude/skills/librarian/lib" "$SBX/.claude-plans" \
           "$SBX/vault/Logs/.coordination"
  cp "$HOOK" "$SBX/.claude/hooks/pre-write-guard.sh"
  cp "$LIB_PATHS" "$SBX/.claude/hooks/lib/paths.sh"
  echo '{"version":2,"entries":[]}' > "$SBX/.claude/hooks/config/doc-dependencies.json"
  # Minimal vault-schema.json for R-32/R-33 path
  cat > "$SBX/.claude/schemas/vault-schema.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "people": {"required": ["type", "name"]},
  "_aliases": {}
}
JSON
  # Minimal plan-path.sh classifier (R-27 path) — installed at hooks/lib/
  # post-SP02 T-9 (canonical coupling target; skills/librarian fallback removed).
  cat > "$SBX/.claude/hooks/lib/plan-path.sh" <<'PLANPATH'
classify_plan_path() {
  local path="$1" plans_dir="${PLANS_DIR:-$HOME/.claude-plans}"
  if [[ "$path" != "$plans_dir/"* ]]; then echo "0|0|"; return; fi
  local rel="${path#$plans_dir/}"
  local top="${rel%%/*}"
  local base="$(basename "$path")"
  local is_manifest=0
  [[ "$base" == "manifest.json" ]] && is_manifest=1
  case "$base" in
    spec.md|tasks.md|handoff.md|00-ideation-brief.md|README.md|manifest.json)
      echo "1|${is_manifest}|${top}"; return ;;
  esac
  if [[ "$rel" == *.md ]] && [[ "$rel" != */* ]]; then
    echo "1|0|${top}"; return
  fi
  echo "0|0|${top}"
}
PLANPATH
}

# Run hook with given stdin JSON, manifest content, env. Echoes hook stdout.
# Args: <input_json> <manifest_json_or_empty> <extra_env_assignments_or_empty>
run_hook() {
  local input="$1" manifest="$2" envextra="$3"
  if [ -n "$manifest" ]; then
    printf '%s' "$manifest" > "$SBX/.claude/user-manifest.json"
  fi
  # Set required env (HOME → sandbox, CLAUDE_HOME → sandbox/.claude, VAULT_ROOT).
  # PWD propagated so resolve_memory_dir's `pwd -L` returns the logical cwd
  # even after env -i (PWD env var is what -L consults).
  env -i HOME="$SBX" CLAUDE_HOME="$SBX/.claude" PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
    VAULT_ROOT="$SBX/vault" PLANS_DIR="$SBX/.claude-plans" PWD="$(pwd)" $envextra \
    bash "$SBX/.claude/hooks/pre-write-guard.sh" <<< "$input"
}

# Assert hook output JSON has permissionDecision == expected.
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

# Assert hook output additionalContext contains substring.
assert_ctx_contains() {
  local label="$1" needle="$2" output="$3"
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
  case "$ctx" in
    *"$needle"*) record_pass "$label (context contains '$needle')" ;;
    *) record_fail "$label" "context missing '$needle' | got: $ctx" ;;
  esac
}

# Assert hook output reason contains substring.
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
# TEST 1: R-01 dead plans path DENY
# ============================================================================
make_sbx
mkdir -p "$SBX/.claude/plans"
INPUT=$(jq -nc --arg fp "$SBX/.claude/plans/something.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"x"}}')
OUT=$(run_hook "$INPUT" "" "PLANS_DIR_DEAD=$SBX/.claude/plans")
assert_decision "R-01 dead plans path → DENY" "deny" "$OUT"
assert_reason_contains "R-01 reason cites dead path" "Dead path" "$OUT"

# ============================================================================
# TEST 2: R-02 skill change protocol reminder
# ============================================================================
make_sbx
INPUT=$(jq -nc --arg fp "$SBX/.claude/skills/foo/SKILL.md" \
  '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:"x",new_string:"y"}}')
OUT=$(run_hook "$INPUT" "" "")
assert_decision "R-02 skill SKILL.md edit → ALLOW" "allow" "$OUT"
assert_ctx_contains "R-02 context cites change protocol" "SKILL CHANGE PROTOCOL" "$OUT"

# ============================================================================
# TEST 3: R-04 size guard hard limit DENY
# ============================================================================
make_sbx
GUARD_PATH="$SBX/vault/big.md"
mkdir -p "$(dirname "$GUARD_PATH")"
MANIFEST=$(jq -nc --arg gp "$GUARD_PATH" '{
  identity:{}, paths:{}, tools:{messaging:[]}, vault:{}, projects:{active:[]},
  people:[], behavioral:{hook_preferences:{}}, backlog:{}, architect:{},
  schema:{size_guards:[{path:$gp, hard_limit_bytes:100, message_template:"too big: {size}>{limit}"}]},
  system:{schema_version:"1.1.0", opt_outs:[]}
}')
BIG_CONTENT=$(printf 'x%.0s' $(seq 1 200))
INPUT=$(jq -nc --arg fp "$GUARD_PATH" --arg c "$BIG_CONTENT" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')
OUT=$(run_hook "$INPUT" "$MANIFEST" "")
assert_decision "R-04 size guard hard limit → DENY" "deny" "$OUT"
assert_reason_contains "R-04 size-guard reason interpolates" "too big" "$OUT"

# ============================================================================
# TEST 4: R-15 plan→backlog reminder
# ============================================================================
make_sbx
mkdir -p "$SBX/.claude-plans/99-test"
PLAN_FILE="$SBX/.claude-plans/99-test/spec.md"
INPUT=$(jq -nc --arg fp "$PLAN_FILE" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"---\ntype: spec\nstatus: planned\n---\n# Spec\n\n**Status:** planned"}}')
OUT=$(run_hook "$INPUT" "" "")
assert_decision "R-15 plan write → ALLOW" "allow" "$OUT"
assert_ctx_contains "R-15 context cites backlog reminder" "PLAN→BACKLOG" "$OUT"

# ============================================================================
# TEST 5: R-23 cron bash 4+ syntax → DENY
# ============================================================================
make_sbx
INPUT=$(jq -nc --arg fp "$SBX/.claude/orchestrator/cron-wrappers/foo.sh" \
  --arg c "#!/bin/bash"$'\n'"declare -A foo"$'\n'"foo[bar]=baz" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')
OUT=$(run_hook "$INPUT" "" "")
assert_decision "R-23 cron declare -A → DENY" "deny" "$OUT"
assert_reason_contains "R-23 reason cites bash 3.2" "bash 3.2" "$OUT"

# ============================================================================
# TEST 6: R-24 protected SessionEnd hook removal → DENY
# ============================================================================
make_sbx
echo '{"hooks":{"SessionEnd":[{"hooks":[{"command":"memory-consolidation-check.sh"}]}]}}' \
  > "$SBX/.claude/settings.json"
NEW_CONTENT='{"hooks":{}}'
INPUT=$(jq -nc --arg fp "$SBX/.claude/settings.json" --arg c "$NEW_CONTENT" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')
OUT=$(run_hook "$INPUT" "" "")
assert_decision "R-24 settings.json removes protected hook → DENY" "deny" "$OUT"
assert_reason_contains "R-24 reason cites protected hook" "Protected SessionEnd" "$OUT"

# ============================================================================
# TEST 7: R-27 plan missing NN- prefix → DENY
# ============================================================================
make_sbx
mkdir -p "$SBX/.claude-plans/no-prefix-plan"
INPUT=$(jq -nc --arg fp "$SBX/.claude-plans/no-prefix-plan/spec.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"# Plan\n**Status:** active"}}')
OUT=$(run_hook "$INPUT" "" "")
assert_decision "R-27 missing NN- prefix → DENY" "deny" "$OUT"
assert_reason_contains "R-27 reason cites NN- prefix" "NN-" "$OUT"

# ============================================================================
# TEST 8: R-27 plan missing status header → DENY
# ============================================================================
make_sbx
mkdir -p "$SBX/.claude-plans/01-numbered"
INPUT=$(jq -nc --arg fp "$SBX/.claude-plans/01-numbered/spec.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"# Plan with no status"}}')
OUT=$(run_hook "$INPUT" "" "")
assert_decision "R-27 missing status header → DENY" "deny" "$OUT"
assert_reason_contains "R-27 reason cites status marker" "status marker" "$OUT"

# ============================================================================
# TEST 9: R-28 sub-plan parent_plan suppresses R-15 backlog reminder
# ============================================================================
make_sbx
mkdir -p "$SBX/.claude-plans/01-parent/02-child"
INPUT=$(jq -nc --arg fp "$SBX/.claude-plans/01-parent/02-child/spec.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"---\nparent_plan: 01-parent\ntype: spec\n---\n**Status:** active"}}')
OUT=$(run_hook "$INPUT" "" "")
assert_decision "R-28 sub-plan with parent_plan → ALLOW" "allow" "$OUT"
CTX=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
case "$CTX" in
  *"PLAN→BACKLOG"*) record_fail "R-28 should suppress R-15 in sub-plans" "context wrongly contains PLAN→BACKLOG: $CTX" ;;
  *) record_pass "R-28 suppresses R-15 (no PLAN→BACKLOG in sub-plan)" ;;
esac

# ============================================================================
# TEST 10: R-32 unknown type in vault frontmatter → DENY
# ============================================================================
make_sbx
INPUT=$(jq -nc --arg fp "$SBX/vault/Engagements/x/People/Alice.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"---\ntype: completely-fake-type\n---\n"}}')
OUT=$(run_hook "$INPUT" "" "")
assert_decision "R-32 unknown type → DENY" "deny" "$OUT"
assert_reason_contains "R-32 reason cites schema allowlist" "R-32" "$OUT"

# ============================================================================
# TEST 11: R-33 folder placement advisory
# ============================================================================
make_sbx
# Schema entry for 'people' with placement pattern
cat > "$SBX/.claude/schemas/vault-schema.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "people": {"required": ["type", "name"], "_placement_pattern": "Engagements/*/People/*"},
  "_aliases": {}
}
JSON
INPUT=$(jq -nc --arg fp "$SBX/vault/wrongplace/Alice.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"---\ntype: people\nname: Alice\n---\n"}}')
OUT=$(run_hook "$INPUT" "" "")
assert_decision "R-33 type-path mismatch → ALLOW (advisory)" "allow" "$OUT"
assert_ctx_contains "R-33 context cites folder placement" "FOLDER PLACEMENT" "$OUT"

# ============================================================================
# TEST 12: R-40 plan-artifact missing canonical type → ALLOW with R-40 advisory
# ============================================================================
make_sbx
mkdir -p "$SBX/.claude-plans/01-good/spec"
INPUT=$(jq -nc --arg fp "$SBX/.claude-plans/01-good/spec.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"---\nstatus: active\n---\n# Spec\n\n**Status:** active"}}')
OUT=$(run_hook "$INPUT" "" "")
assert_decision "R-40 plan spec.md missing type → ALLOW" "allow" "$OUT"
assert_ctx_contains "R-40 context cites missing type" "R-40 PLAN FRONTMATTER" "$OUT"

# ============================================================================
# TEST 13: R-42 multi-session overlap advisory
# ============================================================================
make_sbx
mkdir -p "$SBX/vault/Logs/.coordination"
cat > "$SBX/vault/Logs/.coordination/session-registry.json" <<JSON
{"sessions": {"peer-sid-1234": {"touched_files": ["overlap.md"]}}}
JSON
INPUT=$(jq -nc --arg fp "$SBX/vault/overlap.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"---\ntype: people\nname: x\n---\n"}}')
OUT=$(run_hook "$INPUT" "" "CLAUDE_SESSION_ID=mine-5678")
DEC=$(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""')
CTX=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
# R-42 fires only after vault-schema branch passes; required fields present so should ALLOW + emit overlap context
case "$CTX" in
  *"MULTI-SESSION OVERLAP"*) record_pass "R-42 multi-session overlap → ALLOW with overlap context" ;;
  *) record_fail "R-42 multi-session overlap" "expected MULTI-SESSION OVERLAP context | got dec=$DEC ctx=$CTX" ;;
esac

# ============================================================================
# TEST 14: R-45 memory schema validation → audit JSONL appended
# ============================================================================
make_sbx
# Memory file under sandbox HOME's projects/-tmp-pwg…/memory dir
SLUG="$(echo "$SBX" | sed 's|/|-|g')"
MEM_DIR="$SBX/.claude/projects/${SLUG}/memory"
mkdir -p "$MEM_DIR"
INPUT=$(jq -nc --arg fp "$MEM_DIR/test_memory.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"---\nname: test\n---\nbody"}}')
# resolve_memory_dir uses $(pwd); cd into $SBX so cwd-slugify matches MEM_DIR's slug
OUT=$(cd "$SBX" && run_hook "$INPUT" "" "")
assert_decision "R-45 memory file with missing fields → ALLOW" "allow" "$OUT"
assert_ctx_contains "R-45 context cites schema check" "MEMORY SCHEMA CHECK" "$OUT"
if [ -s "$SBX/.claude/hooks/state/memory-schema-advisory-history.jsonl" ]; then
  record_pass "R-45 audit JSONL appended"
else
  record_fail "R-45 audit JSONL missing" "expected non-empty audit file"
fi

# ============================================================================
# TEST 15: R-54 doc-dependency cascade match
# ============================================================================
make_sbx
cat > "$SBX/.claude/hooks/config/doc-dependencies.json" <<'JSON'
{"version":2,"entries":[{"id":"test-cascade","kind":"doc","primary":"~/sample.md","mirrors":[{"file":"mirror.md","section":"intro"}]}]}
JSON
INPUT=$(jq -nc --arg fp "$SBX/sample.md" \
  '{tool_name:"Write",tool_input:{file_path:$fp,content:"x"}}')
OUT=$(run_hook "$INPUT" "" "")
assert_decision "R-54 doc-dep cascade match → ALLOW" "allow" "$OUT"
assert_ctx_contains "R-54 context cites cascade reminder" "DOC-DEPENDENCY CASCADE" "$OUT"

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
