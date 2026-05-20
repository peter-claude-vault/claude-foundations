#!/usr/bin/env bash
# SP14 T-32 Theme C — writer-reconciler step 8.6 (manifest.sqlite row write).
#
# SUBSTRATE GAP NOTE (anchored to SPEC behavior; expected FAIL against current
# process.sh; signal documented for T-34 absorption):
#   SKILL.md step 8.6 (T-27): reconciler invokes
#   `bash $REPO_ROOT/lib/manifest-record.sh record-write` with derived
#   write_bucket (create | modify-append | modify-amend) after step 7
#   destination write. Current process.sh does NOT invoke manifest-record;
#   manifest.sqlite is never created from the reconciler runtime. Fixture
#   authored per spec; failure signals T-34.
#
# Per spec.md §7 + §8.6 + writer-pipeline-layering.md L-96 + L-104 + §A60.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
RECONCILER="$FOUNDATION_REPO/skills/writer-reconciler/process.sh"
RULES_FILE="$FOUNDATION_REPO/governance/vault-writers-rules.json"

TEMPROOT="$(mktemp -d -t sp14-reconciler-86.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT

export VAULT_ROOT="$TEMPROOT/vault"
export VAULT_WRITER_STATE_ROOT="$TEMPROOT/vault-writers"
export WRITER_MANIFEST_PATH="$VAULT_WRITER_STATE_ROOT/manifest.sqlite"
export STAGING_ROOT="$TEMPROOT/staging"
export CLAUDE_LOG_DIR="$TEMPROOT/logs"
mkdir -p "$VAULT_ROOT" "$VAULT_WRITER_STATE_ROOT" "$STAGING_ROOT" "$CLAUDE_LOG_DIR"

# Bootstrap manifest so a missing-DB doesn't mask the real signal (reconciler
# should still invoke manifest-record record-write per step 8.6).
bash "$FOUNDATION_REPO/lib/manifest-record.sh" init >/dev/null 2>&1

