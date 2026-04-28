#!/usr/bin/env bash
# T-14: 4-layer grep-audit acceptance gate
# Plan 71 SP01 — claude-foundations-engine-v2
#
# Audits SP01 distributed assets for personal/engagement reference leaks
# across 4 layers:
#   L1 plain grep -iE (case-insensitive set) + grep -E (case-sensitive set)
#   L2 NFKC-normalized line-based (both case sets)
#   L3 base64-decoded blobs >=16 chars (combined, case-insensitive)
#   L4 hex-decoded even-length blobs >=16 chars (combined, case-insensitive)
#
# Pattern split: the CI set covers tokens where case carries no signal.
# The CS set covers folder/proper-name references where capitalization
# distinguishes a specific-folder leak from the same noun phrase used
# generically in user prose. See build_pattern_cs for the live token set.
#
# Exit 0: full clean
# Exit 1: any hit (fail-closed CI gate)
# Exit 2: tooling failure (python3 missing, file unreadable)
#
# bash 3.2 compatible. Self-aware: audits itself with zero hits via
# split-construction of both pattern sets (no single line carries any
# forbidden token contiguously).

set -u

ROOT="${HOME}/.claude"

if ! command -v python3 >/dev/null 2>&1; then
  echo "TOOLING_ERROR: python3 not found in PATH" >&2
  exit 2
fi

# Case-insensitive forbidden tokens (split-construction; no contiguous match
# in any single line of this script body).
build_pattern_ci() {
  local p=""
  p="${p}Pe";    p="${p}ter|"
  p="${p}pe";    p="${p}tertiktinsky|"
  p="${p}Art";   p="${p}efact|"
  p="${p}CD";    p="${p}MO|"
  p="${p}L[oO]"; p="${p}real|"
  p="${p}Lanc";  p="${p}[oôO]me|"
  p="${p}Kie";   p="${p}hl|"
  p="${p}Tif";   p="${p}fany|"
  p="${p}Wal";   p="${p}mart|"
  p="${p}LU";    p="${p}XE|"
  p="${p}arte";  p="${p}fact-bd|"
  p="${p}arte";  p="${p}fact-dashboard|"
  p="${p}arte";  p="${p}fact-daily-logs|"
  p="${p}56-sp"; p="${p}ine-remediation|"
  p="${p}/Use";  p="${p}rs/pet"; p="${p}ertiktinsky"
  printf '%s' "$p"
}

# Case-sensitive forbidden tokens — capitalization signals a specific
# folder/proper-name reference and avoids FPs on generic Obsidian usage.
build_pattern_cs() {
  local p=""
  p="${p}Obs";   p="${p}idian Vault"
  printf '%s' "$p"
}

PATTERN_CI="$(build_pattern_ci)"
PATTERN_CS="$(build_pattern_cs)"

# Layers 2-4 run via Python for NFKC + base64 + hex codec coverage. Args
# pass via argv (heredoc owns stdin per Python convention; never pipe).
audit_advanced() {
  local file="$1"
  local pattern_ci="$2"
  local pattern_cs="$3"
  python3 - "$file" "$pattern_ci" "$pattern_cs" <<'PY'
import sys, re, base64, unicodedata

path = sys.argv[1]
pat_ci = sys.argv[2]
pat_cs = sys.argv[3]

try:
    with open(path, 'rb') as f:
        data = f.read()
    content = data.decode('utf-8', errors='ignore')
except Exception as e:
    print('OPEN_ERROR: ' + str(e), file=sys.stderr)
    sys.exit(2)

# L2: NFKC line-based (CI + CS)
nfkc = unicodedata.normalize('NFKC', content)
l2_hits = 0
for line in nfkc.splitlines():
    if re.search(pat_ci, line, re.IGNORECASE) or re.search(pat_cs, line, 0):
        l2_hits += 1

# L3 + L4 use combined pattern, case-insensitive — decoded blobs are
# post-obfuscation, so maximum coverage matters more than FP avoidance.
combined = pat_ci + '|' + pat_cs

# L3: base64 candidates >=16 chars
l3_hits = 0
for tok in re.findall(r'[A-Za-z0-9+/=]{16,}', content):
    try:
        decoded = base64.b64decode(tok + '==', validate=False).decode('utf-8', errors='ignore')
    except Exception:
        continue
    if re.search(combined, decoded, re.IGNORECASE):
        l3_hits += 1

# L4: hex candidates >=16 chars even-length
l4_hits = 0
for tok in re.findall(r'[0-9a-fA-F]{16,}', content):
    if len(tok) % 2 != 0:
        continue
    try:
        decoded = bytes.fromhex(tok).decode('utf-8', errors='ignore')
    except Exception:
        continue
    if re.search(combined, decoded, re.IGNORECASE):
        l4_hits += 1

print('%d %d %d' % (l2_hits, l3_hits, l4_hits))
PY
}

total_l1=0
total_l2=0
total_l3=0
total_l4=0
files_count=0
exit_code=0

echo "==== T-14: 4-layer grep-audit acceptance gate ===="
echo "Root:    $ROOT"
echo "Layers:  L1=plain L2=NFKC L3=base64 L4=hex"
echo "----"

while IFS= read -r f; do
  files_count=$((files_count + 1))
  rel="${f#$ROOT/}"

  l1_ci=$(grep -ciE "$PATTERN_CI" "$f" 2>/dev/null)
  [ -z "$l1_ci" ] && l1_ci=0
  l1_cs=$(grep -cE "$PATTERN_CS" "$f" 2>/dev/null)
  [ -z "$l1_cs" ] && l1_cs=0
  l1=$((l1_ci + l1_cs))

  if ! adv=$(audit_advanced "$f" "$PATTERN_CI" "$PATTERN_CS"); then
    echo "TOOLING_ERROR: audit_advanced failed for $rel" >&2
    exit_code=2
    continue
  fi

  l2=$(printf '%s' "$adv" | awk '{print $1}')
  l3=$(printf '%s' "$adv" | awk '{print $2}')
  l4=$(printf '%s' "$adv" | awk '{print $3}')

  [ -z "$l2" ] && l2=0
  [ -z "$l3" ] && l3=0
  [ -z "$l4" ] && l4=0

  printf '%-60s L1:%s L2:%s L3:%s L4:%s\n' "$rel" "$l1" "$l2" "$l3" "$l4"

  total_l1=$((total_l1 + l1))
  total_l2=$((total_l2 + l2))
  total_l3=$((total_l3 + l3))
  total_l4=$((total_l4 + l4))
done < <(find "$ROOT/schemas" "$ROOT/onboarding" -type f ! -name '.*' | sort)

echo "----"
total=$((total_l1 + total_l2 + total_l3 + total_l4))
printf 'SUMMARY: %d files audited; total hits L1:%d L2:%d L3:%d L4:%d (grand=%d)\n' \
  "$files_count" "$total_l1" "$total_l2" "$total_l3" "$total_l4" "$total"

if [ "$exit_code" -eq 2 ]; then
  echo "VERDICT: TOOLING FAILURE (exit 2)"
  exit 2
elif [ "$total" -gt 0 ]; then
  echo "VERDICT: HITS DETECTED — fail-closed (exit 1)"
  exit 1
else
  echo "VERDICT: CLEAN (exit 0)"
  exit 0
fi
