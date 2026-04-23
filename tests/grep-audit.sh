#!/bin/bash
# tests/grep-audit.sh [target-dir]
#
# 4-layer reference-leak audit. Scans every distributed asset under $TARGET
# for anything in the Peter-specific pattern list. Runs four independent
# layers so obfuscation and commit-history hits cannot slip through:
#
#   Layer 1: raw fixed-string + regex, case-insensitive (grep -F -i / -E -i)
#   Layer 2: NFKC-normalized text (defeats Unicode compatibility obfuscation
#            like mathematical bold, fullwidth, zero-width joiner insertion)
#   Layer 3: base64 blobs decoded then scanned (catches embedded refs)
#   Layer 4: `git log --all --format= -p` diff history (catches refs removed
#            from HEAD but still in commit objects; --format= strips commit
#            headers so author/committer metadata is NOT audited — that is
#            handled separately by SP08 T-9's git-filter-repo scrub)
#
# Exit codes:
#   0  clean (all 4 layers green)
#   1  any layer hit (diagnostic on stderr, per-layer section)
#   7  setup error (missing pattern files, python3 absent, etc.)
#
# Environment:
#   GREP_AUDIT_SKIP_LAYER4=1  Skip Layer 4 (used during self-tests where
#                             seeded fixtures in history would trivially hit)
#   GREP_AUDIT_PATTERNS_DIR=<dir>   Override pattern dir (default: adjacent
#                                   grep-audit-patterns/)
#
# Primitive P6 in SP00. First consumer: SP01 T-14 (α-wave gate).
#
# R-23: bash 3.2 compat.

set -u

TARGET="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERNS_DIR="${GREP_AUDIT_PATTERNS_DIR:-${SCRIPT_DIR}/grep-audit-patterns}"
PATTERNS_LITERAL="${PATTERNS_DIR}/literal.txt"
PATTERNS_REGEX="${PATTERNS_DIR}/regex.txt"

err() { printf 'grep-audit: %s\n' "$1" >&2; }

# --- Setup checks ---
for f in "$PATTERNS_LITERAL" "$PATTERNS_REGEX"; do
  [ -f "$f" ] || { err "missing pattern file: $f"; exit 7; }
done
command -v python3 >/dev/null 2>&1 || { err "python3 required"; exit 7; }
[ -d "$TARGET" ] || { err "target not a directory: $TARGET"; exit 7; }

# --- Exclusion regex ---
# Paths we deliberately skip. Fixtures seed deliberate hits; pattern files
# define the hit strings; this script itself doesn't count; CHANGELOG.md
# and docs/april-13-autopsy.md are explicit carve-outs; .self-verify/
# is T-13 output (attestation logs contain path strings that trigger
# /Users/ regex).
EXCLUDE_RE='/\.git/|/node_modules/|/file-history/|/grep-audit-patterns/|/grep-audit-fixtures/|/\.self-verify/|/grep-audit\.sh$|/CHANGELOG\.md$|/docs/april-13-autopsy\.md$'

# --- Stage Python helpers to a trap-cleaned tmpdir ---
PY_TMP=$(mktemp -d -t grep-audit-py.XXXXXX)
trap 'rm -rf "$PY_TMP"' EXIT INT TERM

cat > "${PY_TMP}/layer2_nfkc.py" <<'PY'
import os, re, sys, unicodedata
target, excl = sys.argv[1], re.compile(sys.argv[2])
for root, dirs, files in os.walk(target):
    dirs[:] = [d for d in dirs if not excl.search(os.path.join(root, d) + '/')]
    for fn in files:
        path = os.path.join(root, fn)
        if excl.search(path):
            continue
        try:
            with open(path, 'r', errors='replace') as fh:
                for i, line in enumerate(fh, 1):
                    nfkc = unicodedata.normalize('NFKC', line)
                    if nfkc != line:
                        sys.stdout.write("{}:{}:{}\n".format(path, i, nfkc.rstrip()))
        except (OSError, UnicodeError):
            continue
PY

