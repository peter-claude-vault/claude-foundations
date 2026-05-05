#!/usr/bin/env bash
# ir-builder-test.sh — SP13 T-3 unit tests
#
# Covers Stage 1 IR construction acceptance criteria:
#   AC1  schema is valid JSON Schema Draft-07
#   AC2  format-detector.sh + format-parsers/ + ir-builder.sh exist; bash -n clean
#   AC3  per-format probe: 7 fixtures (one per supported format) -> 7 IR records,
#        each with the expected `format` value and a non-empty normalized_text
#   AC4  batch cap default (100) over 250 items -> 3 batches with progress lines
#   AC5  custom cap (--batch-cap 50) over 250 items -> 5 batches
#   AC6  unsupported format -> record with format="unsupported" and marker text
#        (does NOT halt pipeline)
#   AC7  every IR record validates structurally against the schema (jq probe)
#   AC8  onboard.sh threads --seed-batch-cap into ir-builder
#
# Hermetic: $TMPDIR/ir-builder-test-XXXXXX. No live writes.
# Bash 3.2 compatible (R-23).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
INTAKE="$REPO_ROOT/onboarding/seed-content/intake.sh"
DETECTOR="$REPO_ROOT/onboarding/seed-content/format-detector.sh"
PARSER_DIR="$REPO_ROOT/onboarding/seed-content/format-parsers"
IR_BUILDER="$REPO_ROOT/onboarding/seed-content/ir-builder.sh"
SCHEMA="$REPO_ROOT/schemas/seed-content-ir-schema.json"
ONBOARD="$REPO_ROOT/skills/onboarder/onboard.sh"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/ir-builder-test-XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
record_pass() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
record_fail() {
  fail=$((fail + 1))
  printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"
}
assert_eq() { if [ "$2" = "$3" ]; then record_pass "$1"; else record_fail "$1" "$2" "$3"; fi; }

# ---------- AC1 — schema is valid JSON Schema Draft-07 ----------
echo "AC1 — schema validity"
if jq -e '."$schema" == "http://json-schema.org/draft-07/schema#"' "$SCHEMA" >/dev/null 2>&1; then
  record_pass "schema declares Draft-07"
else
  record_fail "schema declares Draft-07" "draft-07" "missing-or-mismatch"
fi
if jq -e '.required | index("path") and index("format") and index("normalized_text") and index("source_hash")' "$SCHEMA" >/dev/null 2>&1; then
  record_pass "schema requires core fields"
else
  record_fail "schema requires core fields" "all 4" "missing"
fi
if jq -e '.properties.format.enum | length == 8' "$SCHEMA" >/dev/null 2>&1; then
  record_pass "format enum has 8 values (7 + unsupported)"
else
  record_fail "format enum size" "8" "$(jq '.properties.format.enum | length' "$SCHEMA")"
fi

# ---------- AC2 — components exist + syntax clean ----------
echo "AC2 — components present + bash -n clean"
for f in "$DETECTOR" "$IR_BUILDER" \
         "$PARSER_DIR/markdown.sh" "$PARSER_DIR/plaintext.sh" "$PARSER_DIR/word.sh" \
         "$PARSER_DIR/pdf.sh" "$PARSER_DIR/otter-vtt.sh" \
         "$PARSER_DIR/zoom-transcript.sh" "$PARSER_DIR/llm-export.sh"; do
  if [ -f "$f" ] && bash -n "$f" 2>/dev/null; then
    record_pass "$(basename "$f") exists + bash -n clean"
  else
    record_fail "$(basename "$f") exists + bash -n clean" "ok" "missing-or-syntax"
  fi
done

# ---------- AC3 — per-format probe (7 fixtures) ----------
echo "AC3 — per-format probe"
FMT_DIR="$TMPROOT/per-format"
mkdir -p "$FMT_DIR"

# markdown
cat > "$FMT_DIR/note.md" <<'EOF'
---
title: probe
---
# Heading

body text
EOF

