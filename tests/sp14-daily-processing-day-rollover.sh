#!/usr/bin/env bash
# SP14 T-32 Theme C — daily-processing JSONL day-rollover immutability.
#
# SUBSTRATE GAP NOTE (anchored to SPEC behavior; expected FAIL against current
# process.sh; signal documented for T-34 absorption):
#   SKILL.md step 8.5 (L-100 day-rollover immutability): filename keyed by UTC
#   date at append time; active file freezes at midnight UTC; new day starts
#   empty; archived-not-cleared lifecycle. This fixture pre-populates
#   "yesterday's" JSONL then runs the reconciler "today"; asserts (a)
#   yesterday's file unchanged + (b) today's file created with only today's
#   row. Current process.sh does NOT implement step 8.5, so today's file
#   never gets created — clear T-34 signal.
#
# Per spec.md §7 + writer-pipeline-layering.md L-100..L-104 + §A61.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
RECONCILER="$FOUNDATION_REPO/skills/writer-reconciler/process.sh"
RULES_FILE="$FOUNDATION_REPO/governance/vault-writers-rules.json"

TEMPROOT="$(mktemp -d -t sp14-rollover.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT

export VAULT_ROOT="$TEMPROOT/vault"
export VAULT_WRITER_STATE_ROOT="$TEMPROOT/vault-writers"
export STAGING_ROOT="$TEMPROOT/staging"
export CLAUDE_LOG_DIR="$TEMPROOT/logs"
mkdir -p "$VAULT_ROOT" "$VAULT_WRITER_STATE_ROOT" "$STAGING_ROOT" "$CLAUDE_LOG_DIR"

