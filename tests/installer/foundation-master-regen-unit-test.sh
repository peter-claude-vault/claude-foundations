#!/bin/bash
# tests/installer/foundation-master-regen-unit-test.sh
#
# Synthetic unit test for SP15 T-4 — governance/foundation-master.json regen
# with new pillar 7 fields + write_shape enum on file-type contracts
# (per §A47 + §A60 + §A61 + §A62 + L-104 + L-108).
#
# Coverage (per T-4 brief assertions a–e):
#   T1: build-foundation-master.sh executes successfully (exit 0)
#   T2: Schema validation PASS (build script prints "schema-validation: PASS")
#   T3: 8 pillars present in bundle (frontmatter / tagging / naming /
#       mandatory_files / doc_dependencies / file_type_contracts /
#       vault_writers / plans)
#   T4: schema_version bumped to "1.2.0" (was 1.1.0 pre-SP15-T-4)
#   T5: _meta.source_files_count == 8 (was 6 pre-SP15-T-4)
#   T6: Pillar 7 (vault_writers) carries 3 NEW state-tier fields
#       (daily_processing_root + writer_manifest_path +
#        historical_data_warning_default) per §A47 + §A60 + §A61 + L-104
#   T7: Pillar 7 field values match foundation defaults
#   T8: Pillar 8 (plans) carries cooldown_days: 3 foundation default at
#       lifecycle.status_transitions.closed_to_archived per §A59 + §A65
#   T9: All 11 file_type_contracts entries carry write_shape field
#   T10: write_shape values match the locked SP15 T-4 per-contract mapping
#   T11: Every write_shape value is within the §A62 + L-108 enum
#        [create-only, append-template, amend-via-prompt, replace]
#   T12: Idempotent rebuild — two consecutive runs produce identical
#        bundle_version (deterministic content hash; _meta excluded)
#   T13: Idempotent rebuild — body sha256 (sans _meta) byte-identical
#        across two runs
#   T14: Required source files exist (vault-writers-rules.json +
#        plans-rules.json) — sanity-check that pillar 7 + 8 source authoring
#        landed before bundle absorb
#   T15: Committed governance/foundation-master.json matches a fresh
#        rebuild's content (sans _meta) — guards against drift between
#        committed bundle and current source pillar shape
#
# Hermetic: each test runs against the foundation-repo top via a writable
# SOURCE_REPO override pointed at a tmpdir mirror. No mutation of live
# ~/.claude. No mutation of the live foundation-repo's committed
# foundation-master.json (the build script writes into the tmpdir mirror,
# never the live tree).
# R-23: bash 3.2 compat.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILDER="$REPO_ROOT/tools/build-foundation-master.sh"
SCHEMA="$REPO_ROOT/schemas/foundation-master-schema.json"
COMMITTED_BUNDLE="$REPO_ROOT/governance/foundation-master.json"
VAULT_WRITERS_SRC="$REPO_ROOT/governance/vault-writers-rules.json"
PLANS_SRC="$REPO_ROOT/governance/plans-rules.json"
FTC_DIR="$REPO_ROOT/governance/file-type-contracts"

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
  local d
  d="$(mktemp -d -t fmaster-regen-test.XXXXXX)"
  TMPDIRS="$TMPDIRS $d"
  printf '%s' "$d"
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: expected=[%s] actual=[%s]\n' "$label" "$expected" "$actual" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_path_exists() {
  local path="$1" label="$2"
  if [ -e "$path" ]; then
    printf '  PASS %s (path: %s)\n' "$label" "$path"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (path missing: %s)\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local needle="$1" haystack="$2" label="$3"
  case "$haystack" in
    *"$needle"*)
      printf '  PASS %s\n' "$label"
      PASS=$((PASS+1))
      ;;
    *)
      printf '  FAIL %s (needle not in haystack)\n' "$label" >&2
      printf '    needle: %s\n' "$needle" >&2
      FAIL=$((FAIL+1))
      ;;
  esac
}

# Mirror the foundation-repo's read-only inputs to a writable tmpdir so the
# build script writes to the tmpdir's governance/foundation-master.json
# instead of mutating the live foundation-repo.
mirror_repo() {
  local dest="$1"
  mkdir -p "$dest"
  cp -R "$REPO_ROOT/governance" "$dest/"
  cp -R "$REPO_ROOT/schemas" "$dest/"
  cp -R "$REPO_ROOT/tools" "$dest/"
}

# Body-hash = sha256 of (bundle minus _meta), used for idempotency assertions.
body_hash() {
  jq -S 'del(._meta)' "$1" | shasum -a 256 | awk '{print $1}'
}

# ---- T1 + T2: build executes + schema validation ---------------------------

