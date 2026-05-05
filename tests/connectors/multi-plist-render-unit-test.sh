#!/usr/bin/env bash
# tests/connectors/multi-plist-render-unit-test.sh — synthetic unit tests for SP14 T-2.
#
# Validates AC #1..#6 from
# ~/.claude-plans/71-claude-foundations-engine-v2/14-connector-wizard/tasks.md
# T-2 (multi-job launchd plist rendering):
#
#   AC1 — templates/launchd/ contains ≥7 plist templates (3 baseline + 5 new)
#   AC2 — install.sh references for_each_job (grep-positive)
#   AC3 — Synthetic 3-job fixture install produces 3 plists in $LAUNCHD_DIR
#   AC4 — Plist filenames follow com.<prefix>.<job-id>.plist pattern
#   AC5 — bash -n clean on install.sh, render-all-launchd.sh, render-launchd.sh
#   AC6 — render-launchd.sh handles new calendar (digest-run, meeting-processor)
#         and interval (chat-scrape, calendar-sync) shapes from orchestration.json
#
# Run: bash tests/connectors/multi-plist-render-unit-test.sh
# Exit: 0 on all-pass; 1 on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
RENDER="$REPO_ROOT/installer/render-launchd.sh"
RENDER_ALL="$REPO_ROOT/installer/render-all-launchd.sh"
ITERATOR="$REPO_ROOT/onboarding/lib/job-iterator.sh"
PATHS_SH="$REPO_ROOT/lib/paths.sh"
TEMPLATES_DIR="$REPO_ROOT/templates/launchd"

PASS=0; FAIL=0
check() {
  if [ "$1" = "$2" ]; then
    PASS=$((PASS+1)); echo "PASS $3"
  else
    FAIL=$((FAIL+1)); echo "FAIL $3 (got '$1' expected '$2')" >&2
  fi
}
truthy() {
  if [ -n "$1" ] && [ "$1" != "0" ]; then
    PASS=$((PASS+1)); echo "PASS $2"
  else
    FAIL=$((FAIL+1)); echo "FAIL $2 (value: '$1')" >&2
  fi
}

# --- AC5: bash -n on key files ---
bash -n "$INSTALL_SH"  && PASS=$((PASS+1)) && echo "PASS AC5: install.sh bash -n"  || { FAIL=$((FAIL+1)); echo "FAIL AC5: install.sh bash -n"; }
bash -n "$RENDER"      && PASS=$((PASS+1)) && echo "PASS AC5: render-launchd.sh bash -n" || { FAIL=$((FAIL+1)); echo "FAIL AC5: render-launchd.sh bash -n"; }
bash -n "$RENDER_ALL"  && PASS=$((PASS+1)) && echo "PASS AC5: render-all-launchd.sh bash -n" || { FAIL=$((FAIL+1)); echo "FAIL AC5: render-all-launchd.sh bash -n"; }

