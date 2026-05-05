#!/usr/bin/env bash
# lib/provenance-frontmatter.sh — SP12 T-2 (Plan 71 SP12 Session 1)
#
# Provenance frontmatter helpers. Every auto-authored artifact written by a
# Group B surface MUST carry the contract declared in
# schemas/provenance-frontmatter-schema.json. This library produces conformant
# YAML blocks ready for prepend, and validates parsed frontmatter blocks
# against the schema (jq structural fallback when ajv is unavailable).
#
# OUTPUT CONTRACT (R-43):
#   Files written: none directly. Helpers return YAML on stdout for callers
#                  to prepend to artifacts.
#   Schema-types:  schemas/provenance-frontmatter-schema.json (Draft-07).
#   Pre-write validation: pf_validate runs structural validation + (when ajv
#                  available) full schema validation before consumers prepend.
#   Failure mode:  BLOCK AND LOG. pf_emit returns non-zero on missing args;
#                  pf_validate returns non-zero on schema violation.
#
# API:
#   pf_emit <surface-id> <generated-from> [last-user-edit-iso|--null] \
#           [--consulted-at <ISO-ts>] [--response-hash <sha256-hex>]
#     Emit a YAML frontmatter block (between '---' fences) carrying the
#     three required provenance fields. Default last_user_edit is null
#     (no user edit yet). Pass --null explicitly OR omit the third
#     positional. Pass an ISO-8601 timestamp to lock in last_user_edit.
#
#     SP15 T-3 additivity contract: the optional flags --consulted-at
#     and --response-hash emit the SP15 consultation-gate fields
#     `consulted_at` + `consultation_response_hash` ONLY when supplied.
#     When omitted, neither field is emitted (absent ≠ null) — the
#     output is byte-identical to pre-SP15 callers, so SP12 surfaces
#     that don't go through a consultation gate continue to produce
#     identical artifacts. Flags may appear in any order alongside the
#     three positionals.
#
#     Output (stdout, no consultation flags):
#       ---
#       generated_by: <surface-id>
#       generated_from: <generated-from>
#       last_user_edit: null
#       ---
#
#     Output (stdout, with consultation flags):
#       ---
#       generated_by: <surface-id>
#       generated_from: <generated-from>
#       last_user_edit: null
#       consulted_at: "<ISO-ts>"
#       consultation_response_hash: <sha256-hex>
#       ---
#
#   pf_emit_with_lineage <surface-id> <generated-from> <superseded-by> <original-sha256>
#     Emit a YAML frontmatter block carrying lineage fields for in-place
#     upgrades (e.g., SP11-T-3 seed upgraded by SP12-T-5).
#
#   pf_validate <yaml-frontmatter-file>
#     Validate a YAML frontmatter file (between '---' fences OR raw object)
#     against schemas/provenance-frontmatter-schema.json. Uses ajv when on
#     PATH; falls back to jq structural required-keys check otherwise.
#
#   pf_extract <artifact-path>
#     Extract the leading '---'-fenced YAML block from an artifact file and
#     emit it on stdout. Returns non-zero if no fenced block present.
#
# CONSTRAINTS (R-23): bash 3.2 — no `declare -A`, no `mapfile`, no `${var,,}`.
# `jq` REQUIRED on PATH. `python3` REQUIRED for YAML→JSON parsing in pf_validate
# (the schema is JSON Schema; we convert the YAML block to JSON for validation).
# `ajv` optional (preferred when present).
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP12 Session 1

set -u

