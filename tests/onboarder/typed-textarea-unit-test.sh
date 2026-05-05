#!/bin/bash
# tests/onboarder/typed-textarea-unit-test.sh — synthetic unit tests for SP07 T-4
# onboarding/fallback/typed-textarea.sh.
#
# Validates the 5 acceptance criteria from
# ~/.claude-plans/71-claude-foundations-engine-v2/07-onboarder-ux/tasks.md L105-109:
#
#   AC1 — Render same prompt card as voice mode
#   AC2 — Accept multi-line typed input (terminal EOF or editor save)
#   AC3 — Write blob to same transcript path as voice mode
#   AC4 — Downstream extraction pipeline processes typed blob identically
#         (covered structurally: same path + same UTF-8 blob; downstream
#         pipeline is a contract, not invoked here)
#   AC5 — Honor per-section user toggle to switch from voice → typed mid-flow
#         (covered by atomic-overwrite test: voice writes path, typed
#         re-invocation with same SECTION_ID overwrites cleanly)
#
# Plus structural guardrails (R-37 + path-classification + reference-leak floor):
#
#   T-STRUCT-A — invalid SECTION_ID rejected (exit 2): a, e, junk, uppercase A/E
#   T-STRUCT-B — missing PROMPT_CARD_PATH rejected (exit 2)
#   T-STRUCT-C — unreadable PROMPT_CARD_PATH rejected (exit 2)
#   T-STRUCT-D — --editor without $EDITOR rejected (exit 2)
#   T-STRUCT-E — --editor with stub $EDITOR captures saved blob; comment
#                lines stripped
#   T-STRUCT-F — stdout contract: single path line, transcript content NOT
#                on stdout
#   T-STRUCT-G — multi-line input preserved exactly (newlines + blanks)
#
# Hermetic: per-test temp $TRANSCRIPT_DIR; STDIN_TRANSCRIPT_OVERRIDE replaces
# stdin reads in most paths; stub-EDITOR for editor-mode coverage.
# Bash 3.2 clean (R-23). Reference-leak-clean fixtures.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/onboarding/fallback/typed-textarea.sh"
VOICE_SCRIPT="$REPO_ROOT/onboarding/voice-capture.sh"

if [ ! -x "$SCRIPT" ]; then echo "FAIL: cannot exec $SCRIPT"; exit 2; fi
if [ ! -x "$VOICE_SCRIPT" ]; then echo "FAIL: cannot exec $VOICE_SCRIPT (T-3 dep)"; exit 2; fi

TEST_ROOT="$(mktemp -d -t typed-textarea-unit-test-XXXXXX)"
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

# ---------- AC1 + AC3: prompt card rendered + transcript written to per-section path (B) ----------
{
  D="$(setup_test ac1-card-b)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            STDIN_TRANSCRIPT_OVERRIDE="My role is consultant. I work at Acme Foundation. I lead a team." \
            "$SCRIPT" b "$D/card.md" 2>"$D/stderr")"
  RC=$?
  TPATH="$(echo "$STDOUT" | tail -1)"

  [ "$RC" -eq 0 ] || fail "AC1+3/typed-B/exit" "expected 0, got $RC"
  [ "$TPATH" = "$D/transcripts/section-b.txt" ] || fail "AC3/typed-B/stdout-path" "got $TPATH"
  [ -f "$D/transcripts/section-b.txt" ] || fail "AC3/typed-B/file-exists" "transcript file missing"
  grep -q "PROMPT CARD for test ac1-card-b" "$D/stderr" || fail "AC1/typed-B/card-render" "prompt card not in stderr"
  grep -q "Please describe X" "$D/stderr" || fail "AC1/typed-B/card-content" "card body missing"
  grep -Fq "My role is consultant" "$D/transcripts/section-b.txt" || fail "AC3/typed-B/transcript-content" "transcript text mismatch"
  [ "$RC" -eq 0 ] && [ "$TPATH" = "$D/transcripts/section-b.txt" ] && \
    [ -f "$D/transcripts/section-b.txt" ] && \
    grep -q "PROMPT CARD for test ac1-card-b" "$D/stderr" && \
    grep -q "Please describe X" "$D/stderr" && \
    grep -Fq "My role is consultant" "$D/transcripts/section-b.txt" && \
    pass "AC1+AC3/typed-B happy path (card render + per-section path)"
}

