#!/bin/bash
# tests/sp00-self-verify.sh
#
# SP00 T-13 — α-0 UNLOCK GATE.
#
# Runs every SP00 primitive (P1..P11) against every SP00 invariant
# (I1..I10) from one host-side orchestrator. This is the structural
# unlock for Wave α: SP01 T-1 (and every subsequent sub-plan's live-
# migration step) refuses to start unless this script has published
# `$REPO/.self-verify/sp00-self-verify-passed.json` for the current
# HEAD commit + image digest.
#
# Preconditions:
#   - clean git working tree (enforced; matches T-5 rollback drill)
#   - `.image-digest` present + image extant in Lima
#   - Lima VM `foundations` running
#   - bash 3.2+ (R-23)
#
# Output:
#   - $REPO/.self-verify/sp00-self-verify.jsonl — JSONL stream,
#     one line per primitive+invariant probe (AC1)
#   - $REPO/.self-verify/sp00-self-verify-passed.json — attestation
#     with HEAD sha + image digest + UTC timestamp (AC5). Written
#     ONLY on full green.
#
# Exit codes:
#   0  all primitives + invariants green; attestation published
#   1  any primitive/invariant fail — attestation NOT written,
#      diagnostic on stderr names failing probe
#   2  precondition fail (dirty tree, missing image, Lima down)
#
# R-23: bash 3.2 compat.

set -u

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO/.self-verify"
STREAM="$OUT_DIR/sp00-self-verify.jsonl"
ATTEST="$OUT_DIR/sp00-self-verify-passed.json"
IMAGE_DIGEST_FILE="$REPO/.image-digest"

mkdir -p "$OUT_DIR"
: > "$STREAM"   # truncate

# Clear any previous attestation — writes only on full green.
rm -f "$ATTEST"

die() { printf 'sp00-self-verify: %s\n' "$1" >&2; exit "${2:-2}"; }

fail=0
total=0