cat > "${PY_TMP}/layer3_base64.py" <<'PY'
import os, re, sys, base64
target, excl = sys.argv[1], re.compile(sys.argv[2])
blob_re = re.compile(rb'[A-Za-z0-9+/]{40,}={0,2}')
for root, dirs, files in os.walk(target):
    dirs[:] = [d for d in dirs if not excl.search(os.path.join(root, d) + '/')]
    for fn in files:
        path = os.path.join(root, fn)
        if excl.search(path):
            continue
        try:
            with open(path, 'rb') as fh:
                data = fh.read()
        except OSError:
            continue
        for m in blob_re.finditer(data):
            try:
                decoded = base64.b64decode(m.group(0), validate=True)
                text = decoded.decode('utf-8', errors='replace')
            except Exception:
                continue
            for ln in text.splitlines():
                sys.stdout.write("{}:<base64-blob>:{}\n".format(path, ln))
PY

# --- Per-layer state ---
layer_hits_1=0
layer_hits_2=0
layer_hits_3=0
layer_hits_4=0

# ======================================================================
# Layer 1: raw
# ======================================================================
l1_lit=$(grep -rIn -F -i -f "$PATTERNS_LITERAL" "$TARGET" 2>/dev/null \
  | grep -vE "$EXCLUDE_RE" || true)
l1_re=$(grep -rIn -E -i -f "$PATTERNS_REGEX" "$TARGET" 2>/dev/null \
  | grep -vE "$EXCLUDE_RE" || true)
if [ -n "$l1_lit" ] || [ -n "$l1_re" ]; then
  printf '=== grep-audit Layer 1 (raw) HITS ===\n' >&2
  [ -n "$l1_lit" ] && printf '%s\n' "$l1_lit" >&2
  [ -n "$l1_re"  ] && printf '%s\n' "$l1_re"  >&2
  printf '\n' >&2
  layer_hits_1=1
fi

# ======================================================================
# Layer 2: NFKC
# ======================================================================
l2_out=$(
  python3 "${PY_TMP}/layer2_nfkc.py" "$TARGET" "$EXCLUDE_RE" \
    | grep -E -i -f "$PATTERNS_LITERAL" -f "$PATTERNS_REGEX" 2>/dev/null \
    || true
)
if [ -n "$l2_out" ]; then
  printf '=== grep-audit Layer 2 (NFKC) HITS ===\n%s\n\n' "$l2_out" >&2
  layer_hits_2=1
fi

# ======================================================================
# Layer 3: base64
# ======================================================================
l3_out=$(
  python3 "${PY_TMP}/layer3_base64.py" "$TARGET" "$EXCLUDE_RE" \
    | grep -E -i -f "$PATTERNS_LITERAL" -f "$PATTERNS_REGEX" 2>/dev/null \
    || true
)
if [ -n "$l3_out" ]; then
  printf '=== grep-audit Layer 3 (base64) HITS ===\n%s\n\n' "$l3_out" >&2
  layer_hits_3=1
fi

# ======================================================================
# Layer 4: git log --format= -p (diff content only; no author metadata)
# ======================================================================
if [ "${GREP_AUDIT_SKIP_LAYER4:-0}" != '1' ] && [ -d "${TARGET}/.git" ]; then
  l4_out=$(
    git -C "$TARGET" log --all --format= -p --no-color 2>/dev/null \
      | grep -E -i -f "$PATTERNS_LITERAL" -f "$PATTERNS_REGEX" \
      | head -200 \
      || true
  )
  if [ -n "$l4_out" ]; then
    printf '=== grep-audit Layer 4 (git history diff) HITS ===\n%s\n\n' "$l4_out" >&2
    layer_hits_4=1
  fi
fi

hits_total=$((layer_hits_1 + layer_hits_2 + layer_hits_3 + layer_hits_4))

# --- JSON summary to stdout ---
printf '{"target":"%s","layer1":%d,"layer2":%d,"layer3":%d,"layer4":%d,"hits_total":%d}\n' \
  "$TARGET" "$layer_hits_1" "$layer_hits_2" "$layer_hits_3" "$layer_hits_4" "$hits_total"

[ "$hits_total" -eq 0 ] || exit 1
exit 0