# --- AC1: ≥7 templates ---
template_count=$(ls "$TEMPLATES_DIR"/*.plist.tmpl 2>/dev/null | wc -l | tr -d ' ')
if [ "$template_count" -ge 7 ]; then
  PASS=$((PASS+1)); echo "PASS AC1: $template_count templates (≥7 required)"
else
  FAIL=$((FAIL+1)); echo "FAIL AC1: only $template_count templates"
fi

# Verify each of the 5 new templates exists by name
for tmpl in digest-run chat-scrape calendar-sync meeting-processor connector-runtime; do
  if [ -r "$TEMPLATES_DIR/$tmpl.plist.tmpl" ]; then
    PASS=$((PASS+1)); echo "PASS AC1: template $tmpl.plist.tmpl present"
  else
    FAIL=$((FAIL+1)); echo "FAIL AC1: missing template $tmpl.plist.tmpl"
  fi
done

# --- AC2: install.sh references for_each_job ---
if grep -q 'for_each_job' "$INSTALL_SH"; then
  PASS=$((PASS+1)); echo "PASS AC2: install.sh references for_each_job"
else
  FAIL=$((FAIL+1)); echo "FAIL AC2: install.sh missing for_each_job reference"
fi

# --- Setup synthetic CLAUDE_HOME with paths.sh ---
TMPDIR="$(mktemp -d -t sp14-multi-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

CH="$TMPDIR/claude-home"
LD="$TMPDIR/launchd"
mkdir -p "$CH/hooks/lib" "$CH/logs" "$LD"
cp "$PATHS_SH" "$CH/hooks/lib/paths.sh"

# 3-job orchestration.json: librarian (calendar) + digest-run (calendar) + chat-scrape (interval)
cat > "$TMPDIR/orchestration.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "platform": "darwin-launchd",
  "jobs": [
    {"id": "librarian", "enabled": true,
     "schedule": {"hour": 6, "minute": 0},
     "command": "/test/librarian-cron.sh",
     "log_path": "/tmp/lib.log",
     "idle_watchdog_sec": 180},
    {"id": "digest-run", "enabled": true,
     "schedule": {"hour": 7, "minute": 30},
     "command": "/test/digest-run-cron.sh",
     "log_path": "/tmp/digest.log",
     "idle_watchdog_sec": 180},
    {"id": "chat-scrape", "enabled": true,
     "schedule": {"interval_sec": 1800},
     "command": "/test/chat-scrape-cron.sh",
     "log_path": "/tmp/chat.log",
     "idle_watchdog_sec": 180}
  ],
  "tripwires": [],
  "observability": {"log_dir": "/tmp"}
}
JSON

export CLAUDE_HOME="$CH"
export ORCHESTRATION_JSON="$TMPDIR/orchestration.json"
export LABEL_PREFIX="com.claude-stem-test"
unset INBOX_POLL_INTERVAL_SEC

# --- AC3: Run render-all-launchd.sh against 3-job fixture ---
RENDER_LOG="$TMPDIR/render.log"
if bash "$RENDER_ALL" --staging-dir "$LD" >"$RENDER_LOG" 2>&1; then
  PASS=$((PASS+1)); echo "PASS AC3: render-all-launchd.sh rc=0 on 3-job fixture"
else
  FAIL=$((FAIL+1)); echo "FAIL AC3: render-all-launchd.sh non-zero rc on 3-job fixture"
  cat "$RENDER_LOG" >&2
fi

# Count plists landed in staging dir
plist_count=$(ls "$LD"/*.plist 2>/dev/null | wc -l | tr -d ' ')
check "$plist_count" "3" "AC3: exactly 3 plists landed in \$LAUNCHD_DIR"

# --- AC4: filename pattern com.<prefix>.<job-id>.plist ---
for expected_label in librarian-scan digest-run chat-scrape; do
  expected="$LD/com.claude-stem-test.${expected_label}.plist"
  if [ -r "$expected" ]; then
    PASS=$((PASS+1)); echo "PASS AC4: $(basename "$expected") present"
  else
    FAIL=$((FAIL+1)); echo "FAIL AC4: missing $(basename "$expected")"
  fi
done

# --- AC6: rendered plists pass plutil -lint ---
for plist in "$LD"/*.plist; do
  if plutil -lint -s "$plist" >/dev/null 2>&1; then
    PASS=$((PASS+1)); echo "PASS AC6: $(basename "$plist") plutil-clean"
  else
    FAIL=$((FAIL+1)); echo "FAIL AC6: $(basename "$plist") failed plutil -lint"
  fi
done

# Verify calendar shape vs interval shape rendered correctly
if grep -q 'StartCalendarInterval' "$LD/com.claude-stem-test.librarian-scan.plist" 2>/dev/null; then
  PASS=$((PASS+1)); echo "PASS AC6: librarian → StartCalendarInterval"
else
  FAIL=$((FAIL+1)); echo "FAIL AC6: librarian missing StartCalendarInterval"
fi
if grep -q 'StartCalendarInterval' "$LD/com.claude-stem-test.digest-run.plist" 2>/dev/null; then
  PASS=$((PASS+1)); echo "PASS AC6: digest-run → StartCalendarInterval"
else
  FAIL=$((FAIL+1)); echo "FAIL AC6: digest-run missing StartCalendarInterval"
fi
if grep -q 'StartInterval' "$LD/com.claude-stem-test.chat-scrape.plist" 2>/dev/null; then
  PASS=$((PASS+1)); echo "PASS AC6: chat-scrape → StartInterval"
else
  FAIL=$((FAIL+1)); echo "FAIL AC6: chat-scrape missing StartInterval"
fi

# --- bonus: regression test — single-job librarian render still works ---
LD2="$TMPDIR/launchd-1job"
mkdir -p "$LD2"
if bash "$RENDER" --staging-dir "$LD2" librarian >/dev/null 2>&1; then
  PASS=$((PASS+1)); echo "PASS regression: render-launchd.sh librarian (single) rc=0"
else
  FAIL=$((FAIL+1)); echo "FAIL regression: render-launchd.sh librarian rc!=0"
fi

echo
echo "==========================="
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] && exit 0 || exit 1