t1_build_and_schema() {
  printf '\nT1+T2: build executes + schema validation\n'
  local tmp; tmp="$(mk_tmp)"
  mirror_repo "$tmp"
  local out; out="$(SOURCE_REPO="$tmp" bash "$tmp/tools/build-foundation-master.sh" 2>&1)"
  local rc=$?
  assert_eq 0 "$rc" "T1: build exit 0"
  assert_contains "schema-validation: PASS" "$out" "T2: schema-validation PASS line emitted"
  assert_contains "pillars:        8" "$out" "T2.1: build reports 8 pillars"
}

# ---- T3-T8: pillar structure + pillar 7/8 fields ---------------------------

t3_pillar_shape() {
  printf '\nT3-T8: pillar shape + new fields\n'
  local tmp; tmp="$(mk_tmp)"
  mirror_repo "$tmp"
  SOURCE_REPO="$tmp" bash "$tmp/tools/build-foundation-master.sh" >/dev/null 2>&1
  local bundle="$tmp/governance/foundation-master.json"
  assert_path_exists "$bundle" "T3.0: bundle file written"

  # T3: 8 pillars present
  local pillar_keys; pillar_keys=$(jq -r '[
    (.frontmatter | type),
    (.tagging | type),
    (.naming | type),
    (.mandatory_files | type),
    (.doc_dependencies | type),
    (.file_type_contracts | type),
    (.vault_writers | type),
    (.plans | type)
  ] | unique | join(",")' "$bundle")
  assert_eq "object" "$pillar_keys" "T3: all 8 pillars present as objects"

  # T4: schema_version bumped to 1.2.0
  local sv; sv=$(jq -r '.schema_version' "$bundle")
  assert_eq "1.2.0" "$sv" "T4: schema_version == 1.2.0"

  # T5: _meta.source_files_count == 8
  local src_count; src_count=$(jq -r '._meta.source_files_count' "$bundle")
  assert_eq "8" "$src_count" "T5: _meta.source_files_count == 8"

  # T6: pillar 7 (vault_writers) carries 3 NEW state-tier fields
  local has_daily; has_daily=$(jq -r 'if .vault_writers.daily_processing_root then "Y" else "N" end' "$bundle")
  local has_manifest; has_manifest=$(jq -r 'if .vault_writers.writer_manifest_path then "Y" else "N" end' "$bundle")
  local has_warn; has_warn=$(jq -r 'if .vault_writers.historical_data_warning_default then "Y" else "N" end' "$bundle")
  assert_eq "Y" "$has_daily" "T6.1: pillar 7 has daily_processing_root"
  assert_eq "Y" "$has_manifest" "T6.2: pillar 7 has writer_manifest_path"
  assert_eq "Y" "$has_warn" "T6.3: pillar 7 has historical_data_warning_default"

  # T7: pillar 7 field values match foundation defaults
  local daily; daily=$(jq -r '.vault_writers.daily_processing_root' "$bundle")
  local manifest; manifest=$(jq -r '.vault_writers.writer_manifest_path' "$bundle")
  local warn; warn=$(jq -r '.vault_writers.historical_data_warning_default' "$bundle")
  assert_eq "~/.local/share/claude-stem/vault-writers/daily-processing/" "$daily" "T7.1: daily_processing_root foundation default"
  assert_eq "~/.local/share/claude-stem/vault-writers/manifest.sqlite" "$manifest" "T7.2: writer_manifest_path foundation default"
  assert_eq '^\d{4}-\d{2}-\d{2}' "$warn" "T7.3: historical_data_warning_default foundation default"

  # T8: pillar 8 (plans) carries cooldown_days: 3
  local cooldown; cooldown=$(jq -r '.plans.lifecycle.status_transitions.closed_to_archived.cooldown_days' "$bundle")
  assert_eq "3" "$cooldown" "T8: plans cooldown_days == 3 foundation default"
}

# ---- T9-T11: write_shape on file-type contracts ----------------------------

