#!/bin/bash
# onboarding/ux/section-d.sh — SP07 T-5c Section D record-and-drop runner +
# initial-job-setup hook invocation. Third and final concrete instance of
# the per-section pipeline mechanism shipped in T-5a (section-b.sh) and
# settled by T-5b (section-c.sh). Closes T-5 fully.
#
# Per-section pipeline composes T-2 (Section A discovery context),
# T-3 (voice-capture wrapper) + T-4 (typed-textarea fallback) for transcript
# capture, the SP01 per-section extraction prompt for field population, the
# confidence-gate policy for per-field disposition, the opt-out routing for
# surfaces #7/#8/#9/#10, and — unique to Section D per SKILL.md
# §Initial-Job-Setup Integration — a post-extraction call to
# initial-job-setup.sh (S67 inherited; staging-only renderer) when the user
# has not elected opt-out #9. Atomic write of the populated extraction-output
# fragment satisfies the per-section merge contract; the final
# bootstrap-schemas.sh invocation is the orchestrator's responsibility after
# all 5 sections have committed their fragments (CFF-S77-1 inherited).
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
#        direct_qs.D-* filter, discovery-context from
#        extraction-output-A.json) → write to
#        $INPUTS_DIR/extraction-prompt-D.compiled.txt
#     4. Exit 5 with diagnostic: "compiled prompt staged at <path>; pipe
#        model output JSON via EXTRACTION_OUTPUT_OVERRIDE=<path> and
#        re-invoke section-d.sh to continue"
#
#   Pass 2 (caller has run the extraction model, JSON output staged):
#     5. Read extraction output from $EXTRACTION_OUTPUT_OVERRIDE
#     6. Apply confidence gate per field: bucket into HIGH (≥0.85) / MID
#        (0.5-0.85) / LOW (<0.5). For LOW + required: record the field
#        path in audit follow_ups[] (T-6 owns the user-facing surgical
#        follow-up render + re-extraction; this script records the
#        categorization only)
#     7. Apply opt-out routing for surfaces #7 (hook-advisory) +
#        #8 (checkpoint-relaxed) + #9 (initial-job-skipped) +
#        #10 (tripwires-skipped). --auto-opt-out elects all four.
#        Each opt-out writes its own deterministic record over the
#        extraction's populated map without aborting the section.
#     8. Apply D-4 default: if the extraction omitted
#        U.behavioral.hook_preferences.notification_style, set "digest"
#        per q-field-map.json:direct_qs.D-4.targets[0].default_value.
#        D-2 mutual-exclusion (O.jobs[0].id XOR O.jobs:[]) and D-3
#        conditional-on-D-2 are model-side concerns; bootstrap-schemas.sh
#        validates at end-of-flow.
#     9. Atomic-write $INPUTS_DIR/extraction-output-D.json (R-43 atomic
#        tmp+rename). This is the per-section "merge" — bootstrap-schemas.sh
#        runs once at end-of-flow consuming all 5 extraction-output files
#    10. **NEW for Section D**: invoke initial-job-setup.sh against the
#        Section D output (per SKILL.md §Initial-Job-Setup Integration
#        steps 1-8). Builds a transient orchestration.json wrapper from
#        populated."O.jobs[0].id" + the D-2 defaults_applied bundle for
#        schedule.{hour,minute,dow}, points $ORCHESTRATION_JSON at it,
#        forwards $AUTO_CONFIRM. SKIPS this step entirely when
#        --opt-out-initial-job was elected (populated."O.jobs" = []) OR
#        when the extraction emitted O.jobs:[] (model-side opt-out).
#        Failure of initial-job-setup.sh leaves the user-derived fragment
#        intact and exits 3 (caller can resume).
#    11. Append per-section JSONL audit entry to $AUDIT_LOG with the 9 keys
#        per SKILL.md L141: section_id, run_id, ts, opt_outs[],
#        confidence_map, source_spans, corrections[], follow_ups[],
#        manifest_paths_written[]
#    12. Stub T-6 summary handoff (deferred): info message only
#    13. Exit 0
#
# Hermetic test mode (single-pass): pre-stage transcript at
# $TRANSCRIPT_DIR/section-d.txt + set EXTRACTION_OUTPUT_OVERRIDE pointing at
# a stub extraction-output JSON file. The script detects both pre-conditions,
# skips capture + prompt-rendering, runs steps 5-13. initial-job-setup.sh
# can be stubbed via INITIAL_JOB_SETUP_BIN env knob.
#
# Hard invariants (mirror section-b.sh / section-c.sh / voice-capture.sh):
#   - Bash 3.2 + R-23 compatible (no declare -A, no mapfile, no ${var,,};
#     use tr '[:upper:]' '[:lower:]' for case folding)
#   - Single-deliverable per R-37 (Section D runner + initial-job-setup
#     invocation; the 8-Q customization sub-flow is T-9 follow-up)
#   - JSONL audit emits structural metadata in diagnostic fields (follow_ups,
#     corrections); source_spans is a data field per SKILL.md L141 spec
#   - Probes are READ-ONLY against $INPUTS_DIR + $TRANSCRIPT_DIR (Bucket A
#     foundation-repo path classification)
#   - Atomic tmp+rename for every output file; failure rolls back the tmp
#   - Reference-leak floor: NO user-provided strings in DIAGNOSTIC fields
#     (follow_ups[] holds field-path identifiers, not full follow-up text;
#     corrections[] reserved for T-6 inline-edit field-paths)
#   - Production initial-job-setup.sh writes plist to
#     $CLAUDE_HOME/Library/LaunchAgents.staging/ only — NEVER calls
#     launchctl bootstrap (SP08 enable-daemon owns activation); honors
#     --opt-out-initial-job by short-circuiting before invocation
#
# Env knobs (override defaults; tests + dogfood):
#   PROMPT_CARD_PATH            File with the section-D prompt-card text
#                               (caller anchor-extracts from
#                               onboarder-design.md §6 before invocation)
#   INPUTS_DIR                  Where extraction-output-{A,B,C,D}.json live
#                               (default: $CLAUDE_HOME/onboarding)
#   AUDIT_LOG                   JSONL audit path
#                               (default: $CLAUDE_HOME/onboarding/audit/section-d.jsonl)
#   TRANSCRIPT_DIR              Voice/typed transcript output dir
#                               (default: $CLAUDE_HOME/onboarding/transcripts)
#   Q_FIELD_MAP                 q-field-map.json source path
#                               (default: foundation-repo onboarding/q-field-map.json)
#   EXTRACTION_PROMPT_TEMPLATE  Section-D extraction prompt template
#                               (default: foundation-repo onboarding/
#                                         extraction-prompts/section-D.md)
#   VOICE_CAPTURE_BIN           voice-capture.sh executable path
#                               (default: foundation-repo onboarding/voice-capture.sh)
#   TYPED_TEXTAREA_BIN          typed-textarea.sh executable path
#                               (default: foundation-repo onboarding/fallback/typed-textarea.sh)
#   INITIAL_JOB_SETUP_BIN       initial-job-setup.sh executable path
#                               (default: foundation-repo onboarding/initial-job-setup.sh)
#   EXTRACTION_OUTPUT_OVERRIDE  Path to a pre-existing extraction-output JSON
#                               file (Pass 2 production OR hermetic test path)
#   STDIN_TRANSCRIPT_OVERRIDE   Forwarded to voice-capture/typed-textarea
#                               for hermetic transcript injection
#   VOICE_PROBE_OVERRIDE        Forwarded to voice-capture
#
# Args:
#   --auto-confirm              Non-interactive accept (parity with
#                               section-{a,b,c}.sh; forwarded as
#                               AUTO_CONFIRM=1 to initial-job-setup.sh)
#   --auto-opt-out              Elect ALL FOUR Section-D opt-outs
#                               (#7 hook, #8 checkpoint, #9 initial-job,
#                                #10 tripwires)
#   --opt-out-hooks             Elect opt-out #7 only (hook advisory mode)
#   --opt-out-checkpoint        Elect opt-out #8 only (R-26 threshold relax)
#   --opt-out-initial-job       Elect opt-out #9 only (skip plist staging;
#                               populated.O.jobs forced to empty array)
#   --opt-out-tripwires         Elect opt-out #10 only (cron trilayer skip)
#   --typed-only                Force typed-textarea path (skip voice probe)
#   --inputs-dir DIR            Override INPUTS_DIR
#   --audit-log PATH            Override AUDIT_LOG
#   --transcript-dir DIR        Override TRANSCRIPT_DIR
#   --prompt-card PATH          Override PROMPT_CARD_PATH
#
# Exit codes:
#   0   success (section committed; extraction-output-D.json + audit written)
#   2   bad invocation / missing dependency / invalid input
#   3   write error / extraction-output validation failure / initial-job-setup failure
#   5   extraction needed (Pass 1 complete; caller must run model + re-invoke
#       with EXTRACTION_OUTPUT_OVERRIDE set)
#   130 user quit (forwarded from voice-capture / typed-textarea)

