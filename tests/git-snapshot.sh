#!/bin/bash
# tests/git-snapshot.sh
#
# Captures an atomic snapshot of the current working tree before a
# high-risk mutation (SP01 T-1 live schema migration is the primary
# consumer). Emits a snapshot ID on stdout that tests/git-revert.sh
# can consume to restore the tree exactly.
#
# Mechanism: lightweight tag on the current HEAD + `git stash push -u`
# of any uncommitted work. The tag gives us a commit to reset to;
# the stash captures untracked + modified files outside the commit.
#
# Snapshot ID format:
#   foundation-snapshot-<UTC-timestamp>-<random>
#
# Emits the ID on stdout so callers can:
#   SNAP=$(tests/git-snapshot.sh)
#   ... do risky work ...
#   tests/git-revert.sh "$SNAP"
#
# Exit codes:
#   0  snapshot captured, ID on stdout
#   4  dirty pre-condition (merge/rebase in progress, detached HEAD, etc.)
#   5  git failure
#
# R-23: bash 3.2 compat.

set -u

# Allow override for tests that run inside a throwaway directory.
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || printf '')}"
if [ -z "$REPO_ROOT" ]; then
  printf 'git-snapshot FAIL: not inside a git repo (pwd=%s)\n' "$PWD" >&2
  exit 5
fi
cd "$REPO_ROOT" || exit 5

# Refuse snapshot during merge/rebase/cherry-pick.
for state_file in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
  if [ -e ".git/${state_file}" ]; then
    printf 'git-snapshot FAIL: refusing snapshot during %s (%s present)\n' \
      "$state_file" ".git/${state_file}" >&2
    exit 4
  fi
done

# Build snapshot ID: timestamp + short random suffix.
ts=$(date -u +%Y%m%dT%H%M%SZ)
# 6-char random hex via /dev/urandom, hexdump pipeline (bash 3.2 safe).
rand=$(LC_ALL=C head -c 32 /dev/urandom 2>/dev/null \
  | od -An -tx1 2>/dev/null \
  | tr -d ' \n' \
  | cut -c1-6)
if [ -z "$rand" ]; then
  rand="$$"
fi
snap_id="foundation-snapshot-${ts}-${rand}"

# 1) Stash anything uncommitted (tracked + untracked).
#    `git stash push` with --include-untracked ensures untracked files
#    come along. If there's nothing to stash, the command is a no-op
#    and we record "no-stash" for the revert helper.
stash_ref=''
dirty=$(git status --porcelain 2>/dev/null | head -1)
if [ -n "$dirty" ]; then
  if ! git stash push -u -q -m "$snap_id" >/dev/null 2>&1; then
    printf 'git-snapshot FAIL: git stash push failed\n' >&2
    exit 5
  fi
  # Capture the stash ref as `stash@{0}` isn't stable across further stashes;
  # the message-match lookup is resilient.
  stash_ref="$snap_id"
fi

# 2) Tag current HEAD so revert knows where to reset.
head_sha=$(git rev-parse HEAD 2>/dev/null || printf '')
if [ -z "$head_sha" ]; then
  # Pop the stash we just made to leave caller's tree unchanged before exit.
  if [ -n "$stash_ref" ]; then
    git stash pop -q >/dev/null 2>&1 || true
  fi
  printf 'git-snapshot FAIL: cannot resolve HEAD sha (empty repo?)\n' >&2
  exit 4
fi
if ! git tag -m "$snap_id" "$snap_id" "$head_sha" >/dev/null 2>&1; then
  if [ -n "$stash_ref" ]; then
    git stash pop -q >/dev/null 2>&1 || true
  fi
  printf 'git-snapshot FAIL: git tag %s failed\n' "$snap_id" >&2
  exit 5
fi

# 3) Record metadata sidecar so revert can find the stash by message.
meta_dir=".git/foundation-snapshots"
mkdir -p "$meta_dir"
{
  printf 'snap_id=%s\n' "$snap_id"
  printf 'head_sha=%s\n' "$head_sha"
  printf 'stash_ref=%s\n' "$stash_ref"
  printf 'captured_at=%s\n' "$ts"
  printf 'captured_pwd=%s\n' "$REPO_ROOT"
} > "${meta_dir}/${snap_id}"

printf '%s\n' "$snap_id"
exit 0
