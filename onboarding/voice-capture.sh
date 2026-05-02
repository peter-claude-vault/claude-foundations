#!/bin/bash
# onboarding/voice-capture.sh — SP07 T-3 /voice capture wrapper.
#
# Per-section transcript capture wrapper. Renders the prompt card, probes the
# harness for /voice availability, and produces a transcript file at a
# deterministic per-section path. Returns the transcript path on stdout for
# downstream pipeline (extraction prompts, confidence gates, summary screen).
#
# Wrapping role boundary (per SKILL.md L54-56 + audit F-07):
#   /voice is a Claude Code harness slash-command, NOT a binary on PATH. A
#   shell subprocess CANNOT invoke it directly — `which /voice` always fails
#   (the leading slash makes `which` reject it; harness slash-commands are not
#   on PATH). The audit synthesis (synthesis-final.md F-07) explicitly says
#   the canonical probe "needs research" and there is no documented harness
#   API surface for slash-command discoverability from a subprocess.
#
#   Pragmatic contract: this wrapper does NOT itself invoke /voice. It is the
#   structural seam between the calling agent (Claude inside the harness, who
#   CAN invoke /voice) and the per-section pipeline (sections B/C/D in T-5,
#   summary + extraction in T-6+). The wrapper:
#
#     1. Renders the per-section prompt card to stderr (user-visible)
#     2. Probes /voice availability via env signal (CLAUDE_VOICE_AVAILABLE
#        set by harness when /voice is in scope; VOICE_PROBE_OVERRIDE for
#        tests + user --typed-only flag)
#     3. On available + not --typed-fallback: prints a "speak now" notice +
#        reads the transcript text from stdin (the calling agent pipes the
#        /voice output to this script's stdin after invoking /voice itself)
#     4. On unavailable OR --typed-fallback: prints a one-time "voice
#        unavailable" notice (advisory; routing decision returned via exit
#        code so the caller can dispatch to T-4 typed-textarea) + reads
#        typed transcript from stdin
#     5. Writes transcript text to $TRANSCRIPT_DIR/section-{id}.txt
#     6. Returns transcript path on stdout (last line)
#
#   Uniform stdin → transcript: regardless of voice/typed origin, the
#   transcript text arrives via stdin. This unifies the input mechanism
#   and keeps the wrapper deterministically testable.
#
# Section gate (per spec.md 5-Section UX Flow + tasks.md T-3):
#   Sections A and E are no-recording sections. voice-capture.sh REJECTS
#   SECTION_ID=a/e at arg-parse time with exit 2 + diagnostic. Recording
#   sections: B, C, D.
#
# Retention hook (AC #4, deferral note):
#   The deletion *function* (delete-transcript) is shipped here. The
#   deletion *trigger* — fires after Section E retention checkbox read +
#   post-extraction confirmation in T-6 — is downstream. Until T-7 ships
#   the Section E checkbox + T-6 ships the post-extraction confirmation
#   gate, retention default is OFF and the function is callable but unwired.
#   Callers (T-5/T-6) invoke `voice-capture.sh delete-transcript <path>`
#   to fire the deletion. Audio-path deletion is a no-op until the harness
#   exposes the audio-file path (currently /voice returns transcript text
#   only; audio-path retention is a v2.1+ concern).
#
# Hard invariants:
#   - Bash 3.2 + R-23 compatible (no declare -A, no mapfile, no ${var,,};
#     use tr '[:upper:]' '[:lower:]' for case folding)
#   - Single-deliverable per R-37
#   - Reference-leak floor: NO user-provided strings in diagnostic fields
#     (transcript text is structural data; never logged in stderr/audit)
#   - Hermetic-test override pattern matches section-a.sh S74:
#     VOICE_PROBE_OVERRIDE / TRANSCRIPT_DIR / STDIN_TRANSCRIPT_OVERRIDE
#   - No mkdir/write outside $TRANSCRIPT_DIR + its parent
#
# Env knobs:
#   TRANSCRIPT_DIR              Output dir
#                               (default: $CLAUDE_HOME/onboarding/transcripts)
#   VOICE_PROBE_OVERRIDE        "available" | "unavailable" — forces probe
#                               result (tests + user --typed-only routing)
#   CLAUDE_VOICE_AVAILABLE      "1" — harness sets when /voice is in scope.
#                               Unset/0 → unavailable. Default-deny stance
#                               per F-07 (shell subprocess can't introspect
#                               harness state without explicit signal)
#   STDIN_TRANSCRIPT_OVERRIDE   Test-only: bypass stdin read; use this value
#                               as the transcript text. Hermetic isolation.
#   VOICE_NOTICE_SEEN           Internal: when "1", suppresses the one-time
#                               fallback notice (caller manages across
#                               multi-section invocations)
#
# Args (positional + flags):
#   $1 SECTION_ID               One of {b,c,d} (case-insensitive). Sections
#                               a/e reject with exit 2.
#   $2 PROMPT_CARD_PATH         File containing prompt-card text to render.
#                               Required. Read-only. Caller is responsible
#                               for anchor-extracting from onboarder-design.md
#                               §4-§6 (B/C/D) before invocation.
#   --typed-fallback            Force typed path; skip /voice probe
#   --auto-confirm              Non-interactive; skip "press Enter to start"
#                               prompts (tests + dogfood)
#
# Subcommand:
#   delete-transcript <path>    Deletes the transcript file at <path>.
#                               Idempotent (no-op if missing). Exit 0 on
#                               success or already-absent. Used by T-5/T-6
#                               post-extraction-confirmation trigger.
#
# Stdout contract:
#   Last line on success = absolute path to written transcript file.
#   Caller MUST `tail -1` to extract the path (other stdout lines are user-
#   facing notices and are NOT part of the contract).
#
# Exit codes:
#   0   transcript captured + written (or delete-transcript success)
#   2   bad invocation / missing dependency / invalid section
#   3   write error
#   4   /voice unavailable + --typed-fallback NOT specified AND no stdin
#       supplied (caller must dispatch to T-4 typed-textarea)
#   130 user quit (q/Q at confirm prompt)

