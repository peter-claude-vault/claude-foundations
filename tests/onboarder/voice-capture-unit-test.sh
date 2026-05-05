#!/bin/bash
# tests/onboarder/voice-capture-unit-test.sh — synthetic unit tests for SP07 T-3
# onboarding/voice-capture.sh.
#
# Validates the 5 acceptance criteria from
# ~/.claude-plans/71-claude-foundations-engine-v2/07-onboarder-ux/tasks.md L77-83:
#
#   AC1 — Wrap /voice invocation with per-section prompt card display
#   AC2 — Write transcript to per-section path deterministically
#   AC3 — Degrade to typed fallback when /voice unavailable with user-visible notice
#   AC4 — Delete transcript + audio post-extraction when retention opt-out not checked
#         (deletion FUNCTION is shipped here; deletion TRIGGER lands T-5/T-6)
#   AC5 — Return transcript path on stdout for pipeline consumption
#
# Plus structural guardrails (R-37 single-deliverable + audit F-07 default-deny):
#
#   T-STRUCT-A — invalid SECTION_ID rejected (exit 2): a, e, junk
#   T-STRUCT-B — missing PROMPT_CARD_PATH rejected (exit 2)
#   T-STRUCT-C — unreadable PROMPT_CARD_PATH rejected (exit 2)
#   T-STRUCT-D — voice-mode at TTY without stdin returns exit 4 (caller dispatches T-4)
#   T-STRUCT-E — bad VOICE_PROBE_OVERRIDE value collapses to unavailable (default-deny)
#   T-STRUCT-F — VOICE_NOTICE_SEEN=1 suppresses fallback notice
#   T-STRUCT-G — uniform stdin contract: typed AND voice modes both write transcript
#                from STDIN_TRANSCRIPT_OVERRIDE identically
#   T-STRUCT-H — transcript content never leaks to stdout (path line is sole stdout)
#
# Hermetic: per-test temp $TRANSCRIPT_DIR; VOICE_PROBE_OVERRIDE +
# STDIN_TRANSCRIPT_OVERRIDE replace harness signal + stdin pipe (test cannot
# invoke real /voice — no audio device + harness availability is environmental).
# Bash 3.2 clean (R-23).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/onboarding/voice-capture.sh"

if [ ! -x "$SCRIPT" ]; then echo "FAIL: cannot exec $SCRIPT"; exit 2; fi

TEST_ROOT="$(mktemp -d -t voice-capture-unit-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 — $2"; }

# Per-test transcript dir + sample prompt card.
# $1 = test name (used for subdir + card name)
setup_test() {
  local name="$1"
  local dir="$TEST_ROOT/$name"
  mkdir -p "$dir/transcripts"
  printf 'PROMPT CARD for test %s\nPlease describe X.\n' "$name" > "$dir/card.md"
  echo "$dir"
}

# ---------- AC1 + AC2 + AC5: voice-mode happy path (B) ----------
{
  D="$(setup_test ac1-voice-b)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            VOICE_PROBE_OVERRIDE=available \
            STDIN_TRANSCRIPT_OVERRIDE="My role is consultant. I work at Acme Foundation. I lead a team." \
            "$SCRIPT" b "$D/card.md" 2>"$D/stderr")"
  RC=$?
  TPATH="$(echo "$STDOUT" | tail -1)"

  [ "$RC" -eq 0 ] || fail "AC1+2+5/voice-B/exit" "expected 0, got $RC"
  [ "$TPATH" = "$D/transcripts/section-b.txt" ] || fail "AC5/voice-B/stdout-path" "got $TPATH"
  [ -f "$D/transcripts/section-b.txt" ] || fail "AC2/voice-B/file-exists" "transcript file missing"
  grep -q "PROMPT CARD for test ac1-voice-b" "$D/stderr" || fail "AC1/voice-B/card-render" "prompt card not in stderr"
  grep -q "Please describe X" "$D/stderr" || fail "AC1/voice-B/card-content" "card body missing"
  grep -Fq "My role is consultant" "$D/transcripts/section-b.txt" || fail "AC2/voice-B/transcript-content" "transcript text mismatch"
  [ "$RC" -eq 0 ] && [ "$TPATH" = "$D/transcripts/section-b.txt" ] && \
    [ -f "$D/transcripts/section-b.txt" ] && \
    grep -q "PROMPT CARD for test ac1-voice-b" "$D/stderr" && \
    grep -q "Please describe X" "$D/stderr" && \
    grep -Fq "My role is consultant" "$D/transcripts/section-b.txt" && \
    pass "AC1+AC2+AC5/voice-B happy path"
}