case "$STAGING_ROOT" in "$TEMPROOT"/*) ;; *) printf 'FATAL: STAGING_ROOT not jailed\n' >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS"$'\n'"    - $1"; }

printf '=== SP14 T-32 writer-reconciler-step8.6-manifest-row ===\n'
printf '          NOTE: anchored to spec; expect FAILs on step 8.6 assertions until T-34 lands\n'

# Stage packet for create write_bucket (no prior history at destination).
WRITER_ID="meeting-note-ingestor"
WRITER_DIR="$STAGING_ROOT/$WRITER_ID"
mkdir -p "$WRITER_DIR"
DEST="$VAULT_ROOT/Meetings/2026-05-20-create.md"
BODY="# Create Meeting"
PACKET_SHA=$(printf '%s' "$BODY" | shasum -a 256 | awk '{print $1}')
PACKET="$WRITER_DIR/$PACKET_SHA.json"

jq -nc \
  --arg pv "1.1" --arg w "$WRITER_ID" --arg ts "2026-05-20T12:00:00Z" \
  --arg dp "$DEST" --arg sha "$PACKET_SHA" --arg body "$BODY" \
  --arg ot "md" --arg pk "writer-emit" --arg src "granola-mtg-create" \
  '{packet_version:$pv,writer_id:$w,emitted_at:$ts,destination_path:$dp,content_sha256:$sha,body:$body,output_type:$ot,metadata:{},packet_kind:$pk,source_id:$src}' \
  > "$PACKET"

# Pre-state: manifest has 0 active rows
PRE_ROWS=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT COUNT(*) FROM writes WHERE status='active';" 2>/dev/null)
[ "$PRE_ROWS" = "0" ] && emit_pass "pre-state: manifest has 0 active rows" || emit_fail "pre-state row count=$PRE_ROWS (expected 0)"

bash "$RECONCILER" --rules-file "$RULES_FILE" --staging-root "$STAGING_ROOT" --audit-log "$CLAUDE_LOG_DIR/reconciler.log" >"$TEMPROOT/stdout" 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "reconciler exits 0" || emit_fail "reconciler rc=$RC: $(cat "$TEMPROOT/stderr")"

# Step 7 (destination write) — should PASS
[ -f "$DEST" ] && emit_pass "destination written (step 7)" || emit_fail "destination not written"

# ---- Step 8.6 assertions (EXPECT FAIL on current substrate) -----------------
POST_ROWS=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT COUNT(*) FROM writes WHERE status='active';" 2>/dev/null)
[ "$POST_ROWS" = "1" ] && emit_pass "manifest has 1 active row after reconcile (step 8.6)" || emit_fail "post-reconcile row count=$POST_ROWS (expected 1) — SUBSTRATE GAP: step 8.6 not implemented in process.sh; T-34"

# Verify row fields match packet contract
if [ "$POST_ROWS" = "1" ]; then
  ROW_ID=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT id FROM writes WHERE status='active' LIMIT 1;" 2>/dev/null)
  ROW_JSON=$(bash "$FOUNDATION_REPO/lib/manifest-record.sh" query-row --id "$ROW_ID" 2>/dev/null)
  ROW_OK=1
  for assertion in \
    ".writer_id == \"$WRITER_ID\"" \
    ".destination_path == \"$DEST\"" \
    ".content_sha256 == \"$PACKET_SHA\"" \
    '.write_bucket == "create"' \
    '.packet_kind == "writer-emit"' \
    '.source_id == "granola-mtg-create"' \
    '.status == "active"' \
    '.superseded_by == null'
  do
    if ! printf '%s' "$ROW_JSON" | jq -e "$assertion" >/dev/null 2>&1; then
      emit_fail "manifest row assertion failed: $assertion (got: $ROW_JSON)"
      ROW_OK=0
    fi
  done
  [ "$ROW_OK" = "1" ] && emit_pass "manifest row matches step 8.6 contract for write_bucket=create"
fi

# ---- Second packet at same destination → modify-append / modify-amend -------
sleep 1  # ensure ingestion_date differs
WRITER_DIR2="$STAGING_ROOT/$WRITER_ID"
DEST2="$DEST"  # same destination
BODY2="# Updated Meeting"
PACKET_SHA2=$(printf '%s' "$BODY2" | shasum -a 256 | awk '{print $1}')
PACKET2="$WRITER_DIR2/$PACKET_SHA2.json"

jq -nc \
  --arg pv "1.1" --arg w "$WRITER_ID" --arg ts "2026-05-20T12:05:00Z" \
  --arg dp "$DEST2" --arg sha "$PACKET_SHA2" --arg body "$BODY2" \
  --arg ot "md" --arg pk "writer-emit" \
  '{packet_version:$pv,writer_id:$w,emitted_at:$ts,destination_path:$dp,content_sha256:$sha,body:$body,output_type:$ot,metadata:{},packet_kind:$pk}' \
  > "$PACKET2"

bash "$RECONCILER" --rules-file "$RULES_FILE" --staging-root "$STAGING_ROOT" --audit-log "$CLAUDE_LOG_DIR/reconciler.log" >/dev/null 2>"$TEMPROOT/stderr3"

# After 2 writes at same destination: 1 active (latest) + 1 superseded
ACTIVE_AFTER=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT COUNT(*) FROM writes WHERE status='active';" 2>/dev/null)
SUPER_AFTER=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT COUNT(*) FROM writes WHERE status='superseded';" 2>/dev/null)
[ "$ACTIVE_AFTER" = "1" ] && emit_pass "1 active row after 2nd write (supersession applied)" || emit_fail "active count=$ACTIVE_AFTER after 2nd (expected 1) — SUBSTRATE GAP: step 8.6 supersession derivation not implemented; T-34"
[ "$SUPER_AFTER" = "1" ] && emit_pass "1 superseded row after 2nd write" || emit_fail "superseded count=$SUPER_AFTER after 2nd (expected 1) — SUBSTRATE GAP"

# write_bucket on 2nd active row should be modify-append or modify-amend (NOT create)
if [ "$ACTIVE_AFTER" = "1" ]; then
  BUCKET2=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT write_bucket FROM writes WHERE status='active' LIMIT 1;" 2>/dev/null)
  case "$BUCKET2" in
    modify-append|modify-amend) emit_pass "2nd row write_bucket=$BUCKET2 (correct for prior history)" ;;
    *) emit_fail "2nd row write_bucket=$BUCKET2 (expected modify-append or modify-amend)" ;;
  esac
fi

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%s\n' "$FAILED_CHECKS"; exit 1; }
exit 0
