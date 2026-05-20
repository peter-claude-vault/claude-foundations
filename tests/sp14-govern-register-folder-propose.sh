#!/usr/bin/env bash
# SP14 T-18 Theme B — /govern register folder mode propose
#
# Scope: process.sh propose --kind folder emits JSON payload matching the
# expected Class A shape (frontmatter.path_routing entry + mandatory_files.by_folder
# entry); does NOT write to overlay-master.json or governance-action-log.jsonl.
#
# Per Plan 81 SP14 spec.md §7 (test fixtures) + Batch H handoff (Session 8).
# Isolation per [[feedback_no_live_edits_during_foundation_repo_build]].
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"

# ---- jailed env -------------------------------------------------------------
TEMPROOT="$(mktemp -d -t sp14-folder-propose.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export VAULT_ROOT="$TEMPROOT/vault"
export CLAUDE_SESSION_ID="sp14-t18-folder-propose"
mkdir -p "$VAULT_ROOT"
echo '{}' > "$OVERLAY_MASTER"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 folder-propose ===\n'

# ---- invoke -----------------------------------------------------------------
OUT_FILE="$TEMPROOT/out.json"
bash "$FOUNDATION_REPO/skills/govern/register/process.sh" propose --kind folder --target Engagements >"$OUT_FILE" 2>"$TEMPROOT/err.txt"
RC=$?

if [ "$RC" = "0" ]; then
  emit_pass "rc=0"
else
  emit_fail "rc=$RC (expected 0); stderr: $(cat "$TEMPROOT/err.txt")"
fi

if jq empty "$OUT_FILE" >/dev/null 2>&1; then
  emit_pass "stdout is valid JSON"
else
  emit_fail "stdout is not valid JSON: $(cat "$OUT_FILE")"
fi

KIND=$(jq -r '.kind' "$OUT_FILE" 2>/dev/null)
[ "$KIND" = "folder" ] && emit_pass ".kind == folder" || emit_fail ".kind = '$KIND'"

TARGET=$(jq -r '.target' "$OUT_FILE" 2>/dev/null)
[ "$TARGET" = "Engagements" ] && emit_pass ".target == Engagements" || emit_fail ".target = '$TARGET'"

PILLAR_COUNT=$(jq '.pillars | length' "$OUT_FILE" 2>/dev/null)
[ "$PILLAR_COUNT" = "2" ] && emit_pass ".pillars[] has 2 entries (R-37 atomic pair)" || emit_fail ".pillars length = '$PILLAR_COUNT' (expected 2)"

P0=$(jq -r '.pillars[0].pillar' "$OUT_FILE" 2>/dev/null)
[ "$P0" = "frontmatter" ] && emit_pass ".pillars[0].pillar == frontmatter" || emit_fail ".pillars[0].pillar = '$P0'"

P1=$(jq -r '.pillars[1].pillar' "$OUT_FILE" 2>/dev/null)
[ "$P1" = "mandatory_files" ] && emit_pass ".pillars[1].pillar == mandatory_files" || emit_fail ".pillars[1].pillar = '$P1'"

PR_PATTERN=$(jq -r '.pillars[0].payload.path_routing[0].pattern' "$OUT_FILE" 2>/dev/null)
[ "$PR_PATTERN" = "Engagements/**" ] && emit_pass "path_routing pattern == Engagements/**" || emit_fail "path_routing pattern = '$PR_PATTERN'"

MF_KEY=$(jq -r '.pillars[1].payload.by_folder | keys[0]' "$OUT_FILE" 2>/dev/null)
[ "$MF_KEY" = "Engagements/**" ] && emit_pass "mandatory_files.by_folder key == Engagements/**" || emit_fail "mandatory_files.by_folder key = '$MF_KEY'"

# ---- assert NO mutations to overlay or action-log ---------------------------
OVERLAY_CONTENT=$(cat "$OVERLAY_MASTER")
[ "$OVERLAY_CONTENT" = "{}" ] && emit_pass "overlay-master.json UNCHANGED (propose does not commit)" || emit_fail "overlay-master.json mutated by propose: $OVERLAY_CONTENT"

LOG_BYTES=$(wc -c < "$ACTION_LOG" | tr -d ' ')
[ "$LOG_BYTES" = "0" ] && emit_pass "action-log UNCHANGED (propose does not append)" || emit_fail "action-log non-empty after propose ($LOG_BYTES bytes)"

# ---- summary ----------------------------------------------------------------
printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed checks:%b\n' "$FAILED_CHECKS"
  exit 1
fi
exit 0
