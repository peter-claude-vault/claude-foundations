#!/bin/bash
# install.sh — Plan 71 SP08 T-1 (S59 happy-path slice + S60 G1 follow-up)
#
# Slice scope (S59 + S60 cumulative):
#   - CLAUDE_HOME-first resolution (R-55 invariant; AC #1)
#   - G1-pre 100ms preflight (no FS writes; AC #2)              [S60]
#   - G1-main $HOME/.claude equality gate + I-UNDERSTAND-APRIL-13
#     sentinel + --force-install flag (AC #3)                    [S60]
#   - 14-asset write-sequence (audit F-01..F-05)
#   - LABEL_PREFIX=com.claude-foundations preserved via cp -R installer/ +
#     templates/launchd/ (G6 namespace isolation)
#   - settings.json atomic jq-merge with G7 silent-key-deletion gate
#
# DEFERRED to subsequent T-1 follow-up sessions:
#   - G2 foreign-content detector / G3 backup proof-of-life (need T-5
#     foundation-manifest.json baseline)
#   - G4 vault-symlink, G5 PLANS_HOME, G8 UID-0 refuse, G9 dry-run-default,
#     G10 provenance-write-failure-as-11
#   - claude-mem preservation policy (T-1.5 bundles plugins/claude-mem/v<VERSION>/ first)
#   - --dry-run/--apply default flow + state classification (fresh|foundation-only|mixed|user-only)
#   - --force-all / --no-preserve-config flag matrix
#   - Full 19-exit-code matrix (slice subset below)
#
# Exit codes (slice subset; S59 + S60):
#   0   success
#   10  prereq missing (CLAUDE_HOME unset/empty per G1-pre; required binary
#                       absent; SOURCE_REPO not a foundation-repo)
#   11  permission/write failure
#   30  schema parse failure (post-install)
#   40  settings.json merge conflict requires human resolution (jq error)
#   51  G1-main fired ($HOME/.claude equality + non-foundation content,    [S60]
#       missing --force-install or I-UNDERSTAND-APRIL-13 sentinel)
#   57  G7 fired (settings.json merge would silently delete keys)
#
# R-23 bash 3.2 compat. R-37 single-deliverable. R-55 zero $HOME/.claude
# resolution paths in script body (literal $HOME/.claude appears only in
# the AC #1 / G1-pre user-facing error text per spec.md L74 and the G1-main
# string-equality comparison per spec.md L75).

set -u

# --- diagnostics ---
diag() { printf 'install FAIL: %s\n' "$1" >&2; }
info() { printf 'install: %s\n' "$1"; }
warn() { printf 'install WARN: %s\n' "$1" >&2; }

# --- argv parse (in-memory only; no FS; pre-G1-pre to keep 100ms bound) ---
FORCE_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --force-install) FORCE_INSTALL=1 ;;
  esac
done

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

# --- G1-main: $HOME/.claude equality gate (AC #3; spec.md L75) ---
# Refuse if $CLAUDE_HOME == $HOME/.claude AND target exists with non-foundation
# content, unless --force-install AND I-UNDERSTAND-APRIL-13 sentinel typed.
# String comparison (not resolution) per R-55 carve-out.
foundation_known_entries="hooks skills schemas onboarding orchestrator templates plugins Library installer logs settings.json settings.local.json"

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
      diag "G1-main fired: \$CLAUDE_HOME equals \$HOME/.claude AND target contains non-foundation content. Pass --force-install AND type I-UNDERSTAND-APRIL-13 sentinel to proceed (April-13 protection)."
      exit 51
    fi
    printf 'install: type I-UNDERSTAND-APRIL-13 to confirm: ' >&2
    sentinel=""
    if ! IFS= read -r sentinel; then
      diag "G1-main fired: sentinel not provided (stdin EOF). Aborting."
      exit 51
    fi
    if [ "$sentinel" != "I-UNDERSTAND-APRIL-13" ]; then
      diag "G1-main fired: sentinel mismatch. Expected literal 'I-UNDERSTAND-APRIL-13'. Aborting."
      exit 51
    fi
    info "G1-main sentinel verified; proceeding under --force-install"
  fi
