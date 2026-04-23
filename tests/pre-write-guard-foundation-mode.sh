#!/bin/bash
# tests/pre-write-guard-foundation-mode.sh
#
# SP00 T-4 synthetic test — FOUNDATION_TEST_MODE branch in pre-write-guard.sh.
#
# Acceptance criteria:
#   (a) FOUNDATION_TEST_MODE=0 + 5 existing R-rule cases → unchanged behavior
#       (R-32 DENY, R-40 advisory, R-45 advisory, librarian-manifest DENY,
#       neutral path fall-through)
#   (b) FOUNDATION_TEST_MODE=1 + write under $DOGFOOD_ROOT → ALLOW
#   (c) FOUNDATION_TEST_MODE=1 + write outside allowlist → DENY with
#       FOUNDATION_TEST_MODE diagnostic
#   (d) $HOOKS_STATE/foundation-test.log gets a parseable JSON line
#
# Exit codes:
#   0  all ACs green
#   1  one or more ACs failed (diagnostics on stderr)
#
# Invocation is side-effect-minimal: the hook reads input JSON and emits a
# decision; no files are written under the test paths. The hook does append to
# ~/Desktop/artefact-daily-logs/hook-audit.log for DENYs (expected audit
# behavior) and to $HOOKS_STATE/foundation-test.log for AC(d).

set -u

HOOK="$HOME/.claude/hooks/pre-write-guard.sh"
LOG="$HOME/.claude/hooks/state/foundation-test.log"
VAULT_ROOT="${VAULT_ROOT:-$HOME/Documents/Obsidian Vault}"
PLANS_DIR="${PLANS_DIR:-$HOME/.claude-plans}"

FAIL=0
PASS=0

ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n' "$1" >&2; printf '    got: %s\n' "$2" >&2; FAIL=$((FAIL + 1)); }

run_hook() {
  # args: input-json, [env k=v pairs after --]
  local input="$1"; shift
  env "$@" bash "$HOOK" <<<"$input" 2>/dev/null
}

section() { printf '\n== %s ==\n' "$1"; }

# -------- AC(a): FOUNDATION_TEST_MODE=0 baseline ----------------------------

section "AC(a) baseline — FOUNDATION_TEST_MODE unset"

# a.1 — R-32 DENY: vault .md with invented type
inp=$(jq -nc --arg fp "$VAULT_ROOT/Logs/t4-test-r32.md" '{
  tool_name: "Write",
  tool_input: {
    file_path: $fp,
    content: "---\ntype: wibble\ntitle: t\nlast_verified: 2026-04-22\n---\nbody\n"
  }
}')
out=$(run_hook "$inp")
if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
   && echo "$out" | grep -q 'R-32'; then
  ok "a.1 R-32 unknown-type DENY"
else
  fail "a.1 R-32 unknown-type DENY" "$out"
fi

# a.2 — R-40 advisory: plan spec.md missing type field
inp=$(jq -nc --arg fp "$PLANS_DIR/99-t4-synth-test/spec.md" '{
  tool_name: "Write",
  tool_input: {
    file_path: $fp,
    content: "---\ntitle: t\nstatus: draft\n---\nbody\n"
  }
}')
out=$(run_hook "$inp")
if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null \
   && echo "$out" | grep -q 'R-40'; then
  ok "a.2 R-40 missing-type advisory"
else
  fail "a.2 R-40 missing-type advisory" "$out"
fi

# a.3 — R-45 / memory schema: memory file with missing required fields
inp=$(jq -nc --arg fp "$HOME/.claude/projects/-Users-petertiktinsky/memory/t4_synth_test.md" '{
  tool_name: "Write",
  tool_input: {
    file_path: $fp,
    content: "---\nname: foo\n---\nbody\n"
  }
}')
out=$(run_hook "$inp")
if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null \
   && echo "$out" | grep -q 'MEMORY SCHEMA CHECK'; then
  ok "a.3 memory-schema advisory"
else
  fail "a.3 memory-schema advisory" "$out"
fi

# a.4 — librarian-manifest.json DENY
inp=$(jq -nc --arg fp "$VAULT_ROOT/Logs/librarian-manifest.json" '{
  tool_name: "Write",
  tool_input: { file_path: $fp, content: "{}" }
}')
out=$(run_hook "$inp")
if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
   && echo "$out" | grep -qi 'librarian-manifest'; then
  ok "a.4 librarian-manifest DENY"
else
  fail "a.4 librarian-manifest DENY" "$out"
fi

# a.5 — neutral fall-through: /tmp path outside any rule
inp=$(jq -nc '{
  tool_name: "Write",
  tool_input: { file_path: "/tmp/t4-synth-neutral.txt", content: "hi" }
}')
out=$(run_hook "$inp")
if [[ -z "$out" ]]; then
  ok "a.5 neutral path fall-through (no output)"