# ---------- AC3: per-section paths C and D ----------
{
  D="$(setup_test ac3-typed-c)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            STDIN_TRANSCRIPT_OVERRIDE="My notes live in ~/Notes." \
            "$SCRIPT" c "$D/card.md" 2>"$D/stderr")"
  RC=$?
  TPATH="$(echo "$STDOUT" | tail -1)"
  [ "$RC" -eq 0 ] && [ "$TPATH" = "$D/transcripts/section-c.txt" ] && \
    [ -f "$D/transcripts/section-c.txt" ] && \
    pass "AC3/typed-C deterministic per-section path" || \
    fail "AC3/typed-C" "exit=$RC path=$TPATH"
}
{
  D="$(setup_test ac3-typed-d)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            STDIN_TRANSCRIPT_OVERRIDE="High autonomy. Daily librarian." \
            "$SCRIPT" d "$D/card.md" 2>"$D/stderr")"
  RC=$?
  TPATH="$(echo "$STDOUT" | tail -1)"
  [ "$RC" -eq 0 ] && [ "$TPATH" = "$D/transcripts/section-d.txt" ] && \
    [ -f "$D/transcripts/section-d.txt" ] && \
    pass "AC3/typed-D deterministic per-section path" || \
    fail "AC3/typed-D" "exit=$RC path=$TPATH"
}

# ---------- AC3: section ID is case-insensitive ----------
{
  D="$(setup_test ac3-case-insensitive)"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            STDIN_TRANSCRIPT_OVERRIDE="caps test" \
            "$SCRIPT" C "$D/card.md" 2>"$D/stderr")"
  RC=$?
  TPATH="$(echo "$STDOUT" | tail -1)"
  [ "$RC" -eq 0 ] && [ "$TPATH" = "$D/transcripts/section-c.txt" ] && \
    pass "AC3/case-insensitive section-id (C → c)" || \
    fail "AC3/case-insensitive" "exit=$RC path=$TPATH (expected lowercase c)"
}

# ---------- AC2: multi-line input via piped stdin (no override) ----------
{
  D="$(setup_test ac2-multiline-pipe)"
  # Use a pipe, not the env override, to exercise the cat-stdin path.
  STDOUT="$(printf 'line one\n\nline three after blank\nline four\n' | \
            TRANSCRIPT_DIR="$D/transcripts" \
            "$SCRIPT" b "$D/card.md" 2>"$D/stderr")"
  RC=$?
  TPATH="$(echo "$STDOUT" | tail -1)"
  [ "$RC" -eq 0 ] || fail "AC2/multiline-pipe/exit" "expected 0, got $RC"
  [ -f "$D/transcripts/section-b.txt" ] || fail "AC2/multiline-pipe/file" "missing"
  CONTENT="$(cat "$D/transcripts/section-b.txt")"
  EXPECTED="$(printf 'line one\n\nline three after blank\nline four')"
  [ "$CONTENT" = "$EXPECTED" ] || fail "AC2/multiline-pipe/content" "blob mismatch"
  [ "$RC" -eq 0 ] && [ -f "$D/transcripts/section-b.txt" ] && [ "$CONTENT" = "$EXPECTED" ] && \
    pass "AC2/multi-line input via piped stdin (newlines + blank lines preserved)"
}

# ---------- AC2 + T-STRUCT-E: --editor mode with stub $EDITOR captures saved blob ----------
{
  D="$(setup_test ac2-editor-stub)"
  # Build a stub editor that writes a known multi-line blob to its argv[1]
  # (overwriting the pre-seeded comment header) and exits 0.
  STUB_EDITOR="$D/stub-editor.sh"
  cat > "$STUB_EDITOR" <<'STUB'
#!/bin/bash
# Stub $EDITOR: replaces the file content with a known multi-line blob.
TARGET="$1"
{
  printf '# this comment line should be stripped\n'
  printf 'editor line one\n'
  printf '\n'
  printf 'editor line three\n'
} > "$TARGET"
exit 0
STUB
  chmod 0755 "$STUB_EDITOR"

  STDOUT="$(EDITOR="$STUB_EDITOR" \
            TRANSCRIPT_DIR="$D/transcripts" \
            "$SCRIPT" --editor b "$D/card.md" 2>"$D/stderr")"
  RC=$?
  TPATH="$(echo "$STDOUT" | tail -1)"
  [ "$RC" -eq 0 ] || fail "AC2+STRUCT-E/editor/exit" "expected 0, got $RC"
  [ -f "$D/transcripts/section-b.txt" ] || fail "AC2+STRUCT-E/editor/file" "missing"
  CONTENT="$(cat "$D/transcripts/section-b.txt")"
  # Comment line should be stripped; multi-line body preserved.
  echo "$CONTENT" | grep -q "^# this comment line" && fail "AC2+STRUCT-E/editor/comment-stripped" "comment line leaked through"
  echo "$CONTENT" | grep -Fq "editor line one" || fail "AC2+STRUCT-E/editor/body" "body line missing"
  echo "$CONTENT" | grep -Fq "editor line three" || fail "AC2+STRUCT-E/editor/body3" "body line three missing"
  [ "$RC" -eq 0 ] && [ -f "$D/transcripts/section-b.txt" ] && \
    ! echo "$CONTENT" | grep -q "^# this comment line" && \
    echo "$CONTENT" | grep -Fq "editor line one" && \
    echo "$CONTENT" | grep -Fq "editor line three" && \
    pass "AC2+T-STRUCT-E --editor with stub \$EDITOR (comment lines stripped, body preserved)"
}

