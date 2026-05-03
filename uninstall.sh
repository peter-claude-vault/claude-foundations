#!/bin/bash
# uninstall.sh — Plan 71 SP08 T-2 (S61 happy-path + S62 allowlist + S63 fingerprint match)
#
# S63 update: sha256 fingerprint match against $CLAUDE_HOME/foundation-manifest.json
# baseline (T-5 baseline shipped at install.sh Step 13.5 / S62 ded54f4). Per-file
# walk inside foundation directories: match → rm; mismatch → preserve + record in
# user_edited_foundation[]; not-in-baseline → preserve. --force-rm-edited overrides
# preservation. --force-remove permits uninstall when manifest is absent (falls
# back to basename-allowlist rm for the foundation directories).
#
# Slice scope (S61 + S62 + S63 cumulative):
#   - CLAUDE_HOME-first resolution from G1-pre symmetric (R-55 invariant)
#   - Provenance-log-driven CLAUDE_HOME confirmation: read header line
#     `CLAUDE_HOME: <path>` from most-recent $CLAUDE_HOME/logs/install-*.log
#     (G10 consume) and assert equality with env-supplied $CLAUDE_HOME
#   - foundation-manifest.json read + parse + per-file fingerprint table   [S63]
#   - .pre-uninstall-<ts>/ backup via cp -R (round-trip integrity)
#   - launchctl bootout gui/$UID com.claude-stem.* (LAUNCHCTL_BIN env
#     override for MOCK_LAUNCHCTL=1 hermetic tests; defense-in-depth G6)
#   - G6 namespace gate: refuse to bootout labels outside com.claude-stem.*
#     prefix; secondary guard catches impersonation labels (prefix as substring
#     but not at position 1)
#   - Per-file fingerprint walk inside foundation_known_entries directories:   [S63]
#       baseline match → rm; baseline mismatch → preserve + log to stderr +
#       record in provenance user_edited_foundation[]; not-in-baseline → preserve
#   - Root-level foundation files (settings.json, settings.local.json,
#     foundation-manifest.json) — not tracked in manifest; rm by basename       [S63]
#     (settings.json reverse-merge deferred per CFF-S61-3)
#   - Preserve logs/ (uninstall provenance lands here) + hooks/state/ (session
#     state preserved naturally by per-file walk — files not in baseline) +
#     everything not in foundation set
#   - Provenance log header at $CLAUDE_HOME/logs/uninstall-*.log on completion,
#     including user_edited_foundation_count + per-file listing                  [S63]
#
# DEFERRED to subsequent T-2 follow-up sessions:
#   - 10s/plist timeout wrapper around launchctl bootout (CFF-S61-1)
#   - settings.json baseline jq-reverse unmerge (G7-symmetric; CFF-S61-3)
#   - --selective <hooks|skills|plists|schemas|onboarding|lib|orchestrator|
#     templates|plugins|installer> / --full / --dry-run / --keep-backup flag
#     matrix (slice ships with --force-rm-edited + --force-remove only)
#   - Negative-test rehearsal under SP00 runner-shell in SP00 Docker image
#     (T-3 territory; SP00-owned)
#   - Provenance-log freshness validation (CFF-S61-4)
#
# Exit codes (slice subset):
#   0   success
#   10  prereq missing (CLAUDE_HOME unset/empty per G1-pre symmetric;
#                       required binary absent; provenance log missing;
#                       CLAUDE_HOME mismatch with provenance log header;
#                       foundation-manifest.json missing without --force-remove;
#                       foundation-manifest.json parse/extract failure)
#   11  permission/write failure (backup mkdir, backup cp, or provenance write)
#   56  G6 fired (label outside com.claude-stem.* prefix encountered
#                 during bootout discovery; foundation rm NOT performed;
#                 backup retained for forensic review)
#
# Flags (S63):
#   --force-rm-edited   rm user-edited foundation files even on fingerprint
#                       mismatch (warns per file). Default off; preservation is
#                       the load-bearing safety property.
#   --force-remove      permit uninstall when foundation-manifest.json absent
#                       (falls back to basename-allowlist rm of foundation
#                       directories). Default off; manifest-missing is exit 10.
#
# R-23 bash 3.2 compat. R-37 single-deliverable. R-55 zero $HOME/.claude
# resolution paths in script body (literal $HOME/.claude appears only in
# the G1-pre user-facing error text per spec.md L74 symmetric).

