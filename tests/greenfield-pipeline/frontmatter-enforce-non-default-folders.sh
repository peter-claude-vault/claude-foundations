#!/bin/bash
# SP16 T-5b — frontmatter-enforce.sh engagement-subfolder parameterization sweep.
#
# Three-fixture sweep verifying detect_type() routes correctly under
# non-Peter vault structures:
#   - default     (Engagements / People / Projects / Strategic / Planning)
#   - academic    (Research / Collaborators / Studies / Theses / Coursework)
#   - generalist  (Work / Contacts / Tasks / Goals / Sprints)
#
# Strategy: extract the PROJ_DIR / PD_* bootstrap + detect_type from the Python
# heredoc; exec in an isolated namespace; assert routing across each fixture's
# canonical type-detection cases (people, project, prd, navigation, strategic,
# planning).
#
# Hermetic per feedback_test_isolation_for_hooks_state: each sub-test exports
# only the FM_*_DIRNAME envs (no HOOKS_STATE / CLAUDE_HOME mutations needed —
# detect_type is pure-functional given the env). No live ~/.claude/ writes (R-55).
# No live vault touches (synthetic relpath strings only) per feedback_universal_vault_safety.
#
# Bash 3.2 clean (R-23).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$ROOT/skills/librarian/capabilities/frontmatter-enforce.sh"

PASS=0
FAIL=0
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }

# Sanity: hardcoded substrings called out by spec L64 must be 0.
for tok in 'People/' 'Projects/' 'Strategic/' 'Planning/'; do
    HC=$(grep -cE "^\s*if re\.match.*\"\^.*${tok}" "$TARGET" || true)
    if [ "$HC" = "0" ]; then
        pass "no hardcoded '${tok}' regex literals in detect_type"
    else
        fail "found $HC hardcoded '${tok}' literals (expected 0)"
    fi
done

run_detect() {
    local proj_dir="$1" people="$2" projects_sub="$3" strategic="$4" planning="$5" rel="$6"
    FM_PROJECTS_ROOT_DIRNAME="$proj_dir" \
    FM_PEOPLE_DIRNAME="$people" \
    FM_PROJECTS_SUBDIRNAME="$projects_sub" \
    FM_STRATEGIC_DIRNAME="$strategic" \
    FM_PLANNING_DIRNAME="$planning" \
        python3 - "$TARGET" "$rel" <<'PY'
import os, re, sys
target_path, rel = sys.argv[1], sys.argv[2]

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

ns = {"os": os, "re": re, "sys": sys}

m = re.search(r"PROJ_DIR = .*?\nPD_PLANNING = re\.escape\(PLANNING_DIR\)", heredoc, re.DOTALL)
if not m:
    print("ERROR: could not find PROJ_DIR/PD_* bootstrap in heredoc", file=sys.stderr)
    sys.exit(2)
exec(m.group(0), ns)

m2 = re.search(r"^def detect_type\(rel, fm\):.*?(?=^def )", heredoc, re.MULTILINE | re.DOTALL)
if not m2:
    print("ERROR: could not find detect_type in heredoc", file=sys.stderr)
    sys.exit(2)
exec(m2.group(0), ns)

result = ns["detect_type"](rel, {})
print(result if result is not None else "")
PY
}

assert_detect() {
    local label="$1" proj="$2" people="$3" projects_sub="$4" strategic="$5" planning="$6" rel="$7" expected="$8"
    local got
    got=$(run_detect "$proj" "$people" "$projects_sub" "$strategic" "$planning" "$rel")
    if [ "$got" = "$expected" ]; then
        pass "$label (rel='$rel' → '$got')"
    else
        fail "$label (rel='$rel'; expected '$expected', got '$got')"
    fi
}

# === Fixture 1: default (SP10 install convention; backward-compat) ===
echo
echo "--- Fixture 1: default (Engagements/People/Projects/Strategic/Planning) ---"
F1=("Engagements" "People" "Projects" "Strategic" "Planning")
assert_detect "default people"     "${F1[@]}" "Engagements/Acme/People/jane.md"               "people"
assert_detect "default project"    "${F1[@]}" "Engagements/Acme/Projects/alpha/notes.md"     "project"
assert_detect "default prd"        "${F1[@]}" "Engagements/Acme/Projects/alpha/foo - PRD.md" "prd"
assert_detect "default navigation" "${F1[@]}" "Engagements/Acme/CLAUDE.md"                    "navigation"
assert_detect "default strategic"  "${F1[@]}" "Engagements/Acme/Strategic/plan.md"            "strategic"
assert_detect "default planning"   "${F1[@]}" "Engagements/Acme/Planning/sprint.md"           "planning"

