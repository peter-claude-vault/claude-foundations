#!/usr/bin/env bash
# SP14 T-32 Theme D — doc-amender operator-edit-detected sidecar path.
#
# Scope: when destination has last_user_edit frontmatter timestamp > packet
# emitted_at (Signal A), OR destination content-hash differs from most-recent
# manifest active row's content_sha256 (Signal B), doc-amender writes a
# `<packet>.amender-conflict.json` sidecar next to the packet, audits the
# decision, and SKIPS LLM invocation entirely. Original packet retained for
# operator triage via /amend-accept.
#
# Per spec.md §8.5 + writer-pipeline-layering.md L-107 + §A62 (3-signal
# survivorship hybrid: operator-edit-wins + amender_paused + reviewed-checkpoint).
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
AMENDER="$FOUNDATION_REPO/skills/doc-amender/process.sh"
STAGING_EMIT="$FOUNDATION_REPO/lib/staging-emit.sh"
MANIFEST_RECORD="$FOUNDATION_REPO/lib/manifest-record.sh"
MOCKS_DIR="$FOUNDATION_REPO/tests/fixtures/sp14-doc-amender-mocks"

TEMPROOT="$(mktemp -d -t sp14-amender-conflict.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT

export VAULT_ROOT="$TEMPROOT/vault"
export VAULT_WRITER_STATE_ROOT="$TEMPROOT/vault-writers"
export STAGING_ROOT="$TEMPROOT/staging"
export CLAUDE_LOG_DIR="$TEMPROOT/logs"
mkdir -p "$VAULT_ROOT/Meetings" "$VAULT_WRITER_STATE_ROOT/prompts" "$STAGING_ROOT" "$CLAUDE_LOG_DIR"

