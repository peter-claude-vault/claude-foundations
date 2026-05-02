#!/bin/bash
# onboarding/ux/section-b.sh — SP07 T-5a Section B record-and-drop runner +
# per-section pipeline mechanism (first concrete instance of the pipeline
# that T-5b/Section-C and T-5c/Section-D will copy).
#
# Per-section pipeline composes T-2 (Section A discovery context),
# T-3 (voice-capture wrapper) + T-4 (typed-textarea fallback) for transcript
# capture, the SP01 per-section extraction prompt for field population, the
# confidence-gate policy for per-field disposition, and the opt-out routing
# for surfaces #2/#3/#4. Atomic write of the populated extraction-output
# fragment satisfies the per-section merge contract; the final
# bootstrap-schemas.sh invocation is the orchestrator's responsibility
# after all 5 sections have committed their fragments.
#
# Two-pass production flow (production caller is the onboarder skill,
# Claude inside the harness — F-07 boundary):
#
#   Pass 1 (no extraction yet):
#     1. Validate args + dependencies + section-A discovery context
#     2. Capture transcript via voice-capture.sh (or typed-textarea.sh on
#        probe-fail / --typed-only). Skipped if transcript file already
#        exists at the deterministic per-section path (idempotent re-entry)
#     3. Render the SP01 extraction prompt with the 4 substitution sites
#        filled (transcript, prompt-card, schema-skeleton-slice, discovery-
#        context) → write to $INPUTS_DIR/extraction-prompt-B.compiled.txt
#     4. Exit 5 with diagnostic: "compiled prompt staged at <path>; pipe
#        model output JSON via EXTRACTION_OUTPUT_OVERRIDE=<path> and
#        re-invoke section-b.sh to continue"
#
#   Pass 2 (caller has run the extraction model, JSON output staged):
#     5. Read extraction output from $EXTRACTION_OUTPUT_OVERRIDE
#     6. Apply confidence gate per field: bucket into HIGH (≥0.85) / MID
#        (0.5-0.85) / LOW (<0.5). For LOW + required: record the extraction's
#        follow_up text as a field-path entry in audit follow_ups[] (T-6
#        owns the user-facing surgical follow-up render + re-extraction;
#        this script records the categorization only)
#     7. Apply opt-out routing for surfaces #2/#3/#4 (--opt-out-org /
#        --opt-out-people / --opt-out-tools / --auto-opt-out blanket).
#        Each opt-out writes its own deterministic record over the
#        extraction's populated map without aborting the section
#     8. Atomic-write $INPUTS_DIR/extraction-output-B.json (R-43 atomic
#        tmp+rename). This is the per-section "merge" — bootstrap-schemas.sh
#        runs once at end-of-flow consuming all 5 extraction-output files
#     9. Append per-section JSONL audit entry to $AUDIT_LOG with the 9 keys
#        per SKILL.md L141: section_id, run_id, ts, opt_outs[],
#        confidence_map, source_spans, corrections[], follow_ups[],
#        manifest_paths_written[]
#    10. Stub T-6 summary handoff (deferred): info message only
#    11. Exit 0
#
# Hermetic test mode (single-pass): pre-stage transcript at
# $TRANSCRIPT_DIR/section-b.txt + set EXTRACTION_OUTPUT_OVERRIDE pointing at
# a stub extraction-output JSON file. The script detects both pre-conditions,
# skips capture + prompt-rendering, runs steps 5-11.
#
# Hard invariants (mirror section-a.sh / voice-capture.sh / typed-textarea.sh):
#   - Bash 3.2 + R-23 compatible (no declare -A, no mapfile, no ${var,,};
#     use tr '[:upper:]' '[:lower:]' for case folding)
#   - Single-deliverable per R-37 (the per-section pipeline mechanism +
#     section-b.sh as the first concrete instance)
#   - JSONL audit emits structural metadata in diagnostic fields (follow_ups,
#     corrections); source_spans is a data field per SKILL.md L141 spec
#   - Probes are READ-ONLY against $INPUTS_DIR + $TRANSCRIPT_DIR (Bucket A
#     foundation-repo path classification)
#   - Atomic tmp+rename for every output file; failure rolls back the tmp
#   - Reference-leak floor: NO user-provided strings in DIAGNOSTIC fields
#     (follow_ups[] holds field-path identifiers, not full follow-up text;
#     corrections[] reserved for T-6 inline-edit field-paths)
#
# Env knobs (override defaults; tests + dogfood):
#   PROMPT_CARD_PATH            File with the section-B prompt-card text
#                               (caller anchor-extracts from
#                               onboarder-design.md §4 before invocation)
#   INPUTS_DIR                  Where extraction-output-{A,B}.json live
#                               (default: $CLAUDE_HOME/onboarding)
#   AUDIT_LOG                   JSONL audit path
#                               (default: $CLAUDE_HOME/onboarding/audit/section-b.jsonl)
#   TRANSCRIPT_DIR              Voice/typed transcript output dir
#                               (default: $CLAUDE_HOME/onboarding/transcripts)
#   Q_FIELD_MAP                 q-field-map.json source path
#                               (default: foundation-repo onboarding/q-field-map.json)
#   EXTRACTION_PROMPT_TEMPLATE  Section-B extraction prompt template
#                               (default: foundation-repo onboarding/
#                                         extraction-prompts/section-B.md)
#   VOICE_CAPTURE_BIN           voice-capture.sh executable path
#                               (default: foundation-repo onboarding/voice-capture.sh)
#   TYPED_TEXTAREA_BIN          typed-textarea.sh executable path
#                               (default: foundation-repo onboarding/fallback/typed-textarea.sh)
#   EXTRACTION_OUTPUT_OVERRIDE  Path to a pre-existing extraction-output JSON
#                               file (Pass 2 production OR hermetic test path)
#   STDIN_TRANSCRIPT_OVERRIDE   Forwarded to voice-capture/typed-textarea
#                               for hermetic transcript injection
#   VOICE_PROBE_OVERRIDE        Forwarded to voice-capture
#
# Args:
#   --auto-confirm              Non-interactive accept (parity with
#                               section-a.sh --auto-accept)
#   --auto-opt-out              Elect ALL three Section-B opt-outs
#                               (#2 org, #3 people, #4 tools)
#   --opt-out-org               Elect opt-out #2 only
#   --opt-out-people            Elect opt-out #3 only
#   --opt-out-tools             Elect opt-out #4 only
#   --typed-only                Force typed-textarea path (skip voice probe)
#   --inputs-dir DIR            Override INPUTS_DIR
#   --audit-log PATH            Override AUDIT_LOG
#   --transcript-dir DIR        Override TRANSCRIPT_DIR
#   --prompt-card PATH          Override PROMPT_CARD_PATH
#
# Exit codes:
#   0   success (section committed; extraction-output-B.json + audit written)
#   2   bad invocation / missing dependency / invalid input
#   3   write error / extraction-output validation failure
#   5   extraction needed (Pass 1 complete; caller must run model + re-invoke
#       with EXTRACTION_OUTPUT_OVERRIDE set)
#   130 user quit (forwarded from voice-capture / typed-textarea)

