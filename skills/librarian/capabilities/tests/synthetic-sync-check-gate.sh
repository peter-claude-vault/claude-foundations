#!/bin/bash
# Synthetic test for sync-check.sh AC #5 — has_structured_projects gate.
#
# 2 cases:
#   1. has_structured_projects:false → checks 5-7 emit "skipped (ungated)" events
#   2. has_structured_projects:true  → checks 5-7 actually run (no skip events)
#
# Usage: bash synthetic-sync-check-gate.sh
# Exit:  0 on 2/2 pass, 1 otherwise.
#
# Bash 3.2 clean per R-23.

set -uo pipefail

CAP="$(cd "$(dirname "$0")/.." && pwd)/sync-check.sh"
TMP_DIR="$(mktemp -d -t sync-check-test-XXXXXX)"
TMP_VAULT="$TMP_DIR/vault"
TMP_MANIFEST="$TMP_DIR/user-manifest.json"
TMP_LIBRARIAN_MANIFEST="$TMP_DIR/librarian-manifest.json"

PASS=0
FAIL=0
TESTS=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_VAULT"
echo '{}' > "$TMP_LIBRARIAN_MANIFEST"

# -----------------------------------------------------------------------------
# Case 1: has_structured_projects:false → checks 5-7 skipped
# -----------------------------------------------------------------------------
TESTS=$((TESTS + 1))
cat > "$TMP_MANIFEST" <<JSON
{"vault": {"has_structured_projects": false}}
JSON

OUT=$(USER_MANIFEST_PATH="$TMP_MANIFEST" \
      VAULT_ROOT="$TMP_VAULT" \
      MANIFEST_PATH="$TMP_LIBRARIAN_MANIFEST" \
      bash "$CAP" --dry-run 2>/dev/null)

SKIP_VAULT_CMD=$(printf '%s\n' "$OUT" | grep -c '"event": "sync-check-vault-claude-md".*"status": "skipped (ungated)"')
SKIP_VAULT_ARCH=$(printf '%s\n' "$OUT" | grep -c '"event": "sync-check-vault-architecture".*"status": "skipped (ungated)"')
SKIP_ENG_STATUS=$(printf '%s\n' "$OUT" | grep -c '"event": "sync-check-engagement-status".*"status": "skipped (ungated)"')
SKIP_VAULT_CMD=${SKIP_VAULT_CMD:-0}
SKIP_VAULT_ARCH=${SKIP_VAULT_ARCH:-0}
SKIP_ENG_STATUS=${SKIP_ENG_STATUS:-0}

if [[ "$SKIP_VAULT_CMD" -ge 1 && "$SKIP_VAULT_ARCH" -ge 1 && "$SKIP_ENG_STATUS" -ge 1 ]]; then
  printf '  PASS  1. has_structured_projects=false: 3/3 gated checks emit skipped event\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL  1. has_structured_projects=false: skip-event counts vault-claude-md=%s vault-architecture=%s engagement-status=%s (each must be >=1)\n' \
    "$SKIP_VAULT_CMD" "$SKIP_VAULT_ARCH" "$SKIP_ENG_STATUS"
  FAIL=$((FAIL + 1))
  echo "--- output ---"
  printf '%s\n' "$OUT"
  echo "--- end ---"
fi

# -----------------------------------------------------------------------------
# Case 2: has_structured_projects:true → no skip events for gated checks
# -----------------------------------------------------------------------------
TESTS=$((TESTS + 1))
cat > "$TMP_MANIFEST" <<JSON
{"vault": {"has_structured_projects": true}}
JSON

OUT=$(USER_MANIFEST_PATH="$TMP_MANIFEST" \
      VAULT_ROOT="$TMP_VAULT" \
      MANIFEST_PATH="$TMP_LIBRARIAN_MANIFEST" \
      bash "$CAP" --dry-run 2>/dev/null)

SKIP_COUNT=$(printf '%s\n' "$OUT" | grep -c '"status": "skipped (ungated)"')
SKIP_COUNT=${SKIP_COUNT:-0}
if [[ "$SKIP_COUNT" -eq 0 ]]; then
  printf '  PASS  2. has_structured_projects=true: 0 skip events (gated checks run)\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL  2. has_structured_projects=true: expected 0 skip events, got %s\n' "$SKIP_COUNT"
  FAIL=$((FAIL + 1))
  echo "--- output ---"
  printf '%s\n' "$OUT"
  echo "--- end ---"
fi

printf '\nResults: %d/%d passed\n' "$PASS" "$TESTS"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