if [ -n "${PF_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
PF_LOADED=1

_pf_require() {
  local missing=""
  command -v jq >/dev/null 2>&1 || missing="$missing jq"
  command -v python3 >/dev/null 2>&1 || missing="$missing python3"
  if [ -n "$missing" ]; then
    printf 'provenance-frontmatter FAIL: missing required tool(s):%s\n' "$missing" >&2
    return 2
  fi
  return 0
}

# Resolve schema path: allow PROVENANCE_SCHEMA env override; else compute
# relative to this lib file's grandparent (which is the foundation-repo root
# OR the runtime ~/.claude/ root).
_pf_schema_path() {
  if [ -n "${PROVENANCE_SCHEMA:-}" ]; then
    printf '%s\n' "$PROVENANCE_SCHEMA"
    return 0
  fi
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  local repo_root
  repo_root="$(cd "$script_dir/.." 2>/dev/null && pwd)"
  printf '%s/schemas/provenance-frontmatter-schema.json\n' "$repo_root"
}

# --- public API ---

pf_emit() {
  # Positional: $1=surface_id $2=generated_from [$3=last_user_edit | --null]
  # Optional flags (SP15 T-3, additive — emitted ONLY when supplied):
  #   --consulted-at <ISO-ts>
  #   --response-hash <sha256-hex>
  local sid="" gfrom="" lue=""
  local consulted_at="" response_hash=""
  local got_lue=0 pos=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --consulted-at)
        if [ $# -lt 2 ]; then
          printf 'pf_emit FAIL: --consulted-at requires a value\n' >&2
          return 2
        fi
        consulted_at="$2"
        shift 2
        ;;
      --response-hash)
        if [ $# -lt 2 ]; then
          printf 'pf_emit FAIL: --response-hash requires a value\n' >&2
          return 2
        fi
        response_hash="$2"
        shift 2
        ;;
      *)
        pos=$((pos + 1))
        case "$pos" in
          1) sid="$1" ;;
          2) gfrom="$1" ;;
          3) lue="$1"; got_lue=1 ;;
          *)
            printf 'pf_emit FAIL: unexpected positional arg #%s: %s\n' "$pos" "$1" >&2
            return 2
            ;;
        esac
        shift
        ;;
    esac
  done
  if [ -z "$sid" ] || [ -z "$gfrom" ]; then
    printf 'pf_emit FAIL: surface_id + generated_from required\n' >&2
    return 2
  fi
  if [ "$got_lue" = "0" ]; then
    lue="--null"
  fi
  printf -- '---\n'
  printf 'generated_by: %s\n' "$sid"
  printf 'generated_from: %s\n' "$gfrom"
  if [ "$lue" = "--null" ] || [ -z "$lue" ]; then
    printf 'last_user_edit: null\n'
  else
    # Quote ISO timestamps for YAML safety.
    printf 'last_user_edit: "%s"\n' "$lue"
  fi
  if [ -n "$consulted_at" ]; then
    printf 'consulted_at: "%s"\n' "$consulted_at"
  fi
  if [ -n "$response_hash" ]; then
    printf 'consultation_response_hash: %s\n' "$response_hash"
  fi
  printf -- '---\n'
  return 0
}

pf_emit_with_lineage() {
  # $1=surface_id $2=generated_from $3=superseded_by $4=original_sha256 [$5=last_user_edit]
  local sid="${1:-}"
  local gfrom="${2:-}"
  local sby="${3:-}"
  local osha="${4:-}"
  local lue="${5:---null}"
  if [ -z "$sid" ] || [ -z "$gfrom" ] || [ -z "$sby" ] || [ -z "$osha" ]; then
    printf 'pf_emit_with_lineage FAIL: surface_id + generated_from + superseded_by + original_sha256 required\n' >&2
    return 2
  fi
  printf -- '---\n'
  printf 'generated_by: %s\n' "$sid"
  printf 'generated_from: %s\n' "$gfrom"
  if [ "$lue" = "--null" ] || [ -z "$lue" ]; then
    printf 'last_user_edit: null\n'
  else
    printf 'last_user_edit: "%s"\n' "$lue"
  fi
  printf 'superseded_by: %s\n' "$sby"
  printf 'original_sha256: %s\n' "$osha"
  printf -- '---\n'
  return 0
}

pf_extract() {
  # $1=artifact_path. Echo the leading '---'-fenced YAML block (without fences).
  local f="${1:-}"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    printf 'pf_extract FAIL: artifact path missing or not a file: %s\n' "$f" >&2
    return 2
  fi
  # Use awk to grab block between first two '---' lines (must be at line start).
  awk '
    BEGIN { state=0 }
    /^---[[:space:]]*$/ {
      if (state==0) { state=1; next }
      else if (state==1) { state=2; next }
    }
    state==1 { print }
  ' "$f"
  return 0
}

