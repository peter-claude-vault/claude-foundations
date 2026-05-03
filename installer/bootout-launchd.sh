#!/bin/bash
# installer/bootout-launchd.sh — uninstall foundation engine launchd plists.
#
# Usage: bootout-launchd.sh
#
# Iterates `launchctl list` filtered for `com.claude-stem.*` labels
# (SP08 G6 namespace isolation), `launchctl bootout`s each (rc-tolerant —
# surfaces failures to stderr but continues iteration to other labels),
# then removes matching plist files from ~/Library/LaunchAgents/.
#
# bootout-BEFORE-rm is a non-negotiable invariant: rm-first leaves launchctl
# holding a stale Label pointer to a dead path; bootout-first cleans both.
#
# G6 guard (defense in depth):
#   - Primary: awk filters launchctl list output by prefix; non-matching
#     labels never reach the bootout call.
#   - Secondary: before rm, plutil-extract each plist's Label and reject
#     rm if Label drifts outside the foundation prefix (catches tampered
#     files where filename matches prefix but in-plist Label does not).
#
# Exit codes:
#   0   success (or no foundation plists installed)
#   1   one or more bootout calls returned non-zero (rm still attempted)
#   2   dependency missing
#   56  G6 violation — Label inside a foundation-prefixed plist file does
#       NOT match com.claude-stem.* (refuses rm; mirrors SP08 G6
#       installer exit code 56)
#
# Dependencies: launchctl, plutil, awk.
#
# R-23: bash 3.2 compat. R-37 single-deliverable.

set -u

diag() { printf 'bootout-launchd FAIL: %s\n' "$1" >&2; }
warn() { printf 'bootout-launchd WARN: %s\n' "$1" >&2; }
info() { printf 'bootout-launchd: %s\n' "$1"; }

PREFIX="com.claude-stem"

# --- source paths.sh ---
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi
# paths.sh sourcing is best-effort here — uninstall must work even if the
# install is partially broken. Fall back to $HOME-relative defaults.

# --- dependency check ---
for tool in launchctl plutil awk; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    diag "$tool required but not found on PATH"
    exit 2
  fi
done

uid=$(id -u)
domain="gui/$uid"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

# --- collect loaded foundation labels ---
# `launchctl list` columns: PID Status Label. Skip header (NR > 1). Filter
# by prefix at awk so non-matching labels (com.apple.*, com.user.*, etc.)
# never reach the bootout call — primary G6 enforcement.
labels=$(launchctl list 2>/dev/null | awk -v p="$PREFIX." 'NR > 1 && $3 != "" && index($3, p) == 1 {print $3}')

# --- bootout each (rc-tolerant; track failures for forensic-preserve rm) ---
# Per briefing: "DO NOT proceed to rm if bootout fails — surface as error,
# but continue iteration to other labels". Implementation: track failed
# labels, then in the rm phase skip files whose in-plist Label matches a
# failed label. Succeeded + orphan files still get rm'd.
boot_failed=0
boot_count=0
failed_labels=""
if [ -n "$labels" ]; then
  while IFS= read -r label; do
    [ -z "$label" ] && continue
    # Defense-in-depth: re-check prefix at iteration time even though awk
    # already filtered. Closes the loophole if launchctl list output format
    # ever shifts and awk's column index lands on a non-Label value.
    case "$label" in
      "$PREFIX".*) ;;
      *)
        warn "G6 defense: label '$label' slipped past awk filter; refusing bootout"
        continue
        ;;
    esac
    if launchctl bootout "$domain/$label" 2>/dev/null; then
      info "bootout $label"
      boot_count=$((boot_count + 1))
    else
      rc=$?
      warn "bootout failed for $label (rc=$rc); preserving plist for forensics"
      failed_labels="$failed_labels $label"
      boot_failed=1
    fi
  done <<EOF
$labels
EOF
fi

# --- rm matching plist files (G6 sanity-check Label before each rm) ---
removed_count=0
g6_violation=0
# Bash-3.2-safe glob: literal pattern remains as-is when no match; gate
# with [ -e ] to skip non-existent. Use ?* to require at least one char
# after the prefix-dot (avoid matching "com.claude-stem..plist").
for plist in "$LAUNCH_AGENTS/$PREFIX".?*.plist; do
  [ -e "$plist" ] || continue
  # Extract Label; defense against tampered file where filename matches
  # prefix but in-plist Label drifted outside foundation namespace.
  extracted=""
  extracted=$(plutil -extract Label raw -o - "$plist" 2>/dev/null) || extracted=""
  # Forensic preserve: if Label is in the failed-bootout set, skip rm.
  case " $failed_labels " in
    *" $extracted "*)
      warn "skipping rm of $plist — bootout of $extracted failed (forensic preserve)"
      continue
      ;;
  esac
  case "$extracted" in
    "$PREFIX".*)
      # Label matches — safe to rm.
      if rm -f "$plist" 2>/dev/null; then
        info "removed $plist"
        removed_count=$((removed_count + 1))
      else
        warn "rm failed for $plist"
      fi
      ;;
    "")
      # Could not extract Label (corrupt plist or plutil rejected). Treat
      # as foundation-owned by filename convention; rm with a warning.
      warn "could not extract Label from $plist; rm-ing by filename convention"
      if rm -f "$plist" 2>/dev/null; then
        info "removed $plist"
        removed_count=$((removed_count + 1))
      else
        warn "rm failed for $plist"
      fi
      ;;
    *)
      # G6 secondary guard: filename matches foundation prefix but in-plist
      # Label is something else. Refuse rm to avoid clobbering files we
      # don't own.
      diag "G6 violation: plist '$plist' has Label '$extracted' outside $PREFIX.* prefix; refusing rm"
      g6_violation=1
      ;;
  esac
done

# --- exit ---
info "uninstall complete: bootout=$boot_count rm=$removed_count"

if [ "$g6_violation" -eq 1 ]; then
  exit 56
fi
if [ "$boot_failed" -eq 1 ]; then
  exit 1
fi
exit 0
