#!/usr/bin/env bash
# SP14 T-32 Theme D — doc-amender `reviewed: true` checkpoint survivorship.
#
# SUBSTRATE GAP NOTE (anchored to SPEC behavior; expected FAIL):
#   Per spec.md §8.5 ("3-signal survivorship hybrid: Cursor checkpoints +
#   Karpathy `reviewed: true` + existing `operator-edit-wins`"), a
#   destination carrying `reviewed: true` in frontmatter should be treated
#   as operator-reviewed: doc-amender SKIPS the destination (PAUSED audit;
#   no LLM call; original packet retained).
#
#   Current doc-amender/process.sh implements signals 1 (amender_paused) and
#   2 (operator-edit-wins last_user_edit / content-hash drift) but does NOT
#   check `reviewed: true`. This fixture anchors to spec; failure signals
#   new substrate-hotfix item (implement sig3_reviewed_checkpoint() helper
#   in doc-amender/process.sh).
#
# Per spec.md §8 (3-signal extension) + writer-pipeline-layering.md L-107.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
AMENDER="$FOUNDATION_REPO/skills/doc-amender/process.sh"
STAGING_EMIT="$FOUNDATION_REPO/lib/staging-emit.sh"
MANIFEST_RECORD="$FOUNDATION_REPO/lib/manifest-record.sh"
MOCKS_DIR="$FOUNDATION_REPO/tests/fixtures/sp14-doc-amender-mocks"

TEMPROOT="$(mktemp -d -t sp14-amender-reviewed.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT

export VAULT_ROOT="$TEMPROOT/vault"
export VAULT_WRITER_STATE_ROOT="$TEMPROOT/vault-writers"
export STAGING_ROOT="$TEMPROOT/staging"
export CLAUDE_LOG_DIR="$TEMPROOT/logs"
mkdir -p "$VAULT_ROOT/Meetings" "$VAULT_WRITER_STATE_ROOT/prompts" "$STAGING_ROOT" "$CLAUDE_LOG_DIR"