set -u

diag() { printf 'section-d FAIL: %s\n' "$1" >&2; }
info() { printf 'section-d: %s\n' "$1" >&2; }

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
# section-d.sh ships into $CLAUDE_HOME/onboarding/ux/ at install (SHIP-TO-RUNTIME).
# For invocation under tests we resolve foundation-repo neighbors via $0's
# directory; production runtime resolves via $CLAUDE_HOME.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONBOARDING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- defaults ---
INPUTS_DIR="${INPUTS_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding}"
AUDIT_LOG="${AUDIT_LOG:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/audit/section-d.jsonl}"
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/transcripts}"
Q_FIELD_MAP="${Q_FIELD_MAP:-$ONBOARDING_DIR/q-field-map.json}"
EXTRACTION_PROMPT_TEMPLATE="${EXTRACTION_PROMPT_TEMPLATE:-$ONBOARDING_DIR/extraction-prompts/section-D.md}"
VOICE_CAPTURE_BIN="${VOICE_CAPTURE_BIN:-$ONBOARDING_DIR/voice-capture.sh}"
TYPED_TEXTAREA_BIN="${TYPED_TEXTAREA_BIN:-$ONBOARDING_DIR/fallback/typed-textarea.sh}"
INITIAL_JOB_SETUP_BIN="${INITIAL_JOB_SETUP_BIN:-$ONBOARDING_DIR/initial-job-setup.sh}"
PROMPT_CARD_PATH="${PROMPT_CARD_PATH:-}"
TYPED_ONLY=0
AUTO_CONFIRM=0
AUTO_OPT_OUT=0
OPT_OUT_HOOKS=0
OPT_OUT_CHECKPOINT=0
OPT_OUT_INITIAL_JOB=0
OPT_OUT_TRIPWIRES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --auto-confirm)         AUTO_CONFIRM=1; shift ;;
    --auto-opt-out)         AUTO_OPT_OUT=1; shift ;;
    --opt-out-hooks)        OPT_OUT_HOOKS=1; shift ;;
    --opt-out-checkpoint)   OPT_OUT_CHECKPOINT=1; shift ;;
    --opt-out-initial-job)  OPT_OUT_INITIAL_JOB=1; shift ;;
    --opt-out-tripwires)    OPT_OUT_TRIPWIRES=1; shift ;;
    --typed-only)           TYPED_ONLY=1; shift ;;
    --inputs-dir)           INPUTS_DIR="$2"; shift 2 ;;
    --audit-log)            AUDIT_LOG="$2"; shift 2 ;;
    --transcript-dir)       TRANSCRIPT_DIR="$2"; shift 2 ;;
    --prompt-card)          PROMPT_CARD_PATH="$2"; shift 2 ;;
    -h|--help)              sed -n '2,150p' "$0"; exit 0 ;;
    *)                      diag "unknown arg: $1"; exit 2 ;;
  esac
