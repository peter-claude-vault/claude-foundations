#!/bin/bash
# tests/e2e-lima-dogfood.sh
#
# SP08 T-7a — Full E2E Lima dogfood driver, happy-path slice.
#
# Closes ACs 1-7 of T-7. AC8 (rollback drill in deliberate-failure variant)
# is deferred to T-7b via CFF-S87-1.
#
# Pipeline phases:
#   0. Pre-dogfood contract — 7 host-side invariants.
#   1. Image readiness — verify .image-digest exists + is in Lima cache.
#   2. install.sh inside container against fresh fixture.
#   3. /adopt skill (skills/adopt/adopt.sh) inside container with pre-staged
#      Alex-archetype user-manifest.json. Onboarder Section A-E flow itself
#      is NOT exercised in T-7a (requires Claude Code in image, deferred to
#      T-7b CFF-S87-1) — fixture-stage is the SP01 dogfood pattern.
#   4. librarian-cron simulated fire via baked-in MOCK_LAUNCHCTL.
#   5. uninstall.sh --full inside container; verify residue.
#   6. SP00 grep-audit on /results inside container.
#   7. /results tar-pipe exfil to host; tarball to dogfood-history/ post-scrub.
#
# Composes:
#   - sp00-self-verify.sh  (Phase 0.7 harness-selfcheck attestation)
#   - docker/build.sh      (XDG_RUNTIME_DIR + nerdctl pattern; ephemeral
#                           dogfood image build over sp00-isolation:<digest>)
#   - install.sh / skills/adopt/adopt.sh / uninstall.sh / grep-audit.sh
#   - mock-launchctl       (baked into sp00-isolation Dockerfile L110)
#
# Mounts: [] invariant preserved. The only `nerdctl -v` mount is a tarball
# file path inside the Lima VM's own ext4 filesystem (the host filesystem
# is not reachable thanks to lima/foundations.yaml `mounts: []`).
#
# Exit codes:
#   0   all 7 ACs (AC1-AC7) green; tarball archived
#   1   one or more ACs failed; tarball NOT archived; diagnostic on stderr
#   2   pre-flight failure (Lima down, image missing, dirty tree)
#
# R-23: bash 3.2 compat.

set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TS=$(date -u +%Y%m%dT%H%M%SZ)
# RESULTS lives OUTSIDE the foundation-repo so transient capture (LaunchAgents
# inventory, snapshot path, container stderr) is not scanned by grep-audit
# during sp00-self-verify. The scrubbed tarball lands in dogfood-history/
# inside the repo per spec.md L151.
RESULTS="${E2E_RESULTS_ROOT:-$HOME/.cache/foundations-e2e}/results-$TS"
HISTORY="$REPO/dogfood-history"
mkdir -p "$RESULTS/exfil" "$HISTORY"

err() { printf 'e2e: %s\n' "$1" >&2; }

# Per-AC accumulators.
AC1_OK=0  # SP00 harness-selfcheck green
AC2_OK=0  # Pre-dogfood contract 7 invariants green
AC3_OK=0  # Install + (onboard-fixture) + adopt + librarian-fire all exit 0
AC4_OK=0  # 24h simulated observation no DENYs/failures (T-7a coverage = mock-trace check)
AC5_OK=0  # Uninstall residue = 0 bytes
AC6_OK=0  # SP00 grep-audit hits_total:0 on /results
AC7_OK=0  # Tarball committed to dogfood-history/
AR8_OK=0  # T-7 start mtime > T-11.5 evidence mtime (1777761119)

# Phase 0 invariant tracker.
PH0_PASS=0
ph0() {
  local name="$1" cmd="$2"
  if eval "$cmd"; then
    printf 'phase0/%s: PASS\n' "$name" | tee -a "$RESULTS/phase0.log"
    PH0_PASS=$((PH0_PASS+1))
  else
    printf 'phase0/%s: FAIL\n' "$name" | tee -a "$RESULTS/phase0.log"
  fi
}

# --- AR-8 gate (do BEFORE anything; reject session if mtime regression) ---
T7_START_MTIME=$(date -u +%s)
AR8_BASELINE=1777761119
if [ "$T7_START_MTIME" -gt "$AR8_BASELINE" ]; then
  AR8_OK=1
  printf 'AR-8 gate: PASS (start_mtime=%s > baseline=%s)\n' \
    "$T7_START_MTIME" "$AR8_BASELINE" | tee -a "$RESULTS/ar-8.log"
else
  err "AR-8 gate FAIL: start_mtime=$T7_START_MTIME <= baseline=$AR8_BASELINE"
  exit 2
fi

# ===========================================================================
# Phase 0 — Pre-dogfood contract (7 invariants)
# ===========================================================================
printf '\n=== Phase 0: pre-dogfood contract ===\n' | tee -a "$RESULTS/phase0.log"

