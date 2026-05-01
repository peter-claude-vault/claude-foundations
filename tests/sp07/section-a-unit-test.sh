#!/bin/bash
# tests/sp07/section-a-unit-test.sh — synthetic unit tests for SP07 T-2
# onboarding/ux/section-a.sh.
#
# Validates the 5 acceptance criteria from
# ~/.claude-plans/71-claude-foundations-engine-v2/07-onboarder-ux/tasks.md L58-63:
#
#   AC1 — Render discovery summary from filesystem scan
#   AC2 — Accept Enter-to-accept path + per-field inline edit path
#   AC3 — Honor opt-out #1 (discovery) producing valid empty discovery context
#   AC4 — Write staging JSON fragment for identity + tools + vault.root candidate
#   AC5 — Emit section-A JSONL audit entry with opt_outs[] populated
#
# Plus structural / reference-leak guardrails (R-37 single-deliverable + SKILL.md
# Hard Rule 9 reference-leak floor):
#
#   T-STRUCT-A — extraction-output-A.json conforms to extraction-prompts/section-A.md
#                shape (section_id="A", extraction_mode="deterministic",
#                empty confidence/source_spans, follow_up=null)
#   T-STRUCT-B — JSONL audit entry has all 9 expected keys per SKILL.md L141
#   T-STRUCT-C — corrections[] carries integers only (no user-typed strings)
#   T-STRUCT-D — manifest_paths_written list reflects actual emitted populated keys
#   T-STRUCT-E — quit path (q/Q) exits 130 cleanly, writes no files
#
# Hermetic: per-test fake $HOME with mock git config + mock settings.json +
# mock vault dir. Timezone + dev_env probes overridden via env vars; no
# /etc/localtime / no real `which` interference. Bash 3.2 clean (R-23).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/onboarding/ux/section-a.sh"

if [ ! -x "$SCRIPT" ]; then echo "FAIL: cannot exec $SCRIPT"; exit 2; fi

TEST_ROOT="$(mktemp -d -t section-a-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 — $2"; }

# Per-test fake $HOME. Sets up git config + settings.json + (optional) vault dir.
# $1 = fake home root
# $2 = git user.name
# $3 = git user.email
# $4 = settings.json content (JSON string)
# $5 = vault dir name to create under $1/Documents (empty = no vault)
setup_fake_home() {
  local hroot="$1"; local gn="$2"; local ge="$3"; local sj="$4"; local vault="$5"
  mkdir -p "$hroot/.claude/onboarding/audit"
  HOME="$hroot" git config --global user.name "$gn"
  HOME="$hroot" git config --global user.email "$ge"
  printf '%s\n' "$sj" > "$hroot/.claude/settings.json"
  if [ -n "$vault" ]; then
    mkdir -p "$hroot/Documents/$vault"
  fi
}

# Common env exports + script invocation.
# $1 = fake home root, remaining args appended to script.
run_script() {
  local hroot="$1"; shift
  HOME="$hroot" \
  CLAUDE_HOME="$hroot/.claude" \
  SETTINGS_JSON="$hroot/.claude/settings.json" \
  DISCOVERY_TZ_OVERRIDE="America/New_York" \
  DISCOVERY_DEV_ENV_OVERRIDE="code" \
  "$SCRIPT" "$@"
}

# stdin-driven invocation for interactive-path tests.
# $1 = fake home root, $2 = stdin string, remaining args appended.
run_script_stdin() {
  local hroot="$1"; local input="$2"; shift 2
  printf '%s' "$input" | run_script "$hroot" "$@"
}

# ---------- AC1 + AC4 + T-STRUCT-A: full happy path (Enter-accept) ----------
T1_HOME="$TEST_ROOT/t1"
SETTINGS_T1='{"mcpServers":{"slack":{},"google-calendar":{},"gmail":{},"granola":{},"asana":{}}}'
setup_fake_home "$T1_HOME" "Alice Tester" "alice@example.com" "$SETTINGS_T1" "Alice Vault"
T1_OUT="$TEST_ROOT/t1.out"
run_script "$T1_HOME" --auto-accept > "$T1_OUT" 2>&1
T1_RC=$?
T1_EXTRACT="$T1_HOME/.claude/onboarding/extraction-output-A.json"
T1_AUDIT="$T1_HOME/.claude/onboarding/audit/section-a.jsonl"

