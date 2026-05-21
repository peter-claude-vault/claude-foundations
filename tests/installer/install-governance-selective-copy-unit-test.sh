#!/bin/bash
# tests/installer/install-governance-selective-copy-unit-test.sh
#
# Synthetic unit test for SP18 T-2 — install.sh Step 8.5 selective-copy
# ship-surface reduction. Pre-SP18 Step 8.5 used blanket recursive cp -R; SP18
# replaced it with selective per-file/per-dir copy per packet 02 §"install.sh
# changes" L173-L221.
#
# Foundation pillars (the 7 *-rules.json + doc-dependencies.json source files
# in governance/) compose into foundation-master.json at foundation-repo
# release time via tools/build-foundation-master.sh. They are NOT load-bearing
# for runtime consumers post-SP16 union-read retrofit. Shipping pillars is a
# foundation-repo-specific authoring concern that adopter vaults should not
# carry. governance/_index.json is foundation-repo author convenience
# (operator-locked DO NOT SHIP per SP18 T-2 kickoff).
#
# Coverage:
#   T1: Fresh install — target artifacts ARE shipped:
#       - foundation-master.json
#       - overlay-master.json
#       - log-subtype-registry.json
#       - file-type-contracts/ (dir + entries)
#       - librarian-capabilities/ (dir + entries)
#       - onboarding-reference/ (dir + entries)
#   T2: Fresh install — pillar JSONs + _index.json + retired-marker files NOT shipped:
#       - frontmatter-rules.json, tagging-rules.json, naming-rules.json,
#         mandatory-files-rules.json, doc-dependencies.json, plans-rules.json,
#         vault-writers-rules.json (7 pillar JSONs)
#       - _index.json (operator-locked DO NOT SHIP)
#       - enforcement-map.schema.json.retired-* (retirement marker)
#   T3: archetype-consistency.md NOT present in shipped librarian-capabilities/
#       (deleted in SP18 T-2 per packet 03 cleanup item #9)
#   T4: install.sh exits 0 on fresh install (selective-copy step doesn't break
#       overall flow)
#
# Isolation: each test creates its own tmpdir CLAUDE_HOME; SOURCE_REPO points
# at the foundation-repo top. No mutation of live ~/.claude.
#
# R-23: bash 3.2 compat.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
USERBASE="$(python3 -m site --user-base 2>/dev/null || true)"

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
  d="$(mktemp -d -t governance-selective-copy-test.XXXXXX)"
  TMPDIRS="$TMPDIRS $d"
  printf '%s' "$d"
}

assert_eq() {
  expected="$1"; actual="$2"; label="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: expected=[%s] actual=[%s]\n' "$label" "$expected" "$actual" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_path_exists() {
  path="$1"; label="$2"
  if [ -e "$path" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: path does not exist [%s]\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_path_absent() {
  path="$1"; label="$2"
  if [ ! -e "$path" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: path UNEXPECTEDLY EXISTS [%s]\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

# --- prereq sanity ---
if [ ! -x "$INSTALL_SH" ]; then
  printf 'FATAL: install.sh not executable at %s\n' "$INSTALL_SH" >&2
  exit 7
fi
if [ ! -f "$REPO_ROOT/governance/foundation-master.json" ]; then
  printf 'FATAL: governance/foundation-master.json source missing\n' >&2
  exit 7
fi

printf '=== install-governance-selective-copy-unit-test ===\n'

# =====================================================================
# Fresh install
# =====================================================================
printf '\nFresh install for shared assertions (T1+T2+T3)\n'

CH1="$(mk_tmp)"
rc=0
HOME="$CH1" CLAUDE_HOME="$CH1" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply >"$CH1/.stdout" 2>"$CH1/.stderr" || rc=$?
assert_eq "0" "$rc" "T4.0 install.sh exits 0 on fresh install with SP18 selective copy"

# =====================================================================
# T1 — Target artifacts ARE shipped
# =====================================================================
printf '\nT1: Selective copy ships target artifacts\n'

assert_path_exists "$CH1/governance/foundation-master.json" "T1.1 foundation-master.json shipped"
assert_path_exists "$CH1/governance/overlay-master.json" "T1.2 overlay-master.json shipped"
assert_path_exists "$CH1/governance/log-subtype-registry.json" "T1.3 log-subtype-registry.json shipped"
assert_path_exists "$CH1/governance/file-type-contracts" "T1.4 file-type-contracts/ dir shipped"
assert_path_exists "$CH1/governance/file-type-contracts/_index.md.json" "T1.5 file-type-contracts/_index.md.json shipped"
assert_path_exists "$CH1/governance/librarian-capabilities" "T1.6 librarian-capabilities/ dir shipped"
assert_path_exists "$CH1/governance/librarian-capabilities/governance-parity-audit.md" "T1.7 librarian-capabilities/governance-parity-audit.md shipped"
assert_path_exists "$CH1/governance/onboarding-reference" "T1.8 onboarding-reference/ dir shipped"

# =====================================================================
# T2 — Pillar JSONs + _index.json NOT shipped
# =====================================================================
printf '\nT2: Pillar JSONs + _index.json stay foundation-repo only\n'

assert_path_absent "$CH1/governance/frontmatter-rules.json" "T2.1 frontmatter-rules.json NOT shipped (pillar)"
assert_path_absent "$CH1/governance/tagging-rules.json" "T2.2 tagging-rules.json NOT shipped (pillar)"
assert_path_absent "$CH1/governance/naming-rules.json" "T2.3 naming-rules.json NOT shipped (pillar)"
assert_path_absent "$CH1/governance/mandatory-files-rules.json" "T2.4 mandatory-files-rules.json NOT shipped (pillar)"
assert_path_absent "$CH1/governance/doc-dependencies.json" "T2.5 doc-dependencies.json NOT shipped (pillar)"
assert_path_absent "$CH1/governance/plans-rules.json" "T2.6 plans-rules.json NOT shipped (pillar)"
assert_path_absent "$CH1/governance/vault-writers-rules.json" "T2.7 vault-writers-rules.json NOT shipped (pillar)"
assert_path_absent "$CH1/governance/_index.json" "T2.8 _index.json NOT shipped (operator-locked)"

# Retired-marker file should not ship to adopter
for retired in "$CH1"/governance/enforcement-map.schema.json.retired-*; do
  if [ -e "$retired" ]; then
    assert_eq "absent" "present-at-$retired" "T2.9 retired-marker files NOT shipped"
  fi
done
# Positive form so PASS counter records the assertion when none are present:
RETIRED_GLOB_COUNT=0
for retired in "$CH1"/governance/enforcement-map.schema.json.retired-*; do
  [ -e "$retired" ] && RETIRED_GLOB_COUNT=$((RETIRED_GLOB_COUNT+1))
done
assert_eq "0" "$RETIRED_GLOB_COUNT" "T2.9 retired-marker files NOT shipped (count=0)"

# =====================================================================
# T3 — archetype-consistency.md retired (SP18 T-2 packet 03 #9)
# =====================================================================
printf '\nT3: archetype-consistency.md retired from librarian-capabilities/\n'

assert_path_absent "$CH1/governance/librarian-capabilities/archetype-consistency.md" "T3.1 archetype-consistency.md absent from shipped librarian-capabilities/"
assert_path_absent "$REPO_ROOT/governance/librarian-capabilities/archetype-consistency.md" "T3.2 archetype-consistency.md absent from foundation-repo source"

# =====================================================================
# Summary
# =====================================================================
printf '\n=== install-governance-selective-copy-unit-test ===\n'
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
