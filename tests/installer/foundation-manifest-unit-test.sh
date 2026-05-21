#!/bin/bash
# tests/installer/foundation-manifest-unit-test.sh
#
# Synthetic unit test for SP08 T-5 baseline slice (S62):
#   - generate-foundation-manifest.sh runs on clean foundation-repo
#   - Output is valid JSON with the canonical {version, generated_at,
#     generator_sha256, files[]} shape
#   - Determinism: two runs produce byte-identical output modulo
#     generated_at + generator_sha256 (the latter is also stable; the
#     former always varies)
#   - install.sh ships baseline → $CLAUDE_HOME/foundation-manifest.json
#     with sha256 + mode + size all preserved
#   - Schema sanity: every files[] record has path/sha256/mode/size in
#     the expected shape (sha256 64-hex, mode 4-digit octal, size > 0)
#   - Install round-trip: $CLAUDE_HOME copy is byte-identical to
#     $SOURCE_REPO copy (no install-side mutation); uninstall.sh
#     removes the manifest as foundation provenance
#
# Hermetic: each test creates its own tmpdir CLAUDE_HOME; SOURCE_REPO
# points at the foundation-repo top. No mutation of live ~/.claude.
# R-23: bash 3.2 compat.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GENERATOR="$REPO_ROOT/generate-foundation-manifest.sh"
INSTALL_SH="$REPO_ROOT/install.sh"
UNINSTALL_SH="$REPO_ROOT/uninstall.sh"
COMMITTED_MANIFEST="$REPO_ROOT/governance/foundation-manifest.json"

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
  d="$(mktemp -d -t fmanifest-test.XXXXXX)"
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

