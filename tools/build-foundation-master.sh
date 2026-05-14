#!/bin/bash
# build-foundation-master.sh — SP13 T-2 (2026-05-14); extended SP13 T-3 (2026-05-14)
#
# Composes foundation governance pillars into governance/foundation-master.json
# at foundation-repo RELEASE time per feedback_ship_bundle_dont_build_on_consumer.
# Adopters never build; install.sh ships the composed artifact as immutable
# shipped state.
#
# Inputs (read-only):
#   governance/frontmatter-rules.json       (SP13 T-4 absorbed vault-schema content)
#   governance/tagging-rules.json           (SP13 T-4 canonical taxonomy)
#   governance/naming-rules.json
#   governance/mandatory-files-rules.json
#   governance/doc-dependencies.json
#   governance/file-type-contracts/*.json   (k8s paramKind contracts)
#   governance/_index.json
#   schemas/gate-config.json                (interim contributor — SP13 T-3 absorbs r32.type_aliases
#                                            + r32.exempt_paths + r47.tag_cap + r47.exempt_paths union
#                                            into top-level bundle slots; retires SP13 T-6)
#
# Output (single artifact):
#   governance/foundation-master.json
#
# Deterministic discipline:
#   - All composition uses `jq -S` (sorted keys; canonical JSON serialization).
#   - bundle_version = sha256(canonical-serialized bundle WITHOUT _meta). Same
#     inputs -> same bundle_version. _meta carries built_at + source mtimes but
#     does NOT participate in the version hash.
#   - r47_exempt_paths_composed: deduped + sorted (sort -u) union.
#   - File ordering: jq -S enforces deterministic top-level key order.
#
# Validation:
#   - jq syntax check on every input
#   - jsonschema check on output against schemas/foundation-master-schema.json
#     (skipped with warning if python3 + jsonschema unavailable)
#
# Exit codes:
#   0  success
#   1  generic error
#   2  missing required input file
#   3  jq syntax error in input
#   4  schema validation failure on output
#   5  required tool missing (jq, shasum, date)

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SOURCE_REPO="${SOURCE_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"

OUTPUT="$SOURCE_REPO/governance/foundation-master.json"
SCHEMA="$SOURCE_REPO/schemas/foundation-master-schema.json"

# --- 1. Required tools -------------------------------------------------------
for bin in jq shasum date; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "build-foundation-master: required tool missing: $bin" >&2
    exit 5
  fi
done

# --- 2. Required inputs ------------------------------------------------------
FRONTMATTER="$SOURCE_REPO/governance/frontmatter-rules.json"
TAGGING="$SOURCE_REPO/governance/tagging-rules.json"
NAMING="$SOURCE_REPO/governance/naming-rules.json"
MANDATORY="$SOURCE_REPO/governance/mandatory-files-rules.json"
DOC_DEPS="$SOURCE_REPO/governance/doc-dependencies.json"
INDEX="$SOURCE_REPO/governance/_index.json"
FILE_TYPE_CONTRACTS_DIR="$SOURCE_REPO/governance/file-type-contracts"
GATE_CONFIG="$SOURCE_REPO/schemas/gate-config.json"

for f in "$FRONTMATTER" "$TAGGING" "$NAMING" "$MANDATORY" "$DOC_DEPS" "$INDEX"; do
  if [ ! -f "$f" ]; then
    echo "build-foundation-master: missing required input: $f" >&2
    exit 2
  fi
  if ! jq -e . "$f" >/dev/null 2>&1; then
    echo "build-foundation-master: invalid JSON: $f" >&2
    exit 3
  fi
done

# --- 3. Source mtimes (ISO8601 UTC) ------------------------------------------
mtime_iso() {
  # macOS BSD stat; GNU stat differs but date -r is portable
  local f="$1"
  date -u -r "$f" "+%Y-%m-%dT%H:%M:%SZ"
}

BUILD_AT=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

# --- 4. Compose r47_exempt_paths_composed (deduped sorted union) ------------
# Canonical declarations: tagging-rules.json#rules[id=R-47].r47_exempt_paths
# Interim contributor: gate-config.json#r47.exempt_paths (until SP13 T-6 retirement)
TAGGING_R47=$(jq -r '.rules[] | select(.id=="R-47") | .r47_exempt_paths[]' "$TAGGING")
if [ -f "$GATE_CONFIG" ] && jq -e . "$GATE_CONFIG" >/dev/null 2>&1; then
  GATE_R47=$(jq -r '.r47.exempt_paths[]' "$GATE_CONFIG" 2>/dev/null || true)
else
  GATE_R47=""
fi
R47_COMPOSED_JSON=$(printf '%s\n%s\n' "$TAGGING_R47" "$GATE_R47" | LC_ALL=C sort -u | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))')

