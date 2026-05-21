#!/bin/bash
# install.sh — Plan 71 SP08 T-1 (S59 happy-path + S60 G1 + S62 baseline + S64 G2 + S65 G3-G10 + S66 G9 + flag matrix)
#
# Slice scope (S59 + S60 + S62 + S64 + S65 + S66 cumulative):
#   - CLAUDE_HOME-first resolution (R-55 invariant; AC #1)
#   - G1-pre 100ms preflight (no FS writes; AC #2)              [S60]
#   - G1-main $HOME/.claude equality gate + I-UNDERSTAND-OVERWRITE-RISK
#     sentinel + --force-install flag (AC #3)                    [S60]
#   - G2 foreign-content detector — sha256 drift in foundation files  [S64]
#     against $SOURCE_REPO/foundation-manifest.json baseline; refuse
#     install on drift unless --force-install + sentinel; sentinel
#     reused from G1-main if both fire in same session.
#   - G3 backup proof-of-life — --backup-dir writability + round-trip   [S65]
#     test; required when destructive op pending (settings.json pre-
#     exists in $CLAUDE_HOME); validated whenever supplied.
#   - G4 vault-symlink distance check — refuse unconditionally if       [S65]
#     $CLAUDE_HOME walks contain symlinks resolving under
#     ~/Documents/Obsidian Vault/. April-13 protection; NO override.
#   - G5 plans-dir guard — refuse if $PLANS_HOME contains existing      [S65]
#     NN-*/ plans without --retrofit-existing (waiver stub; v2.1 retrofit
#     logic deferred).
#   - G8 UID-0 refuse — exit 58 if id -u == 0; NO override.             [S65]
#   - G9 dry-run as default — first invocation without --apply emits    [S66]
#     action-plan JSON to stdout with zero $CLAUDE_HOME writes; --apply
#     required to actually install. Posture, not refuse-gate; gate fires
#     after all pre-flight guards (G1-pre..G8 + state-classify) and
#     before Step 1 mkdir.
#   - State classification (fresh|foundation-only|mixed|user-only)      [S66]
#     computed once after G2 close, before G3 gate; user-only without
#     --force-install → exit 21; recorded in provenance.
#   - --force-all flag — broader override than --force-install;         [S66]
#     promotes Steps 2-10 cp -n → cp -f (foundation-known files
#     overwritten unconditionally; user-content under foundation dirs
#     still preserved naturally by walking known-name set, not all files).
#   - --no-preserve-config flag — explicit claude-mem preservation      [S66]
#     waiver per spec §claude-mem Preservation Policy; requires
#     --force-install (exit 11 if missing). Defaults OFF.
#   - G10 provenance-write failure → exit 11 (audit/tick — already      [S65]
#     enforced at log_path write site; counted live as of S65).
#   - 14-asset write-sequence (audit F-01..F-05)
#   - LABEL_PREFIX=com.claude-stem preserved via cp -R installer/ +
#     templates/launchd/ (G6 namespace isolation, transitively)
#   - settings.json atomic jq-merge with G7 silent-key-deletion gate
#   - foundation-manifest.json baseline copy (T-5 generator output;       [S62]
#     consumed by G2 detector + uninstall fingerprint match)
#
# DEFERRED to subsequent T-1 follow-up sessions:
#   - G6 install-side label sentinel (transitively preserved via cp -R
#     installer/; render-launchd.sh enforces at runtime)
#   - claude-mem preservation policy full implementation (T-1.5 must
#     bundle plugins/claude-mem/v<VERSION>/ first; install.sh slice
#     tolerates absence with informational log + flag matrix wired)
#   - Top-level exit code 20 (conflict-manifest workflow; v2.1 rsync
#     backup-before-merge surface)
#   - Top-level exit code 22 (rsync-backup actual failure; v2.1 surface
#     distinct from G3's prove-the-destination-works check at exit 53)
#   - Top-level exit code 60 (grep-audit hit on installed tree; v2.1
#     consumer integration of tools/grep-audit.sh)
#
# Exit codes (slice subset; S59 + S60 + S64 + S65 + S66):
#   0   success (includes G9 dry-run JSON emit)
#   10  prereq missing (CLAUDE_HOME unset/empty per G1-pre; required binary
#                       absent; SOURCE_REPO not a foundation-repo)
#   11  permission/write failure (includes G10 provenance-write failure;
#                       --no-preserve-config without --force-install)
#   21  state=user-only without --force-install ($CLAUDE_HOME contains    [S66]
#       only non-foundation content; refuses to risk overwriting an
#       unrelated installation)
#   30  schema parse failure (post-install)
#   40  settings.json merge conflict requires human resolution (jq error)
#   51  G1-main fired ($HOME/.claude equality + non-foundation content,    [S60]
#       missing --force-install or I-UNDERSTAND-OVERWRITE-RISK sentinel)
#   52  G2 fired (foreign-content sha256 drift in foundation files,        [S64]
#       missing --force-install or I-UNDERSTAND-OVERWRITE-RISK sentinel)
#   53  G3 fired (backup proof-of-life: --backup-dir absent when           [S65]
#       destructive op pending; or supplied --backup-dir not writable
#       or round-trip-broken)
#   54  G4 fired (vault-symlink reachable under $CLAUDE_HOME; no override) [S65]
#   55  G5 fired ($PLANS_HOME contains NN-*/ plans without                 [S65]
#       --retrofit-existing)
#   57  G7 fired (settings.json merge would silently delete keys)
#   58  G8 fired (UID 0; no override)                                      [S65]
#   59  G9 RESERVED — dry-run default is the posture (not refuse-gate);    [S66]
#       --apply required to leave dry-run. 59 is allocated per spec but
#       cannot fire under current implementation (any dry-run violation
#       would be a code-tampering condition).
#
# R-23 bash 3.2 compat. R-37 single-deliverable. R-55 zero $HOME/.claude
# resolution paths in script body (literal $HOME/.claude appears only in
# the AC #1 / G1-pre user-facing error text per spec.md L74 and the G1-main
# string-equality comparison per spec.md L75). G4 resolves $HOME/Documents/
# Obsidian Vault/ as a DETECTION target only — never a write target.

set -u

# --- diagnostics ---
# info() routes to stderr in dry-run mode (APPLY_MODE=0) so the G9 action-plan
# JSON on stdout stays valid for jq parsing. In --apply mode, info() goes to
# stdout per the existing test contract (install-g1 T3.2 stdout grep
# "sentinel verified"; install-g2 T3.2 "G2 sentinel verified"; install-g3-g10
# T1.2 "G3: backup proof-of-life passed").
diag() { printf 'install FAIL: %s\n' "$1" >&2; }
info() {
  if [ "${APPLY_MODE:-0}" = "0" ]; then
    printf 'install: %s\n' "$1" >&2
  else
    printf 'install: %s\n' "$1"
  fi
}
warn() { printf 'install WARN: %s\n' "$1" >&2; }

# --- argv parse (in-memory only; no FS; pre-G1-pre to keep 100ms bound) ---
FORCE_INSTALL=0
FORCE_ALL=0
NO_PRESERVE_CONFIG=0
APPLY_MODE=0
BACKUP_DIR=""
RETROFIT_EXISTING=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)                APPLY_MODE=1 ;;
    --force-install)        FORCE_INSTALL=1 ;;
    --force-all)            FORCE_ALL=1 ;;
    --no-preserve-config)   NO_PRESERVE_CONFIG=1 ;;
    --backup-dir)           shift; BACKUP_DIR="${1:-}" ;;
    --backup-dir=*)         BACKUP_DIR="${1#--backup-dir=}" ;;
    --retrofit-existing)    RETROFIT_EXISTING=1 ;;
    *)                      ;;
  esac
  shift
done

# --- flag mutual-exclusion (S66; spec.md §claude-mem Preservation Policy L138) ---
# --no-preserve-config requires --force-install. Pre-flight refuse — fires
# before any guard / FS work. Exit 11 (permission/write failure family;
# argv-mismatch precondition for the destructive claude-mem path).
if [ "$NO_PRESERVE_CONFIG" = "1" ] && [ "$FORCE_INSTALL" != "1" ]; then
  diag "--no-preserve-config requires --force-install (gating prevents accidental claude-mem config clobber per spec §claude-mem Preservation Policy). Pass both flags together."
  exit 11
fi

# --- sentinel-verified flag (G1-main + G2 share single ceremony per S64) ---
# Set to 1 after the first successful I-UNDERSTAND-OVERWRITE-RISK prompt; later
# guards consult it to avoid re-prompting in the same install invocation.
sentinel_verified=0

