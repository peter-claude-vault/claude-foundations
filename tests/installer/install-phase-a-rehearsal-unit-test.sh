#!/bin/bash
# tests/installer/install-phase-a-rehearsal-unit-test.sh
#
# Plan 81 SP01 Phase A (T-20) rehearsal harness — exercises state
# classification branches and posture gates the existing happy-path test
# does not cover. Net-new coverage relative to install-happy-path-unit-test.sh:
#
#   T1  foundation-only re-install — install --apply twice. Default re-run
#       fires G2 (exit 52) by design (sha256 drift on settings.json + manifest
#       baseline divergence after Step 12 atomic merge). Re-install REQUIRES
#       a 3-flag ceremony: --force-install + I-UNDERSTAND-OVERWRITE-RISK
#       sentinel (interactive stdin) + --backup-dir <path> (because settings.json
#       pre-exists, G3's destructive-op guard fires at exit 53 without backup).
#       Test documents both paths: refuse-by-default + override-with-ceremony.
#       Phase A finding: adopters re-running install.sh after first install
#       MUST know the full 3-flag ceremony. This is the most important T-20
#       on-call surface this harness surfaces.
#   T2  mixed state — adopter-private top-level entry survives default
#       cp -n preserve (state=mixed, rc=0, adopter file untouched, foundation
#       files land)
#   T3  user-only refuse-gate — \$CLAUDE_HOME contains ONLY non-foundation
#       entries → exit 21 without --force-install; pre-existing files
#       untouched (April-13-class protection)
#   T4  user-only --force-install override → rc=0, adopter entries survive
#       (cp -n preserve still applies)
#   T5  G9 dry-run posture — install without --apply → action-plan JSON to
#       stdout, ZERO \$CLAUDE_HOME writes, rc=0
#
# Why net-new: the happy-path test exercises the fresh state-classification
# branch end-to-end; Phase A deploy day surfaces the OTHER three branches
# (foundation-only on adopter re-run, mixed on adopter with private content,
# user-only as the April-13 protection). Authoring these tests pre-T-20
# de-risks the 7-day soak: any adopter-shape failure mode lands as a unit
# test failure now, not a Phase A on-call page.
#
# Hermetic: each test creates its own tmpdir CLAUDE_HOME; SOURCE_REPO points
# at the foundation-repo top. No mutation of live ~/.claude. PYTHONUSERBASE
# forwarding (Plan 81 SP01 S16 pattern) re-exposes user-site site-packages
# so Step 13.6 jsonschema validation runs end-to-end despite HOME isolation.
#
# Foundation-repo path-exempt: harness lives entirely under
# ~/Code/claude-stem/tests/installer/; gate-free regardless of Plan 81
# detection-gap state in plan-71-live-guard.sh.
#
# Routing note: install.sh `info()` routes to STDOUT in --apply mode and
# STDERR in dry-run. State-classification messages are emitted via info(),
# so --apply assertions look at .stdout; dry-run JSON also emits on stdout
# but is the entire stdout payload. `diag()` always routes to stderr.
#
# R-23: bash 3.2 compat (macOS /bin/bash 3.2.57). No associative arrays.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"

# --- harness ---
PASS=0
FAIL=0
TMPDIRS=""

