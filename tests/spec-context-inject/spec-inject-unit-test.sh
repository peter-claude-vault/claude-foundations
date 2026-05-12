#!/bin/bash
# tests/spec-context-inject/spec-inject-unit-test.sh
#
# Synthetic unit test for spec-context-inject hook (Plan 81 SP09 T-5).
#
# Origin: Plan 81 SP01 Session 20 brief-vs-spec drift (2026-05-10). The hook
# injects authoritative sub-plan spec excerpts as additionalContext when a
# user prompt references an active sub-plan via path-pattern or "Plan N SPM"
# framing. See feedback_spec_authority_over_brief.md.
#
# Coverage:
#   1.  Path-based detection (Signal 1)
#   2.  SP-framing detection (Signal 2)
#   3.  Idempotency sentinel (per session × sub-plan)
#   4a. Status guard — closed
#   4b. Status guard — complete
#   4c. Status guard — superseded
#   5.  Garbage prompt silence
#   6.  Plan-N-only (no SP) silence
#   7.  Octal-parse fix (leading-zero SP num like SP09)
#   8.  Multi-digit SP num (SP15)
#   9.  Output JSON shape (hookEventName + additionalContext)
#   10. Output cap at ~9.5KB on oversized spec.md
#   11. Missing manifest.json — still injects (manifest absence ≠ status:closed)
#
# Isolation pattern (feedback_test_isolation_for_hooks_state.md):
#   The hook hardcodes $HOME/.claude/hooks/state and $HOME/.claude-plans (no
#   _OVERRIDE env vars). HOME override per sandbox gives equivalent isolation:
#   each test creates its own $HOME tmpdir with synthetic .claude-plans/ tree
#   + .claude/hooks/state/ dir. Real ~/.claude/ and ~/.claude-plans/ are never
#   touched. Sandbox cleanup via trap on EXIT/INT/TERM.
#
# Foundation-repo hook sources $SCRIPT_DIR/lib/registry.sh which transitively
# requires paths.sh/hook-journal.sh/validate-hook-output.sh. The fixture
# stages a minimal registry.sh stub in the sandbox's hooks/lib/ that defines
# format_output as the bare JSON envelope — sufficient to validate the hook's
# detection + content-build behavior without dragging in the full hook stack.
#
# R-23: bash 3.2 compat (macOS /bin/bash 3.2.57). No associative arrays, no
# [[ -v ]], no `local var=A var2=$var` chains.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_SRC="$REPO_ROOT/hooks/spec-context-inject.sh"

# --- harness ---
PASS=0
FAIL=0
TMPDIRS=""

cleanup() {
  for d in $TMPDIRS; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM

assert_eq() {
  expected="$1"; actual="$2"; label="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: expected=[%s] actual=[%s]\n' "$label" "$expected" "$actual" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  haystack="$1"; needle="$2"; label="$3"
  case "$haystack" in
    *"$needle"*)
      printf '  PASS %s\n' "$label"
      PASS=$((PASS+1))
      ;;
    *)
      printf '  FAIL %s (needle not found: %s)\n' "$label" "$needle" >&2
      FAIL=$((FAIL+1))
      ;;
  esac
}

assert_empty() {
  actual="$1"; label="$2"
  if [ -z "$actual" ]; then
    printf '  PASS %s (empty as expected)\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (expected empty, got %d bytes)\n' "$label" "${#actual}" >&2
    FAIL=$((FAIL+1))
  fi
}

# --- prereq sanity ---
if [ ! -x "$HOOK_SRC" ]; then
  printf 'FATAL: hook not executable at %s\n' "$HOOK_SRC" >&2
  exit 7
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'FATAL: jq required\n' >&2
  exit 7
fi

# --- sandbox builder ---
# mk_sandbox stages: $sandbox/hooks/{spec-context-inject.sh,lib/registry.sh}
#                    $sandbox/.claude/hooks/state/
#                    $sandbox/.claude-plans/
mk_sandbox() {
  d="$(mktemp -d -t spec-inject-test.XXXXXX)"
  TMPDIRS="$TMPDIRS $d"
  mkdir -p "$d/hooks/lib" "$d/.claude/hooks/state" "$d/.claude-plans"
  cp "$HOOK_SRC" "$d/hooks/spec-context-inject.sh"
  chmod +x "$d/hooks/spec-context-inject.sh"
  # Minimal stub for the hook's `source $SCRIPT_DIR/lib/registry.sh`.
  # Provides format_output as a bare jq-based JSON envelope emitter. Bypasses
  # the foundation lib's transitive deps (paths.sh, hook-journal.sh, validator).
  cat > "$d/hooks/lib/registry.sh" <<'STUB'
format_output() {
  evt="$1"
  ctx="$2"
  jq -n --arg event "$evt" --arg ctx "$ctx" \
    '{"hookSpecificOutput":{"hookEventName":$event,"additionalContext":$ctx}}'
  return 0
}
STUB
  printf '%s' "$d"
}

