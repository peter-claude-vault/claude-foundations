#!/usr/bin/env bash
# SP14 T-32 Theme D — doc-amender replacement-packet emission.
#
# SUBSTRATE GAP NOTE (anchored to SPEC behavior; expected partial FAIL):
#   doc-amender/process.sh:489 passes `--output-type md` to staging-emit.sh,
#   but staging-emit's enum (canonical per vault-writer.md.json) accepts
#   `markdown`, not `md`. staging-emit returns rc=3 (enum violation); the
#   replacement packet is never written. This fixture anchors to spec
#   (replacement emitted with packet_kind=amender-replacement); failure
#   signals new substrate-hotfix item for the divergence inventory.
#
# Scope per fix: full doc-amender → staging-emit pipeline. Replacement packet
# emitted under <writer_id>+amender staging dir with packet_kind=amender-
# replacement. Original writer-emit packet UNTOUCHED (doc-amender is a seam,
# not a destination writer).
#
# Per spec.md §8.5 + writer-pipeline-layering.md L-105..L-107 + §A62.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
AMENDER="$FOUNDATION_REPO/skills/doc-amender/process.sh"
STAGING_EMIT="$FOUNDATION_REPO/lib/staging-emit.sh"
MANIFEST_RECORD="$FOUNDATION_REPO/lib/manifest-record.sh"
MOCKS_DIR="$FOUNDATION_REPO/tests/fixtures/sp14-doc-amender-mocks"

TEMPROOT="$(mktemp -d -t sp14-amender-replace.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT

export VAULT_ROOT="$TEMPROOT/vault"
export VAULT_WRITER_STATE_ROOT="$TEMPROOT/vault-writers"
export STAGING_ROOT="$TEMPROOT/staging"
export CLAUDE_LOG_DIR="$TEMPROOT/logs"
mkdir -p "$VAULT_ROOT/Meetings" "$VAULT_WRITER_STATE_ROOT/prompts" "$STAGING_ROOT" "$CLAUDE_LOG_DIR"

case "$STAGING_ROOT" in "$TEMPROOT"/*) ;; *) printf 'FATAL\n' >&2; exit 2 ;; esac

export PATH="$MOCKS_DIR:$PATH"
export MOCK_OUTPUT="# REPLACEMENT BODY"$'\n'"emitted by mock-claude"

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS"$'\n'"    - $1"; }

printf '=== SP14 T-32 doc-amender-replacement-emission ===\n'
printf '          NOTE: anchored to spec; expect FAIL on emission if doc-amender→staging-emit enum gap unfixed\n'

# Setup: doc-deps + prompt + packet (same shape as packet-pickup fixture)
DOC_DEPS="$TEMPROOT/doc-dependencies.json"
WRITER_ID="meeting-processor"
DEST="$VAULT_ROOT/Meetings/replace-test.md"
DEST_GLOB="*/Meetings/*.md"

jq -nc --arg consumer "$DEST_GLOB" --arg writer "$WRITER_ID" \
  '{entries:[{id:"x",kind:"writer-fan-in",consumer:$consumer,upstream_writers:[$writer],amendment_strategy:"prompt-guided-amend"}]}' \
  > "$DOC_DEPS"

cat > "$VAULT_WRITER_STATE_ROOT/prompts/p.md" <<EOF
---
prompt_id: replacement-test-prompt
amendment_strategy: prompt-guided-amend
destination_glob: $DEST_GLOB
---
Amend.
EOF

mkdir -p "$STAGING_ROOT/$WRITER_ID"
BODY="# Original Meeting"
PACKET_SHA=$(printf '%s' "$BODY" | shasum -a 256 | awk '{print $1}')
PACKET="$STAGING_ROOT/$WRITER_ID/$PACKET_SHA.json"

jq -nc --arg pv "1.1" --arg w "$WRITER_ID" --arg ts "2026-05-20T12:00:00Z" \
  --arg dp "$DEST" --arg sha "$PACKET_SHA" --arg body "$BODY" \
  --arg ot "md" --arg pk "writer-emit" --arg src "src-42" \
  '{packet_version:$pv,writer_id:$w,emitted_at:$ts,destination_path:$dp,content_sha256:$sha,body:$body,output_type:$ot,metadata:{custom:"propagate-me"},packet_kind:$pk,source_id:$src}' \
  > "$PACKET"

bash "$AMENDER" --staging-root "$STAGING_ROOT" --prompt-root "$VAULT_WRITER_STATE_ROOT/prompts" \
  --doc-deps-file "$DOC_DEPS" --staging-emit "$STAGING_EMIT" --manifest-record "$MANIFEST_RECORD" \
  --audit-log "$CLAUDE_LOG_DIR/doc-amender.log" --once >/dev/null 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "doc-amender exits 0" || emit_fail "amender rc=$RC"

# ---- Replacement packet assertions ------------------------------------------
AMENDER_DIR="$STAGING_ROOT/${WRITER_ID}+amender"
[ -d "$AMENDER_DIR" ] && emit_pass "+amender staging dir created" || emit_fail "+amender dir missing (SUBSTRATE GAP — doc-amender → staging-emit output-type enum mismatch)"

REPLACEMENT=$(find "$AMENDER_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | head -1)
if [ -n "$REPLACEMENT" ] && [ -f "$REPLACEMENT" ]; then
  emit_pass "replacement packet present"
  if jq -e '.packet_kind == "amender-replacement"' "$REPLACEMENT" >/dev/null 2>&1; then
    emit_pass "packet_kind = amender-replacement"
  else
    emit_fail "packet_kind wrong: $(jq -r '.packet_kind' "$REPLACEMENT")"
  fi
  if jq -e --arg dp "$DEST" '.destination_path == $dp' "$REPLACEMENT" >/dev/null 2>&1; then
    emit_pass "destination_path preserved on replacement"
  else
    emit_fail "destination_path drift on replacement"
  fi
  if jq -e '.body | contains("REPLACEMENT BODY")' "$REPLACEMENT" >/dev/null 2>&1; then
    emit_pass "replacement body = mock-claude output (not original)"
  else
    emit_fail "replacement body != mock output: $(jq -r '.body' "$REPLACEMENT" | head -1)"
  fi
  if jq -e '.source_id == "src-42"' "$REPLACEMENT" >/dev/null 2>&1; then
    emit_pass "source_id propagated from original packet"
  else
    emit_fail "source_id lost on replacement"
  fi
  if jq -e '.writer_id == "'"$WRITER_ID"'+amender"' "$REPLACEMENT" >/dev/null 2>&1; then
    emit_pass "writer_id suffixed with +amender"
  else
    emit_fail "writer_id wrong: $(jq -r '.writer_id' "$REPLACEMENT")"
  fi
else
  emit_fail "no replacement packet found (SUBSTRATE GAP — doc-amender → staging-emit pipeline incomplete)"
fi

# ---- Original packet remains in staging (R-34 seam discipline) --------------
[ -f "$PACKET" ] && emit_pass "original writer-emit packet UNTOUCHED (doc-amender is a seam, not a destination writer)" || emit_fail "original packet deleted by amender"

# ---- Destination NOT written by amender (boundary discipline) ---------------
[ ! -f "$DEST" ] && emit_pass "destination NOT written directly (R-34 boundary)" || emit_fail "destination written by amender (R-34 violation)"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%s\n' "$FAILED_CHECKS"; exit 1; }
exit 0
