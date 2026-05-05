#!/bin/bash
# tests/installer/install-happy-path-unit-test.sh
#
# Synthetic unit test for SP08 T-1 slice (S59):
#   - 14-asset write-sequence lands all expected paths under hermetic CLAUDE_HOME
#   - LABEL_PREFIX=com.claude-stem preserved through cp -R installer/
#   - settings.json atomic jq-merge happy-path
#   - settings.json G7 silent-key-deletion red-team → exit 57
#   - CLAUDE_HOME unset → exit 10
#   - SOURCE_REPO not a foundation-repo → exit 10
#   - Provenance log header written under $CLAUDE_HOME/logs/
#
# Hermetic: each test creates its own tmpdir CLAUDE_HOME; SOURCE_REPO points
# at the foundation-repo top. No mutation of live ~/.claude.
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
  d="$(mktemp -d -t install-test.XXXXXX)"
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

assert_path_exists() {
  local path="$1" label="$2"
  if [ -e "$path" ]; then
    printf '  PASS %s (path exists: %s)\n' "$label" "$path"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (path missing: %s)\n' "$label" "$path" >&2
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

# =====================================================================
# T1 — Happy path: fresh install, 14-asset write-sequence
# =====================================================================
printf 'T1: fresh install happy-path 14-asset write-sequence\n'

CH="$(mk_tmp)"
rc=0
# HOME isolation: G5 (S65) walks $PLANS_HOME=$HOME/.claude-plans for NN-*/ entries.
# Set HOME to test tmpdir so PLANS_HOME resolves to an empty path.
HOME="$CH" CLAUDE_HOME="$CH" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" --apply >"$CH/.stdout" 2>"$CH/.stderr" || rc=$?
assert_eq "0" "$rc" "T1: install.sh exits 0"

# 14 asset categories:
assert_path_exists "$CH/hooks/pre-write-guard.sh"            "T1.1: hooks/ landed (pre-write-guard.sh)"
assert_path_exists "$CH/hooks/lib/paths.sh"                  "T1.2: hooks/lib/ translation landed (paths.sh)"
assert_path_exists "$CH/hooks/lib/lockf.sh"                  "T1.3: hooks/lib/lockf.sh landed"
assert_path_exists "$CH/hooks/config/doc-dependencies.json"  "T1.4: hooks/config/ landed"
assert_path_exists "$CH/skills/librarian"                    "T1.5: skills/librarian/ landed"
assert_path_exists "$CH/skills/architect"                    "T1.6: skills/architect/ landed"
assert_path_exists "$CH/skills/morning-brief"                "T1.7: skills/morning-brief/ landed"
assert_path_exists "$CH/onboarding/SKILL.md"                 "T1.8: onboarding/ landed"
assert_path_exists "$CH/orchestrator/dispatch.sh"            "T1.9: orchestrator/ landed"
assert_path_exists "$CH/orchestrator/job-runner.sh"          "T1.10: orchestrator/job-runner.sh landed"
assert_path_exists "$CH/installer/render-launchd.sh"         "T1.11: installer/render-launchd.sh landed"
assert_path_exists "$CH/installer/bootout-launchd.sh"        "T1.12: installer/bootout-launchd.sh landed"
assert_path_exists "$CH/templates/settings.json"             "T1.13: templates/settings.json landed"
assert_path_exists "$CH/templates/launchd/librarian.plist.tmpl" "T1.14: templates/launchd/ landed"
assert_path_exists "$CH/templates/launchd/architect.plist.tmpl" "T1.15: templates/launchd/architect.plist.tmpl landed"
assert_path_exists "$CH/templates/settings-fragments"        "T1.16: templates/settings-fragments/ landed"
assert_path_exists "$CH/Library/LaunchAgents.staging"        "T1.17: Library/LaunchAgents.staging/ created"
assert_path_exists "$CH/settings.json"                       "T1.18: settings.json merged from template"

# All 6 schemas present
for s in vault-schema plans-schema plan-manifest-schema librarian-manifest-schema user-manifest-schema orchestration-schema; do
  assert_path_exists "$CH/schemas/$s.json" "T1.19: schemas/$s.json landed"
done

# Provenance log
prov_count="$(ls "$CH/logs"/install-*.log 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "1" "$prov_count" "T1.20: provenance log written under logs/"

# SP10 T-4 + SP11 T-1/T-2: CLAUDE.md spine + memory bootstrap templates ship
assert_path_exists "$CH/templates/vault-claude-md-template.md" \
  "T1.21: templates/vault-claude-md-template.md landed (SP10 T-4)"
assert_path_exists "$CH/templates/claude-home-claude-md-template.md" \
  "T1.22: templates/claude-home-claude-md-template.md landed (SP10 T-4)"
assert_path_exists "$CH/templates/MEMORY.md.template" \
  "T1.23: templates/MEMORY.md.template landed (SP11 T-1)"

# SP10 T-4: $CLAUDE_HOME/CLAUDE.md seeded from template (identity placeholders OK
# in fresh install — onboarder + post-install --force seed substitutes them)
assert_path_exists "$CH/CLAUDE.md" \
  "T1.24: \$CLAUDE_HOME/CLAUDE.md seeded from template (SP10 T-4)"

# SP11 T-2: Auto Memory section reaches seeded CLAUDE.md
assert_grep '## Auto Memory' "$CH/CLAUDE.md" \
  "T1.25: seeded CLAUDE.md contains ## Auto Memory section (SP11 T-2)"
assert_grep 'Memory Search Strategy' "$CH/CLAUDE.md" \
  "T1.26: seeded CLAUDE.md contains Memory Search Strategy (SP11 T-2)"

# SP11 T-1: MEMORY.md skeleton seeded under projects/<slug>/memory/
mem_slug="$(printf '%s' "$CH" | tr '/' '-' | sed 's/^-//')"
assert_path_exists "$CH/projects/$mem_slug/memory/MEMORY.md" \
  "T1.27: \$CLAUDE_HOME/projects/<slug>/memory/MEMORY.md seeded (SP11 T-1)"
mem_h2_count="$(grep -c '^## ' "$CH/projects/$mem_slug/memory/MEMORY.md" 2>/dev/null || echo 0)"
assert_eq "4" "$mem_h2_count" "T1.28: seeded MEMORY.md has 4 H2 section headers (User/Feedback/Project/Reference)"

# =====================================================================
# T2 — LABEL_PREFIX preservation (G6)
# =====================================================================
printf 'T2: LABEL_PREFIX=com.claude-stem preserved through cp -R installer/\n'

assert_grep 'LABEL_PREFIX:-com.claude-stem' \
  "$CH/installer/render-launchd.sh" \
  "T2.1: render-launchd.sh ships com.claude-stem LABEL_PREFIX default"

assert_grep 'com.claude-stem' \
  "$CH/installer/bootout-launchd.sh" \
  "T2.2: bootout-launchd.sh enforces com.claude-stem namespace"

# =====================================================================
# T3 — settings.json fresh install equals template
# =====================================================================
printf 'T3: settings.json fresh install matches template byte-identical\n'

if diff -q "$CH/templates/settings.json" "$CH/settings.json" >/dev/null 2>&1; then
  printf '  PASS T3.1: fresh-install settings.json equals template\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T3.1: fresh-install settings.json differs from template\n' >&2
  FAIL=$((FAIL+1))
fi

# =====================================================================
# T4 — settings.json atomic merge with user pre-existing keys
# =====================================================================
printf 'T4: settings.json merge preserves pre-existing user keys\n'

CH2="$(mk_tmp)"
mkdir -p "$CH2"
# Pre-seed user settings.json with extra top-level key
cat > "$CH2/settings.json" <<'JSON'
{
  "userCustom": {
    "preserveMe": true,
    "nested": { "deepKey": "value" }
  },
  "statusLine": {
    "type": "command",
    "command": "/usr/local/bin/my-statusline.sh"
  }
}
JSON
rc=0
# HOME isolation (G5) + --backup-dir (G3) — settings.json pre-exists, so G3 fires.
T4_BACKUP="$CH2/.backup"
HOME="$CH2" CLAUDE_HOME="$CH2" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" \
  --backup-dir "$T4_BACKUP" --apply >"$CH2/.stdout" 2>"$CH2/.stderr" || rc=$?
assert_eq "0" "$rc" "T4.1: install.sh succeeds when target settings.json pre-exists"

# User key preserved
preserved="$(jq -r '.userCustom.preserveMe' "$CH2/settings.json" 2>/dev/null)"
assert_eq "true" "$preserved" "T4.2: userCustom.preserveMe preserved through merge"

deep="$(jq -r '.userCustom.nested.deepKey' "$CH2/settings.json" 2>/dev/null)"
assert_eq "value" "$deep" "T4.3: userCustom.nested.deepKey preserved (recursive merge)"

# User wins on scalar conflict (statusLine.command set by user, not template)
user_statusline="$(jq -r '.statusLine.command' "$CH2/settings.json" 2>/dev/null)"
assert_eq "/usr/local/bin/my-statusline.sh" "$user_statusline" "T4.4: user's statusLine.command wins over template's (user-edits respected)"

# Template hooks still merged in (added new key)
hooks_present="$(jq -r 'has("hooks")' "$CH2/settings.json" 2>/dev/null)"
assert_eq "true" "$hooks_present" "T4.5: template's hooks block merged into existing settings.json"

# =====================================================================
# T5 — G7 silent-key-deletion gate
# =====================================================================
printf 'T5: G7 fires when merge would delete user keys (synthetic)\n'

# Synthesize a merge where the existing settings.json has a path that the
# template lacks AND the merge result drops it. We simulate this by
# monkey-patching jq via PATH shim that returns malformed merged output
# (missing the user's key). Implementation: wrap install.sh in a fake
# directory that ships a `jq` shim returning empty merge output.
CH3="$(mk_tmp)"
SHIM_DIR="$(mk_tmp)"
mkdir -p "$CH3" "$SHIM_DIR"

cat > "$CH3/settings.json" <<'JSON'
{
  "doomedUserKey": {
    "willBeDropped": true,
    "deepDoomed": "byTemplate"
  }
}
JSON

# jq shim that drops doomedUserKey on the slurp-merge call but passes through
# `[paths(scalars,arrays)] | sort | unique[]` with correct semantics so the
# G7 path-diff check actually detects the deletion.
cat > "$SHIM_DIR/jq" <<JQSHIM
#!/bin/bash
# Test shim — only on PATH for this test invocation.
REAL_JQ="$(command -v jq)"
# If asked to slurp-merge two files with the .[0] * .[1] expression,
# emit a doctored output that drops doomedUserKey from the user side.
if [ "\$1" = "-s" ] && [ "\$2" = ".[0] * .[1]" ]; then
  # \$3 is template settings, \$4 is user settings — emit template only,
  # silently dropping user keys (the exact failure mode G7 must catch).
  cat "\$3"
  exit 0
fi
exec "\$REAL_JQ" "\$@"
JQSHIM
chmod +x "$SHIM_DIR/jq"

rc=0
T5_BACKUP="$CH3/.backup"
PATH="$SHIM_DIR:$PATH" HOME="$CH3" CLAUDE_HOME="$CH3" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --backup-dir "$T5_BACKUP" --apply >"$CH3/.stdout" 2>"$CH3/.stderr" || rc=$?
assert_eq "57" "$rc" "T5.1: G7 fires (exit 57) on silent key deletion"

# Diagnostic message present on stderr
if grep -q "G7 fired: settings.json merge would silently delete" "$CH3/.stderr"; then
  printf '  PASS T5.2: G7 diagnostic emitted on stderr\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T5.2: G7 diagnostic missing from stderr\n' >&2
  cat "$CH3/.stderr" >&2
  FAIL=$((FAIL+1))
fi

# Existing settings.json NOT clobbered (atomic mv didn't fire)
post_doomed="$(jq -r '.doomedUserKey.willBeDropped' "$CH3/settings.json" 2>/dev/null)"
assert_eq "true" "$post_doomed" "T5.3: original settings.json preserved on G7 fire (no atomic mv)"

# =====================================================================
# T6 — CLAUDE_HOME unset → exit 10
# =====================================================================
printf 'T6: G1-pre lite — CLAUDE_HOME unset → exit 10\n'

# Use env -i to scrub all env vars, then restore PATH/HOME so the script
# can find binaries but CLAUDE_HOME genuinely unset.
CH6="$(mk_tmp)"
rc=0
env -i HOME="$HOME" PATH="$PATH" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" >"$CH6/.stdout" 2>"$CH6/.stderr" || rc=$?
assert_eq "10" "$rc" "T6.1: CLAUDE_HOME unset → exit 10"

if grep -q "CLAUDE_HOME not set" "$CH6/.stderr"; then
  printf '  PASS T6.2: CLAUDE_HOME-unset diagnostic emitted\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T6.2: diagnostic missing\n' >&2
  FAIL=$((FAIL+1))
fi

# =====================================================================
# T7 — SOURCE_REPO not a foundation-repo → exit 10
# =====================================================================
printf 'T7: SOURCE_REPO without hooks/skills/schemas → exit 10\n'

CH7="$(mk_tmp)"
FAKE_SRC="$(mk_tmp)"
# FAKE_SRC has nothing in it; install.sh should refuse.
rc=0
CLAUDE_HOME="$CH7" SOURCE_REPO="$FAKE_SRC" bash "$INSTALL_SH" \
  >"$CH7/.stdout" 2>"$CH7/.stderr" || rc=$?
assert_eq "10" "$rc" "T7.1: invalid SOURCE_REPO → exit 10"

if grep -q "SOURCE_REPO does not look like a foundation-repo" "$CH7/.stderr"; then
  printf '  PASS T7.2: invalid-SOURCE_REPO diagnostic emitted\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T7.2: diagnostic missing\n' >&2
  FAIL=$((FAIL+1))
fi

# =====================================================================
# T8 — Provenance log content (G10 emit)
# =====================================================================
printf 'T8: provenance log header content\n'

prov="$(ls "$CH/logs"/install-*.log 2>/dev/null | head -1)"
if [ -n "$prov" ] && [ -f "$prov" ]; then
  assert_grep "Plan 71 SP08 T-1 slice" "$prov" "T8.1: provenance header tags slice"
  assert_grep "CLAUDE_HOME: $CH"       "$prov" "T8.2: CLAUDE_HOME recorded"
  assert_grep "SOURCE_REPO: $REPO_ROOT" "$prov" "T8.3: SOURCE_REPO recorded"
  assert_grep "install.sh sha256:"     "$prov" "T8.4: install.sh sha256 recorded"
  assert_grep "deferred:"              "$prov" "T8.5: deferred-scope marker recorded"
else
  printf '  FAIL T8: no provenance log found\n' >&2
  FAIL=$((FAIL+1))
fi

# =====================================================================
# Summary
# =====================================================================
printf '\n=== install-happy-path-unit-test ===\n'
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
