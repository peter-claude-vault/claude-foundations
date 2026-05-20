#!/usr/bin/env bash
# SP14 T-32 Theme C — lib/manifest-record.sh record-write row insert.
#
# Scope: `manifest-record.sh record-write` inserts an active row under
# per-database lockf serialization; ROW_ID echoed on stdout for caller
# chaining. Optional columns store NULL when not provided. write_bucket +
# packet_kind enum validation enforced pre-flight.
#
# Per spec.md §7 + writer-pipeline-layering.md L-96 + L-109. bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
LIB="$FOUNDATION_REPO/lib/manifest-record.sh"

TEMPROOT="$(mktemp -d -t sp14-manifest-writerow.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT

export VAULT_WRITER_STATE_ROOT="$TEMPROOT/vault-writers"
export WRITER_MANIFEST_PATH="$VAULT_WRITER_STATE_ROOT/manifest.sqlite"

case "$WRITER_MANIFEST_PATH" in "$TEMPROOT"/*) ;; *) printf 'FATAL: WRITER_MANIFEST_PATH not jailed: %s\n' "$WRITER_MANIFEST_PATH" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS"$'\n'"    - $1"; }

printf '=== SP14 T-32 manifest-record-write-row ===\n'

if ! command -v sqlite3 >/dev/null 2>&1; then
  emit_fail "sqlite3 not available"
  printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
  exit 1
fi

# Init manifest
bash "$LIB" init >/dev/null 2>"$TEMPROOT/init.err" || { emit_fail "init failed: $(cat "$TEMPROOT/init.err")"; printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"; exit 1; }

# ---- Insert row with all optional fields supplied ---------------------------
ROW_ID_A=$(bash "$LIB" record-write \
  --writer-id "meeting-note-ingestor" \
  --destination-path "/Users/x/Vault/Meetings/2026-05-20-test.md" \
  --content-sha256 "abc123def" \
  --write-bucket "create" \
  --source-id "granola-mtg-42" \
  --raw-path "/raw/granola-mtg-42.json" \
  --packet-kind "writer-emit" \
  --notes "fixture-insert" 2>"$TEMPROOT/insertA.err")
RCA=$?
[ "$RCA" = "0" ] && emit_pass "record-write exits 0" || emit_fail "record-write rc=$RCA: $(cat "$TEMPROOT/insertA.err")"
[ -n "$ROW_ID_A" ] && emit_pass "ROW_ID echoed on stdout (=$ROW_ID_A)" || emit_fail "no ROW_ID on stdout"

# Verify the inserted row via query-row
ROW_JSON=$(bash "$LIB" query-row --id "$ROW_ID_A" 2>"$TEMPROOT/queryA.err")
RCQ=$?
[ "$RCQ" = "0" ] && emit_pass "query-row exits 0" || emit_fail "query-row rc=$RCQ: $(cat "$TEMPROOT/queryA.err")"

# Required field check + optional field round-trip
FIELDS_OK=1
for assertion in \
  '.writer_id == "meeting-note-ingestor"' \
  '.destination_path == "/Users/x/Vault/Meetings/2026-05-20-test.md"' \
  '.content_sha256 == "abc123def"' \
  '.status == "active"' \
  '.write_bucket == "create"' \
  '.source_id == "granola-mtg-42"' \
  '.raw_path == "/raw/granola-mtg-42.json"' \
  '.packet_kind == "writer-emit"' \
  '.notes == "fixture-insert"' \
  '.superseded_by == null'
do
  if ! printf '%s' "$ROW_JSON" | jq -e "$assertion" >/dev/null 2>&1; then
    emit_fail "row assertion failed: $assertion (got: $ROW_JSON)"
    FIELDS_OK=0
  fi
done
[ "$FIELDS_OK" = "1" ] && emit_pass "all 10 row fields round-trip correctly"

# ingestion_date is ISO-8601 UTC
if printf '%s' "$ROW_JSON" | jq -re '.ingestion_date' 2>/dev/null | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  emit_pass "ingestion_date is ISO-8601 UTC"
else
  emit_fail "ingestion_date not ISO-8601 UTC: $(printf '%s' "$ROW_JSON" | jq -r '.ingestion_date')"
fi

# ---- Insert minimal row (optionals omitted → NULL) --------------------------
ROW_ID_B=$(bash "$LIB" record-write \
  --writer-id "auto-research" \
  --destination-path "/Users/x/Vault/Research/topic-x.md" \
  --content-sha256 "ffffeee" \
  --write-bucket "modify-append" 2>"$TEMPROOT/insertB.err")
RCB=$?
[ "$RCB" = "0" ] && emit_pass "minimal record-write exits 0" || emit_fail "minimal record-write rc=$RCB: $(cat "$TEMPROOT/insertB.err")"

ROW_B_JSON=$(bash "$LIB" query-row --id "$ROW_ID_B" 2>/dev/null)
NULL_FIELDS_OK=1
for assertion in \
  '.source_id == null' \
  '.raw_path == null' \
  '.packet_kind == null' \
  '.notes == null' \
  '.superseded_by == null' \
  '.write_bucket == "modify-append"'
do
  if ! printf '%s' "$ROW_B_JSON" | jq -e "$assertion" >/dev/null 2>&1; then
    emit_fail "minimal row assertion failed: $assertion"
    NULL_FIELDS_OK=0
  fi
done
[ "$NULL_FIELDS_OK" = "1" ] && emit_pass "minimal row stores NULL for omitted optionals"

# ---- Enum validation ---------------------------------------------------------
bash "$LIB" record-write \
  --writer-id "bogus" --destination-path "/d" --content-sha256 "sha" \
  --write-bucket "bogus-bucket" 2>"$TEMPROOT/enum.err" >/dev/null
RC_ENUM=$?
[ "$RC_ENUM" = "3" ] && emit_pass "invalid write-bucket rejected (rc=3)" || emit_fail "invalid write-bucket rc=$RC_ENUM (expected 3)"
grep -q 'write-bucket must be' "$TEMPROOT/enum.err" && emit_pass "enum error names allowed values" || emit_fail "enum error did not name allowed values: $(cat "$TEMPROOT/enum.err")"

bash "$LIB" record-write \
  --writer-id "bogus" --destination-path "/d" --content-sha256 "sha" \
  --write-bucket "create" --packet-kind "bogus-kind" 2>"$TEMPROOT/enum2.err" >/dev/null
RC_ENUM2=$?
[ "$RC_ENUM2" = "3" ] && emit_pass "invalid packet-kind rejected (rc=3)" || emit_fail "invalid packet-kind rc=$RC_ENUM2 (expected 3)"

# ---- query-row miss returns rc=6 -------------------------------------------
bash "$LIB" query-row --id "nonexistent-row-id" >/dev/null 2>&1
RC_MISS=$?
[ "$RC_MISS" = "6" ] && emit_pass "query-row miss returns rc=6" || emit_fail "query-row miss rc=$RC_MISS (expected 6)"

# ---- writer-id filename-safety ----------------------------------------------
bash "$LIB" record-write \
  --writer-id "../escape" --destination-path "/d" --content-sha256 "sha" \
  --write-bucket "create" 2>"$TEMPROOT/safe.err" >/dev/null
RC_SAFE=$?
[ "$RC_SAFE" = "2" ] && emit_pass "writer-id path-escape rejected (rc=2)" || emit_fail "writer-id path-escape rc=$RC_SAFE (expected 2)"

# ---- 2 active rows present (no supersession in this fixture) ----------------
ROW_COUNT=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT COUNT(*) FROM writes WHERE status='active';" 2>/dev/null)
[ "$ROW_COUNT" = "2" ] && emit_pass "2 active rows post-insert" || emit_fail "active-row count=$ROW_COUNT (expected 2)"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%s\n' "$FAILED_CHECKS"; exit 1; }
exit 0