case "$STAGING_ROOT" in "$TEMPROOT"/*) ;; *) printf 'FATAL\n' >&2; exit 2 ;; esac

export PATH="$MOCKS_DIR:$PATH"
# If the mock IS invoked (which it shouldn't be per the survivorship gate), fail loudly.
export MOCK_FAIL=1

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS"$'\n'"    - $1"; }

printf '=== SP14 T-32 doc-amender-operator-edit-sidecar ===\n'

DOC_DEPS="$TEMPROOT/doc-dependencies.json"
WRITER_ID="meeting-processor"
DEST="$VAULT_ROOT/Meetings/operator-edited.md"
DEST_GLOB="*/Meetings/*.md"

jq -nc --arg consumer "$DEST_GLOB" --arg writer "$WRITER_ID" \
  '{entries:[{id:"x",kind:"writer-fan-in",consumer:$consumer,upstream_writers:[$writer],amendment_strategy:"prompt-guided-amend"}]}' \
  > "$DOC_DEPS"

cat > "$VAULT_WRITER_STATE_ROOT/prompts/p.md" <<EOF
---
prompt_id: conflict-test
amendment_strategy: prompt-guided-amend
destination_glob: $DEST_GLOB
---
Amend.
EOF

# Pre-existing destination with last_user_edit AFTER the packet's emitted_at.
cat > "$DEST" <<'DEST_EOF'
---
type: meeting-note
last_user_edit: 2026-05-20T15:00:00Z
---

# Operator-edited content (do not amend)
DEST_EOF

mkdir -p "$STAGING_ROOT/$WRITER_ID"
BODY="# New amender input"
PACKET_SHA=$(printf '%s' "$BODY" | shasum -a 256 | awk '{print $1}')
PACKET="$STAGING_ROOT/$WRITER_ID/$PACKET_SHA.json"

# Packet emitted_at is EARLIER than destination's last_user_edit → Signal A fires
jq -nc --arg pv "1.1" --arg w "$WRITER_ID" --arg ts "2026-05-20T12:00:00Z" \
  --arg dp "$DEST" --arg sha "$PACKET_SHA" --arg body "$BODY" \
  --arg ot "md" --arg pk "writer-emit" \
  '{packet_version:$pv,writer_id:$w,emitted_at:$ts,destination_path:$dp,content_sha256:$sha,body:$body,output_type:$ot,metadata:{},packet_kind:$pk}' \
  > "$PACKET"

# Pre-state: destination content sha
DEST_PRE_SHA=$(shasum -a 256 "$DEST" 2>/dev/null | awk '{print $1}')

bash "$AMENDER" --staging-root "$STAGING_ROOT" --prompt-root "$VAULT_WRITER_STATE_ROOT/prompts" \
  --doc-deps-file "$DOC_DEPS" --staging-emit "$STAGING_EMIT" --manifest-record "$MANIFEST_RECORD" \
  --audit-log "$CLAUDE_LOG_DIR/doc-amender.log" --once >/dev/null 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "doc-amender exits 0 (operator-edit gate did not crash)" || emit_fail "amender rc=$RC: $(cat "$TEMPROOT/stderr")"

# ---- Conflict sidecar assertions --------------------------------------------
SIDECAR="${PACKET}.amender-conflict.json"
[ -f "$SIDECAR" ] && emit_pass "amender-conflict.json sidecar created" || emit_fail "sidecar missing: $SIDECAR"

if [ -f "$SIDECAR" ]; then
  if jq -e '.reason == "operator-edit-wins"' "$SIDECAR" >/dev/null 2>&1; then
    emit_pass "sidecar reason = operator-edit-wins"
  else
    emit_fail "sidecar reason wrong: $(jq -r '.reason' "$SIDECAR")"
  fi
  if jq -e --arg dp "$DEST" '.destination_path == $dp' "$SIDECAR" >/dev/null 2>&1; then
    emit_pass "sidecar destination_path = original destination"
  else
    emit_fail "sidecar destination_path drift"
  fi
  if jq -e '.packet_kind == "amender-conflict"' "$SIDECAR" >/dev/null 2>&1; then
    emit_pass "sidecar packet_kind = amender-conflict"
  else
    emit_fail "sidecar packet_kind wrong"
  fi
  if jq -e --arg p "$PACKET" '.original_packet == $p' "$SIDECAR" >/dev/null 2>&1; then
    emit_pass "sidecar names original packet"
  else
    emit_fail "sidecar original_packet ref wrong"
  fi
fi

# ---- LLM was NOT invoked (mock would have failed if called with MOCK_FAIL=1) ---
# Audit row says result=OPERATOR-EDIT, not FAIL
AUDIT=$(grep -F '"op":"survivorship-skip"' "$CLAUDE_LOG_DIR/doc-amender.log" 2>/dev/null | head -1)
[ -n "$AUDIT" ] && emit_pass "audit row recorded survivorship-skip op" || emit_fail "no survivorship-skip audit row"
if [ -n "$AUDIT" ]; then
  printf '%s' "$AUDIT" | jq -e '.result == "OPERATOR-EDIT" and .reason == "operator-edit-detected"' >/dev/null 2>&1 \
    && emit_pass "audit row carries OPERATOR-EDIT result + operator-edit-detected reason" \
    || emit_fail "audit row content wrong: $AUDIT"
fi

# claude binary was NOT invoked (no claude-p audit op)
grep -qF '"op":"claude-p"' "$CLAUDE_LOG_DIR/doc-amender.log" 2>/dev/null && emit_fail "claude-p invoked unexpectedly (survivorship gate did not short-circuit)" || emit_pass "claude-p NOT invoked (survivorship gate short-circuited)"

# ---- Original packet retained for operator triage ---------------------------
[ -f "$PACKET" ] && emit_pass "original packet retained for /amend-accept triage" || emit_fail "original packet deleted (operator cannot triage)"

# ---- Destination UNTOUCHED --------------------------------------------------
DEST_POST_SHA=$(shasum -a 256 "$DEST" 2>/dev/null | awk '{print $1}')
[ "$DEST_PRE_SHA" = "$DEST_POST_SHA" ] && emit_pass "destination content UNCHANGED" || emit_fail "destination mutated despite operator-edit gate"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%s\n' "$FAILED_CHECKS"; exit 1; }
exit 0
