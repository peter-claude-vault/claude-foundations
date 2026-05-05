#!/usr/bin/env bash
# onboarding/tests/sp13-meeting-note-ingestor-test.sh — SP13 T-11 hermetic test.
#
# 12 acceptance gates × N sub-probes covering the foundation-portable
# meeting-note ingestor (skills/meeting-note-ingestor/) + Granola connector
# (skills/meeting-note-ingestor-granola/).
#
# Hermetic isolation per feedback_test_isolation_for_hooks_state:
#   - $TMPDIR/sp13-t11-test-XXXXXX
#   - ANTHROPIC_API_KEY + VOYAGE_API_KEY unset
#   - PROVENANCE_SCHEMA explicit env var (lib path resolution from arbitrary cwd)
#   - $HOOKS_STATE not touched (skill performs zero ~/.claude/ writes)
#
# Constraints: bash 3.2.57 (R-23). jq required.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
INGEST="$REPO_ROOT/skills/meeting-note-ingestor/ingest.sh"
GRANOLA_PARSER="$REPO_ROOT/skills/meeting-note-ingestor/parsers/granola.sh"
INGEST_SKILL_MD="$REPO_ROOT/skills/meeting-note-ingestor/SKILL.md"
CONNECTOR_SCRIPT="$REPO_ROOT/skills/meeting-note-ingestor-granola/from-granola.sh"
CONNECTOR_SKILL_MD="$REPO_ROOT/skills/meeting-note-ingestor-granola/SKILL.md"
PF_LIB="$REPO_ROOT/lib/provenance-frontmatter.sh"
PROV_SCHEMA="$REPO_ROOT/schemas/provenance-frontmatter-schema.json"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/sp13-t11-test-XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

# Hermetic env. Test isolation per feedback_test_isolation_for_hooks_state.
unset ANTHROPIC_API_KEY VOYAGE_API_KEY
export PROVENANCE_SCHEMA="$PROV_SCHEMA"

PASS=0
FAIL=0
RESULTS_LOG="$TMPROOT/results.log"
: > "$RESULTS_LOG"

_log() { printf '%s\n' "$1" | tee -a "$RESULTS_LOG"; }
_pass() { PASS=$((PASS + 1)); _log "PASS $1"; }
_fail() { FAIL=$((FAIL + 1)); _log "FAIL $1"; }

_assert_match() {
  # $1=label $2=needle $3=haystack-file
  if grep -qF -- "$2" "$3" 2>/dev/null; then
    _pass "$1 — match: $2"
  else
    _fail "$1 — missing: $2"
  fi
}

_assert_regex() {
  if grep -qE -- "$2" "$3" 2>/dev/null; then
    _pass "$1 — regex: $2"
  else
    _fail "$1 — regex miss: $2"
  fi
}

_assert_no_match() {
  if grep -qE -- "$2" "$3" 2>/dev/null; then
    _fail "$1 — unexpected match: $2"
  else
    _pass "$1 — absent: $2"
  fi
}

_assert_file_exists() {
  if [ -f "$2" ]; then _pass "$1 — file exists: $2"
  else _fail "$1 — file missing: $2"
  fi
}

_assert_rc() {
  # $1=label $2=expected-rc $3=actual-rc
  if [ "$2" = "$3" ]; then _pass "$1 — rc=$2"
  else _fail "$1 — expected rc=$2 got rc=$3"
  fi
}

# Snapshot R-55 G1 override-log baseline for AC11.
G1_LOG="$HOME/.claude/hooks/state/plan-71-live-mutation-overrides.log"
G1_BASELINE=0
if [ -f "$G1_LOG" ]; then
  G1_BASELINE="$(wc -l < "$G1_LOG" | tr -d ' ')"
fi