set -u

# --- diagnostics ---
diag() { printf 'uninstall FAIL: %s\n' "$1" >&2; }
info() { printf 'uninstall: %s\n' "$1"; }
warn() { printf 'uninstall WARN: %s\n' "$1" >&2; }

# --- argv parse (S63 fingerprint flags; in-memory only; pre-G1-pre) ---
FORCE_RM_EDITED=0
FORCE_REMOVE=0
for arg in "$@"; do
  case "$arg" in
    --force-rm-edited) FORCE_RM_EDITED=1 ;;
    --force-remove)    FORCE_REMOVE=1 ;;
  esac
done

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
for bin in plutil awk jq python3 shasum find; do
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

# --- foundation-manifest.json read + per-file fingerprint baseline (S63) ---
# Reads $CLAUDE_HOME/foundation-manifest.json (T-5 baseline shipped at install
# Step 13.5). Extracts {path, sha256} pairs to a tmp tab-separated file for
# path-keyed awk lookup (bash 3.2 lacks associative arrays).
#
# Default: missing manifest → exit 10 (refuse uninstall; safety property).
# --force-remove: missing manifest → fingerprint_check_skipped=1; falls back
# to basename-allowlist rm of foundation directories.
manifest_path="$CLAUDE_HOME/foundation-manifest.json"
fingerprint_check_skipped=0
manifest_records_tmp=""
manifest_record_count=0

if [ -f "$manifest_path" ]; then
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$manifest_path" 2>/dev/null; then
    diag "foundation-manifest.json parse failure at $manifest_path"
    exit 10
  fi
  manifest_records_tmp="$(mktemp -t uninstall-manifest.XXXXXX 2>/dev/null)" || {
    diag "manifest tmp allocation failed"
    exit 11
  }
  if ! jq -r '.files[] | "\(.path)\t\(.sha256)"' "$manifest_path" > "$manifest_records_tmp" 2>/dev/null; then
    diag "foundation-manifest.json files[] extraction failed"
    rm -f "$manifest_records_tmp"
    exit 10
  fi
  manifest_record_count="$(wc -l <"$manifest_records_tmp" | tr -d ' ')"
  info "fingerprint baseline loaded: $manifest_record_count records"
else
  if [ "$FORCE_REMOVE" = "1" ]; then
    warn "foundation-manifest.json absent at $manifest_path — --force-remove set; falling back to basename-allowlist rm"
    fingerprint_check_skipped=1
  else
    diag "foundation-manifest.json missing at $manifest_path — refusing uninstall (use --force-remove to fall back to basename-allowlist)"
    exit 10
  fi
fi

# Helper: lookup baseline sha256 by relative-to-CLAUDE_HOME path.
# Empty stdout → not in baseline.
lookup_baseline_sha() {
  local rel="$1"
  [ -z "$manifest_records_tmp" ] && return 0
  awk -F'\t' -v p="$rel" '$1 == p {print $2; exit}' "$manifest_records_tmp"
}

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

# --- launchctl bootout gui/$UID com.claude-stem.* (G6-gated) ---
PREFIX="com.claude-stem"
uid="$(id -u)"
domain="gui/$uid"

g6_violation=0
boot_count=0

# Primary G6: filter launchctl list output by prefix at awk; non-matching
# labels never reach the bootout call.
labels=""
labels="$("$LAUNCHCTL_BIN" list 2>/dev/null | awk -v p="$PREFIX." 'NR > 1 && $3 != "" && index($3, p) == 1 {print $3}')" || true

# Secondary G6 (impersonation defense): scan for labels containing the prefix
# substring but NOT at position 1 (e.g., `evil.com.claude-stem.fake`).
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

