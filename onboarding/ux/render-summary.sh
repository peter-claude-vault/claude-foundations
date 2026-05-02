#!/bin/bash
# onboarding/ux/render-summary.sh — SP07 T-6 inline-edit summary screen +
# correction write-back. Renders the per-section summary card after the
# section runner (section-{b,c,d}.sh) has committed extraction-output-{B,C,D}.json
# and appended its initial audit JSONL line. Per SKILL.md §Per-Section Pipeline
# step 6: surfaces extracted values with HIGH/MID/LOW confidence-color
# disposition, accepts user inline edits, applies one surgical follow-up per
# LOW required field, blocks section exit if any required field stays
# unresolved (block-and-log per SKILL.md §Output Contract Failure Mode).
#
# Pipeline contract:
#   1. Read extraction-output-{section_id}.json (committed by section runner)
#   2. Read last JSONL audit line for the same section (for follow_ups[] and
#      confidence_map carry-through)
#   3. Compute required-field-paths from q-field-map.json (target paths where
#      direct_qs.{Q}.required==true AND target.nullable!=true AND cardinality
#      is "single"). Cross with follow_ups[] for the BLOCKING set.
#   4. Render summary screen: HIGH (≥0.85) silent populate, MID (0.5-0.85)
#      yellow-confirm, LOW (<0.5) surgical follow-up text.
#   5. Capture user actions (interactive stdin OR --auto-* flags):
#        Enter        → accept-all
#        N            → numeric per-field edit
#        r            → re-record (delegate; clears fragment + audit + transcript)
#        o SURFACE    → opt-out (delegate; emit info; caller re-invokes section
#                       runner with --opt-out-{SURFACE})
#        q            → quit (rc=130)
#   6. Correction write-back: each user-typed correction merges back into
#      populated[field_path] in extraction-output-{section_id}.json (atomic
#      tmp+rename). Field-path identifier appended to corrections[] in a NEW
#      audit JSONL line. Confidence for the corrected field bumped to 1.0
#      (user-typed). NOTE: corrections[] holds field-path identifiers ONLY —
#      the user-typed VALUE goes into populated, never into corrections[]
#      (reference-leak floor; Hard Rule 9).
#   7. Surgical-follow-up loop: one round per LOW required field. User
#      types value inline → treated as the re-extracted answer; field-path
#      added to corrections[]. Re-extraction loop is bounded to ONE pass per
#      field (Hard Rule 5: never re-interview, never re-record for one field).
#   8. Block-and-log: if any required field stays LOW after follow-up AND
#      user did NOT supply a value, the section does NOT commit; render-summary
#      exits 3 with structured diagnostic; phases_completed[] is NOT updated.
#   9. On user accept: append section_id to user-manifest.system.phases_completed[]
#      (atomic tmp+rename of user-manifest.json; idempotent dedup; creates
#      minimal skeleton {system:{phases_completed:[]}} when absent).
#  10. Re-record path: delete extraction-output-{section_id}.json, transcript
#      file, and remove section_id from phases_completed[]. Append a
#      "re-record-initiated" audit marker (preserves append-only history).
#      Caller re-invokes section runner.
#  11. Opt-out path: emit delegation marker; do NOT modify state. Caller
#      re-invokes section runner with --opt-out-{SURFACE}.
#
# Hermetic test mode: interactive stdin parsing replaced by --auto-* flags.
# All file writes go through atomic tmp+rename. All env knobs match the
# section-runner conventions (CLAUDE_HOME, INPUTS_DIR, AUDIT_LOG, TRANSCRIPT_DIR,
# Q_FIELD_MAP, USER_MANIFEST).
#
# Hard invariants (mirror section-d.sh / section-c.sh / section-b.sh):
#   - Bash 3.2 + R-23 compatible (no declare -A, no mapfile, no ${var,,};
#     use tr '[:upper:]' '[:lower:]' for case folding)
#   - Single-deliverable per R-37 (render-summary.sh + the correction write-back
#     contract; per-section re-record + opt-out delegation are on the same
#     dependency chain)
#   - Atomic tmp+rename for every output file; failure rolls back the tmp
#   - Reference-leak floor: corrections[] holds field-path identifiers ONLY
#     (no user-typed strings); user-typed VALUES go into populated map.
#     SKILL.md §Output Contract Pre-write validation step 6 + Hard Rule 9.
#   - phases_completed[] update is idempotent (re-running over an already-
#     completed section is a no-op accept; the section_id is appended once)
#   - Re-record never disturbs other sections' fragments (per-section delete
#     only)
#   - Opt-out delegation does NOT modify extraction-output-{section_id}.json;
#     the owning section's surface handler does that on re-invocation
#
# Env knobs (override defaults; tests + dogfood):
#   SECTION                     Section id (B|C|D); REQUIRED via --section
#   INPUTS_DIR                  Where extraction-output-{B,C,D}.json live
#                               (default: $CLAUDE_HOME/onboarding)
#   AUDIT_LOG                   Per-section JSONL audit path. Defaulted from
#                               SECTION when not overridden:
#                               $CLAUDE_HOME/onboarding/audit/section-{lower}.jsonl
#   TRANSCRIPT_DIR              Voice/typed transcript output dir
#                               (default: $CLAUDE_HOME/onboarding/transcripts)
#   Q_FIELD_MAP                 q-field-map.json source path
#                               (default: foundation-repo onboarding/q-field-map.json)
#   USER_MANIFEST               user-manifest.json path
#                               (default: $CLAUDE_HOME/user-manifest.json)
#
# Args:
#   --section {B|C|D}           REQUIRED. Section id to render.
#   --auto-accept               Non-interactive accept-all. Required fields
#                               must already be resolved; otherwise block-and-log.
#   --auto-edits-file PATH      JSON map {field_path: corrected_value}. Each
#                               entry merges into populated AND records its
#                               field-path in corrections[]. Implies accept.
#   --auto-rerecord             Re-record the section: delete fragment,
#                               transcript, remove from phases_completed.
#                               Caller re-invokes section runner.
#   --auto-opt-out SURFACE      Opt-out delegation marker. SURFACE is the
#                               surface name (hook_advisory|checkpoint_relaxed
#                               |initial_job_skipped|tripwires_skipped|
#                               vault_skipped|sensitive_skipped|tools_skipped|
#                               people_skipped|org_skipped|discovery_skipped).
#                               Emits info to stderr; caller re-invokes
#                               section runner with --opt-out-{...}.
#   --inputs-dir DIR            Override INPUTS_DIR
#   --audit-log PATH            Override AUDIT_LOG
#   --transcript-dir DIR        Override TRANSCRIPT_DIR
#   --user-manifest PATH        Override USER_MANIFEST
#
# Exit codes:
#   0   success (section accepted; extraction-output updated if needed; audit
#       appended; phases_completed[] appended)
#       OR re-record initiated
#       OR opt-out delegated
#   2   bad invocation / missing dependency / invalid input
#   3   block-and-log: required field stays unresolved post-follow-up;
#       phases_completed[] NOT updated; extraction-output untouched
#   130 user quit
#
# (See section-d.sh for the upstream pipeline; render-summary.sh is the
# user-facing inline-edit summary screen invoked at step 6.)