# ---------- AC4: typed transcript matches voice transcript byte-for-byte for same path ----------
# Downstream extraction pipeline processes typed blob identically because
# both paths produce a UTF-8 blob at $TRANSCRIPT_DIR/section-{id}.txt with no
# format markers. We verify by writing the same content via both scripts to
# isolated dirs and checking byte-equality.
{
  D="$(setup_test ac4-uniform-blob)"
  BLOB="My role is consultant. I work at Acme Foundation."

  # Voice path (probe=available, stdin override).
  TRANSCRIPT_DIR="$D/voice" VOICE_PROBE_OVERRIDE=available \
    STDIN_TRANSCRIPT_OVERRIDE="$BLOB" \
    "$VOICE_SCRIPT" b "$D/card.md" >/dev/null 2>&1
  V_RC=$?

  # Typed path (stdin override).
  TRANSCRIPT_DIR="$D/typed" \
    STDIN_TRANSCRIPT_OVERRIDE="$BLOB" \
    "$SCRIPT" b "$D/card.md" >/dev/null 2>&1
  T_RC=$?

  V_PATH="$D/voice/section-b.txt"
  T_PATH="$D/typed/section-b.txt"
  [ "$V_RC" -eq 0 ] && [ "$T_RC" -eq 0 ] || fail "AC4/exits" "voice=$V_RC typed=$T_RC"
  cmp -s "$V_PATH" "$T_PATH" || fail "AC4/byte-equality" "voice and typed transcripts differ"
  [ "$V_RC" -eq 0 ] && [ "$T_RC" -eq 0 ] && cmp -s "$V_PATH" "$T_PATH" && \
    pass "AC4/voice and typed produce byte-identical transcripts (uniform downstream blob)"
}

# ---------- AC5: mid-flow toggle — typed re-invocation overwrites voice transcript at same path ----------
{
  D="$(setup_test ac5-midflow-toggle)"

  # Step 1: voice mode writes section-b transcript.
  TRANSCRIPT_DIR="$D/transcripts" VOICE_PROBE_OVERRIDE=available \
    STDIN_TRANSCRIPT_OVERRIDE="VOICE_BLOB original recording" \
    "$VOICE_SCRIPT" b "$D/card.md" >/dev/null 2>&1
  V_RC=$?
  TPATH="$D/transcripts/section-b.txt"
  V_CONTENT="$(cat "$TPATH" 2>/dev/null)"

  # Step 2: user toggles to typed mid-flow; same SECTION_ID + path; atomic
  # tmp+rename overwrites voice content cleanly.
  TRANSCRIPT_DIR="$D/transcripts" \
    STDIN_TRANSCRIPT_OVERRIDE="TYPED_BLOB user changed mind" \
    "$SCRIPT" b "$D/card.md" >/dev/null 2>&1
  T_RC=$?
  T_CONTENT="$(cat "$TPATH" 2>/dev/null)"

  [ "$V_RC" -eq 0 ] && [ "$T_RC" -eq 0 ] || fail "AC5/exits" "voice=$V_RC typed=$T_RC"
  [ "$V_CONTENT" = "VOICE_BLOB original recording" ] || fail "AC5/voice-write" "voice content not written"
  [ "$T_CONTENT" = "TYPED_BLOB user changed mind" ] || fail "AC5/typed-overwrite" "typed didn't overwrite voice"
  echo "$T_CONTENT" | grep -q "VOICE_BLOB" && fail "AC5/clean-overwrite" "voice content leaked into typed transcript"
  [ "$V_CONTENT" = "VOICE_BLOB original recording" ] && \
    [ "$T_CONTENT" = "TYPED_BLOB user changed mind" ] && \
    ! echo "$T_CONTENT" | grep -q "VOICE_BLOB" && \
    pass "AC5/mid-flow toggle voice→typed: atomic overwrite at same per-section path"
}

