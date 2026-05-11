#!/bin/bash
# generate-foundation-manifest.sh — Plan 71 SP08 T-5 (S62 baseline slice)
#
# Walks SOURCE_REPO emitting a deterministic JSON manifest of every file
# install.sh ships to $CLAUDE_HOME, with installed-relative paths, sha256,
# octal mode, and byte size. Ships at foundation-repo top; install.sh
# copies the generated artifact to $CLAUDE_HOME/foundation-manifest.json
# at install time (Step 13.5).
#
# Consumers (T-5 enables; T-1 + T-2 follow-up consume):
#   - install.sh G2 — foreign-content detector (compares installed-tree
#     hashes vs baseline; refuses on drift unless --force-install +
#     --backup-verified)
#   - uninstall.sh — sha256 fingerprint match before rm (preserves
#     user-edited foundation files; emits review summary)
#
# Schema (canonical shape; uninstall G2 + install G2 both consume):
#   {
#     "version": "v2.0.0-rc1",
#     "generated_at": "<ISO8601 UTC>",
#     "generator_sha256": "<sha256 of this script>",
#     "files": [
#       {"path": "<installed-relative path>",
#        "sha256": "<64 hex>",
#        "mode": "<4-digit octal>",
#        "size": <bytes>}
#       , …
#     ]
#   }
#
# Determinism: output is byte-identical across runs modulo `generated_at`.
# `find` output is LC_ALL=C-sorted; `files` array is `jq sort_by(.path)`;
# top-level keys are jq -S sorted. R-23 bash 3.2 compat throughout.
#
# Path translation (mirrors install.sh):
#   lib/*.sh → hooks/lib/*.sh                    (install.sh Step 3)
#   plugins/claude-mem/v<VERSION>/<x> → plugins/claude-mem/<x>
#                                                 (install.sh Step 11)
# All other walked directories use identity (source path == installed path).
#
# Walked source paths (mirrors install.sh ship surface):
#   hooks/{*.sh,*.md,MANIFEST.txt}        (top-level only; no recursion)
#   hooks/config/*.json
#   lib/*.sh                              (translated to hooks/lib/)
#   skills/{8 named dirs}/**              (recursive)
#   schemas/{6 named}.json + README.md
#   onboarding/**                         (recursive)
#   orchestrator/**                       (recursive)
#   installer/**                          (recursive)
#   templates/{settings.json,librarian-manifest-skeleton.json,README.md}
#   templates/launchd/*.tmpl
#   templates/settings-fragments/*.json
#   plugins/claude-mem/v*/**              (recursive; T-1.5 deferred)
#
# Excluded (runtime state, source-only artifacts, distribution-tooling):
#   hooks/state/**          (session state; install.sh creates empty dir)
#   tests/**                (test harness, not shipped)
#   .git/**, .github/**, docs/**, lima/**, docker/**, vault-scaffolding/**
#   .gitignore, .image-digest, .self-verify/**
#   install.sh, uninstall.sh, generate-foundation-manifest.sh
#   foundation-manifest.json (chicken-and-egg: this file is the output)
#
# Usage:
#   generate-foundation-manifest.sh [-o <output_path>] [--version <ver>]
#
# Default output: stdout
# Default version: v2.0.0-rc1
# Default SOURCE_REPO: directory containing this script

set -u

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SOURCE_REPO="${SOURCE_REPO:-$SCRIPT_DIR}"
VERSION="v2.1.3"
OUTPUT=""

usage() {
  cat <<EOF
generate-foundation-manifest.sh — Plan 71 SP08 T-5

Usage: $0 [-o <output_path>] [--version <ver>]

Environment:
  SOURCE_REPO   foundation-repo top (default: dir containing this script)

Options:
  -o <path>     write JSON to <path> (default: stdout)
  --version <ver>  pin top-level version field (default: v2.0.0-rc1)
  -h | --help   this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) OUTPUT="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -d "$SOURCE_REPO/hooks" ] || [ ! -d "$SOURCE_REPO/skills" ] || [ ! -d "$SOURCE_REPO/schemas" ]; then
  printf 'generate-foundation-manifest FAIL: SOURCE_REPO does not look like foundation-repo: %s\n' "$SOURCE_REPO" >&2
  exit 10