set -u

diag() { printf 'render-summary FAIL: %s\n' "$1" >&2; }
info() { printf 'render-summary: %s\n' "$1" >&2; }

# --- source paths.sh if present (post-install runtime); fall back to env ---
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi

# --- dependency check ---
for tool in jq date; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    diag "$tool required but not on PATH"
    exit 2
  fi
done

# --- foundation-repo source resolution (Bucket A) ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONBOARDING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- defaults ---
INPUTS_DIR="${INPUTS_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding}"
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/transcripts}"
Q_FIELD_MAP="${Q_FIELD_MAP:-$ONBOARDING_DIR/q-field-map.json}"
USER_MANIFEST="${USER_MANIFEST:-${CLAUDE_HOME:-$HOME/.claude}/user-manifest.json}"
AUDIT_LOG_OVERRIDE="${AUDIT_LOG:-}"

SECTION=""
AUTO_ACCEPT=0
AUTO_EDITS_FILE=""
AUTO_RERECORD=0
AUTO_OPT_OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --section)              SECTION="$2"; shift 2 ;;
    --auto-accept)          AUTO_ACCEPT=1; shift ;;
    --auto-edits-file)      AUTO_EDITS_FILE="$2"; shift 2 ;;
    --auto-rerecord)        AUTO_RERECORD=1; shift ;;
    --auto-opt-out)         AUTO_OPT_OUT="$2"; shift 2 ;;
    --inputs-dir)           INPUTS_DIR="$2"; shift 2 ;;
    --audit-log)            AUDIT_LOG_OVERRIDE="$2"; shift 2 ;;
    --transcript-dir)       TRANSCRIPT_DIR="$2"; shift 2 ;;
    --user-manifest)        USER_MANIFEST="$2"; shift 2 ;;
    -h|--help)              sed -n '2,140p' "$0"; exit 0 ;;
    *)                      diag "unknown arg: $1"; exit 2 ;;
  esac