# --- rm foundation plists at $HOME/Library/LaunchAgents/ (CFF-S71-1) ---
# uninstall.sh historically operated only on $CLAUDE_HOME contents; rendered
# plists at $HOME/Library/LaunchAgents/<Label>.plist (written by render-launchd
# production mode) were outside the removal scope. Stale plists auto-load on
# reboot, re-bootstrapping the foundation label under launchd despite uninstall
# completion (wrapper script under $CLAUDE_HOME is gone — fire produces stderr
# noise but no destructive action; UX-confusing).
#
# Symmetric with G6 awk-filter: only com.claude-stem.*.plist files are
# removed; foreign plists in the same directory are preserved. Glob iteration
# uses [ -e ] guard for the empty-glob case (Bash 3.2 compat).
LA_DIR="${HOME:-/}/Library/LaunchAgents"
plist_rm_count=0
if [ -d "$LA_DIR" ]; then
  for plist in "$LA_DIR"/com.claude-stem.*.plist; do
    [ -e "$plist" ] || continue
    if rm -f "$plist" 2>/dev/null; then
      info "rm $(basename "$plist") from $LA_DIR"
      plist_rm_count=$((plist_rm_count+1))
    else
      warn "rm failed: $plist"
    fi
  done
fi
info "plist cleanup: $plist_rm_count foundation plist(s) removed from $LA_DIR"

# --- rm foundation files at $CLAUDE_HOME root with per-file fingerprint walk (S63) ---
# Top-level dispatch:
#   - logs/                    → preserve entirely (uninstall provenance lands here)
#   - non-foundation entries   → preserve (basename not in foundation_known_entries)
#   - foundation root files    → rm by basename (manifest does NOT track
#                                 settings.json / settings.local.json /
#                                 foundation-manifest.json; reverse-merge is
#                                 deferred per CFF-S61-3)
#   - foundation directories   → per-file walk:
#         baseline match    → rm
#         baseline mismatch → preserve + log + record (or rm if --force-rm-edited)
#         not in baseline   → preserve (user content under foundation dir;
#                              hooks/state/ session files land here)
#       After per-file walk, prune empty subdirs bottom-up via find -depth -delete.
#
# When fingerprint_check_skipped=1 (manifest absent + --force-remove), per-file
# walk degenerates to rm-rf the foundation directories — basename allowlist
# fallback for graceful recovery from incomplete-install state.
removed_count=0
preserved_count=0
user_edited_foundation_count=0
user_edited_paths_log="$(mktemp -t uninstall-edited.XXXXXX 2>/dev/null)" || {
  diag "user-edited tmp allocation failed"
  exit 11
}

for entry in "$CLAUDE_HOME"/* "$CLAUDE_HOME"/.[!.]*; do
  [ -e "$entry" ] || continue
  base="${entry##*/}"
  case "$base" in
    .pre-uninstall-*) continue ;;
  esac

  found=0
  for known in $foundation_known_entries; do
    if [ "$base" = "$known" ]; then
      found=1
      break
    fi
  done

  if [ "$found" = "0" ]; then
    info "preserved (non-foundation): $entry"
    preserved_count=$((preserved_count + 1))
    continue
  fi

  if [ "$base" = "logs" ]; then
    info "preserving logs/ (uninstall provenance destination)"
    preserved_count=$((preserved_count + 1))
    continue
  fi

  if [ -d "$entry" ]; then
    # Foundation directory — per-file fingerprint walk
    if [ "$fingerprint_check_skipped" = "1" ]; then
      # Fallback: basename-allowlist mode rm-rf the directory
      if rm -rf "$entry" 2>/dev/null; then
        info "removed (basename fallback): $entry"
        removed_count=$((removed_count + 1))
      else
        warn "rm failed for $entry"
      fi
      continue
    fi
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      rel="${f#$CLAUDE_HOME/}"
      sha_baseline="$(lookup_baseline_sha "$rel")"
      if [ -n "$sha_baseline" ]; then
        sha_actual="$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')"
        if [ "$sha_actual" = "$sha_baseline" ]; then
          if rm -f "$f" 2>/dev/null; then
            removed_count=$((removed_count + 1))
          else
            warn "rm failed: $f"
          fi
        else
          if [ "$FORCE_RM_EDITED" = "1" ]; then
            warn "user-edited foundation file removed (--force-rm-edited): $rel"
            if rm -f "$f" 2>/dev/null; then
              removed_count=$((removed_count + 1))
            else
              warn "rm failed: $f"
            fi
          else
            warn "user-edited foundation file preserved: $rel (rm with --force-rm-edited if intentional)"
            printf '%s\n' "$rel" >> "$user_edited_paths_log"
            user_edited_foundation_count=$((user_edited_foundation_count + 1))
            preserved_count=$((preserved_count + 1))
          fi
        fi
      else
        info "preserved (not in baseline): $rel"
        preserved_count=$((preserved_count + 1))
      fi
    done <<EOF