else
  fail "a.5 neutral path fall-through (no output)" "$out"
fi

# -------- AC(b): FOUNDATION_TEST_MODE=1 + DOGFOOD_ROOT → allow --------------

section "AC(b) FOUNDATION_TEST_MODE=1 + DOGFOOD_ROOT → allow"

DOGFOOD_DIR=$(mktemp -d -t foundation-test-t4-XXXXX)
trap 'rm -rf "$DOGFOOD_DIR"' EXIT INT TERM

inp=$(jq -nc --arg fp "$DOGFOOD_DIR/foo.md" '{
  tool_name: "Write",
  tool_input: { file_path: $fp, content: "hi" }
}')
out=$(run_hook "$inp" FOUNDATION_TEST_MODE=1 DOGFOOD_ROOT="$DOGFOOD_DIR")
if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null \
   && echo "$out" | grep -q 'FOUNDATION_TEST_MODE'; then
  ok "b.1 DOGFOOD_ROOT path → allow"
else
  fail "b.1 DOGFOOD_ROOT path → allow" "$out"
fi

# -------- AC(c): FOUNDATION_TEST_MODE=1 + disallowed path → deny ------------

section "AC(c) FOUNDATION_TEST_MODE=1 + disallowed path → deny"

# $HOME/notes.txt — under $HOME but outside $CLAUDE_HOME + $PLANS_DIR + DOGFOOD_ROOT
inp=$(jq -nc --arg fp "$HOME/notes.txt" '{
  tool_name: "Write",
  tool_input: { file_path: $fp, content: "hi" }
}')
out=$(run_hook "$inp" FOUNDATION_TEST_MODE=1 DOGFOOD_ROOT="$DOGFOOD_DIR")
if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
   && echo "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("FOUNDATION_TEST_MODE")' >/dev/null; then
  ok "c.1 \$HOME/notes.txt → deny with FOUNDATION_TEST_MODE diagnostic"
else
  fail "c.1 \$HOME/notes.txt → deny with FOUNDATION_TEST_MODE diagnostic" "$out"
fi

# /var/tmp outside allowlist (not /tmp/foundation-test-*)
inp=$(jq -nc '{
  tool_name: "Write",
  tool_input: { file_path: "/var/tmp/evil.txt", content: "hi" }
}')
out=$(run_hook "$inp" FOUNDATION_TEST_MODE=1 DOGFOOD_ROOT="$DOGFOOD_DIR")
if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null; then
  ok "c.2 /var/tmp path → deny"
else
  fail "c.2 /var/tmp path → deny" "$out"
fi

# FOUNDATION_TEST_MODE=1 + $CLAUDE_HOME path → allow (positive allowlist entry)
inp=$(jq -nc --arg fp "$HOME/.claude/hooks/state/foundation-test-probe.txt" '{
  tool_name: "Write",
  tool_input: { file_path: $fp, content: "hi" }
}')
out=$(run_hook "$inp" FOUNDATION_TEST_MODE=1 DOGFOOD_ROOT="$DOGFOOD_DIR")
if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null; then
  ok "c.3 \$CLAUDE_HOME path → allow"
else
  fail "c.3 \$CLAUDE_HOME path → allow" "$out"
fi

# -------- AC(d): log line parseable ----------------------------------------

section "AC(d) $LOG parseable"

if [[ ! -f "$LOG" ]]; then
  fail "d.1 foundation-test.log exists" "file not found at $LOG"
else
  # Last 5 lines should all be valid JSON
  bad=0
  total=0
  while IFS= read -r line; do
    total=$((total + 1))
    if ! echo "$line" | jq -e . >/dev/null 2>&1; then
      bad=$((bad + 1))
    fi
  done < <(tail -5 "$LOG")
  if [[ $bad -eq 0 ]] && [[ $total -gt 0 ]]; then
    ok "d.1 last $total log lines are valid JSON"
  else
    fail "d.1 log lines parseable" "$bad/$total malformed"
  fi

  # Verify last line has required schema fields
  last=$(tail -1 "$LOG")
  if echo "$last" | jq -e 'has("ts") and has("decision") and has("tool") and has("file") and has("reason") and has("dogfood_root")' >/dev/null 2>&1; then
    ok "d.2 last log line has required fields"
  else
    fail "d.2 last log line has required fields" "$last"
  fi
fi

# -------- Summary ----------------------------------------------------------

section "Summary"
printf 'pass=%d fail=%d\n' "$PASS" "$FAIL"
if [[ $FAIL -eq 0 ]]; then
  echo "RESULT: green"
  exit 0
else
  echo "RESULT: RED" >&2
  exit 1
fi