t9_write_shape() {
  printf '\nT9-T11: write_shape on file-type contracts\n'
  local tmp; tmp="$(mk_tmp)"
  mirror_repo "$tmp"
  SOURCE_REPO="$tmp" bash "$tmp/tools/build-foundation-master.sh" >/dev/null 2>&1
  local bundle="$tmp/governance/foundation-master.json"

  # T9: all 11 file_type_contracts entries carry write_shape
  local total; total=$(jq -r '.file_type_contracts | length' "$bundle")
  local with_ws; with_ws=$(jq -r '[.file_type_contracts | to_entries[] | select(.value.write_shape)] | length' "$bundle")
  assert_eq "11" "$total" "T9.1: 11 file_type_contracts in bundle"
  assert_eq "11" "$with_ws" "T9.2: all 11 carry write_shape field"

  # T10: write_shape values match the locked SP15 T-4 per-contract mapping
  local map; map=$(jq -r '.file_type_contracts | to_entries | sort_by(.key) | map("\(.key)=\(.value.write_shape)") | join(",")' "$bundle")
  local expected="CLAUDE.md=create-only,System Governance.md=create-only,_index.md=replace,doc-amender-prompt.md=create-only,handoff.md=append-template,ideation-brief.md=create-only,manifest.json=replace,meeting-note.md=create-only,spec.md=append-template,tasks.md=replace,vault-writer.md=create-only"
  assert_eq "$expected" "$map" "T10: write_shape mapping matches locked T-4 table"

  # T11: every write_shape value is within the §A62 + L-108 enum
  local bad; bad=$(jq -r '[.file_type_contracts | to_entries[] | select(.value.write_shape | IN("create-only","append-template","amend-via-prompt","replace") | not) | .key] | join(",")' "$bundle")
  assert_eq "" "$bad" "T11: every write_shape within enum"
}

# ---- T12-T13: idempotent rebuild -------------------------------------------

t12_idempotent() {
  printf '\nT12-T13: idempotent rebuild\n'
  local tmp; tmp="$(mk_tmp)"
  mirror_repo "$tmp"
  SOURCE_REPO="$tmp" bash "$tmp/tools/build-foundation-master.sh" >/dev/null 2>&1
  local v1; v1=$(jq -r '._meta.bundle_version' "$tmp/governance/foundation-master.json")
  local h1; h1=$(body_hash "$tmp/governance/foundation-master.json")

  # Sleep 1s to guarantee a different built_at; bundle_version must still match.
  sleep 1
  SOURCE_REPO="$tmp" bash "$tmp/tools/build-foundation-master.sh" >/dev/null 2>&1
  local v2; v2=$(jq -r '._meta.bundle_version' "$tmp/governance/foundation-master.json")
  local h2; h2=$(body_hash "$tmp/governance/foundation-master.json")

  assert_eq "$v1" "$v2" "T12: bundle_version identical across rebuilds"
  assert_eq "$h1" "$h2" "T13: body sha256 (sans _meta) byte-identical"
}

# ---- T14: source files exist -----------------------------------------------

t14_sources_exist() {
  printf '\nT14: pillar 7 + 8 source files exist\n'
  assert_path_exists "$VAULT_WRITERS_SRC" "T14.1: governance/vault-writers-rules.json"
  assert_path_exists "$PLANS_SRC" "T14.2: governance/plans-rules.json"
  assert_path_exists "$BUILDER" "T14.3: tools/build-foundation-master.sh"
  assert_path_exists "$SCHEMA" "T14.4: schemas/foundation-master-schema.json"
  assert_path_exists "$COMMITTED_BUNDLE" "T14.5: committed governance/foundation-master.json"
  # Spot-check all 11 file-type contracts shipped
  local ftc_count; ftc_count=$(ls -1 "$FTC_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "11" "$ftc_count" "T14.6: 11 file-type-contracts present at source"
}

# ---- T15: committed bundle matches fresh rebuild ---------------------------

t15_committed_matches_rebuild() {
  printf '\nT15: committed bundle matches fresh rebuild (sans _meta)\n'
  local tmp; tmp="$(mk_tmp)"
  mirror_repo "$tmp"
  SOURCE_REPO="$tmp" bash "$tmp/tools/build-foundation-master.sh" >/dev/null 2>&1
  local committed_hash; committed_hash=$(body_hash "$COMMITTED_BUNDLE")
  local rebuild_hash; rebuild_hash=$(body_hash "$tmp/governance/foundation-master.json")
  assert_eq "$committed_hash" "$rebuild_hash" "T15: committed bundle body sha256 == fresh rebuild body sha256"
}

# --- run all -----------------------------------------------------------------

printf '=== foundation-master-regen-unit-test ===\n'

# Sanity: required tools available
for bin in jq shasum bash python3; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'SKIP: required tool missing: %s\n' "$bin"
    exit 2
  fi
done
# Schema validation requires python3 jsonschema lib (per build script)
if ! python3 -c "import jsonschema" >/dev/null 2>&1; then
  printf 'NOTE: python3 jsonschema not installed; T2 schema-validation PASS line check still runs (build script prints "skipping schema validation" without it; T2 will FAIL surfacing the gap)\n'
fi

t1_build_and_schema
t3_pillar_shape
t9_write_shape
t12_idempotent
t14_sources_exist
t15_committed_matches_rebuild

printf '\n=== foundation-master-regen-unit-test ===\n'
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
