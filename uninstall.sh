#!/bin/bash
# uninstall.sh — Plan 71 SP08 T-2 (S61 happy-path slice + S62 allowlist update)
#
# S62 update: foundation-manifest.json added to foundation_known_entries
# allowlist (symmetric with install.sh foundation_known_entries L87).
# Removed during uninstall as foundation provenance — not user content.
# Future T-2 follow-up: uninstall.sh will read this baseline pre-rm and
# perform sha256 fingerprint match for user-edited foundation file
# preservation (currently rm by basename allowlist; backup-before-mutation
# mitigates accidental loss).
#
# Slice scope (S61):
#   - CLAUDE_HOME-first resolution from G1-pre symmetric (R-55 invariant)
#   - Provenance-log-driven CLAUDE_HOME confirmation: read header line
#     `CLAUDE_HOME: <path>` from most-recent $CLAUDE_HOME/logs/install-*.log
#     (G10 consume) and assert equality with env-supplied $CLAUDE_HOME
#   - .pre-uninstall-<ts>/ backup via cp -R (round-trip integrity)
#   - launchctl bootout gui/$UID com.claude-foundations.* (LAUNCHCTL_BIN env
#     override for MOCK_LAUNCHCTL=1 hermetic tests; defense-in-depth G6)
#   - G6 namespace gate: refuse to bootout labels outside com.claude-foundations.*
#     prefix; secondary guard catches impersonation labels (prefix as substring
#     but not at position 1)
#   - rm foundation-known basename allowlist at $CLAUDE_HOME root (mirror of
#     install.sh L87 foundation_known_entries)
#   - Preserve logs/ (uninstall provenance lands here) + hooks/state/ (session
#     state; nested under foundation hooks/) + everything not in foundation set
#   - Provenance log header at $CLAUDE_HOME/logs/uninstall-*.log on completion
#
# DEFERRED to subsequent T-2 follow-up sessions:
#   - sha256 fingerprint match vs T-5 foundation-manifest.json baseline
#     (currently rm by basename allowlist; user-edited foundation file
#     would be removed without review summary)
#   - settings.json baseline jq-reverse unmerge (G7-symmetric; needs T-5)
#   - --selective <hooks|skills|plists|schemas|onboarding|lib|orchestrator|
#     templates|plugins|installer> / --full / --dry-run / --keep-backup flag
#     matrix (slice ships with no flags; default behavior is full + keep-backup)
#   - Negative-test rehearsal under SP00 runner-shell in SP00 Docker image
#     (T-3 territory; SP00-owned)
#   - User-edited foundation file preservation review summary (depends on
#     fingerprint match; deferred with G2)
#
# Exit codes (slice subset):
#   0   success
#   10  prereq missing (CLAUDE_HOME unset/empty per G1-pre symmetric;
#                       required binary absent; provenance log missing;
#                       CLAUDE_HOME mismatch with provenance log header)
#   11  permission/write failure (backup mkdir, backup cp, or provenance write)
#   56  G6 fired (label outside com.claude-foundations.* prefix encountered
#                 during bootout discovery; foundation rm NOT performed;
#                 backup retained for forensic review)
#
# R-23 bash 3.2 compat. R-37 single-deliverable. R-55 zero $HOME/.claude
# resolution paths in script body (literal $HOME/.claude appears only in
# the G1-pre user-facing error text per spec.md L74 symmetric).

set -u

# --- diagnostics ---
diag() { printf 'uninstall FAIL: %s\n' "$1" >&2; }
info() { printf 'uninstall: %s\n' "$1"; }
warn() { printf 'uninstall WARN: %s\n' "$1" >&2; }

# --- G1-pre symmetric: CLAUDE_HOME unset/empty preflight (no FS writes) ---
# Mirrors install.sh L58-61. Acceptance: headless exit fast; zero filesystem mutation.
if [ -z "${CLAUDE_HOME:-}" ]; then
  diag "CLAUDE_HOME not set. Export CLAUDE_HOME=\$HOME/.claude or a custom path before running uninstall.sh. Never rely on \$HOME/.claude implicit default — hard-fail is required for uninstaller safety."
  exit 10
fi

# --- LAUNCHCTL_BIN env override (MOCK_LAUNCHCTL primitive consumption) ---
# Default: real launchctl on PATH. Tests inject mock via LAUNCHCTL_BIN=/path/to/mock-launchctl.
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"

# --- prereq binary check ---
if ! command -v "$LAUNCHCTL_BIN" >/dev/null 2>&1; then
  diag "missing prereq binary: $LAUNCHCTL_BIN (LAUNCHCTL_BIN env var)"
  exit 10
fi
for bin in plutil awk; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    diag "missing prereq binary: $bin"
    exit 10
  fi
done

if [ ! -d "$CLAUDE_HOME" ]; then
  diag "CLAUDE_HOME does not exist: $CLAUDE_HOME"
  exit 10
fi