# plaintext
printf 'plain text content line 1\nplain text content line 2\n' > "$FMT_DIR/notes.txt"

# word — fake docx with PK\x03\x04 magic
printf 'PK\003\004fake-docx-content' > "$FMT_DIR/doc.docx"

# pdf — fake pdf with %PDF- magic
printf '%%PDF-1.4 fake pdf content' > "$FMT_DIR/file.pdf"

# otter-vtt
cat > "$FMT_DIR/meeting.vtt" <<'EOF'
WEBVTT

00:00:00.000 --> 00:00:05.000
Speaker A: Hello team

00:00:05.000 --> 00:00:10.000
Speaker B: Hi A
EOF

# zoom-transcript (sequence number + timestamp + text triples)
cat > "$FMT_DIR/zoom-meeting.txt" <<'EOF'
1
00:00:01.000 --> 00:00:05.000
Alice: Welcome

2
00:00:06.000 --> 00:00:09.000
Bob: Thanks for joining
EOF

# llm-export
cat > "$FMT_DIR/chat.json" <<'EOF'
[
  {"role": "user", "content": "What is two plus two?"},
  {"role": "assistant", "content": "Four."}
]
EOF

# build intake then IR
INTAKE_M="$TMPROOT/per-format-intake.jsonl"
IR_M="$TMPROOT/per-format-ir.jsonl"
bash "$INTAKE" --source "$FMT_DIR" --manifest "$INTAKE_M" 2>/dev/null
bash "$IR_BUILDER" --manifest "$INTAKE_M" --ir "$IR_M" 2>/dev/null

ir_count=$(wc -l < "$IR_M" | tr -d ' ')
assert_eq "7 IR records emitted" "7" "$ir_count"

for fmt in markdown plaintext word pdf otter-vtt zoom-transcript llm-export; do
  hits=$(jq -c --arg f "$fmt" 'select(.format==$f)' "$IR_M" | wc -l | tr -d ' ')
  assert_eq "format=$fmt present" "1" "$hits"
done

# Each record has non-empty normalized_text
empty_text=$(jq -c 'select(.normalized_text == "")' "$IR_M" | wc -l | tr -d ' ')
assert_eq "no record has empty normalized_text" "0" "$empty_text"

# ---------- AC4 — batch cap default (100) over 250 items ----------
echo "AC4 — default batch cap (100) over 250 items"
BIG_DIR="$TMPROOT/big-fixture"
mkdir -p "$BIG_DIR"
i=1
while [ $i -le 250 ]; do
  printf 'b-%s' "$i" > "$BIG_DIR/file-$i.txt"
  i=$((i + 1))
done
BIG_INTAKE="$TMPROOT/big-intake.jsonl"
BIG_IR="$TMPROOT/big-ir.jsonl"
bash "$INTAKE" --source "$BIG_DIR" --manifest "$BIG_INTAKE" 2>/dev/null

big_intake_count=$(wc -l < "$BIG_INTAKE" | tr -d ' ')
assert_eq "intake yielded 250 records" "250" "$big_intake_count"

stderr_log="$TMPROOT/big-stderr.log"
bash "$IR_BUILDER" --manifest "$BIG_INTAKE" --ir "$BIG_IR" 2>"$stderr_log"
batches_default=$(grep -c '^\[batch ' "$stderr_log" || true)
assert_eq "default cap 100 -> 3 progress lines" "3" "$batches_default"
assert_eq "250 IR records emitted" "250" "$(wc -l < "$BIG_IR" | tr -d ' ')"

# ---------- AC5 — custom batch cap 50 over 250 items ----------
echo "AC5 — custom batch cap (--batch-cap 50)"
BIG_IR_50="$TMPROOT/big-ir-50.jsonl"
stderr_log_50="$TMPROOT/big-stderr-50.log"
bash "$IR_BUILDER" --manifest "$BIG_INTAKE" --ir "$BIG_IR_50" --batch-cap 50 2>"$stderr_log_50"
batches_custom=$(grep -c '^\[batch ' "$stderr_log_50" || true)
assert_eq "custom cap 50 -> 5 progress lines" "5" "$batches_custom"