case "$STAGING_ROOT" in "$TEMPROOT"/*) ;; *) printf 'FATAL\n' >&2; exit 2 ;; esac

export PATH="$MOCKS_DIR:$PATH"

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS"$'\n'"    - $1"; }

printf '=== SP14 T-32 doc-amender-reviewed-checkpoint ===\n'
printf '          NOTE: anchored to spec; expect FAILs until sig3_reviewed_checkpoint() lands\n'

DOC_DEPS="$TEMPROOT/doc-dependencies.json"
WRITER_ID="meeting-processor"
DEST="$VAULT_ROOT/Meetings/reviewed.md"
DEST_GLOB="*/Meetings/*.md"

jq -nc --arg consumer "$DEST_GLOB" --arg writer "$WRITER_ID" \
  '{entries:[{id:"x",kind:"writer-fan-in",consumer:$consumer,upstream_writers:[$writer],amendment_strategy:"prompt-guided-amend"}]}' \
  > "$DOC_DEPS"

cat > "$VAULT_WRITER_STATE_ROOT/prompts/p.md" <<EOF
---
prompt_id: reviewed-test
amendment_strategy: prompt-guided-amend
destination_glob: $DEST_GLOB
---
Amend.
EOF

# Pre-existing destination with reviewed: true (Karpathy checkpoint pattern).
# Crucially: NO amender_paused, NO last_user_edit, NO content drift signals.
# Bytes match what the manifest would contain (no drift to confound sig2).
cat > "$DEST" <<'DEST_EOF'
---
type: meeting-note
reviewed: true
---

# Operator-reviewed checkpoint — amender should respect
DEST_EOF

mkdir -p "$STAGING_ROOT/$WRITER_ID"
# To isolate signal 3, pre-populate manifest with the destination's CURRENT sha
# so sig2 (content-hash drift) does NOT fire. This separates "reviewed: true"
# from operator-edit-wins.
bash "$MANIFEST_RECORD" init >/dev/null 2>&1
export WRITER_MANIFEST_PATH="$VAULT_WRITER_STATE_ROOT/manifest.sqlite"
DEST_CUR_SHA=$(shasum -a 256 "$DEST" | awk '{print $1}')
bash "$MANIFEST_RECORD" record-write \
  --writer-id "$WRITER_ID" --destination-path "$DEST" \
  --content-sha256 "$DEST_CUR_SHA" --write-bucket "create" >/dev/null 2>&1

BODY="# Amender input"
PACKET_SHA=$(printf '%s' "$BODY" | shasum -a 256 | awk '{print $1}')
PACKET="$STAGING_ROOT/$WRITER_ID/$PACKET_SHA.json"

jq -nc --arg pv "1.1" --arg w "$WRITER_ID" --arg ts "2026-05-20T12:00:00Z" \
  --arg dp "$DEST" --arg sha "$PACKET_SHA" --arg body "$BODY" \
  --arg ot "md" --arg pk "writer-emit" \
  '{packet_version:$pv,writer_id:$w,emitted_at:$ts,destination_path:$dp,content_sha256:$sha,body:$body,output_type:$ot,metadata:{},packet_kind:$pk}' \
  > "$PACKET"

DEST_PRE_SHA="$DEST_CUR_SHA"

bash "$AMENDER" --staging-root "$STAGING_ROOT" --prompt-root "$VAULT_WRITER_STATE_ROOT/prompts" \
  --doc-deps-file "$DOC_DEPS" --staging-emit "$STAGING_EMIT" --manifest-record "$MANIFEST_RECORD" \
  --audit-log "$CLAUDE_LOG_DIR/doc-amender.log" --once >/dev/null 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "doc-amender exits 0" || emit_fail "amender rc=$RC"

# ---- Spec expectation: reviewed:true short-circuits the amender ------------
# Audit row records survivorship-skip / REVIEWED-CHECKPOINT reason.
AUDIT_PAUSED=$(grep -F '"op":"survivorship-skip"' "$CLAUDE_LOG_DIR/doc-amender.log" 2>/dev/null | head -1)
if [ -n "$AUDIT_PAUSED" ] && printf '%s' "$AUDIT_PAUSED" | jq -e '.reason | test("reviewed")' >/dev/null 2>&1; then
  emit_pass "audit row records reviewed-checkpoint short-circuit"
else
  emit_fail "no reviewed-checkpoint audit signal (SUBSTRATE GAP — sig3_reviewed_checkpoint() not implemented in doc-amender/process.sh)"
fi

# claude-p should NOT have been invoked
grep -qF '"op":"claude-p"' "$CLAUDE_LOG_DIR/doc-amender.log" 2>/dev/null && emit_fail "claude-p invoked despite reviewed:true (SUBSTRATE GAP — signal 3 missing)" || emit_pass "claude-p NOT invoked"

# No +amender packet should be emitted
AMENDER_DIR="$STAGING_ROOT/${WRITER_ID}+amender"
REPLACEMENT_COUNT=0
if [ -d "$AMENDER_DIR" ]; then
  REPLACEMENT_COUNT=$(find "$AMENDER_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
fi
[ "$REPLACEMENT_COUNT" = "0" ] && emit_pass "no replacement packet emitted" || emit_fail "$REPLACEMENT_COUNT replacement packets emitted despite reviewed:true (SUBSTRATE GAP — signal 3 missing)"

# Original packet retained
[ -f "$PACKET" ] && emit_pass "original packet retained" || emit_fail "original packet deleted"

# Destination UNCHANGED
DEST_POST_SHA=$(shasum -a 256 "$DEST" 2>/dev/null | awk '{print $1}')
[ "$DEST_PRE_SHA" = "$DEST_POST_SHA" ] && emit_pass "destination content UNCHANGED" || emit_fail "destination mutated despite reviewed:true"

# ---- No conflict sidecar (reviewed != conflict) -----------------------------
SIDECAR="${PACKET}.amender-conflict.json"
[ ! -f "$SIDECAR" ] && emit_pass "NO amender-conflict.json sidecar (reviewed is a clean pause, not a conflict)" || emit_fail "sidecar erroneously created"

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%s\n' "$FAILED_CHECKS"; exit 1; }
exit 0