# === Fixture 2: academic (Research/Collaborators/Studies/Theses/Coursework) ===
echo
echo "--- Fixture 2: academic (Research/Collaborators/Studies/Theses/Coursework) ---"
F2=("Research" "Collaborators" "Studies" "Theses" "Coursework")
assert_detect "academic people"     "${F2[@]}" "Research/Lab1/Collaborators/postdoc.md"       "people"
assert_detect "academic project"    "${F2[@]}" "Research/Lab1/Studies/exp01/notes.md"        "project"
assert_detect "academic prd"        "${F2[@]}" "Research/Lab1/Studies/exp01/foo - PRD.md"   "prd"
assert_detect "academic navigation" "${F2[@]}" "Research/Lab1/CLAUDE.md"                      "navigation"
assert_detect "academic strategic"  "${F2[@]}" "Research/Lab1/Theses/dissertation.md"         "strategic"
assert_detect "academic planning"   "${F2[@]}" "Research/Lab1/Coursework/syllabus.md"         "planning"

# Cross-namespace negative: academic config must NOT match Engagements/People paths
assert_detect "academic NEG default-people" "${F2[@]}" "Engagements/Acme/People/jane.md" ""
assert_detect "academic NEG default-strategic" "${F2[@]}" "Engagements/Acme/Strategic/plan.md" ""

# === Fixture 3: generalist (Work/Contacts/Tasks/Goals/Sprints) ===
echo
echo "--- Fixture 3: generalist (Work/Contacts/Tasks/Goals/Sprints) ---"
F3=("Work" "Contacts" "Tasks" "Goals" "Sprints")
assert_detect "generalist people"     "${F3[@]}" "Work/ClientA/Contacts/jane.md"             "people"
assert_detect "generalist project"    "${F3[@]}" "Work/ClientA/Tasks/proj1/notes.md"         "project"
assert_detect "generalist prd"        "${F3[@]}" "Work/ClientA/Tasks/proj1/foo - PRD.md"    "prd"
assert_detect "generalist navigation" "${F3[@]}" "Work/ClientA/CLAUDE.md"                     "navigation"
assert_detect "generalist strategic"  "${F3[@]}" "Work/ClientA/Goals/q1-okrs.md"              "strategic"
assert_detect "generalist planning"   "${F3[@]}" "Work/ClientA/Sprints/s24.md"                "planning"

# Cross-namespace negative: generalist config must NOT match academic paths
assert_detect "generalist NEG academic-people" "${F3[@]}" "Research/Lab1/Collaborators/postdoc.md" ""

# === Empty / unset env → all four fall back to canonical defaults ===
echo
echo "--- Fallback: empty FM_*_DIRNAME envs → canonical defaults ---"
got=$(FM_PROJECTS_ROOT_DIRNAME="" FM_PEOPLE_DIRNAME="" FM_PROJECTS_SUBDIRNAME="" \
      FM_STRATEGIC_DIRNAME="" FM_PLANNING_DIRNAME="" \
      python3 - "$TARGET" "Engagements/Acme/People/jane.md" <<'PY'
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
result = ns["detect_type"](rel, {})
print(result if result is not None else "")
PY
)
if [ "$got" = "people" ]; then
    pass "all-empty envs route default Engagements/Acme/People/jane.md → 'people'"
else
    fail "all-empty fallback failed (got '$got')"
fi

# Verify each PD_* var falls back independently
got=$(FM_PROJECTS_ROOT_DIRNAME="Work" FM_PEOPLE_DIRNAME="" \
      FM_PROJECTS_SUBDIRNAME="Tasks" FM_STRATEGIC_DIRNAME="Goals" \
      FM_PLANNING_DIRNAME="Sprints" \
      python3 - "$TARGET" "Work/ClientA/People/jane.md" <<'PY'
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
result = ns["detect_type"](rel, {})
print(result if result is not None else "")
PY
)
if [ "$got" = "people" ]; then
    pass "partial-empty (PEOPLE only blank) routes Work/ClientA/People/jane.md → 'people' (default)"
else
    fail "partial-empty fallback failed (got '$got')"
fi

echo
echo "=== TOTAL: $PASS PASS, $FAIL FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL CHECKS PASS"
