#!/usr/bin/env bash
# SP14 T-32 Theme C — lib/manifest-record.sh logical supersession.
#
# Scope: when --supersedes <predecessor-id> is provided, the BEGIN/INSERT/
# UPDATE/COMMIT atomic transaction inserts the new row as active AND updates
# the predecessor row to status='superseded' + superseded_by=<new-row-id>.
# Append-only invariant: predecessor row is NOT deleted; superseded chain is
# auditable forward and backward.
#
# Per spec.md §7 + writer-pipeline-layering.md L-96 + L-109 + L-103 (append-
# only + logical supersession via UPDATE; LangChain SQLRecordManager basis).
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
LIB="$FOUNDATION_REPO/lib/manifest-record.sh"

TEMPROOT="$(mktemp -d -t sp14-manifest-super.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT

export VAULT_WRITER_STATE_ROOT="$TEMPROOT/vault-writers"
export WRITER_MANIFEST_PATH="$VAULT_WRITER_STATE_ROOT/manifest.sqlite"

case "$WRITER_MANIFEST_PATH" in "$TEMPROOT"/*) ;; *) printf 'FATAL: WRITER_MANIFEST_PATH not jailed: %s\n' "$WRITER_MANIFEST_PATH" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS"$'\n'"    - $1"; }

printf '=== SP14 T-32 manifest-record-supersession ===\n'

if ! command -v sqlite3 >/dev/null 2>&1; then
  emit_fail "sqlite3 not available"
  printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
  exit 1
fi

bash "$LIB" init >/dev/null 2>&1

DEST="/Users/x/Vault/Meetings/2026-05-20.md"

# ---- Insert row A (initial create) ------------------------------------------
ROW_ID_A=$(bash "$LIB" record-write \
  --writer-id "meeting-ingestor" \
  --destination-path "$DEST" \
  --content-sha256 "sha-A" \
  --write-bucket "create" 2>"$TEMPROOT/A.err")
[ -n "$ROW_ID_A" ] && emit_pass "row A inserted (id=$ROW_ID_A)" || emit_fail "row A insert failed: $(cat "$TEMPROOT/A.err")"

# Brief sleep so ingestion_date differs (ISO-8601 second-resolution).
sleep 1

# ---- Insert row B with --supersedes A ---------------------------------------
ROW_ID_B=$(bash "$LIB" record-write \
  --writer-id "meeting-ingestor" \
  --destination-path "$DEST" \
  --content-sha256 "sha-B" \
  --write-bucket "modify-amend" \
  --supersedes "$ROW_ID_A" 2>"$TEMPROOT/B.err")
[ -n "$ROW_ID_B" ] && emit_pass "row B inserted with --supersedes (id=$ROW_ID_B)" || emit_fail "row B insert failed: $(cat "$TEMPROOT/B.err")"

# ---- Verify B is active --------------------------------------------------
ROW_B_JSON=$(bash "$LIB" query-row --id "$ROW_ID_B" 2>/dev/null)
if printf '%s' "$ROW_B_JSON" | jq -e '.status == "active" and .superseded_by == null' >/dev/null 2>&1; then
  emit_pass "row B is active with superseded_by=null"
else
  emit_fail "row B status/superseded_by wrong: $ROW_B_JSON"
fi

# ---- Verify A is superseded with pointer to B -------------------------------
ROW_A_JSON=$(bash "$LIB" query-row --id "$ROW_ID_A" 2>/dev/null)
if printf '%s' "$ROW_A_JSON" | jq -e --arg b "$ROW_ID_B" '.status == "superseded" and .superseded_by == $b' >/dev/null 2>&1; then
  emit_pass "row A flipped to superseded with pointer to B"
else
  emit_fail "row A supersession state wrong: $ROW_A_JSON (expected status=superseded, superseded_by=$ROW_ID_B)"
fi

# ---- Append-only invariant: row A is NOT deleted ----------------------------
A_COUNT=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT COUNT(*) FROM writes WHERE id='${ROW_ID_A//\'/\'\'}';" 2>/dev/null)
[ "$A_COUNT" = "1" ] && emit_pass "append-only: row A still present (not deleted)" || emit_fail "row A count=$A_COUNT (expected 1)"

# Active-row count: 1 active (B) + 1 superseded (A) = 2 total rows
TOTAL=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT COUNT(*) FROM writes;" 2>/dev/null)
ACTIVE=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT COUNT(*) FROM writes WHERE status='active';" 2>/dev/null)
SUPERSEDED=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT COUNT(*) FROM writes WHERE status='superseded';" 2>/dev/null)
[ "$TOTAL" = "2" ] && emit_pass "total rows = 2" || emit_fail "total=$TOTAL (expected 2)"
[ "$ACTIVE" = "1" ] && emit_pass "active rows = 1 (B only)" || emit_fail "active=$ACTIVE (expected 1)"
[ "$SUPERSEDED" = "1" ] && emit_pass "superseded rows = 1 (A only)" || emit_fail "superseded=$SUPERSEDED (expected 1)"

# ---- query-destination-history returns both rows newest-first ---------------
HISTORY=$(bash "$LIB" query-destination-history --destination-path "$DEST" 2>"$TEMPROOT/hist.err")
HIST_COUNT=$(printf '%s\n' "$HISTORY" | grep -c '^{')
[ "$HIST_COUNT" = "2" ] && emit_pass "destination history shows 2 rows" || emit_fail "history count=$HIST_COUNT (expected 2): $HISTORY"

# Newest first (row B at top)
TOP_ID=$(printf '%s\n' "$HISTORY" | head -1 | jq -r '.id')
[ "$TOP_ID" = "$ROW_ID_B" ] && emit_pass "history ordered newest-first (B at top)" || emit_fail "top row id=$TOP_ID (expected $ROW_ID_B)"

# ---- Chained supersession (A ← B ← C) ---------------------------------------
sleep 1
ROW_ID_C=$(bash "$LIB" record-write \
  --writer-id "meeting-ingestor" \
  --destination-path "$DEST" \
  --content-sha256 "sha-C" \
  --write-bucket "modify-amend" \
  --supersedes "$ROW_ID_B" 2>"$TEMPROOT/C.err")
[ -n "$ROW_ID_C" ] && emit_pass "row C inserted (chained supersession)" || emit_fail "row C insert failed: $(cat "$TEMPROOT/C.err")"

# A still points to B (NOT C) — supersession is direct, not transitive
ROW_A_NEW=$(bash "$LIB" query-row --id "$ROW_ID_A" 2>/dev/null)
if printf '%s' "$ROW_A_NEW" | jq -e --arg b "$ROW_ID_B" '.superseded_by == $b' >/dev/null 2>&1; then
  emit_pass "row A supersession pointer unchanged (chain is non-transitive)"
else
  emit_fail "row A pointer mutated unexpectedly: $ROW_A_NEW"
fi

# B now superseded by C
ROW_B_NEW=$(bash "$LIB" query-row --id "$ROW_ID_B" 2>/dev/null)
if printf '%s' "$ROW_B_NEW" | jq -e --arg c "$ROW_ID_C" '.status == "superseded" and .superseded_by == $c' >/dev/null 2>&1; then
  emit_pass "row B flipped to superseded with pointer to C"
else
  emit_fail "row B not superseded by C: $ROW_B_NEW"
fi

# Only C is active
FINAL_ACTIVE=$(sqlite3 "$WRITER_MANIFEST_PATH" "SELECT COUNT(*) FROM writes WHERE status='active';" 2>/dev/null)
[ "$FINAL_ACTIVE" = "1" ] && emit_pass "exactly 1 active row after chain (C only)" || emit_fail "active count=$FINAL_ACTIVE (expected 1)"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%s\n' "$FAILED_CHECKS"; exit 1; }
exit 0
