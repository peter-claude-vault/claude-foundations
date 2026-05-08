#!/bin/bash
# install-hooks.sh — symlink SP01 git-hooks into target git repos
#
# Sanctioned by SP01 spec L120 ("foundation-repo .git/hooks/pre-commit") +
# spec L122 (cross-sub-plan invalidation post-commit). Hook bodies live in
# foundation-repo work tree; this installer creates symlinks.
#
# pre-commit is installed as a dispatcher (Session 13) chaining the two
# child hooks fail-fast: R-37 coupled-surface (T-7) → R-46-cousin
# flip-to-complete (T-27). Single .git/hooks/pre-commit slot per git's
# convention; dispatcher resolves siblings via the symlink chain back to
# this directory.
#
# Phase A bootstrap deploy (calendar-gated to ≥2026-05-17 per R-55 retire
# window). Run AFTER:
#   - Plan 71 closed (predecessor) ✓ (2026-05-03)
#   - Foundation-repo v2.0.0 published ✓ (2026-05-03)
#   - SP01 T-3 / T-4 / T-8 / T-9 / T-10 / T-13 / T-17 done ✓ (Sessions 2-3)
#   - SP01 T-26 fixture inputs handed off ✓ (Session 4)
#   - SP08 dogfood-harness emits first verdict-pass entry
#
# Usage: install-hooks.sh [--foundation-only|--plans-only|--both] [--dry-run]
#
# Default --both installs in foundation-repo + plans-repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION_REPO="${FOUNDATION_REPO_OVERRIDE:-$HOME/Code/claude-stem}"
PLANS_REPO="${PLANS_ROOT_OVERRIDE:-$HOME/.claude-plans}"

DRY_RUN=0
TARGET="both"

while (( $# > 0 )); do
  case "$1" in
    --foundation-only) TARGET="foundation"; shift ;;
    --plans-only)      TARGET="plans"; shift ;;
    --both)            TARGET="both"; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 3 ;;
  esac
done

install_pre_commit() {
  local repo="$1"
  local hook_dir="$repo/.git/hooks"
  local target="$hook_dir/pre-commit"
  if [[ ! -d "$hook_dir" ]]; then
    echo "skip: $repo/.git/hooks does not exist (not a git repo or worktree)" >&2
    return 0
  fi

  if [[ -e "$target" && ! -L "$target" ]]; then
    echo "WARN: $target exists and is NOT a symlink. Refusing to overwrite. Move it manually first." >&2
    return 1
  fi

  if (( DRY_RUN == 1 )); then
    echo "[dry-run] ln -sf $SCRIPT_DIR/pre-commit-dispatcher.sh $target"
    return 0
  fi

  ln -sf "$SCRIPT_DIR/pre-commit-dispatcher.sh" "$target"
  echo "installed: $target -> $SCRIPT_DIR/pre-commit-dispatcher.sh"
}

install_post_commit() {
  local repo="$1"
  local hook_dir="$repo/.git/hooks"
  local target="$hook_dir/post-commit"
  if [[ ! -d "$hook_dir" ]]; then
    echo "skip: $repo/.git/hooks does not exist" >&2
    return 0
  fi
  if [[ -e "$target" && ! -L "$target" ]]; then
    echo "WARN: $target exists and is NOT a symlink. Refusing to overwrite." >&2
    return 1
  fi
  if (( DRY_RUN == 1 )); then
    echo "[dry-run] ln -sf $SCRIPT_DIR/post-commit-harness-invalidate.sh $target"
    return 0
  fi
  ln -sf "$SCRIPT_DIR/post-commit-harness-invalidate.sh" "$target"
  echo "installed: $target -> $SCRIPT_DIR/post-commit-harness-invalidate.sh"
}

case "$TARGET" in
  foundation|both)
    install_pre_commit "$FOUNDATION_REPO"
    install_post_commit "$FOUNDATION_REPO"
    ;;
esac
case "$TARGET" in
  plans|both)
    install_pre_commit "$PLANS_REPO"
    # Plans-repo doesn't need post-commit (it doesn't carry foundation source)
    ;;
esac
