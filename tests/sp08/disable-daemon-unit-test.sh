#!/bin/bash
# tests/sp08/disable-daemon-unit-test.sh
#
# Hermetic unit test for SP08 T-11 (audit-added) — `disable-daemon` CLI.
# Covers SP08 T-11 ACs 1-7:
#   T1 (AC1+AC4+AC5)  single-label happy path: bootout + plist rm in $HOME/LaunchAgents
#   T2 (AC2+AC4)      --all happy path: multiple labels + multiple plists
#   T3 (AC1)          non-foundation label refused with rc=64 (G6 argv gate)
#   T4 (AC5)          idempotent re-run on already-disabled label = exit 0 no-op
#   T5 (AC4)          missing plist on disk = exit 0 (no-op for plist phase)
#   T6 (AC4)          dogfood-root: $CLAUDE_HOME/Library/LaunchAgents plist rm
#   T7 (G6 secondary) tampered plist (foundation filename, foreign Label) → exit 56
#   T8                --all on empty launchctl list = no-op exit 0
#   T9                usage: no-arg + bad-flag → exit 0/3
#
# Hermetic isolation:
#   - Per-test tmpdir as $HOME (and $CLAUDE_HOME where dogfood-root tests need it).
#   - LAUNCHCTL_BIN injects a synthesized mock; never touches real launchd.
#   - All bootout invocations recorded to MOCK_LAUNCHCTL_BOOTOUT_LOG for assertion.
#
# R-23: bash 3.2 compat.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISABLE_DAEMON_SH="$REPO_ROOT/installer/disable-daemon.sh"

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
  d="$(mktemp -d -t disable-daemon-test.XXXXXX)"
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

assert_path_absent() {
  local path="$1" label="$2"
  if [ ! -e "$path" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (path still exists: %s)\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_path_exists() {
  local path="$1" label="$2"
  if [ -e "$path" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (path missing: %s)\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_file_contains() {
  local pattern="$1" file="$2" label="$3"
  if [ -f "$file" ] && grep -q -- "$pattern" "$file" 2>/dev/null; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (pattern not found: %s in %s)\n' "$label" "$pattern" "$file" >&2
    FAIL=$((FAIL+1))
  fi
}

# --- mock launchctl factory ---
# Honors:
#   MOCK_LAUNCHCTL_LABELS (space-separated; emitted on `list`)
#   MOCK_LAUNCHCTL_BOOTOUT_RC (default 0; rc returned for bootout)
#   MOCK_LAUNCHCTL_BOOTOUT_LOG (path to bootout invocation log)
#   MOCK_LAUNCHCTL_RC113_LABELS (space-separated; bootout returns 113 for these)
write_mock_launchctl() {
  local target="$1"
  cat > "$target" <<'MOCK'
#!/bin/bash
# Mock launchctl for SP08 T-11 disable-daemon hermetic tests.
case "${1:-}" in
  list)
    printf 'PID\tStatus\tLabel\n'
    if [ -n "${MOCK_LAUNCHCTL_LABELS:-}" ]; then
      for label in $MOCK_LAUNCHCTL_LABELS; do
        printf '12345\t0\t%s\n' "$label"
      done
    fi
    exit 0
    ;;
  bootout)
    target_label="${2:-}"
    # Strip domain prefix (e.g., "gui/501/com.foo" -> "com.foo")
    target_label_only="${target_label##*/}"
    if [ -n "${MOCK_LAUNCHCTL_BOOTOUT_LOG:-}" ]; then
      printf 'bootout %s\n' "$target_label" >> "$MOCK_LAUNCHCTL_BOOTOUT_LOG"
    fi
    # Per-label rc113 (idempotent already-inactive simulation)
    if [ -n "${MOCK_LAUNCHCTL_RC113_LABELS:-}" ]; then
      for l in $MOCK_LAUNCHCTL_RC113_LABELS; do
        if [ "$l" = "$target_label_only" ]; then
          exit 113
        fi
      done
    fi
    exit "${MOCK_LAUNCHCTL_BOOTOUT_RC:-0}"
    ;;
  version)
    printf 'mock-launchctl 0.1\n'
    exit 0
    ;;
  *)
    printf 'mock-launchctl: unknown verb %s\n' "${1:-<empty>}" >&2
    exit 1
    ;;
esac
MOCK
  chmod +x "$target"
}

# Helper: write a minimal valid plist with a Label key.
write_plist() {
  local path="$1" label="$2"
  cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/true</string></array>
</dict>
</plist>
EOF
}

# ============================================================================
# T1: single-label happy path
# ============================================================================
echo "=== T1: single-label happy path ==="
T1_HOME="$(mk_tmp)"
T1_LA="$T1_HOME/Library/LaunchAgents"
mkdir -p "$T1_LA"
write_plist "$T1_LA/com.claude-stem.librarian.plist" "com.claude-stem.librarian"
T1_MOCK="$T1_HOME/mock-launchctl"
write_mock_launchctl "$T1_MOCK"
T1_BOOTOUT_LOG="$T1_HOME/bootout.log"
: > "$T1_BOOTOUT_LOG"