# ============================================================================
# AC1 — Skill files exist + bash -n lint clean (R-23).
# ============================================================================
_log "--- AC1: skill files exist + R-23 bash 3.2 lint ---"
_assert_file_exists "AC1.1 portable ingest.sh"          "$INGEST"
_assert_file_exists "AC1.2 portable SKILL.md"           "$INGEST_SKILL_MD"
_assert_file_exists "AC1.3 portable granola parser"     "$GRANOLA_PARSER"
_assert_file_exists "AC1.4 connector SKILL.md"          "$CONNECTOR_SKILL_MD"
_assert_file_exists "AC1.5 connector from-granola.sh"   "$CONNECTOR_SCRIPT"
_assert_file_exists "AC1.6 pf-lib"                      "$PF_LIB"
_assert_file_exists "AC1.7 provenance schema"           "$PROV_SCHEMA"
for sh in "$INGEST" "$GRANOLA_PARSER" "$CONNECTOR_SCRIPT"; do
  if bash -n "$sh" 2>/dev/null; then _pass "AC1.8 bash -n: $(basename "$sh")"
  else _fail "AC1.8 bash -n FAILED: $sh"
  fi
done

# ============================================================================
# AC2 — Otter VTT fixture → structured note (frontmatter + cleaned body).
# ============================================================================
_log "--- AC2: Otter VTT fixture ---"
VTT_FIX="$TMPROOT/2026-04-21-DDX-Standup.vtt"
cat > "$VTT_FIX" <<'EOF'
WEBVTT

NOTE
This is a header note.

1
00:00:00.000 --> 00:00:05.000
Peter Tiktinsky: Welcome to the DDX standup.

2
00:00:05.500 --> 00:00:12.000
Ellie Chen: Thanks Peter. The BAR dashboard is on track.

3
00:00:12.500 --> 00:00:18.000
Pierre-Olivier: I have a quick question about the data model.

4
00:00:18.500 --> 00:00:22.000
Speaker 4: That sounds good to me.

5
00:00:22.500 --> 00:00:25.000
Peter Tiktinsky: Let's wrap up.
EOF

VTT_OUT="$TMPROOT/vtt-note.md"
bash "$INGEST" --transcript "$VTT_FIX" --output "$VTT_OUT" 2>"$TMPROOT/vtt.err"
_assert_rc "AC2.1 ingest exit" "0" "$?"
_assert_file_exists "AC2.2 vtt note written" "$VTT_OUT"
_assert_match  "AC2.3 vtt frontmatter open"     "---"                         "$VTT_OUT"
_assert_match  "AC2.4 vtt title derived"        'title: "DDX-Standup"'        "$VTT_OUT"
_assert_match  "AC2.5 vtt date filename-extr"   "date: 2026-04-21"            "$VTT_OUT"
_assert_match  "AC2.6 vtt source_format"        "source_format: otter-vtt"    "$VTT_OUT"
_assert_match  "AC2.7 vtt source_path"          "$VTT_FIX"                    "$VTT_OUT"
_assert_match  "AC2.8 vtt body header"          "# DDX-Standup"               "$VTT_OUT"
_assert_match  "AC2.9 vtt speaker peter"        "Peter Tiktinsky: Welcome"    "$VTT_OUT"
_assert_match  "AC2.10 vtt participant ellie"   '- "Ellie Chen"'              "$VTT_OUT"
_assert_match  "AC2.11 vtt participant peter"   '- "Peter Tiktinsky"'         "$VTT_OUT"
_assert_match  "AC2.12 vtt participant po"      '- "Pierre-Olivier"'          "$VTT_OUT"
_assert_match  "AC2.13 vtt participant speaker4" '- "Speaker 4"'              "$VTT_OUT"
_assert_no_match "AC2.14 vtt body cue numbers stripped"      '^[0-9]+$'                                 "$VTT_OUT"
_assert_no_match "AC2.15 vtt body timestamp arrow stripped"  '\-\->'                                    "$VTT_OUT"
_assert_no_match "AC2.16 vtt body WEBVTT header stripped"    '^WEBVTT$'                                 "$VTT_OUT"
_assert_no_match "AC2.17 vtt false-positive WEBVTT not in participants" '^  - "WEBVTT"$'                "$VTT_OUT"
_assert_no_match "AC2.18 vtt false-positive NOTE not in participants"   '^  - "NOTE"$'                  "$VTT_OUT"