assert_match() {
  local actual="$1" regex="$2" label="$3"
  if printf '%s' "$actual" | grep -qE -- "$regex"; then
    printf '  PASS %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: actual=%s regex=%s\n' "$label" "$actual" "$regex" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_gt() {
  local actual="$1" floor="$2" label="$3"
  if [ "$actual" -gt "$floor" ] 2>/dev/null; then
    printf '  PASS %s (%s > %s)\n' "$label" "$actual" "$floor"
    PASS=$((PASS+1))
  else
    printf '  FAIL %s: actual=%s not > %s\n' "$label" "$actual" "$floor" >&2
    FAIL=$((FAIL+1))
  fi
}

# --- prereq sanity ---
if [ ! -x "$GENERATOR" ]; then
  printf 'FAIL: generator not executable at %s\n' "$GENERATOR" >&2
  exit 7
fi
if [ ! -x "$INSTALL_SH" ]; then
  printf 'FAIL: install.sh not executable at %s\n' "$INSTALL_SH" >&2
  exit 7
fi
if [ ! -x "$UNINSTALL_SH" ]; then
  printf 'FAIL: uninstall.sh not executable at %s\n' "$UNINSTALL_SH" >&2
  exit 7
fi

# =====================================================================
# T1 — Generator runs on clean foundation-repo, emits canonical JSON
# =====================================================================
printf 'T1: generator emits canonical {version, generated_at, generator_sha256, files} JSON\n'

T1_OUT="$(mk_tmp)/manifest.json"
rc=0
SOURCE_REPO="$REPO_ROOT" bash "$GENERATOR" -o "$T1_OUT" 2>"$T1_OUT.err" || rc=$?
assert_eq "0" "$rc" "T1.1: generator exits 0"
assert_path_exists "$T1_OUT" "T1.2: generator wrote output file"

if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$T1_OUT" 2>/dev/null; then
  printf '  FAIL T1.3: output is not valid JSON\n' >&2
  FAIL=$((FAIL+1))
else
  printf '  PASS T1.3: output is valid JSON\n'
  PASS=$((PASS+1))
fi

t1_keys="$(jq -r 'keys | join(",")' "$T1_OUT" 2>/dev/null)"
assert_eq "files,generated_at,generator_sha256,version" "$t1_keys" "T1.4: top-level keys are sorted (files,generated_at,generator_sha256,version)"

t1_count="$(jq '.files | length' "$T1_OUT")"
assert_gt "$t1_count" "100" "T1.5: files[] populated (>100 entries)"

# =====================================================================
# T2 — Determinism: two consecutive runs produce identical content
#       modulo generated_at (generator_sha256 is also stable)
# =====================================================================
printf 'T2: determinism — two runs byte-identical modulo generated_at\n'

T2_DIR="$(mk_tmp)"
SOURCE_REPO="$REPO_ROOT" bash "$GENERATOR" -o "$T2_DIR/run1.json" 2>/dev/null
SOURCE_REPO="$REPO_ROOT" bash "$GENERATOR" -o "$T2_DIR/run2.json" 2>/dev/null

# Strip generated_at field; compare remaining content byte-for-byte.
jq 'del(.generated_at)' "$T2_DIR/run1.json" > "$T2_DIR/run1.normalized.json"
jq 'del(.generated_at)' "$T2_DIR/run2.json" > "$T2_DIR/run2.normalized.json"

if diff -q "$T2_DIR/run1.normalized.json" "$T2_DIR/run2.normalized.json" >/dev/null 2>&1; then
  printf '  PASS T2.1: runs byte-identical sans generated_at\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T2.1: determinism violated\n' >&2
  FAIL=$((FAIL+1))
fi

# Generator self-sha256 stable across runs (script unchanged)
t2_gen_sha_1="$(jq -r '.generator_sha256' "$T2_DIR/run1.json")"
t2_gen_sha_2="$(jq -r '.generator_sha256' "$T2_DIR/run2.json")"
assert_eq "$t2_gen_sha_1" "$t2_gen_sha_2" "T2.2: generator_sha256 stable across runs"

# files[] array byte-identical across runs (sort_by(.path) is deterministic)
t2_files_sha_1="$(jq -c '.files' "$T2_DIR/run1.json" | shasum -a 256 | awk '{print $1}')"
t2_files_sha_2="$(jq -c '.files' "$T2_DIR/run2.json" | shasum -a 256 | awk '{print $1}')"
assert_eq "$t2_files_sha_1" "$t2_files_sha_2" "T2.3: files[] array sha256-identical across runs"

# =====================================================================
# T3 — Schema sanity: every record has path/sha256/mode/size in
#       canonical shape (sha256 64-hex, mode 4-digit octal, size > 0)
# =====================================================================
printf 'T3: schema sanity per-record (path/sha256/mode/size shape)\n'

# Every record has all 4 keys
t3_missing_keys="$(jq '[.files[] | select((has("path") and has("sha256") and has("mode") and has("size")) | not)] | length' "$T1_OUT")"
assert_eq "0" "$t3_missing_keys" "T3.1: every record has path+sha256+mode+size"

# Every record's keys are exactly the 4 expected (sorted by jq -c via the records)
t3_extra_keys="$(jq '[.files[] | select((keys | sort) != ["mode","path","sha256","size"])] | length' "$T1_OUT")"
assert_eq "0" "$t3_extra_keys" "T3.2: every record has exactly mode+path+sha256+size keys"

# Every sha256 is 64 hex chars
t3_bad_sha="$(jq '[.files[] | select(.sha256 | test("^[a-f0-9]{64}$") | not)] | length' "$T1_OUT")"
assert_eq "0" "$t3_bad_sha" "T3.3: every sha256 is 64 lowercase hex chars"

# Every mode is 4-digit octal
t3_bad_mode="$(jq '[.files[] | select(.mode | test("^[0-7]{4}$") | not)] | length' "$T1_OUT")"
assert_eq "0" "$t3_bad_mode" "T3.4: every mode is 4-digit octal"

# Every non-.gitkeep size > 0 (no empty content files in foundation tree).
# SP15 T-1e: vault-init/ ships 6 .gitkeep scaffolds (System Governance/, Vault Writers/,
# file-type-contracts/, Logs/Archive/, Logs/backlog-progress/, Meetings/) as empty-dir
# markers per §A53. These are by-design zero-byte; T3.5b asserts the exact contract.
t3_zero_size="$(jq '[.files[] | select(.size <= 0 and (.path | test("\\.gitkeep$") | not))] | length' "$T1_OUT")"
assert_eq "0" "$t3_zero_size" "T3.5: every non-.gitkeep size > 0"

# .gitkeep scaffolds (vault-init/ subdir markers per §A53) must be exactly 6, all zero-byte
t3_gitkeep_count="$(jq '[.files[] | select(.path | endswith(".gitkeep"))] | length' "$T1_OUT")"
assert_eq "6" "$t3_gitkeep_count" "T3.5b: exactly 6 .gitkeep scaffold markers in manifest (vault-init/ subdir scaffolds)"
t3_gitkeep_nonzero="$(jq '[.files[] | select((.path | endswith(".gitkeep")) and .size > 0)] | length' "$T1_OUT")"
assert_eq "0" "$t3_gitkeep_nonzero" "T3.5c: every .gitkeep file is zero-byte (empty-dir marker contract)"

# Sample known file: hooks/pre-write-guard.sh (verified shipped per T1.1 of install test)
t3_pwg="$(jq -r '.files[] | select(.path=="hooks/pre-write-guard.sh") | .path' "$T1_OUT")"
assert_eq "hooks/pre-write-guard.sh" "$t3_pwg" "T3.6: hooks/pre-write-guard.sh present"

# Sample translation: lib/*.sh translated to hooks/lib/*.sh
t3_lib_translation="$(jq '[.files[] | select(.path | startswith("hooks/lib/"))] | length' "$T1_OUT")"
assert_gt "$t3_lib_translation" "0" "T3.7: lib/*.sh → hooks/lib/*.sh translation present"

# No raw lib/ paths (translation must be applied)
t3_raw_lib="$(jq '[.files[] | select(.path | startswith("lib/"))] | length' "$T1_OUT")"
assert_eq "0" "$t3_raw_lib" "T3.8: no raw lib/ paths in installed-relative output"

# =====================================================================
# T4 — install.sh ships baseline → $CLAUDE_HOME/governance/foundation-manifest.json
#       with byte-identical content (no install-side mutation)
#       SP18 T-3 relocated manifest from $CLAUDE_HOME root to governance/.
# =====================================================================
printf 'T4: install.sh ships baseline byte-identical to SOURCE_REPO copy\n'

CH="$(mk_tmp)"
rc=0
HOME="$CH" CLAUDE_HOME="$CH" SOURCE_REPO="$REPO_ROOT" bash "$INSTALL_SH" --apply >"$CH/.stdout" 2>"$CH/.stderr" || rc=$?
assert_eq "0" "$rc" "T4.1: install.sh exits 0 with manifest at SOURCE_REPO governance/"
assert_path_exists "$CH/governance/foundation-manifest.json" "T4.2: governance/foundation-manifest.json shipped to \$CLAUDE_HOME"

# Round-trip: $CLAUDE_HOME copy must be byte-identical to $SOURCE_REPO copy
src_sha="$(shasum -a 256 "$COMMITTED_MANIFEST" | awk '{print $1}')"
dst_sha="$(shasum -a 256 "$CH/governance/foundation-manifest.json" | awk '{print $1}')"
assert_eq "$src_sha" "$dst_sha" "T4.3: shipped manifest sha256 matches SOURCE_REPO copy (no mutation)"

# Provenance log records the foundation_manifest_sha256
prov_log="$(ls "$CH/logs"/install-*.log 2>/dev/null | head -1)"
assert_grep "foundation_manifest_sha256:" "$prov_log" "T4.4: provenance log records foundation_manifest_sha256"
assert_grep "$src_sha" "$prov_log"                    "T4.5: provenance log sha256 matches shipped baseline"

# slice_scope reflects T-5 baseline ship (post-SP18 T-3 path update)
assert_grep "governance/foundation-manifest.json baseline copy" "$prov_log" "T4.6: slice_scope mentions T-5 baseline copy at governance/"

# =====================================================================
# T5 — install→uninstall round-trip: manifest removed by uninstall as
#       foundation provenance (allowlist symmetry; SP18 T-3 special-case
#       handling for chicken-and-egg-not-in-baseline file)
# =====================================================================
printf 'T5: uninstall removes governance/foundation-manifest.json as foundation provenance\n'

# Build mock launchctl that returns no labels (clean uninstall path)
MOCK_DIR="$(mk_tmp)"
MOCK_LC="$MOCK_DIR/mock-launchctl"
cat > "$MOCK_LC" <<'EOF'
#!/bin/bash
case "$1" in
  list) printf 'PID\tStatus\tLabel\n' ;;
  bootout) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$MOCK_LC"