if [ "$T1_RC" -eq 0 ] && [ -f "$T1_EXTRACT" ] && [ -f "$T1_AUDIT" ]; then
  pass "AC1+AC4 happy path → both files written, rc=0"
else
  fail "AC1+AC4" "rc=$T1_RC, extract=$([ -f "$T1_EXTRACT" ] && echo y || echo n), audit=$([ -f "$T1_AUDIT" ] && echo y || echo n)"
fi

# T-STRUCT-A: extraction-output-A.json conforms to deterministic shape.
if jq -e '.section_id == "A" and .extraction_mode == "deterministic" and (.confidence == {}) and (.source_spans == {}) and (.missing_required == []) and (.conflicts == []) and (.follow_up == null)' "$T1_EXTRACT" >/dev/null 2>&1; then
  pass "T-STRUCT-A extraction-output shape (section-A.md contract)"
else
  fail "T-STRUCT-A" "shape diverges; got: $(cat "$T1_EXTRACT")"
fi

# AC1: discovery values landed in populated. Probes: git config + filesystem
# scan + MCP enumeration + tz override + dev_env override.
if jq -e --arg vault "$T1_HOME/Documents/Alice Vault" '
    .populated."U.identity.name" == "Alice Tester"
    and .populated."U.identity.email" == "alice@example.com"
    and .populated."U.system.timezone" == "America/New_York"
    and .populated."U.paths.vault_root" == $vault
    and .populated."U.vault.root" == $vault
    and .populated."U.tools.calendar" == "google-calendar"
    and .populated."U.tools.messaging" == ["slack"]
    and .populated."U.tools.email" == "gmail"
    and .populated."U.tools.transcription" == "granola"
    and .populated."U.tools.tasks" == "asana"
    and .populated."U.tools.dev_env" == "code"
  ' "$T1_EXTRACT" >/dev/null 2>&1; then
  pass "AC1 discovery summary populated from filesystem + git + MCP + tz/dev probes"
else
  fail "AC1-discovery" "populated diverges; got: $(jq -c '.populated' "$T1_EXTRACT")"
fi

# AC4: paths.vault_root + vault.root mirror landed.
if jq -e --arg v "$T1_HOME/Documents/Alice Vault" '
    .populated."U.paths.vault_root" == $v
    and .populated."U.vault.root" == $v
  ' "$T1_EXTRACT" >/dev/null 2>&1; then
  pass "AC4 staging JSON fragment carries identity + tools + vault.root candidate"
else
  fail "AC4-staging" "vault path mirror missing; got: $(jq -c '.populated | {pvr: ."U.paths.vault_root", vr: ."U.vault.root"}' "$T1_EXTRACT")"
fi

# AC5: audit entry has opt_outs:[] (empty when not opted out).
if jq -e '.opt_outs == [] and .section_id == "A" and .corrections == [] and .follow_ups == []' "$T1_AUDIT" >/dev/null 2>&1; then
  pass "AC5 audit JSONL emits opt_outs[] (empty on accept path)"
else
  fail "AC5-audit-accept" "audit shape diverges; got: $(cat "$T1_AUDIT")"
fi

# T-STRUCT-B: audit JSONL has all 9 keys per SKILL.md L141.
if jq -e '
    has("section_id") and has("run_id") and has("ts") and has("opt_outs")
    and has("confidence_map") and has("source_spans") and has("corrections")
    and has("follow_ups") and has("manifest_paths_written")
  ' "$T1_AUDIT" >/dev/null 2>&1; then
  pass "T-STRUCT-B audit JSONL carries all 9 SKILL.md L141 fields"
else
  fail "T-STRUCT-B" "audit missing required keys; got: $(cat "$T1_AUDIT")"
fi

# T-STRUCT-D: manifest_paths_written includes every populated key + the
# always-emitted vault paths.
if jq -e '
    (.manifest_paths_written | sort) == ([
      "U.identity.name","U.identity.email","U.system.timezone",
      "U.paths.vault_root","U.vault.root",
      "U.tools.calendar","U.tools.messaging","U.tools.email",
      "U.tools.transcription","U.tools.tasks","U.tools.dev_env"
    ] | sort)
  ' "$T1_AUDIT" >/dev/null 2>&1; then
  pass "T-STRUCT-D manifest_paths_written reflects emitted populated keys"
