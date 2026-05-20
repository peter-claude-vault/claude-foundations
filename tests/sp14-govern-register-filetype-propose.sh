#!/usr/bin/env bash
# SP14 T-18 Theme B — /govern register file-type mode propose
#
# Scope: propose --kind file-type --name <slug> emits proposal with MV
# contract stub when --contract omitted; output has frontmatter.types[<type>]
# + file_type_contracts.<slug> pillars (R-37 atomic pair).
#
# Per Plan 81 SP14 spec.md §7 + Batch H handoff smoke test #10.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"

TEMPROOT="$(mktemp -d -t sp14-filetype-propose.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export VAULT_ROOT="$TEMPROOT/vault"
export CLAUDE_SESSION_ID="sp14-t18-filetype-propose"
mkdir -p "$VAULT_ROOT"
echo '{}' > "$OVERLAY_MASTER"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 filetype-propose ===\n'

OUT="$TEMPROOT/out.json"
bash "$FOUNDATION_REPO/skills/govern/register/process.sh" propose --kind file-type --name engagement-note >"$OUT" 2>"$TEMPROOT/err"
RC=$?
[ "$RC" = "0" ] && emit_pass "propose rc=0" || emit_fail "rc=$RC; stderr: $(cat "$TEMPROOT/err")"

jq empty "$OUT" >/dev/null 2>&1 && emit_pass "stdout valid JSON" || emit_fail "stdout not valid JSON: $(cat "$OUT")"

KIND=$(jq -r '.kind' "$OUT" 2>/dev/null)
[ "$KIND" = "file-type" ] && emit_pass ".kind == file-type" || emit_fail ".kind = '$KIND'"

TARGET=$(jq -r '.target' "$OUT" 2>/dev/null)
[ "$TARGET" = "engagement-note" ] && emit_pass ".target == engagement-note" || emit_fail ".target = '$TARGET'"

PILLAR_COUNT=$(jq '.pillars | length' "$OUT" 2>/dev/null)
[ "$PILLAR_COUNT" = "2" ] && emit_pass ".pillars has 2 entries (R-37 atomic pair)" || emit_fail ".pillars length = '$PILLAR_COUNT'"

# Confirm pillars include frontmatter and file_type_contracts
P0=$(jq -r '.pillars[0].pillar' "$OUT" 2>/dev/null)
P1=$(jq -r '.pillars[1].pillar' "$OUT" 2>/dev/null)
[ "$P0" = "frontmatter" ] && emit_pass ".pillars[0].pillar == frontmatter" || emit_fail ".pillars[0].pillar = '$P0'"
[ "$P1" = "file_type_contracts" ] && emit_pass ".pillars[1].pillar == file_type_contracts" || emit_fail ".pillars[1].pillar = '$P1'"

# types[] contains the slug
TYPE_SLUG=$(jq -r '.pillars[0].payload.types[0]' "$OUT" 2>/dev/null)
[ "$TYPE_SLUG" = "engagement-note" ] && emit_pass "frontmatter.types[0] == engagement-note" || emit_fail "frontmatter.types[0] = '$TYPE_SLUG'"

# file_type_contracts has key matching slug, with MV stub
HAS_KEY=$(jq -e '.pillars[1].payload."engagement-note"' "$OUT" >/dev/null 2>&1 && echo yes || echo no)
[ "$HAS_KEY" = "yes" ] && emit_pass "file_type_contracts.engagement-note present" || emit_fail "file_type_contracts.engagement-note missing"

# MV stub carries required + free_form body
HAS_REQUIRED=$(jq -e '.pillars[1].payload."engagement-note".frontmatter.required | contains(["type","tags","created","updated"])' "$OUT" >/dev/null 2>&1 && echo yes || echo no)
[ "$HAS_REQUIRED" = "yes" ] && emit_pass "MV stub: required includes [type,tags,created,updated]" || emit_fail "MV stub required mismatch"

HAS_FREE_FORM=$(jq -r '.pillars[1].payload."engagement-note".body.free_form' "$OUT" 2>/dev/null)
[ "$HAS_FREE_FORM" = "true" ] && emit_pass "MV stub: body.free_form == true" || emit_fail "body.free_form = '$HAS_FREE_FORM'"

# overlay + action-log untouched
[ "$(cat "$OVERLAY_MASTER")" = "{}" ] && emit_pass "overlay-master.json UNCHANGED" || emit_fail "overlay mutated"
[ "$(wc -c < "$ACTION_LOG" | tr -d ' ')" = "0" ] && emit_pass "action-log UNCHANGED" || emit_fail "action-log appended"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%b\n' "$FAILED_CHECKS"; exit 1; }
exit 0