rc=0
CLAUDE_HOME="$CH" LAUNCHCTL_BIN="$MOCK_LC" bash "$UNINSTALL_SH" >"$CH/.uninstall.stdout" 2>"$CH/.uninstall.stderr" || rc=$?
assert_eq "0" "$rc" "T5.1: uninstall.sh exits 0"

if [ -e "$CH/governance/foundation-manifest.json" ]; then
  printf '  FAIL T5.2: governance/foundation-manifest.json not removed by uninstall\n' >&2
  FAIL=$((FAIL+1))
else
  printf '  PASS T5.2: governance/foundation-manifest.json removed (chicken-and-egg special case)\n'
  PASS=$((PASS+1))
fi

# But the .pre-uninstall-* backup retains the manifest (forensics)
backup_manifest="$(ls "$CH"/.pre-uninstall-*/governance/foundation-manifest.json 2>/dev/null | head -1)"
if [ -n "$backup_manifest" ] && [ -f "$backup_manifest" ]; then
  printf '  PASS T5.3: governance/foundation-manifest.json preserved in backup dir\n'
  PASS=$((PASS+1))
else
  printf '  FAIL T5.3: governance/foundation-manifest.json missing from backup dir\n' >&2
  FAIL=$((FAIL+1))
fi

# Backup sha256 matches original (cp -R fidelity)
if [ -n "$backup_manifest" ] && [ -f "$backup_manifest" ]; then
  bk_sha="$(shasum -a 256 "$backup_manifest" | awk '{print $1}')"
  assert_eq "$src_sha" "$bk_sha" "T5.4: backup manifest sha256 matches original"
fi

# =====================================================================
# Summary
# =====================================================================
printf '\n=== foundation-manifest-unit-test ===\n'
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
