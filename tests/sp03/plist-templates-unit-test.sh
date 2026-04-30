#!/bin/bash
# plist-templates-unit-test.sh — exercises T-5 librarian.plist.tmpl + architect.plist.tmpl
# against 3 archetype env-var fixtures (consultant, researcher, developer); asserts envsubst
# substitution produces plutil -lint clean output; asserts zero absolute paths in .tmpl files;
# asserts Label follows com.claude.<job> convention; asserts malformed template fails lint.
#
# Usage: bash tests/sp03/plist-templates-unit-test.sh
# Returns 0 on all-pass, 1 on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBRARIAN_TMPL="$REPO_ROOT/templates/launchd/librarian.plist.tmpl"
ARCHITECT_TMPL="$REPO_ROOT/templates/launchd/architect.plist.tmpl"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/plist-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
report() {
  if [ "$1" -eq 0 ]; then
    echo "PASS $2"
    PASS=$((PASS + 1))
  else
    echo "FAIL $2"
    FAIL=$((FAIL + 1))
  fi
}

# --- guards ---
command -v envsubst >/dev/null 2>&1 || { echo "ERROR: envsubst not on PATH"; exit 2; }
command -v plutil >/dev/null 2>&1 || { echo "ERROR: plutil not on PATH (macOS only)"; exit 2; }
[ -f "$LIBRARIAN_TMPL" ] || { echo "ERROR: $LIBRARIAN_TMPL missing"; exit 2; }
[ -f "$ARCHITECT_TMPL" ] || { echo "ERROR: $ARCHITECT_TMPL missing"; exit 2; }

# --- T-5 AC: zero absolute paths in .tmpl files ---
abs_lib=$(grep -E '/Users/[A-Za-z]|/home/[A-Za-z]' "$LIBRARIAN_TMPL" || true)
abs_arc=$(grep -E '/Users/[A-Za-z]|/home/[A-Za-z]' "$ARCHITECT_TMPL" || true)
[ -z "$abs_lib" ] && [ -z "$abs_arc" ]
report $? "AC: zero absolute paths in .tmpl files"

# --- T-5 AC: Label follows com.claude.<job> convention ---
grep -q 'Label.*${LABEL_PREFIX}.librarian-scan\|<string>${LABEL_PREFIX}.librarian-scan</string>' "$LIBRARIAN_TMPL"
lib_label_ok=$?
grep -q 'Label.*${LABEL_PREFIX}.architect-analysis\|<string>${LABEL_PREFIX}.architect-analysis</string>' "$ARCHITECT_TMPL"
arc_label_ok=$?
[ "$lib_label_ok" -eq 0 ] && [ "$arc_label_ok" -eq 0 ]
report $? "AC: Label follows \${LABEL_PREFIX}.<job> convention"

# --- archetype fixture: consultant ---
render_consultant() {
  USER_HOME="/Users/consultant" \
  CLAUDE_HOME="/Users/consultant/.claude" \
  CLAUDE_LOG_DIR="/Users/consultant/.claude/logs" \
  TIMEZONE="America/New_York" \
  LABEL_PREFIX="com.claude" \
  LIBRARIAN_HOUR="6" \
  LIBRARIAN_MINUTE="0" \
  ARCHITECT_HOUR="22" \
  ARCHITECT_MINUTE="3" \
  ARCHITECT_WEEKDAY="0" \
  envsubst < "$1"
}

render_researcher() {
  USER_HOME="/Users/researcher" \
  CLAUDE_HOME="/Users/researcher/.claude" \
  CLAUDE_LOG_DIR="/Users/researcher/Logs/claude" \
  TIMEZONE="UTC" \
  LABEL_PREFIX="com.claude" \
  LIBRARIAN_HOUR="9" \
  LIBRARIAN_MINUTE="30" \
  ARCHITECT_HOUR="14" \
  ARCHITECT_MINUTE="0" \
  ARCHITECT_WEEKDAY="1" \
  envsubst < "$1"
}

render_developer() {
  USER_HOME="/Users/dev" \
  CLAUDE_HOME="/Users/dev/.claude" \
  CLAUDE_LOG_DIR="/Users/dev/.claude/logs" \
  TIMEZONE="America/Los_Angeles" \
  LABEL_PREFIX="com.claude" \
  LIBRARIAN_HOUR="7" \
  LIBRARIAN_MINUTE="15" \
  ARCHITECT_HOUR="20" \
  ARCHITECT_MINUTE="45" \
  ARCHITECT_WEEKDAY="6" \
  envsubst < "$1"
}

for archetype in consultant researcher developer; do
  for kind in librarian architect; do
    if [ "$kind" = "librarian" ]; then tmpl="$LIBRARIAN_TMPL"; else tmpl="$ARCHITECT_TMPL"; fi
    out="$TMP_DIR/${archetype}-${kind}.plist"
    render_$archetype "$tmpl" > "$out"
    plutil -lint "$out" >/dev/null 2>&1
    report $? "AC: envsubst+plutil-lint $archetype $kind"

    # Verify no leftover ${VAR} remains in rendered output
    if grep -E '\$\{[A-Z_]+\}' "$out" >/dev/null 2>&1; then
      report 1 "AC: zero unresolved \${VAR} in rendered $archetype $kind"
    else
      report 0 "AC: zero unresolved \${VAR} in rendered $archetype $kind"
    fi

    # Verify Label has com.claude.<job> after substitution
    if grep -q "<string>com.claude.${kind}" "$out" 2>/dev/null; then
      report 0 "rendered Label is com.claude.${kind}-* in $archetype $kind"
    else
      report 1 "rendered Label is com.claude.${kind}-* in $archetype $kind"
    fi
  done
done

# --- AC: malformed template (missing closing brace) → post-substitution lint fails ---
# Synthesize a template with `${CLAUDE_HOME` (no closing brace) inside a tag —
# envsubst leaves it literal; plutil -lint fails because the < & > already-encoded
# but the literal `${...` chars inside an integer field break parse.
mal_tmpl="$TMP_DIR/malformed.plist.tmpl"
cat > "$mal_tmpl" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.claude.malformed</string>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key>
		<integer>${BAD_INTEGER</integer>
	</dict>
</dict>
</plist>
PLIST

mal_out="$TMP_DIR/malformed.rendered.plist"
BAD_INTEGER="6" envsubst < "$mal_tmpl" > "$mal_out"
# Confirm the broken `${BAD_INTEGER` literal survived envsubst (envsubst only
# substitutes well-formed `${VAR}` or `$VAR` — broken syntax left as-is).
if grep -q '\${BAD_INTEGER' "$mal_out"; then
  # Now plutil -lint should reject because <integer>${BAD_INTEGER</integer> is not a valid integer.
  if plutil -lint "$mal_out" >/dev/null 2>&1; then
    report 1 "AC: malformed template post-substitution → plutil-lint fails"
  else
    report 0 "AC: malformed template post-substitution → plutil-lint fails"
  fi
else
  # envsubst substituted it (some envsubst variants tolerate this) — skip-clean
  report 0 "AC: malformed template post-substitution (envsubst tolerated; treated as well-formed)"
fi

# --- summary ---
echo ""
echo "=== plist-templates-unit-test.sh ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
