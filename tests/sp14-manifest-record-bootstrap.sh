#!/usr/bin/env bash
# SP14 T-32 Theme C — lib/manifest-record.sh init bootstrap.
#
# Scope: `manifest-record.sh init` applies lib/manifest-migrate.sql DDL to
# $WRITER_MANIFEST_PATH; idempotent via PRAGMA user_version=1 checkpoint.
# Verify: writes table created with 12 schema-matching columns, all 4 indexes
# present, WAL journal mode set, user_version=1, second invocation no-ops.
#
# Per spec.md §7 + writer-pipeline-layering.md L-96 + L-109. bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
LIB="$FOUNDATION_REPO/lib/manifest-record.sh"

TEMPROOT="$(mktemp -d -t sp14-manifest-bootstrap.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT

export VAULT_WRITER_STATE_ROOT="$TEMPROOT/vault-writers"
export WRITER_MANIFEST_PATH="$VAULT_WRITER_STATE_ROOT/manifest.sqlite"

case "$WRITER_MANIFEST_PATH" in "$TEMPROOT"/*) ;; *) printf 'FATAL: WRITER_MANIFEST_PATH not jailed: %s\n' "$WRITER_MANIFEST_PATH" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS"$'\n'"    - $1"; }

printf '=== SP14 T-32 manifest-record-bootstrap ===\n'

if ! command -v sqlite3 >/dev/null 2>&1; then
  emit_fail "sqlite3 not available — cannot run bootstrap test"
  printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
  exit 1
fi

# ---- First invocation: applies migration ------------------------------------
bash "$LIB" init >"$TEMPROOT/stdout1" 2>"$TEMPROOT/stderr1"
RC1=$?
[ "$RC1" = "0" ] && emit_pass "first init exits 0" || emit_fail "first init rc=$RC1: $(cat "$TEMPROOT/stderr1")"

[ -f "$WRITER_MANIFEST_PATH" ] && emit_pass "manifest.sqlite file created" || emit_fail "manifest.sqlite not created at $WRITER_MANIFEST_PATH"

# user_version=1 checkpoint
USER_VERSION=$(sqlite3 "$WRITER_MANIFEST_PATH" 'PRAGMA user_version;' 2>/dev/null)
[ "$USER_VERSION" = "1" ] && emit_pass "PRAGMA user_version=1 set" || emit_fail "user_version=$USER_VERSION (expected 1)"

# WAL journal mode
JOURNAL_MODE=$(sqlite3 "$WRITER_MANIFEST_PATH" 'PRAGMA journal_mode;' 2>/dev/null)
[ "$JOURNAL_MODE" = "wal" ] && emit_pass "PRAGMA journal_mode=wal set" || emit_fail "journal_mode=$JOURNAL_MODE (expected wal)"

# writes table exists
TABLE_PRESENT=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='writes';" 2>/dev/null)
[ "$TABLE_PRESENT" = "writes" ] && emit_pass "writes table created" || emit_fail "writes table missing: '$TABLE_PRESENT'"

# All 12 schema columns present
COLUMNS=$(sqlite3 "$WRITER_MANIFEST_PATH" "PRAGMA table_info(writes);" 2>/dev/null | awk -F'|' '{print $2}' | sort | tr '\n' ',' | sed 's/,$//')
EXPECTED_COLUMNS="content_sha256,destination_path,id,ingestion_date,notes,packet_kind,raw_path,source_id,status,superseded_by,write_bucket,writer_id"
[ "$COLUMNS" = "$EXPECTED_COLUMNS" ] && emit_pass "12 columns match schema" || emit_fail "columns mismatch — got: $COLUMNS"

# id is PRIMARY KEY
PK_COL=$(sqlite3 "$WRITER_MANIFEST_PATH" "PRAGMA table_info(writes);" 2>/dev/null | awk -F'|' '$6=="1" {print $2}')
[ "$PK_COL" = "id" ] && emit_pass "id is PRIMARY KEY" || emit_fail "PRIMARY KEY mismatch — got: '$PK_COL'"

# All 4 indexes present
INDEXES=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='writes' AND name LIKE 'idx_writes_%';" 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
EXPECTED_INDEXES="idx_writes_destination_path,idx_writes_ingestion_date,idx_writes_source_id,idx_writes_writer_id"
[ "$INDEXES" = "$EXPECTED_INDEXES" ] && emit_pass "4 indexes present" || emit_fail "indexes mismatch — got: $INDEXES"

# status CHECK constraint enforced
INVALID_STATUS_RC=$(sqlite3 "$WRITER_MANIFEST_PATH" \
  "INSERT INTO writes (id, writer_id, destination_path, ingestion_date, content_sha256, status, write_bucket) VALUES ('x', 'w', '/d', '2026-01-01', 'sha', 'bogus', 'create');" 2>&1; echo "rc=$?")
echo "$INVALID_STATUS_RC" | grep -qi 'constraint.*status\|CHECK' && emit_pass "status CHECK constraint enforced" || emit_fail "status CHECK constraint not enforced: $INVALID_STATUS_RC"

# write_bucket CHECK constraint enforced
INVALID_BUCKET_RC=$(sqlite3 "$WRITER_MANIFEST_PATH" \
  "INSERT INTO writes (id, writer_id, destination_path, ingestion_date, content_sha256, status, write_bucket) VALUES ('x', 'w', '/d', '2026-01-01', 'sha', 'active', 'bogus-bucket');" 2>&1; echo "rc=$?")
echo "$INVALID_BUCKET_RC" | grep -qi 'constraint.*write_bucket\|CHECK' && emit_pass "write_bucket CHECK constraint enforced" || emit_fail "write_bucket CHECK constraint not enforced: $INVALID_BUCKET_RC"

# ---- Second invocation: idempotent no-op ------------------------------------
bash "$LIB" init >"$TEMPROOT/stdout2" 2>"$TEMPROOT/stderr2"
RC2=$?
[ "$RC2" = "0" ] && emit_pass "second init exits 0 (idempotent)" || emit_fail "second init rc=$RC2: $(cat "$TEMPROOT/stderr2")"

grep -q 'init no-op' "$TEMPROOT/stderr2" 2>/dev/null && emit_pass "second init logs no-op" || emit_fail "second init did not log no-op signal: $(cat "$TEMPROOT/stderr2")"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%s\n' "$FAILED_CHECKS"; exit 1; }
exit 0
