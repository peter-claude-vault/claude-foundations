#!/bin/bash
# tests/installer-macos-smoke.sh — Plan 71 SP08 T-5 (S71 L2 slice)
#
# L2 scope: real `launchctl bootstrap gui/$UID rc=0` verification under live
# macOS launchd. Designed to run on a GHA macos-14 ephemeral runner — NOT on a
# developer host. Exercises the full install → render → bootstrap → print →
# uninstall lifecycle against a real launchd domain (kernel-boundary isolation
# via the ephemeral guest, not sandbox-exec — see the S70 dogfood.sb
# documentary block for why sandbox-exec cannot contain launchctl).
#
# Inheritance:
#   - SP08 T-5 AC #4 — G1/G4/G6 + launchctl bootstrap rc=0 under live launchd
#   - CFF-S55-4 — real-launchctl rc verification
#   - SP03 T-15 AC #7 — closes via inheritance
#
# Hard guard (R-55 + feedback_hard_constraint_overrides_spec): refuses to run
# unless GITHUB_ACTIONS=true OR MACOS_SMOKE_ALLOW_HOST_LAUNCHD=1. Real
# launchctl bootstrap mutates the live user launchd domain (gui/$UID); this
# guard prevents accidental host execution. The L1 unit test
# (tests/installer/installer-macos-smoke-unit-test.sh) covers all filesystem
# isolation surfaces with PATH-injected mock-launchctl; this driver is
# specifically the layer that requires real launchctl + ephemeral host.
#
# Output: $MACOS_SMOKE_OUTPUT_DIR/macos-smoke-passed.json. The driver emits
# the JSON unsigned; L3 (S72) signs at workflow level via Sigstore + OIDC
# (actions/attest-build-provenance@v2 in macos-smoke.yml; release.yml
# verifies via `gh attestation verify`). Spec §release-attestation signing
# protocol updated S72 from GPG-detach-sign to Sigstore-OIDC — operational
# ceremony cost incompatible with release cadence.
#
# Bash 3.2 clean (R-23). R-37 single-deliverable (driver + workflow YAML).

set -u

# --- hard guard: GHA-only by default ---------------------------------
if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "${MACOS_SMOKE_ALLOW_HOST_LAUNCHD:-0}" != "1" ]; then
  printf 'installer-macos-smoke FAIL: refuses to run outside GHA.\n' >&2
  printf '  Real `launchctl bootstrap` mutates live user launchd (gui/$UID).\n' >&2
  printf '  Set GITHUB_ACTIONS=true (auto-set in CI) or MACOS_SMOKE_ALLOW_HOST_LAUNCHD=1 to override.\n' >&2
  exit 64
fi

# --- platform + tool prereqs -----------------------------------------
case "$(uname -s)" in
  Darwin) ;;
  *) printf 'installer-macos-smoke FAIL: requires Darwin; got %s\n' "$(uname -s)" >&2; exit 65 ;;
esac

for tool in jq plutil envsubst launchctl git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'installer-macos-smoke FAIL: required tool missing: %s\n' "$tool" >&2
    exit 65
  fi
done

# --- locate foundation-repo + outputs --------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
UNINSTALL_SH="$REPO_ROOT/uninstall.sh"
RENDER="$REPO_ROOT/installer/render-launchd.sh"
GREP_AUDIT="$REPO_ROOT/tests/grep-audit.sh"

for f in "$INSTALL_SH" "$UNINSTALL_SH" "$RENDER" "$GREP_AUDIT"; do
  if [ ! -e "$f" ]; then
    printf 'installer-macos-smoke FAIL: prereq missing: %s\n' "$f" >&2
    exit 65
  fi
done

OUT_DIR="${MACOS_SMOKE_OUTPUT_DIR:-$PWD/.macos-smoke-out}"
mkdir -p "$OUT_DIR"

DOGFOOD_ROOT="${DOGFOOD_ROOT:-${RUNNER_TEMP:-$(mktemp -d -t macos-smoke.XXXXXX)}/dogfood-root}"
mkdir -p "$DOGFOOD_ROOT"

CLAUDE_HOME_RUNTIME="$DOGFOOD_ROOT/.claude"
LABEL="com.claude-stem.librarian-scan"
UID_REAL=$(id -u)
DOMAIN="gui/$UID_REAL"