set -u

diag() { printf 'section-b FAIL: %s\n' "$1" >&2; }
info() { printf 'section-b: %s\n' "$1" >&2; }

# --- source paths.sh if present (post-install runtime); fall back to env ---
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi

# --- dependency check ---
for tool in jq date python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    diag "$tool required but not on PATH"
    exit 2
  fi
done

# --- foundation-repo source resolution (Bucket A) ---
# section-b.sh ships into $CLAUDE_HOME/onboarding/ux/ at install (SHIP-TO-RUNTIME).
# For invocation under tests we resolve foundation-repo neighbors via $0's
# directory; production runtime resolves via $CLAUDE_HOME.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONBOARDING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- defaults ---
INPUTS_DIR="${INPUTS_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding}"
AUDIT_LOG="${AUDIT_LOG:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/audit/section-b.jsonl}"
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/transcripts}"
Q_FIELD_MAP="${Q_FIELD_MAP:-$ONBOARDING_DIR/q-field-map.json}"
EXTRACTION_PROMPT_TEMPLATE="${EXTRACTION_PROMPT_TEMPLATE:-$ONBOARDING_DIR/extraction-prompts/section-B.md}"
VOICE_CAPTURE_BIN="${VOICE_CAPTURE_BIN:-$ONBOARDING_DIR/voice-capture.sh}"
TYPED_TEXTAREA_BIN="${TYPED_TEXTAREA_BIN:-$ONBOARDING_DIR/fallback/typed-textarea.sh}"
PROMPT_CARD_PATH="${PROMPT_CARD_PATH:-}"
TYPED_ONLY=0
AUTO_CONFIRM=0
AUTO_OPT_OUT=0
OPT_OUT_ORG=0
OPT_OUT_PEOPLE=0
OPT_OUT_TOOLS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --auto-confirm)    AUTO_CONFIRM=1; shift ;;
    --auto-opt-out)    AUTO_OPT_OUT=1; shift ;;
    --opt-out-org)     OPT_OUT_ORG=1; shift ;;
    --opt-out-people)  OPT_OUT_PEOPLE=1; shift ;;
    --opt-out-tools)   OPT_OUT_TOOLS=1; shift ;;
    --typed-only)      TYPED_ONLY=1; shift ;;
    --inputs-dir)      INPUTS_DIR="$2"; shift 2 ;;
    --audit-log)       AUDIT_LOG="$2"; shift 2 ;;
    --transcript-dir)  TRANSCRIPT_DIR="$2"; shift 2 ;;
    --prompt-card)     PROMPT_CARD_PATH="$2"; shift 2 ;;
    -h|--help)         sed -n '2,110p' "$0"; exit 0 ;;
    *)                 diag "unknown arg: $1"; exit 2 ;;
  esac
