#!/usr/bin/env bash
# SP14 T-18 Theme B — /govern register tag-extension mode propose
#
# Scope: single-pillar deep-merge propose; comma-list parsed via jq -R into
# JSON array.
#
# Per Plan 81 SP14 spec.md §7 + Batch H handoff smoke test #12.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"

TEMPROOT="$(mktemp -d -t sp14-tagext-propose.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export VAULT_ROOT="$TEMPROOT/vault"
export CLAUDE_SESSION_ID="sp14-t18-tagext-propose"
mkdir -p "$VAULT_ROOT"
echo '{}' > "$OVERLAY_MASTER"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 tagext-propose ===\n'

OUT="$TEMPROOT/out.json"
bash "$FOUNDATION_REPO/skills/govern/register/process.sh" propose --kind tag-extension --dimension delivery --values "spec,build, ship ,retro" >"$OUT" 2>"$TEMPROOT/err"
RC=$?
[ "$RC" = "0" ] && emit_pass "propose rc=0" || emit_fail "rc=$RC; stderr: $(cat "$TEMPROOT/err")"

jq empty "$OUT" >/dev/null 2>&1 && emit_pass "stdout valid JSON" || emit_fail "stdout not valid JSON: $(cat "$OUT")"

KIND=$(jq -r '.kind' "$OUT" 2>/dev/null)
[ "$KIND" = "tag-extension" ] && emit_pass ".kind == tag-extension" || emit_fail ".kind = '$KIND'"

TARGET=$(jq -r '.target' "$OUT" 2>/dev/null)
[ "$TARGET" = "delivery" ] && emit_pass ".target == delivery" || emit_fail ".target = '$TARGET'"

PILLAR_COUNT=$(jq '.pillars | length' "$OUT" 2>/dev/null)
[ "$PILLAR_COUNT" = "1" ] && emit_pass "single-pillar (no R-37 bundling)" || emit_fail ".pillars length = '$PILLAR_COUNT'"

PILLAR_NAME=$(jq -r '.pillars[0].pillar' "$OUT" 2>/dev/null)
[ "$PILLAR_NAME" = "tagging" ] && emit_pass ".pillars[0].pillar == tagging" || emit_fail "pillar = '$PILLAR_NAME'"

# values parsed into JSON array; whitespace trimmed
VALUES=$(jq -c '.pillars[0].payload.taxonomy.dimension_prefixes.delivery' "$OUT" 2>/dev/null)
EXPECTED='["spec","build","ship","retro"]'
[ "$VALUES" = "$EXPECTED" ] && emit_pass "comma-list parsed into JSON array, whitespace trimmed" || emit_fail "values = '$VALUES' (expected $EXPECTED)"

# overlay + action-log untouched
[ "$(cat "$OVERLAY_MASTER")" = "{}" ] && emit_pass "overlay UNCHANGED" || emit_fail "overlay mutated"
[ "$(wc -c < "$ACTION_LOG" | tr -d ' ')" = "0" ] && emit_pass "action-log UNCHANGED" || emit_fail "action-log appended"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%b\n' "$FAILED_CHECKS"; exit 1; }
exit 0
