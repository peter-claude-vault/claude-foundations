#!/bin/bash
# tests/readiness-gate-tamper-test.sh
#
# SP00 T-12 acceptance — synthetic "tampered container" test proving
# that the readiness gate's I_UID-tamper branch (lines that check the
# tester:1000 entry in /etc/passwd) fires with the correct diagnostic
# when the passwd entry is removed.
#
# This test drives the container with --user 0:0 so it can mutate the
# overlay's /etc/passwd, then invokes /tests/readiness-gate.sh as uid
# 1000 via setpriv (which does not consult passwd). The readiness gate
# should exit 2 with the diagnostic naming 'tester:*:1000:*' missing.
#
# This test is host-side (runs from macOS via limactl → nerdctl). It
# is NOT routed through tests/runner-shell.sh because it deliberately
# invokes an alternate entrypoint and non-tester initial UID — which
# is precisely the tamper vector under test. The bypass-audit rule
# correctly does not flag this file: the final argv is `-c "..."`,
# but the command string does not end in a bare `bash` / `sh` shell.
#
# R-23: bash 3.2 compat.

set -u

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIGEST_FILE="$REPO/.image-digest"

if [ ! -f "$IMAGE_DIGEST_FILE" ]; then
  printf 'readiness-gate-tamper-test: %s missing — run docker/build.sh first\n' \
    "$IMAGE_DIGEST_FILE" >&2
  exit 64
fi

IMAGE_TAG=$(head -n 1 "$IMAGE_DIGEST_FILE" | awk '{print $1}')
if [ -z "$IMAGE_TAG" ]; then
  printf 'readiness-gate-tamper-test: could not parse image tag from %s\n' \
    "$IMAGE_DIGEST_FILE" >&2
  exit 64
fi

# Script run INSIDE the container as root (uid 0), which then:
#   1. Removes the tester entry from /etc/passwd.
#   2. Invokes readiness-gate via setpriv --reuid 1000 --regid 1000.
#   3. Captures exit code + stderr diagnostic.
#   4. Prints TAMPER_EXIT and TAMPER_DIAG lines that the host parses.
read -r -d '' INNER_SCRIPT <<'INNER' || true
#!/bin/bash
set -u
if ! grep -qE '^tester:[^:]*:1000:' /etc/passwd; then
  echo 'INNER-SETUP-FAIL tester line absent before tamper'
  exit 90
fi
sed -i '/^tester:[^:]*:1000:/d' /etc/passwd
if grep -qE '^tester:[^:]*:1000:' /etc/passwd; then
  echo 'INNER-SETUP-FAIL sed did not remove tester line'
  exit 91
fi
# Fake HOME so I_HOME passes — we are only testing the passwd tamper.
# setpriv reruns gate as uid=1000 without consulting passwd.
HOME=/home/tester \
  setpriv --reuid=1000 --regid=1000 --clear-groups \
    /tests/readiness-gate.sh 2>/tmp/gate-stderr
rc=$?
echo "TAMPER_EXIT=$rc"
echo 'TAMPER_DIAG<<EOF'
cat /tmp/gate-stderr
echo 'EOF'
INNER

# Execute inside container.
out=$(
  limactl shell foundations -- bash -lc "
    export XDG_RUNTIME_DIR=/run/user/\$(id -u)
    nerdctl run --rm \
      --tmpfs /home/tester:uid=1000,gid=1000,mode=1777 \
      --network=none \
      --user 0:0 \
      --entrypoint /bin/bash \
      $IMAGE_TAG -c '$(printf '%s' "$INNER_SCRIPT" | sed "s/'/'\\\\''/g")'
  " 2>&1
)
outer_rc=$?

# --- Assertions ---
fail=0
pass=0
log_ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
log_bad() { printf '  FAIL  %s (%s)\n' "$1" "${2:-}"; fail=$((fail+1)); }

if [ "$outer_rc" -ne 0 ]; then
  # A non-zero outer rc is OK — the test deliberately trips the gate.
  # But we need to have captured TAMPER_EXIT from the inner script.
  :
fi

tamper_exit=$(printf '%s' "$out" | grep -E '^TAMPER_EXIT=' | head -n 1 \
  | sed 's/^TAMPER_EXIT=//')
tamper_diag=$(printf '%s' "$out" | awk '/^TAMPER_DIAG<<EOF$/{flag=1; next} /^EOF$/{flag=0} flag')

if [ "$tamper_exit" = "2" ]; then
  log_ok "AC: readiness-gate tamper branch exits 2"
else
  log_bad "expected TAMPER_EXIT=2 got '${tamper_exit:-<empty>}'" \
    "outer_rc=$outer_rc raw=$(printf '%s' "$out" | tail -10 | tr '\n' '|')"
fi

if printf '%s' "$tamper_diag" | grep -qE "I_UID .*tester:\\*:1000:\\*" ; then
  log_ok "AC: diagnostic names 'tester:*:1000:*' missing line"
else
  log_bad "diagnostic does not name the expected pattern" \
    "diag=$(printf '%s' "$tamper_diag" | tr '\n' '|' | head -c 200)"
fi

echo
echo "== Summary =="
echo "pass=$pass fail=$fail"
if [ "$fail" -eq 0 ]; then
  echo "RESULT: green"
  exit 0
else
  echo "RESULT: red"
  exit 1
fi
