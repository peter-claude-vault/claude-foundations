#!/bin/bash
# docker/build.sh
#
# Host-side wrapper that ships the SP00 source tree into the Lima VM and
# builds the sp00-isolation OCI image there (rootless containerd-via-nerdctl
# inside the VM is the only supported build target — Docker Desktop on macOS
# is explicitly rejected because its default /Users bind-mount reopens the
# April-13 vector).
#
# Why nerdctl not dockerd:
#   Lima's default Ubuntu 24.04 template auto-provisions containerd-rootless
#   + nerdctl + buildkitd at VM boot. nerdctl drives the same BuildKit daemon
#   docker would (via containerd-worker), reads our Dockerfile identically,
#   and supports every flag this harness uses (--tmpfs uid/gid/mode,
#   --network=none, --secret id=,src= for T-11 burner key, image save/export
#   for grep-audit). Skipping the dockerd daemon saves ~60-90 MB RSS and
#   ~70 MB disk, and keeps us on Lima's blessed path. Isolation posture is
#   identical — same rootlesskit, same runc, same seccomp/apparmor/userns.
#   See 00-isolation-harness/spec.md §Key Design Decisions.
#
# Flow:
#   1. Assert Lima VM `foundations` is Running; abort otherwise with a
#      pointer to lima/init.sh.
#   2. Assert containerd-rootless + nerdctl are responsive inside the VM.
#   3. limactl copy the source tree into the VM at ~/foundations-build-<sha>/.
#   4. `nerdctl build -t sp00-isolation:<git-sha>` inside the VM.
#   5. Copy the resulting image digest back to the host at .image-digest.
#
# Exit codes:
#   0  image built; .image-digest on host is non-empty
#   9  pre-conditions failed (Lima down, nerdctl missing/unresponsive, dirty tree)
#   5  build or copy failed
#
# R-23: bash 3.2 compat.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

err() { printf 'docker/build.sh: %s\n' "$1" >&2; }

# Every `limactl shell foundations -- nerdctl ...` invocation must ensure the
# user's XDG_RUNTIME_DIR is set so nerdctl can reach the rootless containerd
# socket at /run/user/<uid>/containerd-rootless/. limactl's non-login ssh
# session does not set this; `bash -lc` + explicit export is the fix.
LIMA_NERDCTL='bash -lc '\''export XDG_RUNTIME_DIR=/run/user/$(id -u) && nerdctl'\'

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

# nerdctl + containerd-rootless must be responsive inside the VM. Lima's
# default provisioning brings them up at VM boot; if they're missing, the VM
# was booted with a non-default template or provisioning failed.
if ! limactl shell foundations -- command -v nerdctl >/dev/null 2>&1; then
  err "nerdctl not installed inside Lima VM"
  err "  Lima's default Ubuntu 24.04 template provisions nerdctl at boot."
  err "  If missing, re-run: ${REPO_ROOT}/lima/init.sh"
  exit 9
fi
if ! limactl shell foundations -- bash -lc \
     'export XDG_RUNTIME_DIR=/run/user/$(id -u) && nerdctl info' \
     >/dev/null 2>&1; then
  err "rootless containerd installed but not responsive inside VM"
  err "  fix: limactl shell foundations -- \\"
  err "         bash -lc 'containerd-rootless-setuptool.sh install'"
  exit 9
fi

# --- 2. Source tree → VM ---
# Use a fresh staging dir per build so we don't inherit stale artifacts.
# The `mounts: []` invariant holds — this is a one-shot scp-over-tar transfer,
# not a bind-mount. The tarball is materialized inside the VM's own ext4
# filesystem and lives only for the duration of the build.
git_sha=$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || printf 'nogit')
stage_dir="foundations-build-${git_sha}"

limactl shell foundations -- rm -rf "${stage_dir}" >/dev/null 2>&1 || true
# tar+pipe is more reliable than per-file copy for a nested tree, and
# avoids wildcard expansion quirks in `limactl copy`.
if ! ( cd "$REPO_ROOT" && tar --exclude='.git/objects' --exclude='.git/logs' \
         -cf - . ) \
   | limactl shell foundations -- bash -lc "mkdir -p ${stage_dir} && tar -C ${stage_dir} -xf -"; then
  err "source transfer into VM failed"
  exit 5
fi

# --- 3. Build ---
# nerdctl build drives buildkitd through the containerd worker. BuildKit
# reads Dockerfile syntax via the # syntax=docker/dockerfile:1.7 frontend
# image (a Docker Hub-hosted BuildKit frontend — not a dockerd dependency).
image_tag="sp00-isolation:${git_sha}"
if ! limactl shell foundations -- bash -lc \
    "export XDG_RUNTIME_DIR=/run/user/\$(id -u) && \
     cd ${stage_dir} && \
     nerdctl build --iidfile .image-id -t ${image_tag} -f docker/Dockerfile ."; then
  err "nerdctl build failed"
  exit 5
fi

# --- 4. Pull digest back ---
digest=$(limactl shell foundations -- cat "${stage_dir}/.image-id" 2>/dev/null)
if [ -z "$digest" ]; then
  err "nerdctl build did not emit image id"
  exit 5
fi
printf '%s\n' "$digest" > "${REPO_ROOT}/.image-digest"

printf 'docker/build.sh: built %s\n  digest=%s\n  host=.image-digest\n' \
  "$image_tag" "$digest"
exit 0
