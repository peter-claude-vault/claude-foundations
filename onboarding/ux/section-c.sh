#!/bin/bash
# onboarding/ux/section-c.sh — SP07 T-5b Section C record-and-drop runner +
# archetype-inference invocation. Second concrete instance of the per-section
# pipeline mechanism shipped in T-5a (section-b.sh).
#
# Per-section pipeline composes T-2 (Section A discovery context),
# T-3 (voice-capture wrapper) + T-4 (typed-textarea fallback) for transcript
# capture, the SP01 per-section extraction prompt for field population, the
# confidence-gate policy for per-field disposition, the opt-out routing for
# surfaces #5/#6, and — unique to Section C per SKILL.md §Per-Section
# Pipeline step 10 — a post-extraction archetype-inference pass against
# B+C transcripts. The archetype label is merged into the populated map
# (U.architect.prior_seed) and archetype-seeded canonical file types are
# appended (deduplicated) to U.vault.canonical_file_types[]. Atomic write
# of the populated extraction-output fragment satisfies the per-section
# merge contract; the final bootstrap-schemas.sh invocation is the
# orchestrator's responsibility after all 5 sections have committed their
# fragments (CFF-S77-1 inherited).
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
#        filled (transcript, prompt-card, schema-skeleton-slice via
#        direct_qs.C-* filter, discovery-context from
#        extraction-output-A.json) → write to
#        $INPUTS_DIR/extraction-prompt-C.compiled.txt
#     4. Exit 5 with diagnostic: "compiled prompt staged at <path>; pipe
#        model output JSON via EXTRACTION_OUTPUT_OVERRIDE=<path> and
#        re-invoke section-c.sh to continue"
#
#   Pass 2 (caller has run the extraction model, JSON output staged):
#     5. Read extraction output from $EXTRACTION_OUTPUT_OVERRIDE
#     6. Apply confidence gate per field: bucket into HIGH (≥0.85) / MID
#        (0.5-0.85) / LOW (<0.5). For LOW + required: record the
#        extraction's follow_up text as a field-path entry in audit
#        follow_ups[] (T-6 owns the user-facing surgical follow-up render
#        + re-extraction; this script records the categorization only)
#     7. Apply opt-out routing for surfaces #5/#6 (--opt-out-vault /
#        --opt-out-sensitive / --auto-opt-out blanket). Each opt-out
#        writes its own deterministic record over the extraction's
#        populated map without aborting the section
#     8. Atomic-write $INPUTS_DIR/extraction-output-C.json (R-43 atomic
#        tmp+rename). This is the per-section "merge" — bootstrap-schemas.sh
#        runs once at end-of-flow consuming all 5 extraction-output files
#     9. **NEW for Section C**: invoke archetype-inference.sh against the
#        B+C transcripts (per SKILL.md §Per-Section Pipeline step 10).
#        Receive {archetype, confidence, margin, score_top, score_runner_up}.
#        Look up archetype-keywords.json
#        .archetypes[archetype].seeds.vault_canonical_file_types_add and
#        merge into the populated map:
#          - U.architect.prior_seed = <archetype label>
#          - U.vault.canonical_file_types[] += seeds (deduplicated)
#        Skip the canonical_file_types append if --opt-out-vault was elected
#        (vault is null; nothing to append into). Re-write
#        extraction-output-C.json atomically with the augmented map. Append
#        a separate archetype-inference.jsonl audit entry — section-c.jsonl
#        keeps its 9-key shape.
#    10. Append per-section JSONL audit entry to $AUDIT_LOG with the 9 keys
#        per SKILL.md L141: section_id, run_id, ts, opt_outs[],
#        confidence_map, source_spans, corrections[], follow_ups[],
#        manifest_paths_written[]
#    11. Stub T-6 summary handoff (deferred): info message only
#    12. Exit 0
#
# Hermetic test mode (single-pass): pre-stage transcript at
# $TRANSCRIPT_DIR/section-c.txt + set EXTRACTION_OUTPUT_OVERRIDE pointing at
# a stub extraction-output JSON file. The script detects both pre-conditions,
# skips capture + prompt-rendering, runs steps 5-12. archetype-inference can
# be stubbed via ARCHETYPE_INFERENCE_BIN env knob; archetype-keywords lookup
# via ARCHETYPE_KEYWORDS_FILE env knob. KEYWORDS_FILE is forwarded to the
# stub (or the real binary) so both processes see the same keyword table.
#
# Hard invariants (mirror section-b.sh / voice-capture.sh / typed-textarea.sh):
#   - Bash 3.2 + R-23 compatible (no declare -A, no mapfile, no ${var,,};
#     use tr '[:upper:]' '[:lower:]' for case folding)
#   - Single-deliverable per R-37 (Section C runner + archetype-inference
#     invocation; T-5c/Section D is a separate session)
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
#   PROMPT_CARD_PATH            File with the section-C prompt-card text
#                               (caller anchor-extracts from
#                               onboarder-design.md §5 before invocation)
#   INPUTS_DIR                  Where extraction-output-{A,B,C}.json live
#                               (default: $CLAUDE_HOME/onboarding)
#   AUDIT_LOG                   JSONL audit path
#                               (default: $CLAUDE_HOME/onboarding/audit/section-c.jsonl)
#   ARCHETYPE_AUDIT_LOG         JSONL audit path for archetype-inference
#                               (default: $CLAUDE_HOME/onboarding/audit/archetype-inference.jsonl)
#   TRANSCRIPT_DIR              Voice/typed transcript output dir
#                               (default: $CLAUDE_HOME/onboarding/transcripts)
#   Q_FIELD_MAP                 q-field-map.json source path
#                               (default: foundation-repo onboarding/q-field-map.json)
#   EXTRACTION_PROMPT_TEMPLATE  Section-C extraction prompt template
#                               (default: foundation-repo onboarding/
#                                         extraction-prompts/section-C.md)
#   VOICE_CAPTURE_BIN           voice-capture.sh executable path
#                               (default: foundation-repo onboarding/voice-capture.sh)
#   TYPED_TEXTAREA_BIN          typed-textarea.sh executable path
#                               (default: foundation-repo onboarding/fallback/typed-textarea.sh)
#   ARCHETYPE_INFERENCE_BIN     archetype-inference.sh executable path
#                               (default: foundation-repo onboarding/archetype-inference.sh)
#   ARCHETYPE_KEYWORDS_FILE     archetype-keywords.json source path
#                               (default: foundation-repo onboarding/archetype-keywords.json)
#                               Also forwarded to ARCHETYPE_INFERENCE_BIN as
#                               KEYWORDS_FILE so caller + callee agree
#   EXTRACTION_OUTPUT_OVERRIDE  Path to a pre-existing extraction-output JSON
#                               file (Pass 2 production OR hermetic test path)
#   STDIN_TRANSCRIPT_OVERRIDE   Forwarded to voice-capture/typed-textarea
#                               for hermetic transcript injection
#   VOICE_PROBE_OVERRIDE        Forwarded to voice-capture
#
# Args:
#   --auto-confirm              Non-interactive accept (parity with
#                               section-a.sh --auto-accept)
#   --auto-opt-out              Elect BOTH Section-C opt-outs
#                               (#5 vault, #6 sensitive-content)
#   --opt-out-vault             Elect opt-out #5 only (vault: null)
#   --opt-out-sensitive         Elect opt-out #6 only (system.opt_outs[]
#                               appends "sensitive_isolation")
#   --typed-only                Force typed-textarea path (skip voice probe)
#   --inputs-dir DIR            Override INPUTS_DIR
#   --audit-log PATH            Override AUDIT_LOG
#   --archetype-audit-log PATH  Override ARCHETYPE_AUDIT_LOG
#   --transcript-dir DIR        Override TRANSCRIPT_DIR
#   --prompt-card PATH          Override PROMPT_CARD_PATH
#
# Exit codes:
#   0   success (section committed; extraction-output-C.json + audit written)
#   2   bad invocation / missing dependency / invalid input
#   3   write error / extraction-output validation failure
#   5   extraction needed (Pass 1 complete; caller must run model + re-invoke
#       with EXTRACTION_OUTPUT_OVERRIDE set)
#   130 user quit (forwarded from voice-capture / typed-textarea)