done

# Apply blanket --auto-opt-out: enables all four Section-D surfaces.
if [ "$AUTO_OPT_OUT" = "1" ]; then
  OPT_OUT_HOOKS=1
  OPT_OUT_CHECKPOINT=1
  OPT_OUT_INITIAL_JOB=1
  OPT_OUT_TRIPWIRES=1
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

# Section A's output is the discovery context for Section D's extraction.
DISCOVERY_CONTEXT="$INPUTS_DIR/extraction-output-A.json"
if [ ! -r "$DISCOVERY_CONTEXT" ]; then
  diag "Section A discovery context not found at $DISCOVERY_CONTEXT — run section-a.sh first"
  exit 2
fi

# --- run constants ---
SECTION_ID="D"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TRANSCRIPT_PATH="$TRANSCRIPT_DIR/section-d.txt"
COMPILED_PROMPT_PATH="$INPUTS_DIR/extraction-prompt-D.compiled.txt"
EXTRACTION_OUT="$INPUTS_DIR/extraction-output-D.json"

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
# Substitutes 4 placeholder blocks per extraction-prompts/section-D.md.
# Schema slice = q-field-map.json filtered to direct_qs.D-* (per L196 of
# section-D.md notes). Discovery context = full extraction-output-A.json.
render_compiled_prompt() {
  local schema_slice_tmp="$INPUTS_DIR/.schema-slice-D.tmp.$$"

  jq -c '{direct_qs: (.direct_qs | with_entries(select(.key | startswith("D-"))))}' \
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

  # Validate basic shape: section_id="D", populated is object.
  jq -e . "$extract_in" >/dev/null 2>&1 || { diag "extraction-output not valid JSON"; return 3; }
  local sid
  sid="$(jq -r '.section_id // empty' "$extract_in")"
  if [ "$sid" != "D" ]; then
    diag "extraction-output section_id='$sid' (expected 'D')"
    return 3
  fi
  jq -e '.populated | type == "object"' "$extract_in" >/dev/null 2>&1 \
    || { diag "extraction-output 'populated' must be object"; return 3; }

  # --- confidence gate categorization ---
  # Walk populated keys, look up confidence per key. Bucket into HIGH/MID/LOW.
  # LOW + required → record follow_up field-path in audit (no re-extraction
  # in T-5c; T-6 owns the user-facing loop).
  local gated_tmp="$INPUTS_DIR/.gated-D.tmp.$$"
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
  # required fields (from gate). For T-5c we capture both as field-path
  # identifiers; the actual surgical-text follow_up belongs to T-6.
  local followups_json
  followups_json="$(jq -c --slurpfile g "$gated_tmp" '
    ((.missing_required // []) + ($g[0].low // []))
    | unique
  ' "$extract_in")"

  rm -f "$gated_tmp"

  # --- opt-out routing (#7/#8/#9/#10) ---
  # Each surface deterministically overrides extraction.populated for its
  # domain. Records the surface-name in opt_outs[] for audit. Surfaces are
  # additive — they write distinct paths and never collide.
  local opt_outs_json="[]"
  local populated_tmp="$INPUTS_DIR/.populated-D.tmp.$$"
  jq -c '.populated' "$extract_in" > "$populated_tmp" || {
    diag "populated extraction failed"; rm -f "$populated_tmp"; return 3;
  }

  if [ "$OPT_OUT_HOOKS" = "1" ]; then
    # Surface #7 (hook enforcement): advisory-mode install for R-43 family
    # hooks. Records sentinel U.behavioral.hook_preferences.r43_advisory_mode
    # = true. Downstream hook-installer reads this flag and suppresses
    # block-on-violation behavior in favor of warn-and-continue.
    opt_outs_json="$(echo "$opt_outs_json" | jq -c '. + ["hook_advisory"]')"
    jq -c '."U.behavioral.hook_preferences.r43_advisory_mode" = true' \
        "$populated_tmp" > "$populated_tmp.s" \
      && mv "$populated_tmp.s" "$populated_tmp"
  fi
  if [ "$OPT_OUT_CHECKPOINT" = "1" ]; then
    # Surface #8 (R-26 threshold): set
    # U.behavioral.hook_preferences.checkpoint_disable_ok = true (the
    # CHECKPOINT_DISABLE_OK env-signal alternative per spec L187). The
    # checkpoint hook reads this flag and either disables or relaxes its
    # threshold; the alternate "raise to 55%" representation is a
    # downstream installer concern.
    opt_outs_json="$(echo "$opt_outs_json" | jq -c '. + ["checkpoint_relaxed"]')"
    jq -c '."U.behavioral.hook_preferences.checkpoint_disable_ok" = true' \
        "$populated_tmp" > "$populated_tmp.s" \
      && mv "$populated_tmp.s" "$populated_tmp"
  fi
  if [ "$OPT_OUT_INITIAL_JOB" = "1" ]; then
    # Surface #9 (initial-job-setup): force populated.O.jobs to the empty
    # array (per q-field-map.json D-2 fallback_value). Drops any
    # extraction-emitted O.jobs[0].id to keep mutual-exclusion clean.
    # The post-extraction initial-job-setup invocation skips when this
    # flag is set; bootstrap-schemas.sh L340-407 enforces the [] shape
    # at end-of-flow.
    opt_outs_json="$(echo "$opt_outs_json" | jq -c '. + ["initial_job_skipped"]')"
    jq -c 'with_entries(select(.key != "O.jobs[0].id"))
           | ."O.jobs" = []' \
        "$populated_tmp" > "$populated_tmp.s" \
      && mv "$populated_tmp.s" "$populated_tmp"
  fi
  if [ "$OPT_OUT_TRIPWIRES" = "1" ]; then
    # Surface #10 (observability tripwires): record sentinel
    # U.behavioral.hook_preferences.tripwires_skipped = true. SP05/SP06
    # cron trilayer install honors this flag by leaving the trilayer
    # uninstalled; user can re-enable later via /setup-job.
    opt_outs_json="$(echo "$opt_outs_json" | jq -c '. + ["tripwires_skipped"]')"
    jq -c '."U.behavioral.hook_preferences.tripwires_skipped" = true' \
        "$populated_tmp" > "$populated_tmp.s" \
      && mv "$populated_tmp.s" "$populated_tmp"
  fi

  # --- D-4 default application ---
  # If the extraction omitted U.behavioral.hook_preferences.notification_style,
  # write "digest" per q-field-map.json:direct_qs.D-4.targets[0].default_value
  # and section-D.md L121 contract ("absence is the signal"). The deterministic
  # default does NOT count as an opt-out; it's the engine completing a
  # required-field with the documented fallback.
  local has_notif
  has_notif="$(jq -r 'has("U.behavioral.hook_preferences.notification_style") | tostring' "$populated_tmp")"
  if [ "$has_notif" != "true" ]; then
    jq -c '."U.behavioral.hook_preferences.notification_style" = "digest"' \
        "$populated_tmp" > "$populated_tmp.s" \
      && mv "$populated_tmp.s" "$populated_tmp"
  fi

  # --- atomic write of extraction-output-D.json (per-section "merge") ---
  local final_tmp="$EXTRACTION_OUT.tmp.$$"
  jq -c \
    --argjson populated "$(cat "$populated_tmp")" \
    --argjson opt_outs "$opt_outs_json" \
    --arg run_id "$RUN_ID" \
    --arg ts "$RUN_TS" \
    '{
      section_id: "D",
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
    diag "extraction-output-D render failed"; rm -f "$final_tmp" "$populated_tmp"; return 3;
  }
  mv "$final_tmp" "$EXTRACTION_OUT" || {
    diag "extraction-output-D rename failed"; rm -f "$final_tmp" "$populated_tmp"; return 3;
  }
  rm -f "$populated_tmp"

  # --- initial-job-setup invocation (Section D only; SKILL.md §Initial- ---
  # Job-Setup Integration steps 1-8). Skipped when --opt-out-initial-job
  # was elected OR when the extraction emitted O.jobs:[] (model-side
  # opt-out). Renders staged plist via SP03 render-launchd.sh; never
  # calls launchctl bootstrap (SP08 enable-daemon owns activation).
  run_initial_job_setup || return 3

  # --- JSONL audit entry (9-key shape per SKILL.md L141) ---
  # follow_ups[] holds field-path identifiers (no user-typed strings) per
  # reference-leak floor. corrections[] is empty in T-5c (T-6 owns inline
  # edits). source_spans is a data field (spec L141) — copied verbatim.
  # manifest_paths reflects the final populated keys after opt-out + D-4
  # default application.
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

# --- initial-job-setup invocation (Section D — SKILL.md §Integration) ---
# Reads orchestration.jobs[0].id from the just-written extraction-output-D.json,
# resolves D-2 defaults_applied bundle (schedule.{hour,minute,dow}) per job_id,
# builds a transient orchestration.json wrapper at .orchestration-d-render.tmp,
# invokes initial-job-setup.sh with ORCHESTRATION_JSON pointing at it. Honors
# AUTO_CONFIRM=1 by forwarding to the callee. Skips invocation cleanly when:
#   - --opt-out-initial-job was elected (opt_outs[initial_job_skipped] recorded)
#   - extraction emitted O.jobs:[] (model-side opt-out)
#   - O.jobs[0].id is absent for any other reason
# Failure of initial-job-setup.sh leaves the user-derived fragment intact and
# returns 3 (caller can resume).
run_initial_job_setup() {
  if [ "$OPT_OUT_INITIAL_JOB" = "1" ]; then
    info "Skipping initial-job-setup invocation (opt-out #9 elected)"
    return 0
  fi

  local job_id
  job_id="$(jq -r '.populated."O.jobs[0].id" // empty' "$EXTRACTION_OUT")"
  if [ -z "$job_id" ]; then
    info "Skipping initial-job-setup invocation (extraction emitted no O.jobs[0].id; treating as model-side opt-out)"
    return 0
  fi

  case "$job_id" in
    librarian|architect)
      : # supported
      ;;
    *)
      diag "initial-job-setup: unsupported job id '$job_id' (expected librarian|architect)"
      return 3
      ;;
  esac

  if [ ! -x "$INITIAL_JOB_SETUP_BIN" ] && [ ! -r "$INITIAL_JOB_SETUP_BIN" ]; then
    diag "INITIAL_JOB_SETUP_BIN not executable: $INITIAL_JOB_SETUP_BIN"
    return 3
  fi

  # Resolve D-2 defaults_applied per job_id from q-field-map.json. The
  # shape we need for initial-job-setup.sh is just the schedule slice;
  # render-launchd.sh handles log_path / idle_watchdog / budget / model
  # / skip_weekends from its own template defaults.
  local sched_hour sched_minute sched_dow
  sched_hour="$(jq -r --arg j "$job_id" '.direct_qs."D-2".defaults_applied."O.jobs[0].schedule"[$j].hour // empty' "$Q_FIELD_MAP")"
  sched_minute="$(jq -r --arg j "$job_id" '.direct_qs."D-2".defaults_applied."O.jobs[0].schedule"[$j].minute // empty' "$Q_FIELD_MAP")"
  sched_dow="$(jq -c --arg j "$job_id" '.direct_qs."D-2".defaults_applied."O.jobs[0].schedule"[$j].dow // empty' "$Q_FIELD_MAP")"

  if [ -z "$sched_hour" ] || [ -z "$sched_minute" ]; then
    diag "initial-job-setup: q-field-map.json D-2 defaults missing schedule for job_id='$job_id'"
    return 3
  fi

  local orch_tmp="$INPUTS_DIR/.orchestration-d-render.tmp.$$"
  if [ -n "$sched_dow" ] && [ "$sched_dow" != "null" ]; then
    jq -nc --arg j "$job_id" --argjson h "$sched_hour" --argjson m "$sched_minute" --argjson d "$sched_dow" \
      '{jobs: [{id: $j, schedule: {hour: $h, minute: $m, dow: $d}}]}' > "$orch_tmp" || {
      diag "initial-job-setup: orchestration wrapper render failed"
      rm -f "$orch_tmp"; return 3;
    }
  else
    jq -nc --arg j "$job_id" --argjson h "$sched_hour" --argjson m "$sched_minute" \
      '{jobs: [{id: $j, schedule: {hour: $h, minute: $m}}]}' > "$orch_tmp" || {
      diag "initial-job-setup: orchestration wrapper render failed"
      rm -f "$orch_tmp"; return 3;
    }
  fi

  info "Invoking initial-job-setup for job '$job_id'"
  ORCHESTRATION_JSON="$orch_tmp" \
  AUTO_CONFIRM="$AUTO_CONFIRM" \
    "$INITIAL_JOB_SETUP_BIN"
  local ijs_rc=$?
  rm -f "$orch_tmp"

  if [ "$ijs_rc" -ne 0 ]; then
    diag "initial-job-setup returned rc=$ijs_rc"
    return 3
  fi
  return 0
}

# --- main flow ---

# Pass 1 step 2: transcript (idempotent — skips if already present).
capture_transcript
case "$?" in
  0)   : ;;
  130) info "section-d aborted at user request. Re-run /onboard --resume to continue."; exit 130 ;;
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
  info "then re-invoke section-d.sh with EXTRACTION_OUTPUT_OVERRIDE=<path-to-output.json>."
  exit 5
fi

# Pass 2: process extraction → confidence gate → opt-outs → D-4 default →
# fragment + initial-job-setup + audit.
process_extraction "$EXTRACTION_IN" || exit 3

# Pass 2 complete: section fragment + audit committed. The next step is the
# inline-edit summary screen (render-summary.sh), which consumes
# extraction-output-D.json + audit follow_ups[] to render per-field disposition.
# onboard.sh runs render-summary automatically; LLM-driven /onboard or harness
# scripts read the HANDOFF emit below to know what to invoke next.
info "Section D fragment committed at $EXTRACTION_OUT"
info "JSONL audit entry appended at $AUDIT_LOG"
info "# HANDOFF: render-summary --section D"
exit 0
