#!/bin/bash
# installer/disable-daemon.sh — disable a single foundation daemon, or --all.
#
# Usage:
#   disable-daemon.sh <label>     # disable single foundation label
#   disable-daemon.sh --all       # disable all foundation labels
#   disable-daemon.sh --help
#
# Symmetric command-side companion to enable-daemon (render-launchd.sh +
# launchctl bootstrap). Disables (bootout + plist rm) one or more launchd
# jobs in the com.claude-stem.* namespace.
#
# G6 namespace gate: refuses to act on labels outside com.claude-stem.*
# (mirrors install.sh + uninstall.sh + bootout-launchd.sh).
#
# Plist removal scope:
#   - $HOME/Library/LaunchAgents/<Label>.plist (production install)
#   - $CLAUDE_HOME/Library/LaunchAgents/<Label>.plist (dogfood-root install,
#     only when CLAUDE_HOME is set and != $HOME/.claude)
#
# Idempotent: missing label or already-disabled = no-op exit 0 with diagnostic.
#
# Exit codes:
#   0   success (or no-op idempotent re-run)
#   1   bootout failed for at least one targeted label
#   2   missing dependency (launchctl, plutil, awk)
#   3   usage error (no args, conflicting flags, etc.)
#   56  G6 violation — Label inside foundation-prefixed plist file does NOT
#       match com.claude-stem.* (refuses rm; mirrors install.sh G6 +
#       bootout-launchd.sh exit 56)
#   64  non-foundation label argument (G6 namespace gate refusal at argv)
#
# Env:
#   LAUNCHCTL_BIN  override path to launchctl (test injection); default 'launchctl'
#
# Dependencies: launchctl, plutil, awk.
#
# R-23: bash 3.2 compat. R-37 single-deliverable.

set -u

PREFIX="com.claude-stem"

diag() { printf 'disable-daemon FAIL: %s\n' "$1" >&2; }
warn() { printf 'disable-daemon WARN: %s\n' "$1" >&2; }
info() { printf 'disable-daemon: %s\n' "$1"; }

usage() {
  cat <<'USAGE'
Usage:
  disable-daemon.sh <label>    disable single foundation label
  disable-daemon.sh --all      disable all foundation labels
  disable-daemon.sh --help     this help

Labels must match the com.claude-stem.* namespace (G6 gate).
USAGE
}

# --- arg parse ---
mode=""
target_label=""
case "${1:-}" in
  ""|--help|-h)
    usage
    exit 0
    ;;
  --all)
    mode="all"
    ;;
  -*)
    diag "unknown flag: $1"
    usage >&2
    exit 3
    ;;
  *)
    mode="single"
    target_label="$1"
    case "$target_label" in
      "$PREFIX".*) : ;;
      *)
        diag "G6 violation: refusing non-foundation label '$target_label' (namespace must match $PREFIX.*)"
        exit 64
        ;;
    esac
    ;;
esac
shift || true
if [ "$#" -gt 0 ]; then
  diag "unexpected arguments after first: $*"
  usage >&2
  exit 3
fi

# --- LAUNCHCTL_BIN env override (test injection) ---
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"

# --- dependency check ---
if ! command -v "$LAUNCHCTL_BIN" >/dev/null 2>&1; then
  diag "dependency missing: $LAUNCHCTL_BIN (LAUNCHCTL_BIN env)"
  exit 2
fi
for tool in plutil awk; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    diag "dependency missing: $tool"
    exit 2
  fi
done

uid=$(id -u)
domain="gui/$uid"

# --- LaunchAgents directories (production + dogfood-root) ---
LA_DIRS="$HOME/Library/LaunchAgents"
CH="${CLAUDE_HOME:-}"
if [ -n "$CH" ] && [ "$CH/Library/LaunchAgents" != "$HOME/Library/LaunchAgents" ]; then
  LA_DIRS="$LA_DIRS $CH/Library/LaunchAgents"
fi

