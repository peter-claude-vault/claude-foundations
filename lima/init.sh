#!/bin/bash
# lima/init.sh — Scripted Lima VM init for Claude Foundations SP00.
#
# Checks Lima version floor, starts (or reuses) the `foundations` VM from
# lima/foundations.yaml, asserts the `mounts: []` invariant holds, and
# confirms /Users is ENOENT inside the guest. Exits 0 on green, 1 on any
# failed assertion with a named diagnostic.
#
# R-23: bash 3.2 compat (macOS factory bash).

set -euo pipefail

LIMA_VERSION_FLOOR="${LIMA_VERSION_FLOOR:-0.22.0}"
LIMA_VM_NAME="${LIMA_VM_NAME:-foundations}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_YAML="${SCRIPT_DIR}/foundations.yaml"

fail() {
  printf 'lima/init.sh FAIL: %s\n' "$1" >&2
  exit 1
}

log() {
  printf 'lima/init.sh: %s\n' "$1"
}

# Returns 0 iff $1 >= $2 per semver numeric ordering. POSIX awk; bash 3.2 safe.
version_ge() {
  awk -v a="$1" -v b="$2" '
    BEGIN {
      na = split(a, A, ".")
      nb = split(b, B, ".")
      n = (na > nb) ? na : nb
      for (i = 1; i <= n; i++) {
        ai = A[i] + 0
        bi = B[i] + 0
        if (ai > bi) { exit 0 }
        if (ai < bi) { exit 1 }
      }
      exit 0
    }
  '
}

# --- 1. Lima binary present ---
if ! command -v limactl >/dev/null 2>&1; then
  fail "limactl not found on PATH. Install: brew install lima (requires >=${LIMA_VERSION_FLOOR})"
fi

# --- 2. Version floor ---
lima_raw=$(limactl --version 2>&1 | head -1 || true)
lima_ver=$(printf '%s' "$lima_raw" | awk '{ for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+/) { print $i; exit } }')
if [ -z "$lima_ver" ]; then
  fail "Could not parse Lima version from: $lima_raw"
fi
if ! version_ge "$lima_ver" "$LIMA_VERSION_FLOOR"; then
  fail "Lima ${lima_ver} below floor ${LIMA_VERSION_FLOOR}. Upgrade: brew upgrade lima"
fi
log "Lima ${lima_ver} satisfies floor ${LIMA_VERSION_FLOOR}"

# --- 3. Config file present ---
if [ ! -f "$CONFIG_YAML" ]; then
  fail "Config not found: $CONFIG_YAML"
fi

# --- 4. VM state: create or reuse ---
existing_status=$(limactl list --format='{{.Name}} {{.Status}}' 2>/dev/null | awk -v n="$LIMA_VM_NAME" '$1==n {print $2}')
if [ -n "$existing_status" ]; then
  case "$existing_status" in
    Running)
      log "VM ${LIMA_VM_NAME} already Running"
      ;;
    Stopped)
      log "Starting stopped VM ${LIMA_VM_NAME}"
      limactl start "$LIMA_VM_NAME"
      ;;
    *)
      fail "VM ${LIMA_VM_NAME} in unexpected state: ${existing_status}"
      ;;
  esac
else
  log "Creating VM ${LIMA_VM_NAME} from ${CONFIG_YAML}"
  limactl start --name="$LIMA_VM_NAME" --tty=false "$CONFIG_YAML"
fi

# --- 5. Mount audit — the invariant ---
log "Auditing mount table for host filesystem leaks"
mount_hits=$(limactl shell "$LIMA_VM_NAME" mount 2>/dev/null \
  | grep -cE ' on /Users( |$)| on /Volumes( |$)| on /private( |$)' \
  || true)
if [ "${mount_hits:-0}" != '0' ]; then
  limactl shell "$LIMA_VM_NAME" mount 2>/dev/null \
    | grep -E ' on /Users( |$)| on /Volumes( |$)| on /private( |$)' >&2 || true
  fail "Host filesystem leaked into VM mount table. Fix lima/foundations.yaml 'mounts: []' and re-run."
fi

# --- 6. /Users ENOENT inside VM ---
if limactl shell "$LIMA_VM_NAME" test -e /Users 2>/dev/null; then
  fail "/Users exists inside VM — isolation broken"
fi
if limactl shell "$LIMA_VM_NAME" test -e /Volumes 2>/dev/null; then
  fail "/Volumes exists inside VM — isolation broken"
fi

log "VM ${LIMA_VM_NAME} ready; mounts: [] invariant holds; /Users + /Volumes ENOENT confirmed"
exit 0