fi

info "CLAUDE_HOME=$CLAUDE_HOME"
info "SOURCE_REPO=$SOURCE_REPO"

# --- 14-asset write sequence (per spec.md L240-255 audit-2026-04-29) ---

# Step 1: mkdir -p target tree
target_dirs="hooks hooks/lib hooks/state hooks/config skills schemas onboarding orchestrator templates templates/launchd templates/settings-fragments plugins Library/LaunchAgents.staging installer logs"
for d in $target_dirs; do
  mkdir -p "$CLAUDE_HOME/$d" || { diag "mkdir failed: $CLAUDE_HOME/$d"; exit 11; }
done

# Step 2: hooks/*.sh + hooks/*.md + MANIFEST → $CLAUDE_HOME/hooks/
# (cp -n: never clobber; honors user-edited variants)
for f in "$SOURCE_REPO/hooks"/*.sh "$SOURCE_REPO/hooks"/*.md "$SOURCE_REPO/hooks/MANIFEST.txt"; do
  [ -e "$f" ] || continue
  cp -n "$f" "$CLAUDE_HOME/hooks/" 2>/dev/null || true
done

# Step 3: lib/ → hooks/lib/  (translation per spec.md L242 + A4)
for f in "$SOURCE_REPO/lib"/*.sh; do
  [ -e "$f" ] || continue
  cp -n "$f" "$CLAUDE_HOME/hooks/lib/" 2>/dev/null || true
done

# Step 4: hooks/config/*.json → $CLAUDE_HOME/hooks/config/
for f in "$SOURCE_REPO/hooks/config"/*.json; do
  [ -e "$f" ] || continue
  cp -n "$f" "$CLAUDE_HOME/hooks/config/" 2>/dev/null || true
done

# Step 5: skills/{8 dirs} → $CLAUDE_HOME/skills/
# Slice tolerates absent skills (some land in later sub-plans); warn but proceed.
for skill in librarian architect backlog-hygiene backlog-triage backlog-research morning-brief onboarder adopt; do
  src="$SOURCE_REPO/skills/$skill"
  if [ ! -d "$src" ]; then
    warn "skill not present in foundation-repo source: $skill (deferred to its sub-plan)"
    continue
  fi
  cp -R -n "$src" "$CLAUDE_HOME/skills/" 2>/dev/null || true
done

# Step 6: onboarding/ → $CLAUDE_HOME/onboarding/
if [ -d "$SOURCE_REPO/onboarding" ]; then
  cp -R -n "$SOURCE_REPO/onboarding"/. "$CLAUDE_HOME/onboarding/" 2>/dev/null || true
fi

# Step 7: orchestrator/ → $CLAUDE_HOME/orchestrator/
if [ -d "$SOURCE_REPO/orchestrator" ]; then
  cp -R -n "$SOURCE_REPO/orchestrator"/. "$CLAUDE_HOME/orchestrator/" 2>/dev/null || true
fi

# Step 8: installer/ → $CLAUDE_HOME/installer/
# Preserves render-launchd.sh + bootout-launchd.sh with their G6 LABEL_PREFIX
# default (com.claude-foundations); install.sh does NOT override this default.
if [ -d "$SOURCE_REPO/installer" ]; then
  cp -R -n "$SOURCE_REPO/installer"/. "$CLAUDE_HOME/installer/" 2>/dev/null || true
fi

# Step 9: schemas/ — 6 named files only (audit F-06)
for schema in vault-schema plans-schema plan-manifest-schema librarian-manifest-schema user-manifest-schema orchestration-schema; do
  src="$SOURCE_REPO/schemas/$schema.json"
  if [ ! -f "$src" ]; then
    diag "schema missing in source: $schema.json"
    exit 11
  fi
  cp -n "$src" "$CLAUDE_HOME/schemas/" 2>/dev/null || true
done
# Schemas/README.md ships alongside (operator docs)
[ -f "$SOURCE_REPO/schemas/README.md" ] && \
  cp -n "$SOURCE_REPO/schemas/README.md" "$CLAUDE_HOME/schemas/" 2>/dev/null || true

# Step 10: templates/ — settings.json + manifest skeletons + launchd/*.tmpl + settings-fragments/
for tmpl in settings.json librarian-manifest-skeleton.json README.md; do
  src="$SOURCE_REPO/templates/$tmpl"
  [ -e "$src" ] || continue
  cp -n "$src" "$CLAUDE_HOME/templates/" 2>/dev/null || true
done
for f in "$SOURCE_REPO/templates/launchd"/*.tmpl; do
  [ -e "$f" ] || continue
  cp -n "$f" "$CLAUDE_HOME/templates/launchd/" 2>/dev/null || true
done
for f in "$SOURCE_REPO/templates/settings-fragments"/*.json; do
  [ -e "$f" ] || continue
  cp -n "$f" "$CLAUDE_HOME/templates/settings-fragments/" 2>/dev/null || true
done

# Step 11: plugins/claude-mem/v<VERSION>/ → $CLAUDE_HOME/plugins/claude-mem/
# T-1.5 not yet shipped — handle gracefully without failing.
claude_mem_copied=0
if [ -d "$SOURCE_REPO/plugins/claude-mem" ]; then
  for vdir in "$SOURCE_REPO/plugins/claude-mem"/v*; do
    [ -d "$vdir" ] || continue
    mkdir -p "$CLAUDE_HOME/plugins/claude-mem"
    cp -R -n "$vdir"/. "$CLAUDE_HOME/plugins/claude-mem/" 2>/dev/null || true
    claude_mem_copied=1
    info "claude-mem bundle copied from $(basename "$vdir")"
  done
fi
if [ "$claude_mem_copied" = "0" ]; then
  info "claude-mem bundle not present in foundation-repo (T-1.5 deferred); skipping"
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

# Step 13: schema parse validation (post-install)
for schema in "$CLAUDE_HOME/schemas"/*.json; do
  [ -e "$schema" ] || continue
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$schema" 2>/dev/null; then
    diag "schema parse failure: $schema"
    exit 30
  fi
done

# Step 14: provenance log header (G10 emit; full G10 enforcement at T-1 follow-up)
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log_path="$CLAUDE_HOME/logs/install-$(date -u +%Y%m%d-%H%M%S)-$$.log"
{
  printf 'install.sh provenance — Plan 71 SP08 T-1 slice (S59 + S60)\n'
  printf 'timestamp: %s\n'        "$ts"
  printf 'CLAUDE_HOME: %s\n'      "$CLAUDE_HOME"
  printf 'SOURCE_REPO: %s\n'      "$SOURCE_REPO"
  printf 'force_install: %s\n'    "$FORCE_INSTALL"
  printf 'install.sh sha256: %s\n' "$(shasum -a 256 "$0" 2>/dev/null | awk '{print $1}')"
  printf 'slice_scope: 14-asset write-sequence + LABEL_PREFIX preservation + settings.json atomic merge + G1-pre + G1-main equality gate + I-UNDERSTAND-APRIL-13 sentinel\n'
  printf 'deferred: G2/G3 fingerprint; G4/G5/G8/G9/G10 red-team; claude-mem preservation; --dry-run/--apply matrix; --force-all/--no-preserve-config; full 19-exit-code matrix\n'
} > "$log_path" || { diag "provenance log write failed"; exit 11; }

info "install complete (slice). next-steps:"
info "  - render plists at runtime: \$CLAUDE_HOME/installer/render-launchd.sh --staging-dir \$CLAUDE_HOME/Library/LaunchAgents.staging librarian|architect"
info "  - claude-mem bundle: deferred to SP08 T-1.5"
info "  - G2-G10 firewall (foreign-content / backup / vault-symlink / PLANS_HOME / UID-0 / dry-run / provenance-fail): deferred to SP08 T-1 follow-up"
info "provenance: $log_path"

exit 0
