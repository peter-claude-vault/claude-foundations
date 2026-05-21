#!/bin/bash
# tests/sp18-cleanup/sp18-archetype-removed-unit-test.sh
#
# SP18 T-3 verification: confirms foundation-master.json (regen output) carries
# zero archetype-as-governance content per the cleanup landed in T-1 + T-4 +
# T-2. Specifically asserts:
#
#   T1 — bundle contains zero references to archetype_enum / archetype_conditional_fields
#   T2 — bundle contains zero R-41 / R-51 rule entries
#   T3 — bundle path_routing._rule_shape_contract does not declare archetype
#   T4 — bundle frontmatter pillar _design_notes does not list archetype_enum
#        in absorbed_from_vault_schema
#   T5 — archetype-consistency.md librarian capability is absent from
#        governance/librarian-capabilities/ (retired per T-2)
#   T6 — governance/_index.json carries no archetype pointers
#   T7 — foundation-manifest.json is at governance/foundation-manifest.json
#        (SP18 T-3 relocated from repo root)
#   T8 — foundation-manifest.json entries do NOT include 7 pillar JSONs
#        (selective ship per T-2)
#   T9 — foundation-manifest.json entries do NOT include 4 per-pillar schemas
#        (selective ship per T-7)
#
# Hermetic: reads $REPO_ROOT artifacts directly; no $CLAUDE_HOME mutation.
# R-23: bash 3.2 compat.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUNDLE="$REPO_ROOT/governance/foundation-master.json"
MANIFEST="$REPO_ROOT/governance/foundation-manifest.json"
INDEX="$REPO_ROOT/governance/_index.json"
CAPABILITIES_DIR="$REPO_ROOT/governance/librarian-capabilities"

PASS=0
FAIL=0

assert_zero_match() {
  local pattern="$1" file="$2" label="$3"
  local count
  count="$(grep -c "$pattern" "$file" 2>/dev/null || true)"
  count="${count:-0}"
  if [ "$count" = "0" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: %d matches in %s\n' "$label" "$count" "$file" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_file_absent() {
  local path="$1" label="$2"
  if [ ! -e "$path" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: path present: %s\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_file_exists() {
  local path="$1" label="$2"
  if [ -f "$path" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: path missing: %s\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_jq_empty() {
  local file="$1" jq_filter="$2" label="$3"
  local out
  out="$(jq -r "$jq_filter" "$file" 2>/dev/null)"
  if [ -z "$out" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: jq output non-empty:\n%s\n' "$label" "$out" >&2
    FAIL=$((FAIL+1))
  fi
}

printf 'SP18 T-3 archetype-removed unit test\n'
printf 'BUNDLE=%s\n' "$BUNDLE"
printf 'MANIFEST=%s\n' "$MANIFEST"
printf '\n'

# Pre-flight: required artifacts present
if [ ! -f "$BUNDLE" ]; then
  printf 'PREREQ FAIL: bundle missing at %s; run tools/build-foundation-master.sh first\n' "$BUNDLE" >&2
  exit 10
fi
if [ ! -f "$MANIFEST" ]; then
  printf 'PREREQ FAIL: manifest missing at %s; run generate-foundation-manifest.sh first\n' "$MANIFEST" >&2
  exit 10
fi

# T1 — bundle contains zero archetype_enum / archetype_conditional_fields refs
assert_zero_match 'archetype_enum' "$BUNDLE" "T1.a: bundle has zero archetype_enum refs"
assert_zero_match 'archetype_conditional_fields' "$BUNDLE" "T1.b: bundle has zero archetype_conditional_fields refs"

# T2 — bundle contains zero R-41 / R-51 rule entries
assert_zero_match '"R-41"' "$BUNDLE" "T2.a: bundle has zero R-41 rule_id refs"
assert_zero_match '"R-51"' "$BUNDLE" "T2.b: bundle has zero R-51 rule_id refs"

# T3 — bundle path_routing._rule_shape_contract does not declare archetype field
assert_jq_empty "$BUNDLE" \
  '.frontmatter.path_routing._rule_shape_contract.archetype // empty' \
  "T3: path_routing._rule_shape_contract.archetype is absent"

# T4 — frontmatter pillar _design_notes does not list archetype_enum in absorbed_from_vault_schema
assert_jq_empty "$BUNDLE" \
  '.frontmatter._design_notes.absorbed_from_vault_schema // [] | map(select(test("archetype_enum"; "i"))) | .[]' \
  "T4: frontmatter _design_notes does not cite archetype_enum"

# T5 — archetype-consistency.md librarian capability retired (file absent)
assert_file_absent "$CAPABILITIES_DIR/archetype-consistency.md" \
  "T5: archetype-consistency.md librarian capability retired"

# T6 — governance/_index.json carries no archetype pointers
assert_zero_match 'archetype_enum' "$INDEX" "T6.a: _index.json has zero archetype_enum refs"
assert_zero_match 'archetype_conditional_fields' "$INDEX" "T6.b: _index.json has zero archetype_conditional_fields refs"

# T7 — foundation-manifest.json at governance/foundation-manifest.json (MOVE)
assert_file_exists "$MANIFEST" "T7.a: governance/foundation-manifest.json present"
assert_file_absent "$REPO_ROOT/foundation-manifest.json" \
  "T7.b: repo-root foundation-manifest.json removed (SP18 T-3 MOVE)"

# T8 — manifest entries do NOT include 7 pillar JSONs (T-2 selective ship)
for pillar in frontmatter-rules tagging-rules naming-rules mandatory-files-rules \
              doc-dependencies plans-rules vault-writers-rules; do
  assert_jq_empty "$MANIFEST" \
    --arg p "governance/$pillar.json" \
    '.files[] | select(.path == $p) | .path' \
    "T8: manifest excludes governance/$pillar.json" 2>/dev/null || {
    # Fallback: jq without --arg (sub-3.2 jq may not support)
    out="$(jq -r --arg p "governance/$pillar.json" \
      '.files[] | select(.path == $p) | .path' "$MANIFEST" 2>/dev/null)"
    if [ -z "$out" ]; then
      printf '  PASS T8: manifest excludes governance/%s.json\n' "$pillar"
      PASS=$((PASS+1))
    else
      printf '  FAIL T8: manifest includes governance/%s.json\n' "$pillar" >&2
      FAIL=$((FAIL+1))
    fi
  }
done

# T9 — manifest entries do NOT include 4 per-pillar schemas (T-7 selective ship)
for schema in doc-dependencies-schema vault-writers-rules-schema \
              processing-rules-schema plans-rules-schema; do
  out="$(jq -r --arg p "schemas/$schema.json" \
    '.files[] | select(.path == $p) | .path' "$MANIFEST" 2>/dev/null)"
  if [ -z "$out" ]; then
    printf '  PASS T9: manifest excludes schemas/%s.json (T-7)\n' "$schema"
    PASS=$((PASS+1))
  else
    printf '  FAIL T9: manifest includes schemas/%s.json (T-7 violation)\n' "$schema" >&2
    FAIL=$((FAIL+1))
  fi
done

# T10 — _index.json carries no R-41 or R-51 references
assert_zero_match '"R-41"' "$INDEX" "T10.a: _index.json has zero R-41 refs"
assert_zero_match '"R-51"' "$INDEX" "T10.b: _index.json has zero R-51 refs"

printf '\nPASS: %d\nFAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