# --- 4b. SP13 T-3: Absorb gate-config r32/r47 residual slices ----------------
# T-3 freeze-with-marker discipline: hooks read foundation-master.json exclusively
# while gate-config.json physical retirement waits for T-6. The 3 slices below
# carry over verbatim from gate-config.json into top-level bundle slots:
#   r32_type_aliases   (alias→canonical map; 5 entries)
#   r32_exempt_paths   (R-32 type-check exempt globs; 4 entries)
#   r47_tag_cap        (per-file tag count cap; integer)
# These slots are explicitly interim. T-6 pillar-shard decides final resting
# (frontmatter-rules.json or tagging-rules.json) with full migration context.
if [ -f "$GATE_CONFIG" ] && jq -e . "$GATE_CONFIG" >/dev/null 2>&1; then
  R32_TYPE_ALIASES_JSON=$(jq -S '.r32.type_aliases // {}' "$GATE_CONFIG")
  R32_EXEMPT_PATHS_JSON=$(jq -S '.r32.exempt_paths // []' "$GATE_CONFIG")
  R47_TAG_CAP_JSON=$(jq -S '.r47.tag_cap // 25' "$GATE_CONFIG")
else
  R32_TYPE_ALIASES_JSON='{}'
  R32_EXEMPT_PATHS_JSON='[]'
  R47_TAG_CAP_JSON='25'
fi