else
  fail "T-STRUCT-D" "got: $(jq -c '.manifest_paths_written' "$T1_AUDIT")"
fi

# ---------- AC2: per-field inline edit path ----------
T2_HOME="$TEST_ROOT/t2"
setup_fake_home "$T2_HOME" "Alice Tester" "alice@example.com" "$SETTINGS_T1" "Alice Vault"
# Edit field 1 (Name → "Bob Edited") + field 3 (Timezone → "Europe/Paris"),
# then accept. \n is the Enter-accept terminator.
T2_INPUT='1
Bob Edited
3
Europe/Paris

'
T2_OUT="$TEST_ROOT/t2.out"
run_script_stdin "$T2_HOME" "$T2_INPUT" > "$T2_OUT" 2>&1
T2_RC=$?
T2_EXTRACT="$T2_HOME/.claude/onboarding/extraction-output-A.json"
T2_AUDIT="$T2_HOME/.claude/onboarding/audit/section-a.jsonl"

if [ "$T2_RC" -eq 0 ] \
   && jq -e '.populated."U.identity.name" == "Bob Edited" and .populated."U.system.timezone" == "Europe/Paris" and .populated."U.identity.email" == "alice@example.com"' "$T2_EXTRACT" >/dev/null 2>&1; then
  pass "AC2 per-field inline edit applied to fields 1 + 3; field 2 untouched"
else
  fail "AC2-edit" "rc=$T2_RC; populated=$(jq -c '.populated' "$T2_EXTRACT" 2>/dev/null)"
fi

# T-STRUCT-C: corrections[] carries integers only (no user strings).
if jq -e '.corrections == [1,3] and (.corrections | all(type == "number"))' "$T2_AUDIT" >/dev/null 2>&1; then
  pass "T-STRUCT-C corrections[] is integer-only (reference-leak floor)"
else
  fail "T-STRUCT-C" "corrections=$(jq -c '.corrections' "$T2_AUDIT")"
fi

# AC2 also covers Enter-to-accept — verified by AC1 happy path above (which
# uses --auto-accept). Add an explicit interactive Enter-accept run for full
# AC2 coverage.
T2B_HOME="$TEST_ROOT/t2b"
setup_fake_home "$T2B_HOME" "Carol Tester" "carol@example.com" "$SETTINGS_T1" ""
T2B_OUT="$TEST_ROOT/t2b.out"
printf '\n' | run_script "$T2B_HOME" > "$T2B_OUT" 2>&1
T2B_RC=$?
T2B_EXTRACT="$T2B_HOME/.claude/onboarding/extraction-output-A.json"
T2B_AUDIT="$T2B_HOME/.claude/onboarding/audit/section-a.jsonl"
if [ "$T2B_RC" -eq 0 ] \
   && jq -e '.populated."U.identity.name" == "Carol Tester"' "$T2B_EXTRACT" >/dev/null 2>&1 \
   && jq -e '.corrections == []' "$T2B_AUDIT" >/dev/null 2>&1; then
  pass "AC2 Enter-to-accept (interactive stdin) preserves all discovery values"
else
  fail "AC2-enter-accept" "rc=$T2B_RC; corrections=$(jq -c '.corrections' "$T2B_AUDIT" 2>/dev/null)"
fi

# ---------- AC3 + AC5: opt-out #1 path ----------
T3_HOME="$TEST_ROOT/t3"
setup_fake_home "$T3_HOME" "Dave Opt-Out" "dave@example.com" "$SETTINGS_T1" "Dave Vault"
T3_OUT="$TEST_ROOT/t3.out"
run_script "$T3_HOME" --auto-opt-out > "$T3_OUT" 2>&1
T3_RC=$?
T3_EXTRACT="$T3_HOME/.claude/onboarding/extraction-output-A.json"
T3_AUDIT="$T3_HOME/.claude/onboarding/audit/section-a.jsonl"