# --- G8: UID-0 refuse (S65; spec.md L82) ---
# Fires before any FS work or env evaluation. Unconditional — no --force override.
# Root context broadens blast radius irreversibly (April-13 protection).
g8_uid="$(id -u 2>/dev/null || echo unknown)"
if [ "$g8_uid" = "0" ]; then
  diag "G8 fired: install.sh refuses to run as UID 0 (root). Re-run as a non-root user."
  exit 58
fi

# --- G1-pre: CLAUDE_HOME unset/empty preflight (AC #2; spec.md L74) ---
# Fires BEFORE binary check / SOURCE_REPO resolve / any mkdir. No FS writes.
# Acceptance: headless exit within 100ms.
if [ -z "${CLAUDE_HOME:-}" ]; then
  diag "CLAUDE_HOME not set. Export CLAUDE_HOME=\$HOME/.claude or a custom path before running install.sh. Never rely on \$HOME/.claude implicit default — hard-fail is required for installer safety."
  exit 10
fi

# --- prereq binary check ---
for bin in jq python3 plutil; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    diag "missing prereq binary: $bin"
    exit 10
  fi
done

# --- resolve foundation-repo source ---
# install.sh lives at top of foundation-repo. SOURCE_REPO env-overridable for
# tests; default = directory containing this script.
script_path="${BASH_SOURCE[0]:-$0}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
SOURCE_REPO="${SOURCE_REPO:-$script_dir}"

if [ ! -d "$SOURCE_REPO/hooks" ] || [ ! -d "$SOURCE_REPO/skills" ] || [ ! -d "$SOURCE_REPO/schemas" ]; then
  diag "SOURCE_REPO does not look like a foundation-repo (missing hooks/, skills/, or schemas/): $SOURCE_REPO"
  exit 10
fi

# --- G5: $PLANS_HOME plan-dir guard (S65; spec.md L79) ---
# Refuse if $PLANS_HOME contains existing NN-*/ plans without
# --retrofit-existing. Foundation ships zero plans; the flag is currently a
# v2.1 waiver stub (no retrofit logic implemented) but the gate is
# load-bearing — without it, an install onto a pre-existing plan-tracking
# tree would be silently underspecified.
PLANS_HOME="${PLANS_HOME:-$HOME/.claude-plans}"
g5_existing_plans=""
g5_existing_count=0
if [ -d "$PLANS_HOME" ]; then
  for entry in "$PLANS_HOME"/[0-9][0-9]-*/; do
    [ -d "$entry" ] || continue
    base="${entry%/}"
    base="${base##*/}"
    if [ -z "$g5_existing_plans" ]; then
      g5_existing_plans="$base"
    else
      g5_existing_plans="$g5_existing_plans
$base"
    fi
    g5_existing_count=$((g5_existing_count + 1))
  done
fi
if [ "$g5_existing_count" -gt 0 ]; then
  if [ "$RETROFIT_EXISTING" != "1" ]; then
    diag "G5 fired: \$PLANS_HOME contains $g5_existing_count existing NN-*/ plan(s); pass --retrofit-existing to acknowledge (v2.1 retrofit logic deferred — flag currently waives only). \$PLANS_HOME=$PLANS_HOME"
    printf '%s\n' "$g5_existing_plans" | while IFS= read -r p; do
      [ -z "$p" ] || printf '  %s\n' "$p" >&2
    done
    exit 55
  fi
  warn "G5: --retrofit-existing supplied with $g5_existing_count pre-existing plan(s); v2.1 retrofit logic NOT YET IMPLEMENTED — flag is a waiver stub. Proceeding under explicit user waiver; install does not modify \$PLANS_HOME."
fi

# --- G1-main: $HOME/.claude equality gate (AC #3; spec.md L75) ---
# Refuse if $CLAUDE_HOME == $HOME/.claude AND target exists with non-foundation
# content, unless --force-install AND I-UNDERSTAND-OVERWRITE-RISK sentinel typed.
# String comparison (not resolution) per R-55 carve-out.
foundation_known_entries="hooks skills schemas onboarding orchestrator templates plugins Library installer logs governance settings.json settings.local.json foundation-manifest.json CLAUDE.md projects"

g1_main_has_non_foundation_content() {
  local d="$1"
  [ -d "$d" ] || return 1
  local entry base known found
  for entry in "$d"/* "$d"/.[!.]*; do
    [ -e "$entry" ] || continue
    base="${entry##*/}"
    found=0
    for known in $foundation_known_entries; do
      if [ "$base" = "$known" ]; then
        found=1
        break
      fi
    done
    if [ "$found" = "0" ]; then
      return 0
    fi
  done
  return 1
}

if [ "$CLAUDE_HOME" = "$HOME/.claude" ] && [ -d "$CLAUDE_HOME" ]; then
  if g1_main_has_non_foundation_content "$CLAUDE_HOME"; then
    if [ "$FORCE_INSTALL" != "1" ]; then
      diag "G1-main fired: \$CLAUDE_HOME equals \$HOME/.claude AND target contains non-foundation content. Pass --force-install AND type I-UNDERSTAND-OVERWRITE-RISK sentinel to proceed (April-13 protection)."
      exit 51
    fi
    printf 'install: type I-UNDERSTAND-OVERWRITE-RISK to confirm: ' >&2
    sentinel=""
    if ! IFS= read -r sentinel; then
      diag "G1-main fired: sentinel not provided (stdin EOF). Aborting."
      exit 51
    fi
    if [ "$sentinel" != "I-UNDERSTAND-OVERWRITE-RISK" ]; then
      diag "G1-main fired: sentinel mismatch. Expected literal 'I-UNDERSTAND-OVERWRITE-RISK'. Aborting."
      exit 51
    fi
    sentinel_verified=1
    info "G1-main sentinel verified; proceeding under --force-install"
  fi
fi

# --- G4: vault-symlink distance check (S65; spec.md L78) ---
# If ~/Documents/Obsidian Vault/ is reachable via symlink under $CLAUDE_HOME,
# refuse unconditionally. April-13 protection: vault was symlinked into
# .claude (Plans/ → vault/Plans), bootstrap clobbered the vault. NO override.
# Detection-only path resolution; never a write target.
g4_vault_canonical=""
if [ -d "$HOME/Documents/Obsidian Vault" ]; then
  g4_vault_canonical="$(cd "$HOME/Documents/Obsidian Vault" 2>/dev/null && pwd -P)"