T1_RC=0
HOME="$T1_HOME" \
  LAUNCHCTL_BIN="$T1_MOCK" \
  MOCK_LAUNCHCTL_BOOTOUT_LOG="$T1_BOOTOUT_LOG" \
  bash "$DISABLE_DAEMON_SH" com.claude-stem.librarian >/dev/null 2>&1 || T1_RC=$?

assert_eq 0 "$T1_RC" "T1.1 rc=0"
assert_file_contains "com.claude-stem.librarian" "$T1_BOOTOUT_LOG" "T1.2 bootout invoked"
assert_path_absent "$T1_LA/com.claude-stem.librarian.plist" "T1.3 plist removed"

# ============================================================================
# T2: --all happy path
# ============================================================================
echo "=== T2: --all happy path ==="
T2_HOME="$(mk_tmp)"
T2_LA="$T2_HOME/Library/LaunchAgents"
mkdir -p "$T2_LA"
write_plist "$T2_LA/com.claude-stem.librarian.plist" "com.claude-stem.librarian"
write_plist "$T2_LA/com.claude-stem.architect.plist" "com.claude-stem.architect"
# Sentinel: non-foundation plist that must NOT be removed
write_plist "$T2_LA/com.user.unrelated.plist" "com.user.unrelated"
T2_MOCK="$T2_HOME/mock-launchctl"
write_mock_launchctl "$T2_MOCK"
T2_BOOTOUT_LOG="$T2_HOME/bootout.log"
: > "$T2_BOOTOUT_LOG"

T2_RC=0
HOME="$T2_HOME" \
  LAUNCHCTL_BIN="$T2_MOCK" \
  MOCK_LAUNCHCTL_LABELS="com.claude-stem.librarian com.claude-stem.architect com.user.unrelated" \
  MOCK_LAUNCHCTL_BOOTOUT_LOG="$T2_BOOTOUT_LOG" \
  bash "$DISABLE_DAEMON_SH" --all >/dev/null 2>&1 || T2_RC=$?

assert_eq 0 "$T2_RC" "T2.1 rc=0"
assert_file_contains "com.claude-stem.librarian" "$T2_BOOTOUT_LOG" "T2.2 librarian bootout invoked"
assert_file_contains "com.claude-stem.architect" "$T2_BOOTOUT_LOG" "T2.3 architect bootout invoked"
T2_BOOT_COUNT=$(wc -l <"$T2_BOOTOUT_LOG" | tr -d ' ')
assert_eq 2 "$T2_BOOT_COUNT" "T2.4 only 2 foundation labels boot-out (G6 awk filter)"
assert_path_absent "$T2_LA/com.claude-stem.librarian.plist" "T2.5 librarian plist removed"
assert_path_absent "$T2_LA/com.claude-stem.architect.plist" "T2.6 architect plist removed"
assert_path_exists "$T2_LA/com.user.unrelated.plist" "T2.7 non-foundation plist preserved"

# ============================================================================
# T3: non-foundation label argument refused (G6 argv gate)
# ============================================================================
echo "=== T3: non-foundation label refused ==="
T3_HOME="$(mk_tmp)"
T3_MOCK="$T3_HOME/mock-launchctl"
write_mock_launchctl "$T3_MOCK"

T3_RC=0
HOME="$T3_HOME" \
  LAUNCHCTL_BIN="$T3_MOCK" \
  bash "$DISABLE_DAEMON_SH" com.user.something >/dev/null 2>&1 || T3_RC=$?
assert_eq 64 "$T3_RC" "T3.1 non-foundation label rc=64"

T3b_RC=0
HOME="$T3_HOME" \
  LAUNCHCTL_BIN="$T3_MOCK" \
  bash "$DISABLE_DAEMON_SH" com.apple.launchd.peruser >/dev/null 2>&1 || T3b_RC=$?
assert_eq 64 "$T3b_RC" "T3.2 com.apple.* refused rc=64"

# ============================================================================
# T4: idempotent re-run on already-disabled label
# ============================================================================
echo "=== T4: idempotent re-run no-op ==="
T4_HOME="$(mk_tmp)"
T4_LA="$T4_HOME/Library/LaunchAgents"
mkdir -p "$T4_LA"
# No plist on disk; mock returns rc=113 (already-inactive)
T4_MOCK="$T4_HOME/mock-launchctl"
write_mock_launchctl "$T4_MOCK"

T4_RC=0
HOME="$T4_HOME" \
  LAUNCHCTL_BIN="$T4_MOCK" \
  MOCK_LAUNCHCTL_RC113_LABELS="com.claude-stem.librarian" \
  bash "$DISABLE_DAEMON_SH" com.claude-stem.librarian >/dev/null 2>&1 || T4_RC=$?