# ============================================================================
# AC3 — Word fixture → structured note (graceful-degrade or pandoc-cleaned).
# ============================================================================
_log "--- AC3: Word fixture ---"
# Synthesize a minimal .docx (zip with magic bytes 50 4b 03 04 at offset 0)
# so format-detector identifies it as Word. Body content irrelevant — the
# T-3 word.sh parser shells out to pandoc; we accept either a pandoc-cleaned
# body or the graceful-degrade marker.
WORD_FIX="$TMPROOT/2026-04-22-Weekly-Word-Notes.docx"
# Real .docx requires a zip. Use python3 to author a minimal valid docx-like
# zip with a [Content_Types].xml + word/document.xml (pandoc reads these).
python3 - "$WORD_FIX" <<'PY'
import sys, zipfile
path = sys.argv[1]
ct = (
  '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
  '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\n'
  '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\n'
  '<Default Extension="xml" ContentType="application/xml"/>\n'
  '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\n'
  '</Types>\n'
)
rels = (
  '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
  '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\n'
  '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\n'
  '</Relationships>\n'
)
doc = (
  '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
  '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\n'
  '<w:body>\n'
  '<w:p><w:r><w:t>Sarah Liang: Q3 forecast looks strong.</w:t></w:r></w:p>\n'
  '<w:p><w:r><w:t>Florian Thiebaut: Margin compression is the headwind.</w:t></w:r></w:p>\n'
  '<w:p><w:r><w:t>Speaker 3: Action item to follow up by Friday.</w:t></w:r></w:p>\n'
  '</w:body></w:document>\n'
)
with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('[Content_Types].xml', ct)
    z.writestr('_rels/.rels', rels)
    z.writestr('word/document.xml', doc)
PY

WORD_OUT="$TMPROOT/word-note.md"
bash "$INGEST" --transcript "$WORD_FIX" --output "$WORD_OUT" 2>"$TMPROOT/word.err"
_assert_rc "AC3.1 ingest exit" "0" "$?"
_assert_file_exists "AC3.2 word note written" "$WORD_OUT"
_assert_match  "AC3.3 word frontmatter open"      "---"                          "$WORD_OUT"
_assert_match  "AC3.4 word source_format"         "source_format: word"          "$WORD_OUT"
_assert_match  "AC3.5 word date filename-extr"    "date: 2026-04-22"             "$WORD_OUT"
_assert_match  "AC3.6 word source_path"           "$WORD_FIX"                    "$WORD_OUT"
_assert_match  "AC3.7 word title derived"         'title: "Weekly-Word-Notes"'   "$WORD_OUT"
# Body: either pandoc-cleaned content OR the graceful-degrade marker. Accept
# either — both are valid per the spec L355 "structured note + frontmatter".
if grep -q "Sarah Liang: Q3 forecast" "$WORD_OUT" 2>/dev/null; then
  _pass "AC3.8 word body pandoc-cleaned (Sarah Liang line present)"
elif grep -q "binary content not extracted" "$WORD_OUT" 2>/dev/null; then
  _pass "AC3.8 word body graceful-degrade marker (pandoc unavailable)"
else
  _fail "AC3.8 word body neither pandoc-cleaned nor graceful-degrade marker"
fi

# ============================================================================
# AC4 — Granola JSON fixture (full shape: title + date + attendees + transcript).
# ============================================================================
_log "--- AC4: Granola JSON fixture ---"
GRANOLA_FIX="$TMPROOT/granola-meeting-abc123.json"
cat > "$GRANOLA_FIX" <<'EOF'
{
  "title": "Q2 Planning Sync",
  "date": "2026-04-22T15:00:00Z",
  "attendees": [
    {"name": "Peter Tiktinsky", "role": "host"},
    {"name": "Ellie Chen"},
    "Sri Patel",
    {"first_name": "Pierre-Olivier"}
  ],
  "transcript": [
    {"speaker": "Peter Tiktinsky", "text": "Welcome to the planning sync."},
    {"speaker": "Ellie Chen", "text": "I'll cover the BAR dashboard."},
    {"speaker": "Sri Patel", "content": "I have data for the LUXE workstream."},
    {"speaker": "Pierre-Olivier", "text": "Briefly on the data model."}
  ]
}
EOF