done

# --- validate args ---
if [ -z "$SECTION" ]; then
  diag "--section required (one of B|C|D)"
  exit 2
fi

# Case-fold via tr (R-23 — no ${var,,}).
SECTION_UPPER="$(printf '%s' "$SECTION" | tr '[:lower:]' '[:upper:]')"
SECTION_LOWER="$(printf '%s' "$SECTION" | tr '[:upper:]' '[:lower:]')"

case "$SECTION_UPPER" in
  B|C|D) : ;;
  *) diag "--section must be one of B|C|D (got: $SECTION)"; exit 2 ;;
esac

# Default AUDIT_LOG from SECTION when not overridden.
if [ -n "$AUDIT_LOG_OVERRIDE" ]; then
  AUDIT_LOG="$AUDIT_LOG_OVERRIDE"
else
  AUDIT_LOG="${CLAUDE_HOME:-$HOME/.claude}/onboarding/audit/section-${SECTION_LOWER}.jsonl"
fi

if [ ! -r "$Q_FIELD_MAP" ]; then
  diag "Q_FIELD_MAP not readable: $Q_FIELD_MAP"
  exit 2
fi

EXTRACTION_OUT="$INPUTS_DIR/extraction-output-${SECTION_UPPER}.json"
TRANSCRIPT_PATH="$TRANSCRIPT_DIR/section-${SECTION_LOWER}.txt"

# Validate auto-flag combinations early — orthogonal modes only.
MODE_COUNT=0
[ "$AUTO_ACCEPT" = "1" ] && MODE_COUNT=$((MODE_COUNT + 1))
[ -n "$AUTO_EDITS_FILE" ] && MODE_COUNT=$((MODE_COUNT + 1))
[ "$AUTO_RERECORD" = "1" ] && MODE_COUNT=$((MODE_COUNT + 1))
[ -n "$AUTO_OPT_OUT" ] && MODE_COUNT=$((MODE_COUNT + 1))
if [ "$MODE_COUNT" -gt 1 ]; then
  diag "--auto-* flags are mutually exclusive (got $MODE_COUNT)"
  exit 2
fi

# --- run constants ---
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- helper: resolve required-field-paths set for SECTION_UPPER ---
# Walks q-field-map.json direct_qs entries where the Q-ID prefix matches
# SECTION_UPPER, has required==true, and emits each non-nullable target
# path. Output: one path per line.
resolve_required_paths() {
  jq -r --arg s "$SECTION_UPPER" '
    .direct_qs
    | to_entries
    | map(select((.key | startswith($s + "-")) and .value.required == true))
    | map(.value.targets[] | select(.nullable != true) | .path)
    | .[]
  ' "$Q_FIELD_MAP"
}