# AC3: opt-out path exits cleanly + produces empty discovery context.
if [ "$T3_RC" -eq 0 ] \
   && jq -e '.populated == {"U.system.opt_outs": ["discovery_skipped"]} and .extraction_mode == "deterministic"' "$T3_EXTRACT" >/dev/null 2>&1; then
  pass "AC3 opt-out #1 → empty discovery context + system.opt_outs append"
else
  fail "AC3-opt-out" "rc=$T3_RC; populated=$(jq -c '.populated' "$T3_EXTRACT" 2>/dev/null)"
fi

# AC3 boundary: NO identity/tools/vault keys leaked into populated under opt-out.
LEAK_KEYS="$(jq -r '.populated | keys[] | select(. != "U.system.opt_outs")' "$T3_EXTRACT" 2>/dev/null)"
if [ -z "$LEAK_KEYS" ]; then
  pass "AC3-boundary opt-out populated contains ONLY system.opt_outs"
else
  fail "AC3-boundary" "leaked keys: $LEAK_KEYS"
fi

# AC5 on opt-out: audit opt_outs[] populated with discovery_skipped.
if jq -e '.opt_outs == ["discovery_skipped"] and .manifest_paths_written == ["U.system.opt_outs"]' "$T3_AUDIT" >/dev/null 2>&1; then
  pass "AC5 audit JSONL records discovery_skipped + minimal manifest_paths"
else
  fail "AC5-opt-out-audit" "audit=$(cat "$T3_AUDIT")"
fi

# AC3 interactive opt-out (typed 'o' at prompt) — exercises the interactive path.
T3B_HOME="$TEST_ROOT/t3b"
setup_fake_home "$T3B_HOME" "Eve User" "eve@example.com" "$SETTINGS_T1" ""
printf 'o\n' | run_script "$T3B_HOME" > /dev/null 2>&1
T3B_RC=$?
T3B_AUDIT="$T3B_HOME/.claude/onboarding/audit/section-a.jsonl"
if [ "$T3B_RC" -eq 0 ] && jq -e '.opt_outs == ["discovery_skipped"]' "$T3B_AUDIT" >/dev/null 2>&1; then
  pass "AC3 interactive 'o' input elects opt-out from prompt"
else
  fail "AC3-interactive-opt-out" "rc=$T3B_RC; audit=$(cat "$T3B_AUDIT" 2>&1)"
fi

# ---------- T-STRUCT-E: quit path ----------
T4_HOME="$TEST_ROOT/t4"
setup_fake_home "$T4_HOME" "Frank Quit" "frank@example.com" "$SETTINGS_T1" ""
printf 'q\n' | run_script "$T4_HOME" > /dev/null 2>&1
T4_RC=$?
T4_EXTRACT="$T4_HOME/.claude/onboarding/extraction-output-A.json"
T4_AUDIT="$T4_HOME/.claude/onboarding/audit/section-a.jsonl"
if [ "$T4_RC" -eq 130 ] && [ ! -f "$T4_EXTRACT" ] && [ ! -f "$T4_AUDIT" ]; then
  pass "T-STRUCT-E quit path → exit 130, no files written"
else
  fail "T-STRUCT-E" "rc=$T4_RC; extract_exists=$([ -f "$T4_EXTRACT" ] && echo y || echo n); audit_exists=$([ -f "$T4_AUDIT" ] && echo y || echo n)"
fi

# ---------- AC1 boundary: missing probes (no vault, empty MCPs) emit explicit nulls ----------
T5_HOME="$TEST_ROOT/t5"
setup_fake_home "$T5_HOME" "Grace Empty" "grace@example.com" '{"mcpServers":{}}' ""
run_script "$T5_HOME" --auto-accept > /dev/null 2>&1
T5_EXTRACT="$T5_HOME/.claude/onboarding/extraction-output-A.json"
if jq -e '
    .populated."U.paths.vault_root" == null
    and .populated."U.vault.root" == null
    and .populated."U.tools.messaging" == []
    and (.populated | has("U.tools.calendar") | not)
  ' "$T5_EXTRACT" >/dev/null 2>&1; then
  pass "AC1-boundary empty probes → vault explicit null + empty messaging + missing tools"
else
  fail "AC1-boundary" "populated=$(jq -c '.populated' "$T5_EXTRACT")"
fi

# ---------- summary ----------
echo "=== section-a-unit-test ==="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
