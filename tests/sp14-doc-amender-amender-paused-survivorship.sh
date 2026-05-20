#!/usr/bin/env bash
# SP14 T-32 Theme D — doc-amender amender_paused survivorship signal.
#
# Scope: when destination carries `amender_paused: true` in YAML frontmatter,
# doc-amender SKIPS the destination entirely. No LLM call, no sidecar, no
# audit-FAIL — just an audit row recording PAUSED reason. Original packet
# retained.
#
# Per spec.md §8.5 + writer-pipeline-layering.md L-107 (3rd survivorship
# signal: `amender_paused: true` extends 2-signal operator-edit-wins to
# 3-signal hybrid per §A62). bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
AMENDER="$FOUNDATION_REPO/skills/doc-amender/process.sh"
STAGING_EMIT="$FOUNDATION_REPO/lib/staging-emit.sh"
MANIFEST_RECORD="$FOUNDATION_REPO/lib/manifest-record.sh"
MOCKS_DIR="$FOUNDATION_REPO/tests/fixtures/sp14-doc-amender-mocks"

TEMPROOT="$(mktemp -d -t sp14-amender-paused.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT

export VAULT_ROOT="$TEMPROOT/vault"
export VAULT_WRITER_STATE_ROOT="$TEMPROOT/vault-writers"
export STAGING_ROOT="$TEMPROOT/staging"
export CLAUDE_LOG_DIR="$TEMPROOT/logs"
mkdir -p "$VAULT_ROOT/Meetings" "$VAULT_WRITER_STATE_ROOT/prompts" "$STAGING_ROOT" "$CLAUDE_LOG_DIR"