done

# Apply blanket --auto-opt-out: enables all three Section-B surfaces.
if [ "$AUTO_OPT_OUT" = "1" ]; then
  OPT_OUT_ORG=1
  OPT_OUT_PEOPLE=1
  OPT_OUT_TOOLS=1
fi

# --- validate inputs ---
if [ -z "$PROMPT_CARD_PATH" ]; then
  diag "PROMPT_CARD_PATH required (--prompt-card or env)"
  exit 2
fi
if [ ! -r "$PROMPT_CARD_PATH" ]; then
  diag "PROMPT_CARD_PATH not readable: $PROMPT_CARD_PATH"
  exit 2
fi
if [ ! -r "$Q_FIELD_MAP" ]; then
  diag "Q_FIELD_MAP not readable: $Q_FIELD_MAP"
  exit 2
fi
if [ ! -r "$EXTRACTION_PROMPT_TEMPLATE" ]; then
  diag "EXTRACTION_PROMPT_TEMPLATE not readable: $EXTRACTION_PROMPT_TEMPLATE"
  exit 2
fi

# Section A's output is the discovery context for Section B's extraction.
DISCOVERY_CONTEXT="$INPUTS_DIR/extraction-output-A.json"
if [ ! -r "$DISCOVERY_CONTEXT" ]; then
  diag "Section A discovery context not found at $DISCOVERY_CONTEXT — run section-a.sh first"
  exit 2
fi

# --- run constants ---
SECTION_ID="B"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TRANSCRIPT_PATH="$TRANSCRIPT_DIR/section-b.txt"
COMPILED_PROMPT_PATH="$INPUTS_DIR/extraction-prompt-B.compiled.txt"
EXTRACTION_OUT="$INPUTS_DIR/extraction-output-B.json"