# --- discover most-recent install provenance log (G10 consume) ---
# Symmetric with install.sh L298-309 emit format. Filenames are deterministic
# install-YYYYMMDD-HHMMSS-pid.log (no spaces) so `ls -1t` is parsable.
log_dir="$CLAUDE_HOME/logs"
if [ ! -d "$log_dir" ]; then
  diag "no logs/ directory at $CLAUDE_HOME (no foundation install detected)"
  exit 10
fi

provenance_log=""
for f in $(ls -1t "$log_dir"/install-*.log 2>/dev/null); do
  provenance_log="$f"
  break
done

if [ -z "$provenance_log" ]; then
  diag "no install-*.log provenance under $CLAUDE_HOME/logs/ (no foundation install detected)"
  exit 10
fi

info "provenance: $provenance_log"

# --- read CLAUDE_HOME from provenance header (R-55 discipline) ---
# install.sh writes line `CLAUDE_HOME: <path>`; awk extracts the second field.
# Sanity-check vs env-supplied $CLAUDE_HOME — mismatch indicates corrupt log
# or wrong target (refuse rather than guess).
provenance_claude_home=""
provenance_claude_home="$(awk '/^CLAUDE_HOME:/ {print $2; exit}' "$provenance_log" 2>/dev/null)"

if [ -z "$provenance_claude_home" ]; then
  diag "provenance log missing CLAUDE_HOME header line: $provenance_log"
  exit 10
fi

if [ "$provenance_claude_home" != "$CLAUDE_HOME" ]; then
  diag "provenance CLAUDE_HOME=$provenance_claude_home does not match env CLAUDE_HOME=$CLAUDE_HOME — refusing uninstall (corrupt log or wrong target)"
  exit 10
fi

# --- foundation-known basename allowlist (mirror of install.sh L87) ---
# Source: install.sh foundation_known_entries. Symmetric with G1-main heuristic.
# Includes foundation-manifest.json (T-5 baseline; install.sh Step 13.5).
foundation_known_entries="hooks skills schemas onboarding orchestrator templates plugins Library installer logs settings.json settings.local.json foundation-manifest.json"

info "CLAUDE_HOME=$CLAUDE_HOME"
info "LAUNCHCTL_BIN=$LAUNCHCTL_BIN"

# --- backup: .pre-uninstall-<ts>/ via cp -R ---
ts="$(date -u +%Y%m%d-%H%M%S)"
backup_dir="$CLAUDE_HOME/.pre-uninstall-$ts"

info "creating backup: $backup_dir"
mkdir -p "$backup_dir" || { diag "backup mkdir failed: $backup_dir"; exit 11; }

# Copy each top-level entry except prior backup dirs (avoid recursion).
# Bash 3.2 + macOS cp -R: literal `cp -R src dst/` per-entry.
backup_count=0
for entry in "$CLAUDE_HOME"/* "$CLAUDE_HOME"/.[!.]*; do
  [ -e "$entry" ] || continue
  base="${entry##*/}"
  case "$base" in
    .pre-uninstall-*) continue ;;
  esac
  if cp -R "$entry" "$backup_dir/" 2>/dev/null; then
    backup_count=$((backup_count + 1))
  else
    warn "backup cp failed for $entry"
  fi
done

info "backup complete: $backup_count entries → $backup_dir"

# --- launchctl bootout gui/$UID com.claude-foundations.* (G6-gated) ---
PREFIX="com.claude-foundations"
uid="$(id -u)"
domain="gui/$uid"

g6_violation=0
boot_count=0

# Primary G6: filter launchctl list output by prefix at awk; non-matching
# labels never reach the bootout call.
labels=""
labels="$("$LAUNCHCTL_BIN" list 2>/dev/null | awk -v p="$PREFIX." 'NR > 1 && $3 != "" && index($3, p) == 1 {print $3}')" || true

# Secondary G6 (impersonation defense): scan for labels containing the prefix
# substring but NOT at position 1 (e.g., `evil.com.claude-foundations.fake`).
# This catches impersonation that the primary index==1 filter excludes.
foreign=""
foreign="$("$LAUNCHCTL_BIN" list 2>/dev/null | awk -v p="$PREFIX" 'NR > 1 && $3 != "" && index($3, p) > 0 && index($3, p) != 1 {print $3}')" || true
if [ -n "$foreign" ]; then
  diag "G6 fired: foreign label(s) contain '$PREFIX' substring outside namespace (position 1):"
  printf '%s\n' "$foreign" >&2
  g6_violation=1
fi

if [ "$g6_violation" = "1" ]; then
  diag "uninstall aborted on G6 violation; foundation file removal NOT performed (backup retained at $backup_dir for forensic review)"
  exit 56
fi

# --- bootout each foundation label (rc-tolerant; warn on failure) ---
if [ -n "$labels" ]; then
  while IFS= read -r label; do
    [ -z "$label" ] && continue
    # Defense-in-depth: re-check prefix at iteration time.
    case "$label" in
      "$PREFIX".*) ;;
      *)
        warn "G6 defense: label '$label' slipped past awk filter; refusing bootout"
        continue
        ;;
    esac
    if "$LAUNCHCTL_BIN" bootout "$domain/$label" 2>/dev/null; then
      info "bootout $label"
      boot_count=$((boot_count + 1))
    else
      rc=$?
      warn "bootout failed for $label (rc=$rc); continuing iteration"
    fi
  done <<EOF