fi
g4_violations=""
g4_violation_count=0
if [ -n "$g4_vault_canonical" ] && [ -d "$CLAUDE_HOME" ]; then
  while IFS= read -r symlink; do
    [ -z "$symlink" ] && continue
    resolved="$(readlink -f "$symlink" 2>/dev/null || true)"
    [ -z "$resolved" ] && continue
    case "$resolved" in
      "$g4_vault_canonical"|"$g4_vault_canonical"/*)
        if [ -z "$g4_violations" ]; then
          g4_violations="$symlink -> $resolved"
        else
          g4_violations="$g4_violations
$symlink -> $resolved"
        fi
        g4_violation_count=$((g4_violation_count + 1))
        ;;
    esac
  done <<EOF
$(find "$CLAUDE_HOME" -type l 2>/dev/null)
EOF
fi
if [ "$g4_violation_count" -gt 0 ]; then
  diag "G4 fired: \$CLAUDE_HOME contains $g4_violation_count symlink(s) reaching ~/Documents/Obsidian Vault/. April-13 protection — refuse unconditionally (no --force override; vault clobber prevention)."
  printf '%s\n' "$g4_violations" | while IFS= read -r v; do
    [ -z "$v" ] || printf '  %s\n' "$v" >&2
  done
  exit 54
fi

info "CLAUDE_HOME=$CLAUDE_HOME"
info "SOURCE_REPO=$SOURCE_REPO"

# --- state-tier env-var resolution (SP15 T-1b — §A60 + L-95 two-root topology) ---
# $VAULT_WRITER_STATE_ROOT default ~/.local/share/claude-stem/vault-writers/
#   Durable second-brain artifacts (manifest.sqlite, raw retention,
#   daily-processing, per-writer history). XDG-compliant; backup-included by
#   Time Machine/restic defaults via ~/.local/share/.
# $CLAUDE_STATE_ROOT default ~/.local/state/claude-stem/
#   Ephemeral Claude-runtime (staging packets, locks, queues). Rebuildable.
# Decision rule (§A60): "would this survive a Claude reinstall + harness
#   switch?" YES → $VAULT_WRITER_STATE_ROOT; NO → $CLAUDE_STATE_ROOT.
# Overrides honored when exported pre-invocation; defaults applied when unset.
VAULT_WRITER_STATE_ROOT="${VAULT_WRITER_STATE_ROOT:-$HOME/.local/share/claude-stem/vault-writers}"
CLAUDE_STATE_ROOT="${CLAUDE_STATE_ROOT:-$HOME/.local/state/claude-stem}"
info "VAULT_WRITER_STATE_ROOT=$VAULT_WRITER_STATE_ROOT"
info "CLAUDE_STATE_ROOT=$CLAUDE_STATE_ROOT"

# --- G2: foreign-content detector (S64; spec §Installer firewall guards) ---
# Walks $CLAUDE_HOME for files inside foundation-known directories whose
# relative path is tracked by $SOURCE_REPO/foundation-manifest.json baseline
# but whose actual sha256 differs (drift). Files NOT in baseline (user
# content under a foundation directory; hooks/state/ session files; etc.)
# are not violations — cp -n preserves them naturally.
#
# Refuses install on any violation unless --force-install AND
# I-UNDERSTAND-OVERWRITE-RISK sentinel typed (sentinel reused from G1-main if
# both fire in the same session; single ceremony per session).
#
# Skip conditions (G2 is a no-op):
#   - $CLAUDE_HOME does not exist (fresh install, mkdir-p ahead)
#   - $SOURCE_REPO/foundation-manifest.json absent (T-5 baseline not yet
#     generated; warns; cannot compare without baseline)
#   - jq extraction failure (warns; degrade-open rather than wedge install)
g2_violations=""
g2_violation_count=0

g2_detect_foreign_content() {
  local manifest_src="$SOURCE_REPO/foundation-manifest.json"

  if [ ! -f "$manifest_src" ]; then
    info "G2: foundation-manifest.json absent at SOURCE_REPO; foreign-content detection skipped"
    return 0
  fi
  if [ ! -d "$CLAUDE_HOME" ]; then
    return 0
  fi

  local baseline_tmp
  baseline_tmp="$(mktemp -t install-g2-baseline.XXXXXX 2>/dev/null)" || {
    warn "G2: tmp allocation failed; foreign-content detection skipped"
    return 0
  }
  if ! jq -r '.files[] | "\(.path)\t\(.sha256)"' "$manifest_src" > "$baseline_tmp" 2>/dev/null; then
    warn "G2: foundation-manifest.json files[] extraction failed; foreign-content detection skipped"
    rm -f "$baseline_tmp"
    return 0
  fi

  local entry base known found f rel sha_actual sha_baseline
  for entry in "$CLAUDE_HOME"/* "$CLAUDE_HOME"/.[!.]*; do
    [ -e "$entry" ] || continue
    base="${entry##*/}"
    found=0
    for known in $foundation_known_entries; do
      if [ "$base" = "$known" ]; then
        found=1
        break
      fi
    done
    [ "$found" = "0" ] && continue          # non-foundation entry (G1-main domain)
    [ -d "$entry" ] || continue              # only walk directories
    [ "$base" = "logs" ] && continue         # logs/ is append-only provenance

    while IFS= read -r f; do
      [ -z "$f" ] && continue
      rel="${f#$CLAUDE_HOME/}"
      sha_baseline="$(awk -F'\t' -v p="$rel" '$1 == p {print $2; exit}' "$baseline_tmp")"
      [ -z "$sha_baseline" ] && continue   # not in baseline = user content
      sha_actual="$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')"
      if [ "$sha_actual" != "$sha_baseline" ]; then
        if [ -z "$g2_violations" ]; then
          g2_violations="$rel"
        else
          g2_violations="$g2_violations
$rel"
        fi
        g2_violation_count=$((g2_violation_count + 1))
      fi
    done <<EOF
$(find "$entry" -type f 2>/dev/null)
EOF
  done

  rm -f "$baseline_tmp"
}

g2_detect_foreign_content

if [ "$g2_violation_count" -gt 0 ]; then
  diag "G2 fired: foreign content (sha256 drift) detected in $g2_violation_count foundation file(s):"
  printf '%s\n' "$g2_violations" | while IFS= read -r p; do
    [ -z "$p" ] || printf '  %s\n' "$p" >&2
  done
  if [ "$FORCE_INSTALL" != "1" ]; then
    diag "Pass --force-install AND type I-UNDERSTAND-OVERWRITE-RISK sentinel to proceed (cp -n preserves your edits; April-13 protection)."
    exit 52
  fi
  if [ "$sentinel_verified" = "1" ]; then
    info "G2: sentinel reused from G1-main; proceeding under --force-install"
  else
    printf 'install: type I-UNDERSTAND-OVERWRITE-RISK to confirm G2 override: ' >&2
    sentinel=""
    if ! IFS= read -r sentinel; then
      diag "G2 fired: sentinel not provided (stdin EOF). Aborting."
      exit 52
    fi
    if [ "$sentinel" != "I-UNDERSTAND-OVERWRITE-RISK" ]; then
      diag "G2 fired: sentinel mismatch. Expected literal 'I-UNDERSTAND-OVERWRITE-RISK'. Aborting."
      exit 52
    fi
    sentinel_verified=1
    info "G2 sentinel verified; proceeding under --force-install"
  fi
fi

# --- State classification (S66; spec §write sequence + §Installer exit codes 21) ---
# Walks $CLAUDE_HOME entries and classifies state once after G2 close + before
# G3 gate. Reuses foundation_known_entries set already declared at L172 for
# basename matching.
#   - fresh             — $CLAUDE_HOME does not exist OR exists but is empty
#   - foundation-only   — every top-level entry matches foundation-known set
#   - mixed             — at least one foundation entry + at least one non-
#                          foundation entry (cp -n preserves non-foundation;
#                          proceeds normally)
#   - user-only         — at least one entry, NONE matches foundation-known
#                          (refuse without --force-install → exit 21)
# user-only is the new April-13-class protection: $CLAUDE_HOME pointed at
# someone else's installation. G1-main covers the $HOME/.claude case at 51;
# state-classify covers any $CLAUDE_HOME-equal-to-non-foundation-tree at 21.
state_classification="unknown"
if [ ! -d "$CLAUDE_HOME" ]; then
  state_classification="fresh"
else
  # Walk NON-HIDDEN top-level entries only. Foundation has zero top-level
  # dotfiles; hidden entries are typically user config / test artifacts /
  # transient redirects, NOT a separate installation. G1-main retains its
  # broader dotfile walk for the more targeted $HOME/.claude protection (51);
  # state-classify is the looser non-$HOME/.claude protection (21).
  state_has_foundation=0
  state_has_non_foundation=0
  state_has_any=0
  state_non_foundation_list=""
  for entry in "$CLAUDE_HOME"/*; do
    [ -e "$entry" ] || continue
    state_has_any=1
    base="${entry##*/}"
    matched=0
    for known in $foundation_known_entries; do
      if [ "$base" = "$known" ]; then
        matched=1
        break
      fi
    done
    if [ "$matched" = "1" ]; then
      state_has_foundation=1
    else
      state_has_non_foundation=1
      if [ -z "$state_non_foundation_list" ]; then
        state_non_foundation_list="$base"
      else
        state_non_foundation_list="$state_non_foundation_list
$base"
      fi
    fi
  done
  if [ "$state_has_any" = "0" ]; then
    state_classification="fresh"
  elif [ "$state_has_foundation" = "1" ] && [ "$state_has_non_foundation" = "0" ]; then
    state_classification="foundation-only"
  elif [ "$state_has_foundation" = "0" ] && [ "$state_has_non_foundation" = "1" ]; then
    state_classification="user-only"
  else
    state_classification="mixed"
  fi
fi

if [ "$state_classification" = "user-only" ] && [ "$FORCE_INSTALL" != "1" ]; then
  diag "state=user-only fired: \$CLAUDE_HOME contains only non-foundation content; pass --force-install to acknowledge installer is overwriting a non-foundation tree (April-13-class protection — distinct from G1-main \$HOME/.claude equality at 51). Non-foundation entries:"
  printf '%s\n' "$state_non_foundation_list" | while IFS= read -r p; do
    [ -z "$p" ] || printf '  %s\n' "$p" >&2
  done
  exit 21
fi
info "state classification: $state_classification"