case "$STAGING_ROOT" in "$TEMPROOT"/*) ;; *) printf 'FATAL: STAGING_ROOT not jailed\n' >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS"$'\n'"    - $1"; }

printf '=== SP14 T-32 daily-processing-day-rollover ===\n'
printf '          NOTE: anchored to spec; expect FAILs until step 8.5 lands (T-34)\n'

TODAY=$(date -u +%Y-%m-%d)
# "Yesterday" computed via date arithmetic (macOS BSD date + GNU fallback).
YESTERDAY=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null)
if [ -z "$YESTERDAY" ]; then
  emit_fail "could not compute yesterday's UTC date"
  printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
  exit 1
fi

WRITER_ID="meeting-note-ingestor"
DEST="$VAULT_ROOT/Meetings/rollover-test.md"
DEST_SLUG=$(printf '%s' "$DEST" | sed 's|^/||; s|/|_|g; s/ /_/g; s/\./_/g')

YESTERDAY_DIR="$VAULT_WRITER_STATE_ROOT/daily-processing/$YESTERDAY"
TODAY_DIR="$VAULT_WRITER_STATE_ROOT/daily-processing/$TODAY"
YESTERDAY_JSONL="$YESTERDAY_DIR/$DEST_SLUG.jsonl"
TODAY_JSONL="$TODAY_DIR/$DEST_SLUG.jsonl"

# Pre-populate yesterday's frozen archive with a synthetic row.
mkdir -p "$YESTERDAY_DIR"
YESTERDAY_ROW='{"ts":"'"$YESTERDAY"'T23:59:00Z","packet_sha":"old-sha","writer_id":"'"$WRITER_ID"'","destination_path":"'"$DEST"'","content_sha256":"old-content-sha","output_type":"md","packet_kind":"writer-emit","write_bucket":"create"}'
printf '%s\n' "$YESTERDAY_ROW" > "$YESTERDAY_JSONL"
YESTERDAY_PRE_SHA=$(shasum -a 256 "$YESTERDAY_JSONL" | awk '{print $1}')
[ -f "$YESTERDAY_JSONL" ] && emit_pass "pre-seed: yesterday's JSONL exists" || emit_fail "yesterday's JSONL pre-seed failed"

# Stage a packet today.
WRITER_DIR="$STAGING_ROOT/$WRITER_ID"
mkdir -p "$WRITER_DIR"
BODY="# Today's Write"
PACKET_SHA=$(printf '%s' "$BODY" | shasum -a 256 | awk '{print $1}')
PACKET="$WRITER_DIR/$PACKET_SHA.json"

jq -nc \
  --arg pv "1.1" --arg w "$WRITER_ID" --arg ts "${TODAY}T12:00:00Z" \
  --arg dp "$DEST" --arg sha "$PACKET_SHA" --arg body "$BODY" \
  --arg ot "md" --arg pk "writer-emit" \
  '{packet_version:$pv,writer_id:$w,emitted_at:$ts,destination_path:$dp,content_sha256:$sha,body:$body,output_type:$ot,metadata:{},packet_kind:$pk}' \
  > "$PACKET"

bash "$RECONCILER" --rules-file "$RULES_FILE" --staging-root "$STAGING_ROOT" --audit-log "$CLAUDE_LOG_DIR/reconciler.log" >/dev/null 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "reconciler exits 0" || emit_fail "reconciler rc=$RC: $(cat "$TEMPROOT/stderr")"

# Step 7 (destination write) — should PASS
[ -f "$DEST" ] && emit_pass "destination written (step 7)" || emit_fail "destination not written"

# ---- Day-rollover invariant: yesterday's file UNCHANGED ---------------------
[ -f "$YESTERDAY_JSONL" ] && emit_pass "yesterday's JSONL still present (archived-not-cleared)" || emit_fail "yesterday's JSONL deleted"
YESTERDAY_POST_SHA=$(shasum -a 256 "$YESTERDAY_JSONL" 2>/dev/null | awk '{print $1}')
[ "$YESTERDAY_POST_SHA" = "$YESTERDAY_PRE_SHA" ] && emit_pass "yesterday's JSONL bytes UNCHANGED (frozen archive)" || emit_fail "yesterday's JSONL mutated (immutability violated)"

# Yesterday's file still has exactly 1 row
YESTERDAY_LINES=$(wc -l < "$YESTERDAY_JSONL" 2>/dev/null | tr -d ' ')
[ "$YESTERDAY_LINES" = "1" ] && emit_pass "yesterday's JSONL still has 1 row" || emit_fail "yesterday line count=$YESTERDAY_LINES (expected 1)"

# ---- Today's file: created + contains only today's row ----------------------
[ -d "$TODAY_DIR" ] && emit_pass "today's daily-processing dir exists" || emit_fail "today's dir missing: $TODAY_DIR (SUBSTRATE GAP — step 8.5 not implemented; T-34)"
[ -f "$TODAY_JSONL" ] && emit_pass "today's JSONL created" || emit_fail "today's JSONL missing (SUBSTRATE GAP — step 8.5 not implemented; T-34)"

if [ -f "$TODAY_JSONL" ]; then
  TODAY_LINES=$(wc -l < "$TODAY_JSONL" 2>/dev/null | tr -d ' ')
  [ "$TODAY_LINES" = "1" ] && emit_pass "today's JSONL has exactly 1 row (clean start)" || emit_fail "today line count=$TODAY_LINES (expected 1)"
  TODAY_ROW=$(head -1 "$TODAY_JSONL")
  if printf '%s' "$TODAY_ROW" | jq -e ".content_sha256 == \"$PACKET_SHA\"" >/dev/null 2>&1; then
    emit_pass "today's row references current packet sha (not yesterday's)"
  else
    emit_fail "today's row sha drift: $TODAY_ROW"
  fi
fi

# ---- Filename keyed by UTC date at append time ------------------------------
# Today's filename includes today's date, NOT yesterday's
case "$TODAY_JSONL" in
  *"$TODAY"*) emit_pass "today's filename contains today's UTC date" ;;
  *) emit_fail "today's filename does not contain today's date: $TODAY_JSONL" ;;
esac
case "$TODAY_JSONL" in
  *"$YESTERDAY"*) emit_fail "today's filename accidentally contains yesterday's date" ;;
  *) emit_pass "today's filename does NOT contain yesterday's date (clean rollover)" ;;
esac

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%s\n' "$FAILED_CHECKS"; exit 1; }
exit 0
