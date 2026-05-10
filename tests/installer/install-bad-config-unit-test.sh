#!/bin/bash
# tests/installer/install-bad-config-unit-test.sh
#
# Plan 81 SP01 Session 16 (T-28a deferral disposition): Step 13.6 jsonschema
# validation of foundation-shipped configs against companion schemas at
# $CLAUDE_HOME/schemas/. This test red-teams the happy-path by injecting a
# malformed config into a SOURCE_REPO copy, then asserts install.sh exits
# 30 (pre-allocated for "schema parse failure (post-install)") with the
# expected diagnostic on stderr.
#
# Hermetic: copies the foundation-repo to a tmpdir, mutates the config there,
# runs install.sh against the mutated SOURCE_REPO. Live foundation-repo and
# live $HOME/.claude untouched.
#
# Skipped (pass with notice) when the python3 jsonschema module is not
# available on the test machine — Step 13.6 graceful-skips in that case
# and exits 0, which is correct behavior but not testable here without
# the validator.
#
# R-23: bash 3.2 compat (macOS /bin/bash 3.2.57). No associative arrays.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"

# --- harness ---
PASS=0
FAIL=0
TMPDIRS=""

cleanup() {
  for d in $TMPDIRS; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM

mk_tmp() {
  local d
  d="$(mktemp -d -t install-bad-config.XXXXXX)"
  TMPDIRS="$TMPDIRS $d"
  printf '%s' "$d"
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: expected=%s actual=%s\n' "$label" "$expected" "$actual" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_grep() {
  local pattern="$1" file="$2" label="$3"
  if grep -q -- "$pattern" "$file" 2>/dev/null; then
    printf '  PASS %s (pattern: %s)\n' "$label" "$pattern"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (pattern not found: %s in %s)\n' "$label" "$pattern" "$file" >&2
    FAIL=$((FAIL+1))
  fi
}

# --- prereq sanity ---
if [ ! -x "$INSTALL_SH" ]; then
  printf 'FAIL: install.sh not executable at %s\n' "$INSTALL_SH" >&2
  exit 7
fi

# --- jsonschema availability gate ---
# Step 13.6 graceful-skips when jsonschema is unavailable. This test exercises
# the failure path, so it requires the module. Skip with a notice when absent.
if ! python3 -c "import jsonschema" 2>/dev/null; then
  printf 'SKIP: python3 jsonschema module not available; Step 13.6 graceful-skip\n'
  printf '       path is exercised by install-happy-path-unit-test.sh T1.30 instead.\n'
  printf '\n=== install-bad-config-unit-test ===\n'
  printf 'PASS: 0\n'
  printf 'FAIL: 0\n'
  printf 'SKIPPED (jsonschema unavailable)\n'
  exit 0
fi

# =====================================================================
# T1 — Malformed doc-dependencies.json (missing required "version") → exit 30
# =====================================================================
printf 'T1: Step 13.6 fires (exit 30) on malformed doc-dependencies.json\n'

# Hermetic SOURCE_REPO copy
SRC="$(mk_tmp)/foundation-repo"
mkdir -p "$SRC"
cp -R "$REPO_ROOT/." "$SRC/" 2>/dev/null || true

# Inject malformed config: drop the required "version" field
python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
doc.pop('version', None)
with open(sys.argv[1], 'w') as f:
    json.dump(doc, f, indent=2)
" "$SRC/hooks/config/doc-dependencies.json"

# Verify mutation took effect (defensive)
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if 'version' not in d else 1)" "$SRC/hooks/config/doc-dependencies.json"; then
  printf '  PASS T1.0: SOURCE_REPO mutation applied (version dropped)\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T1.0: SOURCE_REPO mutation did not take effect\n' >&2
  FAIL=$((FAIL+1))
  exit 1
fi

CH="$(mk_tmp)"
rc=0
# PYTHONUSERBASE forwarding so Step 13.6's `python3 -c "import jsonschema"`
# detects the user-site-installed module despite HOME isolation.
USERBASE="$(python3 -m site --user-base 2>/dev/null || true)"
HOME="$CH" CLAUDE_HOME="$CH" SOURCE_REPO="$SRC" PYTHONUSERBASE="$USERBASE" bash "$INSTALL_SH" --apply >"$CH/.stdout" 2>"$CH/.stderr" || rc=$?
assert_eq "30" "$rc" "T1.1: install.sh exits 30 on malformed config"

assert_grep "config schema validation failed" "$CH/.stderr" \
  "T1.2: Step 13.6 diagnostic emitted on stderr"

# =====================================================================
# T2 — Malformed cron-log-architecture-exceptions.json (exception missing
#       required "label" field) → exit 30
# =====================================================================
printf 'T2: Step 13.6 fires on malformed cron-log-architecture-exceptions.json\n'

SRC2="$(mk_tmp)/foundation-repo"
mkdir -p "$SRC2"
cp -R "$REPO_ROOT/." "$SRC2/" 2>/dev/null || true

# Inject an exception entry that lacks the required "label" field
python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
doc['exceptions'] = [{'reason': 'bogus entry without label'}]
with open(sys.argv[1], 'w') as f:
    json.dump(doc, f, indent=2)
" "$SRC2/hooks/config/cron-log-architecture-exceptions.json"

CH2="$(mk_tmp)"
rc=0
HOME="$CH2" CLAUDE_HOME="$CH2" SOURCE_REPO="$SRC2" PYTHONUSERBASE="$USERBASE" bash "$INSTALL_SH" --apply >"$CH2/.stdout" 2>"$CH2/.stderr" || rc=$?
assert_eq "30" "$rc" "T2.1: install.sh exits 30 on missing-required-field config"

assert_grep "config schema validation failed" "$CH2/.stderr" \
  "T2.2: Step 13.6 diagnostic emitted on stderr"

# =====================================================================
# Summary
# =====================================================================
printf '\n=== install-bad-config-unit-test ===\n'
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