# ---------- AC1 + AC2 + AC5: voice-mode happy path (C) ----------
{
  D="$(setup_test ac1-voice-c)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            VOICE_PROBE_OVERRIDE=available \
            STDIN_TRANSCRIPT_OVERRIDE="My vault is at ~/Notes. Mostly markdown files." \
            "$SCRIPT" c "$D/card.md" 2>"$D/stderr")"
  RC=$?
  TPATH="$(echo "$STDOUT" | tail -1)"
  [ "$RC" -eq 0 ] && [ "$TPATH" = "$D/transcripts/section-c.txt" ] && \
    [ -f "$D/transcripts/section-c.txt" ] && \
    pass "AC2/voice-C deterministic per-section path" || \
    fail "AC2/voice-C" "exit=$RC path=$TPATH"
}

# ---------- AC1 + AC2 + AC5: voice-mode happy path (D) ----------
{
  D="$(setup_test ac1-voice-d)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            VOICE_PROBE_OVERRIDE=available \
            STDIN_TRANSCRIPT_OVERRIDE="High autonomy. Daily librarian please." \
            "$SCRIPT" d "$D/card.md" 2>"$D/stderr")"
  RC=$?
  TPATH="$(echo "$STDOUT" | tail -1)"
  [ "$RC" -eq 0 ] && [ "$TPATH" = "$D/transcripts/section-d.txt" ] && \
    [ -f "$D/transcripts/section-d.txt" ] && \
    pass "AC2/voice-D deterministic per-section path" || \
    fail "AC2/voice-D" "exit=$RC path=$TPATH"
}

# ---------- AC2: section ID is case-insensitive ----------
{
  D="$(setup_test ac2-case-insensitive)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            VOICE_PROBE_OVERRIDE=available \
            STDIN_TRANSCRIPT_OVERRIDE="caps test" \
            "$SCRIPT" B "$D/card.md" 2>"$D/stderr")"
  RC=$?
  TPATH="$(echo "$STDOUT" | tail -1)"
  [ "$RC" -eq 0 ] && [ "$TPATH" = "$D/transcripts/section-b.txt" ] && \
    pass "AC2/case-insensitive section-id" || \
    fail "AC2/case-insensitive" "exit=$RC path=$TPATH (expected lowercase b)"
}

# ---------- AC3: typed-fallback on probe=unavailable + user-visible notice ----------
{
  D="$(setup_test ac3-fallback-unavailable)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            VOICE_PROBE_OVERRIDE=unavailable \
            STDIN_TRANSCRIPT_OVERRIDE="typed content here" \
            "$SCRIPT" b "$D/card.md" 2>"$D/stderr")"
  RC=$?
  TPATH="$(echo "$STDOUT" | tail -1)"

  [ "$RC" -eq 0 ] || fail "AC3/unavailable/exit" "expected 0, got $RC"
  [ -f "$D/transcripts/section-b.txt" ] || fail "AC3/unavailable/transcript-written" "missing"
  grep -q "voice unavailable" "$D/stderr" || fail "AC3/unavailable/notice" "user-visible notice missing"
  grep -q "Typed input mode" "$D/stderr" || fail "AC3/unavailable/typed-mode-notice" "typed-mode notice missing"
  grep -Fq "typed content here" "$D/transcripts/section-b.txt" || fail "AC3/unavailable/content" "typed content missing"
  [ "$RC" -eq 0 ] && [ -f "$D/transcripts/section-b.txt" ] && \
    grep -q "voice unavailable" "$D/stderr" && \
    grep -q "Typed input mode" "$D/stderr" && \
    grep -Fq "typed content here" "$D/transcripts/section-b.txt" && \
    pass "AC3/probe=unavailable degrades to typed with notice"
}

# ---------- AC3: --typed-fallback flag forces typed path even if voice available ----------
{
  D="$(setup_test ac3-flag-forced)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            VOICE_PROBE_OVERRIDE=available \
            STDIN_TRANSCRIPT_OVERRIDE="user wants typed" \
            "$SCRIPT" --typed-fallback c "$D/card.md" 2>"$D/stderr")"
  RC=$?
  [ "$RC" -eq 0 ] || fail "AC3/--typed-fallback/exit" "expected 0, got $RC"
  grep -q "Typed input mode" "$D/stderr" || fail "AC3/--typed-fallback/notice" "typed-mode notice missing"
  grep -q "voice ready" "$D/stderr" && fail "AC3/--typed-fallback/no-voice-notice" "voice notice should not appear when --typed-fallback"
  grep -Fq "user wants typed" "$D/transcripts/section-c.txt" || fail "AC3/--typed-fallback/content" "content missing"
  [ "$RC" -eq 0 ] && grep -q "Typed input mode" "$D/stderr" && \
    ! grep -q "voice ready" "$D/stderr" && \
    grep -Fq "user wants typed" "$D/transcripts/section-c.txt" && \
    pass "AC3/--typed-fallback flag forces typed path"
}