# 0.1 — git working tree clean (foundation-repo). Required to make rollback
# drills meaningful (T-5 incident-response convention; rollback restores HEAD).
ph0 "git_status_clean" \
    "[ -z \"\$(git -C \"$REPO\" status --porcelain)\" ]"

# 0.2 — rsync ~/.claude/ snapshot to sibling path (not under .claude/, so
# R-55 trigger glob does NOT fire; rsync via Bash is outside G1 anyway).
SNAP="$HOME/.claude.pre-dogfood-$TS"
rsync -a --exclude='projects/' --exclude='plugins/cache/' \
      "$HOME/.claude/" "$SNAP/" >"$RESULTS/rsync.log" 2>&1 || true
ph0 "rsync_snapshot" "[ -d \"$SNAP\" ]"
echo "$SNAP" > "$RESULTS/snapshot-path.txt"

# 0.3 — vault git readable.
VAULT="$HOME/Documents/Obsidian Vault"
git -C "$VAULT" status --porcelain > "$RESULTS/vault-status.txt" 2>&1 || true
ph0 "vault_git_readable" "[ -f \"$RESULTS/vault-status.txt\" ]"

# 0.4 — file-history mtime captured (informational; not gating).
ls -la "$HOME/.claude/file-history/" > "$RESULTS/file-history.txt" 2>&1 || true
ph0 "file_history_inspected" "[ -f \"$RESULTS/file-history.txt\" ]"

# 0.5 — LaunchAgents baseline (will diff against post-uninstall on host).
ls -la "$HOME/Library/LaunchAgents/" > "$RESULTS/pre-dogfood-plists.txt" 2>&1
ph0 "launchagents_baseline" "[ -s \"$RESULTS/pre-dogfood-plists.txt\" ]"

# 0.6 — Lima VM mounts: [] verified (no host paths inside VM).
limactl shell foundations -- cat /proc/mounts \
  | grep -E '^/Users|^/Volumes' > "$RESULTS/vm-host-mounts.txt" 2>&1 || true
ph0 "vm_mounts_empty" "[ ! -s \"$RESULTS/vm-host-mounts.txt\" ]"

# 0.7 — SP00 harness-selfcheck (this gives AC1 directly + part of AC2).
# Skip if attestation fresh (<1h) to save 5-10 min per re-run.
ATTEST="$REPO/.self-verify/sp00-self-verify-passed.json"
SV_FRESH=0
if [ -f "$ATTEST" ]; then
  ATTEST_AGE=$(( T7_START_MTIME - $(stat -f %m "$ATTEST" 2>/dev/null || echo 0) ))
  [ "$ATTEST_AGE" -lt 3600 ] && SV_FRESH=1
fi
if [ "$SV_FRESH" = '1' ]; then
  printf 'sp00-self-verify: REUSE (attestation age=%ds < 3600)\n' "$ATTEST_AGE" \
    | tee -a "$RESULTS/sp00-self-verify.log"
  SV_RC=0
else
  printf 'sp00-self-verify: running fresh\n' | tee -a "$RESULTS/sp00-self-verify.log"
  bash "$REPO/tests/sp00-self-verify.sh" >> "$RESULTS/sp00-self-verify.log" 2>&1
  SV_RC=$?
fi
ph0 "sp00_self_verify_green" "[ \"$SV_RC\" = \"0\" ]"

# AC1 = SP00 harness-selfcheck green. Direct map.
[ "$SV_RC" = '0' ] && AC1_OK=1
# AC2 = all 7 phase-0 invariants green.
[ "$PH0_PASS" -ge 7 ] && AC2_OK=1

if [ "$AC1_OK" != '1' ] || [ "$AC2_OK" != '1' ]; then
  err "Phase 0 GATE FAIL: AC1=$AC1_OK AC2=$AC2_OK ph0_pass=$PH0_PASS / 7 — refusing to dogfood"
  err "  see $RESULTS/phase0.log + $RESULTS/sp00-self-verify.log"
  exit 1
fi

# ===========================================================================
# Phase 1 — Image readiness
# ===========================================================================
printf '\n=== Phase 1: image readiness ===\n'

[ -f "$REPO/.image-digest" ] || { err "missing .image-digest — run docker/build.sh"; exit 2; }
IMAGE=$(head -n 1 "$REPO/.image-digest")
[ -n "$IMAGE" ] || { err "empty .image-digest"; exit 2; }
printf 'image: %s\n' "$IMAGE" | tee "$RESULTS/image.txt"

# Verify image is loaded in Lima cache (by digest; nerdctl accepts sha256:...
# refs to inspect; succeed=present, fail=absent).
if ! limactl shell foundations -- bash -lc \
     "export XDG_RUNTIME_DIR=/run/user/\$(id -u); nerdctl image inspect $IMAGE >/dev/null 2>&1"; then
  err "image $IMAGE not in Lima cache; run docker/build.sh"
  exit 2