assert_eq 0 "$T4_RC" "T4.1 idempotent rc=113 → exit 0"

# ============================================================================
# T5: missing plist on disk = exit 0 (bootout succeeded)
# ============================================================================
echo "=== T5: missing plist no-op ==="
T5_HOME="$(mk_tmp)"
T5_LA="$T5_HOME/Library/LaunchAgents"
mkdir -p "$T5_LA"
# No plist file; mock bootout returns 0 (Label registered but plist already rm'd)
T5_MOCK="$T5_HOME/mock-launchctl"
write_mock_launchctl "$T5_MOCK"

T5_RC=0
HOME="$T5_HOME" \
  LAUNCHCTL_BIN="$T5_MOCK" \
  bash "$DISABLE_DAEMON_SH" com.claude-stem.librarian >/dev/null 2>&1 || T5_RC=$?
assert_eq 0 "$T5_RC" "T5.1 missing-plist rc=0"

# ============================================================================
# T6: dogfood-root — $CLAUDE_HOME/Library/LaunchAgents plist removal
# ============================================================================
echo "=== T6: dogfood-root plist scope ==="
T6_HOME="$(mk_tmp)"
T6_CH="$(mk_tmp)"
T6_LA_HOME="$T6_HOME/Library/LaunchAgents"
T6_LA_CH="$T6_CH/Library/LaunchAgents"
mkdir -p "$T6_LA_HOME" "$T6_LA_CH"
write_plist "$T6_LA_CH/com.claude-stem.librarian.plist" "com.claude-stem.librarian"
T6_MOCK="$T6_HOME/mock-launchctl"
write_mock_launchctl "$T6_MOCK"

T6_RC=0
HOME="$T6_HOME" \
  CLAUDE_HOME="$T6_CH" \
  LAUNCHCTL_BIN="$T6_MOCK" \
  bash "$DISABLE_DAEMON_SH" com.claude-stem.librarian >/dev/null 2>&1 || T6_RC=$?
assert_eq 0 "$T6_RC" "T6.1 dogfood-root rc=0"
assert_path_absent "$T6_LA_CH/com.claude-stem.librarian.plist" "T6.2 dogfood plist removed"

# ============================================================================
# T7: G6 secondary — tampered plist (foundation filename, foreign Label) → 56
# ============================================================================
echo "=== T7: G6 tampered plist refusal ==="
T7_HOME="$(mk_tmp)"
T7_LA="$T7_HOME/Library/LaunchAgents"
mkdir -p "$T7_LA"
# Filename matches foundation prefix but in-plist Label is foreign → G6 refuse
write_plist "$T7_LA/com.claude-stem.tampered.plist" "com.evil.attacker"
T7_MOCK="$T7_HOME/mock-launchctl"
write_mock_launchctl "$T7_MOCK"

T7_RC=0
HOME="$T7_HOME" \
  LAUNCHCTL_BIN="$T7_MOCK" \
  bash "$DISABLE_DAEMON_SH" --all >/dev/null 2>&1 || T7_RC=$?
assert_eq 56 "$T7_RC" "T7.1 G6 tampered plist rc=56"
assert_path_exists "$T7_LA/com.claude-stem.tampered.plist" "T7.2 tampered plist preserved (refused rm)"

# ============================================================================
# T8: --all on empty launchctl list = no-op exit 0
# ============================================================================
echo "=== T8: --all empty no-op ==="
T8_HOME="$(mk_tmp)"
T8_LA="$T8_HOME/Library/LaunchAgents"
mkdir -p "$T8_LA"
T8_MOCK="$T8_HOME/mock-launchctl"
write_mock_launchctl "$T8_MOCK"

T8_RC=0
HOME="$T8_HOME" \
  LAUNCHCTL_BIN="$T8_MOCK" \
  bash "$DISABLE_DAEMON_SH" --all >/dev/null 2>&1 || T8_RC=$?
assert_eq 0 "$T8_RC" "T8.1 --all empty rc=0"

# ============================================================================
# T9: usage handling
# ============================================================================
echo "=== T9: usage ==="
T9_RC=0
bash "$DISABLE_DAEMON_SH" >/dev/null 2>&1 || T9_RC=$?
assert_eq 0 "$T9_RC" "T9.1 no-arg → help → rc=0"

T9b_RC=0
bash "$DISABLE_DAEMON_SH" --help >/dev/null 2>&1 || T9b_RC=$?
assert_eq 0 "$T9b_RC" "T9.2 --help → rc=0"

T9c_RC=0
bash "$DISABLE_DAEMON_SH" --bogus >/dev/null 2>&1 || T9c_RC=$?
assert_eq 3 "$T9c_RC" "T9.3 unknown flag → rc=3"

T9d_RC=0
bash "$DISABLE_DAEMON_SH" com.claude-stem.foo extra-arg >/dev/null 2>&1 || T9d_RC=$?
assert_eq 3 "$T9d_RC" "T9.4 extra args → rc=3"

# ============================================================================
echo "==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