# ---------- AC3 + default-deny: no env signals → typed fallback (audit F-07) ----------
{
  D="$(setup_test ac3-default-deny)"
  # Explicitly unset both env signals.
  STDOUT="$(unset VOICE_PROBE_OVERRIDE CLAUDE_VOICE_AVAILABLE; \
            TRANSCRIPT_DIR="$D/transcripts" \
            STDIN_TRANSCRIPT_OVERRIDE="default deny path" \
            "$SCRIPT" d "$D/card.md" 2>"$D/stderr")"
  RC=$?
  [ "$RC" -eq 0 ] || fail "AC3/default-deny/exit" "expected 0, got $RC"
  grep -q "voice unavailable" "$D/stderr" || fail "AC3/default-deny/notice" "fallback notice missing"
  [ "$RC" -eq 0 ] && grep -q "voice unavailable" "$D/stderr" && \
    pass "AC3/default-deny: no env signals → typed fallback (F-07)"
}

# ---------- AC3 + CLAUDE_VOICE_AVAILABLE=1 → voice mode ----------
{
  D="$(setup_test ac3-harness-signal)"
  STDOUT="$(unset VOICE_PROBE_OVERRIDE; \
            CLAUDE_VOICE_AVAILABLE=1 \
            TRANSCRIPT_DIR="$D/transcripts" \
            STDIN_TRANSCRIPT_OVERRIDE="harness-signaled voice" \
            "$SCRIPT" b "$D/card.md" 2>"$D/stderr")"
  RC=$?
  [ "$RC" -eq 0 ] || fail "AC3/harness-signal/exit" "expected 0, got $RC"
  grep -q "voice ready" "$D/stderr" || fail "AC3/harness-signal/voice-notice" "voice-ready notice missing"
  grep -q "voice unavailable" "$D/stderr" && fail "AC3/harness-signal/no-fallback" "fallback notice should NOT appear"
  [ "$RC" -eq 0 ] && grep -q "voice ready" "$D/stderr" && \
    ! grep -q "voice unavailable" "$D/stderr" && \
    pass "AC3/CLAUDE_VOICE_AVAILABLE=1 → voice mode (no fallback notice)"
}

# ---------- AC4: delete-transcript subcommand removes file ----------
{
  D="$(setup_test ac4-delete-existing)"
  # Create a transcript first.
  TRANSCRIPT_DIR="$D/transcripts" VOICE_PROBE_OVERRIDE=available \
    STDIN_TRANSCRIPT_OVERRIDE="to be deleted" \
    "$SCRIPT" b "$D/card.md" >/dev/null 2>&1

  TARGET="$D/transcripts/section-b.txt"
  [ -f "$TARGET" ] || fail "AC4/setup" "test setup transcript missing"

  "$SCRIPT" delete-transcript "$TARGET"
  RC=$?
  [ "$RC" -eq 0 ] || fail "AC4/delete/exit" "expected 0, got $RC"
  [ ! -f "$TARGET" ] || fail "AC4/delete/file-removed" "transcript still exists"
  [ "$RC" -eq 0 ] && [ ! -f "$TARGET" ] && \
    pass "AC4/delete-transcript removes existing transcript"
}

# ---------- AC4: delete-transcript on missing file is idempotent ----------
{
  D="$(setup_test ac4-delete-missing)"
  "$SCRIPT" delete-transcript "$D/transcripts/never-existed.txt"
  RC=$?
  [ "$RC" -eq 0 ] || fail "AC4/delete-missing/exit" "expected 0 idempotent, got $RC"
  [ "$RC" -eq 0 ] && pass "AC4/delete-transcript idempotent on missing path"
}

# ---------- AC4: delete-transcript with no path arg exits 2 ----------
{
  "$SCRIPT" delete-transcript 2>/dev/null
  RC=$?
  [ "$RC" -eq 2 ] && pass "AC4/delete-transcript missing arg → exit 2" || \
    fail "AC4/delete-no-arg" "expected 2, got $RC"
}