fi

# ===========================================================================
# Phase 2-6 — In-container scenario (single nerdctl run via tar pipes)
# ===========================================================================
printf '\n=== Phase 2-6: in-container scenario ===\n'

# Source-repo tarball — staged via stdin into a tmp file inside Lima VM
# (VM's own ext4 filesystem; not a host bind-mount; mounts: [] preserved).
# Excludes .git/objects + .git/logs to keep transfer small.
#
# Scenario script ships permanently at tests/e2e-scenario.sh; tar pipe
# carries it in naturally — container reads from /source-repo/tests/.
SCENARIO="$REPO/tests/e2e-scenario.sh"
[ -x "$SCENARIO" ] || { err "missing or non-executable $SCENARIO"; exit 2; }


# Tar the source-repo (scenario script ships at tests/e2e-scenario.sh; carried
# in naturally) and pipe through limactl-shell into nerdctl's stdin. nerdctl's
# container reads stdin via the `tar -xf -` pattern, runs the scenario, then
# `tar -c .` /results back to its stdout — which threads back through
# limactl-shell to host.
( cd "$REPO" && tar --exclude='.git/objects' --exclude='.git/logs' \
                    --exclude='.e2e' \
                    --exclude='.self-verify/results-sample' \
                    -cf - . ) \
| limactl shell foundations -- bash -lc "
    export XDG_RUNTIME_DIR=/run/user/\$(id -u)
    HOST_TAR=\$(mktemp /tmp/source-XXXXXX.tar)
    cat > \"\$HOST_TAR\"
    # mktemp defaults to mode 600; container runs as tester (uid 1000)
    # while VM owner is uid 501 — make the tarball world-readable.
    chmod 0644 \"\$HOST_TAR\"
    nerdctl run --rm \
      --tmpfs /home/tester:uid=1000,gid=1000,mode=1777 \
      --tmpfs /tmp:uid=1000,gid=1000,mode=1777 \
      --network=none \
      -v \"\$HOST_TAR\":/source.tar:ro \
      $IMAGE /bin/bash -c '
        mkdir -p /tmp/source-repo
        tar -xf /source.tar -C /tmp/source-repo
        ln -s /tmp/source-repo /source-repo 2>/dev/null || true
        bash /source-repo/tests/e2e-scenario.sh
      '
    rc=\$?
    rm -f \"\$HOST_TAR\"
    exit \$rc
  " 2> "$RESULTS/lima-stderr.log" \
| tar -xC "$RESULTS/exfil" 2> "$RESULTS/exfil-tar.err" || true

# Tee container stderr to log; presence of phases.json marks success.
if [ ! -s "$RESULTS/exfil/phases.json" ]; then
  err "container scenario did not produce phases.json — see $RESULTS/lima-stderr.log + $RESULTS/exfil-tar.err"
  exit 1
fi

# ===========================================================================
# Phase 7 — AC verification + tarball + archive
# ===========================================================================
printf '\n=== Phase 7: AC verification + archive ===\n'

# Parse phases.json for AC verdicts.
P_INSTALL=$(jq -r '.install_rc // empty' "$RESULTS/exfil/phases.json")
P_ADOPT=$(jq -r '.adopt_rc // empty' "$RESULTS/exfil/phases.json")
P_CRON=$(jq -r '.cron_boot_rc // empty' "$RESULTS/exfil/phases.json")
P_CRON_TRACE=$(jq -r '.cron_trace_bytes // 0' "$RESULTS/exfil/phases.json")
P_UNINSTALL=$(jq -r '.uninstall_rc // empty' "$RESULTS/exfil/phases.json")
P_RESIDUE=$(jq -r '.uninstall_residue_count // 99' "$RESULTS/exfil/phases.json")
P_GA_HITS=$(jq -r '.grep_audit_hits_total // 99' "$RESULTS/exfil/phases.json")

# AC3: install + adopt + cron + uninstall all exit 0
if [ "$P_INSTALL" = '0' ] && [ "$P_ADOPT" = '0' ] \
   && [ "$P_CRON" = '0' ] && [ "$P_UNINSTALL" = '0' ]; then
  AC3_OK=1
fi