fi

for bin in jq shasum stat awk find sort; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'generate-foundation-manifest FAIL: missing prereq binary: %s\n' "$bin" >&2
    exit 10
  fi
done

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
generator_sha256="$(shasum -a 256 "$SCRIPT_PATH" | awk '{print $1}')"

# --- emit (src_relative\tinstalled_relative) pairs for every shipped file ---
# Ordering does not matter: final files[] gets jq sort_by(.path).
emit_pairs() {
  local f base d skill s vdir vname rel installed

  # hooks/ top-level files (no recursion)
  for f in "$SOURCE_REPO/hooks"/*.sh "$SOURCE_REPO/hooks"/*.md "$SOURCE_REPO/hooks/MANIFEST.txt"; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf 'hooks/%s\thooks/%s\n' "$base" "$base"
  done

  # hooks/config/*.json
  for f in "$SOURCE_REPO/hooks/config"/*.json; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf 'hooks/config/%s\thooks/config/%s\n' "$base" "$base"
  done

  # lib/*.sh → hooks/lib/*.sh (TRANSLATION; install.sh Step 3)
  # Skip files that also exist at hooks/lib/ — install.sh Step 3.5 cp_clobbers
  # over them, so the post-install effective state is the hooks/lib/ copy.
  # Mirrors install.sh ordering: Step 3 copies lib/*, Step 3.5 overwrites
  # with hooks/lib/*. Manifest reflects post-install state, not intermediate.
  for f in "$SOURCE_REPO/lib"/*.sh; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    [ -f "$SOURCE_REPO/hooks/lib/$base" ] && continue
    printf 'lib/%s\thooks/lib/%s\n' "$base" "$base"
  done

  # hooks/lib/*.{sh,json} (identity; install.sh Step 3.5)
  # Plan 81 SP01 helpers ship from hooks/lib/ directly: live-guard.sh,
  # l3-pause-helper.sh, l3-writer-registry.json, gate-schema-migrate.sh.
  for f in "$SOURCE_REPO/hooks/lib"/*.sh "$SOURCE_REPO/hooks/lib"/*.json; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf 'hooks/lib/%s\thooks/lib/%s\n' "$base" "$base"
  done

  # skills/{9 named}/** (recursive within named dirs)
  # infer-vault-structure added v2.1.2 SP16 T-6 to mirror install.sh's 9-named scope.
  for skill in librarian architect backlog-hygiene backlog-triage backlog-research morning-brief onboarder adopt infer-vault-structure; do
    d="$SOURCE_REPO/skills/$skill"
    [ -d "$d" ] || continue
    LC_ALL=C find "$d" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      rel="${f#$SOURCE_REPO/}"
      printf '%s\t%s\n' "$rel" "$rel"
    done
  done

  # schemas — 12 named .json + README.md (mirrors install.sh Step 9 list +
  # Plan 81 SP01 gate-config/gate-config-schema additions per v2.1.3).
  for s in vault-schema plans-schema plan-manifest-schema librarian-manifest-schema user-manifest-schema orchestration-schema vault-overlay-schema doc-dependencies-schema drift-allowlist-schema cron-log-architecture-exceptions-schema gate-config gate-config-schema; do
    f="$SOURCE_REPO/schemas/$s.json"
    [ -f "$f" ] || continue
    printf 'schemas/%s.json\tschemas/%s.json\n' "$s" "$s"
  done
  if [ -f "$SOURCE_REPO/schemas/README.md" ]; then
    printf 'schemas/README.md\tschemas/README.md\n'
  fi

  # onboarding/** (recursive)
  d="$SOURCE_REPO/onboarding"
  if [ -d "$d" ]; then
    LC_ALL=C find "$d" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      rel="${f#$SOURCE_REPO/}"
      printf '%s\t%s\n' "$rel" "$rel"
    done
  fi

  # orchestrator/** (recursive)
  d="$SOURCE_REPO/orchestrator"
  if [ -d "$d" ]; then
    LC_ALL=C find "$d" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      rel="${f#$SOURCE_REPO/}"
      printf '%s\t%s\n' "$rel" "$rel"
    done
  fi

  # installer/** (recursive)
  d="$SOURCE_REPO/installer"
  if [ -d "$d" ]; then
    LC_ALL=C find "$d" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      rel="${f#$SOURCE_REPO/}"
      printf '%s\t%s\n' "$rel" "$rel"
    done
  fi

  # templates/ — 6 named files at top (CLAUDE.md spine + memory bootstrap added by SP10/SP11)
  for f in "$SOURCE_REPO/templates/settings.json" "$SOURCE_REPO/templates/librarian-manifest-skeleton.json" "$SOURCE_REPO/templates/README.md" "$SOURCE_REPO/templates/vault-claude-md-template.md" "$SOURCE_REPO/templates/claude-home-claude-md-template.md" "$SOURCE_REPO/templates/MEMORY.md.template"; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf 'templates/%s\ttemplates/%s\n' "$base" "$base"
  done

  # templates/launchd/*.tmpl
  for f in "$SOURCE_REPO/templates/launchd"/*.tmpl; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf 'templates/launchd/%s\ttemplates/launchd/%s\n' "$base" "$base"
  done

  # templates/settings-fragments/*.json
  for f in "$SOURCE_REPO/templates/settings-fragments"/*.json; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf 'templates/settings-fragments/%s\ttemplates/settings-fragments/%s\n' "$base" "$base"
  done

  # plugins/claude-mem/v*/** (T-1.5 deferred; manifest tolerates absence)
  for vdir in "$SOURCE_REPO/plugins/claude-mem"/v*; do
    [ -d "$vdir" ] || continue
    vname="${vdir##*/}"
    LC_ALL=C find "$vdir" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      rel="${f#$SOURCE_REPO/}"
      installed="${rel#plugins/claude-mem/$vname/}"
      installed="plugins/claude-mem/$installed"
      printf '%s\t%s\n' "$rel" "$installed"
    done
  done
}