cleanup() {
  for d in $TMPDIRS; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM

mk_tmp() {
  local d
  d="$(mktemp -d -t install-rehearsal.XXXXXX)"
  TMPDIRS="$TMPDIRS $d"
  printf '%s' "$d"
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: expected=%s actual=%s\n' "$label" "$expected" "$actual" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_path_exists() {
  local path="$1" label="$2"
  if [ -e "$path" ]; then
    printf '  PASS %s (path exists: %s)\n' "$label" "$path"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (path missing: %s)\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_path_absent() {
  local path="$1" label="$2"
  if [ ! -e "$path" ]; then
    printf '  PASS %s (path correctly absent: %s)\n' "$label" "$path"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (path unexpectedly exists: %s)\n' "$label" "$path" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_grep() {
  local pattern="$1" file="$2" label="$3"
  if grep -q -- "$pattern" "$file" 2>/dev/null; then
    printf '  PASS %s (pattern: %s)\n' "$label" "$pattern"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s (pattern not found: %s in %s)\n' "$label" "$pattern" "$file" >&2
    FAIL=$((FAIL+1))
  fi
}

# --- prereq sanity ---
if [ ! -x "$INSTALL_SH" ]; then
  printf 'FAIL: install.sh not executable at %s\n' "$INSTALL_SH" >&2
  exit 7
fi

USERBASE="$(python3 -m site --user-base 2>/dev/null || true)"

# =====================================================================
# T1 — foundation-only re-install (G2 ceremony documented)
# =====================================================================
printf 'T1: foundation-only re-install — refuse-by-default + ceremony override\n'

CH1="$(mk_tmp)"
rc=0
HOME="$CH1" CLAUDE_HOME="$CH1" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply >"$CH1/.stdout1" 2>"$CH1/.stderr1" </dev/null || rc=$?
assert_eq "0" "$rc" "T1.1: first install --apply rc=0 (fresh state)"

assert_grep "state classification: fresh" "$CH1/.stdout1" \
  "T1.2: first run classifies as fresh (info-on-stdout)"

prov_after_first="$(ls "$CH1/logs"/install-*.log 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "1" "$prov_after_first" "T1.3: provenance log count = 1 after first run"

# Snapshot settings.json sha for idempotency check across the ceremony override
sha_before="$(shasum -a 256 "$CH1/settings.json" 2>/dev/null | awk '{print $1}')"

# Capture files OUTSIDE CLAUDE_HOME for clean state assertions
CAPTURE1="$(mk_tmp)"

# Second install WITHOUT --force-install — G2 must fire (exit 52). This is
# expected Phase A behavior, not a bug: settings.json was atomically merged
# in run 1, foundation-manifest.json baseline now diverges from on-disk file.
rc=0
HOME="$CH1" CLAUDE_HOME="$CH1" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply >"$CAPTURE1/stdout2" 2>"$CAPTURE1/stderr2" </dev/null || rc=$?
assert_eq "52" "$rc" "T1.4: re-install without --force-install fires G2 → exit 52 (refuse-by-default)"

assert_grep "G2 fired" "$CAPTURE1/stderr2" \
  "T1.5: G2 diagnostic emitted on stderr"

# Third install WITH full ceremony: --force-install + sentinel via stdin +
# --backup-dir. settings.json pre-exists from run 1, so G3's destructive-op
# guard requires --backup-dir for proof-of-life (exit 53 without it). The
# full Phase A re-install ceremony is therefore three flags + sentinel.
T1_BACKUP="$(mk_tmp)/backup"
rc=0
printf 'I-UNDERSTAND-OVERWRITE-RISK\n' | \
  HOME="$CH1" CLAUDE_HOME="$CH1" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
    bash "$INSTALL_SH" --apply --force-install --backup-dir "$T1_BACKUP" \
    >"$CAPTURE1/stdout3" 2>"$CAPTURE1/stderr3" || rc=$?
assert_eq "0" "$rc" "T1.6: re-install with --force-install + sentinel + --backup-dir rc=0 (full ceremony succeeds)"

# Regression check (T-29 fix landed Session 18, 2026-05-10):
# After a fresh install, the second-run state must classify as
# "foundation-only" because SP10 T-4 (seeded $CLAUDE_HOME/CLAUDE.md) and
# SP11 T-1 (seeded $CLAUDE_HOME/projects/<slug>/memory/MEMORY.md) are now
# present in install.sh's foundation_known_entries (line ~222). Prior
# Session 17 D1 ship encoded the bug as "mixed"; T-29 flipped this from
# bug-encoder to regression-checker. If this assertion ever flips back to
# "mixed", it means CLAUDE.md or projects/ regressed out of the whitelist.
assert_grep "state classification: foundation-only" "$CAPTURE1/stdout3" \
  "T1.7: ceremony re-install classifies state as foundation-only (T-29 regression check; whitelist must include CLAUDE.md + projects)"

prov_after_third="$(ls "$CH1/logs"/install-*.log 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "2" "$prov_after_third" "T1.8: provenance log count = 2 after ceremony re-install (G2 refuse leaves no log; one per successful --apply)"

# =====================================================================
# T2 — mixed state — adopter-private top-level entry survives
# =====================================================================
printf 'T2: mixed state — adopter-private entry survives default cp -n preserve\n'

CH2="$(mk_tmp)"
mkdir -p "$CH2/my-private-config"
printf 'adopter-private content\n' > "$CH2/my-private-config/notes.md"
adopter_sha_before="$(shasum -a 256 "$CH2/my-private-config/notes.md" | awk '{print $1}')"

# Pre-seed an empty foundation-known dir so we land in mixed (foundation
# entry + adopter entry) rather than user-only (no foundation entries).
mkdir -p "$CH2/hooks"

rc=0
HOME="$CH2" CLAUDE_HOME="$CH2" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply >"$CH2/.stdout" 2>"$CH2/.stderr" </dev/null || rc=$?
assert_eq "0" "$rc" "T2.1: install --apply rc=0 in mixed state"

assert_grep "state classification: mixed" "$CH2/.stdout" \
  "T2.2: state classified as mixed (info-on-stdout)"

assert_path_exists "$CH2/my-private-config/notes.md" \
  "T2.3: adopter-private file survives install"

adopter_sha_after="$(shasum -a 256 "$CH2/my-private-config/notes.md" | awk '{print $1}')"
assert_eq "$adopter_sha_before" "$adopter_sha_after" \
  "T2.4: adopter-private file content unchanged (cp -n preserve)"

# Foundation files actually landed
assert_path_exists "$CH2/hooks/pre-write-guard.sh" \
  "T2.5: foundation file pre-write-guard.sh installed alongside adopter content"

# =====================================================================
# T3 — user-only refuse-gate (exit 21)
# =====================================================================
printf 'T3: user-only state without --force-install → exit 21\n'

CH3="$(mk_tmp)"
mkdir -p "$CH3/my-other-tool" "$CH3/some-config"
printf 'tool content\n' > "$CH3/my-other-tool/data.txt"
printf 'config\n' > "$CH3/some-config/settings.yml"

# Snapshot pre-state for untouched assertion (capture files external to CLAUDE_HOME)
pre_sha="$(find "$CH3" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')"
CAPTURE3="$(mk_tmp)"

rc=0
HOME="$CH3" CLAUDE_HOME="$CH3" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply >"$CAPTURE3/stdout" 2>"$CAPTURE3/stderr" </dev/null || rc=$?
assert_eq "21" "$rc" "T3.1: install exits 21 in user-only state without --force-install"

assert_grep "state=user-only fired" "$CAPTURE3/stderr" \
  "T3.2: user-only diagnostic emitted on stderr"

post_sha="$(find "$CH3" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')"
assert_eq "$pre_sha" "$post_sha" \
  "T3.3: pre-existing CLAUDE_HOME content untouched on refuse"

# =====================================================================
# T4 — user-only --force-install override
# =====================================================================
printf 'T4: user-only state with --force-install → rc=0, adopter entries survive\n'

CH4="$(mk_tmp)"
mkdir -p "$CH4/my-other-tool"
printf 'survives forced install\n' > "$CH4/my-other-tool/data.txt"
adopter_t4_sha_before="$(shasum -a 256 "$CH4/my-other-tool/data.txt" | awk '{print $1}')"

rc=0
HOME="$CH4" CLAUDE_HOME="$CH4" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" --apply --force-install >"$CH4/.stdout" 2>"$CH4/.stderr" </dev/null || rc=$?
assert_eq "0" "$rc" "T4.1: install --apply --force-install rc=0 in user-only state"

assert_path_exists "$CH4/my-other-tool/data.txt" \
  "T4.2: adopter-private file survives --force-install"

adopter_t4_sha_after="$(shasum -a 256 "$CH4/my-other-tool/data.txt" | awk '{print $1}')"
assert_eq "$adopter_t4_sha_before" "$adopter_t4_sha_after" \
  "T4.3: adopter-private file content unchanged under --force-install (cp -n preserves non-foundation paths)"

# Foundation files landed
assert_path_exists "$CH4/hooks/pre-write-guard.sh" \
  "T4.4: foundation files installed under --force-install"

# =====================================================================
# T5 — G9 dry-run posture (no --apply → JSON to stdout, zero writes)
# =====================================================================
printf 'T5: G9 dry-run posture — no --apply → action-plan JSON, zero CLAUDE_HOME writes\n'

CH5="$(mk_tmp)"
# CH5 starts empty; record pre-state file count.
pre_count="$(find "$CH5" -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$pre_count" "T5.0: CLAUDE_HOME starts empty"

# .stdout/.stderr capture files live OUTSIDE CH5 to keep the post-write
# count assertion clean. Using a sibling dir from mk_tmp ensures cleanup.
CAPTURE5="$(mk_tmp)"
rc=0
HOME="$CH5" CLAUDE_HOME="$CH5" SOURCE_REPO="$REPO_ROOT" PYTHONUSERBASE="$USERBASE" \
  bash "$INSTALL_SH" >"$CAPTURE5/stdout" 2>"$CAPTURE5/stderr" </dev/null || rc=$?
assert_eq "0" "$rc" "T5.1: dry-run rc=0 (no --apply)"

# Action-plan JSON should be on stdout. Validate it parses.
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CAPTURE5/stdout" 2>/dev/null; then
  printf '  PASS T5.2: dry-run stdout is valid JSON\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T5.2: dry-run stdout is not valid JSON\n' >&2
  head -20 "$CAPTURE5/stdout" >&2
  FAIL=$((FAIL+1))
fi

# state_classification key present in JSON
if python3 -c "
import json, sys
with open(sys.argv[1]) as f: doc = json.load(f)
sys.exit(0 if 'state_classification' in doc else 1)
" "$CAPTURE5/stdout" 2>/dev/null; then
  printf '  PASS T5.3: dry-run JSON includes state_classification\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T5.3: dry-run JSON missing state_classification\n' >&2
  FAIL=$((FAIL+1))
fi

# Most importantly: ZERO writes under CLAUDE_HOME (CH5 stays clean because
# capture files are external).
post_count="$(find "$CH5" -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$post_count" "T5.4: dry-run produced zero CLAUDE_HOME writes"

# Provenance log NOT written (G9 spec: dry-run skips provenance)
assert_path_absent "$CH5/logs" "T5.5: dry-run did not create logs/ (no provenance write)"

# =====================================================================
# Summary
# =====================================================================
printf '\n=== install-phase-a-rehearsal-unit-test ===\n'
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
