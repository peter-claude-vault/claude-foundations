#!/usr/bin/env bash
# SP14 T-32 Theme C — writer-reconciler tick step 8.5 (daily-processing JSONL).
#
# SUBSTRATE GAP NOTE (anchored to SPEC behavior; expected FAIL against current
# process.sh; signal documented for T-34 absorption):
#   SKILL.md (T-27 LANDED Batch E+F 2026-05-19) documents step 8.5: reconciler
#   appends one row per reconciled write to
#   `$VAULT_WRITER_STATE_ROOT/daily-processing/YYYY-MM-DD/<destination-slug>.jsonl`
#   with row shape `{ts, packet_sha, writer_id, destination_path,
#   content_sha256, output_type, packet_kind, write_bucket}`. Current
#   process.sh (Batch B baseline) does NOT yet implement step 8.5 — no
#   reference to daily-processing or VAULT_WRITER_STATE_ROOT anywhere in the
#   runtime. This fixture is authored per spec; failure signals T-34 work
#   item (implement step 8.5 + 8.6 in process.sh; ~80-120 LOC).
#
# Per spec.md §7 + §8.6 + writer-pipeline-layering.md L-99..L-104 + §A61.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
RECONCILER="$FOUNDATION_REPO/skills/writer-reconciler/process.sh"
RULES_FILE="$FOUNDATION_REPO/governance/vault-writers-rules.json"

TEMPROOT="$(mktemp -d -t sp14-reconciler-85.XXXXXX)"
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

printf '=== SP14 T-32 writer-reconciler-tick-step8.5 ===\n'
printf '          NOTE: anchored to spec; expect FAILs on step 8.5 assertions until T-34 lands\n'

# Stage one packet (writer-emit, output_type=md).
WRITER_ID="meeting-note-ingestor"
WRITER_DIR="$STAGING_ROOT/$WRITER_ID"
mkdir -p "$WRITER_DIR"
DEST="$VAULT_ROOT/Meetings/2026-05-20-standup.md"
BODY="# Test Meeting"$'\n\n'"body"
PACKET_SHA=$(printf '%s' "$BODY" | shasum -a 256 | awk '{print $1}')
PACKET="$WRITER_DIR/$PACKET_SHA.json"

jq -nc \
  --arg pv "1.1" \
  --arg w "$WRITER_ID" \
  --arg ts "2026-05-20T12:00:00Z" \
  --arg dp "$DEST" \
  --arg sha "$PACKET_SHA" \
  --arg body "$BODY" \
  --arg ot "markdown" \
  --arg pk "writer-emit" \
  '{packet_version:$pv,writer_id:$w,emitted_at:$ts,destination_path:$dp,content_sha256:$sha,body:$body,output_type:$ot,metadata:{},packet_kind:$pk}' \
  > "$PACKET"

[ -f "$PACKET" ] && emit_pass "packet staged at $PACKET" || emit_fail "packet staging failed"

# Run reconciler
bash "$RECONCILER" --rules-file "$RULES_FILE" --staging-root "$STAGING_ROOT" --audit-log "$CLAUDE_LOG_DIR/reconciler.log" >"$TEMPROOT/stdout" 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "reconciler exits 0" || emit_fail "reconciler rc=$RC: $(cat "$TEMPROOT/stderr")"

# Step 7 (destination write) — should PASS regardless of step 8.5 status
[ -f "$DEST" ] && emit_pass "destination file written (step 7)" || emit_fail "destination not written: $DEST"
DEST_CONTENT=$(cat "$DEST" 2>/dev/null)
[ "$DEST_CONTENT" = "$BODY" ] && emit_pass "destination content matches packet body" || emit_fail "destination content drift"

# Step 8 (packet removed) — should PASS
[ ! -f "$PACKET" ] && emit_pass "processed packet removed (step 8)" || emit_fail "packet still in staging: $PACKET"

# ---- Step 8.5 assertions (EXPECT FAIL on current substrate) -----------------
TODAY=$(date -u +%Y-%m-%d)
DAILY_DIR="$VAULT_WRITER_STATE_ROOT/daily-processing/$TODAY"

# Destination-slug derivation per SKILL.md: strip leading /, replace / and space and . with _
DEST_SLUG=$(printf '%s' "$DEST" | sed 's|^/||; s|/|_|g; s/ /_/g; s/\./_/g')
JSONL_FILE="$DAILY_DIR/$DEST_SLUG.jsonl"

[ -d "$DAILY_DIR" ] && emit_pass "daily-processing dir created for today (step 8.5)" || emit_fail "daily-processing dir missing: $DAILY_DIR (SUBSTRATE GAP — step 8.5 not implemented in process.sh; T-34)"
[ -f "$JSONL_FILE" ] && emit_pass "daily-processing JSONL exists" || emit_fail "JSONL missing: $JSONL_FILE (SUBSTRATE GAP — step 8.5 not implemented)"

if [ -f "$JSONL_FILE" ]; then
  ROW=$(head -1 "$JSONL_FILE")
  ROW_OK=1
  for assertion in \
    ".writer_id == \"$WRITER_ID\"" \
    ".destination_path == \"$DEST\"" \
    ".content_sha256 == \"$PACKET_SHA\"" \
    '.output_type == "markdown"' \
    '.packet_kind == "writer-emit"' \
    '.write_bucket == "create"'
  do
    if ! printf '%s' "$ROW" | jq -e "$assertion" >/dev/null 2>&1; then
      emit_fail "JSONL row assertion failed: $assertion (got: $ROW)"
      ROW_OK=0
    fi
  done
  [ "$ROW_OK" = "1" ] && emit_pass "JSONL row matches step 8.5 contract"
fi

# Idempotent re-run on empty staging is no-op
bash "$RECONCILER" --rules-file "$RULES_FILE" --staging-root "$STAGING_ROOT" --audit-log "$CLAUDE_LOG_DIR/reconciler.log" >/dev/null 2>"$TEMPROOT/stderr2"
RC2=$?
[ "$RC2" = "0" ] && emit_pass "second reconciler tick exits 0 (idempotent)" || emit_fail "second tick rc=$RC2"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%s\n' "$FAILED_CHECKS"; exit 1; }
exit 0
