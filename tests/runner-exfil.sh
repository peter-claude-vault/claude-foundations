#!/bin/bash
# tests/runner-exfil.sh
#
# SP00 Primitive — Exfiltration transport for /results after runner-shell
# has completed. Kept out of runner-shell.sh so in-container runs can
# complete without needing SSH credentials for sub-plans that only
# care about assertion outcomes (summary.json), not off-container archival.
#
# Transport contract:
#   - Default transport is `scp -r`. Honors the $EXFIL_SCP env var so tests
#     can swap in a `cp -r` shim without modifying this script. Treating
#     scp as a pluggable binary is standard rsync/scp practice and does
#     NOT relax the "never bind-mount" rule — the shim still performs a
#     one-way file COPY across the boundary.
#   - Target syntax follows scp: `user@host:/absolute/path` OR a local
#     path when $EXFIL_SCP resolves to a non-SSH copier (test harness).
#   - Verification is transport-independent: file-count + per-file
#     sha256 computed on source; the same computation is applied on
#     destination (via $EXFIL_SHASUM_CMD; defaults to shelling into the
#     host via `ssh` for remote targets, or reading locally for shim
#     targets). Any mismatch aborts with exit 12 and a diagnostic line
#     naming the first divergent file.
#
# Usage:
#   tests/runner-exfil.sh <source-dir> <target>
#
#   Real exfil:
#     tests/runner-exfil.sh /results tester@host.lima.internal:/tmp/run-42
#
#   Harness exfil (test):
#     EXFIL_SCP='cp -r' EXFIL_SHASUM_CMD=local \
#       tests/runner-exfil.sh /results /tmp/exfil-mirror
#
# Exit codes:
#   0   transfer complete; file counts + shasums match
#   10  usage error (missing args, source not a directory)
#   11  transport failure (scp / cp returned non-zero)
#   12  post-transfer verification mismatch (file count or sha256)
#
# R-23: bash 3.2 compat.

set -u

usage() {
  cat >&2 <<'USAGE'
Usage: runner-exfil.sh <source-dir> <target>

  <source-dir>   Path to runner-shell /results tree.
  <target>       scp-compatible target (user@host:/path) or, when
                 $EXFIL_SCP is a local copier, a filesystem path.

Env overrides:
  EXFIL_SCP           transport command (default: scp -r)
  EXFIL_SHASUM_CMD    how to compute dest shasums:
                        "local"        — dest is a local path; use
                                         local sha256sum
                        "ssh:user@host"— ssh to user@host and run
                                         sha256sum there
                        (unset)        — auto-detect from target
                                         (user@host:path → ssh:..;
                                          /path → local)

Exit codes: 0 ok, 10 usage, 11 transport, 12 verification mismatch.
USAGE
}

err() { printf 'runner-exfil: %s\n' "$1" >&2; }

if [ "$#" -ne 2 ]; then
  usage
  exit 10
fi

SRC="$1"
TARGET="$2"

if [ ! -d "$SRC" ]; then
  err "source dir not found: $SRC"
  exit 10
fi

# ------------------------------------------------------------------------
# Transport command.
# ------------------------------------------------------------------------
EXFIL_SCP="${EXFIL_SCP:-scp -r}"

# ------------------------------------------------------------------------
# Extract remote user/host/path IF the target has a colon and no leading
# slash before it (scp idiom). Otherwise treat as local.
# ------------------------------------------------------------------------
target_kind='local'
target_remote=''
target_remote_path="$TARGET"

