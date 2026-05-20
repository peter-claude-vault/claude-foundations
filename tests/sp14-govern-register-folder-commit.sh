#!/usr/bin/env bash
# SP14 T-18 Theme B — /govern register folder mode commit
#
# Scope: process.sh commit --kind folder writes overlay-master.json with BOTH
# pillars atomically (frontmatter.path_routing AND mandatory_files.by_folder
# in same write); appends action-log row with kind: "folder", unregistered:
# false; vault-root CLAUDE.md is updated (tree append) OR sidecar marker is
# emitted when CLAUDE.md absent.
#
# Per Plan 81 SP14 spec.md §2 + §7 + Batch H handoff smoke test #6 + #7.
# bash 3.2 compatible.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"

TEMPROOT="$(mktemp -d -t sp14-folder-commit.XXXXXX)"
trap 'rm -rf "$TEMPROOT"' EXIT
export OVERLAY_MASTER="$TEMPROOT/overlay-master.json"
export ACTION_LOG="$TEMPROOT/governance-action-log.jsonl"
export VAULT_ROOT="$TEMPROOT/vault"
export CLAUDE_SESSION_ID="sp14-t18-folder-commit"
mkdir -p "$VAULT_ROOT"
echo '{}' > "$OVERLAY_MASTER"
: > "$ACTION_LOG"

case "$OVERLAY_MASTER" in "$TEMPROOT"/*) ;; *) printf 'FATAL: OVERLAY_MASTER not jailed: %s\n' "$OVERLAY_MASTER" >&2; exit 2 ;; esac

PASS=0
FAIL=0
FAILED_CHECKS=""
emit_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
emit_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_CHECKS="$FAILED_CHECKS\n    - $1"; }

printf '=== SP14 T-18 folder-commit ===\n'

PROPOSAL="$TEMPROOT/proposal.json"
bash "$FOUNDATION_REPO/skills/govern/register/process.sh" propose --kind folder --target Engagements >"$PROPOSAL" 2>/dev/null || {
  emit_fail "propose step failed"
}

bash "$FOUNDATION_REPO/skills/govern/register/process.sh" commit --kind folder --proposal "$PROPOSAL" >"$TEMPROOT/stdout" 2>"$TEMPROOT/stderr"
RC=$?
[ "$RC" = "0" ] && emit_pass "commit rc=0" || emit_fail "commit rc=$RC; stderr: $(cat "$TEMPROOT/stderr")"

# ---- assert R-37 atomic: BOTH pillars present in overlay --------------------
if jq -e '.frontmatter.path_routing[0].pattern == "Engagements/**"' "$OVERLAY_MASTER" >/dev/null 2>&1; then
  emit_pass "overlay-master.frontmatter.path_routing[0].pattern == Engagements/**"
else
  emit_fail "overlay-master missing frontmatter.path_routing entry; got: $(cat "$OVERLAY_MASTER")"
fi

if jq -e '.mandatory_files.by_folder["Engagements/**"][0] == "_index.md"' "$OVERLAY_MASTER" >/dev/null 2>&1; then
  emit_pass "overlay-master.mandatory_files.by_folder[Engagements/**] == [_index.md]"
else
  emit_fail "overlay-master missing mandatory_files.by_folder entry; got: $(cat "$OVERLAY_MASTER")"
fi

# ---- action-log row(s) ------------------------------------------------------
ROW_COUNT=$(wc -l < "$ACTION_LOG" | tr -d ' ')
# Library emits one row per pillar (per spec — R-37 row-per-pillar)
[ "$ROW_COUNT" = "2" ] && emit_pass "action-log has 2 rows (one per pillar)" || emit_fail "action-log row count = $ROW_COUNT (expected 2)"

ROW_KIND=$(jq -r '.kind' < <(head -1 "$ACTION_LOG"))
[ "$ROW_KIND" = "folder" ] && emit_pass "action-log row[0].kind == folder" || emit_fail "row[0].kind = '$ROW_KIND'"

ROW_UNREG=$(jq -r '.unregistered // false' < <(head -1 "$ACTION_LOG"))
[ "$ROW_UNREG" = "false" ] && emit_pass "action-log row[0].unregistered == false" || emit_fail "row[0].unregistered = '$ROW_UNREG'"

ROW_TARGET=$(jq -r '.target' < <(head -1 "$ACTION_LOG"))
[ "$ROW_TARGET" = "Engagements" ] && emit_pass "action-log row[0].target == Engagements" || emit_fail "row[0].target = '$ROW_TARGET'"

# ---- vault-root CLAUDE.md sidecar fallback (absent CLAUDE.md) --------------
SIDECAR="$VAULT_ROOT/_claude-md-tree-update-pending.json"
if [ -f "$SIDECAR" ]; then
  emit_pass "sidecar pending-update marker emitted when CLAUDE.md absent"
else
  emit_fail "sidecar pending-update marker missing"
fi

# ---- jsonschema validation --------------------------------------------------
if python3 -c "
import json, jsonschema, sys
schema = json.load(open('$FOUNDATION_REPO/schemas/overlay-master-schema.json'))
doc = json.load(open('$OVERLAY_MASTER'))
jsonschema.Draft202012Validator(schema).validate(doc)
" 2>"$TEMPROOT/schema-err"; then
  emit_pass "overlay-master.json validates against overlay-master-schema.json"
else
  emit_fail "schema validation failed: $(cat "$TEMPROOT/schema-err")"
fi

if python3 -c "
import json, jsonschema, sys
schema = json.load(open('$FOUNDATION_REPO/schemas/governance-action-log-schema.json'))
v = jsonschema.Draft202012Validator(schema)
for line in open('$ACTION_LOG'):
    line = line.strip()
    if not line: continue
    v.validate(json.loads(line))
" 2>"$TEMPROOT/log-err"; then
  emit_pass "action-log rows validate against governance-action-log-schema.json"
else
  emit_fail "action-log schema validation failed: $(cat "$TEMPROOT/log-err")"
fi

printf '\n=== Summary: %s PASS / %s FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'Failed checks:%b\n' "$FAILED_CHECKS"; exit 1; }
exit 0
