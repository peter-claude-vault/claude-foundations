#!/bin/bash
# tests/bypass-audit-unit-test.sh
#
# Unit test for tests/bypass-audit.sh — 4 fixture shapes that MUST be
# caught, plus 4 non-bypass shapes that MUST NOT be flagged.
#
# AC1 nerdctl run ... /bin/bash     → hit
# AC2 docker run -it ... bash       → hit
# AC3 podman run ... bash -c "..."  → hit
# AC4 ctr run ... sh                → hit
# AC5 nerdctl run ... runner-shell  → no-hit (sanctioned)
# AC6 nerdctl build ...             → no-hit (build path)
# AC7 comment-line in .sh            → no-hit (docstring)
# AC8 markdown doc (runbook-style)  → no-hit (filter excludes .md)
#
# Exit 0 iff all 8 ACs pass. R-23 bash 3.2 compat.

set -u

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$REPO/tests/bypass-audit.sh"

pass=0
fail=0
log_ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
log_bad() { printf '  FAIL  %s (%s)\n' "$1" "${2:-}"; fail=$((fail+1)); }

tmpdir=$(mktemp -d -t bypass-audit-test.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT INT TERM

# --- Hit cases ---------------------------------------------------------
mkdir -p "$tmpdir/hits"

cat > "$tmpdir/hits/ac1-nerdctl-bash.sh" <<'SH'
#!/bin/bash
nerdctl run --rm sp00-isolation:fake /bin/bash
SH

cat > "$tmpdir/hits/ac2-docker-it-bash.sh" <<'SH'
#!/bin/bash
docker run --rm -it sp00-isolation:fake bash
SH

cat > "$tmpdir/hits/ac3-podman-sh-c.sh" <<'SH'
#!/bin/bash
podman run --rm sp00-isolation:fake bash -c 'echo hi'
SH

cat > "$tmpdir/hits/ac4-ctr-sh.sh" <<'SH'
#!/bin/bash
ctr run --rm sp00-isolation:fake sh
SH

# One hit dir at a time (so diagnostic is clean).
for ac in ac1-nerdctl-bash ac2-docker-it-bash ac3-podman-sh-c ac4-ctr-sh; do
  subdir="$tmpdir/only-$ac"
  mkdir -p "$subdir"
  cp "$tmpdir/hits/$ac.sh" "$subdir/"
  if "$AUDIT" "$subdir" >/dev/null 2>&1; then
    log_bad "$ac should have been flagged as bypass" "exit=0"
  else
    rc=$?
    if [ "$rc" = "1" ]; then
      log_ok "$ac → bypass-audit exit 1 (hit)"
    else
      log_bad "$ac expected exit 1 got $rc"
    fi
  fi
done

# --- No-hit cases ------------------------------------------------------
nohit="$tmpdir/nohits"
mkdir -p "$nohit"

cat > "$nohit/ac5-sanctioned.sh" <<'SH'
#!/bin/bash
nerdctl run --rm sp00-isolation:fake /tests/runner-shell.sh
SH

cat > "$nohit/ac6-build.sh" <<'SH'
#!/bin/bash
nerdctl build --tag sp00-isolation:fake -f docker/Dockerfile .
SH

cat > "$nohit/ac7-comment.sh" <<'SH'
#!/bin/bash
# nerdctl run --rm sp00-isolation:fake /bin/bash   <-- docstring only
echo 'no container invocation here'
SH

cat > "$nohit/ac8-doc.md" <<'MD'
# Burner key runbook excerpt
```
nerdctl run --rm sp00-isolation:fake /bin/bash
```
MD

if "$AUDIT" "$nohit" >/dev/null 2>&1; then
  log_ok "AC5-AC8 sanctioned/build/comment/markdown: no-hit"
else
  rc=$?
  log_bad "AC5-AC8 expected exit 0 got $rc — false positive"
  "$AUDIT" "$nohit" 2>&1 | head -10
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