# mk_subplan sandbox plan-slug sp-slug status [spec_body_lines]
# Creates $sandbox/.claude-plans/<plan-slug>/{spec.md,<sp-slug>/{spec.md,manifest.json,00-ideation-brief.md}}
mk_subplan() {
  sandbox="$1"
  plan_slug="$2"
  sp_slug="$3"
  status="$4"
  body_lines="${5:-3}"
  plan_root="$sandbox/.claude-plans/$plan_slug"
  mkdir -p "$plan_root/$sp_slug"
  # Master spec.md
  cat > "$plan_root/spec.md" <<MASTER
---
title: Master $plan_slug
status: in-progress
---
# Master $plan_slug
Master spec head.
Authoritative sequencing claims live here.
MASTER
  # Sub-plan spec.md — body_lines controls length
  {
    printf -- '---\n'
    printf -- 'title: %s\n' "$sp_slug"
    printf -- 'status: %s\n' "$status"
    printf -- '---\n\n'
    printf -- '# %s spec\n' "$sp_slug"
    i=0
    while [ "$i" -lt "$body_lines" ]; do
      printf -- 'Authoritative sub-plan claim line %d. Critical sequencing detail.\n' "$i"
      i=$((i+1))
    done
  } > "$plan_root/$sp_slug/spec.md"
  # Sub-plan manifest.json
  jq -n --arg status "$status" --arg parent "$plan_slug" \
    '{status:$status, schema_version:1, parent_plan:$parent, sub_plan_id:"01", dependencies:[],
      tasks:[{id:"T-1", title:"Test task", status:"done", depends_on:[], acceptance_criteria:["ac1","ac2"], max_budget_usd:0}]}' \
    > "$plan_root/$sp_slug/manifest.json"
  # Sub-plan ideation brief
  cat > "$plan_root/$sp_slug/00-ideation-brief.md" <<BRIEF
# Ideation: $sp_slug
Failure mode being prevented.
Industry research excerpt.
BRIEF
}

# invoke_hook sandbox prompt [session_id]
# Pipes synthetic JSON {session_id, prompt} to the sandboxed hook.
# Returns stdout (the JSON additionalContext payload or empty on silence).
invoke_hook() {
  sandbox="$1"
  prompt="$2"
  sid="${3:-test-session-aaaa1111}"
  in_json=$(jq -n --arg sid "$sid" --arg p "$prompt" '{session_id:$sid,prompt:$p}')
  printf '%s' "$in_json" | HOME="$sandbox" bash "$sandbox/hooks/spec-context-inject.sh" 2>/dev/null
  return 0
}