set -u

diag() { printf 'section-c FAIL: %s\n' "$1" >&2; }
info() { printf 'section-c: %s\n' "$1" >&2; }

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
# section-c.sh ships into $CLAUDE_HOME/onboarding/ux/ at install (SHIP-TO-RUNTIME).
# For invocation under tests we resolve foundation-repo neighbors via $0's
# directory; production runtime resolves via $CLAUDE_HOME.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONBOARDING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- defaults ---
INPUTS_DIR="${INPUTS_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding}"
AUDIT_LOG="${AUDIT_LOG:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/audit/section-c.jsonl}"
ARCHETYPE_AUDIT_LOG="${ARCHETYPE_AUDIT_LOG:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/audit/archetype-inference.jsonl}"
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/transcripts}"
Q_FIELD_MAP="${Q_FIELD_MAP:-$ONBOARDING_DIR/q-field-map.json}"
EXTRACTION_PROMPT_TEMPLATE="${EXTRACTION_PROMPT_TEMPLATE:-$ONBOARDING_DIR/extraction-prompts/section-C.md}"
VOICE_CAPTURE_BIN="${VOICE_CAPTURE_BIN:-$ONBOARDING_DIR/voice-capture.sh}"
TYPED_TEXTAREA_BIN="${TYPED_TEXTAREA_BIN:-$ONBOARDING_DIR/fallback/typed-textarea.sh}"
ARCHETYPE_INFERENCE_BIN="${ARCHETYPE_INFERENCE_BIN:-$ONBOARDING_DIR/archetype-inference.sh}"
ARCHETYPE_KEYWORDS_FILE="${ARCHETYPE_KEYWORDS_FILE:-$ONBOARDING_DIR/archetype-keywords.json}"
PROMPT_CARD_PATH="${PROMPT_CARD_PATH:-}"
TYPED_ONLY=0
AUTO_CONFIRM=0
AUTO_OPT_OUT=0
OPT_OUT_VAULT=0
OPT_OUT_SENSITIVE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --auto-confirm)         AUTO_CONFIRM=1; shift ;;
    --auto-opt-out)         AUTO_OPT_OUT=1; shift ;;
    --opt-out-vault)        OPT_OUT_VAULT=1; shift ;;
    --opt-out-sensitive)    OPT_OUT_SENSITIVE=1; shift ;;
    --typed-only)           TYPED_ONLY=1; shift ;;
    --inputs-dir)           INPUTS_DIR="$2"; shift 2 ;;
    --audit-log)            AUDIT_LOG="$2"; shift 2 ;;
    --archetype-audit-log)  ARCHETYPE_AUDIT_LOG="$2"; shift 2 ;;
    --transcript-dir)       TRANSCRIPT_DIR="$2"; shift 2 ;;
    --prompt-card)          PROMPT_CARD_PATH="$2"; shift 2 ;;
    -h|--help)              sed -n '2,140p' "$0"; exit 0 ;;
    *)                      diag "unknown arg: $1"; exit 2 ;;
  esac
