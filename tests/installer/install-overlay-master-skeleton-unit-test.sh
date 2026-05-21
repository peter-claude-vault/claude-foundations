#!/bin/bash
# tests/installer/install-overlay-master-skeleton-unit-test.sh
#
# Synthetic unit test for SP15 T-1f — overlay-master.json empty 8-pillar
# parallel skeleton ship via Step 8.5 governance/ cp -R (§A54 + §A32 + §H).
#
# Coverage (per T-1f brief assertions a–e):
#   T1: Fresh install — overlay-master.json shipped + JSON valid + 8 keys
#       (frontmatter / tagging / naming / mandatory_files / doc_dependencies /
#        file_type_contracts / vault_writers / plans) present + each value = {}
#   T2: Re-install idempotent (cp -n) — user-mutated overlay-master.json
#       preserved (skeleton ships once; lib/overlay-master-mutate.sh is the
#       sole subsequent write path)
#   T3: Dry-run JSON Step 8.5 rationale mentions overlay-master.json + T-1f
#       (Option A: no new step entry; rationale extension)
#   T4: Schema validation — shipped file validates against
#       overlay-master-schema.json (Draft 2020-12)
#   T5: lib/overlay-master-mutate.sh accepts empty skeleton as starting state
#       (dry-run mutation against the shipped file PASSES schema validation)
#
# Isolation: each test creates its own tmpdir CLAUDE_HOME; SOURCE_REPO points
# at the foundation-repo top. No mutation of live ~/.claude.
#
# R-23: bash 3.2 compat.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
OVERLAY_SRC="$REPO_ROOT/governance/overlay-master.json"
OVERLAY_SCHEMA="$REPO_ROOT/schemas/overlay-master-schema.json"
MUTATE_LIB="$REPO_ROOT/lib/overlay-master-mutate.sh"
USERBASE="$(python3 -m site --user-base 2>/dev/null || true)"

# --- harness ---
PASS=0
FAIL=0
TMPDIRS=""