# Convert a YAML block (passed via filename argv) to JSON on stdout. Uses
# python3 YAML parser if available; otherwise a minimal `key: value` shim.
# IMPORTANT: pass the YAML body via a temp file (argv $1), NOT via stdin —
# python3 heredoc consumes stdin from the heredoc itself, so a piped
# stdin is silently ignored (feedback_python_heredoc_argv).
_pf_yaml_to_json_file() {
  # $1=path-to-yaml-body
  local f="$1"
  python3 - "$f" <<'PY' 2>/dev/null
import sys, json
path = sys.argv[1]
with open(path, 'r') as fh:
    body = fh.read()
try:
    import yaml  # type: ignore
    data = yaml.safe_load(body)
except ImportError:
    # Fallback: handle k:v lines + null + quoted strings + bare scalars.
    data = {}
    for raw in body.splitlines():
        line = raw.rstrip()
        if not line or line.startswith('#'):
            continue
        if ':' not in line:
            continue
        k, v = line.split(':', 1)
        k = k.strip()
        v = v.strip()
        if v == 'null' or v == '~' or v == '':
            data[k] = None
        elif v.lower() == 'true':
            data[k] = True
        elif v.lower() == 'false':
            data[k] = False
        elif (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
            data[k] = v[1:-1]
        else:
            try:
                data[k] = int(v)
            except ValueError:
                try:
                    data[k] = float(v)
                except ValueError:
                    data[k] = v
json.dump(data, sys.stdout, default=str)
PY
}

pf_validate() {
  # $1=path-to-yaml-file (frontmatter block, fenced or unfenced)
  _pf_require || return 2
  local f="${1:-}"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    printf 'pf_validate FAIL: file missing or not regular: %s\n' "$f" >&2
    return 2
  fi
  local schema
  schema="$(_pf_schema_path)"
  if [ ! -f "$schema" ]; then
    printf 'pf_validate FAIL: schema not found at %s\n' "$schema" >&2
    return 2
  fi

  # Strip outer '---' fences if present. If the file is fenced, take the
  # block between the first two fences. If it isn't fenced, take the whole
  # file (raw block-mode validation).
  local has_fence
  has_fence="$(grep -c '^---[[:space:]]*$' "$f" 2>/dev/null || true)"
  local stripped
  if [ -n "$has_fence" ] && [ "$has_fence" -ge 2 ]; then
    stripped="$(awk '
      BEGIN { state=0 }
      /^---[[:space:]]*$/ {
        if (state==0) { state=1; next }
        else if (state==1) { exit }
      }
      state==1 { print }
    ' "$f")"
  else
    stripped="$(cat "$f")"
  fi

  # Convert YAML -> JSON via tmpfile (heredoc-stdin pitfall avoidance).
  local body_tmp
  body_tmp="$(mktemp "${TMPDIR:-/tmp}/pf-body.XXXXXX")"
  printf '%s\n' "$stripped" > "$body_tmp"
  local json
  json="$(_pf_yaml_to_json_file "$body_tmp")"
  rm -f "$body_tmp"
  if [ -z "$json" ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    printf 'pf_validate FAIL: could not parse YAML to JSON\n' >&2
    return 1
  fi

  # ajv path (preferred when available).
  if command -v ajv >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/pf-validate.XXXXXX.json")"
    printf '%s' "$json" > "$tmp"
    if ajv validate -s "$schema" -d "$tmp" --strict=false >/dev/null 2>&1; then
      rm -f "$tmp"
      return 0
    else
      printf 'pf_validate FAIL: ajv validation failed\n' >&2
      ajv validate -s "$schema" -d "$tmp" --strict=false 2>&1 | head -20 >&2
      rm -f "$tmp"
      return 1
    fi
  fi

  # jq structural fallback: check required keys + their types.
  local req
  req="$(jq -r '.required[]?' "$schema")"
  local k
  for k in $req; do
    if ! printf '%s' "$json" | jq -e --arg k "$k" 'has($k)' >/dev/null 2>&1; then
      printf 'pf_validate FAIL: missing required key: %s\n' "$k" >&2
      return 1
    fi
  done
  # Type spot-checks for the three required fields.
  local gby
  gby="$(printf '%s' "$json" | jq -r '.generated_by | type')"
  if [ "$gby" != "string" ]; then
    printf 'pf_validate FAIL: generated_by must be string, got %s\n' "$gby" >&2
    return 1
  fi
  local gfrom_t
  gfrom_t="$(printf '%s' "$json" | jq -r '.generated_from | type')"
  if [ "$gfrom_t" != "string" ]; then
    printf 'pf_validate FAIL: generated_from must be string, got %s\n' "$gfrom_t" >&2
    return 1
  fi
  local lue_t
  lue_t="$(printf '%s' "$json" | jq -r '.last_user_edit | type')"
  if [ "$lue_t" != "string" ] && [ "$lue_t" != "null" ]; then
    printf 'pf_validate FAIL: last_user_edit must be string or null, got %s\n' "$lue_t" >&2
    return 1
  fi
  return 0
}

# --- self-test entrypoint ---
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    --self-test)
      shift
      _PF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pf-self.XXXXXX")"
      _block="$_PF_TEST_DIR/block.yml"
      pf_emit "onboarder@v2.0.0-pre" "section-a" > "$_block" || { echo "FAIL: pf_emit basic" >&2; exit 1; }
      grep -q '^generated_by: onboarder@v2.0.0-pre$' "$_block" || { echo "FAIL: generated_by line absent" >&2; exit 1; }
      grep -q '^last_user_edit: null$' "$_block" || { echo "FAIL: last_user_edit null line absent" >&2; exit 1; }
      pf_validate "$_block" || { echo "FAIL: pf_validate on basic block" >&2; exit 1; }

      _block_iso="$_PF_TEST_DIR/block-iso.yml"
      pf_emit "surface-2-memory-seeds" "section-a-priorities" "2026-05-04T13:22:08Z" > "$_block_iso" || { echo "FAIL: pf_emit iso" >&2; exit 1; }
      pf_validate "$_block_iso" || { echo "FAIL: pf_validate on iso block" >&2; exit 1; }

      _block_lineage="$_PF_TEST_DIR/block-lineage.yml"
      pf_emit_with_lineage "surface-2-memory-seeds" "section-a-priorities" "surface-2-memory-seeds" \
        "a7b43e5e4b0d6e3f5b31d6a0e29c8b8b4e9c5f3c2a1d8b7e6f5d4c3b2a1908f7" \
        > "$_block_lineage" || { echo "FAIL: pf_emit_with_lineage" >&2; exit 1; }
      pf_validate "$_block_lineage" || { echo "FAIL: pf_validate on lineage block" >&2; exit 1; }

      # Negative test: missing generated_from.
      _bad="$_PF_TEST_DIR/bad.yml"
      printf -- '---\ngenerated_by: foo@1\nlast_user_edit: null\n---\n' > "$_bad"
      if pf_validate "$_bad" 2>/dev/null; then
        echo "FAIL: pf_validate accepted invalid block" >&2; exit 1
      fi

      # pf_extract on a synthetic artifact with frontmatter.
      _artifact="$_PF_TEST_DIR/artifact.md"
      cat > "$_artifact" <<'ART'
---
generated_by: onboarder@v2.0.0-pre
generated_from: section-a
last_user_edit: null
---

# Body content
hello
ART
      _extract="$(pf_extract "$_artifact")"
      printf '%s\n' "$_extract" | grep -q '^generated_by: onboarder@v2.0.0-pre$' || {
        echo "FAIL: pf_extract did not return frontmatter" >&2; exit 1
      }
      printf '%s\n' "$_extract" | grep -q '^# Body content$' && {
        echo "FAIL: pf_extract leaked body" >&2; exit 1
      }

      printf 'self-test PASS\n'
      rm -rf "$_PF_TEST_DIR"
      exit 0
      ;;
    "") : ;;
    *) printf 'provenance-frontmatter: unknown direct invocation arg: %s\n' "$1" >&2; exit 2 ;;
  esac
fi