mkdir -p "$INPUTS_DIR" "$TRANSCRIPT_DIR" "$(dirname "$AUDIT_LOG")" 2>/dev/null || {
  diag "cannot create output directories"
  exit 3
}

# --- Pass 1 step 2: transcript capture (idempotent) ---
capture_transcript() {
  if [ -f "$TRANSCRIPT_PATH" ]; then
    info "transcript already exists at $TRANSCRIPT_PATH; skipping capture"
    return 0
  fi

  if [ "$TYPED_ONLY" = "1" ]; then
    info "dispatching to typed-textarea (--typed-only)"
    TRANSCRIPT_DIR="$TRANSCRIPT_DIR" \
      "$TYPED_TEXTAREA_BIN" "$SECTION_ID" "$PROMPT_CARD_PATH"
    return $?
  fi

  info "dispatching to voice-capture (probe will route to typed on unavailability)"
  TRANSCRIPT_DIR="$TRANSCRIPT_DIR" \
    "$VOICE_CAPTURE_BIN" "$SECTION_ID" "$PROMPT_CARD_PATH"
  rc=$?
  case "$rc" in
    0)   return 0 ;;
    4)
      # voice probe says available but no stdin pipe — caller must dispatch
      # to typed. The pragmatic single-script handling: re-invoke typed.
      info "voice unavailable in this context; dispatching to typed-textarea"
      TRANSCRIPT_DIR="$TRANSCRIPT_DIR" \
        "$TYPED_TEXTAREA_BIN" "$SECTION_ID" "$PROMPT_CARD_PATH"
      return $?
      ;;
    130) info "user quit during transcript capture"; return 130 ;;
    *)   diag "transcript capture failed (rc=$rc)"; return 3 ;;
  esac
}

# --- Pass 1 step 3: render compiled extraction prompt ---
# Substitutes 4 placeholder blocks per extraction-prompts/section-B.md.
# Schema slice = q-field-map.json filtered to direct_qs.B-* (per L160-162 of
# section-B.md notes). Discovery context = full extraction-output-A.json.
render_compiled_prompt() {
  local schema_slice_tmp="$INPUTS_DIR/.schema-slice-B.tmp.$$"

  jq -c '{direct_qs: (.direct_qs | with_entries(select(.key | startswith("B-"))))}' \
    "$Q_FIELD_MAP" > "$schema_slice_tmp" || {
    diag "schema-slice extraction failed"
    rm -f "$schema_slice_tmp"
    return 3
  }

  python3 -c '
import sys
template, transcript_f, card_f, slice_f, ctx_f, out_f = sys.argv[1:]
def rd(p):
    with open(p, "r", encoding="utf-8") as f: return f.read()
t = rd(template)
t = t.replace("<<<{transcript}>>>", rd(transcript_f))
t = t.replace("<<<{section_prompt_card}>>>", rd(card_f))
t = t.replace("<<<{schema_skeleton_slice}>>>", rd(slice_f))
t = t.replace("<<<{discovery_context}>>>", rd(ctx_f))
with open(out_f, "w", encoding="utf-8") as f: f.write(t)
' "$EXTRACTION_PROMPT_TEMPLATE" "$TRANSCRIPT_PATH" "$PROMPT_CARD_PATH" \
    "$schema_slice_tmp" "$DISCOVERY_CONTEXT" "$COMPILED_PROMPT_PATH" || {
    diag "compiled-prompt render failed"
    rm -f "$schema_slice_tmp"
    return 3
  }
  rm -f "$schema_slice_tmp"
  return 0
}

