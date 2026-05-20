#!/usr/bin/env bash
# SP14 T-18 Theme B — /govern register writer mode invalid --writer-kind
#
# Scope: propose --kind writer with invalid --writer-kind value is rejected
# with rc=2; no side effects.
#
# Per Plan 81 SP14 spec.md §7 + Batch H handoff smoke test #16.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"

TEMPROOT="$(mktemp -d -t sp14-writer-invalid.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export VAULT_ROOT="$TEMPROOT/vault"
export CLAUDE_SESSION_ID="sp14-t18-writer-invalid"
mkdir -p "$VAULT_ROOT/Vault Writers"
echo '{}' > "$OVERLAY_MASTER"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 writer-invalid-kind ===\n'

bash "$FOUNDATION_REPO/skills/govern/register/process.sh" propose --kind writer --writer-name foo --writer-kind bogus-kind >"$TEMPROOT/stdout" 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "2" ] && emit_pass "rc=2 (invalid --writer-kind rejected)" || emit_fail "rc=$RC (expected 2); stderr: $(cat "$TEMPROOT/stderr")"

if grep -q -i 'invalid --writer-kind' "$TEMPROOT/stderr" 2>/dev/null; then
  emit_pass "stderr mentions invalid --writer-kind"
else
  emit_fail "stderr does not mention 'invalid --writer-kind': $(cat "$TEMPROOT/stderr")"
fi

# No side effects
[ "$(cat "$OVERLAY_MASTER")" = "{}" ] && emit_pass "overlay UNCHANGED" || emit_fail "overlay mutated"
[ "$(wc -c < "$ACTION_LOG" | tr -d ' ')" = "0" ] && emit_pass "action-log UNCHANGED" || emit_fail "action-log appended"

WRITERS_DIR_FILES=$(find "$VAULT_ROOT/Vault Writers" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$WRITERS_DIR_FILES" = "0" ] && emit_pass "no writer-reference .md file written" || emit_fail "spurious files in Vault Writers/"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%b\n' "$FAILED_CHECKS"; exit 1; }
exit 0