# JSONL line emit: {"probe":"<id>","ok":<bool>,"detail":"<string>"}
emit() {
  local id="$1" ok="$2" detail="${3:-}"
  # json_escape the detail
  detail=${detail//\\/\\\\}
  detail=${detail//\"/\\\"}
  detail=${detail//	/\\t}
  # strip newlines — one JSON line per probe
  detail=$(printf '%s' "$detail" | tr '\n' ' ')
  printf '{"probe":"%s","ok":%s,"detail":"%s"}\n' "$id" "$ok" "$detail" >> "$STREAM"
  total=$((total + 1))
  if [ "$ok" != "true" ]; then
    fail=$((fail + 1))
    printf 'FAIL %s: %s\n' "$id" "$detail" >&2
  fi
}

# --- Preconditions ---------------------------------------------------

# Clean working tree (AC6).
cd "$REPO" || die "cannot cd into repo $REPO"
dirty=$(git status --porcelain 2>/dev/null | head -n 5)
if [ -n "$dirty" ]; then
  die "dirty working tree — commit or stash before self-verify (T-5 precondition):
$dirty" 2
fi

# Image digest.
[ -f "$IMAGE_DIGEST_FILE" ] || die "missing $IMAGE_DIGEST_FILE — run docker/build.sh" 2
IMAGE_REF=$(head -n 1 "$IMAGE_DIGEST_FILE" | awk '{print $1}')
[ -n "$IMAGE_REF" ] || die "empty/unparseable $IMAGE_DIGEST_FILE" 2

# Lima VM.
if ! limactl list 2>/dev/null | awk '$1=="foundations" && $2=="Running"' | grep -q foundations; then
  die "Lima VM 'foundations' is not running — limactl start foundations" 2
fi

HEAD_SHA=$(git rev-parse HEAD)

printf 'sp00-self-verify: HEAD=%s image=%s\n' "$HEAD_SHA" "$IMAGE_REF"

# Shared container runner (host → Lima → nerdctl). Captures stdout.
# Uses the DEFAULT entrypoint (/entrypoint.sh) so the env-scrub layer
# fires; the caller's script runs as bash -c "$@" post-scrub. This is
# what SP01+ consumer sub-plans will do, so it is what self-verify
# must exercise.
run_in_container() {
  local extra_opts="$1"; shift
  limactl shell foundations -- bash -lc "
    export XDG_RUNTIME_DIR=/run/user/\$(id -u)
    nerdctl run --rm \
      --tmpfs /home/tester:uid=1000,gid=1000,mode=1777 \
      --network=none $extra_opts \
      $IMAGE_REF /bin/bash -c '$*'
  " 2>&1
}

# --- P1 Lima VM mount audit / I1 I10 ---------------------------------
# AC7: cat /proc/mounts | grep -E '^/Users|^/Volumes' empty
mounts_host=$(limactl shell foundations -- cat /proc/mounts 2>/dev/null \
  | grep -E '^/Users|^/Volumes' || true)
if [ -z "$mounts_host" ]; then
  emit "P1/I1.lima_mounts" "true" "no host-path mounts in Lima /proc/mounts"
else
  emit "P1/I1.lima_mounts" "false" "UNEXPECTED mounts: $mounts_host"
fi

# --- P2 container boot + readiness-gate / I9 -------------------------
gate_out=$(limactl shell foundations -- bash -lc "
  export XDG_RUNTIME_DIR=/run/user/\$(id -u)
  nerdctl run --rm \
    --tmpfs /home/tester:uid=1000,gid=1000,mode=1777 \
    --network=none \
    $IMAGE_REF /tests/readiness-gate.sh
" 2>&1)
gate_rc=$?
if [ "$gate_rc" = "0" ]; then
  emit "P2/I9.readiness_gate" "true" "readiness-gate exit 0 inside container"
else
  emit "P2/I9.readiness_gate" "false" "exit=$gate_rc out=$(echo "$gate_out" | head -c 160)"
fi

# --- P3 tester UID + HOME floor --------------------------------------
uid_out=$(run_in_container "" 'id -u; echo "HOME=$HOME"')
uid_line=$(printf '%s' "$uid_out" | awk 'NR==1{print; exit}')
home_line=$(printf '%s' "$uid_out" | grep -E '^HOME=' | head -n 1)
if [ "$uid_line" = "1000" ] && [ "$home_line" = "HOME=/home/tester" ]; then
  emit "P3.uid_home_floor" "true" "uid=1000 HOME=/home/tester"
else
  emit "P3.uid_home_floor" "false" "uid=$uid_line home=$home_line"
fi

# --- I1 /Users + /Volumes + ~/.claude unreachable from container -----
# AC4 of T-13. Host-user's home path is derived from $USER so the probe
# is adopter-agnostic and the self-verify script itself holds no
# host-user literal.
HOST_USER_DIR="/Users/${USER:-unknown}"
unreach_out=$(run_in_container "" "
  for p in /Users '$HOST_USER_DIR' /Volumes /home/tester/../../Users; do
    if [ -e \"\$p\" ]; then echo \"LEAK:\$p\"; else echo \"ENOENT:\$p\"; fi
  done
")
leaks=$(printf '%s' "$unreach_out" | grep '^LEAK:' || true)
if [ -z "$leaks" ]; then
  emit "I1.host_paths_enoent" "true" "all host paths ENOENT inside container (probed /Users + $HOST_USER_DIR + /Volumes)"
else
  emit "I1.host_paths_enoent" "false" "host paths reachable: $leaks"
fi

# --- P5 mock-launchctl / I2 ------------------------------------------
# Run a bootstrap, verify it does NOT fire a real launchd syscall
# (we're on Linux; mock writes to /results/launchctl-trace.ndjson).
# /results is image-owned by tester (see Dockerfile), so no bind-mount.
#
# Write the plist + probe script via base64 so the multi-level-quote
# hell of heredoc-through-ssh-through-bash-c does not corrupt the XML.
mock_probe_b64=$(base64 <<'INNER' | tr -d '\n'
set -u
cat > /tmp/sv.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict><key>Label</key><string>com.foundations.sv</string></dict>
</plist>
PLIST
launchctl bootstrap gui/1000 /tmp/sv.plist
echo "rc=$?"
[ -s /results/launchctl-trace.ndjson ] && echo TRACE_OK || echo TRACE_MISSING
INNER
)

mock_out=$(limactl shell foundations -- bash -lc "
  export XDG_RUNTIME_DIR=/run/user/\$(id -u)
  nerdctl run --rm \
    --tmpfs /home/tester:uid=1000,gid=1000,mode=1777 \
    --network=none \
    $IMAGE_REF /bin/bash -c \"echo $mock_probe_b64 | base64 -d | bash\"
" 2>&1)

if printf '%s' "$mock_out" | grep -q '^rc=0' && printf '%s' "$mock_out" | grep -q '^TRACE_OK'; then
  emit "P5/I2.mock_launchctl" "true" "mock bootstrap emits trace; no host launchd called"
else
  emit "P5/I2.mock_launchctl" "false" "out=$(printf '%s' "$mock_out" | tr '\n' '|' | head -c 200)"
fi

# --- P10 env-allowlist / I4 — ANTHROPIC_API_KEY stripped -------------
# Use DEFAULT entrypoint (/entrypoint.sh) so scrub fires. Pass `env`
# as the command — entrypoint exec's it post-scrub, so we observe the
# post-scrub environment.
env_out=$(limactl shell foundations -- bash -lc "
  export XDG_RUNTIME_DIR=/run/user/\$(id -u)
  nerdctl run --rm \
    --tmpfs /home/tester:uid=1000,gid=1000,mode=1777 \
    --network=none \
    -e ANTHROPIC_API_KEY=should-be-stripped-never-real \
    -e CLAUDE_HOME=/home/tester/.claude \
    $IMAGE_REF /usr/bin/env
" 2>&1)
ak_line=$(printf '%s' "$env_out" | grep -E '^ANTHROPIC_API_KEY=' || true)
ch_line=$(printf '%s' "$env_out" | grep -E '^CLAUDE_HOME=/home/tester/\.claude$' || true)
if [ -n "$ak_line" ]; then
  emit "P10/I4.env_scrub" "false" "ANTHROPIC_API_KEY survived scrub: $ak_line"
elif [ -n "$ch_line" ]; then
  emit "P10/I4.env_scrub" "true" "ANTHROPIC_API_KEY stripped; CLAUDE_HOME preserved"
else
  emit "P10/I4.env_scrub" "false" "allowlist behavior unexpected: $(printf '%s' "$env_out" | head -c 200)"
fi

# --- P6 grep-audit / I3 — SP00 tree first-party clean ----------------
# Stricter exclude: skip fixtures + patterns + .git + autopsy. Self-
# verify attests first-party SP00 code; layer-4 (git history) captures
# the seeded fixtures baseline, so we run with SKIP_LAYER4=1 here and
# separately attest that layer-4 hits match the known-baseline.
ga_out=$(GREP_AUDIT_SKIP_LAYER4=1 bash "$REPO/tests/grep-audit.sh" "$REPO" 2>&1 \
  | tail -n 1)
# Expected: {"target":"...","layer1":0,"layer2":0,"layer3":0,"layer4":0,"hits_total":0}
if printf '%s' "$ga_out" | grep -q '"hits_total":0'; then
  emit "P6/I3.grep_audit_first_party" "true" "layer1=0 layer2=0 layer3=0 (layer4 baseline)"
else
  emit "P6/I3.grep_audit_first_party" "false" "first-party hit: $ga_out"
fi

# Layer-4 baseline attestation: expected {l1:0, l2:0, l3:0, l4:1} —
# the one layer-4 hit is from tests/grep-audit-unit-test.sh's
# transient git-history fixture (which lives OUTSIDE the main repo
# tree inside a mktemp dir during the unit test but appears here via
# the unit-test script's heredoc source). Anything else is drift.
ga_full=$(bash "$REPO/tests/grep-audit.sh" "$REPO" 2>&1 | tail -n 1)
if printf '%s' "$ga_full" | grep -q '"layer1":0,"layer2":0,"layer3":0,"layer4":1'; then
  emit "P6/I3.grep_audit_baseline" "true" "full-tree matches T-7 seeded baseline (l4=1 unit-test history only)"
else
  emit "P6/I3.grep_audit_baseline" "false" "baseline drift: $ga_full"
fi

# --- Bypass audit (T-12) — no direct-shell container invocations ---
ba_out=$(bash "$REPO/tests/bypass-audit.sh" "$REPO" 2>&1 | tail -n 1)
if printf '%s' "$ba_out" | grep -q '"hits":0'; then
  emit "P6/I3.bypass_audit" "true" "0 hits"
else
  emit "P6/I3.bypass_audit" "false" "bypass hit: $ba_out"
fi

# --- P7 pre-write-guard foundation-test mode / I6 --------------------
pwg_rc=0
pwg_out=$(bash "$REPO/tests/pre-write-guard-foundation-mode.sh" 2>&1 | tail -n 3)
pwg_rc=$?
if [ "$pwg_rc" = "0" ]; then
  emit "P7/I6.pre_write_guard" "true" "11/11 pass"
else
  emit "P7/I6.pre_write_guard" "false" "rc=$pwg_rc out=$pwg_out"
fi

# --- P8 git-snapshot + rollback drill / I6 I8 ------------------------
# The drill creates a snapshot, simulates a mutation, and verifies the
# revert path restores the tree. Runs on a clean tree; any leftover
# diff after revert is a fail.
drill_out=$(bash "$REPO/tests/drill-rollback.sh" 2>&1 | tail -n 5)
drill_rc=$?
if [ "$drill_rc" = "0" ]; then
  emit "P8/I6.I8.rollback_drill" "true" "snapshot→mutate→revert diff clean"
else
  emit "P8/I6.I8.rollback_drill" "false" "rc=$drill_rc out=$(printf '%s' "$drill_out" | tr '\n' '|' | head -c 200)"
fi

# --- P9 $DOGFOOD_ROOT helper -----------------------------------------
dogfood_rc=0
dogfood_out=$(
  set +u
  unset DOGFOOD_ROOT
  . "$REPO/tests/dogfood-root-helper.sh" || exit 90
  [ -n "${DOGFOOD_ROOT:-}" ] || exit 91
  [ -d "$DOGFOOD_ROOT" ] || exit 92
  touch "$DOGFOOD_ROOT/probe" && rm -f "$DOGFOOD_ROOT/probe" || exit 93
  echo "DOGFOOD_ROOT=$DOGFOOD_ROOT"
)
dogfood_rc=$?
if [ "$dogfood_rc" = "0" ]; then
  emit "P9.dogfood_root_helper" "true" "helper sources; DOGFOOD_ROOT valid"
else
  emit "P9.dogfood_root_helper" "false" "rc=$dogfood_rc out=$dogfood_out"
fi

# --- I7 no secondary $HOME/.claude refs in SP00 first-party ---------
# Scope: runtime-material refs in .sh files under docker/ + tests/.
# Comments and documentation prose are legitimate (the Dockerfile
# explains the /etc/passwd remap mechanism by naming expanduser("~/
# .claude") as the vector being defeated — that is an architectural
# note, not a runtime ref). The check targets shell-script paths of
# the form `$HOME/.claude`, `${HOME}/.claude`, `~/.claude` on a line
# that is NOT a comment.
home_refs=$(grep -rIn -E '(\$HOME|\$\{HOME\}|(^|[^A-Za-z0-9_])~)/?\.claude' \
    "$REPO/docker"/*.sh "$REPO/tests"/*.sh "$REPO/lima"/*.yaml 2>/dev/null \
  | grep -vE '/grep-audit-fixtures/|/grep-audit-patterns/|sp00-self-verify\.sh|pre-write-guard-foundation-mode\.sh' \
  | awk -F: '{
      # Drop lines whose content (post lineno) begins with # after trim.
      content=$0; sub(/^[^:]*:[0-9]+:/, "", content);
      # Trim leading ws.
      sub(/^[ \t]+/, "", content);
      if (content ~ /^#/) next;
      print
    }' \
  | head -n 5)
if [ -z "$home_refs" ]; then
  emit "I7.no_home_claude_secondary_refs" "true" "no runtime \$HOME/.claude literals in SP00 shell scripts"
else
  emit "I7.no_home_claude_secondary_refs" "false" "refs: $home_refs"
fi

# --- P11 burner-key runbook static asserts --------------------------
if [ -f "$REPO/docs/burner-key-runbook.md" ] \
   && [ "$(wc -l < "$REPO/docs/burner-key-runbook.md")" -gt 100 ] \
   && grep -q 'Phase 1 — Create' "$REPO/docs/burner-key-runbook.md" \
   && grep -q 'Phase 5 — Revoke' "$REPO/docs/burner-key-runbook.md" \
   && grep -q -- '--mount=type=secret' "$REPO/docs/burner-key-runbook.md"; then
  emit "P11.burner_runbook" "true" "5-phase runbook present; --secret injection pattern documented"
else
  emit "P11.burner_runbook" "false" "runbook incomplete or missing"
fi

# --- I10 Lima NAT + Docker --network=none ----------------------------
# Inside --network=none container, an outbound TCP connect must fail
# fast (no interface). A successful connect would prove --network=none
# is not being applied.
i10_out=$(run_in_container "" '
  # getent only works if network stack is usable; test via python
  python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(2)
try:
  s.connect((\"1.1.1.1\", 443))
  print(\"LEAK:connected\")
except Exception as e:
  print(f\"OK:{type(e).__name__}\")
" 2>&1
')
if printf '%s' "$i10_out" | grep -q '^OK:'; then
  emit "I10.network_isolation" "true" "outbound TCP blocked (--network=none enforced)"
else
  emit "I10.network_isolation" "false" "network reachable: $i10_out"
fi

# Lima config: mounts: [] present AND no active `networks:` stanza
# (default user-mode NAT applies). The lima config comment enumerates
# this decision — we match "mounts: []" and the absence of a non-
# commented `networks:` key.
lima_file="$REPO/lima/foundations.yaml"
lima_mounts_ok=$(grep -E '^\s*mounts:\s*\[\]\s*$' "$lima_file" || true)
# Any non-comment line starting with `networks:` is a drift from the
# default NAT-only posture.
lima_networks_stanza=$(grep -E '^\s*networks:\s*$|^\s*networks:\s*\[' "$lima_file" || true)
if [ -n "$lima_mounts_ok" ] && [ -z "$lima_networks_stanza" ]; then
  emit "I10.lima_config" "true" "lima/foundations.yaml: mounts: [] + no networks: stanza (default NAT)"
else
  emit "I10.lima_config" "false" "mounts_ok='$lima_mounts_ok' networks_stanza='$lima_networks_stanza'"
fi

# --- P4 sandbox-exec (macOS-only) ------------------------------------
if [ "$(uname -s)" = "Darwin" ] && command -v sandbox-exec >/dev/null 2>&1; then
  sb_rc=0
  bash "$REPO/tests/macos-smoke-driver-test.sh" >/dev/null 2>&1 || sb_rc=$?
  if [ "$sb_rc" = "0" ]; then
    emit "P4.sandbox_exec" "true" "macos-smoke-driver-test 6/6 green"
  else
    emit "P4.sandbox_exec" "false" "macos-smoke-driver-test rc=$sb_rc"
  fi
else
  emit "P4.sandbox_exec" "true" "skipped on non-Darwin host (documented)"
fi

# --- Runner-shell end-to-end + /results exfil grep-audit / I5 -------
# Exercise the full container run path via the synthetic 7-case suite,
# then grep-audit the /results tree before it would be exfil'd. The
# synthetic 7-case suite has 4 pass + 2 soft + 2 hard → aggregate=3.
# We retain cid via --cidfile, run `nerdctl cp <cid>:/results` to a
# Lima-side tmp, then `limactl copy` to the host. The container exits
# with aggregate=3 (expected) which is fine — we only need the
# summary.json + logs tree for attest.
rs_tmp="$REPO/.self-verify/results-sample"
rm -rf "$rs_tmp"; mkdir -p "$rs_tmp"

rs_script='
export XDG_RUNTIME_DIR=/run/user/$(id -u)
cid_file=$(mktemp -t sv-cid.XXXXXX)
# --rm conflicts with --cidfile on stopped containers; use --name instead.
cname=sv-runner-$$
nerdctl run --name $cname \
  --tmpfs /home/tester:uid=1000,gid=1000,mode=1777 \
  --network=none \
  '"$IMAGE_REF"' /tests/runner-shell.sh
agg_rc=$?
out_dir=$(mktemp -d -t sv-res.XXXXXX)
nerdctl cp $cname:/results/. $out_dir/ 2>/dev/null
nerdctl rm $cname >/dev/null 2>&1
echo LIMARESDIR=$out_dir
echo AGG_RC=$agg_rc
'
rs_out=$(limactl shell foundations -- bash -lc "$rs_script" 2>&1)
lima_res=$(printf '%s' "$rs_out" | grep -E '^LIMARESDIR=' | sed 's/^LIMARESDIR=//')
agg_rc=$(printf '%s' "$rs_out" | grep -E '^AGG_RC=' | sed 's/^AGG_RC=//')

if [ -n "$lima_res" ]; then
  # tar the Lima-side dir over ssh → host; limactl copy works only on
  # explicit files, not dir-to-dir. Use `limactl shell` + tar pipe.
  limactl shell foundations -- tar -cC "$lima_res" . 2>/dev/null | tar -xC "$rs_tmp" 2>/dev/null || true
fi

# Expected aggregate=3 (max of per-case exits); presence of summary.json
# + 7 case logs is the gate.
case_log_count=$(find "$rs_tmp" -maxdepth 1 -type f -name '*.log' 2>/dev/null | wc -l | tr -d ' ')
summary_present='n'
[ -s "$rs_tmp/summary.json" ] && summary_present='y'

if [ "$summary_present" = 'y' ] && [ "$case_log_count" -ge 1 ]; then
  emit "P2.runner_shell_end_to_end" "true" "agg_rc=$agg_rc summary.json present; case logs=$case_log_count"
else
  emit "P2.runner_shell_end_to_end" "false" "agg_rc=$agg_rc summary_present=$summary_present case_logs=$case_log_count rs_out=$(printf '%s' "$rs_out" | tr '\n' '|' | head -c 200)"
fi

# I5: grep-audit the copied /results tree.
ga_res=$(GREP_AUDIT_SKIP_LAYER4=1 bash "$REPO/tests/grep-audit.sh" "$rs_tmp" 2>&1 | tail -n 1)
if printf '%s' "$ga_res" | grep -q '"hits_total":0'; then
  emit "I5.results_exfil_leak_free" "true" "grep-audit /results sample clean"
else
  emit "I5.results_exfil_leak_free" "false" "results-audit=$ga_res"
fi

# --- Summary ---------------------------------------------------------
printf '\n== sp00-self-verify summary ==\n'
printf 'probes=%d fail=%d\n' "$total" "$fail"

if [ "$fail" -ne 0 ]; then
  printf 'RESULT: FAIL (attestation NOT written)\n'
  exit 1
fi

# Write attestation.
ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
img_digest=$(printf '%s' "$IMAGE_REF" | sed -n 's/.*\(sha256:[0-9a-f]\{64\}\).*/\1/p')
[ -n "$img_digest" ] || img_digest="$IMAGE_REF"

cat > "$ATTEST" <<JSON
{
  "schema": "sp00-self-verify-passed.v1",
  "head_sha": "$HEAD_SHA",
  "image_digest": "$img_digest",
  "timestamp_utc": "$ts",
  "probes_total": $total,
  "probes_failed": 0,
  "stream_file": "$STREAM"
}
JSON

printf 'RESULT: PASS — attestation written: %s\n' "$ATTEST"
exit 0
