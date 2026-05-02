#!/bin/bash
# onboarding/fallback/typed-textarea.sh — SP07 T-4 typed-textarea fallback.
#
# Per-section typed-input wrapper. Renders the prompt card and produces a
# transcript file at the SAME deterministic per-section path as
# voice-capture.sh. Returns the transcript path on stdout for the downstream
# pipeline (extraction prompts, confidence gates, summary screen).
#
# Role — complement to voice-capture.sh. Invoked when:
#   1. /voice probe returns unavailable (voice-capture.sh exit 4 routes here)
#   2. User invokes onboarder with --typed-only install-time flag
#   3. User toggles to typed mid-flow (per-section runner kills voice path,
#      dispatches here with the same SECTION_ID + PROMPT_CARD_PATH; atomic
#      tmp+rename in this script overwrites the prior voice transcript
#      cleanly — same path, same downstream pipeline)
#
# "One UX, two input modes" (spec.md L184 / L220): same prompt card, same
# transcript path, same downstream pipeline. The only difference is the
# input mechanism. This is the typed half of the pair to T-3's voice half.
#
# Input modes (priority order):
#   1. STDIN_TRANSCRIPT_OVERRIDE env var → bypass all input UI; use the env
#      value as the transcript text (hermetic-test isolation; mirrors
#      voice-capture.sh L243-244)
#   2. --editor flag → invoke $EDITOR on a tmp file, read saved blob.
#      Requires $EDITOR to be set; missing $EDITOR with --editor → exit 2.
#   3. stdin not a TTY (piped or redirected) → cat stdin until EOF
#   4. stdin IS a TTY + no --editor → cat stdin until Ctrl-D (interactive
#      multi-line; user-visible notice prompts before reading)
#
# Section gate (mirror T-3 voice-capture.sh L41-43):
#   Sections A and E are no-recording sections. typed-textarea.sh REJECTS
#   SECTION_ID=a/e at arg-parse time with exit 2 + diagnostic. Recording
#   sections: B, C, D.
#
# Hard invariants (mirror voice-capture.sh):
#   - Bash 3.2 + R-23 compatible (no declare -A, no mapfile, no ${var,,};
#     use tr '[:upper:]' '[:lower:]' for case folding)
#   - Single-deliverable per R-37
#   - Reference-leak floor: NO user-provided strings in diagnostic fields
#     (transcript text is structural data; never logged in stderr/audit)
#   - Hermetic-test override: TRANSCRIPT_DIR + STDIN_TRANSCRIPT_OVERRIDE
#   - No mkdir/write outside $TRANSCRIPT_DIR + its parent (and the editor
#     tmp file under $TMPDIR when --editor)
#
# Env knobs:
#   TRANSCRIPT_DIR              Output dir
#                               (default: $CLAUDE_HOME/onboarding/transcripts)
#   STDIN_TRANSCRIPT_OVERRIDE   Test-only: bypass input UI; use this value
#                               as the transcript text. Hermetic isolation.
#   EDITOR                      Used when --editor flag set. Required if
#                               --editor + no override (else exit 2).
#
# Args (positional + flags):
#   $1 SECTION_ID               One of {b,c,d} (case-insensitive). Sections
#                               a/e reject with exit 2.
#   $2 PROMPT_CARD_PATH         File containing prompt-card text to render.
#                               Required. Read-only. Caller is responsible
#                               for anchor-extracting from onboarder-design.md
#                               §4-§6 (B/C/D) before invocation.
#   --editor                    Open $EDITOR on a tmp file for multi-line
#                               composition. Saved blob becomes the
#                               transcript.
#   --auto-confirm              Reserved for parity with voice-capture; no
#                               interactive confirm step in this script.
#
# Stdout contract:
#   Last line on success = absolute path to written transcript file.
#   Caller MUST `tail -1` to extract the path (other stdout lines are user-
#   facing notices and are NOT part of the contract).
#
# Exit codes:
#   0   transcript captured + written
#   2   bad invocation / missing dependency / invalid section / --editor
#       without $EDITOR
#   3   write error / editor exited non-zero

set -u

diag() { printf 'typed-textarea FAIL: %s\n' "$1" >&2; }
info() { printf 'typed-textarea: %s\n' "$1" >&2; }

# --- source paths.sh if present (post-install runtime); fall back to env ---
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi

# --- defaults ---
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/transcripts}"
USE_EDITOR=0
AUTO_CONFIRM=0
SECTION_ID=""
PROMPT_CARD_PATH=""