# =====================================================================
# T1 — Path-based detection (Signal 1)
# =====================================================================
printf 'T1: path-based detection (Signal 1)\n'
SBOX1="$(mk_sandbox)"
mk_subplan "$SBOX1" "72-foo-plan" "01-bar-sub" "in-progress"
out1=$(invoke_hook "$SBOX1" "Working on ~/.claude-plans/72-foo-plan/01-bar-sub/spec.md right now")
hookEvt=$(printf '%s' "$out1" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
assert_eq "UserPromptSubmit" "$hookEvt" "T1.1: path-detection emits hookSpecificOutput.hookEventName=UserPromptSubmit"
ctx1=$(printf '%s' "$out1" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains "$ctx1" "SPEC AUTHORITY" "T1.2: payload contains SPEC AUTHORITY header"
assert_contains "$ctx1" "01-bar-sub/spec.md" "T1.3: payload references sub-plan spec.md by slug"
assert_contains "$ctx1" "01-bar-sub/manifest.json" "T1.4: payload references sub-plan manifest.json"
assert_contains "$ctx1" "Master 72-foo-plan" "T1.5: payload includes master plan spec excerpt"

# =====================================================================
# T2 — SP-framing detection (Signal 2)
# =====================================================================
printf 'T2: SP-framing detection (Signal 2)\n'
SBOX2="$(mk_sandbox)"
mk_subplan "$SBOX2" "73-baz-plan" "02-qux-sub" "in-progress"
out2=$(invoke_hook "$SBOX2" "Continue Plan 73 SP02 — finish the open AC")
hookEvt2=$(printf '%s' "$out2" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
assert_eq "UserPromptSubmit" "$hookEvt2" "T2.1: SP-framing emits hookEventName=UserPromptSubmit"
ctx2=$(printf '%s' "$out2" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains "$ctx2" "02-qux-sub" "T2.2: SP-framing resolves to 02-qux-sub directory"

# =====================================================================
# T3 — Idempotency sentinel
# =====================================================================
printf 'T3: idempotency sentinel (per session × sub-plan)\n'
SBOX3="$(mk_sandbox)"
mk_subplan "$SBOX3" "74-zog-plan" "01-blip-sub" "in-progress"
first=$(invoke_hook "$SBOX3" "~/.claude-plans/74-zog-plan/01-blip-sub/spec.md")
second=$(invoke_hook "$SBOX3" "~/.claude-plans/74-zog-plan/01-blip-sub/handoff.md")
firstEvt=$(printf '%s' "$first" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
assert_eq "UserPromptSubmit" "$firstEvt" "T3.1: first invocation injects"
assert_empty "$second" "T3.2: second invocation in same session is silent (sentinel works)"

# =====================================================================
# T4 — Status guards (closed/complete/superseded)
# =====================================================================
printf 'T4: status guards skip closed/complete/superseded\n'
SBOX4a="$(mk_sandbox)"
mk_subplan "$SBOX4a" "75-closed-plan" "01-x-sub" "closed"
out4a=$(invoke_hook "$SBOX4a" "~/.claude-plans/75-closed-plan/01-x-sub/spec.md")
assert_empty "$out4a" "T4.1: status=closed → silent"

SBOX4b="$(mk_sandbox)"
mk_subplan "$SBOX4b" "76-complete-plan" "01-y-sub" "complete"
out4b=$(invoke_hook "$SBOX4b" "~/.claude-plans/76-complete-plan/01-y-sub/spec.md")
assert_empty "$out4b" "T4.2: status=complete → silent"

SBOX4c="$(mk_sandbox)"
mk_subplan "$SBOX4c" "77-superseded-plan" "01-z-sub" "superseded"
out4c=$(invoke_hook "$SBOX4c" "~/.claude-plans/77-superseded-plan/01-z-sub/spec.md")
assert_empty "$out4c" "T4.3: status=superseded → silent"

# =====================================================================
# T5 — Garbage prompt silence
# =====================================================================
printf 'T5: garbage prompt silence\n'
SBOX5="$(mk_sandbox)"
out5=$(invoke_hook "$SBOX5" "hello world, just chatting")
assert_empty "$out5" "T5.1: garbage prompt with no plan reference → silent"

# =====================================================================
# T6 — Plan-N-only (no SP) silence
# =====================================================================
printf 'T6: "Plan N" without SP framing is silent\n'
SBOX6="$(mk_sandbox)"
mk_subplan "$SBOX6" "78-loose-plan" "01-w-sub" "in-progress"
out6=$(invoke_hook "$SBOX6" "What is the status of Plan 78 overall?")
assert_empty "$out6" "T6.1: bare Plan 78 mention → silent (no SP num)"

# =====================================================================
# T7 — Octal-parse fix (leading-zero SP num)
# =====================================================================
printf 'T7: octal-parse fix — leading-zero SP num like SP09\n'
SBOX7="$(mk_sandbox)"
mk_subplan "$SBOX7" "79-octal-plan" "09-leading-zero-sub" "in-progress"
out7=$(invoke_hook "$SBOX7" "Resume Plan 79 SP09 work")
hookEvt7=$(printf '%s' "$out7" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
assert_eq "UserPromptSubmit" "$hookEvt7" "T7.1: SP09 (leading zero) resolves via base-10 force"
ctx7=$(printf '%s' "$out7" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains "$ctx7" "09-leading-zero-sub" "T7.2: SP09 framing maps to 09-leading-zero-sub directory"

# =====================================================================
# T8 — Multi-digit SP num
# =====================================================================
printf 'T8: multi-digit SP num — SP15\n'
SBOX8="$(mk_sandbox)"
mk_subplan "$SBOX8" "80-multi-plan" "15-fifteenth-sub" "in-progress"
out8=$(invoke_hook "$SBOX8" "Continue Plan 80 SP15 — drive to close")
ctx8=$(printf '%s' "$out8" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains "$ctx8" "15-fifteenth-sub" "T8.1: SP15 framing resolves to 15-fifteenth-sub directory"

# =====================================================================
# T9 — Output JSON shape contract
# =====================================================================
printf 'T9: output JSON shape contract\n'
SBOX9="$(mk_sandbox)"
mk_subplan "$SBOX9" "81-shape-plan" "01-shape-sub" "in-progress"
out9=$(invoke_hook "$SBOX9" "~/.claude-plans/81-shape-plan/01-shape-sub/manifest.json")
# Top-level key
top_key=$(printf '%s' "$out9" | jq -r 'keys[0] // ""' 2>/dev/null)
assert_eq "hookSpecificOutput" "$top_key" "T9.1: top-level JSON key is hookSpecificOutput"
# hookEventName field
evt9=$(printf '%s' "$out9" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
assert_eq "UserPromptSubmit" "$evt9" "T9.2: hookEventName field equals UserPromptSubmit"
# additionalContext field non-empty
ctx9_len=$(printf '%s' "$out9" | jq -r '.hookSpecificOutput.additionalContext // "" | length' 2>/dev/null)
if [ "${ctx9_len:-0}" -gt 100 ]; then
  printf '  PASS T9.3: additionalContext is non-trivial (>100 chars; got %s)\n' "$ctx9_len"
  PASS=$((PASS+1))
else
  printf '  FAIL T9.3: additionalContext too short or absent (got %s chars)\n' "$ctx9_len" >&2
  FAIL=$((FAIL+1))
fi

# =====================================================================
# T10 — Output cap at ~9.5KB on oversized spec.md
# =====================================================================
# The hook reads head -80 of sub-plan spec.md, so line count alone is bounded.
# Use long lines to push first-80 past the 9728-byte cap (need ~12.2KB).
printf 'T10: output additionalContext capped near 9.5KB on oversized spec.md\n'
SBOX10="$(mk_sandbox)"
mk_subplan "$SBOX10" "82-big-plan" "01-big-sub" "in-progress" 3
# Overwrite spec.md with 80 long lines (~200 chars each → ~16KB head)
big_line="Authoritative claim XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
{
  printf -- '---\ntitle: 01-big-sub\nstatus: in-progress\n---\n\n'
  i=0
  while [ "$i" -lt 80 ]; do
    printf '%s line %d\n' "$big_line" "$i"
    i=$((i+1))
  done
} > "$SBOX10/.claude-plans/82-big-plan/01-big-sub/spec.md"
out10=$(invoke_hook "$SBOX10" "~/.claude-plans/82-big-plan/01-big-sub/spec.md")
ctx10_len=$(printf '%s' "$out10" | jq -r '.hookSpecificOutput.additionalContext // "" | length' 2>/dev/null)
# Cap is 9728 bytes; truncated payload ends at 9500 + marker. Allow ≤ 9728.
if [ "${ctx10_len:-0}" -gt 0 ] && [ "${ctx10_len:-0}" -le 9728 ]; then
  printf '  PASS T10.1: additionalContext within 9728-byte cap (got %s)\n' "$ctx10_len"
  PASS=$((PASS+1))
else
  printf '  FAIL T10.1: additionalContext violates cap (got %s, cap=9728)\n' "$ctx10_len" >&2
  FAIL=$((FAIL+1))
fi
ctx10=$(printf '%s' "$out10" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains "$ctx10" "truncated at 9.5KB" "T10.2: oversized payload carries truncation marker"

# =====================================================================
# T11 — Missing manifest.json (manifest absence ≠ closed status)
# =====================================================================
printf 'T11: missing manifest.json still injects (absence is not status:closed)\n'
SBOX11="$(mk_sandbox)"
mk_subplan "$SBOX11" "83-nomanifest-plan" "01-nm-sub" "in-progress"
rm -f "$SBOX11/.claude-plans/83-nomanifest-plan/01-nm-sub/manifest.json"
out11=$(invoke_hook "$SBOX11" "~/.claude-plans/83-nomanifest-plan/01-nm-sub/spec.md")
hookEvt11=$(printf '%s' "$out11" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
assert_eq "UserPromptSubmit" "$hookEvt11" "T11.1: missing manifest → still injects (status guard skips absent manifest)"

# =====================================================================
printf '\n=== spec-inject-unit-test ===\n'
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