$labels
EOF
fi

info "bootout complete: $boot_count labels"

# --- preserve hooks/state/ across foundation hooks/ removal ---
# hooks/ is foundation-known (gets rm-rf'd) but hooks/state/ is session state.
# Move hooks/state/ aside, rm hooks/, then move hooks/state/ back.
hooks_state_tmp=""
if [ -d "$CLAUDE_HOME/hooks/state" ]; then
  hooks_state_tmp="$CLAUDE_HOME/.uninstall-tmp-hooks-state-$$"
  if mv "$CLAUDE_HOME/hooks/state" "$hooks_state_tmp" 2>/dev/null; then
    info "hooks/state/ preserved aside: $hooks_state_tmp"
  else
    warn "hooks/state/ preserve mv failed; will be removed with hooks/"
    hooks_state_tmp=""
  fi
fi

# --- rm foundation files at $CLAUDE_HOME root per allowlist ---
removed_count=0
preserved_count=0

for entry in "$CLAUDE_HOME"/* "$CLAUDE_HOME"/.[!.]*; do
  [ -e "$entry" ] || continue
  base="${entry##*/}"
  case "$base" in
    .pre-uninstall-*) continue ;;
    .uninstall-tmp-hooks-state-*) continue ;;
  esac

  found=0
  for known in $foundation_known_entries; do
    if [ "$base" = "$known" ]; then
      found=1
      break
    fi
  done

  if [ "$found" = "1" ]; then
    # Preserve logs/ entirely (uninstall provenance log writes here next).
    if [ "$base" = "logs" ]; then
      info "preserving logs/ (uninstall provenance destination)"
      preserved_count=$((preserved_count + 1))
      continue
    fi
    if rm -rf "$entry" 2>/dev/null; then
      info "removed $entry"
      removed_count=$((removed_count + 1))
    else
      warn "rm failed for $entry"
    fi
  else
    info "preserved (non-foundation): $entry"
    preserved_count=$((preserved_count + 1))
  fi
done

# --- restore hooks/state/ if it was preserved aside ---
if [ -n "$hooks_state_tmp" ] && [ -d "$hooks_state_tmp" ]; then
  mkdir -p "$CLAUDE_HOME/hooks" || warn "hooks/ recreate failed for hooks/state/ restore"
  if mv "$hooks_state_tmp" "$CLAUDE_HOME/hooks/state" 2>/dev/null; then
    info "hooks/state/ restored"
    preserved_count=$((preserved_count + 1))
  else
    warn "hooks/state/ restore mv failed; left at $hooks_state_tmp for manual recovery"
  fi
fi

info "rm complete: removed=$removed_count preserved=$preserved_count"

# --- provenance log header (G10 emit; symmetric with install.sh) ---
log_path="$CLAUDE_HOME/logs/uninstall-$(date -u +%Y%m%d-%H%M%S)-$$.log"
{
  printf 'uninstall.sh provenance — Plan 71 SP08 T-2 slice (S61)\n'
  printf 'timestamp: %s\n'             "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'CLAUDE_HOME: %s\n'           "$CLAUDE_HOME"
  printf 'consumed_install_log: %s\n'  "$provenance_log"
  printf 'backup_dir: %s\n'            "$backup_dir"
  printf 'backup_entry_count: %d\n'    "$backup_count"
  printf 'bootout_count: %d\n'         "$boot_count"
  printf 'removed_count: %d\n'         "$removed_count"
  printf 'preserved_count: %d\n'       "$preserved_count"
  printf 'launchctl_bin: %s\n'         "$LAUNCHCTL_BIN"
  printf 'uninstall.sh sha256: %s\n'   "$(shasum -a 256 "$0" 2>/dev/null | awk '{print $1}')"
  printf 'slice_scope: G1-pre symmetric + provenance-log-driven CLAUDE_HOME confirm + .pre-uninstall-<ts>/ backup + launchctl bootout (LAUNCHCTL_BIN-overridable, G6-gated, com.claude-foundations.* only) + foundation-known basename allowlist removal + logs/ + hooks/state/ + non-foundation top-level preservation\n'
  printf 'deferred: sha256 fingerprint match vs T-5 foundation-manifest.json; settings.json baseline jq-reverse unmerge; --selective/--full/--dry-run/--keep-backup flag matrix; SP00 runner-shell negative rehearsal; user-edited foundation file review summary\n'
} > "$log_path" || { diag "uninstall provenance log write failed"; exit 11; }

info "uninstall complete (slice). next-steps:"
info "  - restore round-trip: cp -R $backup_dir/. \$CLAUDE_HOME/"
info "  - prune backup when satisfied: rm -rf $backup_dir"
info "provenance: $log_path"

exit 0
