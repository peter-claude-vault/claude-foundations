#!/usr/bin/env bash
# lib/staging-emit.sh — shared library for vault writers to emit content packets
# into the writer-reconciler staging area at ~/.claude/state/vault-staging/.
#
# Per Plan 81 SP13 alignment Session 4 A35 + L-42 + L-54. Authored under
# SP14 Batch B T-9 (2026-05-18).
#
# Pipeline posture (per Session 4 L-41 — Posture D, per-destination contract-
# driven hybrid):
#   - Default = direct write; this library is NOT used in the default path
#   - Opt-in = staged-packet per destination, declared by folder-level
#     `_processing-rules.json :: posture: staged`
#   - When opted-in, writers source this library and emit one packet per
#     intended destination write. The writer-reconciler skill picks up packets
#     at the next tick (cron 15-min default per pillar 7) and applies
#     mechanical-only reconciliation per folder > file-type > universal
#     precedence (per Session 4 L-44 + L-49 + L-50).
#
# Packet shape (per Session 4 A35 + L-39; v1.1 per SP14 Batch D T-26 adds
# source_id + packet_kind fields per writer-pipeline-layering L-106 + L-110
# + foundation-governance-target-state §A62):
#   {
#     "packet_version": "1.1",
#     "writer_id": "<writer-reference filename minus .md>",
#     "emitted_at": "<ISO-8601 UTC>",
#     "destination_path": "<Mustache-resolved absolute path>",
#     "content_sha256": "<sha256 of body>",
#     "body": "<string for markdown / object for json/structured>",
#     "output_type": "markdown | json | sqlite | db | opaque",
#     "metadata": { ... opaque to reconciler ... },
#     "packet_kind": "writer-emit | amender-replacement | amender-conflict",
#     "source_id": "<optional caller-supplied source identifier; omitted if empty>"
#   }
#
# bash 3.2 compatible (no `declare -A`, no `mapfile`, no `${var,,}`).
# Canonical lock pattern: /usr/bin/lockf -k -t 0 (per feedback_shell_lock_pattern).

set -u

# ---- defaults ---------------------------------------------------------------

# Resolve STAGING_ROOT: env wins; otherwise default to ~/.claude/state/vault-staging.
if [ -z "${STAGING_ROOT:-}" ]; then
  STAGING_ROOT="${HOME}/.claude/state/vault-staging"
fi

WRITER_ID=""
DESTINATION_PATH=""
OUTPUT_TYPE=""
BODY_FILE=""
METADATA_FILE=""
DEDUP=""
SOURCE_ID=""
PACKET_KIND="writer-emit"

usage() {
  cat <<EOF
staging-emit.sh — vault writer staging-packet emission helper.

Usage:
  staging-emit.sh --writer-id <id>
                  --destination-path <path>
                  --output-type <markdown|json|sqlite|db|opaque>
                  --body-file <path>
                  [--metadata-file <path>]
                  [--dedup sha256-content]
                  [--source-id <id>]
                  [--packet-kind <writer-emit|amender-replacement|amender-conflict>]

Required:
  --writer-id           Writer reference filename minus .md (e.g.,
                        "meeting-note-ingestor-granola").
  --destination-path    Absolute path where reconciler will eventually write
                        (Mustache substitution already resolved by caller per
                        Session 5 L-69 foundation_variable_namespace).
  --output-type         One of: markdown | json | sqlite | db | opaque (per
                        Session 4 L-38 output-type universe + file-type-
                        contracts/vault-writer.md.json destinations_entry_shape
                        enums).
  --body-file           Path to file containing the proposed-write body.
                        Reads bytes; sha256 computed over body content.

Optional:
  --metadata-file       Path to JSON file with writer-specific metadata
                        (object). Embedded verbatim under packet.metadata.
                        Opaque to reconciler.
  --dedup sha256-content
                        Skip emission when an existing packet under this
                        writer_id has matching content_sha256. Returns
                        rc=0 + emits "duplicate-skip" diagnostic. Full
                        dedup decision still at reconciler per Session 4 R-34.
  --source-id           Optional caller-supplied source identifier (e.g.,
                        upstream meeting-id, ingest batch-id). When empty
                        (default), field is omitted from the packet entirely.
                        Per writer-pipeline-layering L-106 + foundation-
                        governance-target-state §A62.
  --packet-kind         One of: writer-emit (default) | amender-replacement |
                        amender-conflict. Discriminates regular writer emits
                        from amender-driven replacement / conflict packets.
                        Per writer-pipeline-layering L-110 + foundation-
                        governance-target-state §A62.

Env:
  STAGING_ROOT          Default ~/.claude/state/vault-staging. Override
                        for tests / CI / alternate adopter paths.

Exit codes:
  0   packet written (or duplicate-skipped under --dedup)
  2   bad invocation / missing prereq
  3   pre-flight failure (body-file missing, output-type invalid, etc.)
  4   lock contention (per-writer-id lock could not be acquired)
  5   packet write failure (atomic-rename failed; tempfile cleaned)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --writer-id)         WRITER_ID="$2"; shift 2 ;;
    --destination-path)  DESTINATION_PATH="$2"; shift 2 ;;
    --output-type)       OUTPUT_TYPE="$2"; shift 2 ;;
    --body-file)         BODY_FILE="$2"; shift 2 ;;
    --metadata-file)     METADATA_FILE="$2"; shift 2 ;;
    --dedup)             DEDUP="$2"; shift 2 ;;
    --source-id)         SOURCE_ID="$2"; shift 2 ;;
    --packet-kind)       PACKET_KIND="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) printf 'staging-emit.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- argv validation --------------------------------------------------------