# --- emit one JSON record per file (src→{path,sha256,mode,size}) ---
emit_records() {
  local src_rel installed_rel src sha mode_full mode size mode_len
  while IFS=$'\t' read -r src_rel installed_rel; do
    [ -z "$src_rel" ] && continue
    src="$SOURCE_REPO/$src_rel"
    [ -f "$src" ] || continue
    sha="$(shasum -a 256 "$src" 2>/dev/null | awk '{print $1}')"
    mode_full="$(stat -f '%Op' "$src" 2>/dev/null)"
    mode_len=${#mode_full}
    if [ "$mode_len" -ge 4 ]; then
      mode="${mode_full:$((mode_len-4)):4}"
    else
      mode="$mode_full"
    fi
    size="$(stat -f '%z' "$src" 2>/dev/null)"
    if [ -z "$sha" ] || [ -z "$mode" ] || [ -z "$size" ]; then
      printf 'generate-foundation-manifest WARN: stat/sha failure on %s; skipping\n' "$src" >&2
      continue
    fi
    jq -n -c \
      --arg path "$installed_rel" \
      --arg sha256 "$sha" \
      --arg mode "$mode" \
      --argjson size "$size" \
      '{path: $path, sha256: $sha256, mode: $mode, size: $size}'
  done
}

# --- build files[] array, sorted by path ---
records="$(emit_pairs | emit_records)"
if [ -z "$records" ]; then
  printf 'generate-foundation-manifest FAIL: no shipped files discovered under %s\n' "$SOURCE_REPO" >&2
  exit 11
fi

files_json="$(printf '%s\n' "$records" | jq -s 'sort_by(.path)')"

# --- compose final JSON with sorted top-level keys ---
out_json="$(jq -n -S \
  --arg version "$VERSION" \
  --arg generated_at "$generated_at" \
  --arg generator_sha256 "$generator_sha256" \
  --argjson files "$files_json" \
  '{version: $version, generated_at: $generated_at, generator_sha256: $generator_sha256, files: $files}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$out_json" > "$OUTPUT" || {
    printf 'generate-foundation-manifest FAIL: write failed: %s\n' "$OUTPUT" >&2
    exit 11
  }
else
  printf '%s\n' "$out_json"
fi

exit 0
