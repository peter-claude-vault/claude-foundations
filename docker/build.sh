#!/bin/bash
# docker/build.sh
#
# Host-side wrapper that ships the SP00 source tree into the Lima VM and
# builds the sp00-isolation Docker image there (rootless Docker inside the
# VM is the only supported build target — Docker Desktop on macOS is
# explicitly rejected because its default /Users bind-mount reopens the
# April-13 vector).
#
# Flow:
#   1. Assert Lima VM `foundations` is Running; abort otherwise with a
#      pointer to lima/init.sh.
#   2. limactl copy the source tree into the VM at ~/foundations-build/.
#   3. `limactl shell foundations -- bash -lc 'cd foundations-build && \
#       docker build -t sp00-isolation:<git-sha> docker/'`
#   4. Copy the resulting image digest back to the host at .image-digest.
#
# Exit codes:
#   0  image built; .image-digest on host is non-empty
#   9  pre-conditions failed (Lima down, Docker missing, dirty tree)
#   5  docker build or copy failed
#
# R-23: bash 3.2 compat.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

err() { printf 'docker/build.sh: %s\n' "$1" >&2; }

# --- 1. Pre-conditions ---
command -v limactl >/dev/null 2>&1 \
  || { err "limactl not on PATH; brew install lima"; exit 9; }

vm_status=$(limactl list --format='{{.Name}} {{.Status}}' 2>/dev/null \
            | awk '$1=="foundations" {print $2}')
if [ "$vm_status" != 'Running' ]; then
  err "Lima VM 'foundations' is not Running (state=${vm_status:-absent})"
  err "  fix: ${REPO_ROOT}/lima/init.sh"
  exit 9
fi

# Docker must be installed AND running inside the VM (rootless). If not,
# tell the caller how to install rather than guessing.
if ! limactl shell foundations -- command -v docker >/dev/null 2>&1; then
  err "rootless Docker not installed inside Lima VM"
  err "  fix: limactl shell foundations -- bash -c \\"
  err "         'curl -fsSL https://get.docker.com/rootless | sh && \\"
  err "          systemctl --user enable --now docker'"
  exit 9
fi
if ! limactl shell foundations -- docker info >/dev/null 2>&1; then
  err "rootless Docker installed but not running inside VM"
  err "  fix: limactl shell foundations -- systemctl --user start docker"
  exit 9
fi

# --- 2. Source tree → VM ---
# Use a fresh staging dir per build so we don't inherit stale artifacts.
# limactl copy uses scp under the hood; respects the `mounts: []` invariant
# (this is NOT a bind-mount — it's a one-shot transfer).
git_sha=$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || printf 'nogit')
stage_dir="foundations-build-${git_sha}"

limactl shell foundations -- rm -rf "${stage_dir}" >/dev/null 2>&1 || true
# The `limactl cp` needs each source argument; wildcards do not expand inside
# the VM. tar+pipe is more reliable than per-file copy for a nested tree.
if ! ( cd "$REPO_ROOT" && tar --exclude='.git/objects' --exclude='.git/logs' \
         -cf - . ) \
   | limactl shell foundations -- bash -lc "mkdir -p ${stage_dir} && tar -C ${stage_dir} -xf -"; then
  err "source transfer into VM failed"
  exit 5
fi

# --- 3. Build ---
image_tag="sp00-isolation:${git_sha}"
if ! limactl shell foundations -- bash -lc \
    "cd ${stage_dir} && docker build --iidfile .image-id -t ${image_tag} -f docker/Dockerfile ."; then
  err "docker build failed"
  exit 5
fi

# --- 4. Pull digest back ---
digest=$(limactl shell foundations -- cat "${stage_dir}/.image-id" 2>/dev/null)
if [ -z "$digest" ]; then
  err "docker build did not emit image id"
  exit 5
fi
printf '%s\n' "$digest" > "${REPO_ROOT}/.image-digest"

printf 'docker/build.sh: built %s\n  digest=%s\n  host=.image-digest\n' \
  "$image_tag" "$digest"
exit 0