# --- G3: backup proof-of-life (S65; spec.md L77) ---
# Last gate before destructive ops (Step 12 settings.json mv -f). Two trigger
# conditions:
#   (a) --backup-dir supplied → validate writability + round-trip regardless
#       of destructive-op state (catches typos / unwritable paths early).
#   (b) destructive op pending ($CLAUDE_HOME/settings.json pre-exists) AND
#       --backup-dir absent → exit 53 (no backup → no install).
# Fresh install (no settings.json yet) without --backup-dir is a no-op
# (cp -n preserves all other files; mkdir -p is idempotent).
g3_destructive_op_pending=0
if [ -f "$CLAUDE_HOME/settings.json" ]; then
  g3_destructive_op_pending=1
fi
g3_proof_of_life_passed=0
g3_skip_reason=""
if [ -n "$BACKUP_DIR" ]; then
  if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
    diag "G3 fired: --backup-dir not creatable: $BACKUP_DIR"
    exit 53
  fi
  g3_test_file="$BACKUP_DIR/.install-g3-proof-$$"
  if ! ( printf 'g3-roundtrip\n' > "$g3_test_file" ) 2>/dev/null; then
    diag "G3 fired: --backup-dir not writable (round-trip test failed): $BACKUP_DIR"
    rm -f "$g3_test_file" 2>/dev/null
    exit 53
  fi
  if [ ! -f "$g3_test_file" ] || [ "$(cat "$g3_test_file" 2>/dev/null)" != "g3-roundtrip" ]; then
    diag "G3 fired: --backup-dir round-trip readback mismatch: $BACKUP_DIR"
    rm -f "$g3_test_file" 2>/dev/null
    exit 53
  fi
  rm -f "$g3_test_file" 2>/dev/null
  g3_proof_of_life_passed=1
  info "G3: backup proof-of-life passed at $BACKUP_DIR"
elif [ "$g3_destructive_op_pending" = "1" ]; then
  diag "G3 fired: \$CLAUDE_HOME/settings.json pre-exists (destructive op pending); --backup-dir <path> required for proof-of-life. No backup → no install."
  exit 53
else
  g3_skip_reason="no destructive op pending (no pre-existing settings.json) and --backup-dir not supplied"
fi

# --- G9: dry-run as default (S66; spec.md L83) ---
# Posture (not refuse-gate). First invocation without --apply emits action-plan
# JSON to stdout with zero $CLAUDE_HOME writes; --apply required to actually
# install. Position: G9 fires AFTER all pre-flight guards (G1-pre, G8, G1-main,
# G4, G2, state-classify, G3) but BEFORE Step 1 mkdir — the action-plan
# reflects state validated by every guard. NO --force override (G9 is posture,
# not refuse). Exit 0 from dry-run; provenance log NOT written (zero FS
# writes by design).
if [ "$APPLY_MODE" != "1" ]; then
  # JSON action-plan emit. Validity contract: jq parseable. Schema:
  #   {version, claude_home, source_repo, state_classification, flags{...},
  #    guards_passed[], actions[{step, op, target, source, rationale}], deferred[]}
  cat <<JSON
{
  "version": "1",
  "claude_home": "$CLAUDE_HOME",
  "source_repo": "$SOURCE_REPO",
  "state_classification": "$state_classification",
  "flags": {
    "force_install": $FORCE_INSTALL,
    "force_all": $FORCE_ALL,
    "no_preserve_config": $NO_PRESERVE_CONFIG,
    "retrofit_existing": $RETROFIT_EXISTING,
    "backup_dir": "${BACKUP_DIR:-}"
  },
  "guards_passed": ["G1-pre", "G1-main", "G2", "G3", "G4", "G5", "G7", "G8"],
  "actions": [
    {"step": 1, "op": "mkdir", "target": "$CLAUDE_HOME/{hooks,hooks/lib,hooks/state,hooks/config,skills,schemas,onboarding,orchestrator,templates,templates/launchd,templates/settings-fragments,plugins,Library/LaunchAgents.staging,installer,logs,governance,governance/file-type-contracts,governance/librarian-capabilities,governance/onboarding-reference}", "rationale": "create target tree (SP15 T-1a: governance/ subtree added)"},
    {"step": 1.5, "op": "mkdir+symlink", "target": "$VAULT_WRITER_STATE_ROOT/{,daily-processing,raw} + $CLAUDE_STATE_ROOT/{,vault-staging,vault-staging/_archive} + $CLAUDE_HOME/state symlink → $CLAUDE_STATE_ROOT", "rationale": "create v3 two-root state-tier scaffold (SP15 T-1b §A60 + L-95): durable second-brain root + ephemeral Claude-runtime root + back-compat symlink at $CLAUDE_HOME/state for one release cycle (deprecated; remove in v4)"},
    {"step": 2, "op": "cp", "target": "$CLAUDE_HOME/hooks/", "source": "$SOURCE_REPO/hooks/{*.sh,*.md,MANIFEST.txt}", "rationale": "ship hook entry-points + MANIFEST (pre-asq-guard.sh ships via wildcard per SP15 T-1a)"},
    {"step": 3, "op": "cp", "target": "$CLAUDE_HOME/hooks/lib/", "source": "$SOURCE_REPO/lib/{*.sh,*.sql}", "rationale": "ship hook libs (lib/ to hooks/lib/ translation per A4; SP15 T-1a: *.sql wildcard ships manifest-migrate.sql companion to manifest-record.sh)"},
    {"step": 4, "op": "cp", "target": "$CLAUDE_HOME/hooks/config/", "source": "$SOURCE_REPO/hooks/config/", "rationale": "ship hook config JSON"},
    {"step": 5, "op": "cp", "target": "$CLAUDE_HOME/skills/", "source": "$SOURCE_REPO/skills/{12 named}/", "rationale": "ship 12 named skill subtrees recursively (SP15 T-1a adds govern + doc-amender + writer-reconciler; writer-reconciler replaces retired inbox-processor)"},
    {"step": 6, "op": "cp", "target": "$CLAUDE_HOME/onboarding/", "source": "$SOURCE_REPO/onboarding/", "rationale": "ship onboarding subtree"},
    {"step": 7, "op": "cp", "target": "$CLAUDE_HOME/orchestrator/", "source": "$SOURCE_REPO/orchestrator/", "rationale": "ship orchestrator subtree"},
    {"step": 8, "op": "cp", "target": "$CLAUDE_HOME/installer/", "source": "$SOURCE_REPO/installer/", "rationale": "ship installer subtree (G6 LABEL_PREFIX preserved transitively)"},
    {"step": 8.5, "op": "cp", "target": "$CLAUDE_HOME/governance/", "source": "$SOURCE_REPO/governance/", "rationale": "ship v3 governance subtree (SP15 T-1a NEW): 8 pillars + librarian-capabilities/ + file-type-contracts/ + onboarding-reference/ (foundation-master.json regen at T-4 lands on top)"},
    {"step": 9, "op": "cp", "target": "$CLAUDE_HOME/schemas/", "source": "$SOURCE_REPO/schemas/{14 named}.json", "rationale": "ship 14 named schemas + README (SP15 T-1a adds 6 SP14 schemas: overlay-master + governance-action-log + vault-writers-rules + processing-rules + plans-rules + writer-manifest; SP15 T-1a also retires vault-overlay-schema reference per SP14 Batch A schema deletion)"},
    {"step": 10, "op": "cp", "target": "$CLAUDE_HOME/templates/", "source": "$SOURCE_REPO/templates/{settings,librarian-manifest-skeleton,README,vault-claude-md,claude-home-claude-md,MEMORY,updates,prd,connector-brief,context}+{launchd,settings-fragments}/", "rationale": "ship templates + launchd tmpl + settings-fragments (SP15 T-1a adds updates/prd/connector-brief/context shape templates)"},
    {"step": 11, "op": "cp", "target": "$CLAUDE_HOME/plugins/claude-mem/", "source": "$SOURCE_REPO/plugins/claude-mem/v*/", "rationale": "ship claude-mem bundle if present (T-1.5 deferred; absence informational)"},
    {"step": 11.5, "op": "seed", "target": "$CLAUDE_HOME/CLAUDE.md", "source": "$CLAUDE_HOME/templates/claude-home-claude-md-template.md", "rationale": "seed claude-home CLAUDE.md with identity substitution from user-manifest.json (no clobber without --force-install + sentinel; SP10 T-4)"},
    {"step": 12, "op": "jq-merge", "target": "$CLAUDE_HOME/settings.json", "source": "$CLAUDE_HOME/templates/settings.json", "rationale": "atomic deep-merge with G7 silent-key-deletion gate"},
    {"step": 13, "op": "validate", "target": "$CLAUDE_HOME/schemas/*.json", "rationale": "post-install schema parse validation"},
    {"step": 14, "op": "cp", "target": "$CLAUDE_HOME/foundation-manifest.json", "source": "$SOURCE_REPO/foundation-manifest.json", "rationale": "ship T-5 baseline (slice tolerates absence with warn)"},
    {"step": 15, "op": "log", "target": "$CLAUDE_HOME/logs/install-*.log", "rationale": "G10 provenance log header emit"}
  ],
  "deferred": ["G6-install-side-explicit-sentinel", "20-conflict-manifest-v2.1", "22-rsync-backup-v2.1", "60-grep-audit-consumer-v2.1"]
}
JSON
  exit 0