cleanup() {
  for d in $TMPDIRS; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM

mk_tmp() {
  d="$(mktemp -d -t overlay-master-skeleton-test.XXXXXX)"
  TMPDIRS="$TMPDIRS $d"
  printf '%s' "$d"
}

assert_eq() {
  expected="$1"; actual="$2"; label="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: expected=[%s] actual=[%s]\n' "$label" "$expected" "$actual" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_path_exists() {
  path="$1"; label="$2"
  if [ -e "$path" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: path does not exist [%s]\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

# --- prereq sanity ---
if [ ! -x "$INSTALL_SH" ]; then
  printf 'FATAL: install.sh not executable at %s\n' "$INSTALL_SH" >&2
  exit 7
fi
if [ ! -f "$OVERLAY_SRC" ]; then
  printf 'FATAL: governance/overlay-master.json source missing at %s\n' "$OVERLAY_SRC" >&2
  exit 7
fi
if [ ! -f "$OVERLAY_SCHEMA" ]; then
  printf 'FATAL: overlay-master-schema.json missing at %s\n' "$OVERLAY_SCHEMA" >&2
  exit 7
fi
if [ ! -f "$MUTATE_LIB" ]; then
  printf 'FATAL: lib/overlay-master-mutate.sh missing at %s\n' "$MUTATE_LIB" >&2
  exit 7
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'FATAL: jq required\n' >&2
  exit 7
fi
if ! python3 -c 'import jsonschema' 2>/dev/null; then
  printf 'FATAL: python3 jsonschema module required\n' >&2
  exit 7
fi

printf '=== install-overlay-master-skeleton-unit-test ===\n'

# =====================================================================
# T1 — Fresh install: overlay-master.json shipped with 8-pillar skeleton
# =====================================================================
printf '\nT1: Fresh install — overlay-master.json 8-pillar skeleton shipped\n'

CH1="$(mk_tmp)"
rc=0
HOME="$CH1" CLAUDE_HOME="$CH1" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply >"$CH1/.stdout" 2>"$CH1/.stderr" || rc=$?
assert_eq "0" "$rc" "T1.0 install.sh exits 0 on fresh install"

assert_path_exists "$CH1/governance/overlay-master.json" "T1.1 overlay-master.json shipped to governance/"

# JSON validity
jq . "$CH1/governance/overlay-master.json" >/dev/null 2>&1
JQ_RC=$?
assert_eq "0" "$JQ_RC" "T1.2 overlay-master.json is valid JSON"

# 8 keys present
KEY_COUNT="$(jq -r 'keys | length' "$CH1/governance/overlay-master.json" 2>/dev/null)"
assert_eq "8" "$KEY_COUNT" "T1.3 overlay-master.json has exactly 8 top-level keys"

# Each pillar slot present + value is {}
for pillar in frontmatter tagging naming mandatory_files doc_dependencies file_type_contracts vault_writers plans; do
  HAS_PILLAR="$(jq -r --arg p "$pillar" 'if has($p) then "yes" else "no" end' "$CH1/governance/overlay-master.json" 2>/dev/null)"
  assert_eq "yes" "$HAS_PILLAR" "T1.4 pillar slot present: $pillar"
  PILLAR_VALUE="$(jq -c --arg p "$pillar" '.[$p]' "$CH1/governance/overlay-master.json" 2>/dev/null)"
  assert_eq "{}" "$PILLAR_VALUE" "T1.5 pillar slot empty (value = {}): $pillar"
done

# =====================================================================
# T2 — Re-install idempotent (cp -n default): user mutations preserved
# =====================================================================
printf '\nT2: Re-install idempotent — cp -n preserves user-mutated overlay-master.json\n'

# Reuse $CH1 (already has overlay-master.json from T1). Simulate a /govern
# register mutation that landed a real entry — we want re-install to NOT
# clobber it.
USER_MUTATED_OVERLAY='{
  "frontmatter": {"types": {"my-custom-type": {}}},
  "tagging": {},
  "naming": {},
  "mandatory_files": {},
  "doc_dependencies": {},
  "file_type_contracts": {},
  "vault_writers": {},
  "plans": {}
}'
printf '%s' "$USER_MUTATED_OVERLAY" > "$CH1/governance/overlay-master.json"

rc=0
T2_BACKUP="$CH1/.backup-t2"
printf 'I-UNDERSTAND-OVERWRITE-RISK\n' | \
  HOME="$CH1" CLAUDE_HOME="$CH1" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply --force-install --backup-dir "$T2_BACKUP" \
  >"$CH1/.stdout2" 2>"$CH1/.stderr2" || rc=$?
assert_eq "0" "$rc" "T2.0 re-install exits 0 (G2-sentinel + G3-backup)"

T2_HAS_MUTATION="$(jq -r '.frontmatter.types | has("my-custom-type") | tostring' "$CH1/governance/overlay-master.json" 2>/dev/null)"
assert_eq "true" "$T2_HAS_MUTATION" "T2.1 user mutation (frontmatter.types.my-custom-type) preserved across re-install"

# =====================================================================
# T3 — Dry-run JSON Step 8.5 rationale documents T-1f overlay-master.json
# =====================================================================
printf '\nT3: Dry-run JSON Step 8.5 rationale documents T-1f overlay-master.json\n'

CH3="$(mk_tmp)"
HOME="$CH3" CLAUDE_HOME="$CH3" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" >"$CH3/.dry-run.json" 2>"$CH3/.dry-run.stderr" || true

jq . "$CH3/.dry-run.json" >/dev/null 2>&1
JQ_RC=$?
assert_eq "0" "$JQ_RC" "T3.0 dry-run output is valid JSON"

# Step 8.5 must exist
STEP_85_STEP="$(jq -r '.actions[] | select(.step == 8.5) | .step' "$CH3/.dry-run.json" 2>/dev/null)"
assert_eq "8.5" "$STEP_85_STEP" "T3.1 step 8.5 entry present in dry-run actions array"

# Step 8.5 rationale mentions overlay-master.json + T-1f
STEP_85_RATIONALE="$(jq -r '.actions[] | select(.step == 8.5) | .rationale' "$CH3/.dry-run.json" 2>/dev/null)"
case "$STEP_85_RATIONALE" in
  *overlay-master.json*) assert_eq "found" "found" "T3.2 step 8.5 rationale mentions overlay-master.json" ;;
  *) assert_eq "found" "NOT-FOUND" "T3.2 step 8.5 rationale mentions overlay-master.json" ;;
esac
case "$STEP_85_RATIONALE" in
  *T-1f*) assert_eq "found" "found" "T3.3 step 8.5 rationale references SP15 T-1f" ;;
  *) assert_eq "found" "NOT-FOUND" "T3.3 step 8.5 rationale references SP15 T-1f" ;;