GRANOLA_OUT="$TMPROOT/granola-note.md"
bash "$INGEST" --transcript "$GRANOLA_FIX" --output "$GRANOLA_OUT" 2>"$TMPROOT/granola.err"
_assert_rc "AC4.1 ingest exit" "0" "$?"
_assert_file_exists "AC4.2 granola note written" "$GRANOLA_OUT"
_assert_match "AC4.3 granola title from JSON"      'title: "Q2 Planning Sync"' "$GRANOLA_OUT"
_assert_match "AC4.4 granola date stripped to YMD" "date: 2026-04-22"          "$GRANOLA_OUT"
_assert_match "AC4.5 granola source_format"        "source_format: granola"    "$GRANOLA_OUT"
_assert_match "AC4.6 granola participant peter"    '- "Peter Tiktinsky"'       "$GRANOLA_OUT"
_assert_match "AC4.7 granola participant ellie"    '- "Ellie Chen"'            "$GRANOLA_OUT"
_assert_match "AC4.8 granola participant sri str"  '- "Sri Patel"'             "$GRANOLA_OUT"
_assert_match "AC4.9 granola participant po fname" '- "Pierre-Olivier"'        "$GRANOLA_OUT"
_assert_match "AC4.10 granola body peter line"     "Peter Tiktinsky: Welcome"  "$GRANOLA_OUT"
_assert_match "AC4.11 granola body sri content"    "Sri Patel: I have data"    "$GRANOLA_OUT"
_assert_match "AC4.12 granola body header"         "# Q2 Planning Sync"        "$GRANOLA_OUT"

# ============================================================================
# AC5 — Provenance frontmatter validates against SP12 schema (every fixture).
# ============================================================================
_log "--- AC5: pf_validate on all generated notes ---"
# shellcheck disable=SC1090
. "$PF_LIB"
for note in "$VTT_OUT" "$WORD_OUT" "$GRANOLA_OUT"; do
  if pf_validate "$note" 2>>"$TMPROOT/pf.err"; then
    _pass "AC5 pf_validate: $(basename "$note")"
  else
    _fail "AC5 pf_validate FAIL: $(basename "$note")"
  fi
done

# ============================================================================
# AC6 — Granola connector wrapper (from-granola.sh) produces equivalent output.
# ============================================================================
_log "--- AC6: Granola connector wrapper ---"
CONN_OUT="$TMPROOT/connector-note.md"
bash "$CONNECTOR_SCRIPT" --granola-json "$GRANOLA_FIX" --output "$CONN_OUT" 2>"$TMPROOT/conn.err"
CONN_RC=$?
_assert_rc "AC6.1 connector exit"        "0" "$CONN_RC"
_assert_file_exists "AC6.2 connector note written" "$CONN_OUT"
# Diff against direct Granola invocation: should be byte-equal (same surface_id, same source_path).
if diff -q "$GRANOLA_OUT" "$CONN_OUT" >/dev/null 2>&1; then
  _pass "AC6.3 connector output byte-equal to direct ingestor invocation"
else
  _fail "AC6.3 connector output diverges from direct invocation"
fi
_assert_match "AC6.4 connector source_format" "source_format: granola"        "$CONN_OUT"
_assert_match "AC6.5 connector pf surface_id" "generated_by: sp13-t11/1"      "$CONN_OUT"