# Capture host LaunchAgents fingerprint as informational baseline. With
# HOME=$DOGFOOD_ROOT the real-user $HOME/Library/LaunchAgents path is the
# DOGFOOD_ROOT path; the runner's /Users/runner/Library/LaunchAgents (the
# actual host) is captured separately so attestation records both.
RUNNER_HOME_LA="/Users/runner/Library/LaunchAgents"
HOST_LA_BEFORE=""
if [ -d "$RUNNER_HOME_LA" ]; then
  HOST_LA_BEFORE=$(ls -1 "$RUNNER_HOME_LA" 2>/dev/null | LC_ALL=C sort | tr '\n' ',')
fi

cleanup_label() {
  # Defensive bootout + plist rm — runs at exit even on failure paths so a
  # partially-succeeded run doesn't leave a foundation label loaded in the
  # runner's launchd, and so the rendered plist at
  # $DOGFOOD_ROOT/Library/LaunchAgents/ is removed (CFF-S71-1: uninstall.sh
  # only walks $CLAUDE_HOME contents; plists at $HOME/Library/LaunchAgents/
  # survive uninstall by design — driver-level cleanup compensates for the
  # smoke run only). Idempotent; rc swallowed.
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  rm -f "$DOGFOOD_ROOT/Library/LaunchAgents/$LABEL.plist" 2>/dev/null || true
}
trap cleanup_label EXIT INT TERM

# --- Step 1: install.sh --apply --------------------------------------
printf '== Step 1: install.sh --apply (HOME=%s) ==\n' "$DOGFOOD_ROOT"
INSTALL_LOG="$OUT_DIR/install.log"
HOME="$DOGFOOD_ROOT" CLAUDE_HOME="$CLAUDE_HOME_RUNTIME" SOURCE_REPO="$REPO_ROOT" \
  bash "$INSTALL_SH" --apply >"$INSTALL_LOG" 2>&1
INSTALL_RC=$?
if [ "$INSTALL_RC" != "0" ]; then
  printf 'FAIL: install.sh --apply rc=%s\n' "$INSTALL_RC" >&2
  cat "$INSTALL_LOG" >&2
  exit 70
fi

PATHS_SH="$CLAUDE_HOME_RUNTIME/hooks/lib/paths.sh"
if [ ! -r "$PATHS_SH" ]; then
  printf 'FAIL: paths.sh not landed at %s\n' "$PATHS_SH" >&2
  exit 71
fi

# --- Step 2: seed orchestration.json (librarian job only) ------------
# install.sh creates the directory tree but SP07 onboarder normally writes
# orchestration.json. For a cold smoke we synthesize a minimal librarian-only
# fixture matching SP01's StartCalendarInterval schedule branch. The
# log_path / command fields are placeholders; render-launchd consumes only
# schedule.hour + schedule.minute. The plist Program path resolves to a
# file that need not exist at bootstrap time (launchd validates plist
# syntax, not Program existence).
printf '== Step 2: seed orchestration.json (librarian-only fixture) ==\n'
ORCH_JSON="$CLAUDE_HOME_RUNTIME/orchestration.json"
cat > "$ORCH_JSON" <<'JSON'
{
  "schema_version": "1.0.0",
  "platform": "darwin-launchd",
  "jobs": [
    {
      "id": "librarian",
      "enabled": true,
      "schedule": {"hour": 6, "minute": 0},
      "command": "echo smoke-test-job",
      "log_path": "smoke.log",
      "idle_watchdog_sec": 180
    }
  ],
  "tripwires": [],
  "observability": {
    "morning_brief_staleness_h": 48,
    "librarian_staleness_h": 24,
    "sessionstart_banner_staleness_h": 24
  }
}
JSON

# --- Step 3: render-launchd.sh librarian (production mode) ----------
# Production mode: render-launchd writes plist to $HOME/Library/LaunchAgents/
# (= $DOGFOOD_ROOT/Library/LaunchAgents/), then launchctl bootout (idempotent,
# swallowed) → launchctl bootstrap. Bootstrap rc gates exit; render-launchd
# exits 6 on bootstrap failure.
printf '== Step 3: render-launchd.sh librarian (real launchctl bootstrap) ==\n'
RENDER_LOG="$OUT_DIR/render-launchd.log"
HOME="$DOGFOOD_ROOT" CLAUDE_HOME="$CLAUDE_HOME_RUNTIME" \
  ORCHESTRATION_JSON="$ORCH_JSON" \
  bash "$RENDER" librarian </dev/null >"$RENDER_LOG" 2>&1