# --- Pass 2: process extraction output ---
# $1 = extraction-output JSON file path (validated upstream).
# Returns 0 on success; 3 on validation/write failure.
process_extraction() {
  local extract_in="$1"

  # Validate basic shape: section_id="B", populated is object.
  jq -e . "$extract_in" >/dev/null 2>&1 || { diag "extraction-output not valid JSON"; return 3; }
  local sid
  sid="$(jq -r '.section_id // empty' "$extract_in")"
  if [ "$sid" != "B" ]; then
    diag "extraction-output section_id='$sid' (expected 'B')"
    return 3
  fi
  jq -e '.populated | type == "object"' "$extract_in" >/dev/null 2>&1 \
    || { diag "extraction-output 'populated' must be object"; return 3; }

  # --- confidence gate categorization ---
  # Walk populated keys, look up confidence per key. Bucket into HIGH/MID/LOW.
  # LOW + required → record follow_up field-path in audit (no re-extraction
  # in T-5a; T-6 owns the user-facing loop).
  local gated_tmp="$INPUTS_DIR/.gated-B.tmp.$$"
  jq -c '
    . as $e
    | ($e.populated | keys) as $paths
    | {
        high: [ $paths[] | . as $p | select(($e.confidence[$p] // 1.0) >= 0.85) ],
        mid:  [ $paths[] | . as $p | select(($e.confidence[$p] // 1.0) >= 0.5 and ($e.confidence[$p] // 1.0) < 0.85) ],
        low:  [ $paths[] | . as $p | select(($e.confidence[$p] // 1.0) < 0.5) ]
      }
  ' "$extract_in" > "$gated_tmp" || { diag "gate categorization failed"; rm -f "$gated_tmp"; return 3; }

  # follow_ups[] field-paths: extraction's missing_required[] ∪ low-confidence
  # required fields (from gate). For T-5a we capture both as field-path
  # identifiers; the actual surgical-text follow_up belongs to T-6.
  local followups_json
  followups_json="$(jq -c --slurpfile g "$gated_tmp" '
    ((.missing_required // []) + ($g[0].low // []))
    | unique
  ' "$extract_in")"

  rm -f "$gated_tmp"

  # --- opt-out routing (#2/#3/#4) ---
  # Each surface deterministically overrides extraction.populated for its
  # domain. Records the surface-name in opt_outs[] for audit.
  local opt_outs_json="[]"
  local populated_tmp="$INPUTS_DIR/.populated-B.tmp.$$"
  jq -c '.populated' "$extract_in" > "$populated_tmp" || {
    diag "populated extraction failed"; rm -f "$populated_tmp"; return 3;
  }

  if [ "$OPT_OUT_ORG" = "1" ]; then
    opt_outs_json="$(echo "$opt_outs_json" | jq -c '. + ["organization_skipped"]')"
    jq -c '."U.identity.organization" = null' "$populated_tmp" > "$populated_tmp.s" \
      && mv "$populated_tmp.s" "$populated_tmp"
  fi
  if [ "$OPT_OUT_PEOPLE" = "1" ]; then
    opt_outs_json="$(echo "$opt_outs_json" | jq -c '. + ["people_skipped"]')"
    jq -c '."U.people" = []' "$populated_tmp" > "$populated_tmp.s" \
      && mv "$populated_tmp.s" "$populated_tmp"
  fi
  if [ "$OPT_OUT_TOOLS" = "1" ]; then
    # Section B opt-out #4 = tool integrations. Section B's extraction does
    # not populate U.tools.* directly (those are A's domain), so this is a
    # signal-only opt-out: append to opt_outs[] for downstream consumers
    # (initial-job-setup + librarian skill registration) without mutating
    # the populated map. No per-tool null overrides at this layer.
    opt_outs_json="$(echo "$opt_outs_json" | jq -c '. + ["tools_skipped"]')"
  fi

  # --- atomic write of extraction-output-B.json (per-section "merge") ---
  local final_tmp="$EXTRACTION_OUT.tmp.$$"
  jq -c \
    --argjson populated "$(cat "$populated_tmp")" \
    --argjson opt_outs "$opt_outs_json" \
    --arg run_id "$RUN_ID" \
    --arg ts "$RUN_TS" \
    '{
      section_id: "B",
      extraction_mode: "transcript",
      populated: $populated,
      confidence: (.confidence // {}),
      source_spans: (.source_spans // {}),
      missing_required: (.missing_required // []),
      conflicts: (.conflicts // []),
      follow_up: (.follow_up // null),
      opt_outs: $opt_outs,
      run_id: $run_id,
      timestamp: $ts
    }' "$extract_in" > "$final_tmp" || {
    diag "extraction-output-B render failed"; rm -f "$final_tmp" "$populated_tmp"; return 3;
  }
  mv "$final_tmp" "$EXTRACTION_OUT" || {
    diag "extraction-output-B rename failed"; rm -f "$final_tmp" "$populated_tmp"; return 3;
  }
  rm -f "$populated_tmp"

  # --- JSONL audit entry (9-key shape per SKILL.md L141) ---
  # follow_ups[] holds field-path identifiers (no user-typed strings) per
  # reference-leak floor. corrections[] is empty in T-5a (T-6 owns inline
  # edits). source_spans is a data field (spec L141) — copied verbatim.
  local audit_tmp="$AUDIT_LOG.tmp.$$"
  jq -nc \
    --arg section_id "$SECTION_ID" \
    --arg run_id "$RUN_ID" \
    --arg ts "$RUN_TS" \
    --argjson opt_outs "$opt_outs_json" \
    --argjson confidence_map "$(jq -c '.confidence // {}' "$extract_in")" \
    --argjson source_spans "$(jq -c '.source_spans // {}' "$extract_in")" \
    --argjson follow_ups "$followups_json" \
    --argjson manifest_paths "$(jq -c '.populated | keys' "$EXTRACTION_OUT")" \
    '{
      section_id: $section_id,
      run_id: $run_id,
      ts: $ts,
      opt_outs: $opt_outs,
      confidence_map: $confidence_map,
      source_spans: $source_spans,
      corrections: [],
      follow_ups: $follow_ups,
      manifest_paths_written: $manifest_paths
    }' > "$audit_tmp" || { diag "audit JSONL render failed"; rm -f "$audit_tmp"; return 3; }
  cat "$audit_tmp" >> "$AUDIT_LOG" || { diag "audit JSONL append failed"; rm -f "$audit_tmp"; return 3; }
  rm -f "$audit_tmp"

  return 0
}

# --- main flow ---

# Pass 1 step 2: transcript (idempotent — skips if already present).
capture_transcript
case "$?" in
  0)   : ;;
  130) info "section-b aborted at user request. Re-run /onboard --resume to continue."; exit 130 ;;
  *)   exit 3 ;;
esac

# Pass 1 step 3: render compiled extraction prompt.
render_compiled_prompt || exit 3

# Pass 1 → Pass 2 transition: do we have the extraction output yet?
if [ -n "${EXTRACTION_OUTPUT_OVERRIDE:-}" ]; then
  if [ ! -r "$EXTRACTION_OUTPUT_OVERRIDE" ]; then
    diag "EXTRACTION_OUTPUT_OVERRIDE set but not readable: $EXTRACTION_OUTPUT_OVERRIDE"
    exit 2
  fi
  EXTRACTION_IN="$EXTRACTION_OUTPUT_OVERRIDE"
else
  info "compiled prompt staged at $COMPILED_PROMPT_PATH"
  info "Pass 1 complete. To continue: run the extraction model on the compiled prompt,"
  info "then re-invoke section-b.sh with EXTRACTION_OUTPUT_OVERRIDE=<path-to-output.json>."
  exit 5
fi

# Pass 2: process extraction → confidence gate → opt-outs → fragment + audit.
process_extraction "$EXTRACTION_IN" || exit 3

# T-6 handoff stub (deferred): the inline-edit summary screen consumes
# extraction-output-B.json + audit follow_ups[] to render per-field disposition.
info "Section B fragment committed at $EXTRACTION_OUT"
info "JSONL audit entry appended at $AUDIT_LOG"
info "TODO(T-6): hand off to inline-edit summary screen (render-summary.sh)"
exit 0