$(find "$entry" -type f 2>/dev/null)
EOF
    # Prune empty subdirs bottom-up; -depth so leaves go first.
    find "$entry" -depth -type d -empty -exec rmdir {} \; 2>/dev/null || true
  else
    # Foundation root file (settings.json / settings.local.json /
    # foundation-manifest.json). Manifest doesn't track these. rm by basename.
    if rm -rf "$entry" 2>/dev/null; then
      info "removed $entry"
      removed_count=$((removed_count + 1))
    else
      warn "rm failed for $entry"
    fi
  fi
done

info "rm complete: removed=$removed_count preserved=$preserved_count user_edited=$user_edited_foundation_count"

# --- provenance log header (G10 emit; symmetric with install.sh) ---
log_path="$CLAUDE_HOME/logs/uninstall-$(date -u +%Y%m%d-%H%M%S)-$$.log"
if [ "$fingerprint_check_skipped" = "1" ]; then
  fingerprint_check_skipped_str="true"
else
  fingerprint_check_skipped_str="false"
fi
{
  printf 'uninstall.sh provenance — Plan 71 SP08 T-2 slice (S61 + S62 + S63 fingerprint match)\n'
  printf 'timestamp: %s\n'                       "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'CLAUDE_HOME: %s\n'                     "$CLAUDE_HOME"
  printf 'consumed_install_log: %s\n'            "$provenance_log"
  printf 'backup_dir: %s\n'                      "$backup_dir"
  printf 'backup_entry_count: %d\n'              "$backup_count"
  printf 'bootout_count: %d\n'                   "$boot_count"
  printf 'plist_rm_count: %d\n'                  "$plist_rm_count"
  printf 'plist_rm_dir: %s\n'                    "$LA_DIR"
  printf 'removed_count: %d\n'                   "$removed_count"
  printf 'preserved_count: %d\n'                 "$preserved_count"
  printf 'user_edited_foundation_count: %d\n'    "$user_edited_foundation_count"
  printf 'fingerprint_check_skipped: %s\n'       "$fingerprint_check_skipped_str"
  printf 'manifest_record_count: %d\n'           "$manifest_record_count"
  printf 'force_rm_edited: %d\n'                 "$FORCE_RM_EDITED"
  printf 'force_remove: %d\n'                    "$FORCE_REMOVE"
  printf 'launchctl_bin: %s\n'                   "$LAUNCHCTL_BIN"
  printf 'uninstall.sh sha256: %s\n'             "$(shasum -a 256 "$0" 2>/dev/null | awk '{print $1}')"
  if [ -s "$user_edited_paths_log" ]; then
    printf 'user_edited_foundation:\n'
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      printf '  - %s\n' "$p"
    done < "$user_edited_paths_log"
  fi
  printf 'slice_scope: G1-pre symmetric + provenance-log-driven CLAUDE_HOME confirm + foundation-manifest.json read + .pre-uninstall-<ts>/ backup + launchctl bootout (LAUNCHCTL_BIN-overridable, G6-gated, com.claude-stem.* only) + foundation plist rm at $HOME/Library/LaunchAgents/ (CFF-S71-1; G6-symmetric prefix filter) + per-file fingerprint walk inside foundation directories + basename rm for foundation root files + logs/ + non-foundation top-level preservation + --force-rm-edited / --force-remove\n'
  printf 'deferred: 10s/plist timeout wrapper around launchctl bootout; settings.json baseline jq-reverse unmerge (G7-symmetric); --selective/--full/--dry-run/--keep-backup flag matrix; SP00 runner-shell negative rehearsal; provenance-log freshness validation\n'
} > "$log_path" || { diag "uninstall provenance log write failed"; rm -f "$manifest_records_tmp" "$user_edited_paths_log"; exit 11; }

# --- cleanup tmp files ---
[ -n "$manifest_records_tmp" ] && rm -f "$manifest_records_tmp"
rm -f "$user_edited_paths_log"

info "uninstall complete (slice). next-steps:"
info "  - restore round-trip: cp -R $backup_dir/. \$CLAUDE_HOME/"
info "  - prune backup when satisfied: rm -rf $backup_dir"
info "provenance: $log_path"

exit 0
