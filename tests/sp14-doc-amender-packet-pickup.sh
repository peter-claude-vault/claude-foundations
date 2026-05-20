#!/usr/bin/env bash
# SP14 T-32 Theme D — doc-amender packet pickup.
#
# Scope: doc-amender enumerates writer-fan-in entries with amendment_strategy=
# prompt-guided-amend; for each, scans staging for packets matching consumer
# glob + upstream_writers join; resolves prompt asset by destination_glob
# frontmatter match; invokes claude -p (mock); on success emits replacement
# packet via staging-emit.sh. Self-exclusion: packet_kind ∈ {amender-
# replacement, amender-conflict} are silently skipped.
#
# Per spec.md §8.5 + writer-pipeline-layering.md L-105..L-107 + §A62.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
AMENDER="$FOUNDATION_REPO/skills/doc-amender/process.sh"
STAGING_EMIT="$FOUNDATION_REPO/lib/staging-emit.sh"
MANIFEST_RECORD="$FOUNDATION_REPO/lib/manifest-record.sh"
MOCKS_DIR="$FOUNDATION_REPO/tests/fixtures/sp14-doc-amender-mocks"

TEMPROOT="$(mktemp -d -t sp14-amender-pickup.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT

export VAULT_ROOT="$TEMPROOT/vault"
export VAULT_WRITER_STATE_ROOT="$TEMPROOT/vault-writers"
export STAGING_ROOT="$TEMPROOT/staging"
export CLAUDE_LOG_DIR="$TEMPROOT/logs"
mkdir -p "$VAULT_ROOT/Meetings" "$VAULT_WRITER_STATE_ROOT/prompts" "$STAGING_ROOT" "$CLAUDE_LOG_DIR"

case "$STAGING_ROOT" in "$TEMPROOT"/*) ;; *) printf 'FATAL: STAGING_ROOT not jailed\n' >&2; exit 2 ;; esac

# Prepend mocks to PATH so doc-amender's `claude -p` resolves to the mock.
export PATH="$MOCKS_DIR:$PATH"

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS"$'\n'"    - $1"; }

printf '=== SP14 T-32 doc-amender-packet-pickup ===\n'

# ---- Stage doc-deps with writer-fan-in entry --------------------------------
DOC_DEPS="$TEMPROOT/doc-dependencies.json"
WRITER_ID="meeting-processor"
DEST_REL="Meetings/2026-05-20-standup.md"
DEST="$VAULT_ROOT/$DEST_REL"
DEST_GLOB="*/Meetings/*.md"

jq -nc \
  --arg consumer "$DEST_GLOB" \
  --arg writer "$WRITER_ID" \
  '{entries:[{id:"meetings-fan-in",kind:"writer-fan-in",consumer:$consumer,upstream_writers:[$writer],amendment_strategy:"prompt-guided-amend"}]}' \
  > "$DOC_DEPS"

# ---- Stage prompt asset -----------------------------------------------------
PROMPT="$VAULT_WRITER_STATE_ROOT/prompts/meeting-fan-in.md"
cat > "$PROMPT" <<EOF
---
prompt_id: meeting-fan-in-v1
amendment_strategy: prompt-guided-amend
destination_glob: $DEST_GLOB
---

Amend the destination with the incoming meeting note. Preserve human edits.
EOF

# ---- Stage packet -----------------------------------------------------------
WRITER_DIR="$STAGING_ROOT/$WRITER_ID"
mkdir -p "$WRITER_DIR"
BODY="# Standup 2026-05-20"$'\n\n'"- attendees: Peter, claude"
PACKET_SHA=$(printf '%s' "$BODY" | shasum -a 256 | awk '{print $1}')
PACKET="$WRITER_DIR/$PACKET_SHA.json"

jq -nc \
  --arg pv "1.1" --arg w "$WRITER_ID" --arg ts "2026-05-20T12:00:00Z" \
  --arg dp "$DEST" --arg sha "$PACKET_SHA" --arg body "$BODY" \
  --arg ot "md" --arg pk "writer-emit" --arg src "granola-mtg-pickup" \
  '{packet_version:$pv,writer_id:$w,emitted_at:$ts,destination_path:$dp,content_sha256:$sha,body:$body,output_type:$ot,metadata:{},packet_kind:$pk,source_id:$src}' \
  > "$PACKET"

[ -f "$PACKET" ] && emit_pass "writer-emit packet staged" || emit_fail "packet staging failed"

# ---- Run doc-amender --------------------------------------------------------
bash "$AMENDER" \
  --staging-root "$STAGING_ROOT" \
  --prompt-root "$VAULT_WRITER_STATE_ROOT/prompts" \
  --doc-deps-file "$DOC_DEPS" \
  --staging-emit "$STAGING_EMIT" \
  --manifest-record "$MANIFEST_RECORD" \
  --audit-log "$CLAUDE_LOG_DIR/doc-amender.log" \
  --once >"$TEMPROOT/stdout" 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "doc-amender exits 0" || emit_fail "amender rc=$RC: $(cat "$TEMPROOT/stderr")"

# Counter telemetry on stderr
grep -qE 'eligible=1' "$TEMPROOT/stderr" && emit_pass "eligible counter = 1" || emit_fail "eligible counter wrong: $(grep '^process.sh:' "$TEMPROOT/stderr")"
grep -qE 'succeeded=1' "$TEMPROOT/stderr" && emit_pass "succeeded counter = 1" || emit_fail "succeeded counter wrong: $(grep '^process.sh:' "$TEMPROOT/stderr")"
grep -qE 'failed=0' "$TEMPROOT/stderr" && emit_pass "failed counter = 0" || emit_fail "failed counter wrong: $(grep '^process.sh:' "$TEMPROOT/stderr")"

# Audit log entry
[ -f "$CLAUDE_LOG_DIR/doc-amender.log" ] && emit_pass "audit log created" || emit_fail "audit log missing"
AUDIT_OK_LINE=$(grep -F '"op":"staging-emit"' "$CLAUDE_LOG_DIR/doc-amender.log" 2>/dev/null | head -1)
[ -n "$AUDIT_OK_LINE" ] && emit_pass "staging-emit audit row present" || emit_fail "no staging-emit audit row"
if [ -n "$AUDIT_OK_LINE" ]; then
  printf '%s' "$AUDIT_OK_LINE" | jq -e '.result == "OK" and .prompt_id == "meeting-fan-in-v1"' >/dev/null 2>&1 \
    && emit_pass "audit row carries result=OK + prompt_id" \
    || emit_fail "audit row missing result=OK or prompt_id: $AUDIT_OK_LINE"
fi

# Replacement packet emitted under +amender writer dir
AMENDER_WRITER_DIR="$STAGING_ROOT/${WRITER_ID}+amender"
[ -d "$AMENDER_WRITER_DIR" ] && emit_pass "+amender staging dir created" || emit_fail "+amender dir missing"
REPLACEMENT_COUNT=$(find "$AMENDER_WRITER_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[ "$REPLACEMENT_COUNT" = "1" ] && emit_pass "1 replacement packet emitted" || emit_fail "replacement packet count=$REPLACEMENT_COUNT (expected 1)"

# Original packet should NOT have been removed (doc-amender doesn't write to
# destination; reconciler removes packets, not doc-amender — but the original
# pre-amend packet may remain in staging awaiting reconciler.)
[ -f "$PACKET" ] && emit_pass "original writer-emit packet still in staging (doc-amender does not delete)" || emit_fail "original packet was deleted (doc-amender boundary violation)"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%s\n' "$FAILED_CHECKS"; exit 1; }
exit 0
