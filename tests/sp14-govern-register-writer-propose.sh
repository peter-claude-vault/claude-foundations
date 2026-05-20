#!/usr/bin/env bash
# SP14 T-18 Theme B — /govern register writer mode propose (Class D)
#
# Scope: --writer-kind connector propose; conditional-required fields
# (source + authentication) injected per writer_kind.
#
# Per Plan 81 SP14 spec.md §7 + Batch H handoff smoke test #13.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"

TEMPROOT="$(mktemp -d -t sp14-writer-propose.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export VAULT_ROOT="$TEMPROOT/vault"
export CLAUDE_SESSION_ID="sp14-t18-writer-propose"
mkdir -p "$VAULT_ROOT/Vault Writers"
echo '{}' > "$OVERLAY_MASTER"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 writer-propose ===\n'

OUT="$TEMPROOT/out.json"
bash "$FOUNDATION_REPO/skills/govern/register/process.sh" propose --kind writer --writer-name granola-meetings --writer-kind connector --writer-subtype granola >"$OUT" 2>"$TEMPROOT/err"
RC=$?
[ "$RC" = "0" ] && emit_pass "propose rc=0" || emit_fail "rc=$RC; stderr: $(cat "$TEMPROOT/err")"

jq empty "$OUT" >/dev/null 2>&1 && emit_pass "stdout valid JSON" || emit_fail "stdout not valid JSON"

KIND=$(jq -r '.kind' "$OUT" 2>/dev/null)
[ "$KIND" = "writer" ] && emit_pass ".kind == writer" || emit_fail ".kind = '$KIND'"

TARGET=$(jq -r '.target' "$OUT" 2>/dev/null)
[ "$TARGET" = "granola-meetings" ] && emit_pass ".target == granola-meetings" || emit_fail ".target = '$TARGET'"

# vault_writers pillar with empty {} payload
HAS_VW_PILLAR=$(jq -e '.pillars[0].pillar == "vault_writers"' "$OUT" >/dev/null 2>&1 && echo yes || echo no)
[ "$HAS_VW_PILLAR" = "yes" ] && emit_pass ".pillars[0].pillar == vault_writers" || emit_fail "pillars[0].pillar mismatch"

EMPTY_PAYLOAD=$(jq -c '.pillars[0].payload' "$OUT" 2>/dev/null)
[ "$EMPTY_PAYLOAD" = "{}" ] && emit_pass "vault_writers payload is empty {}" || emit_fail "vault_writers payload = '$EMPTY_PAYLOAD'"

# writer_reference block — destination + frontmatter + body_template
DEST=$(jq -r '.writer_reference.destination' "$OUT" 2>/dev/null)
case "$DEST" in
  */Vault\ Writers/granola-meetings.md) emit_pass "writer_reference.destination = .../Vault Writers/granola-meetings.md" ;;
  *) emit_fail "writer_reference.destination = '$DEST'" ;;
esac

# Connector kind injects source + authentication
HAS_SOURCE=$(jq -e '.writer_reference.frontmatter.source' "$OUT" >/dev/null 2>&1 && echo yes || echo no)
[ "$HAS_SOURCE" = "yes" ] && emit_pass "connector kind injects .frontmatter.source" || emit_fail "source field missing for connector kind"

HAS_AUTH=$(jq -e '.writer_reference.frontmatter.authentication.method' "$OUT" >/dev/null 2>&1 && echo yes || echo no)
[ "$HAS_AUTH" = "yes" ] && emit_pass "connector kind injects .frontmatter.authentication" || emit_fail "authentication field missing"

WRITER_KIND=$(jq -r '.writer_reference.frontmatter.writer_kind' "$OUT" 2>/dev/null)
[ "$WRITER_KIND" = "connector" ] && emit_pass "frontmatter.writer_kind == connector" || emit_fail "writer_kind = '$WRITER_KIND'"

[ "$(cat "$OVERLAY_MASTER")" = "{}" ] && emit_pass "overlay UNCHANGED" || emit_fail "overlay mutated"
[ "$(wc -c < "$ACTION_LOG" | tr -d ' ')" = "0" ] && emit_pass "action-log UNCHANGED" || emit_fail "action-log appended"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%b\n' "$FAILED_CHECKS"; exit 1; }
exit 0