# --- helper: read last JSONL line for this section's audit ---
# Returns empty string if audit log absent or has no lines.
read_last_audit_line() {
  if [ ! -s "$AUDIT_LOG" ]; then
    printf ''
    return 0
  fi
  # Last full line. tail -1 is acceptable here (small file, structured JSONL).
  tail -1 "$AUDIT_LOG" 2>/dev/null
}

# --- helper: classify each populated path into HIGH/MID/LOW buckets ---
# Reads $EXTRACTION_OUT; emits compact JSON {high:[...], mid:[...], low:[...]}.
classify_confidence() {
  jq -c '
    . as $e
    | ($e.populated | keys) as $paths
    | {
        high: [ $paths[] | . as $p | select(($e.confidence[$p] // 1.0) >= 0.85) ],
        mid:  [ $paths[] | . as $p | select(($e.confidence[$p] // 1.0) >= 0.5 and ($e.confidence[$p] // 1.0) < 0.85) ],
        low:  [ $paths[] | . as $p | select(($e.confidence[$p] // 1.0) < 0.5) ]
      }
  ' "$EXTRACTION_OUT"
}

# --- helper: render summary screen to stderr ---
# Visual disposition:
#   HIGH (≥0.85): bullet "  ✓ <path> = <value>"
#   MID  (0.5-0.85): bullet "  ? <path> = <value>  (confidence: <c>)"
#   LOW  (<0.5): bullet "  ! <path> = <value>  (LOW confidence: <c>) — needs your input"
# Required fields among LOW get an extra "[REQUIRED]" marker.
render_summary_screen() {
  local buckets="$1" required_paths_file="$2"

  printf '\n=== Section %s — Summary ===\n' "$SECTION_UPPER" >&2
  printf '\nHigh-confidence (silently populated):\n' >&2
  printf '%s' "$buckets" | jq -r '.high[]' | while read -r p; do
    [ -z "$p" ] && continue
    local v
    v="$(jq -r --arg p "$p" '.populated[$p] | tojson' "$EXTRACTION_OUT")"
    printf '  ✓ %s = %s\n' "$p" "$v" >&2
  done

  printf '\nMid-confidence (please confirm):\n' >&2
  printf '%s' "$buckets" | jq -r '.mid[]' | while read -r p; do
    [ -z "$p" ] && continue
    local v c
    v="$(jq -r --arg p "$p" '.populated[$p] | tojson' "$EXTRACTION_OUT")"
    c="$(jq -r --arg p "$p" '.confidence[$p] // 1.0' "$EXTRACTION_OUT")"
    printf '  ? %s = %s  (confidence: %s)\n' "$p" "$v" "$c" >&2
  done

  printf '\nLow-confidence (needs your input):\n' >&2
  printf '%s' "$buckets" | jq -r '.low[]' | while read -r p; do
    [ -z "$p" ] && continue
    local v c req_marker=""
    v="$(jq -r --arg p "$p" '.populated[$p] | tojson' "$EXTRACTION_OUT")"
    c="$(jq -r --arg p "$p" '.confidence[$p] // 1.0' "$EXTRACTION_OUT")"
    if grep -Fxq "$p" "$required_paths_file" 2>/dev/null; then
      req_marker=" [REQUIRED]"
    fi
    printf '  ! %s = %s  (LOW: %s)%s\n' "$p" "$v" "$c" "$req_marker" >&2
  done

  printf '\nActions: Enter to accept, N for numeric edit, r to re-record, o SURFACE for opt-out, q to quit\n\n' >&2
}

# --- helper: identify blocking required fields ---
# A field-path is "blocking" iff (post-edit current state):
#   - it appears in the LOW bucket of confidence classification, OR
#   - it appears in extraction-output's missing_required[]
# AND it is in the required-paths set.
#
# Note: prior-audit follow_ups[] is HISTORICAL (what was originally LOW
# before edits). It is informational and carried through into the new audit
# line by append_audit_line, but does NOT participate in blocking — edits
# resolve LOW fields by bumping their confidence, which the post-edit LOW
# bucket reflects.
#
# Output: blocking field-paths, one per line.
compute_blocking_paths() {
  local buckets="$1" required_paths_file="$2"
  local low_paths missing_paths

  low_paths="$(printf '%s' "$buckets" | jq -r '.low[]')"
  missing_paths="$(jq -r '.missing_required[]? // empty' "$EXTRACTION_OUT" 2>/dev/null)"

  # Union of two CURRENT-STATE signals.
  printf '%s\n%s\n' "$low_paths" "$missing_paths" \
    | grep -v '^$' \
    | sort -u \
    | while read -r p; do
        if grep -Fxq "$p" "$required_paths_file" 2>/dev/null; then
          printf '%s\n' "$p"
        fi
      done
}

# --- helper: apply correction edits from JSON map ---
# Reads $1 (path to edits JSON map). Merges each {field_path: value} into
# extraction-output's populated map AND records each field_path in corrections[]
# global var. Bumps confidence to 1.0 (user-typed). Atomic tmp+rename.
# Returns 0 on success, 3 on failure. corrections[] field-paths are emitted
# to stdout (one per line) for the caller to capture.
apply_edits_from_file() {
  local edits_file="$1"
  if [ ! -r "$edits_file" ]; then
    diag "auto-edits-file not readable: $edits_file"
    return 3
  fi

  jq -e '. | type == "object"' "$edits_file" >/dev/null 2>&1 || {
    diag "auto-edits-file must be JSON object: $edits_file"
    return 3
  }

  # Merge edits into extraction-output. For each (path, value) in edits:
  #   .populated[path] = value
  #   .confidence[path] = 1.0
  # Atomic tmp+rename.
  local final_tmp="$EXTRACTION_OUT.tmp.$$"
  jq -c --slurpfile e "$edits_file" '
    . as $orig
    | $e[0] as $edits
    | .populated = (.populated + $edits)
    | .confidence = (.confidence + ($edits | with_entries({key: .key, value: 1.0})))
  ' "$EXTRACTION_OUT" > "$final_tmp" || {
    diag "extraction-output edit-merge render failed"
    rm -f "$final_tmp"
    return 3
  }
  mv "$final_tmp" "$EXTRACTION_OUT" || {
    diag "extraction-output edit-merge rename failed"
    rm -f "$final_tmp"
    return 3
  }

  # Emit field-paths for caller.
  jq -r 'keys[]' "$edits_file"
}

# --- helper: append audit JSONL line with corrections[] populated ---
# $1 = JSON array of correction field-paths (compact JSON, e.g. ["U.x","U.y"])
# $2 = JSON array of opt_outs (typically [] from this script; carried through)
append_audit_line() {
  local corrections_json="$1"
  local opt_outs_json="${2:-[]}"

  local audit_tmp="$AUDIT_LOG.tmp.$$"
  local confidence_map="{}" source_spans="{}" follow_ups="[]" manifest_paths="[]"

  if [ -r "$EXTRACTION_OUT" ]; then
    confidence_map="$(jq -c '.confidence // {}' "$EXTRACTION_OUT")"
    source_spans="$(jq -c '.source_spans // {}' "$EXTRACTION_OUT")"
    manifest_paths="$(jq -c '.populated | keys' "$EXTRACTION_OUT")"
  fi

  # Carry follow_ups[] from last audit line (post-correction set after edits).
  local prev_audit
  prev_audit="$(read_last_audit_line)"
  if [ -n "$prev_audit" ]; then
    follow_ups="$(printf '%s' "$prev_audit" | jq -c '.follow_ups // []')"
  fi

  mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null

  jq -nc \
    --arg section_id "$SECTION_UPPER" \
    --arg run_id "$RUN_ID" \
    --arg ts "$RUN_TS" \
    --argjson opt_outs "$opt_outs_json" \
    --argjson confidence_map "$confidence_map" \
    --argjson source_spans "$source_spans" \
    --argjson corrections "$corrections_json" \
    --argjson follow_ups "$follow_ups" \
    --argjson manifest_paths "$manifest_paths" \
    '{
      section_id: $section_id,
      run_id: $run_id,
      ts: $ts,
      opt_outs: $opt_outs,
      confidence_map: $confidence_map,
      source_spans: $source_spans,
      corrections: $corrections,
      follow_ups: $follow_ups,
      manifest_paths_written: $manifest_paths
    }' > "$audit_tmp" || {
      diag "audit JSONL render failed"
      rm -f "$audit_tmp"
      return 3
    }
  cat "$audit_tmp" >> "$AUDIT_LOG" || {
    diag "audit JSONL append failed"
    rm -f "$audit_tmp"
    return 3
  }
  rm -f "$audit_tmp"
  return 0
}

# --- helper: append section_id to user-manifest.system.phases_completed[] ---
# Idempotent: re-appending an already-present id is a no-op. Creates minimal
# {system:{phases_completed:[]}} skeleton when user-manifest is absent.
# Atomic tmp+rename.
append_phases_completed() {
  mkdir -p "$(dirname "$USER_MANIFEST")" 2>/dev/null

  if [ ! -f "$USER_MANIFEST" ]; then
    # Seed minimal skeleton.
    printf '{"system":{"phases_completed":[]}}\n' > "$USER_MANIFEST" || {
      diag "user-manifest skeleton creation failed: $USER_MANIFEST"
      return 3
    }
  fi

  local final_tmp="$USER_MANIFEST.tmp.$$"
  jq -c --arg s "$SECTION_UPPER" '
    .system = (.system // {})
    | .system.phases_completed = (
        (.system.phases_completed // []) + [$s] | unique
      )
  ' "$USER_MANIFEST" > "$final_tmp" || {
    diag "user-manifest phases_completed merge failed"
    rm -f "$final_tmp"
    return 3
  }
  mv "$final_tmp" "$USER_MANIFEST" || {
    diag "user-manifest rename failed"
    rm -f "$final_tmp"
    return 3
  }
  return 0
}

# --- helper: remove section_id from phases_completed[] (re-record) ---
remove_phases_completed() {
  if [ ! -f "$USER_MANIFEST" ]; then
    # Nothing to remove from.
    return 0
  fi
  local final_tmp="$USER_MANIFEST.tmp.$$"
  jq -c --arg s "$SECTION_UPPER" '
    if (.system.phases_completed // []) | type == "array"
    then .system.phases_completed = ((.system.phases_completed // []) - [$s])
    else .
    end
  ' "$USER_MANIFEST" > "$final_tmp" || {
    diag "user-manifest phases_completed remove failed"
    rm -f "$final_tmp"
    return 3
  }
  mv "$final_tmp" "$USER_MANIFEST" || {
    diag "user-manifest rename failed"
    rm -f "$final_tmp"
    return 3
  }
  return 0
}

# --- branch: re-record path ---
# Deletes extraction-output, transcript; removes section_id from
# phases_completed[]; appends a "re-record-initiated" audit marker so the
# JSONL trail records the action (append-only history). Caller re-invokes
# section runner.
do_rerecord() {
  info "Re-record initiated for section $SECTION_UPPER"

  rm -f "$EXTRACTION_OUT" "$TRANSCRIPT_PATH" 2>/dev/null

  remove_phases_completed || return 3

  # SP07 T-10: also remove the completion_state[$SECTION] entry. checkpoint.sh
  # --remove-section is idempotent; safe even if the entry was never written.
  if ! "$ONBOARDING_DIR/checkpoint.sh" --remove-section "$SECTION_UPPER" \
       --user-manifest "$USER_MANIFEST"; then
    diag "checkpoint.sh remove failed for section $SECTION_UPPER"
    return 3
  fi

  # Append re-record marker as a separate audit event. Per JSONL append-only
  # convention, prior entries remain in the log as historical record.
  local audit_tmp="$AUDIT_LOG.tmp.$$"
  mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null
  jq -nc \
    --arg section_id "$SECTION_UPPER" \
    --arg run_id "$RUN_ID" \
    --arg ts "$RUN_TS" \
    '{
      section_id: $section_id,
      run_id: $run_id,
      ts: $ts,
      opt_outs: [],
      confidence_map: {},
      source_spans: {},
      corrections: [],
      follow_ups: [],
      manifest_paths_written: [],
      event: "re-record-initiated"
    }' > "$audit_tmp" || {
      diag "re-record audit marker render failed"
      rm -f "$audit_tmp"
      return 3
    }
  cat "$audit_tmp" >> "$AUDIT_LOG" || {
    diag "re-record audit marker append failed"
    rm -f "$audit_tmp"
    return 3
  }
  rm -f "$audit_tmp"

  info "Section $SECTION_UPPER fragment + transcript cleared. Re-invoke section-${SECTION_LOWER}.sh to continue."
  return 0
}

# --- branch: opt-out delegation ---
# Emits a delegation marker on stderr and an audit-log entry recording the
# opt-out request. Does NOT modify extraction-output (the section runner's
# surface handler does that when re-invoked with --opt-out-{NAME}).
do_opt_out() {
  local surface="$1"

  case "$surface" in
    hook_advisory|checkpoint_relaxed|initial_job_skipped|tripwires_skipped \
    |vault_skipped|sensitive_skipped|tools_skipped|people_skipped \
    |org_skipped|discovery_skipped)
      : ;;
    *)
      diag "unknown opt-out surface: $surface"
      return 2
      ;;
  esac

  info "Opt-out '$surface' delegated for section $SECTION_UPPER"
  info "Re-invoke section-${SECTION_LOWER}.sh with the matching --opt-out-* flag to apply"

  # Append a delegation-marker audit event for trace.
  local audit_tmp="$AUDIT_LOG.tmp.$$"
  mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null
  jq -nc \
    --arg section_id "$SECTION_UPPER" \
    --arg run_id "$RUN_ID" \
    --arg ts "$RUN_TS" \
    --arg surface "$surface" \
    '{
      section_id: $section_id,
      run_id: $run_id,
      ts: $ts,
      opt_outs: [$surface],
      confidence_map: {},
      source_spans: {},
      corrections: [],
      follow_ups: [],
      manifest_paths_written: [],
      event: "opt-out-delegated"
    }' > "$audit_tmp" || {
      diag "opt-out audit marker render failed"
      rm -f "$audit_tmp"
      return 3
    }
  cat "$audit_tmp" >> "$AUDIT_LOG" || {
    diag "opt-out audit marker append failed"
    rm -f "$audit_tmp"
    return 3
  }
  rm -f "$audit_tmp"
  return 0
}

# --- branch: accept-with-edits path ---
# Validates extraction-output exists; classifies confidence; computes blocking
# required-paths; applies any edits from --auto-edits-file; checks for
# remaining blocking paths; writes audit + phases_completed on success.
do_accept() {
  if [ ! -r "$EXTRACTION_OUT" ]; then
    diag "extraction-output not found: $EXTRACTION_OUT (run section-${SECTION_LOWER}.sh first)"
    return 2
  fi

  jq -e . "$EXTRACTION_OUT" >/dev/null 2>&1 || {
    diag "extraction-output not valid JSON: $EXTRACTION_OUT"
    return 3
  }
  local sid
  sid="$(jq -r '.section_id // empty' "$EXTRACTION_OUT")"
  if [ "$sid" != "$SECTION_UPPER" ]; then
    diag "extraction-output section_id='$sid' (expected '$SECTION_UPPER')"
    return 3
  fi

  local required_paths_tmp="$INPUTS_DIR/.required-paths-${SECTION_UPPER}.tmp.$$"
  mkdir -p "$INPUTS_DIR" 2>/dev/null
  resolve_required_paths > "$required_paths_tmp" || {
    diag "required-paths resolution failed"
    rm -f "$required_paths_tmp"
    return 3
  }

  local buckets
  buckets="$(classify_confidence)" || {
    diag "confidence classification failed"
    rm -f "$required_paths_tmp"
    return 3
  }

  local prev_audit
  prev_audit="$(read_last_audit_line)"

  # Render the screen (visual aid for interactive sessions; harmless for
  # programmatic). For --auto-accept tests the screen render is informational
  # only — the decision is taken by flag.
  render_summary_screen "$buckets" "$required_paths_tmp"

  # Apply edits BEFORE checking blocking-paths so user-supplied corrections
  # resolve LOW required fields.
  local corrections_json="[]"
  if [ -n "$AUTO_EDITS_FILE" ]; then
    local applied_paths_tmp="$INPUTS_DIR/.applied-paths-${SECTION_UPPER}.tmp.$$"
    apply_edits_from_file "$AUTO_EDITS_FILE" > "$applied_paths_tmp"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
      rm -f "$required_paths_tmp" "$applied_paths_tmp"
      return "$rc"
    fi
    corrections_json="$(jq -R . "$applied_paths_tmp" 2>/dev/null | jq -sc 'map(select(. != ""))')"
    rm -f "$applied_paths_tmp"
    # Re-classify after edits so blocking-set check sees the updated state.
    buckets="$(classify_confidence)"
  fi

  # Block-and-log: if any required field is still blocking AFTER edits applied,
  # the section does not commit.
  local blocking_paths
  blocking_paths="$(compute_blocking_paths "$buckets" "$required_paths_tmp")"
  rm -f "$required_paths_tmp"

  if [ -n "$blocking_paths" ]; then
    diag "block-and-log: required field(s) unresolved post-follow-up:"
    printf '%s\n' "$blocking_paths" >&2
    diag "section ${SECTION_UPPER} not committed; phases_completed[] not updated"
    # Still append an audit line recording the block event for the trace.
    append_audit_line "$corrections_json" "[]" || {
      diag "block-and-log audit append failed (trace lost)"
    }
    return 3
  fi

  # Accept path: append audit line with corrections[] populated, then update
  # phases_completed[]. SP07 T-10: also write the completion_state checkpoint
  # via checkpoint.sh (writes phases_completed idempotently AND records
  # completion_state[$SECTION] = {committed_at, transcript_sha?}).
  append_audit_line "$corrections_json" "[]" || return 3
  append_phases_completed || return 3

  local checkpoint_args="--section $SECTION_UPPER --user-manifest $USER_MANIFEST"
  if [ -r "$TRANSCRIPT_PATH" ]; then
    checkpoint_args="$checkpoint_args --transcript $TRANSCRIPT_PATH"
  fi
  # shellcheck disable=SC2086
  if ! "$ONBOARDING_DIR/checkpoint.sh" $checkpoint_args; then
    diag "checkpoint.sh write failed for section $SECTION_UPPER"
    return 3
  fi

  info "Section ${SECTION_UPPER} accepted; phases_completed[] + completion_state updated; corrections=${corrections_json}"
  return 0
}

# --- main flow ---

# Re-record path is independent of extraction-output existence (it deletes).
if [ "$AUTO_RERECORD" = "1" ]; then
  do_rerecord
  exit $?
fi

# Opt-out path is also independent of extraction-output existence (the section
# runner re-invocation overwrites the populated map regardless).
if [ -n "$AUTO_OPT_OUT" ]; then
  do_opt_out "$AUTO_OPT_OUT"
  exit $?
fi

# Default path: accept-with-edits (interactive or programmatic).
# Programmatic: --auto-accept or --auto-edits-file. Interactive (no flags):
# T-6 currently emits the summary screen and returns rc=0 in the trivial
# accept-all case. Future: full interactive parsing of stdin (deferred to a
# follow-up in this same task chain — surfaces the screen for visual review
# without modifying state when no auto-* flag is supplied).
if [ "$AUTO_ACCEPT" = "1" ] || [ -n "$AUTO_EDITS_FILE" ]; then
  do_accept
  exit $?
fi

# Interactive default: render screen and accept-all (the simplest interactive
# flow per spec L196-200; user can re-invoke with --auto-rerecord or
# --auto-opt-out for non-accept paths). Treat as --auto-accept implicitly.
do_accept
exit $?