esac

# =====================================================================
# T4 — Schema validation: shipped overlay-master.json validates against
#      overlay-master-schema.json (Draft 2020-12)
# =====================================================================
printf '\nT4: Schema validation — shipped file validates against overlay-master-schema.json\n'

CH4="$(mk_tmp)"
rc=0
HOME="$CH4" CLAUDE_HOME="$CH4" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply >"$CH4/.stdout" 2>"$CH4/.stderr" || rc=$?
assert_eq "0" "$rc" "T4.0 install.sh exits 0"

python3 - "$CH4/governance/overlay-master.json" "$OVERLAY_SCHEMA" >"$CH4/.schema-validation.out" 2>&1 <<'PY'
import json, sys, jsonschema
candidate_path = sys.argv[1]
schema_path = sys.argv[2]
with open(schema_path) as f:
    schema = json.load(f)
with open(candidate_path) as f:
    candidate = json.load(f)
validator = jsonschema.Draft202012Validator(schema)
errors = sorted(validator.iter_errors(candidate), key=lambda e: list(e.path))
if errors:
    for err in errors:
        print(f"ERROR: {list(err.path)}: {err.message}")
    sys.exit(1)
print("OK")
sys.exit(0)
PY
SCHEMA_RC=$?
assert_eq "0" "$SCHEMA_RC" "T4.1 shipped overlay-master.json validates against schema (Draft 2020-12)"

SCHEMA_OUT="$(cat "$CH4/.schema-validation.out")"
assert_eq "OK" "$SCHEMA_OUT" "T4.2 schema validator emitted OK (no errors)"

# =====================================================================
# T5 — lib/overlay-master-mutate.sh accepts empty skeleton as starting state
# =====================================================================
printf '\nT5: lib/overlay-master-mutate.sh dry-run against empty skeleton PASSES\n'

CH5="$(mk_tmp)"
rc=0
HOME="$CH5" CLAUDE_HOME="$CH5" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply >"$CH5/.stdout" 2>"$CH5/.stderr" || rc=$?
assert_eq "0" "$rc" "T5.0 install.sh exits 0"

# Build a synthetic mutation payload (valid for frontmatter pillar — any
# object shape works against the min-viable {type: object} stub)
mkdir -p "$CH5/payloads"
printf '{"types": {"test-type": {}}}' > "$CH5/payloads/frontmatter-payload.json"

# Run lib in dry-run mode against the shipped empty skeleton. Use the
# repo-local lib (not yet copied to $CLAUDE_HOME/hooks/lib/ — install.sh ships
# it at Step 3 but the test exercises the lib's contract directly against the
# shipped overlay-master.json).
rc=0
OVERLAY_MASTER="$CH5/governance/overlay-master.json" \
  SCHEMA="$OVERLAY_SCHEMA" \
  ACTION_LOG="$CH5/governance/governance-action-log.jsonl" \
  bash "$MUTATE_LIB" \
    --pillar frontmatter \
    --payload-file "$CH5/payloads/frontmatter-payload.json" \
    --dry-run \
    >"$CH5/.mutate.stdout" 2>"$CH5/.mutate.stderr" || rc=$?
assert_eq "0" "$rc" "T5.1 lib dry-run against empty skeleton exits 0"

if grep -q "dry-run validation PASS" "$CH5/.mutate.stderr"; then
  assert_eq "found" "found" "T5.2 lib emits 'dry-run validation PASS' against empty skeleton"
else
  assert_eq "found" "NOT-FOUND" "T5.2 lib emits 'dry-run validation PASS' against empty skeleton"
fi

# Verify the shipped overlay-master.json is unchanged by the dry-run (no
# write should have occurred)
T5_KEYS_AFTER="$(jq -r 'keys | length' "$CH5/governance/overlay-master.json" 2>/dev/null)"
assert_eq "8" "$T5_KEYS_AFTER" "T5.3 overlay-master.json unchanged after dry-run (still 8 keys)"

T5_FRONTMATTER_AFTER="$(jq -c '.frontmatter' "$CH5/governance/overlay-master.json" 2>/dev/null)"
assert_eq "{}" "$T5_FRONTMATTER_AFTER" "T5.4 frontmatter pillar still empty after dry-run (no live write)"

# =====================================================================
# Summary
# =====================================================================
printf '\n=== install-overlay-master-skeleton-unit-test ===\n'
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