if [ -z "$WRITER_ID" ]; then
  printf 'staging-emit.sh: --writer-id required\n' >&2; exit 2
fi
if [ -z "$DESTINATION_PATH" ]; then
  printf 'staging-emit.sh: --destination-path required\n' >&2; exit 2
fi
if [ -z "$OUTPUT_TYPE" ]; then
  printf 'staging-emit.sh: --output-type required\n' >&2; exit 2
fi
if [ -z "$BODY_FILE" ]; then
  printf 'staging-emit.sh: --body-file required\n' >&2; exit 2
fi

# Validate output-type enum (operator-amended 2026-05-18 supersedes Session 5 L-58
# consolidation; split sqlite vs db preserves the local-file-DB vs remote-service-DB
# distinction operationally relevant for writer audit + reconciler merge semantics).
case "$OUTPUT_TYPE" in
  markdown|json|sqlite|db|opaque) : ;;
  *)
    printf 'staging-emit.sh: --output-type must be one of: markdown, json, sqlite, db, opaque (got: %s)\n' \
      "$OUTPUT_TYPE" >&2
    exit 3
    ;;
esac

# Validate writer-id is filename-safe (no slashes; no leading dot).
case "$WRITER_ID" in
  */*|.*)
    printf 'staging-emit.sh: --writer-id must be filename-safe (got: %s)\n' "$WRITER_ID" >&2
    exit 2
    ;;
esac

# Validate --dedup flag value (only sha256-content supported in v1).
if [ -n "$DEDUP" ]; then
  case "$DEDUP" in
    sha256-content) : ;;
    *)
      printf 'staging-emit.sh: --dedup must be sha256-content (got: %s)\n' "$DEDUP" >&2
      exit 2
      ;;
  esac
fi

# Validate --packet-kind enum (block-and-log per SP14 Batch D T-26).
case "$PACKET_KIND" in
  writer-emit|amender-replacement|amender-conflict) : ;;
  *)
    printf 'staging-emit.sh: --packet-kind must be one of: writer-emit, amender-replacement, amender-conflict (got: %s)\n' \
      "$PACKET_KIND" >&2
    exit 2
    ;;
esac

# ---- pre-flight -------------------------------------------------------------

for tool in jq shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'staging-emit.sh: missing prereq: %s\n' "$tool" >&2
    exit 3
  fi
done

if [ ! -r "$BODY_FILE" ]; then
  printf 'staging-emit.sh: --body-file not readable: %s\n' "$BODY_FILE" >&2
  exit 3
fi

if [ -n "$METADATA_FILE" ]; then
  if [ ! -r "$METADATA_FILE" ]; then
    printf 'staging-emit.sh: --metadata-file not readable: %s\n' "$METADATA_FILE" >&2
    exit 3
  fi
  if ! jq empty "$METADATA_FILE" >/dev/null 2>&1; then
    printf 'staging-emit.sh: --metadata-file is not valid JSON: %s\n' "$METADATA_FILE" >&2
    exit 3
  fi
fi

# Per-writer-id directory + lock setup.
WRITER_DIR="$STAGING_ROOT/$WRITER_ID"
mkdir -p "$WRITER_DIR" 2>/dev/null || {
  printf 'staging-emit.sh: cannot create writer dir: %s\n' "$WRITER_DIR" >&2
  exit 3
}

LOCK_FILE="$WRITER_DIR/.lock"

# ---- sha256 ------------------------------------------------------------------

CONTENT_SHA256=$(shasum -a 256 "$BODY_FILE" 2>/dev/null | awk '{print $1}')
if [ -z "$CONTENT_SHA256" ]; then
  printf 'staging-emit.sh: sha256 failed for body-file: %s\n' "$BODY_FILE" >&2
  exit 3
fi

# ---- lock acquisition (re-exec under lockf for per-writer serialization) ----
#
# Sentinel pattern: outer call (no sentinel set) re-execs $0 under lockf;
# inner call (sentinel set) proceeds with the real work. The kernel releases
# the lock on inner-process death automatically.

if [ -z "${STAGING_EMIT_LOCKED:-}" ]; then
  # Forward original argv inside the locked re-exec.
  export STAGING_EMIT_LOCKED=1
  if ! /usr/bin/lockf -k -t 0 "$LOCK_FILE" "$0" \
       --writer-id "$WRITER_ID" \
       --destination-path "$DESTINATION_PATH" \
       --output-type "$OUTPUT_TYPE" \
       --body-file "$BODY_FILE" \
       --packet-kind "$PACKET_KIND" \
       ${METADATA_FILE:+--metadata-file "$METADATA_FILE"} \
       ${DEDUP:+--dedup "$DEDUP"} \
       ${SOURCE_ID:+--source-id "$SOURCE_ID"}; then
    rc=$?
    if [ "$rc" = "75" ]; then
      printf 'staging-emit.sh: lock contention on %s; deferring\n' "$LOCK_FILE" >&2
      exit 4
    fi
    exit "$rc"
  fi
  exit 0
fi

# ---- dedup-at-emit check (optional; under lock) -----------------------------

if [ "$DEDUP" = "sha256-content" ]; then
  for existing in "$WRITER_DIR"/*.json; do
    [ -f "$existing" ] || continue
    existing_sha=$(jq -r '.content_sha256 // empty' "$existing" 2>/dev/null)
    if [ "$existing_sha" = "$CONTENT_SHA256" ]; then
      printf 'staging-emit.sh: duplicate-skip (sha256 match): %s already exists\n' "$existing" >&2
      exit 0
    fi
  done
fi

# ---- body marshaling --------------------------------------------------------
#
# For output_type=markdown: body is read as-is as a string.
# For output_type=json: body is parsed as JSON object (jq -e .).
# For sqlite/db/opaque: body is read as base64-encoded bytes for safe JSON
# embedding (these output types are not text-readable; reconciler base64-
# decodes before writing).

BODY_JQ_ARGS=""

case "$OUTPUT_TYPE" in
  markdown)
    BODY_RAW=$(cat "$BODY_FILE")
    BODY_JSON=$(printf '%s' "$BODY_RAW" | jq -Rs '.')
    ;;
  json)
    if ! jq empty "$BODY_FILE" >/dev/null 2>&1; then
      printf 'staging-emit.sh: --output-type json requires valid JSON body (got: %s)\n' "$BODY_FILE" >&2
      exit 3
    fi
    BODY_JSON=$(jq -c '.' "$BODY_FILE")
    ;;
  sqlite|db|opaque)
    if ! command -v base64 >/dev/null 2>&1; then
      printf 'staging-emit.sh: base64 required for output_type=%s\n' "$OUTPUT_TYPE" >&2
      exit 3
    fi
    BODY_B64=$(base64 < "$BODY_FILE" 2>/dev/null | tr -d '\n')
    BODY_JSON=$(printf '{"encoding":"base64","data":"%s"}' "$BODY_B64")
    ;;
esac

# ---- metadata marshaling ----------------------------------------------------

if [ -n "$METADATA_FILE" ]; then
  METADATA_JSON=$(jq -c '.' "$METADATA_FILE")
else
  METADATA_JSON='{}'
fi

# ---- packet composition + atomic write --------------------------------------

EMITTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Packet filename per A35: <writer-id>/<source-sha>.json
PACKET_PATH="$WRITER_DIR/$CONTENT_SHA256.json"
TMP_PATH="$WRITER_DIR/.$CONTENT_SHA256.tmp.$$"

# Compose packet via jq for safe JSON construction (handles destination_path
# with special characters; preserves output_type enum).
if ! printf '%s\n' "$BODY_JSON" | jq -c \
    --arg packet_version "1.1" \
    --arg writer_id "$WRITER_ID" \
    --arg emitted_at "$EMITTED_AT" \
    --arg destination_path "$DESTINATION_PATH" \
    --arg content_sha256 "$CONTENT_SHA256" \
    --arg output_type "$OUTPUT_TYPE" \
    --argjson metadata "$METADATA_JSON" \
    --arg packet_kind "$PACKET_KIND" \
    --arg source_id "$SOURCE_ID" \
    '{
      packet_version: $packet_version,
      writer_id: $writer_id,
      emitted_at: $emitted_at,
      destination_path: $destination_path,
      content_sha256: $content_sha256,
      body: .,
      output_type: $output_type,
      metadata: $metadata,
      packet_kind: $packet_kind
    }
    + (if $source_id == "" then {} else {source_id: $source_id} end)' \
    > "$TMP_PATH" 2>/dev/null; then
  rm -f "$TMP_PATH"
  printf 'staging-emit.sh: packet composition failed\n' >&2
  exit 5
fi

# Post-compose validation: ensure tempfile is parseable JSON.
if ! jq empty "$TMP_PATH" >/dev/null 2>&1; then
  rm -f "$TMP_PATH"
  printf 'staging-emit.sh: composed packet not valid JSON\n' >&2
  exit 5
fi

# Atomic rename.
if ! mv -f "$TMP_PATH" "$PACKET_PATH"; then
  rm -f "$TMP_PATH"
  printf 'staging-emit.sh: atomic rename failed: %s -> %s\n' "$TMP_PATH" "$PACKET_PATH" >&2
  exit 5
fi

printf 'staging-emit.sh: emitted %s\n' "$PACKET_PATH" >&2
exit 0
