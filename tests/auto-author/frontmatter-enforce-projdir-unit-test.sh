#!/bin/bash
# SP12 T-9 — frontmatter-enforce.sh PROJ_DIR parameterization unit test.
#
# Verifies that detect_type() correctly routes paths under both the default
# projects-root ("Engagements") and a user-declared alternative (e.g. "Clients").
#
# Strategy: extract the detect_type function + PROJ_DIR/PD bootstrap from the
# Python heredoc; exec it in an isolated namespace; assert routing.
#
# Bash 3.2 clean (R-23). No live ~/.claude/ writes (R-55).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$ROOT/skills/librarian/capabilities/frontmatter-enforce.sh"

PASS=0
FAIL=0
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }

# Sanity: count of "Engagements/" hardcodes must be 0.
HC=$(grep -c 'Engagements/' "$TARGET" || true)
if [ "$HC" = "0" ]; then
    pass "grep -c 'Engagements/' returns 0 (no hardcoded path literals)"
else
    fail "grep -c 'Engagements/' returns $HC (expected 0)"
fi

# Run detection harness with default proj_dir (Engagements).
TMP="$(mktemp -d -t frontmatter-enforce-projdir-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

run_detect() {
    local proj_dir="$1"
    local rel="$2"
    FM_PROJECTS_ROOT_DIRNAME="$proj_dir" python3 - "$TARGET" "$rel" <<'PY'
import os, re, sys
target_path, rel = sys.argv[1], sys.argv[2]

# Extract just the PROJ_DIR/PD bootstrap + detect_type function from the
# heredoc. The python heredoc starts with `python3 - ... <<'PY'` and ends
# at a lone `PY` line.
src_lines = []
in_heredoc = False
with open(target_path) as f:
    for line in f:
        if line.startswith("python3 - ") and "<<'PY'" in line:
            in_heredoc = True
            continue
        if in_heredoc and line.rstrip() == "PY":
            break
        if in_heredoc:
            src_lines.append(line)
heredoc = "".join(src_lines)

# Build a minimal namespace: import json, os, re, sys, datetime; load
# PROJ_DIR + PD; load detect_type. Skip everything else by truncating after
# detect_type returns None.
ns = {"os": os, "re": re, "sys": sys}

# Pull out PROJ_DIR + PD definitions.
m = re.search(r"PROJ_DIR = .*?\nPD_PLANNING = re\.escape\(PLANNING_DIR\)", heredoc, re.DOTALL)
if not m:
    print("ERROR: could not find PROJ_DIR/PD bootstrap in heredoc", file=sys.stderr)
    sys.exit(2)
exec(m.group(0), ns)

# Pull out detect_type body (everything from `def detect_type(rel, fm):` up
# to the next top-level `def `).
m2 = re.search(r"^def detect_type\(rel, fm\):.*?(?=^def )", heredoc, re.MULTILINE | re.DOTALL)
if not m2:
    print("ERROR: could not find detect_type in heredoc", file=sys.stderr)
    sys.exit(2)
exec(m2.group(0), ns)

result = ns["detect_type"](rel, {})
print(result if result is not None else "")
PY
}

# Default projects-root: "Engagements"
assert_detect() {
    local proj_dir="$1" rel="$2" expected="$3" label="$4"
    local got
    got=$(run_detect "$proj_dir" "$rel")
    if [ "$got" = "$expected" ]; then
        pass "$label (proj_dir=$proj_dir, rel='$rel' → '$got')"
    else
        fail "$label (proj_dir=$proj_dir, rel='$rel'; expected '$expected', got '$got')"
    fi
}

# === Default ("Engagements") — backward compat ===
assert_detect "Engagements" "Engagements/Acme/People/jane.md" "people" "default-engagements people"
assert_detect "Engagements" "Engagements/Acme/Projects/alpha/foo - PRD.md" "prd" "default-engagements prd"
assert_detect "Engagements" "Engagements/Acme/CLAUDE.md" "navigation" "default-engagements navigation"
assert_detect "Engagements" "Engagements/Acme/Strategic/plan.md" "strategic" "default-engagements strategic"

# === Custom ("Clients") — parameterized path ===
assert_detect "Clients" "Clients/Acme/People/jane.md" "people" "custom-clients people"
assert_detect "Clients" "Clients/Acme/Projects/alpha/foo - PRD.md" "prd" "custom-clients prd"
assert_detect "Clients" "Clients/Acme/CLAUDE.md" "navigation" "custom-clients navigation"
assert_detect "Clients" "Clients/Acme/Strategic/plan.md" "strategic" "custom-clients strategic"
assert_detect "Clients" "Clients/Acme/Planning/sprint.md" "planning" "custom-clients planning"

# === Custom proj_dir does NOT match the old "Engagements/" prefix ===
assert_detect "Clients" "Engagements/Acme/People/jane.md" "" "custom-clients does NOT match Engagements/ paths"

# === Empty/null env → fallback to Engagements ===
got=$(FM_PROJECTS_ROOT_DIRNAME="" python3 - "$TARGET" "Engagements/Acme/CLAUDE.md" <<'PY'
import os, re, sys
target_path, rel = sys.argv[1], sys.argv[2]
src_lines = []
in_heredoc = False
with open(target_path) as f:
    for line in f:
        if line.startswith("python3 - ") and "<<'PY'" in line:
            in_heredoc = True; continue
        if in_heredoc and line.rstrip() == "PY":
            break
        if in_heredoc:
            src_lines.append(line)
heredoc = "".join(src_lines)
ns = {"os": os, "re": re, "sys": sys}
m = re.search(r"PROJ_DIR = .*?\nPD_PLANNING = re\.escape\(PLANNING_DIR\)", heredoc, re.DOTALL)
exec(m.group(0), ns)
m2 = re.search(r"^def detect_type\(rel, fm\):.*?(?=^def )", heredoc, re.MULTILINE | re.DOTALL)
exec(m2.group(0), ns)
print(ns["PROJ_DIR"])
PY
)
if [ "$got" = "Engagements" ]; then
    pass "empty FM_PROJECTS_ROOT_DIRNAME falls back to 'Engagements'"
else
    fail "empty FM_PROJECTS_ROOT_DIRNAME fallback failed (got '$got')"
fi

echo
echo "=== TOTAL: $PASS PASS, $FAIL FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL CHECKS PASS"