# ---------- T-STRUCT-A: invalid SECTION_ID rejected ----------
{
  D="$(setup_test struct-a-bad-section)"
  for bad in a e A E z xyz; do
    "$SCRIPT" "$bad" "$D/card.md" </dev/null >/dev/null 2>"$D/stderr-$bad"
    RC=$?
    [ "$RC" -eq 2 ] || { fail "T-STRUCT-A/section=$bad" "expected 2, got $RC"; continue; }
  done
  grep -q "no-recording" "$D/stderr-a" || fail "T-STRUCT-A/section=a/diagnostic" "missing no-recording rationale"
  grep -q "no-recording" "$D/stderr-A" || fail "T-STRUCT-A/section=A/diagnostic" "uppercase normalize"
  grep -q "no-recording" "$D/stderr-e" || fail "T-STRUCT-A/section=e/diagnostic" "missing"
  grep -q "no-recording" "$D/stderr-E" || fail "T-STRUCT-A/section=E/diagnostic" "uppercase normalize"
  grep -q "invalid SECTION_ID" "$D/stderr-z" || fail "T-STRUCT-A/section=z/diagnostic" "missing invalid-id"
  grep -q "invalid SECTION_ID" "$D/stderr-xyz" || fail "T-STRUCT-A/section=xyz/diagnostic" "missing invalid-id"
  pass "T-STRUCT-A invalid SECTION_ID values rejected (a/A/e/E/z/xyz)"
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

# ---------- T-STRUCT-D: --editor without $EDITOR rejected ----------
{
  D="$(setup_test struct-d-editor-no-env)"
  unset EDITOR
  "$SCRIPT" --editor b "$D/card.md" </dev/null >/dev/null 2>"$D/stderr"
  RC=$?
  [ "$RC" -eq 2 ] && grep -q "EDITOR is unset" "$D/stderr" && \
    pass "T-STRUCT-D --editor without \$EDITOR → exit 2" || \
    fail "T-STRUCT-D" "exit=$RC stderr=$(cat $D/stderr)"
}

# ---------- T-STRUCT-F: stdout contract — single path line, content stays in file ----------
{
  D="$(setup_test struct-f-stdout-isolation)"
  SECRET="THIS_TYPED_TRANSCRIPT_TEXT_MUST_NOT_APPEAR_ON_STDOUT_ONLY_PATH"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            STDIN_TRANSCRIPT_OVERRIDE="$SECRET" \
            "$SCRIPT" b "$D/card.md" 2>/dev/null)"
  LAST="$(echo "$STDOUT" | tail -1)"
  LINES="$(echo "$STDOUT" | wc -l | tr -d ' ')"
  echo "$STDOUT" | grep -q "$SECRET" && fail "T-STRUCT-F/leak" "transcript content leaked to stdout"
  [ "$LAST" = "$D/transcripts/section-b.txt" ] || fail "T-STRUCT-F/last-line" "got $LAST"
  [ "$LINES" = "1" ] || fail "T-STRUCT-F/line-count" "expected 1 stdout line, got $LINES"
  ! echo "$STDOUT" | grep -q "$SECRET" && \
    [ "$LAST" = "$D/transcripts/section-b.txt" ] && [ "$LINES" = "1" ] && \
    pass "T-STRUCT-F stdout = single transcript path line (content stays in file)"
}

# ---------- T-STRUCT-G: multi-line input preserved exactly ----------
{
  D="$(setup_test struct-g-multiline-preserve)"
  # Trailing newline + interior blanks + leading blank.
  PAYLOAD="$(printf '\nleading blank\nmiddle\n\ntrailing\n')"
  STDOUT="$(TRANSCRIPT_DIR="$D/transcripts" \
            STDIN_TRANSCRIPT_OVERRIDE="$PAYLOAD" \
            "$SCRIPT" d "$D/card.md" 2>/dev/null)"
  RC=$?
  CONTENT="$(cat "$D/transcripts/section-d.txt" 2>/dev/null)"
  [ "$RC" -eq 0 ] && [ "$CONTENT" = "$PAYLOAD" ] && \
    pass "T-STRUCT-G multi-line input preserved (leading + interior + trailing newlines)" || \
    fail "T-STRUCT-G" "rc=$RC payload!=content"
}

# ---------- summary ----------
echo ""
echo "=== typed-textarea-unit-test ==="
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