# ---------- AC6 — unsupported format reports rather than halts ----------
echo "AC6 — unsupported format reports"
UNSUP_DIR="$TMPROOT/unsup"
mkdir -p "$UNSUP_DIR"
printf 'mystery-bytes' > "$UNSUP_DIR/mystery.unknown.xyz"
printf 'plain text' > "$UNSUP_DIR/normal.txt"
UNSUP_INTAKE="$TMPROOT/unsup-intake.jsonl"
UNSUP_IR="$TMPROOT/unsup-ir.jsonl"
bash "$INTAKE" --source "$UNSUP_DIR" --manifest "$UNSUP_INTAKE" 2>/dev/null
bash "$IR_BUILDER" --manifest "$UNSUP_INTAKE" --ir "$UNSUP_IR" 2>/dev/null

unsup_count=$(jq -c 'select(.format == "unsupported")' "$UNSUP_IR" | wc -l | tr -d ' ')
assert_eq "1 unsupported record emitted" "1" "$unsup_count"
total_count=$(wc -l < "$UNSUP_IR" | tr -d ' ')
assert_eq "pipeline did NOT halt (2 records total)" "2" "$total_count"

unsup_marker=$(jq -r 'select(.format=="unsupported") | .normalized_text' "$UNSUP_IR")
case "$unsup_marker" in
  '[format not supported:'*) record_pass "unsupported record carries marker" ;;
  *) record_fail "unsupported record carries marker" "[format not supported: ...]" "$unsup_marker" ;;
esac

# ---------- AC7 — IR records validate structurally ----------
echo "AC7 — IR record structural validity"
invalid=0
while IFS= read -r line; do
  echo "$line" | jq -e '
    has("path") and has("format") and has("detected_at") and
    has("raw_bytes") and has("normalized_text") and has("metadata") and
    has("source_hash") and
    (.normalized_text | type == "string") and
    (.metadata | type == "object") and
    (.raw_bytes | type == "number") and
    (.source_hash | type == "string" and length >= 8)
  ' >/dev/null 2>&1 || invalid=$((invalid + 1))
done < "$IR_M"
assert_eq "all per-format records structurally valid" "0" "$invalid"

# ---------- AC8 — onboard.sh threads --seed-batch-cap ----------
echo "AC8 — onboard.sh --seed-batch-cap plumbing"
FAKE_HOME="$TMPROOT/fake-home-2"
mkdir -p "$FAKE_HOME/.claude/onboarding"
out=$(CLAUDE_HOME="$FAKE_HOME/.claude" \
      INPUTS_DIR="$FAKE_HOME/.claude/onboarding" \
      USER_MANIFEST="$FAKE_HOME/.claude/user-manifest.json" \
      bash "$ONBOARD" --seed-content "$BIG_DIR" --seed-batch-cap 50 --dry-run 2>&1) || true

if echo "$out" | grep -q 'IR build (batch cap=50)'; then
  record_pass "onboard.sh logs custom batch cap"
else
  record_fail "onboard.sh logs custom batch cap" "IR build (batch cap=50)" \
              "$(echo "$out" | grep -i 'batch cap' | head -1)"
fi

real_ir="$FAKE_HOME/.claude/onboarding/seed-content/ir.jsonl"
if [ -f "$real_ir" ]; then
  real_ir_count=$(wc -l < "$real_ir" | tr -d ' ')
  assert_eq "ir.jsonl written under \$INPUTS_DIR (250 records)" "250" "$real_ir_count"
else
  record_fail "ir.jsonl written under \$INPUTS_DIR" "file" "missing"
fi

# ---------- summary ----------
echo
total=$((pass + fail))
echo "=========================================="
echo "Total: $total — pass=$pass fail=$fail"
if [ "$fail" -gt 0 ]; then exit 1; else exit 0; fi