# Syntactic test for [user@]host:path WITHOUT consuming a drive-letter
# colon etc. — safe in bash 3.2.
case "$TARGET" in
  /*) target_kind='local' ;;
  *:*)
    # Must not start with / and must contain :; treat first : as separator.
    target_remote="${TARGET%%:*}"
    target_remote_path="${TARGET#*:}"
    target_kind='remote'
    ;;
  *) target_kind='local' ;;
esac

# ------------------------------------------------------------------------
# Source shasum manifest.
# ------------------------------------------------------------------------
SHA_TOOL=""
if command -v sha256sum >/dev/null 2>&1; then
  SHA_TOOL='sha256sum'
elif command -v shasum >/dev/null 2>&1; then
  SHA_TOOL='shasum -a 256'
else
  err "neither sha256sum nor shasum(1) available — cannot verify exfil"
  exit 11
fi

# Manifest: "<sha>  <relative-path>" lines, sorted, for stable diff.
# Emit into a tmp file inside SRC so we don't pollute outside state.
src_manifest=$(mktemp -t runner-exfil-src.XXXXXX) \
  || { err "mktemp failed"; exit 11; }
src_sorted=$(mktemp -t runner-exfil-src-sorted.XXXXXX) \
  || { err "mktemp failed"; exit 11; }
dst_sorted=$(mktemp -t runner-exfil-dst-sorted.XXXXXX) \
  || { err "mktemp failed"; exit 11; }
# Trap: clean up on any exit.
trap 'rm -f "$src_manifest" "${dst_manifest:-}" "$src_sorted" "$dst_sorted"' \
  EXIT INT TERM

( cd "$SRC" && find . -type f -print0 \
    | sort -z \
    | xargs -0 -I{} sh -c "$SHA_TOOL \"\$1\"" _ {} ) \
  > "$src_manifest" 2>/dev/null

src_file_count=$(wc -l < "$src_manifest" | tr -d ' ')
printf 'runner-exfil: source file count=%d manifest=%s\n' \
  "$src_file_count" "$src_manifest"

# ------------------------------------------------------------------------
# Transfer.
# ------------------------------------------------------------------------
printf 'runner-exfil: transport=%s target=%s kind=%s\n' \
  "$EXFIL_SCP" "$TARGET" "$target_kind"

# Split $EXFIL_SCP into command + args so `scp -r` or `cp -r` work equally.
# Safe word-split — env var is under caller control (not untrusted input).
# shellcheck disable=SC2086
if ! $EXFIL_SCP "$SRC" "$TARGET" >/dev/null 2>&1; then
  err "transport failed: $EXFIL_SCP $SRC $TARGET"
  exit 11
fi

# ------------------------------------------------------------------------
# Destination manifest.
# ------------------------------------------------------------------------
EXFIL_SHASUM_CMD_RESOLVED="${EXFIL_SHASUM_CMD:-}"
if [ -z "$EXFIL_SHASUM_CMD_RESOLVED" ]; then
  case "$target_kind" in
    remote) EXFIL_SHASUM_CMD_RESOLVED="ssh:${target_remote}" ;;
    local)  EXFIL_SHASUM_CMD_RESOLVED='local' ;;
  esac
fi

# The dest path after scp -r <src> <target>:
#   scp places <src> AS a child of <target> (directory semantics).
# Mirror that: the dest tree we need to walk is
#   <target-path>/<basename-of-src>.
src_basename=$(basename "$SRC")
case "$target_kind" in
  remote) dst_root="${target_remote_path%/}/${src_basename}" ;;
  local)  dst_root="${TARGET%/}/${src_basename}" ;;
esac

dst_manifest=$(mktemp -t runner-exfil-dst.XXXXXX) \
  || { err "mktemp failed for dst"; exit 11; }

case "$EXFIL_SHASUM_CMD_RESOLVED" in
  local)
    if [ ! -d "$dst_root" ]; then
      err "destination dir missing after transport: $dst_root"
      exit 12
    fi
    ( cd "$dst_root" && find . -type f -print0 \
        | sort -z \
        | xargs -0 -I{} sh -c "$SHA_TOOL \"\$1\"" _ {} ) \
      > "$dst_manifest" 2>/dev/null
    ;;
  ssh:*)
    ssh_target="${EXFIL_SHASUM_CMD_RESOLVED#ssh:}"
    # Pipe a remote one-liner; quote the path carefully.
    # shellcheck disable=SC2029
    ssh "$ssh_target" "cd '$dst_root' && find . -type f -print0 \
      | sort -z | xargs -0 -I{} $SHA_TOOL \"{}\"" > "$dst_manifest" 2>/dev/null \
      || { err "remote shasum failed on $ssh_target"; exit 12; }
    ;;
  *)
    err "unknown EXFIL_SHASUM_CMD mode: $EXFIL_SHASUM_CMD_RESOLVED"
    exit 12
    ;;
esac

dst_file_count=$(wc -l < "$dst_manifest" | tr -d ' ')
printf 'runner-exfil: dest   file count=%d manifest=%s\n' \
  "$dst_file_count" "$dst_manifest"

# ------------------------------------------------------------------------
# Verify.
# ------------------------------------------------------------------------
if [ "$src_file_count" != "$dst_file_count" ]; then
  err "file-count mismatch: src=${src_file_count} dst=${dst_file_count}"
  exit 12
fi

# diff-style comparison. Sort to tmp files (bash 3.2 — no process subst).
sort "$src_manifest" > "$src_sorted"
sort "$dst_manifest" > "$dst_sorted"
if ! diff "$src_sorted" "$dst_sorted" >/dev/null 2>&1; then
  err "sha256 mismatch between source and dest manifests"
  err "  first diff line:"
  diff "$src_sorted" "$dst_sorted" | head -5 >&2
  exit 12
fi

printf 'runner-exfil: OK — %d files, sha256 manifests match\n' "$src_file_count"
exit 0
