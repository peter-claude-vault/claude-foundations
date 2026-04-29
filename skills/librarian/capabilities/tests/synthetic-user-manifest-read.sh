#!/bin/bash
# Synthetic test for lib/user-manifest-read.sh — Plan 71 SP04 T-9b.
#
# 4 cases (graceful-degrade contract per helper Output Contract):
#   1. present-fixture        → all 5 target fields extract correctly
#                               (4 of T-9b + transcript_dir scalar of T-4 c5)
#   2. missing-manifest       → array empty, object "{}", string ""
#   3. malformed-json         → array empty, object "{}", string ""
#   4. empty-manifest         → array empty, object "{}", string "" (well-
#                               formed JSON, missing fields)
#
# Usage: bash synthetic-user-manifest-read.sh
# Exit:  0 on all-pass, 1 otherwise.
#
# Bash 3.2 clean per R-23.

set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/user-manifest-read.sh"

# shellcheck source=/dev/null
source "$LIB"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $(printf %q "$expected")"
    echo "  actual:   $(printf %q "$actual")"
    FAIL=$((FAIL + 1))
  fi
}

# --- Case 1: present-fixture ---
TMPDIR_C1="$(mktemp -d -t umr-test-c1-XXXXXX)"
cat > "$TMPDIR_C1/user-manifest.json" <<'JSON'
{
  "vault": {
    "logs_whitelist_subdirs": ["build/", "ideation-brief/"],
    "tag_audit_exemptions": ["scratch/", "drafts/"],
    "engagement_aliases": {"acme-corp": "acme", "northwind": "nw"},
    "transcript_dir": "/tmp/synthetic-transcripts"
  },
  "system": {
    "backup_targets": ["/srv/extra-repo", "/srv/another-repo"]
  }
}
JSON

export UMR_USER_MANIFEST_PATH="$TMPDIR_C1/user-manifest.json"

c1_backup=$(umr_get_array '.system.backup_targets' | tr '\n' '|')
assert_eq "c1-backup-targets" "$c1_backup" "/srv/extra-repo|/srv/another-repo|"

c1_logs=$(umr_get_array '.vault.logs_whitelist_subdirs' | tr '\n' '|')
assert_eq "c1-logs-whitelist" "$c1_logs" "build/|ideation-brief/|"

c1_exempt=$(umr_get_array '.vault.tag_audit_exemptions' | tr '\n' '|')
assert_eq "c1-tag-exemptions" "$c1_exempt" "scratch/|drafts/|"

c1_aliases=$(umr_get_object '.vault.engagement_aliases')
case "$c1_aliases" in
  *'"acme-corp":"acme"'*'"northwind":"nw"'*)
    echo "PASS: c1-engagement-aliases"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "FAIL: c1-engagement-aliases"
    echo "  got: $c1_aliases"
    FAIL=$((FAIL + 1))
    ;;
esac

c1_transcripts=$(umr_get_string '.vault.transcript_dir')
assert_eq "c1-transcript-dir" "$c1_transcripts" "/tmp/synthetic-transcripts"

unset UMR_USER_MANIFEST_PATH
rm -rf "$TMPDIR_C1"

# --- Case 2: missing-manifest ---
export UMR_USER_MANIFEST_PATH="/nonexistent/path/user-manifest.json"

c2_backup=$(umr_get_array '.system.backup_targets')
assert_eq "c2-missing-array-empty" "$c2_backup" ""

c2_aliases=$(umr_get_object '.vault.engagement_aliases')
assert_eq "c2-missing-object-default" "$c2_aliases" "{}"

c2_transcripts=$(umr_get_string '.vault.transcript_dir')
assert_eq "c2-missing-string-empty" "$c2_transcripts" ""

unset UMR_USER_MANIFEST_PATH

# --- Case 3: malformed-json ---
TMPDIR_C3="$(mktemp -d -t umr-test-c3-XXXXXX)"
echo "{ broken json {{" > "$TMPDIR_C3/user-manifest.json"
export UMR_USER_MANIFEST_PATH="$TMPDIR_C3/user-manifest.json"

c3_backup=$(umr_get_array '.system.backup_targets')
assert_eq "c3-malformed-array-empty" "$c3_backup" ""

c3_aliases=$(umr_get_object '.vault.engagement_aliases')
assert_eq "c3-malformed-object-default" "$c3_aliases" "{}"

c3_transcripts=$(umr_get_string '.vault.transcript_dir')
assert_eq "c3-malformed-string-empty" "$c3_transcripts" ""

unset UMR_USER_MANIFEST_PATH
rm -rf "$TMPDIR_C3"

# --- Case 4: empty-manifest (well-formed but missing fields) ---
TMPDIR_C4="$(mktemp -d -t umr-test-c4-XXXXXX)"
echo "{}" > "$TMPDIR_C4/user-manifest.json"
export UMR_USER_MANIFEST_PATH="$TMPDIR_C4/user-manifest.json"

c4_backup=$(umr_get_array '.system.backup_targets')
assert_eq "c4-empty-array-empty" "$c4_backup" ""

c4_aliases=$(umr_get_object '.vault.engagement_aliases')
assert_eq "c4-empty-object-default" "$c4_aliases" "{}"

c4_transcripts=$(umr_get_string '.vault.transcript_dir')
assert_eq "c4-empty-string-empty" "$c4_transcripts" ""

unset UMR_USER_MANIFEST_PATH
rm -rf "$TMPDIR_C4"

# --- Summary ---
echo
TOTAL=$((PASS + FAIL))
if [[ $FAIL -gt 0 ]]; then
  echo "synthetic-user-manifest-read: $PASS/$TOTAL pass ($FAIL fail)"
  exit 1
else
  echo "synthetic-user-manifest-read: $PASS/$TOTAL pass"
  exit 0
fi