# --- 5. Compose file-type-contracts (key = filename without extension) ------
FTC_JSON='{}'
if [ -d "$FILE_TYPE_CONTRACTS_DIR" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    name=$(basename "$f" .json)
    contract=$(jq -S '.' "$f")
    FTC_JSON=$(jq -S --arg k "$name" --argjson v "$contract" '. + {($k): $v}' <<<"$FTC_JSON")
  done < <(LC_ALL=C find "$FILE_TYPE_CONTRACTS_DIR" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
fi

# --- 6. Build source_file_mtimes block --------------------------------------
mt_frontmatter=$(mtime_iso "$FRONTMATTER")
mt_tagging=$(mtime_iso "$TAGGING")
mt_naming=$(mtime_iso "$NAMING")
mt_mandatory=$(mtime_iso "$MANDATORY")
mt_doc_deps=$(mtime_iso "$DOC_DEPS")
mt_index=$(mtime_iso "$INDEX")

SOURCE_MTIMES_JSON=$(jq -n -S \
  --arg fm "$mt_frontmatter" \
  --arg tg "$mt_tagging" \
  --arg nm "$mt_naming" \
  --arg mf "$mt_mandatory" \
  --arg dd "$mt_doc_deps" \
  --arg ix "$mt_index" \
  '{
    "governance/frontmatter-rules.json": $fm,
    "governance/tagging-rules.json": $tg,
    "governance/naming-rules.json": $nm,
    "governance/mandatory-files-rules.json": $mf,
    "governance/doc-dependencies.json": $dd,
    "governance/_index.json": $ix
  }')

# --- 7. Compose the bundle (sans _meta) --------------------------------------
FRONTMATTER_JSON=$(jq -S '.' "$FRONTMATTER")
TAGGING_JSON=$(jq -S '.' "$TAGGING")
NAMING_JSON=$(jq -S '.' "$NAMING")
MANDATORY_JSON=$(jq -S '.' "$MANDATORY")
DOC_DEPS_JSON=$(jq -S '.' "$DOC_DEPS")
INDEX_JSON=$(jq -S '.' "$INDEX")
TYPES_LIFT_JSON=$(jq -S '.types | del(._description)' "$FRONTMATTER")

BUNDLE_BODY=$(jq -n -S \
  --argjson fm "$FRONTMATTER_JSON" \
  --argjson tg "$TAGGING_JSON" \
  --argjson nm "$NAMING_JSON" \
  --argjson mf "$MANDATORY_JSON" \
  --argjson dd "$DOC_DEPS_JSON" \
  --argjson ix "$INDEX_JSON" \
  --argjson ftc "$FTC_JSON" \
  --argjson r47 "$R47_COMPOSED_JSON" \
  --argjson r32ta "$R32_TYPE_ALIASES_JSON" \
  --argjson r32ep "$R32_EXEMPT_PATHS_JSON" \
  --argjson r47cap "$R47_TAG_CAP_JSON" \
  --argjson types "$TYPES_LIFT_JSON" \
  '{
    "schema_version": "1.1.0",
    "_description": "Composed foundation governance bundle (SP13 T-2 + T-3). Built deterministically from foundation-repo authoring pillars by tools/build-foundation-master.sh. Shipped as immutable artifact to adopter ~/.claude/governance/foundation-master.json per feedback_ship_bundle_dont_build_on_consumer; adopters never build. Hooks load this bundle once per write-session; per-rule lookups derive from this composed view.",
    "frontmatter": $fm,
    "tagging": $tg,
    "naming": $nm,
    "mandatory_files": $mf,
    "doc_dependencies": $dd,
    "file_type_contracts": $ftc,
    "_index": $ix,
    "r47_exempt_paths_composed": $r47,
    "r32_type_aliases": $r32ta,
    "r32_exempt_paths": $r32ep,
    "r47_tag_cap": $r47cap,
    "types": $types,
    "_sp13_provenance": "SP13 T-2 (2026-05-14) initial build; SP13 T-3 (2026-05-14) extended bundle to absorb gate-config residual slices (r32_type_aliases + r32_exempt_paths + r47_tag_cap) so hooks/pre-write-guard.sh + hooks/post-write-verify.sh can drop direct gate-config reads while gate-config physical retirement waits for T-6. Composes 6 pillar files + N file-type-contracts. Gate-config dissolved with marker in SP13 T-3 commit (mirrors T-4 vault-schema freeze-with-marker pattern per feedback_freeze_with_marker_retirement_pattern)."
  }')

# --- 8. bundle_version = sha256 of canonical body (without _meta) -----------
BUNDLE_VERSION=$(printf '%s' "$BUNDLE_BODY" | shasum -a 256 | awk '{print $1}')

# --- 9. Stamp _meta + assemble final bundle ---------------------------------
META_JSON=$(jq -n -S \
  --arg bv "$BUNDLE_VERSION" \
  --arg ba "$BUILD_AT" \
  --argjson mtimes "$SOURCE_MTIMES_JSON" \
  --argjson src_count 6 \
  '{
    "bundle_version": $bv,
    "built_at": $ba,
    "source_file_mtimes": $mtimes,
    "build_tool": "tools/build-foundation-master.sh",
    "deterministic_serialization": "jq -S sorted-keys canonical JSON; bundle_version excludes _meta block from hash input",
    "source_files_count": $src_count,
    "_provenance": "SP13 T-2 build. Same source files (by content) -> same bundle_version. _meta.built_at + _meta.source_file_mtimes intentionally excluded from bundle_version hash so identical content rebuilt at different times produces stable version."
  }')

FINAL_BUNDLE=$(jq -S --argjson meta "$META_JSON" '. + {"_meta": $meta}' <<<"$BUNDLE_BODY")

# --- 10. Write atomically ----------------------------------------------------
TMP_OUT="$OUTPUT.tmp.$$"
printf '%s\n' "$FINAL_BUNDLE" > "$TMP_OUT"

# --- 11. Validate output -----------------------------------------------------
if ! jq -e . "$TMP_OUT" >/dev/null 2>&1; then
  echo "build-foundation-master: output is not valid JSON" >&2
  rm -f "$TMP_OUT"
  exit 1
fi

if [ -f "$SCHEMA" ] && command -v python3 >/dev/null 2>&1; then
  if python3 -c "import jsonschema" >/dev/null 2>&1; then
    if ! python3 -c "
import json, sys
import jsonschema
with open('$SCHEMA') as f: schema = json.load(f)
with open('$TMP_OUT') as f: bundle = json.load(f)
try:
    jsonschema.validate(bundle, schema)
    print('schema-validation: PASS')
except jsonschema.ValidationError as e:
    print('schema-validation: FAIL', file=sys.stderr)
    print(f'  path: {list(e.absolute_path)}', file=sys.stderr)
    print(f'  msg: {e.message}', file=sys.stderr)
    sys.exit(4)
"; then
      rm -f "$TMP_OUT"
      exit 4
    fi
  else
    echo "build-foundation-master: jsonschema not installed; skipping schema validation" >&2
  fi
fi

# --- 12. Atomic move ---------------------------------------------------------
mv -f "$TMP_OUT" "$OUTPUT"

echo "build-foundation-master: wrote $OUTPUT"
echo "  bundle_version: $BUNDLE_VERSION"
echo "  built_at:       $BUILD_AT"
echo "  pillars:        6"
echo "  r47_exempt_paths_composed: $(echo "$R47_COMPOSED_JSON" | jq 'length') entries"
echo "  r32_type_aliases:          $(echo "$R32_TYPE_ALIASES_JSON" | jq 'length') entries"
echo "  r32_exempt_paths:          $(echo "$R32_EXEMPT_PATHS_JSON" | jq 'length') entries"
echo "  r47_tag_cap:               $(echo "$R47_TAG_CAP_JSON")"
echo "  file_type_contracts:       $(echo "$FTC_JSON" | jq 'length') entries"