set -u

diag() { printf 'voice-capture FAIL: %s\n' "$1" >&2; }
info() { printf 'voice-capture: %s\n' "$1" >&2; }

# --- source paths.sh if present (post-install runtime); fall back to env ---
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi

# --- subcommand dispatch ---
if [ "${1:-}" = "delete-transcript" ]; then
  shift
  TARGET="${1:-}"
  if [ -z "$TARGET" ]; then
    diag "delete-transcript: missing path argument"
    exit 2
  fi
  if [ -f "$TARGET" ]; then
    rm -f "$TARGET" || { diag "delete-transcript: rm failed for $TARGET"; exit 3; }
  fi
  exit 0
fi

# --- defaults ---
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-${CLAUDE_HOME:-$HOME/.claude}/onboarding/transcripts}"
TYPED_FALLBACK=0
AUTO_CONFIRM=0
SECTION_ID=""
PROMPT_CARD_PATH=""

# --- arg parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --typed-fallback) TYPED_FALLBACK=1; shift ;;
    --auto-confirm)   AUTO_CONFIRM=1; shift ;;
    -h|--help)        sed -n '2,90p' "$0"; exit 0 ;;
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
    diag "section $SECTION_ID is no-recording (a=discovery review, e=checkbox); voice-capture not applicable"
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

# --- output path ---
TRANSCRIPT_PATH="$TRANSCRIPT_DIR/section-${SECTION_ID}.txt"
mkdir -p "$TRANSCRIPT_DIR" 2>/dev/null || { diag "cannot create $TRANSCRIPT_DIR"; exit 3; }

# --- render prompt card ---
info "rendering prompt card for section $SECTION_ID"
printf '\n' >&2
cat "$PROMPT_CARD_PATH" >&2
printf '\n' >&2

# --- probe /voice availability ---
# Default-deny stance per F-07: shell subprocesses cannot reliably introspect
# harness slash-command availability. Probe resolves via:
#   1. VOICE_PROBE_OVERRIDE (test/user-flag override; "available"|"unavailable")
#   2. CLAUDE_VOICE_AVAILABLE env var (harness sets to "1" when /voice is in scope)
#   3. Default unavailable
probe_voice() {
  if [ -n "${VOICE_PROBE_OVERRIDE:-}" ]; then
    case "$VOICE_PROBE_OVERRIDE" in
      available)   return 0 ;;
      unavailable) return 1 ;;
      *)           diag "VOICE_PROBE_OVERRIDE invalid: $VOICE_PROBE_OVERRIDE"; return 1 ;;
    esac
  fi
  if [ "${CLAUDE_VOICE_AVAILABLE:-0}" = "1" ]; then
    return 0
  fi
  return 1
}

VOICE_MODE="voice"
if [ "$TYPED_FALLBACK" -eq 1 ]; then
  VOICE_MODE="typed"
elif ! probe_voice; then
  VOICE_MODE="typed"
  if [ "${VOICE_NOTICE_SEEN:-0}" != "1" ]; then
    info "/voice unavailable on this host — falling back to typed input. Type your response below; press Ctrl-D when done."
  fi
fi

# --- capture transcript ---
case "$VOICE_MODE" in
  voice)
    info "/voice ready — speak when prompted (recording stops when you stop). Transcript will be piped on stdin by the harness."
    ;;
  typed)
    info "Typed input mode — enter transcript text below. Ctrl-D to finish."
    ;;
esac

# Hermetic test override: bypass stdin, use env var as transcript text.
TRANSCRIPT_TEXT=""
if [ -n "${STDIN_TRANSCRIPT_OVERRIDE:-}" ]; then
  TRANSCRIPT_TEXT="$STDIN_TRANSCRIPT_OVERRIDE"
else
  # Read stdin until EOF. If stdin is a TTY (no piped input) AND we are in
  # voice mode without a fallback, signal exit 4 so caller can dispatch to
  # T-4 typed-textarea (interactive editor flow). In typed mode at a TTY,
  # we still read stdin until Ctrl-D — caller may attach a here-doc or
  # pipe explicitly.
  if [ -t 0 ] && [ "$VOICE_MODE" = "voice" ]; then
    diag "/voice mode requires stdin transcript pipe from harness; no input received. Caller should dispatch to T-4 typed-textarea or set --typed-fallback."
    exit 4
  fi
  TRANSCRIPT_TEXT="$(cat)"
fi

# --- write transcript ---
TMP_PATH="${TRANSCRIPT_PATH}.tmp.$$"
printf '%s' "$TRANSCRIPT_TEXT" > "$TMP_PATH" || { diag "tmp write failed"; rm -f "$TMP_PATH"; exit 3; }
mv -f "$TMP_PATH" "$TRANSCRIPT_PATH" || { diag "rename failed"; rm -f "$TMP_PATH"; exit 3; }

# --- emit transcript path on stdout (last line is the contract) ---
printf '%s\n' "$TRANSCRIPT_PATH"
exit 0