RENDER_RC=$?
LAUNCHCTL_BOOTSTRAP_RC="$RENDER_RC"
if [ "$RENDER_RC" != "0" ]; then
  printf 'FAIL: render-launchd.sh rc=%s\n' "$RENDER_RC" >&2
  cat "$RENDER_LOG" >&2
  exit 72
fi

# --- Step 4: launchctl print verification ---------------------------
printf '== Step 4: launchctl print %s/%s ==\n' "$DOMAIN" "$LABEL"
LAUNCHCTL_PRINT_OUT="$OUT_DIR/launchctl-print.txt"
launchctl print "$DOMAIN/$LABEL" >"$LAUNCHCTL_PRINT_OUT" 2>&1
PRINT_RC=$?
if [ "$PRINT_RC" != "0" ]; then
  printf 'FAIL: launchctl print rc=%s — label not loaded\n' "$PRINT_RC" >&2
  cat "$LAUNCHCTL_PRINT_OUT" >&2
  exit 73
fi

# --- Step 5: uninstall.sh (G6 walks live launchd list) --------------
# uninstall.sh discovers the loaded foundation label via `launchctl list |
# awk '... index($3, "com.claude-stem.") == 1'`, runs G6 substring
# defense, then bootouts. With LAUNCHCTL_BIN unset (default), uses real
# launchctl from PATH. This exercises the G6 fire-path under live launchd.
printf '== Step 5: uninstall.sh (G6 walks live launchd) ==\n'
UNINSTALL_LOG="$OUT_DIR/uninstall.log"
HOME="$DOGFOOD_ROOT" CLAUDE_HOME="$CLAUDE_HOME_RUNTIME" \
  bash "$UNINSTALL_SH" >"$UNINSTALL_LOG" 2>&1
UNINSTALL_RC=$?
if [ "$UNINSTALL_RC" != "0" ]; then
  printf 'FAIL: uninstall.sh rc=%s\n' "$UNINSTALL_RC" >&2
  cat "$UNINSTALL_LOG" >&2
  exit 74
fi

# --- Step 6: post-uninstall label-gone assertion --------------------
launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
POST_UNINSTALL_LABEL_RC=$?
if [ "$POST_UNINSTALL_LABEL_RC" = "0" ]; then
  printf 'FAIL: label %s still loaded after uninstall.sh\n' "$LABEL" >&2
  exit 75
fi

# --- Step 7: residue count ------------------------------------------
# Count files remaining under DOGFOOD_ROOT excluding:
#   - logs/ (uninstall provenance lands here; spec: "empty-minus-logs")
#   - .pre-uninstall-*/ backup dirs (expected forensic artifacts)
#   - Library/LaunchAgents/ (CFF-S71-1: uninstall.sh leaves rendered plists
#     at $HOME/Library/LaunchAgents/ — outside $CLAUDE_HOME's removal scope.
#     Tracked as SP08 follow-up; informational here, the cleanup_label trap
#     rms the plist so the runner exits clean.)
# Foundation-tree residue (under $CLAUDE_HOME excluding logs/backups) is the
# meaningful number for AC #5 inheritance.
RESIDUE_COUNT=$(find "$DOGFOOD_ROOT" -type f \
  -not -path "$CLAUDE_HOME_RUNTIME/logs/*" \
  -not -path "$CLAUDE_HOME_RUNTIME/.pre-uninstall-*/*" \
  -not -path "$DOGFOOD_ROOT/Library/LaunchAgents/*" \
  2>/dev/null | wc -l | tr -d ' ')

# --- Step 8: grep-audit (foundation source tree, 4-layer) ----------
printf '== Step 8: grep-audit foundation source tree (4-layer) ==\n'
AUDIT_FOUND_OUT="$OUT_DIR/grep-audit-foundation.json"
AUDIT_FOUND_STDERR="$OUT_DIR/grep-audit-foundation.stderr"
(cd "$REPO_ROOT" && bash "$GREP_AUDIT" .) > "$AUDIT_FOUND_OUT" 2>"$AUDIT_FOUND_STDERR"
GREP_AUDIT_FOUNDATION_HITS=$(jq -r '.hits_total // -1' < "$AUDIT_FOUND_OUT" 2>/dev/null || echo -1)