fi

# --- 14-asset write sequence (per spec.md L240-255 audit-2026-04-29) ---

# cp clobber posture (S66): default --force-all=0 → cp -n (no clobber, preserves
# user-edited foundation files; G2 baseline-mismatch covers drift detection).
# --force-all=1 → cp -f (overwrite foundation-known files unconditionally).
# claude-mem at Step 11 has its own clobber posture per --no-preserve-config.
cp_clobber="-n"
[ "$FORCE_ALL" = "1" ] && cp_clobber="-f"

# Step 1: mkdir -p target tree
target_dirs="hooks hooks/lib hooks/state hooks/config skills schemas onboarding orchestrator templates templates/launchd templates/settings-fragments plugins Library/LaunchAgents.staging installer logs governance governance/file-type-contracts governance/librarian-capabilities governance/onboarding-reference"
for d in $target_dirs; do
  mkdir -p "$CLAUDE_HOME/$d" || { diag "mkdir failed: $CLAUDE_HOME/$d"; exit 11; }
done

# Step 1.5: state-tier scaffold (SP15 T-1b — v3 two-root topology per §A60 + L-95)
# Creates the two state roots + subdirectory scaffolds OUTSIDE $CLAUDE_HOME and
# the back-compat symlink at $CLAUDE_HOME/state → $CLAUDE_STATE_ROOT for one
# release cycle (deprecated; remove in v4). Env vars resolved earlier; defaults
# honor XDG ~/.local/share/ + ~/.local/state/ conventions per §A60.
#
# Subdirectories per spec §1.5:
#   $VAULT_WRITER_STATE_ROOT/                 durable root
#   $VAULT_WRITER_STATE_ROOT/daily-processing/ empty; reconciler creates
#                                              per-day subdirs at runtime
#                                              (L-99 + A61)
#   $VAULT_WRITER_STATE_ROOT/raw/             raw retention (L-97 + A60);
#                                              mandatory for writer_kind ∈
#                                              {agentic-flow, auto-research}
#   $CLAUDE_STATE_ROOT/                       ephemeral root
#   $CLAUDE_STATE_ROOT/vault-staging/         replaces former
#                                              ~/.claude/state/vault-staging/
#   $CLAUDE_STATE_ROOT/vault-staging/_archive/ empty
#
# Idempotent: mkdir -p tolerates existing dirs (re-install safe). Back-compat
# symlink uses G2-style protection — only created if absent OR already
# pointing at $CLAUDE_STATE_ROOT. Existing real directory at $CLAUDE_HOME/state
# (pre-v3 installs) is left untouched with a warn; operator must migrate
# contents before v4 removes the symlink. Existing symlink to a different
# target is left untouched with a warn.
#
# OUT OF SCOPE for T-1b (later sub-tasks):
#   - manifest.sqlite bootstrap at $VAULT_WRITER_STATE_ROOT/manifest.sqlite (T-1c)
#   - empty governance-action-log.jsonl initializer (T-1c)
#   - empty overlay-master.json skeleton at $CLAUDE_HOME/governance/ (T-1f)
#   - meeting-processor-state migration (T-2)
state_tier_dirs="$VAULT_WRITER_STATE_ROOT $VAULT_WRITER_STATE_ROOT/daily-processing $VAULT_WRITER_STATE_ROOT/raw $CLAUDE_STATE_ROOT $CLAUDE_STATE_ROOT/vault-staging $CLAUDE_STATE_ROOT/vault-staging/_archive"
for d in $state_tier_dirs; do
  mkdir -p "$d" || { diag "state-tier mkdir failed: $d"; exit 11; }
done

backcompat_link="$CLAUDE_HOME/state"
if [ -L "$backcompat_link" ]; then
  current_target="$(readlink "$backcompat_link")"
  if [ "$current_target" = "$CLAUDE_STATE_ROOT" ]; then
    info "state back-compat symlink already correct: $backcompat_link → $CLAUDE_STATE_ROOT"
  else
    warn "state back-compat symlink exists at $backcompat_link pointing to $current_target (expected $CLAUDE_STATE_ROOT); leaving unchanged"
  fi
elif [ -e "$backcompat_link" ]; then
  warn "state back-compat target $backcompat_link exists as non-symlink (pre-v3 real directory); leaving unchanged. Operator must migrate contents into $CLAUDE_STATE_ROOT before v4 removes the symlink convention."
else
  ln -s "$CLAUDE_STATE_ROOT" "$backcompat_link" || { diag "state back-compat symlink creation failed: $backcompat_link → $CLAUDE_STATE_ROOT"; exit 11; }
  info "state back-compat symlink created: $backcompat_link → $CLAUDE_STATE_ROOT (deprecated; v4 removal)"
fi

