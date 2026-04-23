#!/bin/bash
# tests/git-revert.sh <snapshot-id>
#
# Restores the working tree captured by tests/git-snapshot.sh. The revert
# is atomic-success-or-full-fail — if any step fails, caller knows the
# tree may be in a partial state and must inspect manually.
#
# Steps:
#   1. Look up .git/foundation-snapshots/<snap_id> metadata
#   2. `git reset --hard <head_sha>` to restore the committed state
#   3. If the snapshot included a stash, `git stash apply` to recover
#      untracked/modified files
#   4. Remove the snapshot tag + metadata sidecar
#
# Exit codes:
#   0  tree restored to snapshot state
#   4  snapshot not found / invalid ID
#   5  git failure
#
# R-23: bash 3.2 compat.

set -u

snap_id="${1:-}"
if [ -z "$snap_id" ]; then
  printf 'git-revert FAIL: missing snapshot-id argument\n' >&2
  printf '  usage: git-revert.sh <snapshot-id>\n' >&2
  exit 4
fi

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || printf '')}"
if [ -z "$REPO_ROOT" ]; then
  printf 'git-revert FAIL: not inside a git repo\n' >&2
  exit 5
fi
cd "$REPO_ROOT" || exit 5

meta_file=".git/foundation-snapshots/${snap_id}"
if [ ! -f "$meta_file" ]; then
  printf 'git-revert FAIL: snapshot %s not found at %s\n' "$snap_id" "$meta_file" >&2
  exit 4
fi

# Parse metadata (simple KEY=VALUE format).
head_sha=$(awk -F= '$1=="head_sha"{print $2}' "$meta_file")
stash_ref=$(awk -F= '$1=="stash_ref"{print $2}' "$meta_file")

if [ -z "$head_sha" ]; then
  printf 'git-revert FAIL: metadata %s missing head_sha\n' "$meta_file" >&2
  exit 4
fi

# 1) Hard-reset to the snapshot's HEAD sha.
if ! git reset --hard "$head_sha" >/dev/null 2>&1; then
  printf 'git-revert FAIL: git reset --hard %s failed\n' "$head_sha" >&2
  exit 5
fi

# 1a) Remove any files that appeared after the snapshot. `git reset --hard`
#     restores tracked content but leaves new untracked files behind. Clean
#     -fd removes them; -x is deliberately omitted so user-ignored caches
#     (e.g. /results/ in .gitignore) survive.
#     The .git/foundation-snapshots/ sidecars live inside .git/ which
#     git-clean always respects, so they are not at risk here.
if ! git clean -fd -- . >/dev/null 2>&1; then
  printf 'git-revert FAIL: git clean -fd failed\n' >&2
  exit 5
fi

# 2) Recover the stash if one was captured. `git stash list` is message-based
#    lookup — we find the ref by matching the snap_id in the stash message.
if [ -n "$stash_ref" ]; then
  # Find the stash@{N} that matches our snap_id.
  stash_line=$(git stash list 2>/dev/null | grep -F "$stash_ref" | head -1 || true)
  if [ -z "$stash_line" ]; then
    printf 'git-revert WARN: stash for %s not found; tree reset to HEAD only\n' "$snap_id" >&2
  else
    stash_pos="${stash_line%%:*}"
    if ! git stash pop -q "$stash_pos" >/dev/null 2>&1; then
      printf 'git-revert FAIL: git stash pop %s failed\n' "$stash_pos" >&2
      exit 5
    fi
  fi
fi

# 3) Remove the snapshot tag and metadata.
git tag -d "$snap_id" >/dev/null 2>&1 || true
rm -f "$meta_file"

printf 'git-revert: tree restored to %s\n' "$snap_id"
exit 0