done

# Apply blanket --auto-opt-out: enables both Section-C surfaces.
if [ "$AUTO_OPT_OUT" = "1" ]; then
  OPT_OUT_VAULT=1
  OPT_OUT_SENSITIVE=1
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

# Section A's output is the discovery context for Section C's extraction.
DISCOVERY_CONTEXT="$INPUTS_DIR/extraction-output-A.json"
if [ ! -r "$DISCOVERY_CONTEXT" ]; then
  diag "Section A discovery context not found at $DISCOVERY_CONTEXT — run section-a.sh first"
  exit 2
fi

# --- run constants ---
SECTION_ID="C"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TRANSCRIPT_PATH="$TRANSCRIPT_DIR/section-c.txt"
COMPILED_PROMPT_PATH="$INPUTS_DIR/extraction-prompt-C.compiled.txt"
EXTRACTION_OUT="$INPUTS_DIR/extraction-output-C.json"

mkdir -p "$INPUTS_DIR" "$TRANSCRIPT_DIR" "$(dirname "$AUDIT_LOG")" "$(dirname "$ARCHETYPE_AUDIT_LOG")" 2>/dev/null || {
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
# Substitutes 4 placeholder blocks per extraction-prompts/section-C.md.
# Schema slice = q-field-map.json filtered to direct_qs.C-* (per L171-172
# of section-C.md notes). Discovery context = full extraction-output-A.json.
render_compiled_prompt() {
  local schema_slice_tmp="$INPUTS_DIR/.schema-slice-C.tmp.$$"

  jq -c '{direct_qs: (.direct_qs | with_entries(select(.key | startswith("C-"))))}' \
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

  # Validate basic shape: section_id="C", populated is object.
  jq -e . "$extract_in" >/dev/null 2>&1 || { diag "extraction-output not valid JSON"; return 3; }
  local sid
  sid="$(jq -r '.section_id // empty' "$extract_in")"
  if [ "$sid" != "C" ]; then
    diag "extraction-output section_id='$sid' (expected 'C')"
    return 3
  fi
  jq -e '.populated | type == "object"' "$extract_in" >/dev/null 2>&1 \
    || { diag "extraction-output 'populated' must be object"; return 3; }

  # --- confidence gate categorization ---
  # Walk populated keys, look up confidence per key. Bucket into HIGH/MID/LOW.
  # LOW + required → record follow_up field-path in audit (no re-extraction
  # in T-5b; T-6 owns the user-facing loop).
  local gated_tmp="$INPUTS_DIR/.gated-C.tmp.$$"
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
  # required fields (from gate). For T-5b we capture both as field-path
  # identifiers; the actual surgical-text follow_up belongs to T-6.
  local followups_json
  followups_json="$(jq -c --slurpfile g "$gated_tmp" '
    ((.missing_required // []) + ($g[0].low // []))
    | unique
  ' "$extract_in")"

  rm -f "$gated_tmp"

  # --- opt-out routing (#5/#6) ---
  # Each surface deterministically overrides extraction.populated for its
  # domain. Records the surface-name in opt_outs[] for audit.
  local opt_outs_json="[]"
  local populated_tmp="$INPUTS_DIR/.populated-C.tmp.$$"
  jq -c '.populated' "$extract_in" > "$populated_tmp" || {
    diag "populated extraction failed"; rm -f "$populated_tmp"; return 3;
  }

  if [ "$OPT_OUT_VAULT" = "1" ]; then
    # Surface #5 (vault): drop all U.vault.* keys + record sentinel
    # "U.vault" = null. Downstream librarian reads U.vault == null as
    # stub-mode (per SKILL.md L93). canonical_file_types[] cannot be
    # appended into a null vault, so the archetype-inference pass below
    # will skip its append step when this opt-out is elected.
    opt_outs_json="$(echo "$opt_outs_json" | jq -c '. + ["vault_skipped"]')"
    jq -c 'with_entries(select(.key | startswith("U.vault.") | not))
           | . + {"U.vault": null}' \
        "$populated_tmp" > "$populated_tmp.s" \
      && mv "$populated_tmp.s" "$populated_tmp"
  fi
  if [ "$OPT_OUT_SENSITIVE" = "1" ]; then
    # Surface #6 (sensitive-content acknowledgement): append
    # "sensitive_isolation" to U.system.opt_outs[] (canonical C-3 shape
    # bootstrap-schemas.sh L324-338 expects). Idempotent at orchestrator
    # via `unique`; we still ensure local idempotence here.
    opt_outs_json="$(echo "$opt_outs_json" | jq -c '. + ["sensitive_skipped"]')"
    jq -c '."U.system.opt_outs" = (((."U.system.opt_outs" // []) + ["sensitive_isolation"]) | unique)' \
        "$populated_tmp" > "$populated_tmp.s" \
      && mv "$populated_tmp.s" "$populated_tmp"
  fi

  # --- atomic write of extraction-output-C.json (per-section "merge") ---
  local final_tmp="$EXTRACTION_OUT.tmp.$$"
  jq -c \
    --argjson populated "$(cat "$populated_tmp")" \
    --argjson opt_outs "$opt_outs_json" \
    --arg run_id "$RUN_ID" \
    --arg ts "$RUN_TS" \
    '{
      section_id: "C",
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
    diag "extraction-output-C render failed"; rm -f "$final_tmp" "$populated_tmp"; return 3;
  }
  mv "$final_tmp" "$EXTRACTION_OUT" || {
    diag "extraction-output-C rename failed"; rm -f "$final_tmp" "$populated_tmp"; return 3;
  }
  rm -f "$populated_tmp"

  # --- archetype-inference pass (Section C only; SKILL.md step 10) ---
  # Read B + C transcripts, build a JSON wrapper, invoke archetype-inference.sh,
  # merge result back into extraction-output-C.json, append separate audit.
  run_archetype_inference || return 3

  # --- JSONL audit entry (9-key shape per SKILL.md L141) ---
  # follow_ups[] holds field-path identifiers (no user-typed strings) per
  # reference-leak floor. corrections[] is empty in T-5b (T-6 owns inline
  # edits). source_spans is a data field (spec L141) — copied verbatim.
  # manifest_paths reflects the final populated keys after archetype merge.
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

# --- archetype-inference invocation (Section C — SKILL.md step 10) ---
# Reads B + C transcripts, builds a JSON wrapper for archetype-inference.sh,
# parses the {archetype, confidence, ...} response, looks up
# seeds.vault_canonical_file_types_add from archetype-keywords.json, and
# merges into the extraction-output-C.json populated map:
#   - U.architect.prior_seed = <archetype label>
#   - U.vault.canonical_file_types[] += seeds (deduplicated)
# When --opt-out-vault is elected, U.vault is null and the file-type append
# step is skipped; U.architect.prior_seed is still written (architect lives
# outside vault). Audits a separate archetype-inference.jsonl entry.
# Returns 0 on success or skip; 3 on irrecoverable error.
run_archetype_inference() {
  local b_transcript="$TRANSCRIPT_DIR/section-b.txt"
  local c_transcript="$TRANSCRIPT_PATH"

  if [ ! -r "$ARCHETYPE_INFERENCE_BIN" ] && [ ! -x "$ARCHETYPE_INFERENCE_BIN" ]; then
    diag "ARCHETYPE_INFERENCE_BIN not executable: $ARCHETYPE_INFERENCE_BIN"
    return 3
  fi
  if [ ! -r "$ARCHETYPE_KEYWORDS_FILE" ]; then
    diag "ARCHETYPE_KEYWORDS_FILE not readable: $ARCHETYPE_KEYWORDS_FILE"
    return 3
  fi

  # Build transcript wrapper. Sections B and C both contribute; missing
  # B (e.g. resumed mid-flow) maps to empty string. archetype-inference.sh
  # tokenizes string leaves, so any nesting works.
  local b_text="" c_text=""
  [ -r "$b_transcript" ] && b_text="$(cat "$b_transcript")"
  [ -r "$c_transcript" ] && c_text="$(cat "$c_transcript")"

  local arch_input_tmp="$INPUTS_DIR/.archetype-input.tmp.$$"
  jq -nc --arg b "$b_text" --arg c "$c_text" \
    '{section_b: $b, section_c: $c}' > "$arch_input_tmp" || {
    diag "archetype input render failed"; rm -f "$arch_input_tmp"; return 3;
  }

  # Invoke archetype-inference.sh. KEYWORDS_FILE is the env knob the
  # callee reads; we forward ARCHETYPE_KEYWORDS_FILE so caller + callee
  # see the same table.
  local arch_out_tmp="$INPUTS_DIR/.archetype-output.tmp.$$"
  KEYWORDS_FILE="$ARCHETYPE_KEYWORDS_FILE" \
    "$ARCHETYPE_INFERENCE_BIN" "$arch_input_tmp" > "$arch_out_tmp" 2>/dev/null
  local arch_rc=$?
  rm -f "$arch_input_tmp"

  if [ "$arch_rc" -ne 0 ]; then
    diag "archetype-inference returned rc=$arch_rc"
    rm -f "$arch_out_tmp"
    return 3
  fi
  if ! jq -e . "$arch_out_tmp" >/dev/null 2>&1; then
    diag "archetype-inference emitted invalid JSON"
    rm -f "$arch_out_tmp"
    return 3
  fi

  local archetype
  archetype="$(jq -r '.archetype // empty' "$arch_out_tmp")"
  if [ -z "$archetype" ]; then
    diag "archetype-inference output missing 'archetype' key"
    rm -f "$arch_out_tmp"
    return 3
  fi

  # Look up seeds from archetype-keywords.json. Generalist (the fallback)
  # has no seeds; absent .archetypes[generalist].seeds returns empty, so
  # both branches collapse to "append nothing extra".
  local seeds_json
  seeds_json="$(jq -c --arg a "$archetype" \
    '.archetypes[$a].seeds.vault_canonical_file_types_add // []' \
    "$ARCHETYPE_KEYWORDS_FILE")"
  if [ -z "$seeds_json" ]; then
    seeds_json="[]"
  fi

  # --- merge into extraction-output-C.json populated map ---
  # If --opt-out-vault was elected, U.vault is null; skip the file-type
  # append. U.architect.prior_seed always writes (architect lives outside
  # vault).
  local merge_tmp="$EXTRACTION_OUT.merge.$$"
  if [ "$OPT_OUT_VAULT" = "1" ]; then
    jq -c --arg arch "$archetype" \
      '.populated."U.architect.prior_seed" = $arch' \
      "$EXTRACTION_OUT" > "$merge_tmp" || {
      diag "archetype merge (opt-out-vault) failed"; rm -f "$merge_tmp" "$arch_out_tmp"; return 3;
    }
  else
    jq -c --arg arch "$archetype" --argjson seeds "$seeds_json" \
      '.populated."U.architect.prior_seed" = $arch
       | .populated."U.vault.canonical_file_types" = (
           ((.populated."U.vault.canonical_file_types" // []) + $seeds) | unique
         )' \
      "$EXTRACTION_OUT" > "$merge_tmp" || {
      diag "archetype merge failed"; rm -f "$merge_tmp" "$arch_out_tmp"; return 3;
    }
  fi
  mv "$merge_tmp" "$EXTRACTION_OUT" || {
    diag "archetype merge rename failed"; rm -f "$merge_tmp" "$arch_out_tmp"; return 3;
  }

  # --- separate archetype-inference.jsonl audit entry ---
  # Records the heuristic outcome with structural metadata only — the
  # transcripts themselves are NOT logged (reference-leak floor).
  local manifest_paths_json
  if [ "$OPT_OUT_VAULT" = "1" ]; then
    manifest_paths_json='["U.architect.prior_seed"]'
  else
    manifest_paths_json='["U.architect.prior_seed","U.vault.canonical_file_types"]'
  fi
  local arch_audit_tmp="$ARCHETYPE_AUDIT_LOG.tmp.$$"
  jq -nc \
    --arg run_id "$RUN_ID" \
    --arg ts "$RUN_TS" \
    --arg archetype "$archetype" \
    --argjson confidence "$(jq -r '.confidence // 0' "$arch_out_tmp")" \
    --argjson margin "$(jq -r '.margin // 0' "$arch_out_tmp")" \
    --argjson score_top "$(jq -r '.score_top // 0' "$arch_out_tmp")" \
    --argjson score_runner_up "$(jq -r '.score_runner_up // 0' "$arch_out_tmp")" \
    --argjson seeds "$seeds_json" \
    --argjson manifest_paths "$manifest_paths_json" \
    '{
      run_id: $run_id,
      ts: $ts,
      archetype: $archetype,
      confidence: $confidence,
      margin: $margin,
      score_top: $score_top,
      score_runner_up: $score_runner_up,
      seeds_appended: $seeds,
      manifest_paths_written: $manifest_paths
    }' > "$arch_audit_tmp" || {
    diag "archetype audit JSONL render failed"; rm -f "$arch_audit_tmp" "$arch_out_tmp"; return 3;
  }
  cat "$arch_audit_tmp" >> "$ARCHETYPE_AUDIT_LOG" || {
    diag "archetype audit JSONL append failed"; rm -f "$arch_audit_tmp" "$arch_out_tmp"; return 3;
  }
  rm -f "$arch_audit_tmp" "$arch_out_tmp"

  return 0
}

# --- main flow ---

# Pass 1 step 2: transcript (idempotent — skips if already present).
capture_transcript
case "$?" in
  0)   : ;;
  130) info "section-c aborted at user request. Re-run /onboard --resume to continue."; exit 130 ;;
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
  info "then re-invoke section-c.sh with EXTRACTION_OUTPUT_OVERRIDE=<path-to-output.json>."
  exit 5
fi

# Pass 2: process extraction → confidence gate → opt-outs → fragment +
# archetype-inference + audit.
process_extraction "$EXTRACTION_IN" || exit 3

# Pass 2 complete: section fragment + audit committed. The next step is the
# inline-edit summary screen (render-summary.sh), which consumes
# extraction-output-C.json + audit follow_ups[] to render per-field disposition.
# onboard.sh runs render-summary automatically; LLM-driven /onboard or harness
# scripts read the HANDOFF emit below to know what to invoke next.
info "Section C fragment committed at $EXTRACTION_OUT"
info "JSONL audit entry appended at $AUDIT_LOG"
info "Archetype-inference audit appended at $ARCHETYPE_AUDIT_LOG"
info "# HANDOFF: render-summary --section C"
exit 0