# Step 2: hooks/*.sh + hooks/*.md + MANIFEST → $CLAUDE_HOME/hooks/
# (cp -n: never clobber; honors user-edited variants)
for f in "$SOURCE_REPO/hooks"/*.sh "$SOURCE_REPO/hooks"/*.md "$SOURCE_REPO/hooks/MANIFEST.txt"; do
  [ -e "$f" ] || continue
  cp $cp_clobber "$f" "$CLAUDE_HOME/hooks/" 2>/dev/null || true
done

# Step 3: lib/ → hooks/lib/  (translation per spec.md L242 + A4)
# SP15 T-1a: lib/*.sql added to ship manifest-migrate.sql (companion to
# lib/manifest-record.sh; consumed at T-1c manifest.sqlite bootstrap).
for f in "$SOURCE_REPO/lib"/*.sh "$SOURCE_REPO/lib"/*.sql; do
  [ -e "$f" ] || continue
  cp $cp_clobber "$f" "$CLAUDE_HOME/hooks/lib/" 2>/dev/null || true
done

# Step 3.5: hooks/lib/*.{sh,json} → $CLAUDE_HOME/hooks/lib/
# (Plan 81 SP01 T-20: ship plan-agnostic gate helpers — live-guard.sh,
# l3-pause-helper.sh, l3-writer-registry.json, gate-schema-migrate.sh.
# These were authored under hooks/lib/ rather than lib/ and must be
# shipped explicitly. cp_clobber posture matches Step 3.)
for f in "$SOURCE_REPO/hooks/lib"/*.sh "$SOURCE_REPO/hooks/lib"/*.json; do
  [ -e "$f" ] || continue
  cp $cp_clobber "$f" "$CLAUDE_HOME/hooks/lib/" 2>/dev/null || true
done

# Step 4: hooks/config/*.json → $CLAUDE_HOME/hooks/config/
for f in "$SOURCE_REPO/hooks/config"/*.json; do
  [ -e "$f" ] || continue
  cp $cp_clobber "$f" "$CLAUDE_HOME/hooks/config/" 2>/dev/null || true
done

# Step 5: skills/{9 dirs} → $CLAUDE_HOME/skills/
# Slice tolerates absent skills (some land in later sub-plans); warn but proceed.
# infer-vault-structure added v2.1.2 SP16 T-6: Section F orchestrator
# (skills/onboarder/onboard.sh) + /adopt --retrofit-existing both depend on it.
for skill in librarian architect backlog-hygiene backlog-triage backlog-research morning-brief onboarder adopt infer-vault-structure govern doc-amender writer-reconciler; do
  src="$SOURCE_REPO/skills/$skill"
  if [ ! -d "$src" ]; then
    warn "skill not present in foundation-repo source: $skill (deferred to its sub-plan)"
    continue
  fi
  cp -R $cp_clobber "$src" "$CLAUDE_HOME/skills/" 2>/dev/null || true
done

# Step 6: onboarding/ → $CLAUDE_HOME/onboarding/
if [ -d "$SOURCE_REPO/onboarding" ]; then
  cp -R $cp_clobber "$SOURCE_REPO/onboarding"/. "$CLAUDE_HOME/onboarding/" 2>/dev/null || true
fi

# Step 7: orchestrator/ → $CLAUDE_HOME/orchestrator/
if [ -d "$SOURCE_REPO/orchestrator" ]; then
  cp -R $cp_clobber "$SOURCE_REPO/orchestrator"/. "$CLAUDE_HOME/orchestrator/" 2>/dev/null || true
fi

# Step 8: installer/ → $CLAUDE_HOME/installer/
# Preserves render-launchd.sh + bootout-launchd.sh with their G6 LABEL_PREFIX
# default (com.claude-stem); install.sh does NOT override this default.
if [ -d "$SOURCE_REPO/installer" ]; then
  cp -R $cp_clobber "$SOURCE_REPO/installer"/. "$CLAUDE_HOME/installer/" 2>/dev/null || true
fi

# Step 8.5: governance/ → $CLAUDE_HOME/governance/  (SP15 T-1a — v3 NEW top-level)
# Recursive cp -R; deploys the v3 8-pillar surface + librarian capabilities +
# file-type-contracts + onboarding-reference. cp_clobber posture matches the
# rest of the foundation-known tree (cp -n default; --force-all → cp -f).
# foundation-master.json regen at T-4 (release-time bundle composition) lands
# on top of whatever this step ships; no exclusion needed.
if [ -d "$SOURCE_REPO/governance" ]; then
  cp -R $cp_clobber "$SOURCE_REPO/governance"/. "$CLAUDE_HOME/governance/" 2>/dev/null || true
fi

# Step 9: schemas/ — 14 named files. SP13 P0 (2026-05-15) dropped vault-schema +
# gate-config + gate-config-schema (dissolved per SP13 T-4 pillar shard / SP13
# T-6 retirement). SP14 Batch A (2026-05-18) additionally retired
# vault-overlay-schema.json; companion config hooks/config/vault-overlay.json
# now ships unvalidated until a replacement pillar shard supersedes it.
# Remaining hooks/config/*.json companion schemas (doc-dependencies,
# drift-allowlist, cron-log-architecture-exceptions) consumed by Step 13.6
# jsonschema validation below. SP15 T-1a adds 6 new schemas (overlay-master,
# governance-action-log, vault-writers-rules, processing-rules, plans-rules,
# writer-manifest) per A60-A65.
for schema in plans-schema plan-manifest-schema librarian-manifest-schema user-manifest-schema orchestration-schema doc-dependencies-schema drift-allowlist-schema cron-log-architecture-exceptions-schema overlay-master-schema governance-action-log-schema vault-writers-rules-schema processing-rules-schema plans-rules-schema writer-manifest-schema; do
  src="$SOURCE_REPO/schemas/$schema.json"
  if [ ! -f "$src" ]; then
    diag "schema missing in source: $schema.json"
    exit 11
  fi
  cp $cp_clobber "$src" "$CLAUDE_HOME/schemas/" 2>/dev/null || true
done
# Schemas/README.md ships alongside (operator docs)
[ -f "$SOURCE_REPO/schemas/README.md" ] && \
  cp $cp_clobber "$SOURCE_REPO/schemas/README.md" "$CLAUDE_HOME/schemas/" 2>/dev/null || true

# Step 10: templates/ — settings.json + manifest skeletons + README + CLAUDE.md templates + launchd/*.tmpl + settings-fragments/
for tmpl in settings.json librarian-manifest-skeleton.json README.md vault-claude-md-template.md claude-home-claude-md-template.md MEMORY.md.template updates-template.md prd-template.md connector-brief-template.md context-template.md; do
  src="$SOURCE_REPO/templates/$tmpl"
  [ -e "$src" ] || continue
  cp $cp_clobber "$src" "$CLAUDE_HOME/templates/" 2>/dev/null || true
done
for f in "$SOURCE_REPO/templates/launchd"/*.tmpl; do
  [ -e "$f" ] || continue
  cp $cp_clobber "$f" "$CLAUDE_HOME/templates/launchd/" 2>/dev/null || true
done
for f in "$SOURCE_REPO/templates/settings-fragments"/*.json; do
  [ -e "$f" ] || continue
  cp $cp_clobber "$f" "$CLAUDE_HOME/templates/settings-fragments/" 2>/dev/null || true
done

# Step 11: plugins/claude-mem/v<VERSION>/ → $CLAUDE_HOME/plugins/claude-mem/
# T-1.5 not yet shipped — handle gracefully without failing.
#
# claude-mem clobber posture (S66; spec §claude-mem Preservation Policy L136-138):
#   - default (preserve-config ON): cp -R -n — preserves any existing
#     plugins/claude-mem/claude-mem.config.json + user/** by no-clobber.
#   - --no-preserve-config (gated on --force-install at argv parse): cp -R -f
#     — full overwrite including user config. Logged in provenance.
#   - --force-all alone does NOT toggle this (per spec L138: "--force-install
#     alone does NOT disable --preserve-config"; --force-all inherits).
cm_clobber="-n"
if [ "$NO_PRESERVE_CONFIG" = "1" ]; then
  cm_clobber="-f"
fi
claude_mem_copied=0
if [ -d "$SOURCE_REPO/plugins/claude-mem" ]; then
  for vdir in "$SOURCE_REPO/plugins/claude-mem"/v*; do
    [ -d "$vdir" ] || continue
    mkdir -p "$CLAUDE_HOME/plugins/claude-mem"
    cp -R $cm_clobber "$vdir"/. "$CLAUDE_HOME/plugins/claude-mem/" 2>/dev/null || true
    claude_mem_copied=1
    info "claude-mem bundle copied from $(basename "$vdir") (cm_clobber=$cm_clobber)"
  done
fi
if [ "$claude_mem_copied" = "0" ]; then
  info "claude-mem bundle not present in foundation-repo (T-1.5 deferred); skipping"
fi

# Step 11.5: claude-home CLAUDE.md seed (Plan 71 SP10 T-4)
# Seeds $CLAUDE_HOME/CLAUDE.md from templates/claude-home-claude-md-template.md
# with {{IDENTITY_NAME}} / {{IDENTITY_ROLE}} / {{IDENTITY_ORGANIZATION}} substituted
# from $CLAUDE_HOME/user-manifest.json. Identity values fall back to literal
# placeholder tokens if user-manifest.json is absent (pre-onboarding install) —
# the template's "What install.sh did" section instructs a re-run after /onboard.
#
# Clobber-protection (G-rule symmetry with G1-main + G2): existing CLAUDE.md is
# preserved unless --force-install AND I-UNDERSTAND-OVERWRITE-RISK sentinel verified.
# If --force-install was passed but no upstream gate (G1-main / G2) prompted for
# the sentinel, we prompt explicitly here. EOF / mismatch on the prompt
# preserves the existing file (fail-closed; no silent clobber).
template_claude_md="$CLAUDE_HOME/templates/claude-home-claude-md-template.md"
target_claude_md="$CLAUDE_HOME/CLAUDE.md"

if [ ! -f "$template_claude_md" ]; then
  warn "claude-home-claude-md-template.md not present at $template_claude_md — skipping CLAUDE.md seed"
else
  # sed-escape identity values: backslash, sed delimiter, ampersand. Strip newlines (F3 hardening).
  sed_escape() {
    printf '%s' "$1" | LC_ALL=C sed -e 's/[\\&|]/\\&/g' | tr -d '\n\r'
  }

  cm_name="{{IDENTITY_NAME}}"
  cm_role="{{IDENTITY_ROLE}}"
  cm_org="{{IDENTITY_ORGANIZATION}}"
  user_manifest="$CLAUDE_HOME/user-manifest.json"
  if [ -f "$user_manifest" ]; then
    _cm_name="$(jq -r '.identity.name // ""' "$user_manifest" 2>/dev/null)"
    _cm_role="$(jq -r '.identity.role // ""' "$user_manifest" 2>/dev/null)"
    _cm_org="$(jq -r '.identity.organization // ""' "$user_manifest" 2>/dev/null)"
    [ -n "$_cm_name" ] && [ "$_cm_name" != "null" ] && cm_name="$_cm_name"
    [ -n "$_cm_role" ] && [ "$_cm_role" != "null" ] && cm_role="$_cm_role"
    [ -n "$_cm_org" ] && [ "$_cm_org" != "null" ] && cm_org="$_cm_org"
  fi

  proceed_with_seed=1
  if [ -f "$target_claude_md" ]; then
    if [ "$FORCE_INSTALL" != "1" ]; then
      info "claude-home CLAUDE.md exists at $target_claude_md — preserving (re-run with --force-install + I-UNDERSTAND-OVERWRITE-RISK sentinel to re-seed)"
      proceed_with_seed=0
    elif [ "$sentinel_verified" != "1" ]; then
      printf 'install: type I-UNDERSTAND-OVERWRITE-RISK to confirm CLAUDE.md re-seed: ' >&2
      cm_sentinel=""
      if ! IFS= read -r cm_sentinel; then
        info "claude-home CLAUDE.md re-seed: sentinel not provided (stdin EOF) — preserving existing"
        proceed_with_seed=0
      elif [ "$cm_sentinel" != "I-UNDERSTAND-OVERWRITE-RISK" ]; then
        info "claude-home CLAUDE.md re-seed: sentinel mismatch — preserving existing"
        proceed_with_seed=0
      else
        sentinel_verified=1
        info "CLAUDE.md re-seed sentinel verified"
      fi
    fi
  fi

  if [ "$proceed_with_seed" = "1" ]; then
    cm_name_esc="$(sed_escape "$cm_name")"
    cm_role_esc="$(sed_escape "$cm_role")"
    cm_org_esc="$(sed_escape "$cm_org")"
    cm_tmp="$target_claude_md.tmp.$$"
    if ! sed \
        -e "s|{{IDENTITY_NAME}}|$cm_name_esc|g" \
        -e "s|{{IDENTITY_ROLE}}|$cm_role_esc|g" \
        -e "s|{{IDENTITY_ORGANIZATION}}|$cm_org_esc|g" \
        "$template_claude_md" > "$cm_tmp"; then
      diag "CLAUDE.md seed: sed substitution failed"
      rm -f "$cm_tmp"
      exit 11
    fi
    if ! mv -f "$cm_tmp" "$target_claude_md"; then
      diag "CLAUDE.md seed: atomic mv failed: $target_claude_md"
      rm -f "$cm_tmp"
      exit 11
    fi
    info "claude-home CLAUDE.md seeded from template (identity name: $cm_name)"
  fi
fi

# Step 11.6: MEMORY.md skeleton seed (Plan 71 SP11 T-1)
# Seeds $CLAUDE_HOME/projects/<slug>/memory/MEMORY.md from
# templates/MEMORY.md.template. Skeleton has 4 H2 section headers (User /
# Feedback / Project / Reference); per-topic memory files accumulate lazily
# (SP11 T-3 seeds 3-5 from interview answers; SessionEnd consolidation
# adds more over time).
#
# Slug convention: $CLAUDE_HOME path with / → - and leading - stripped.
# Mirrors install-time install slug; runtime claude-mem may use a different
# pwd-derived slug. Cross-slug reconciliation is out of SP11 scope.
#
# No-clobber: an existing MEMORY.md (whether template-shipped or
# user-curated) is preserved unconditionally — no --force-install path
# overwrites memory contents.
template_memory="$CLAUDE_HOME/templates/MEMORY.md.template"
mem_slug="$(printf '%s' "$CLAUDE_HOME" | tr '/' '-' | sed 's/^-//')"
mem_dir="$CLAUDE_HOME/projects/$mem_slug/memory"
mem_target="$mem_dir/MEMORY.md"

if [ ! -f "$template_memory" ]; then
  warn "MEMORY.md.template not present at $template_memory — skipping MEMORY.md seed"
elif [ -f "$mem_target" ]; then
  info "MEMORY.md exists at $mem_target — preserving (no clobber)"
else
  if ! mkdir -p "$mem_dir"; then
    diag "MEMORY.md seed: mkdir failed: $mem_dir"
    exit 11
  fi
  mem_tmp="$mem_target.tmp.$$"
  if ! cp "$template_memory" "$mem_tmp"; then
    diag "MEMORY.md seed: cp failed: $template_memory → $mem_tmp"
    rm -f "$mem_tmp"
    exit 11
  fi
  if ! mv -f "$mem_tmp" "$mem_target"; then
    diag "MEMORY.md seed: atomic mv failed: $mem_target"
    rm -f "$mem_tmp"
    exit 11
  fi
  info "MEMORY.md seeded at $mem_target"
fi

# Step 12: settings.json atomic jq-merge with G7 silent-key-deletion gate
template_settings="$CLAUDE_HOME/templates/settings.json"
target_settings="$CLAUDE_HOME/settings.json"
tmp_settings="$CLAUDE_HOME/.settings.json.tmp.$$"

if [ ! -f "$template_settings" ]; then
  diag "templates/settings.json missing post-copy"
  exit 11
fi

if [ -f "$target_settings" ]; then
  before_paths_file="$CLAUDE_HOME/.settings-before-paths.$$"
  after_paths_file="$CLAUDE_HOME/.settings-after-paths.$$"

  # All structural paths in the existing settings (G7 baseline)
  jq -c '[paths(scalars,arrays)] | sort | unique[]' "$target_settings" \
    > "$before_paths_file" 2>/dev/null || {
      diag "jq read failure on existing settings.json (malformed?); manual resolution required"
      rm -f "$before_paths_file"
      exit 40
    }

  # Deep merge: template provides defaults, user edits win on scalar conflict.
  # In jq `a * b`, b wins on scalar conflicts; objects merge recursively. Arg
  # order: template first, user second → template * user = user wins.
  if ! jq -s '.[0] * .[1]' "$template_settings" "$target_settings" > "$tmp_settings" 2>/dev/null; then
    diag "jq atomic merge failed; manual resolution required"
    rm -f "$tmp_settings" "$before_paths_file"
    exit 40
  fi

  jq -c '[paths(scalars,arrays)] | sort | unique[]' "$tmp_settings" \
    > "$after_paths_file" 2>/dev/null || {
      diag "jq read failure on merged settings.json (post-merge corruption)"
      rm -f "$tmp_settings" "$before_paths_file" "$after_paths_file"
      exit 40
    }

  # G7: every path in BEFORE must be present in AFTER. Missing path = silent deletion.
  missing="$(comm -23 "$before_paths_file" "$after_paths_file" 2>/dev/null || true)"
  rm -f "$before_paths_file" "$after_paths_file"
  if [ -n "$missing" ]; then
    diag "G7 fired: settings.json merge would silently delete the following paths:"
    printf '%s\n' "$missing" >&2
    rm -f "$tmp_settings"
    exit 57
  fi
else
  # Fresh install — copy template verbatim
  cp "$template_settings" "$tmp_settings" || { diag "cp template_settings → tmp failed"; exit 11; }
fi

# Atomic rename (G7 atomicity)
sync 2>/dev/null || true
mv -f "$tmp_settings" "$target_settings" || { diag "atomic mv failed: $target_settings"; rm -f "$tmp_settings"; exit 11; }

# Step 12.5: idempotent spec-context-inject hook registration in UserPromptSubmit
# chain (Plan 81 SP09 T-4). The template declares this hook, but Step 12 jq merge
# `template * user_settings` lets the user's array win on array conflicts — so
# re-installs against an adopter whose UserPromptSubmit chain lacks the hook
# would silently drop it. Step 12.5 detects absence and appends to the first
# bucket's hooks array (preserving user customizations); presence is a no-op
# (idempotent). Operates on the post-Step-12 result.
if [ -f "$target_settings" ]; then
  has_spec_inject=$(jq -r '
    [.hooks.UserPromptSubmit[]?.hooks[]?.command // ""]
    | map(test("spec-context-inject\\.sh"))
    | any
  ' "$target_settings" 2>/dev/null || echo "error")
  if [ "$has_spec_inject" = "false" ]; then
    tmp_settings_125="$CLAUDE_HOME/.settings.json.tmp.125.$$"
    if ! jq '
      .hooks.UserPromptSubmit |= (
        if . == null or length == 0 then
          [{"hooks":[{"type":"command","command":"~/.claude/hooks/spec-context-inject.sh","timeout":5}]}]
        else
          .[0].hooks += [{"type":"command","command":"~/.claude/hooks/spec-context-inject.sh","timeout":5}]
        end
      )
    ' "$target_settings" > "$tmp_settings_125" 2>/dev/null; then
      diag "jq spec-context-inject registration failed (Step 12.5); manual resolution required"
      rm -f "$tmp_settings_125"
      exit 40
    fi
    sync 2>/dev/null || true
    mv -f "$tmp_settings_125" "$target_settings" || { diag "atomic mv failed: $target_settings (Step 12.5)"; rm -f "$tmp_settings_125"; exit 11; }
  fi
fi

# Step 13: schema parse validation (post-install)
for schema in "$CLAUDE_HOME/schemas"/*.json; do
  [ -e "$schema" ] || continue
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$schema" 2>/dev/null; then
    diag "schema parse failure: $schema"
    exit 30
  fi
done

# Step 13.6: jsonschema validation of foundation-shipped configs (Plan 81 SP01
# S16; T-28a deferral disposition). Validates hooks/config/*.json against the
# 4 companion schemas shipped at Step 9. Graceful skip when python3 jsonschema
# module is unavailable on the adopter machine — preserves T-20 Phase A
# error_action: ignore posture (fresh adopters degrade silently at runtime
# when validation tooling absent). Adopters with jsonschema installed
# (pip3 install jsonschema) get fail-loud-at-install behavior on malformed
# configs via exit 30 (pre-allocated for "schema parse failure (post-install)").
if python3 -c "import jsonschema" 2>/dev/null; then
  for pair in \
    "doc-dependencies.json:doc-dependencies-schema.json" \
    "drift-allowlist.json:drift-allowlist-schema.json" \
    "cron-log-architecture-exceptions.json:cron-log-architecture-exceptions-schema.json"; do
    cfg_name="${pair%:*}"
    sch_name="${pair#*:}"
    cfg_path="$CLAUDE_HOME/hooks/config/$cfg_name"
    sch_path="$CLAUDE_HOME/schemas/$sch_name"
    [ -f "$cfg_path" ] || continue
    [ -f "$sch_path" ] || continue
    if ! python3 -c "import json,sys; from jsonschema.validators import Draft202012Validator; Draft202012Validator(json.load(open(sys.argv[1]))).validate(json.load(open(sys.argv[2])))" "$sch_path" "$cfg_path"; then
      diag "config schema validation failed: $cfg_path against $sch_path"
      exit 30
    fi
  done
else
  warn "python3 jsonschema module not available; install-time config-vs-schema validation skipped (pip3 install jsonschema to enable). Configs were JSON-syntax-validated by Step 13."
fi

# Step 13.5: ship foundation-manifest.json baseline (T-5 / S62)
# Generator is at $SOURCE_REPO/generate-foundation-manifest.sh; output is
# committed at $SOURCE_REPO/foundation-manifest.json at release-cut time.
# install.sh ships the static artifact (cp -n; never clobber user variant).
# Consumed by uninstall.sh fingerprint match + future G2 foreign-content
# detector (deferred to T-1 follow-up). Absence is non-fatal during the
# slice window (warns only) so install on a partial-bootstrap foundation-repo
# remains usable; T-5 baseline ships before v2.0.0-rc1 release-cut.
manifest_src="$SOURCE_REPO/foundation-manifest.json"
manifest_dst="$CLAUDE_HOME/foundation-manifest.json"
if [ -f "$manifest_src" ]; then
  cp $cp_clobber "$manifest_src" "$manifest_dst" 2>/dev/null || true
  if [ -f "$manifest_dst" ]; then
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$manifest_dst" 2>/dev/null; then
      diag "foundation-manifest.json parse failure post-copy: $manifest_dst"
      exit 30
    fi
  fi
else
  warn "foundation-manifest.json not present at SOURCE_REPO root (T-5 baseline absent; G2 + fingerprint match unavailable until generated)"
fi

# Step 14: provenance log header (G10 — write failure exits 11; AC #6 G10 live as of S65)
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log_path="$CLAUDE_HOME/logs/install-$(date -u +%Y%m%d-%H%M%S)-$$.log"
{
  printf 'install.sh provenance — Plan 71 SP08 T-1 slice (S59 + S60 + S62 + S64 + S65 + S66 G9 + flag matrix)\n'
  printf 'timestamp: %s\n'        "$ts"
  printf 'CLAUDE_HOME: %s\n'      "$CLAUDE_HOME"
  printf 'SOURCE_REPO: %s\n'      "$SOURCE_REPO"
  printf 'apply_mode: %s\n'       "$APPLY_MODE"
  printf 'dry_run: %s\n'          "0"
  printf 'action_plan_emitted: %s\n' "0"
  printf 'force_install: %s\n'    "$FORCE_INSTALL"
  printf 'force_all: %s\n'        "$FORCE_ALL"
  printf 'no_preserve_config: %s\n' "$NO_PRESERVE_CONFIG"
  printf 'state_classification: %s\n' "$state_classification"
  printf 'retrofit_existing: %s\n' "$RETROFIT_EXISTING"
  printf 'sentinel_verified: %s\n' "$sentinel_verified"
  printf 'install.sh sha256: %s\n' "$(shasum -a 256 "$0" 2>/dev/null | awk '{print $1}')"
  if [ -f "$manifest_dst" ]; then
    printf 'foundation_manifest_sha256: %s\n' "$(shasum -a 256 "$manifest_dst" 2>/dev/null | awk '{print $1}')"
  else
    printf 'foundation_manifest_sha256: (absent)\n'
  fi
  printf 'g2_violation_count: %s\n' "$g2_violation_count"
  if [ "$g2_violation_count" -gt 0 ]; then
    printf 'g2_violations:\n'
    printf '%s\n' "$g2_violations" | while IFS= read -r p; do
      [ -z "$p" ] || printf '  - %s\n' "$p"
    done
  fi
  printf 'g3_backup_dir: %s\n' "${BACKUP_DIR:-(absent)}"
  printf 'g3_destructive_op_pending: %s\n' "$g3_destructive_op_pending"
  printf 'g3_proof_of_life_passed: %s\n' "$g3_proof_of_life_passed"
  if [ -n "$g3_skip_reason" ]; then
    printf 'g3_skip_reason: %s\n' "$g3_skip_reason"
  fi
  printf 'g4_vault_canonical: %s\n' "${g4_vault_canonical:-(absent)}"
  printf 'g4_violation_count: %s\n' "$g4_violation_count"
  printf 'g5_plans_home: %s\n' "$PLANS_HOME"
  printf 'g5_existing_count: %s\n' "$g5_existing_count"
  if [ "$g5_existing_count" -gt 0 ]; then
    printf 'g5_existing_plans:\n'
    printf '%s\n' "$g5_existing_plans" | while IFS= read -r p; do
      [ -z "$p" ] || printf '  - %s\n' "$p"
    done
  fi
  printf 'g8_uid: %s\n' "$g8_uid"
  printf 'slice_scope: 14-asset write-sequence + LABEL_PREFIX preservation + settings.json atomic merge + G1-pre + G1-main equality gate + G2 foreign-content detector + I-UNDERSTAND-OVERWRITE-RISK sentinel (single-ceremony G1+G2) + G3 backup proof-of-life + G4 vault-symlink check + G5 plans-dir guard + G8 UID-0 refuse + G9 dry-run-as-default (--apply transitions out) + state classification (fresh|foundation-only|mixed|user-only; user-only refuse at 21) + --force-all flag (cp -n→cp -f for foundation files) + --no-preserve-config flag (gated on --force-install) + G10 provenance-write-failure-as-11 + foundation-manifest.json baseline copy (T-5)\n'
  printf 'deferred: G6 install-side explicit label sentinel (transitively preserved); claude-mem preservation full implementation (T-1.5 bundle); top-level exit codes 20 (conflict-manifest v2.1) / 22 (rsync-backup v2.1) / 60 (grep-audit consumer v2.1)\n'
} > "$log_path" || { diag "G10: provenance log write failed at $log_path"; exit 11; }

info "install complete (slice). next-steps:"
# SP14 T-2: post-install plist rendering walks O.jobs[] via for_each_job (sourced
# from onboarding/lib/job-iterator.sh) and invokes render-launchd.sh per declared
# job. Single-job (librarian|architect) callers may still invoke render-launchd.sh
# directly; multi-job callers (post-onboarding, post-connector-wizard) use
# render-all-launchd.sh which iterates via for_each_job over orchestration.json.
info "  - render plists for ALL declared jobs (post-onboarding):"
info "    \$CLAUDE_HOME/installer/render-all-launchd.sh --staging-dir \$CLAUDE_HOME/Library/LaunchAgents.staging"
info "  - render a single job manually:"
info "    \$CLAUDE_HOME/installer/render-launchd.sh --staging-dir \$CLAUDE_HOME/Library/LaunchAgents.staging <job-id>"
info "  - claude-mem bundle: deferred to SP08 T-1.5"
info "  - G6 install-side explicit label sentinel: deferred (transitively preserved via cp -R installer/; render-launchd.sh enforces at runtime)"
info "  - top-level exit codes 20/22/60: deferred to v2.1 (conflict-manifest, rsync-backup, grep-audit consumer)"
info "provenance: $log_path"

exit 0