case "$STAGING_ROOT" in "$TEMPROOT"/*) ;; *) printf 'FATAL\n' >&2; exit 2 ;; esac

export PATH="$MOCKS_DIR:$PATH"
# If mock is invoked (which it shouldn't be), fail loudly.
export MOCK_FAIL=1

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS"$'\n'"    - $1"; }

printf '=== SP14 T-32 doc-amender-amender-paused-survivorship ===\n'

DOC_DEPS="$TEMPROOT/doc-dependencies.json"
WRITER_ID="meeting-processor"
DEST="$VAULT_ROOT/Meetings/paused-meeting.md"
DEST_GLOB="*/Meetings/*.md"

jq -nc --arg consumer "$DEST_GLOB" --arg writer "$WRITER_ID" \
  '{entries:[{id:"x",kind:"writer-fan-in",consumer:$consumer,upstream_writers:[$writer],amendment_strategy:"prompt-guided-amend"}]}' \
  > "$DOC_DEPS"

cat > "$VAULT_WRITER_STATE_ROOT/prompts/p.md" <<EOF
---
prompt_id: paused-test
amendment_strategy: prompt-guided-amend
destination_glob: $DEST_GLOB
---
Amend.
EOF

# Pre-existing destination with amender_paused: true frontmatter.
cat > "$DEST" <<'DEST_EOF'
---
type: meeting-note
amender_paused: true
---

# Paused — operator does not want amender to touch this
DEST_EOF

mkdir -p "$STAGING_ROOT/$WRITER_ID"
BODY="# Amender input"
PACKET_SHA=$(printf '%s' "$BODY" | shasum -a 256 | awk '{print $1}')
PACKET="$STAGING_ROOT/$WRITER_ID/$PACKET_SHA.json"

jq -nc --arg pv "1.1" --arg w "$WRITER_ID" --arg ts "2026-05-20T12:00:00Z" \
  --arg dp "$DEST" --arg sha "$PACKET_SHA" --arg body "$BODY" \
  --arg ot "md" --arg pk "writer-emit" \
  '{packet_version:$pv,writer_id:$w,emitted_at:$ts,destination_path:$dp,content_sha256:$sha,body:$body,output_type:$ot,metadata:{},packet_kind:$pk}' \
  > "$PACKET"

DEST_PRE_SHA=$(shasum -a 256 "$DEST" 2>/dev/null | awk '{print $1}')

bash "$AMENDER" --staging-root "$STAGING_ROOT" --prompt-root "$VAULT_WRITER_STATE_ROOT/prompts" \
  --doc-deps-file "$DOC_DEPS" --staging-emit "$STAGING_EMIT" --manifest-record "$MANIFEST_RECORD" \
  --audit-log "$CLAUDE_LOG_DIR/doc-amender.log" --once >/dev/null 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "doc-amender exits 0 (amender_paused gate did not crash)" || emit_fail "amender rc=$RC: $(cat "$TEMPROOT/stderr")"

# ---- No conflict sidecar (paused != conflict) -------------------------------
SIDECAR="${PACKET}.amender-conflict.json"
[ ! -f "$SIDECAR" ] && emit_pass "NO amender-conflict.json sidecar (paused is not a conflict)" || emit_fail "sidecar erroneously created on amender_paused path"

# ---- Audit row records PAUSED ----------------------------------------------
AUDIT=$(grep -F '"op":"survivorship-skip"' "$CLAUDE_LOG_DIR/doc-amender.log" 2>/dev/null | head -1)
[ -n "$AUDIT" ] && emit_pass "audit row recorded survivorship-skip op" || emit_fail "no survivorship-skip audit row"
if [ -n "$AUDIT" ]; then
  printf '%s' "$AUDIT" | jq -e '.result == "PAUSED" and .reason == "amender-paused-frontmatter"' >/dev/null 2>&1 \
    && emit_pass "audit row carries PAUSED result + amender-paused-frontmatter reason" \
    || emit_fail "audit row content wrong: $AUDIT"
fi

# ---- LLM NOT invoked --------------------------------------------------------
grep -qF '"op":"claude-p"' "$CLAUDE_LOG_DIR/doc-amender.log" 2>/dev/null && emit_fail "claude-p invoked despite amender_paused" || emit_pass "claude-p NOT invoked (paused gate short-circuited)"

# ---- Original packet retained -----------------------------------------------
[ -f "$PACKET" ] && emit_pass "original packet retained" || emit_fail "original packet deleted"

# ---- Destination UNCHANGED --------------------------------------------------
DEST_POST_SHA=$(shasum -a 256 "$DEST" 2>/dev/null | awk '{print $1}')
[ "$DEST_PRE_SHA" = "$DEST_POST_SHA" ] && emit_pass "destination content UNCHANGED" || emit_fail "destination mutated despite amender_paused"

# ---- No +amender packet emitted ---------------------------------------------
AMENDER_DIR="$STAGING_ROOT/${WRITER_ID}+amender"
[ ! -d "$AMENDER_DIR" ] && emit_pass "no +amender staging dir created (no replacement emission)" || {
  COUNT=$(find "$AMENDER_DIR" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  [ "$COUNT" = "0" ] && emit_pass "+amender dir empty (no replacement emission)" || emit_fail "$COUNT replacement packets emitted despite paused"
}

# ---- Verify amender_paused alt-case values also pause -----------------------
# Re-stage with destination using `True` (capitalized).
cat > "$DEST" <<'DEST_EOF'
---
type: meeting-note
amender_paused: True
---

# Paused (capitalized)
DEST_EOF
# Re-stage packet
rm -f "$CLAUDE_LOG_DIR/doc-amender.log"
PACKET_SHA2=$(printf '%s' "different body" | shasum -a 256 | awk '{print $1}')
PACKET2="$STAGING_ROOT/$WRITER_ID/$PACKET_SHA2.json"
jq -nc --arg pv "1.1" --arg w "$WRITER_ID" --arg ts "2026-05-20T12:00:00Z" \
  --arg dp "$DEST" --arg sha "$PACKET_SHA2" --arg body "different body" \
  --arg ot "md" --arg pk "writer-emit" \
  '{packet_version:$pv,writer_id:$w,emitted_at:$ts,destination_path:$dp,content_sha256:$sha,body:$body,output_type:$ot,metadata:{},packet_kind:$pk}' \
  > "$PACKET2"
rm -f "$PACKET"  # remove first packet so we don't re-test it
bash "$AMENDER" --staging-root "$STAGING_ROOT" --prompt-root "$VAULT_WRITER_STATE_ROOT/prompts" \
  --doc-deps-file "$DOC_DEPS" --staging-emit "$STAGING_EMIT" --manifest-record "$MANIFEST_RECORD" \
  --audit-log "$CLAUDE_LOG_DIR/doc-amender.log" --once >/dev/null 2>&1
AUDIT2=$(grep -F '"result":"PAUSED"' "$CLAUDE_LOG_DIR/doc-amender.log" 2>/dev/null | head -1)
[ -n "$AUDIT2" ] && emit_pass "alt-case 'True' also recognized as paused" || emit_fail "alt-case True not recognized"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%s\n' "$FAILED_CHECKS"; exit 1; }
exit 0