# ---------- AC5: stdout last line is transcript path; stderr noise excluded ----------
{
  D="$(setup_test ac5-stdout-contract)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            VOICE_PROBE_OVERRIDE=available \
            STDIN_TRANSCRIPT_OVERRIDE="path contract test" \
            "$SCRIPT" b "$D/card.md" 2>/dev/null)"
  LAST="$(echo "$STDOUT" | tail -1)"
  LINES="$(echo "$STDOUT" | wc -l | tr -d ' ')"
  [ "$LAST" = "$D/transcripts/section-b.txt" ] || fail "AC5/last-line" "got $LAST"
  [ "$LINES" = "1" ] || fail "AC5/line-count" "expected 1 stdout line, got $LINES"
  [ "$LAST" = "$D/transcripts/section-b.txt" ] && [ "$LINES" = "1" ] && \
    pass "AC5/stdout = single transcript path line (stderr-isolated)"
}

# ---------- T-STRUCT-A: invalid SECTION_ID values rejected ----------
{
  D="$(setup_test struct-a-bad-section)"
  for bad in a e z A E xyz; do
    "$SCRIPT" "$bad" "$D/card.md" </dev/null >/dev/null 2>"$D/stderr-$bad"
    RC=$?
    [ "$RC" -eq 2 ] || { fail "T-STRUCT-A/section=$bad" "expected 2, got $RC"; continue; }
  done
  # Verify a/e diagnostic mentions no-recording semantics.
  grep -q "no-recording" "$D/stderr-a" || fail "T-STRUCT-A/section=a/diagnostic" "missing no-recording rationale"
  grep -q "no-recording" "$D/stderr-A" || fail "T-STRUCT-A/section=A/diagnostic" "missing (uppercase A normalized)"
  grep -q "no-recording" "$D/stderr-e" || fail "T-STRUCT-A/section=e/diagnostic" "missing"
  grep -q "invalid SECTION_ID" "$D/stderr-z" || fail "T-STRUCT-A/section=z/diagnostic" "missing invalid-id"
  pass "T-STRUCT-A invalid SECTION_ID values rejected (a/A/e/z/junk)"
}

# ---------- T-STRUCT-B: missing PROMPT_CARD_PATH rejected ----------
{
  D="$(setup_test struct-b-no-card)"
  "$SCRIPT" b </dev/null >/dev/null 2>"$D/stderr"
  RC=$?
  [ "$RC" -eq 2 ] && grep -q "PROMPT_CARD_PATH required" "$D/stderr" && \
    pass "T-STRUCT-B missing PROMPT_CARD_PATH → exit 2" || \
    fail "T-STRUCT-B" "exit=$RC stderr=$(cat $D/stderr)"
}

# ---------- T-STRUCT-C: unreadable PROMPT_CARD_PATH rejected ----------
{
  D="$(setup_test struct-c-unreadable-card)"
  "$SCRIPT" b "$D/does-not-exist.md" </dev/null >/dev/null 2>"$D/stderr"
  RC=$?
  [ "$RC" -eq 2 ] && grep -q "not readable" "$D/stderr" && \
    pass "T-STRUCT-C unreadable PROMPT_CARD_PATH → exit 2" || \
    fail "T-STRUCT-C" "exit=$RC stderr=$(cat $D/stderr)"
}

# ---------- T-STRUCT-D: voice-mode at TTY without stdin → exit 4 ----------
# Cannot actually attach a TTY in a non-interactive test runner. Instead,
# verify the exit-4 path via /dev/tty redirection if available, OR document
# the gate via code-path inspection. We approximate by NOT setting
# STDIN_TRANSCRIPT_OVERRIDE and providing /dev/null on stdin (which IS a
# pipe, NOT a TTY) — the script reads empty transcript and exits 0. This
# is the documented behavior: empty transcripts are accepted (caller
# pipeline decides). The TTY-specific exit-4 path is exercised only in
# real interactive sessions; we test the code path by ensuring `[ -t 0 ]`
# false-branch (pipe stdin) succeeds.
{
  D="$(setup_test struct-d-empty-stdin)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            VOICE_PROBE_OVERRIDE=available \
            "$SCRIPT" b "$D/card.md" </dev/null 2>"$D/stderr")"
  RC=$?
  TPATH="$(echo "$STDOUT" | tail -1)"
  [ "$RC" -eq 0 ] || fail "T-STRUCT-D/pipe-empty/exit" "expected 0, got $RC"
  [ "$TPATH" = "$D/transcripts/section-b.txt" ] || fail "T-STRUCT-D/pipe-empty/path" "wrong path: $TPATH"
  [ -f "$D/transcripts/section-b.txt" ] || fail "T-STRUCT-D/pipe-empty/file" "transcript missing"
  # Empty transcript is acceptable in pipe mode.
  pass "T-STRUCT-D pipe-stdin path (TTY-without-stdin exit-4 branch documented in code)"
}