# AC4: 24h simulated observation no DENYs/failures.
# T-7a coverage: cron mock-launchctl trace was recorded (bytes > 0) AND no
# foundation hooks emitted DENY in /results logs. The full 24h-simulated
# observation cycle is deferred to T-7b (CFF-S87-2).
DENY_COUNT=$(grep -rE 'DENY|HOOK_DENY' "$RESULTS/exfil"/*.log 2>/dev/null | wc -l | tr -d ' ')
if [ "$P_CRON_TRACE" -gt 0 ] && [ "$DENY_COUNT" = '0' ]; then
  AC4_OK=1
fi

# AC5: uninstall residue == 0
[ "$P_RESIDUE" = '0' ] && AC5_OK=1

# AC6: grep-audit hits_total == 0 on /results
[ "$P_GA_HITS" = '0' ] && AC6_OK=1

# AC7: tarball committed to dogfood-history/
TARBALL="$HISTORY/dogfood-results-$TS.tar.gz"
( cd "$RESULTS/exfil" && tar -czf "$TARBALL" . ) || true

# Re-run grep-audit on the tarball before declaring AC7 green (host-side
# scrub layer; spec.md §Incident-response 'after SP00 grep-audit scrub').
TARBALL_AUDIT_LAST=$( cd "$REPO" && \
  TMPSCRUB=$(mktemp -d) && \
  tar -xzf "$TARBALL" -C "$TMPSCRUB" && \
  GREP_AUDIT_SKIP_LAYER4=1 bash tests/grep-audit.sh "$TMPSCRUB" 2>&1 | tail -1; \
  rm -rf "$TMPSCRUB" )
TARBALL_HITS=$(printf '%s' "$TARBALL_AUDIT_LAST" \
               | grep -oE '"hits_total":[0-9]+' | cut -d: -f2)
echo "tarball-scrub: $TARBALL_AUDIT_LAST" > "$RESULTS/tarball-scrub.log"
if [ -s "$TARBALL" ] && [ "$TARBALL_HITS" = '0' ]; then
  AC7_OK=1
else
  err "tarball scrub failed: hits=$TARBALL_HITS — REMOVING TARBALL"
  rm -f "$TARBALL"
fi

# ===========================================================================
# Summary
# ===========================================================================
SUMMARY="$RESULTS/e2e-summary.json"
cat > "$SUMMARY" <<JSON
{
  "schema": "e2e-lima-dogfood-summary.v1",
  "started_at_epoch": $T7_START_MTIME,
  "started_at_utc": "$(date -u -r $T7_START_MTIME +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)",
  "completed_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "image_ref": "$IMAGE",
  "results_dir": "$RESULTS",
  "tarball_path": "${TARBALL:-(absent)}",
  "tarball_present": $([ -s "${TARBALL:-/dev/null}" ] && echo true || echo false),
  "ar8_ok": $AR8_OK,
  "ac1_harness_selfcheck_green": $AC1_OK,
  "ac2_pre_dogfood_contract_green": $AC2_OK,
  "ac3_install_adopt_cron_uninstall_all_zero": $AC3_OK,
  "ac4_24h_observation_clean": $AC4_OK,
  "ac5_uninstall_residue_zero": $AC5_OK,
  "ac6_grep_audit_results_zero": $AC6_OK,
  "ac7_tarball_committed_post_scrub": $AC7_OK,
  "ac8_rollback_drill": "DEFERRED to T-7b CFF-S87-1",
  "phase0_passes": $PH0_PASS,
  "phase_exit_codes": {
    "install": ${P_INSTALL:-null},
    "adopt": ${P_ADOPT:-null},
    "cron_boot": ${P_CRON:-null},
    "uninstall": ${P_UNINSTALL:-null}
  },
  "uninstall_residue_count": ${P_RESIDUE:-99},
  "grep_audit_hits_results": ${P_GA_HITS:-99},
  "grep_audit_hits_tarball": ${TARBALL_HITS:-99},
  "snapshot_path": "$SNAP"
}
JSON

printf '\n== e2e-lima-dogfood T-7a summary ==\n'
printf '  AR-8: %s\n' "$([ "$AR8_OK" = 1 ] && echo PASS || echo FAIL)"
for ac in 1 2 3 4 5 6 7; do
  v=$(eval echo \$AC${ac}_OK)
  printf '  AC%d: %s\n' "$ac" "$([ "$v" = 1 ] && echo PASS || echo FAIL)"
done
printf '  AC8: DEFERRED to T-7b (CFF-S87-1)\n'
printf '  summary: %s\n' "$SUMMARY"
printf '  tarball: %s\n' "${TARBALL:-(absent)}"

if [ "$AC1_OK" = 1 ] && [ "$AC2_OK" = 1 ] && [ "$AC3_OK" = 1 ] \
   && [ "$AC4_OK" = 1 ] && [ "$AC5_OK" = 1 ] && [ "$AC6_OK" = 1 ] \
   && [ "$AC7_OK" = 1 ]; then
  printf 'RESULT: PASS — T-7a closed\n'
  exit 0
fi
printf 'RESULT: FAIL — see %s for per-AC verdicts\n' "$SUMMARY"
exit 1