# Baseline check: foundation must produce hits_total ≤ 2 (schemas/=1 +
# onboarding/=1, established 2026-04-29 cleanup pass; preserved across SP08).
GREP_AUDIT_BASELINE=2
if [ "$GREP_AUDIT_FOUNDATION_HITS" -gt "$GREP_AUDIT_BASELINE" ]; then
  printf 'FAIL: foundation grep-audit hits_total=%s exceeds baseline %s\n' \
    "$GREP_AUDIT_FOUNDATION_HITS" "$GREP_AUDIT_BASELINE" >&2
  cat "$AUDIT_FOUND_STDERR" >&2
  exit 76
fi

# --- Step 9: host LaunchAgents fingerprint after run ----------------
HOST_LA_AFTER=""
if [ -d "$RUNNER_HOME_LA" ]; then
  HOST_LA_AFTER=$(ls -1 "$RUNNER_HOME_LA" 2>/dev/null | LC_ALL=C sort | tr '\n' ',')
fi

# --- Step 10: emit macos-smoke-passed.json --------------------------
printf '== Step 10: emit macos-smoke-passed.json ==\n'
ATTESTATION="$OUT_DIR/macos-smoke-passed.json"
GENERATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
FOUNDATION_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')
RUNNER_OS_REPORTED="${RUNNER_OS:-$(uname -s)-$(uname -r)}"
GH_RUN_ID="${GITHUB_RUN_ID:-local}"
GH_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
GH_REF="${GITHUB_REF:-}"
GH_SHA="${GITHUB_SHA:-$FOUNDATION_SHA}"

# Compose JSON via jq for safe escaping of launchctl print excerpt
# (head -30 keeps the artifact small; full output stays in launchctl-print.txt).
jq -n \
  --arg generated_at        "$GENERATED_AT" \
  --arg runner_os           "$RUNNER_OS_REPORTED" \
  --arg foundation_sha      "$FOUNDATION_SHA" \
  --arg github_run_id       "$GH_RUN_ID" \
  --arg github_run_attempt  "$GH_RUN_ATTEMPT" \
  --arg github_ref          "$GH_REF" \
  --arg github_sha          "$GH_SHA" \
  --arg label               "$LABEL" \
  --arg domain              "$DOMAIN" \
  --arg host_la_before      "$HOST_LA_BEFORE" \
  --arg host_la_after       "$HOST_LA_AFTER" \
  --argjson install_rc                  "$INSTALL_RC" \
  --argjson render_launchd_rc           "$RENDER_RC" \
  --argjson launchctl_bootstrap_rc      "$LAUNCHCTL_BOOTSTRAP_RC" \
  --argjson launchctl_print_rc          "$PRINT_RC" \
  --argjson uninstall_rc                "$UNINSTALL_RC" \
  --argjson uninstall_residue_count     "$RESIDUE_COUNT" \
  --argjson grep_audit_foundation_hits  "$GREP_AUDIT_FOUNDATION_HITS" \
  --argjson grep_audit_baseline         "$GREP_AUDIT_BASELINE" \
  --rawfile launchctl_print_raw         "$LAUNCHCTL_PRINT_OUT" \
  '{
     schema_version: "1.0.0",
     generated_at: $generated_at,
     runner_os: $runner_os,
     foundation_sha: $foundation_sha,
     github_run_id: $github_run_id,
     github_run_attempt: $github_run_attempt,
     github_ref: $github_ref,
     github_sha: $github_sha,
     label: $label,
     domain: $domain,
     install_rc: $install_rc,
     render_launchd_rc: $render_launchd_rc,
     launchctl_bootstrap_rc: $launchctl_bootstrap_rc,
     launchctl_print_rc: $launchctl_print_rc,
     uninstall_rc: $uninstall_rc,
     uninstall_residue_count: $uninstall_residue_count,
     grep_audit_foundation_hits: $grep_audit_foundation_hits,
     grep_audit_baseline: $grep_audit_baseline,
     host_la_before: $host_la_before,
     host_la_after: $host_la_after,
     launchctl_print_excerpt: ($launchctl_print_raw | split("\n") | .[0:30] | join("\n")),
     smoke_exit: 0
   }' > "$ATTESTATION"

printf 'macos-smoke-passed.json emitted at %s\n' "$ATTESTATION"
cat "$ATTESTATION"
exit 0