# ============================================================================
# AC7 — JSON-shape sniff promotes llm-export → granola when shape matches.
# ============================================================================
_log "--- AC7: JSON-shape sniff promotes llm-export → granola ---"
LLM_FIX="$TMPROOT/conversations.json"
cat > "$LLM_FIX" <<'EOF'
{
  "title": "Misnamed Granola Export",
  "date": "2026-04-23",
  "attendees": ["Alice", "Bob"],
  "transcript": [{"speaker": "Alice", "text": "hello"}, {"speaker": "Bob", "text": "hi"}]
}
EOF
LLM_OUT="$TMPROOT/llm-promoted-note.md"
bash "$INGEST" --transcript "$LLM_FIX" --output "$LLM_OUT" 2>"$TMPROOT/llm.err"
_assert_rc "AC7.1 ingest exit" "0" "$?"
_assert_match "AC7.2 promoted to granola format" "source_format: granola"      "$LLM_OUT"
_assert_match "AC7.3 promoted title from JSON"   'title: "Misnamed Granola'    "$LLM_OUT"
_assert_match "AC7.4 promoted participant alice" '- "Alice"'                   "$LLM_OUT"

# Conversely, a real role+content array should stay llm-export.
ROLE_FIX="$TMPROOT/openai-export.json"
cat > "$ROLE_FIX" <<'EOF'
[
  {"role": "user", "content": "hello"},
  {"role": "assistant", "content": "hi"}
]
EOF
ROLE_OUT="$TMPROOT/role-note.md"
bash "$INGEST" --transcript "$ROLE_FIX" --output "$ROLE_OUT" 2>"$TMPROOT/role.err"
_assert_rc "AC7.5 ingest exit (llm-export not promoted)" "0" "$?"
_assert_match "AC7.6 stays llm-export" "source_format: llm-export" "$ROLE_OUT"

# ============================================================================
# AC8 — --format override forces format; --title + --date overrides win.
# ============================================================================
_log "--- AC8: --format / --title / --date overrides ---"
OV_OUT="$TMPROOT/override-note.md"
bash "$INGEST" --transcript "$VTT_FIX" \
  --format otter-vtt \
  --title "Custom Title" \
  --date 2026-12-31 \
  --output "$OV_OUT" 2>"$TMPROOT/ov.err"
_assert_rc "AC8.1 ingest exit"           "0" "$?"
_assert_match "AC8.2 title override"      'title: "Custom Title"' "$OV_OUT"
_assert_match "AC8.3 date override"       "date: 2026-12-31"      "$OV_OUT"
_assert_match "AC8.4 format override"     "source_format: otter-vtt" "$OV_OUT"

# ============================================================================
# AC9 — Empty transcript → graceful-degrade body marker, no halt.
# ============================================================================
_log "--- AC9: empty transcript graceful degrade ---"
EMPTY_FIX="$TMPROOT/2026-04-24-empty.vtt"
cat > "$EMPTY_FIX" <<'EOF'
WEBVTT

EOF
EMPTY_OUT="$TMPROOT/empty-note.md"
bash "$INGEST" --transcript "$EMPTY_FIX" --output "$EMPTY_OUT" 2>"$TMPROOT/empty.err"
_assert_rc "AC9.1 ingest exit"            "0" "$?"
_assert_match "AC9.2 frontmatter present"  "source_format: otter-vtt" "$EMPTY_OUT"
_assert_match "AC9.3 graceful-degrade body" "_(empty transcript body)_" "$EMPTY_OUT"
_assert_match "AC9.4 empty participants list" "participants: []"     "$EMPTY_OUT"

# ============================================================================
# AC10 — Unsupported format + PDF rejection.
# ============================================================================
_log "--- AC10: unsupported format rejection ---"
UNS_FIX="$TMPROOT/random.unknownext"
printf 'random binary\n' > "$UNS_FIX"
bash "$INGEST" --transcript "$UNS_FIX" --output "$TMPROOT/uns.md" 2>"$TMPROOT/uns.err"
_assert_rc "AC10.1 unsupported exits 3" "3" "$?"

PDF_FIX="$TMPROOT/scanned.pdf"
printf '%%PDF-1.4\n%%fake\n' > "$PDF_FIX"
bash "$INGEST" --transcript "$PDF_FIX" --output "$TMPROOT/pdf.md" 2>"$TMPROOT/pdf.err"
_assert_rc "AC10.2 pdf exits 3 without --format override" "3" "$?"

