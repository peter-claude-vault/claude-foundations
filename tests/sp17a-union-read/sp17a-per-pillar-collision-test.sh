#!/usr/bin/env bash
# SP17a T-4 — per-pillar R-52 collision walk unit test (AC-2, AC-3, AC-4)
#
# Verifies the helper at lib/foundation-overlay-load.sh:
#   - Walks ALL 8 pillars by default (not just .frontmatter.types as in spike)
#   - Detects collisions in non-frontmatter pillars (naming.rules, tagging.rules,
#     mandatory_files.rules, doc_dependencies.entries, file_type_contracts.*, ...)
#   - Honors shape-bridge: per-entry _override_reason OR top-level override_reasons
#   - --collision-pillars flag narrows the walk (operator can opt out per-pillar)
#   - --force-override bypasses entire walk (preserved from SP16)
#
# Scope: bash 3.2 compatible; mktemp-jailed fixtures; zero ~/.claude/ writes.

set -u

FOUNDATION_REPO="${FOUNDATION_REPO:-$HOME/Code/claude-stem}"
HELPER="$FOUNDATION_REPO/lib/foundation-overlay-load.sh"
[ -x "$HELPER" ] || { printf 'FATAL: helper not executable: %s\n' "$HELPER" >&2; exit 2; }

TEMPROOT="$(mktemp -d -t sp17a-perpillar.XXXXXX)" || exit 2
trap 'rm -rf "$TEMPROOT"' EXIT

PASS=0
FAIL=0

run_helper() {
  # args: foundation-json overlay-json [extra-helper-args...]
  local fjson="$1" ojson="$2"; shift 2
  printf '%s' "$fjson" > "$TEMPROOT/foundation.json"
  printf '%s' "$ojson" > "$TEMPROOT/overlay.json"
  "$HELPER" \
    --foundation-path "$TEMPROOT/foundation.json" \
    --overlay-path "$TEMPROOT/overlay.json" \
    "$@" >"$TEMPROOT/stdout.txt" 2>"$TEMPROOT/stderr.txt"
  echo $?
}

assert_rc() {
  local label="$1" exp="$2" got="$3"
  if [ "$exp" = "$got" ]; then
    printf '  PASS: %s (rc=%s)\n' "$label" "$got"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s (expected rc=%s, got rc=%s)\n' "$label" "$exp" "$got"
    printf '    stderr=%s\n' "$(cat "$TEMPROOT/stderr.txt")"
    FAIL=$((FAIL + 1))
  fi
}

assert_stderr_contains() {
  local label="$1" needle="$2"
  if grep -qF -- "$needle" "$TEMPROOT/stderr.txt" 2>/dev/null; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s (needle: %s)\n' "$label" "$needle"
    printf '    stderr=%s\n' "$(cat "$TEMPROOT/stderr.txt")"
    FAIL=$((FAIL + 1))
  fi
}

# ---- Scenario 1: naming.rules collision DENY (no override) ----
printf '\n--- (1) naming.rules.R-04 collision → DENY (default all-pillars walk) ---\n'
FOUND_1='{"naming":{"rules":{"R-04":{"text":"foundation R-04 text"}}}}'
OVER_1='{"naming":{"rules":{"R-04":{"text":"overlay R-04 text"}}}}'
rc=$(run_helper "$FOUND_1" "$OVER_1")
assert_rc "non-frontmatter pillar collision rejected" "1" "$rc"
assert_stderr_contains "DENIED_KEYS path naming.rules.R-04" "naming.rules.R-04"

# ---- Scenario 2: same collision with per-entry _override_reason → PERMIT ----
printf '\n--- (2) naming.rules.R-04 collision WITH per-entry _override_reason → PERMIT ---\n'
OVER_2='{"naming":{"rules":{"R-04":{"text":"overlay R-04 text","_override_reason":"adopter-extended R-04"}}}}'
rc=$(run_helper "$FOUND_1" "$OVER_2")
assert_rc "shape-bridge per-entry _override_reason permits" "0" "$rc"

# ---- Scenario 3: same collision with top-level override_reasons → PERMIT ----
printf '\n--- (3) naming.rules.R-04 collision WITH top-level override_reasons.naming.rules.R-04 → PERMIT ---\n'
OVER_3='{"naming":{"rules":{"R-04":{"text":"overlay R-04 text"}}},"override_reasons":{"naming":{"rules":{"R-04":"adopter-extended R-04"}}}}'
rc=$(run_helper "$FOUND_1" "$OVER_3")
assert_rc "shape-bridge top-level override_reasons permits" "0" "$rc"

# ---- Scenario 4: --collision-pillars=frontmatter excludes naming pillar ----
printf '\n--- (4) --collision-pillars=frontmatter excludes naming walk → PERMIT ---\n'
rc=$(run_helper "$FOUND_1" "$OVER_1" --collision-pillars "frontmatter")
assert_rc "narrowed-pillars flag skips naming.rules walk" "0" "$rc"

# ---- Scenario 5: --force-override bypasses entire walk (regression check) ----
printf '\n--- (5) --force-override bypasses entire walk → PERMIT ---\n'
rc=$(run_helper "$FOUND_1" "$OVER_1" --force-override)
assert_rc "--force-override preserved from SP16" "0" "$rc"

# ---- Scenario 6: file_type_contracts top-level-keys walk catches collision ----
printf '\n--- (6) file_type_contracts.daily-note.md.json collision → DENY ---\n'
FOUND_6='{"file_type_contracts":{"daily-note.md.json":{"size_limits":{"max_lines":400}}}}'
OVER_6='{"file_type_contracts":{"daily-note.md.json":{"size_limits":{"max_lines":600}}}}'
rc=$(run_helper "$FOUND_6" "$OVER_6")
assert_rc "file_type_contracts top-level-keys walk detects collision" "1" "$rc"
assert_stderr_contains "DENIED_KEYS path file_type_contracts.daily-note.md.json" "file_type_contracts.daily-note.md.json"

# ---- Scenario 7: file_type_contracts with per-entry _override_reason → PERMIT ----
printf '\n--- (7) file_type_contracts collision WITH per-entry _override_reason → PERMIT ---\n'
OVER_7='{"file_type_contracts":{"daily-note.md.json":{"size_limits":{"max_lines":600},"_override_reason":"adopter raised cap"}}}'
rc=$(run_helper "$FOUND_6" "$OVER_7")
assert_rc "file_type_contracts shape-bridge per-entry permits" "0" "$rc"

# ---- Scenario 8: overlay-only entity (no collision) → PERMIT ----
printf '\n--- (8) overlay-only naming rule (no foundation collision) → PERMIT ---\n'
OVER_8='{"naming":{"rules":{"R-99":{"text":"adopter-novel rule"}}}}'
rc=$(run_helper "$FOUND_1" "$OVER_8")
assert_rc "overlay-only entity (no collision) permits" "0" "$rc"

# ---- Summary ----
printf '\n=== SP17a T-4 per-pillar collision walk results: %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