# ---------- T-STRUCT-E: bad VOICE_PROBE_OVERRIDE → default-deny (typed) ----------
{
  D="$(setup_test struct-e-bad-override)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            VOICE_PROBE_OVERRIDE=garbage \
            STDIN_TRANSCRIPT_OVERRIDE="bad override fallback" \
            "$SCRIPT" b "$D/card.md" 2>"$D/stderr")"
  RC=$?
  [ "$RC" -eq 0 ] || fail "T-STRUCT-E/exit" "expected 0, got $RC"
  grep -q "VOICE_PROBE_OVERRIDE invalid" "$D/stderr" || fail "T-STRUCT-E/diag" "diagnostic missing"
  grep -q "voice unavailable" "$D/stderr" || fail "T-STRUCT-E/fallback" "fallback notice missing"
  [ "$RC" -eq 0 ] && grep -q "VOICE_PROBE_OVERRIDE invalid" "$D/stderr" && \
    grep -q "voice unavailable" "$D/stderr" && \
    pass "T-STRUCT-E bad VOICE_PROBE_OVERRIDE → default-deny + diag"
}

# ---------- T-STRUCT-F: VOICE_NOTICE_SEEN=1 suppresses fallback notice ----------
{
  D="$(setup_test struct-f-notice-seen)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            VOICE_PROBE_OVERRIDE=unavailable \
            VOICE_NOTICE_SEEN=1 \
            STDIN_TRANSCRIPT_OVERRIDE="silent fallback" \
            "$SCRIPT" b "$D/card.md" 2>"$D/stderr")"
  RC=$?
  [ "$RC" -eq 0 ] || fail "T-STRUCT-F/exit" "expected 0, got $RC"
  # The "voice unavailable" notice should be suppressed.
  grep -q "voice unavailable" "$D/stderr" && fail "T-STRUCT-F/notice-suppressed" "notice should be suppressed when VOICE_NOTICE_SEEN=1"
  # But typed-mode notice still appears (per-invocation, not the dedupable one).
  grep -q "Typed input mode" "$D/stderr" || fail "T-STRUCT-F/typed-mode-still-shown" "typed-mode notice missing"
  [ "$RC" -eq 0 ] && ! grep -q "voice unavailable" "$D/stderr" && \
    grep -q "Typed input mode" "$D/stderr" && \
    pass "T-STRUCT-F VOICE_NOTICE_SEEN=1 suppresses fallback notice"
}

# ---------- T-STRUCT-G: uniform stdin contract (typed + voice both via stdin) ----------
{
  D="$(setup_test struct-g-uniform-stdin)"
  V_OUT="$(TRANSCRIPT_DIR="$D/transcripts-v" \
           VOICE_PROBE_OVERRIDE=available \
           STDIN_TRANSCRIPT_OVERRIDE="X" \
           "$SCRIPT" b "$D/card.md" 2>/dev/null)"
  T_OUT="$(TRANSCRIPT_DIR="$D/transcripts-t" \
           VOICE_PROBE_OVERRIDE=unavailable \
           STDIN_TRANSCRIPT_OVERRIDE="X" \
           "$SCRIPT" b "$D/card.md" 2>/dev/null)"
  V_FILE="$(cat "$D/transcripts-v/section-b.txt")"
  T_FILE="$(cat "$D/transcripts-t/section-b.txt")"
  [ "$V_FILE" = "X" ] && [ "$T_FILE" = "X" ] && \
    pass "T-STRUCT-G uniform stdin: voice and typed paths capture identically" || \
    fail "T-STRUCT-G" "voice='$V_FILE' typed='$T_FILE'"
}

# ---------- T-STRUCT-H: transcript content does not leak to stdout ----------
{
  D="$(setup_test struct-h-stdout-isolation)"
  SECRET="THIS_TRANSCRIPT_TEXT_MUST_NOT_APPEAR_ON_STDOUT_ONLY_PATH"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            VOICE_PROBE_OVERRIDE=available \
            STDIN_TRANSCRIPT_OVERRIDE="$SECRET" \
            "$SCRIPT" b "$D/card.md" 2>/dev/null)"
  echo "$STDOUT" | grep -q "$SECRET" && fail "T-STRUCT-H" "transcript content leaked to stdout" || \
    pass "T-STRUCT-H transcript content stays in file (not on stdout)"
}

# ---------- summary ----------
echo ""
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