# --- arg parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --editor)         USE_EDITOR=1; shift ;;
    --auto-confirm)   AUTO_CONFIRM=1; shift ;;
    -h|--help)        sed -n '2,80p' "$0"; exit 0 ;;
    -*)               diag "unknown flag: $1"; exit 2 ;;
    *)
      if [ -z "$SECTION_ID" ]; then
        SECTION_ID="$1"
      elif [ -z "$PROMPT_CARD_PATH" ]; then
        PROMPT_CARD_PATH="$1"
      else
        diag "unexpected positional arg: $1"
        exit 2
      fi
      shift ;;
  esac
done

# --- validate SECTION_ID ---
if [ -z "$SECTION_ID" ]; then
  diag "SECTION_ID required (one of b/c/d)"
  exit 2
fi
SECTION_ID="$(printf '%s' "$SECTION_ID" | tr '[:upper:]' '[:lower:]')"
case "$SECTION_ID" in
  a|e)
    diag "section $SECTION_ID is no-recording (a=discovery review, e=checkbox); typed-textarea not applicable"
    exit 2 ;;
  b|c|d)
    : ;;
  *)
    diag "invalid SECTION_ID: $SECTION_ID (expected b/c/d)"
    exit 2 ;;
esac

# --- validate PROMPT_CARD_PATH ---
if [ -z "$PROMPT_CARD_PATH" ]; then
  diag "PROMPT_CARD_PATH required (path to file containing prompt-card text)"
  exit 2
fi
if [ ! -r "$PROMPT_CARD_PATH" ]; then
  diag "PROMPT_CARD_PATH not readable: $PROMPT_CARD_PATH"
  exit 2
fi

# --- validate --editor preconditions ---
if [ "$USE_EDITOR" -eq 1 ] && [ -z "${STDIN_TRANSCRIPT_OVERRIDE:-}" ]; then
  if [ -z "${EDITOR:-}" ]; then
    diag "--editor flag set but \$EDITOR is unset"
    exit 2
  fi
fi

# --- output path ---
TRANSCRIPT_PATH="$TRANSCRIPT_DIR/section-${SECTION_ID}.txt"
mkdir -p "$TRANSCRIPT_DIR" 2>/dev/null || { diag "cannot create $TRANSCRIPT_DIR"; exit 3; }

# --- render prompt card ---
info "rendering prompt card for section $SECTION_ID"
printf '\n' >&2
cat "$PROMPT_CARD_PATH" >&2
printf '\n' >&2

# --- capture transcript ---
TRANSCRIPT_TEXT=""
if [ -n "${STDIN_TRANSCRIPT_OVERRIDE:-}" ]; then
  # Hermetic-test path — bypass input UI entirely.
  TRANSCRIPT_TEXT="$STDIN_TRANSCRIPT_OVERRIDE"
elif [ "$USE_EDITOR" -eq 1 ]; then
  # Editor mode — open $EDITOR on a tmp file; saved blob is the transcript.
  EDITOR_TMP="$(mktemp -t typed-textarea-XXXXXX)" || { diag "mktemp failed"; exit 3; }
  # Pre-seed the tmp file with a comment header explaining the contract.
  # Lines starting with '#' at column 0 are stripped before write — gives the
  # user a hint without polluting the transcript.
  {
    printf '# Type your response below. Lines starting with "#" are ignored.\n'
    printf '# Save and quit your editor when done.\n\n'
  } > "$EDITOR_TMP"
  info "opening \$EDITOR ($EDITOR) for multi-line input — save+quit when done"
  # shellcheck disable=SC2086
  $EDITOR "$EDITOR_TMP"
  EDITOR_RC=$?
  if [ "$EDITOR_RC" -ne 0 ]; then
    rm -f "$EDITOR_TMP"
    diag "\$EDITOR exited with rc=$EDITOR_RC"
    exit 3
  fi
  # Strip comment lines.
  TRANSCRIPT_TEXT="$(grep -v '^#' "$EDITOR_TMP")"
  rm -f "$EDITOR_TMP"
else
  # stdin mode (TTY: interactive Ctrl-D; pipe: read until EOF).
  if [ -t 0 ]; then
    info "Typed input mode — enter multi-line response below. Press Ctrl-D when done."
  else
    info "Typed input mode — reading transcript from stdin until EOF."
  fi
  TRANSCRIPT_TEXT="$(cat)"
fi

# --- write transcript (atomic tmp+rename; overwrites prior voice transcript
# cleanly when invoked mid-flow per AC #5) ---
TMP_PATH="${TRANSCRIPT_PATH}.tmp.$$"
printf '%s' "$TRANSCRIPT_TEXT" > "$TMP_PATH" || { diag "tmp write failed"; rm -f "$TMP_PATH"; exit 3; }
mv -f "$TMP_PATH" "$TRANSCRIPT_PATH" || { diag "rename failed"; rm -f "$TMP_PATH"; exit 3; }

# --- emit transcript path on stdout (last line is the contract) ---
printf '%s\n' "$TRANSCRIPT_PATH"
exit 0