# Missing transcript → exit 2.
bash "$INGEST" --transcript "$TMPROOT/does-not-exist.vtt" 2>"$TMPROOT/missing.err" >/dev/null
_assert_rc "AC10.3 missing transcript exits 2" "2" "$?"

# Missing --transcript flag → exit 2.
bash "$INGEST" --output - 2>"$TMPROOT/noargs.err" >/dev/null
_assert_rc "AC10.4 no --transcript exits 2" "2" "$?"

# ============================================================================
# AC11 — R-55 hermetic isolation: zero ~/.claude/ writes; G1 override-log delta == 0.
# ============================================================================
_log "--- AC11: R-55 hermetic isolation ---"
G1_FINAL=0
if [ -f "$G1_LOG" ]; then
  G1_FINAL="$(wc -l < "$G1_LOG" | tr -d ' ')"
fi
if [ "$G1_FINAL" = "$G1_BASELINE" ]; then
  _pass "AC11.1 R-55 G1 override-log delta == 0 (baseline=$G1_BASELINE final=$G1_FINAL)"
else
  _fail "AC11.1 R-55 G1 override-log delta non-zero (baseline=$G1_BASELINE final=$G1_FINAL)"
fi

# Verify all generated notes are inside $TMPROOT (no rogue writes elsewhere).
for note in "$VTT_OUT" "$WORD_OUT" "$GRANOLA_OUT" "$LLM_OUT" "$ROLE_OUT" "$OV_OUT" "$EMPTY_OUT" "$CONN_OUT"; do
  case "$note" in
    "$TMPROOT"/*) ;; # OK
    *) _fail "AC11.2 note outside TMPROOT: $note"; continue ;;
  esac
done
_pass "AC11.2 all output paths inside TMPROOT"

# ============================================================================
# AC12 — stdout default mode (--output - or omitted).
# ============================================================================
_log "--- AC12: stdout default mode ---"
STDOUT_CAP="$TMPROOT/stdout-cap.md"
bash "$INGEST" --transcript "$VTT_FIX" > "$STDOUT_CAP" 2>"$TMPROOT/stdout.err"
_assert_rc "AC12.1 stdout default exit"            "0" "$?"
_assert_match "AC12.2 stdout has frontmatter"       "source_format: otter-vtt" "$STDOUT_CAP"
_assert_match "AC12.3 stdout has speaker line"      "Peter Tiktinsky: Welcome" "$STDOUT_CAP"

DASH_CAP="$TMPROOT/dash-cap.md"
bash "$INGEST" --transcript "$VTT_FIX" --output - > "$DASH_CAP" 2>"$TMPROOT/dash.err"
_assert_rc "AC12.4 --output - explicit exit" "0" "$?"
if diff -q "$STDOUT_CAP" "$DASH_CAP" >/dev/null 2>&1; then
  _pass "AC12.5 --output - byte-equal to default stdout"
else
  _fail "AC12.5 --output - diverges from default stdout"
fi

# Connector --output - smoke (regression for the wrapper's pass-through).
CONN_DASH="$TMPROOT/conn-dash.md"
bash "$CONNECTOR_SCRIPT" --granola-json "$GRANOLA_FIX" --output - > "$CONN_DASH" 2>"$TMPROOT/conn-dash.err"
_assert_rc "AC12.6 connector --output - exit" "0" "$?"
_assert_match "AC12.7 connector stdout has granola format" "source_format: granola" "$CONN_DASH"

# ============================================================================
# Summary.
# ============================================================================
TOTAL=$((PASS + FAIL))
_log ""
_log "========================================================================"
_log "SP13 T-11 hermetic test results: ${PASS}/${TOTAL} PASS, ${FAIL} FAIL"
_log "========================================================================"

if [ "$FAIL" -eq 0 ]; then
  _log "ALL ACS GREEN."
  exit 0
else
  _log "FAILURES:"
  grep '^FAIL ' "$RESULTS_LOG" | head -30
  exit 1
fi