# --- collect target labels ---
if [ "$mode" = "all" ]; then
  labels=$("$LAUNCHCTL_BIN" list 2>/dev/null \
    | awk -v p="$PREFIX." 'NR > 1 && $3 != "" && index($3, p) == 1 {print $3}')
else
  labels="$target_label"
fi

# --- bootout phase ---
boot_failed=0
boot_count=0
noop_count=0
failed_labels=""

if [ -n "$labels" ]; then
  while IFS= read -r label; do
    [ -z "$label" ] && continue
    # Defense-in-depth: re-check prefix even though argv + awk filters fired.
    case "$label" in
      "$PREFIX".*) ;;
      *)
        warn "G6 defense: refusing bootout of non-foundation label '$label'"
        continue
        ;;
    esac
    bo_rc=0
    "$LAUNCHCTL_BIN" bootout "$domain/$label" >/dev/null 2>&1 || bo_rc=$?
    case "$bo_rc" in
      0)
        info "bootout $label"
        boot_count=$((boot_count + 1))
        ;;
      3|36|113)
        # Already-inactive idempotent paths: 113 = Could not find specified
        # service; 3 = No such process; 36 = LaunchOptions: not found. All
        # treated as no-op for re-run safety.
        info "bootout $label — already inactive (no-op)"
        noop_count=$((noop_count + 1))
        ;;
      *)
        warn "bootout failed for $label (rc=$bo_rc); preserving plist for forensics"
        failed_labels="$failed_labels $label"
        boot_failed=1
        ;;
    esac
  done <<EOF
$labels
EOF
elif [ "$mode" = "all" ]; then
  info "no foundation labels currently bootstrapped"
fi

# --- rm matching plist files in each LaunchAgents dir ---
removed_count=0
g6_violation=0

# Returns 0 if rm succeeded or skipped; sets g6_violation/removed_count as side-effects.
# Reads $failed_labels, $PREFIX from outer scope.
rm_plist_safely() {
  local plist="$1"
  local extracted=""
  [ -e "$plist" ] || return 0
  extracted=$(plutil -extract Label raw -o - "$plist" 2>/dev/null) || extracted=""
  # Forensic preserve: skip rm if bootout failed for this Label.
  case " $failed_labels " in
    *" $extracted "*)
      warn "skipping rm of $plist — bootout of $extracted failed (forensic preserve)"
      return 0
      ;;
  esac
  case "$extracted" in
    "$PREFIX".*)
      if rm -f "$plist" 2>/dev/null; then
        info "removed $plist"
        removed_count=$((removed_count + 1))
      else
        warn "rm failed for $plist"
      fi
      ;;
    "")
      # Could not extract Label (corrupt plist or plutil rejected). Treat as
      # foundation-owned by filename convention; rm with a warning.
      warn "could not extract Label from $plist; rm-ing by filename convention"
      if rm -f "$plist" 2>/dev/null; then
        info "removed $plist"
        removed_count=$((removed_count + 1))
      else
        warn "rm failed for $plist"
      fi
      ;;
    *)
      diag "G6 violation: plist '$plist' has Label '$extracted' outside $PREFIX.* prefix; refusing rm"
      g6_violation=1
      ;;
  esac
  return 0
}

for la_dir in $LA_DIRS; do
  [ -d "$la_dir" ] || continue
  if [ "$mode" = "all" ]; then
    # Bash-3.2-safe glob: literal pattern stays if no match; gate on [ -e ].
    # ?* requires at least one char after the prefix-dot.
    for plist in "$la_dir/$PREFIX".?*.plist; do
      [ -e "$plist" ] || continue
      rm_plist_safely "$plist"
    done
  else
    rm_plist_safely "$la_dir/$target_label.plist"
  fi
done

# --- exit ---
info "disable-daemon complete: bootout=$boot_count noop=$noop_count rm=$removed_count"

if [ "$g6_violation" -eq 1 ]; then
  exit 56
fi
if [ "$boot_failed" -eq 1 ]; then
  exit 1
fi
exit 0
